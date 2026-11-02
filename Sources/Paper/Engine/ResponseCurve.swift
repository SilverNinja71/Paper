import Foundation
import simd

/// A curve through control points in the unit square, used for Apple Pencil pressure/tilt response
/// and for tone curves.
///
/// Evaluation uses monotone cubic Hermite interpolation (Fritsch–Carlson): smooth like a spline, but it
/// never overshoots between points, so a rising set of points always gives a rising curve.
public struct ResponseCurve: Codable, Equatable, Hashable, Sendable {
    /// Control points sorted by x, each in [0, 1]².
    public private(set) var points: [SIMD2<Float>]

    public init(points: [SIMD2<Float>]) {
        var pts = points.map { simd_clamp($0, SIMD2<Float>(0, 0), SIMD2<Float>(1, 1)) }.sorted { $0.x < $1.x }
        // Drop points that share an x with their neighbour (keep the later one).
        var unique: [SIMD2<Float>] = []
        for p in pts {
            if let last = unique.last, abs(last.x - p.x) < 1e-5 { unique[unique.count - 1] = p } else { unique.append(p) }
        }
        pts = unique
        if pts.isEmpty { pts = [SIMD2(0, 0), SIMD2(1, 1)] }
        if pts.count == 1 { pts = [SIMD2(0, pts[0].y), SIMD2(1, pts[0].y)] }
        self.points = pts
    }

    public static let linear = ResponseCurve(points: [SIMD2(0, 0), SIMD2(1, 1)])
    /// Always 1 — the input has no effect.
    public static let constantOne = ResponseCurve(points: [SIMD2(0, 1), SIMD2(1, 1)])

    /// y = x^gamma sampled at five points (gamma < 1 is "soft", > 1 is "firm").
    public static func gamma(_ g: Float) -> ResponseCurve {
        ResponseCurve(points: (0...4).map { i in let x = Float(i) / 4; return SIMD2(x, pow(x, g)) })
    }

    public var isIdentity: Bool {
        points.allSatisfy { abs($0.x - $0.y) < 1e-4 }
    }

    /// Hermite tangents after the Fritsch–Carlson monotonicity fix.
    private var tangents: [Float] {
        let n = points.count
        guard n >= 2 else { return [0] }
        var d = [Float](repeating: 0, count: n - 1)
        for k in 0..<(n - 1) {
            let h = points[k + 1].x - points[k].x
            d[k] = h > 0 ? (points[k + 1].y - points[k].y) / h : 0
        }
        var m = [Float](repeating: 0, count: n)
        m[0] = d[0]
        m[n - 1] = d[n - 2]
        if n > 2 {
            for k in 1..<(n - 1) {
                m[k] = d[k - 1] * d[k] <= 0 ? 0 : (d[k - 1] + d[k]) / 2
            }
        }
        for k in 0..<(n - 1) {
            if d[k] == 0 {
                m[k] = 0; m[k + 1] = 0
            } else {
                let a = m[k] / d[k], b = m[k + 1] / d[k]
                let s = a * a + b * b
                if s > 9 {
                    let t = 3 / s.squareRoot()
                    m[k] = t * a * d[k]
                    m[k + 1] = t * b * d[k]
                }
            }
        }
        return m
    }

    /// The curve's value at `x` (inputs outside [0, 1] are clamped).
    public func value(at x: Float) -> Float {
        evaluate(x, tangents: tangents)
    }

    private func evaluate(_ xIn: Float, tangents m: [Float]) -> Float {
        let x = min(max(xIn, points.first!.x), points.last!.x)
        var k = 0
        while k < points.count - 2 && x > points[k + 1].x { k += 1 }
        let p0 = points[k], p1 = points[k + 1]
        let h = p1.x - p0.x
        guard h > 0 else { return p0.y }
        let t = (x - p0.x) / h
        let t2 = t * t, t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2
        return h00 * p0.y + h10 * h * m[k] + h01 * p1.y + h11 * h * m[k + 1]
    }

    /// `count` evenly spaced samples from x = 0 to x = 1 (for GPU lookup tables).
    public func lut(count: Int) -> [Float] {
        let m = tangents
        return (0..<count).map { i in evaluate(Float(i) / Float(max(1, count - 1)), tangents: m) }
    }

    // MARK: Editing

    public mutating func movePoint(at index: Int, to p: SIMD2<Float>) {
        guard points.indices.contains(index) else { return }
        var pts = points
        let lo: Float = index > 0 ? pts[index - 1].x + 0.01 : 0
        let hi: Float = index < pts.count - 1 ? pts[index + 1].x - 0.01 : 1
        pts[index] = SIMD2(min(max(p.x, lo), hi), min(max(p.y, 0), 1))
        self = ResponseCurve(points: pts)
    }

    /// Adds a point and returns its index.
    @discardableResult
    public mutating func addPoint(_ p: SIMD2<Float>) -> Int {
        self = ResponseCurve(points: points + [p])
        return points.firstIndex { abs($0.x - min(max(p.x, 0), 1)) < 1e-5 } ?? 0
    }

    public mutating func removePoint(at index: Int) {
        guard points.count > 2, points.indices.contains(index) else { return }
        var pts = points
        pts.remove(at: index)
        self = ResponseCurve(points: pts)
    }
}
