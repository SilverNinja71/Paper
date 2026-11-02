import Testing
import Foundation
import Metal
import simd
@testable import PaperCore

// MARK: - Helpers (all file-private so they cannot clash with other test files)

private let adjHaveGPU = MTLCreateSystemDefaultDevice() != nil

private func adjS2L(_ x: Float) -> Float {
    let a = abs(x)
    let y = a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4)
    return x < 0 ? -y : y
}

private func adjL2S(_ x: Float) -> Float {
    let a = abs(x)
    let y = a <= 0.0031308 ? a * 12.92 : 1.055 * pow(a, 1 / 2.4) - 0.055
    return x < 0 ? -y : y
}

private let adjLumaP3 = SIMD3<Float>(0.2289746, 0.6917385, 0.0792869)

/// Premultiplied pixel from straight colour.
private func adjPx(_ r: Float, _ g: Float, _ b: Float, a: Float = 1) -> SIMD4<Float> { SIMD4(r * a, g * a, b * a, a) }

private func adjStraight(_ p: SIMD4<Float>) -> SIMD3<Float> { p.w > 0 ? SIMD3(p.x, p.y, p.z) / p.w : .zero }

private func adjMaxDiff(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Float {
    precondition(a.count == b.count)
    var m: Float = 0
    for (x, y) in zip(a, b) {
        let tol = max(1, abs(y.x), abs(y.y), abs(y.z))     // half floats: error scales with magnitude
        m = max(m, simd_reduce_max(simd_abs(x - y)) / tol)
    }
    return m
}

private func adjIsFinite(_ p: [SIMD4<Float>]) -> Bool {
    p.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite }
}

/// Deterministic pseudo-random numbers in [0, 1).
private struct AdjTestRandom {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float((state >> 40) & 0xFFFFFF) / Float(0x1000000)
    }
}

/// A varied picture: hue across, brightness down, HDR highlights, a transparent stripe and some partial alpha.
private func adjVariedImage(_ w: Int, _ h: Int) -> [SIMD4<Float>] {
    var rng = AdjTestRandom(7)
    var out: [SIMD4<Float>] = []
    for y in 0..<h {
        for x in 0..<w {
            let hue = Float(x) / Float(w)
            let v = (Float(y) + 0.5) / Float(h) * 1.6
            let sat = 0.15 + 0.85 * rng.next()
            func ch(_ n: Float) -> Float { max(0, min(1, abs((hue * 6 + n).truncatingRemainder(dividingBy: 6) - 3) - 1)) }
            let r = v * (1 - sat + sat * ch(0)), g = v * (1 - sat + sat * ch(4)), b = v * (1 - sat + sat * ch(2))
            var a: Float = 1
            if y % 7 == 3 { a = 0.5 }
            if y % 11 == 5 && x % 3 == 0 { a = 0 }
            out.append(adjPx(r, g, b, a: a))
        }
    }
    return out
}

private final class AdjHarness {
    let gpu: PaperGPU
    let pipeline: AdjustmentPipeline

    init() throws {
        gpu = try PaperGPU()
        pipeline = try AdjustmentPipeline(gpu: gpu)
    }

    func texture(_ pixels: [SIMD4<Float>], _ w: Int, _ h: Int) throws -> MTLTexture {
        let t = try gpu.makeTexture(width: w, height: h, label: "test")
        gpu.writePixels(pixels, to: t)
        return t
    }

    /// Runs one adjustment and returns (the half-rounded input, the output).
    @discardableResult
    func run(_ settings: AdjustmentSettings, _ pixels: [SIMD4<Float>], _ w: Int, _ h: Int,
             region: IntRect? = nil) throws -> (input: [SIMD4<Float>], output: [SIMD4<Float>]) {
        let src = try texture(pixels, w, h)
        let dst = try gpu.makeTexture(width: w, height: h, label: "test out")
        gpu.run("clear") { cb in gpu.clear(dst, in: cb) }
        try gpu.run("adjust") { cb in
            try pipeline.encode(settings, source: src, destination: dst,
                                region: region ?? IntRect(x: 0, y: 0, width: w, height: h), commandBuffer: cb)
        }
        return (gpu.readPixels(src), gpu.readPixels(dst))
    }

    /// Applies a settings block to a handful of colours and returns the straight output colours.
    func colors(_ settings: AdjustmentSettings, _ input: [SIMD3<Float>]) throws -> [SIMD3<Float>] {
        let pixels = input.map { adjPx($0.x, $0.y, $0.z) }
        let (_, out) = try run(settings, pixels, pixels.count, 1)
        return out.map(adjStraight)
    }
}

private func adjDevelop(_ edit: (inout DevelopSettings) -> Void) -> AdjustmentSettings {
    var s = AdjustmentSettings(kind: .develop)
    edit(&s.develop)
    return s
}

// MARK: - Tests

@Suite(.enabled(if: adjHaveGPU)) struct AdjustmentTests {

    // MARK: identity and alpha

    @Test func identitySettingsLeaveEveryPixelUnchanged() throws {
        let h = try AdjHarness()
        let w = 40, ht = 30
        let image = adjVariedImage(w, ht)
        for kind in AdjustmentKind.allCases where kind != .gradientMap {
            let (input, output) = try h.run(AdjustmentSettings(kind: kind), image, w, ht)
            #expect(input == output, "\(kind) changed pixels with default settings")
        }
    }

    @Test func negligibleSettingsRunningThroughTheShadersStayWithinHalfFloatTolerance() throws {
        let h = try AdjHarness()
        let w = 40, ht = 30
        let image = adjVariedImage(w, ht)
        var all: [AdjustmentSettings] = []
        all.append(adjDevelop { $0.exposure = 1e-6 })
        all.append(adjDevelop { $0.contrast = 1e-4; $0.shadows = 1e-4; $0.vibrance = 1e-4; $0.temperature = 1e-4 })
        var curve = AdjustmentSettings(kind: .toneCurve)
        curve.curves.master = ResponseCurve(points: [SIMD2(0, 0), SIMD2(0.5, 0.5002), SIMD2(1, 1)])
        curve.curves.luminance = ResponseCurve(points: [SIMD2(0, 0), SIMD2(0.5, 0.5002), SIMD2(1, 1)])
        all.append(curve)
        var hsl = AdjustmentSettings(kind: .hsl)
        hsl.hsl.hue[0] = 0.001; hsl.hsl.saturation[3] = 0.001; hsl.hsl.luminance[5] = 0.001
        all.append(hsl)
        var grading = AdjustmentSettings(kind: .colorGrading)
        grading.grading.shadows.saturation = 0.001; grading.grading.global.luminance = 0.001
        all.append(grading)
        var selective = AdjustmentSettings(kind: .selectiveColor)
        selective.selectiveColor.ranges[0].cyan = 0.001
        all.append(selective)
        for s in all {
            let (input, output) = try h.run(s, image, w, ht)
            #expect(adjMaxDiff(output, input) < 4e-3, "\(s.kind) drifted: \(adjMaxDiff(output, input))")
        }
    }

    @Test func alphaIsAlwaysPreserved() throws {
        let h = try AdjHarness()
        let w = 48, ht = 36
        let image = adjVariedImage(w, ht)
        var all: [AdjustmentSettings] = []
        all.append(adjDevelop { d in
            d.exposure = 0.7; d.contrast = 40; d.highlights = -60; d.shadows = 50; d.whites = 20; d.blacks = -30
            d.temperature = 30; d.tint = -20; d.vibrance = 50; d.saturation = 20; d.clarity = 70; d.dehaze = 50
        })
        all.append(adjDevelop { $0.dehaze = -80; $0.clarity = -60 })
        var curve = AdjustmentSettings(kind: .toneCurve)
        curve.curves.master = ResponseCurve(points: [SIMD2(0, 0.1), SIMD2(0.5, 0.4), SIMD2(1, 0.9)])
        curve.curves.red = ResponseCurve(points: [SIMD2(0, 0), SIMD2(0.5, 0.6), SIMD2(1, 1)])
        curve.curves.luminance = ResponseCurve(points: [SIMD2(0, 0.05), SIMD2(0.5, 0.6), SIMD2(1, 1)])
        all.append(curve)
        var hsl = AdjustmentSettings(kind: .hsl)
        hsl.hsl.hue = [30, -50, 20, 0, 40, 0, -100, 60]
        hsl.hsl.saturation = [-100, 50, 0, 60, 0, -30, 100, 0]
        hsl.hsl.luminance = [20, -40, 100, 0, -100, 30, 0, 50]
        all.append(hsl)
        var grading = AdjustmentSettings(kind: .colorGrading)
        grading.grading.shadows = ColorWheel(hue: 220, saturation: 60, luminance: 20)
        grading.grading.midtones = ColorWheel(hue: 40, saturation: 30, luminance: -30)
        grading.grading.highlights = ColorWheel(hue: 50, saturation: 80, luminance: 40)
        grading.grading.global = ColorWheel(hue: 0, saturation: 10, luminance: 10)
        all.append(grading)
        var selective = AdjustmentSettings(kind: .selectiveColor)
        for i in 0..<9 { selective.selectiveColor.ranges[i] = {
            var a = CMYKAdjustment(); a.cyan = Float(i * 10 - 40); a.magenta = Float(30 - i * 5); a.yellow = 20; a.black = Float(i * 3 - 12); return a }() }
        all.append(selective)
        all.append(AdjustmentSettings(kind: .gradientMap))
        for s in all {
            let (input, output) = try h.run(s, image, w, ht)
            #expect(adjIsFinite(output))
            for (i, o) in zip(input, output).enumerated() {
                #expect(o.1.w == o.0.w, "\(s.kind) pixel \(i): alpha \(o.0.w) -> \(o.1.w)")
                if o.0.w == 0 { #expect(o.1 == o.0) }
            }
        }
    }

    // MARK: develop

    @Test func plusOneEVDoublesLinearLight() throws {
        let h = try AdjHarness()
        let colors: [SIMD3<Float>] = [[0.1, 0.1, 0.1], [0.3, 0.3, 0.3], [0.5, 0.2, 0.7], [0.62, 0.62, 0.62]]
        for ev: Float in [1, -1, 0.5] {
            let out = try h.colors(adjDevelop { $0.exposure = ev }, colors)
            for (c, o) in zip(colors, out) {
                for k in 0..<3 {
                    let expected = adjL2S(adjS2L(c[k]) * pow(2, ev))
                    #expect(abs(o[k] - expected) < 2e-3, "EV \(ev): \(c[k]) -> \(o[k]), expected \(expected)")
                }
            }
        }
        // Linear light doubles exactly where it matters: 0.3 sRGB -> 2 x linear.
        let doubled = try h.colors(adjDevelop { $0.exposure = 1 }, [[0.3, 0.3, 0.3]])[0]
        #expect(abs(adjS2L(doubled.x) / adjS2L(0.3) - 2) < 0.02)
    }

    @Test func exposureKeepsHighlightsAboveOne() throws {
        let h = try AdjHarness()
        let out = try h.colors(adjDevelop { $0.exposure = 1 }, [[1.2, 1.2, 1.2]])[0]
        #expect(abs(out.x - adjL2S(adjS2L(1.2) * 2)) < 4e-3)
        #expect(out.x > 1.2)
    }

    @Test func temperatureAndTintMoveWhiteInTheExpectedDirections() throws {
        let h = try AdjHarness()
        let grey: [SIMD3<Float>] = [[0.5, 0.5, 0.5]]
        let warm = try h.colors(adjDevelop { $0.temperature = 60 }, grey)[0]
        let cool = try h.colors(adjDevelop { $0.temperature = -60 }, grey)[0]
        #expect(warm.x > 0.5 && warm.z < 0.5 && warm.x > warm.z)
        #expect(cool.z > 0.5 && cool.x < 0.5 && cool.z > cool.x)
        let magenta = try h.colors(adjDevelop { $0.tint = 60 }, grey)[0]
        let green = try h.colors(adjDevelop { $0.tint = -60 }, grey)[0]
        #expect(magenta.y < magenta.x && magenta.y < magenta.z)
        #expect(green.y > green.x && green.y > green.z)
        // White balance keeps the luminance of white roughly where it was.
        let white = try h.colors(adjDevelop { $0.temperature = 100 }, [[1, 1, 1]])[0]
        #expect(abs(simd_dot(white, adjLumaP3) - 1) < 0.08)
    }

    @Test func contrastIsMonotoneAndPivotsAroundMidGrey() throws {
        let h = try AdjHarness()
        let ramp = (0...20).map { SIMD3<Float>(repeating: Float($0) / 20) }
        for c: Float in [100, 50, -50, -100] {
            let out = try h.colors(adjDevelop { $0.contrast = c }, ramp).map { $0.x }
            for i in 1..<out.count { #expect(out[i] >= out[i - 1] - 1e-3, "contrast \(c) not monotone at \(i)") }
            if c > 0 {
                #expect(out[4] < ramp[4].x - 0.01)     // darks get darker
                #expect(out[16] > ramp[16].x + 0.01)   // lights get lighter
            } else {
                #expect(out[4] > ramp[4].x + 0.01)
                #expect(out[16] < ramp[16].x - 0.01)
            }
        }
        let pivot = try h.colors(adjDevelop { $0.contrast = 100 }, [[0.46, 0.46, 0.46]])[0]
        #expect(abs(pivot.x - 0.46) < 3e-3)
    }

    @Test func toneControlsActOnTheirOwnRangesAndKeepHue() throws {
        let h = try AdjHarness()
        let dark: SIMD3<Float> = [0.12, 0.08, 0.06], light: SIMD3<Float> = [0.9, 0.8, 0.7]
        let hueOf: (SIMD3<Float>) -> Float = { ($0.x - $0.z) / max($0.x, 1e-3) }     // crude hue/chroma signature

        let shadowsUp = try h.colors(adjDevelop { $0.shadows = 100 }, [dark, light])
        #expect(simd_dot(shadowsUp[0], adjLumaP3) > simd_dot(dark, adjLumaP3) * 1.3)
        #expect(abs(simd_dot(shadowsUp[1], adjLumaP3) - simd_dot(light, adjLumaP3)) < 0.03)
        #expect(abs(hueOf(shadowsUp[0]) - hueOf(dark)) < 0.02)

        let highlightsDown = try h.colors(adjDevelop { $0.highlights = -100 }, [dark, light])
        #expect(simd_dot(highlightsDown[1], adjLumaP3) < simd_dot(light, adjLumaP3) * 0.85)
        #expect(abs(simd_dot(highlightsDown[0], adjLumaP3) - simd_dot(dark, adjLumaP3)) < 0.01)
        #expect(abs(hueOf(highlightsDown[1]) - hueOf(light)) < 0.02)

        let blacksDown = try h.colors(adjDevelop { $0.blacks = -100 }, [[0.05, 0.05, 0.05], [0.7, 0.7, 0.7]])
        #expect(blacksDown[0].x < 0.01)
        #expect(abs(blacksDown[1].x - 0.7) < 0.02)
        let blacksUp = try h.colors(adjDevelop { $0.blacks = 100 }, [[0, 0, 0]])
        #expect(blacksUp[0].x > 0.05)

        let whitesUp = try h.colors(adjDevelop { $0.whites = 100 }, [[0.8, 0.8, 0.8], [0.3, 0.3, 0.3]])
        #expect(whitesUp[0].x > 0.82)
        #expect(abs(whitesUp[1].x - 0.3) < 0.01)
    }

    @Test func saturationAndVibrance() throws {
        let h = try AdjHarness()
        let c: SIMD3<Float> = [0.7, 0.4, 0.3]
        let grey = try h.colors(adjDevelop { $0.saturation = -100 }, [c])[0]
        let l = simd_dot(c, adjLumaP3)
        #expect(abs(grey.x - l) < 2e-3 && abs(grey.y - l) < 2e-3 && abs(grey.z - l) < 2e-3)
        let chroma: (SIMD3<Float>) -> Float = { simd_reduce_max($0) - simd_reduce_min($0) }
        let boosted = try h.colors(adjDevelop { $0.saturation = 50 }, [c])[0]
        #expect(chroma(boosted) > chroma(c) * 1.3)

        // Vibrance lifts muted colours much more than saturated ones, and spares skin tones.
        let muted: SIMD3<Float> = [0.45, 0.5, 0.55]          // bluish, low saturation
        let vivid: SIMD3<Float> = [0.1, 0.3, 0.95]
        let skin: SIMD3<Float> = [0.8, 0.62, 0.5]
        let skinMuted: SIMD3<Float> = [0.55, 0.5, 0.45]
        let bluishMuted: SIMD3<Float> = [0.45, 0.5, 0.55]
        let out = try h.colors(adjDevelop { $0.vibrance = 100 }, [muted, vivid, skin, skinMuted, bluishMuted])
        let gain: (Int, SIMD3<Float>) -> Float = { chroma(out[$0]) / max(chroma($1), 1e-4) }
        #expect(gain(0, muted) > 1.5)
        #expect(gain(1, vivid) < 1.15)
        #expect(gain(3, skinMuted) < gain(4, bluishMuted))
        _ = skin
    }

    // MARK: tone curve

    @Test func toneCurveLookupTableMatchesResponseCurve() throws {
        let h = try AdjHarness()
        let curve = ResponseCurve(points: [SIMD2(0, 0.05), SIMD2(0.25, 0.4), SIMD2(0.6, 0.55), SIMD2(1, 0.95)])
        var s = AdjustmentSettings(kind: .toneCurve)
        s.curves.master = curve
        let xs = (0...50).map { Float($0) / 50 }
        let out = try h.colors(s, xs.map { SIMD3(repeating: $0) })
        for (x, o) in zip(xs, out) {
            let expected = curve.value(at: x)
            #expect(abs(o.x - expected) < 2e-3 && abs(o.y - expected) < 2e-3 && abs(o.z - expected) < 2e-3,
                    "x \(x): got \(o), expected \(expected)")
        }
    }

    @Test func perChannelAndLuminanceCurves() throws {
        let h = try AdjHarness()
        let lift = ResponseCurve(points: [SIMD2(0, 0), SIMD2(0.5, 0.7), SIMD2(1, 1)])
        var red = AdjustmentSettings(kind: .toneCurve)
        red.curves.red = lift
        let c = try h.colors(red, [[0.5, 0.5, 0.5]])[0]
        #expect(abs(c.x - 0.7) < 3e-3 && abs(c.y - 0.5) < 2e-3 && abs(c.z - 0.5) < 2e-3)

        // master then channel: red(master(x))
        var both = AdjustmentSettings(kind: .toneCurve)
        let master = ResponseCurve(points: [SIMD2(0, 0), SIMD2(0.5, 0.3), SIMD2(1, 1)])
        both.curves.master = master
        both.curves.red = lift
        let b = try h.colors(both, [[0.5, 0.5, 0.5]])[0]
        #expect(abs(b.x - lift.value(at: master.value(at: 0.5))) < 4e-3)
        #expect(abs(b.y - master.value(at: 0.5)) < 3e-3)

        // luminance curve moves brightness but keeps the hue of a colour
        var lum = AdjustmentSettings(kind: .toneCurve)
        lum.curves.luminance = ResponseCurve(points: [SIMD2(0, 0), SIMD2(0.4, 0.2), SIMD2(1, 1)])
        let colour: SIMD3<Float> = [0.5, 0.35, 0.2]
        let l = try h.colors(lum, [colour])[0]
        #expect(simd_dot(l, adjLumaP3) < simd_dot(colour, adjLumaP3) - 0.03)
        #expect(abs(l.x / l.z - colour.x / colour.z) < 0.03)
        #expect(abs(l.y / l.z - colour.y / colour.z) < 0.03)
        // and on grey it matches the curve
        let g = try h.colors(lum, [[0.4, 0.4, 0.4]])[0]
        #expect(abs(g.x - 0.2) < 3e-3)
    }

    @Test func toneCurveExtendsLinearlyAboveOne() throws {
        let h = try AdjHarness()
        var s = AdjustmentSettings(kind: .toneCurve)
        s.curves.master = ResponseCurve(points: [SIMD2(0, 0), SIMD2(0.5, 0.4), SIMD2(1, 0.8)])
        let o = try h.colors(s, [[1.5, 1.5, 1.5]])[0]
        // end slope of this curve is (0.8 - 0.4) / 0.5 = 0.8, so f(1.5) = 0.8 + 0.5 * 0.8 = 1.2
        #expect(abs(o.x - 1.2) < 0.02)
    }

    @Test func curveCacheFollowsSettingsChanges() throws {
        let h = try AdjHarness()
        var a = AdjustmentSettings(kind: .toneCurve)
        a.curves.master = ResponseCurve(points: [SIMD2(0, 0), SIMD2(0.5, 0.8), SIMD2(1, 1)])
        var b = a
        b.curves.master = ResponseCurve(points: [SIMD2(0, 0), SIMD2(0.5, 0.2), SIMD2(1, 1)])
        let grey: [SIMD3<Float>] = [[0.5, 0.5, 0.5]]
        let first = try h.colors(a, grey)[0].x
        let second = try h.colors(b, grey)[0].x
        let third = try h.colors(a, grey)[0].x
        #expect(abs(first - 0.8) < 3e-3 && abs(second - 0.2) < 3e-3 && first == third)
    }

    // MARK: HSL

    @Test func hslRedSaturationMinus100GreysOutRedButNotBlue() throws {
        let h = try AdjHarness()
        var s = AdjustmentSettings(kind: .hsl)
        s.hsl.saturation[HueBand.red.rawValue] = -100
        let out = try h.colors(s, [[1, 0, 0], [0, 0, 1], [0.5, 0.5, 0.5]])
        let redLuma = adjLumaP3.x
        #expect(abs(out[0].x - redLuma) < 3e-3 && abs(out[0].y - redLuma) < 3e-3 && abs(out[0].z - redLuma) < 3e-3)
        #expect(adjMaxDiff([adjPx(out[1].x, out[1].y, out[1].z)], [adjPx(0, 0, 1)]) < 2e-3)
        #expect(abs(out[2].x - 0.5) < 2e-3)
    }

    @Test func hslBandsBlendWithoutSeams() throws {
        let h = try AdjHarness()
        var s = AdjustmentSettings(kind: .hsl)
        s.hsl.hue = [60, -40, 80, -70, 50, -90, 100, -60]
        s.hsl.saturation = [50, -60, 70, -30, 90, -80, 40, 60]
        s.hsl.luminance = [-40, 60, -70, 30, -50, 80, -20, 40]
        // Sweep the hue circle in 0.25 degree steps with a fixed, saturated colour.
        let steps = 1440
        let colours: [SIMD3<Float>] = (0..<steps).map { i in
            let hue = Float(i) / Float(steps)
            func ch(_ n: Float) -> Float { max(0, min(1, abs((hue * 6 + n).truncatingRemainder(dividingBy: 6) - 3) - 1)) }
            return SIMD3(0.2 + 0.6 * ch(0), 0.2 + 0.6 * ch(4), 0.2 + 0.6 * ch(2))
        }
        let out = try h.colors(s, colours)
        var biggest: Float = 0
        for i in 0..<steps {
            let a = out[i], b = out[(i + 1) % steps]
            biggest = max(biggest, simd_length(a - b))
        }
        let inputStep = zip(colours, colours.dropFirst()).map { simd_length($0 - $1) }.max()!
        // A seam would show up as a jump far larger than the input's own step (times the adjustment's gain).
        #expect(biggest < inputStep * 12 + 0.02, "largest jump \(biggest), input step \(inputStep)")
        #expect(adjIsFinite(out.map { adjPx($0.x, $0.y, $0.z) }))
    }

    @Test func hslHueShiftRotatesAtConstantLuminance() throws {
        let h = try AdjHarness()
        var s = AdjustmentSettings(kind: .hsl)
        s.hsl.hue[HueBand.red.rawValue] = 100
        let c: SIMD3<Float> = [0.9, 0.2, 0.2]
        let o = try h.colors(s, [c])[0]
        #expect(o.y > c.y + 0.07)                                            // moved toward orange
        #expect(abs(simd_dot(o, adjLumaP3) - simd_dot(c, adjLumaP3)) < 4e-3)       // same luminance
    }

    // MARK: colour grading

    @Test func shadowsWheelTintsDarksNotLights() throws {
        let h = try AdjHarness()
        var s = AdjustmentSettings(kind: .colorGrading)
        s.grading.shadows = ColorWheel(hue: 0, saturation: 100, luminance: 0)
        let out = try h.colors(s, [[0.05, 0.05, 0.05], [0.95, 0.95, 0.95], [0.5, 0.5, 0.5]])
        #expect(out[0].x - out[0].y > 0.04)
        #expect(abs(out[1].x - out[1].y) < 0.01)
        #expect(out[2].x - out[2].y < out[0].x - out[0].y)
    }

    @Test func gradingLuminanceControlsMoveTheirRanges() throws {
        let h = try AdjHarness()
        var s = AdjustmentSettings(kind: .colorGrading)
        s.grading.highlights.luminance = 100
        let out = try h.colors(s, [[0.1, 0.1, 0.1], [0.8, 0.8, 0.8]])
        #expect(abs(out[0].x - 0.1) < 3e-3)
        #expect(out[1].x > 0.85)
        var lift = AdjustmentSettings(kind: .colorGrading)
        lift.grading.shadows.luminance = 100
        let l = try h.colors(lift, [[0.1, 0.1, 0.1], [0.9, 0.9, 0.9]])
        #expect(l[0].x > 0.2)
        #expect(abs(l[1].x - 0.9) < 3e-3)
    }

    // MARK: gradient map

    @Test func gradientMapSendsBlackToFirstStopAndWhiteToLast() throws {
        let h = try AdjHarness()
        var s = AdjustmentSettings(kind: .gradientMap)
        let first = SIMD4<Float>(0.1, 0.2, 0.6, 1), last = SIMD4<Float>(1, 0.9, 0.3, 1)
        s.gradientMap.stops = [GradientStop(location: 0, color: first), GradientStop(location: 1, color: last)]
        let out = try h.colors(s, [[0, 0, 0], [1, 1, 1]])
        for k in 0..<3 {
            #expect(abs(out[0][k] - first[k]) < 1.5e-3)
            #expect(abs(out[1][k] - last[k]) < 1.5e-3)
        }
        s.gradientMap.reversed = true
        let rev = try h.colors(s, [[0, 0, 0], [1, 1, 1]])
        for k in 0..<3 {
            #expect(abs(rev[0][k] - last[k]) < 1.5e-3)
            #expect(abs(rev[1][k] - first[k]) < 1.5e-3)
        }
    }

    @Test func gradientMapInterpolatesStopsAndMultipliesAlpha() throws {
        let h = try AdjHarness()
        var s = AdjustmentSettings(kind: .gradientMap)
        s.gradientMap.stops = [GradientStop(location: 0, color: SIMD4(0, 0, 0, 1)),
                               GradientStop(location: 0.5, color: SIMD4(1, 0, 0, 0.5)),
                               GradientStop(location: 1, color: SIMD4(1, 1, 1, 1))]
        // Mid grey in P3 has luma 0.5 -> exactly the middle stop (red, alpha 0.5)
        let pixels = [adjPx(0.5, 0.5, 0.5, a: 0.8)]
        let (_, out) = try h.run(s, pixels, 1, 1)
        #expect(abs(out[0].w - 0.4) < 2e-3)                  // 0.8 x 0.5
        #expect(abs(out[0].x - 0.4) < 3e-3 && abs(out[0].y) < 2e-3)   // premultiplied red
        // Unsorted stops are sorted
        s.gradientMap.stops.reverse()
        let (_, again) = try h.run(s, pixels, 1, 1)
        #expect(adjMaxDiff(again, out) < 1e-3)
    }

    // MARK: selective colour

    @Test func selectiveColorOnNeutralsDoesNotTouchSaturatedRed() throws {
        let h = try AdjHarness()
        var s = AdjustmentSettings(kind: .selectiveColor)
        s.selectiveColor.ranges[SelectiveColorRange.neutrals.rawValue].cyan = 100
        s.selectiveColor.ranges[SelectiveColorRange.neutrals.rawValue].black = 50
        s.selectiveColor.relative = false
        let out = try h.colors(s, [[1, 0, 0], [0.5, 0.5, 0.5], [0, 0, 1]])
        #expect(abs(out[0].x - 1) < 1.5e-3 && abs(out[0].y) < 1.5e-3 && abs(out[0].z) < 1.5e-3)
        #expect(abs(out[2].z - 1) < 1.5e-3 && abs(out[2].x) < 1.5e-3)
        #expect(out[1].x < 0.45)           // the neutral grey did change
    }

    @Test func selectiveColorRelativeAndAbsoluteBlackOnMidGrey() throws {
        let h = try AdjHarness()
        var s = AdjustmentSettings(kind: .selectiveColor)
        s.selectiveColor.ranges[SelectiveColorRange.neutrals.rawValue].black = 50
        s.selectiveColor.relative = true
        // K = 0.5; relative +50 % of the existing 50 % -> 75 % -> grey 0.25
        #expect(abs(try h.colors(s, [[0.5, 0.5, 0.5]])[0].x - 0.25) < 2e-3)
        s.selectiveColor.relative = false
        // absolute +50 points -> K = 1.0 -> black
        #expect(abs(try h.colors(s, [[0.5, 0.5, 0.5]])[0].x) < 2e-3)
        s.selectiveColor.ranges[SelectiveColorRange.neutrals.rawValue].black = 20
        #expect(abs(try h.colors(s, [[0.5, 0.5, 0.5]])[0].x - 0.3) < 2e-3)
    }

    @Test func selectiveColorRangesSelectTheRightColours() throws {
        let h = try AdjHarness()
        let primaries: [(SelectiveColorRange, SIMD3<Float>)] = [
            (.reds, [1, 0, 0]), (.yellows, [1, 1, 0]), (.greens, [0, 1, 0]),
            (.cyans, [0, 1, 1]), (.blues, [0, 0, 1]), (.magentas, [1, 0, 1]),
        ]
        for (target, _) in primaries {
            var s = AdjustmentSettings(kind: .selectiveColor)
            s.selectiveColor.relative = false
            s.selectiveColor.ranges[target.rawValue].black = 60        // darken only this range
            let out = try h.colors(s, primaries.map { $0.1 })
            for (i, (range, colour)) in primaries.enumerated() {
                if range == target {
                    #expect(simd_reduce_max(out[i]) < 0.5, "\(range) should have darkened, got \(out[i])")
                } else {
                    #expect(simd_length(out[i] - colour) < 3e-3, "\(range) should be untouched by \(target), got \(out[i])")
                }
            }
        }
        // Whites and blacks
        var w = AdjustmentSettings(kind: .selectiveColor)
        w.selectiveColor.relative = false
        w.selectiveColor.ranges[SelectiveColorRange.whites.rawValue].black = 30
        let out = try h.colors(w, [[1, 1, 1], [0, 0, 0], [1, 0, 0]])
        #expect(abs(out[0].x - 0.7) < 3e-3)
        #expect(out[1].x < 3e-3)
        #expect(abs(out[2].x - 1) < 3e-3)
    }

    // MARK: neighbourhood-dependent adjustments

    @Test func neighborhoodRadiusIsZeroForPerPixelAdjustments() {
        for kind in AdjustmentKind.allCases where kind != .develop {
            #expect(AdjustmentPipeline.neighborhoodRadius(for: AdjustmentSettings(kind: kind), canvasWidth: 4000, canvasHeight: 3000) == 0)
        }
        #expect(AdjustmentPipeline.neighborhoodRadius(for: adjDevelop { $0.exposure = 1; $0.contrast = 30 },
                                                      canvasWidth: 4000, canvasHeight: 3000) == 0)
        let clarity = AdjustmentPipeline.neighborhoodRadius(for: adjDevelop { $0.clarity = 50 }, canvasWidth: 4000, canvasHeight: 3000)
        #expect(clarity > 20 && clarity < 1500)
        let dehaze = AdjustmentPipeline.neighborhoodRadius(for: adjDevelop { $0.dehaze = -50 }, canvasWidth: 4000, canvasHeight: 3000)
        #expect(dehaze >= 4000)
    }

    @Test func clarityAndDehazeProduceFiniteImagesAtEveryScale() throws {
        let h = try AdjHarness()
        for (w, ht) in [(33, 21), (96, 64), (420, 300), (900, 520), (1700, 900)] {
            let image = adjVariedImage(w, ht)
            for edit: (inout DevelopSettings) -> Void in [
                { $0.clarity = 100 }, { $0.clarity = -100 }, { $0.dehaze = 100 }, { $0.dehaze = -100 },
                { $0.clarity = 80; $0.dehaze = 80; $0.exposure = 1; $0.contrast = 50 },
            ] {
                let (_, out) = try h.run(adjDevelop(edit), image, w, ht)
                #expect(adjIsFinite(out), "non-finite output at \(w)x\(ht)")
                #expect(out.allSatisfy { simd_reduce_max(simd_abs($0)) < 1000 })
            }
        }
    }

    @Test func clarityBoostsLocalContrast() throws {
        let h = try AdjHarness()
        let w = 128, ht = 96
        // A fine checkerboard of +-0.04 around a smooth ramp.
        var image: [SIMD4<Float>] = []
        for y in 0..<ht {
            for x in 0..<w {
                let base = 0.35 + 0.3 * Float(x) / Float(w)
                let v = base + (((x / 4) + (y / 4)) % 2 == 0 ? 0.04 : -0.04)
                image.append(adjPx(v, v, v))
            }
        }
        func contrast(_ p: [SIMD4<Float>]) -> Float {
            var sum: Float = 0
            for y in 8..<(ht - 8) { for x in 8..<(w - 8) { sum += abs(p[y * w + x].x - p[y * w + x + 4].x) } }
            return sum
        }
        let (input, up) = try h.run(adjDevelop { $0.clarity = 100 }, image, w, ht)
        let (_, down) = try h.run(adjDevelop { $0.clarity = -100 }, image, w, ht)
        #expect(contrast(up) > contrast(input) * 1.5)
        #expect(contrast(down) < contrast(input) * 0.6)
    }

    @Test func dehazeRestoresContrastToAHazyScene() throws {
        let h = try AdjHarness()
        let w = 160, ht = 120
        var rng = AdjTestRandom(99)
        // Blocky scene J, then I = J t + A (1 - t) with t = 0.45 and a bright bluish-white atmosphere.
        let air = SIMD3<Float>(0.92, 0.94, 1.0)
        var blocks: [SIMD3<Float>] = []
        for _ in 0..<((w / 16 + 1) * (ht / 16 + 1)) {
            blocks.append(SIMD3(0.7 * rng.next(), 0.7 * rng.next(), 0.7 * rng.next()))
        }
        var image: [SIMD4<Float>] = []
        for y in 0..<ht {
            for x in 0..<w {
                let j = blocks[(y / 16) * (w / 16 + 1) + x / 16]
                let i = j * 0.45 + air * 0.55
                image.append(adjPx(i.x, i.y, i.z))
            }
        }
        func spread(_ p: [SIMD4<Float>]) -> Float {
            let l = p.map { simd_dot(SIMD3($0.x, $0.y, $0.z), adjLumaP3) }
            let mean = l.reduce(0, +) / Float(l.count)
            return (l.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(l.count)).squareRoot()
        }
        let (input, out) = try h.run(adjDevelop { $0.dehaze = 100 }, image, w, ht)
        #expect(spread(out) > spread(input) * 1.6, "dehaze should widen the tonal spread: \(spread(input)) -> \(spread(out))")
        let minIn = input.map { $0.x }.min()!, minOut = out.map { $0.x }.min()!
        #expect(minOut < minIn - 0.05)
        // Adding haze does the opposite.
        let (_, hazy) = try h.run(adjDevelop { $0.dehaze = -100 }, image, w, ht)
        #expect(spread(hazy) < spread(input) * 0.85)
    }

    @Test func partialRegionsMatchTheFullRenderIncludingBlurHalos() throws {
        let h = try AdjHarness()
        for (w, ht) in [(220, 160), (1000, 640), (1650, 900)] {
            let image = adjVariedImage(w, ht)
            let s = adjDevelop { d in d.clarity = 80; d.dehaze = 60; d.exposure = 0.4; d.contrast = 20; d.vibrance = 30; d.temperature = 15 }
            let full = try h.run(s, image, w, ht).output
            let region = IntRect(x: w / 3, y: ht / 4, width: w / 4, height: ht / 3)
            let part = try h.run(s, image, w, ht, region: region).output
            var worst: Float = 0
            for y in region.y..<region.maxY {
                for x in region.x..<region.maxX {
                    let a = full[y * w + x], b = part[y * w + x]
                    worst = max(worst, simd_reduce_max(simd_abs(a - b)) / max(1, simd_reduce_max(simd_abs(a))))
                }
            }
            #expect(worst < 3e-3, "\(w)x\(ht): region render differs from full render by \(worst)")
            // Outside the region nothing is written (the harness clears the destination first).
            let outsideTouched = (0..<(w * ht)).contains { i in
                let x = i % w, y = i / w
                return !(x >= region.x && x < region.maxX && y >= region.y && y < region.maxY) && part[i] != .zero
            }
            #expect(!outsideTouched)
        }
    }

    // MARK: robustness

    @Test func regionsAreClampedAndBadTexturesRejected() throws {
        let h = try AdjHarness()
        let image = adjVariedImage(20, 20)
        let (_, out) = try h.run(adjDevelop { $0.exposure = 1 }, image, 20, 20, region: IntRect(x: -10, y: 10, width: 100, height: 100))
        #expect(adjIsFinite(out))
        let src = try h.texture(image, 20, 20)
        #expect(throws: (any Error).self) {
            try h.gpu.run("same") { cb in
                try h.pipeline.encode(adjDevelop { $0.exposure = 1 }, source: src, destination: src,
                                      region: IntRect(x: 0, y: 0, width: 20, height: 20), commandBuffer: cb)
            }
        }
        let small = try h.gpu.makeTexture(width: 10, height: 10, label: "small")
        #expect(throws: (any Error).self) {
            try h.gpu.run("size") { cb in
                try h.pipeline.encode(adjDevelop { $0.exposure = 1 }, source: src, destination: small,
                                      region: IntRect(x: 0, y: 0, width: 10, height: 10), commandBuffer: cb)
            }
        }
        // Empty region is a no-op.
        let (_, none) = try h.run(adjDevelop { $0.exposure = 1 }, image, 20, 20, region: .empty)
        #expect(none.allSatisfy { $0 == .zero })
    }

    @Test func repeatedEncodingIsDeterministic() throws {
        let h = try AdjHarness()
        let image = adjVariedImage(300, 200)
        let s = adjDevelop { $0.clarity = 50; $0.dehaze = 40; $0.exposure = 0.2 }
        let a = try h.run(s, image, 300, 200).output
        let b = try h.run(s, image, 300, 200).output
        #expect(a == b)
    }
}

// MARK: - Photo import / export

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

private func adjTempFile(_ ext: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("paper-test-\(UUID().uuidString).\(ext)")
}

/// A smooth picture whose values are NOT representable in 8 bits, with a few alpha levels.
private func adjSmoothPhoto(_ w: Int, _ h: Int, alphas: [Float] = [1, 0.5, 0.25]) -> PhotoImage {
    var pixels: [SIMD4<Float>] = []
    for y in 0..<h {
        for x in 0..<w {
            let u = Float(x) / Float(w - 1), v = Float(y) / Float(h - 1)
            let a = alphas[(y * 3 / h) % alphas.count]
            let c = SIMD3<Float>(0.05 + 0.9 * u, 0.1 + 0.8 * v, 0.9 - 0.7 * u * v + 0.00037)
            pixels.append(SIMD4(c * a, a))
        }
    }
    return PhotoImage(width: w, height: h, pixels: pixels)
}

private func adjProperties(of url: URL) -> [CFString: Any] {
    guard let s = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
    return (CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any]) ?? [:]
}

private func adjWorstStraightError(_ a: PhotoImage, _ b: PhotoImage) -> Float {
    var worst: Float = 0
    for (p, q) in zip(a.pixels, b.pixels) {
        worst = max(worst, abs(p.w - q.w))
        if p.w > 0.2 { worst = max(worst, simd_reduce_max(simd_abs(SIMD3(p.x, p.y, p.z) / p.w - SIMD3(q.x, q.y, q.z) / max(q.w, 1e-6)))) }
    }
    return worst
}

@Suite struct PhotoIOTests {
    @Test func sixteenBitPNGRoundTripKeepsPrecisionAndAlpha() throws {
        let photo = adjSmoothPhoto(64, 48)
        let url = adjTempFile("png")
        defer { try? FileManager.default.removeItem(at: url) }
        try PhotoExporter.write(photo, to: url, format: .png16)
        #expect(adjProperties(of: url)[kCGImagePropertyDepth] as? Int == 16)
        #expect(adjProperties(of: url)[kCGImagePropertyHasAlpha] as? Bool == true)
        let back = try PhotoImporter.load(url)
        #expect(back.width == 64 && back.height == 48)
        #expect(adjWorstStraightError(photo, back) < 6e-4, "16-bit PNG error \(adjWorstStraightError(photo, back))")
        // The same bytes through load(data:)
        let again = try PhotoImporter.load(data: Data(contentsOf: url))
        #expect(again == back)
    }

    @Test func eightBitPNGAndTIFFRoundTrips() throws {
        let photo = adjSmoothPhoto(40, 30)
        let png = adjTempFile("png"), tiff = adjTempFile("tiff")
        defer { try? FileManager.default.removeItem(at: png); try? FileManager.default.removeItem(at: tiff) }
        try PhotoExporter.write(photo, to: png, format: .png8)
        #expect(adjProperties(of: png)[kCGImagePropertyDepth] as? Int == 8)
        #expect(adjWorstStraightError(photo, try PhotoImporter.load(png)) < 0.5 / 255 + 6e-3)    // 8-bit steps; low alpha amplifies

        try PhotoExporter.write(photo, to: tiff, format: .tiff16)
        #expect(adjProperties(of: tiff)[kCGImagePropertyDepth] as? Int == 16)
        #expect(adjWorstStraightError(photo, try PhotoImporter.load(tiff)) < 6e-4)
    }

    @Test func jpegRoundTripDropsAlphaOntoWhite() throws {
        // Smooth, opaque picture: JPEG should be close.
        let photo = adjSmoothPhoto(64, 48, alphas: [1])
        let url = adjTempFile("jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try PhotoExporter.write(photo, to: url, format: .jpeg(quality: 0.95))
        #expect(adjProperties(of: url)[kCGImagePropertyHasAlpha] as? Bool != true)
        let back = try PhotoImporter.load(url)
        #expect(adjWorstStraightError(photo, back) < 0.03)

        // Half-transparent grey composites on white: 0.5 grey at alpha 0.5 -> 0.75
        let half = PhotoImage(width: 16, height: 16, pixels: Array(repeating: SIMD4(0.25, 0.25, 0.25, 0.5), count: 256))
        let flat = adjTempFile("jpg")
        defer { try? FileManager.default.removeItem(at: flat) }
        try PhotoExporter.write(half, to: flat, format: .jpeg(quality: 1))
        let flatBack = try PhotoImporter.load(flat)
        let mid = flatBack.pixels[8 * 16 + 8]
        #expect(abs(mid.w - 1) < 1e-3 && abs(mid.x - 0.75) < 0.02)
    }

    @Test func heicRoundTripIsClose() throws {
        let photo = adjSmoothPhoto(64, 48, alphas: [1])
        let url = adjTempFile("heic")
        defer { try? FileManager.default.removeItem(at: url) }
        do { try PhotoExporter.write(photo, to: url, format: .heic(quality: 0.95)) } catch {
            // Some machines have no HEIC encoder; that is not a failure of the exporter.
            return
        }
        let back = try PhotoImporter.load(url)
        #expect(back.width == 64 && back.height == 48)
        #expect(adjWorstStraightError(photo, back) < 0.06)
    }

    @Test func importConvertsIntoDisplayP3() throws {
        // A pure sRGB red pixel is (0.9175, 0.2003, 0.1386) in Display P3.
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: srgb, components: [1, 0, 0, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(dest))
        let photo = try PhotoImporter.load(data: data as Data)
        let p = photo.pixels[5]
        #expect(abs(p.x - 0.9175) < 0.01 && abs(p.y - 0.2003) < 0.012 && abs(p.z - 0.1386) < 0.012 && p.w == 1)
    }

    @Test func importAppliesExifOrientationAndMaxDimension() throws {
        // 4 x 2 grid of 8 px blocks, each a different colour; JPEG stores it with every EXIF orientation.
        let colours: [[SIMD3<Float>]] = [
            [[0.9, 0.1, 0.1], [0.1, 0.8, 0.1], [0.1, 0.1, 0.9], [0.9, 0.9, 0.1]],
            [[0.9, 0.1, 0.9], [0.1, 0.9, 0.9], [0.5, 0.5, 0.5], [0.95, 0.5, 0.1]],
        ]
        let bw = 4, bh = 2, block = 8
        var pixels: [SIMD4<Float>] = []
        for y in 0..<(bh * block) { for x in 0..<(bw * block) {
            let c = colours[y / block][x / block]; pixels.append(SIMD4(c.x, c.y, c.z, 1))
        } }
        let stored = PhotoImage(width: bw * block, height: bh * block, pixels: pixels)
        let cg = PhotoExporter.cgImage(stored, sixteenBit: false)!

        for orientation in 1...8 {
            let data = NSMutableData()
            let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, cg, [kCGImagePropertyOrientation: orientation,
                                                   kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
            #expect(CGImageDestinationFinalize(dest))
            let img = try PhotoImporter.load(data: data as Data)
            let swapped = orientation >= 5
            let ow = swapped ? bh : bw, oh = swapped ? bw : bh
            #expect(img.width == ow * block && img.height == oh * block, "orientation \(orientation): size \(img.width)x\(img.height)")
            guard img.width == ow * block, img.height == oh * block else { continue }
            for by in 0..<oh { for bx in 0..<ow {
                // displayed block (bx, by) comes from this stored block (EXIF orientation definitions)
                let (sx, sy): (Int, Int)
                switch orientation {
                case 1: (sx, sy) = (bx, by)
                case 2: (sx, sy) = (bw - 1 - bx, by)
                case 3: (sx, sy) = (bw - 1 - bx, bh - 1 - by)
                case 4: (sx, sy) = (bx, bh - 1 - by)
                case 5: (sx, sy) = (by, bx)
                case 6: (sx, sy) = (by, bh - 1 - bx)
                case 7: (sx, sy) = (bw - 1 - by, bh - 1 - bx)
                default: (sx, sy) = (bw - 1 - by, bx)
                }
                let p = img.pixels[(by * block + block / 2) * img.width + bx * block + block / 2]
                let want = stored.pixels[(sy * block + block / 2) * stored.width + sx * block + block / 2]
                // JPEG + P3 round trip: compare loosely but distinguish all eight colours.
                #expect(simd_length(SIMD3(p.x, p.y, p.z) - SIMD3(want.x, want.y, want.z)) < 0.08,
                        "orientation \(orientation) block (\(bx),\(by)): got \(p), want \(want)")
            } }
        }

        // maxDimension shrinks the longer side and keeps the aspect ratio.
        let url = adjTempFile("png")
        defer { try? FileManager.default.removeItem(at: url) }
        try PhotoExporter.write(adjSmoothPhoto(80, 40), to: url, format: .png8)
        let small = try PhotoImporter.load(url, maxDimension: 20)
        #expect(small.width == 20 && small.height == 10)
        let notEnlarged = try PhotoImporter.load(url, maxDimension: 500)
        #expect(notEnlarged.width == 80)
    }

    @Test func exportClampsHDRAndProducesTaggedCGImages() throws {
        let hdr = PhotoImage(width: 2, height: 1, pixels: [SIMD4(1.8, 0.5, -0.2, 1), SIMD4(0.2, 0.2, 0.2, 1)])
        let eight = try #require(PhotoExporter.cgImage(hdr, sixteenBit: false))
        #expect(eight.bitsPerComponent == 8 && eight.width == 2 && eight.alphaInfo == .last)
        #expect(eight.colorSpace?.name == CGColorSpace.displayP3)
        let sixteen = try #require(PhotoExporter.cgImage(hdr, sixteenBit: true))
        #expect(sixteen.bitsPerComponent == 16 && sixteen.colorSpace?.name == CGColorSpace.displayP3)
        let url = adjTempFile("png")
        defer { try? FileManager.default.removeItem(at: url) }
        try PhotoExporter.write(hdr, to: url, format: .png16)
        let back = try PhotoImporter.load(url)
        #expect(abs(back.pixels[0].x - 1) < 1e-3 && abs(back.pixels[0].z) < 1e-3)
        // Empty or inconsistent images produce nil rather than crashing.
        #expect(PhotoExporter.cgImage(PhotoImage(width: 0, height: 0, pixels: []), sixteenBit: false) == nil)
    }

    @Test func importFailuresThrow() {
        #expect(throws: (any Error).self) { try PhotoImporter.load(data: Data("definitely not a picture".utf8)) }
        #expect(throws: (any Error).self) { try PhotoImporter.load(URL(fileURLWithPath: "/nonexistent/folder/missing.jpg")) }
        #expect(throws: (any Error).self) { try PhotoImporter.load(URL(fileURLWithPath: "/nonexistent/folder/missing.dng")) }
        #expect(throws: (any Error).self) { try PhotoExporter.write(PhotoImage(width: 0, height: 0, pixels: []),
                                                                     to: adjTempFile("png"), format: .png8) }
    }
}

// MARK: - SwiftUI smoke tests (headless: rendered to an image, no window)

import SwiftUI

@Suite struct AdjustmentUITests {
    @MainActor @Test func curveEditorDrawsItsGridCurveAndPoints() throws {
        var curve = ResponseCurve(points: [SIMD2(0, 0), SIMD2(0.3, 0.15), SIMD2(0.7, 0.85), SIMD2(1, 1)])
        let binding = Binding(get: { curve }, set: { curve = $0 })
        let renderer = ImageRenderer(content: CurveEditorView(curve: binding, tint: .red).frame(width: 160, height: 160))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        #expect(image.width == 160 && image.height == 160)
        // Something other than a flat fill was drawn, and the red tint made it into the picture.
        let photo = try #require(PhotoImage(cgImage: image))
        let reds = photo.pixels.filter { $0.x > 0.6 && $0.y < 0.5 && $0.w > 0.5 }.count
        #expect(reds > 100)
        #expect(Set(photo.pixels.map { SIMD4<Int>(Int($0.x * 20), Int($0.y * 20), Int($0.z * 20), Int($0.w * 20)) }).count > 4)
    }

    @MainActor @Test func everyAdjustmentKindBuildsAPanel() throws {
        for kind in AdjustmentKind.allCases {
            var settings = AdjustmentSettings(kind: kind)
            let binding = Binding(get: { settings }, set: { settings = $0 })
            let renderer = ImageRenderer(content: LightroomAdjustmentsView(settings: binding).frame(width: 300, height: 600))
            #expect(renderer.cgImage != nil, "\(kind) panel failed to render")
        }
    }
}
