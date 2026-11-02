import Foundation
import CoreGraphics

/// Reads sampled brush tips from Adobe Photoshop `.abr` files.
///
/// Supported layouts (as documented by GIMP's and Krita's open-source loaders):
/// - **v1 / v2** (Photoshop ≤ 6): a list of brushes; type-2 entries are sampled tips with spacing and,
///   in v2, a Unicode name.
/// - **v6 / v7 / v10** (Photoshop 7 → CC): `8BIM` sections; the `samp` section holds the tips.
/// Computed (parametric) v1 brushes and the `desc` descriptor settings are skipped — each tip becomes
/// a Paper brush with sensible default dynamics that you can tune in Brush Studio.
public enum ABRImporter {
    public enum ABRError: Error, LocalizedError {
        case unsupportedVersion(Int)
        case malformed(String)
        case noSampledBrushes

        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let v): return "This .abr file uses an unsupported format (version \(v))."
            case .malformed(let what): return "The .abr file looks damaged (\(what))."
            case .noSampledBrushes: return "The .abr file has no image-based brushes Paper can import."
            }
        }
    }

    /// One decoded tip: 8-bit coverage (255 = paint), plus spacing (fraction of diameter) and name.
    public struct SampledTip {
        public var width: Int
        public var height: Int
        public var pixels: [UInt8]
        public var spacing: Float?
        public var name: String?
    }

    public static func brushes(from data: Data, packName: String) throws -> [BrushPreset] {
        let tips = try parse(data)
        guard !tips.isEmpty else { throw ABRError.noSampledBrushes }
        return tips.enumerated().compactMap { i, tip in
            guard let image = cgImage(tip), let gray = BrushTextureLibrary.grayPixels(from: image),
                  let png = BrushTextureLibrary.pngData(gray: gray) else { return nil }
            var b = BrushPreset(name: tip.name.flatMap { $0.isEmpty ? nil : $0 } ?? "\(packName) \(i + 1)", category: packName)
            b.author = "Imported from \(packName).abr"
            b.tip = .image(png)
            b.spacing = min(max(tip.spacing ?? 0.25, 0.01), 10)
            b.defaultSize = Float(max(tip.width, tip.height))
            b.maxSize = max(b.defaultSize * 2, 600)
            b.pressureSize = 0.6
            b.pressureFlow = 0.3
            return b
        }
    }

    public static func parse(_ data: Data) throws -> [SampledTip] {
        var r = Reader(data: data)
        let version = Int(try r.u16())
        switch version {
        case 1, 2: return try parseV12(&r, version: version)
        case 6, 7, 10: return try parseV6(&r)
        default: throw ABRError.unsupportedVersion(version)
        }
    }

    private static func parseV12(_ r: inout Reader, version: Int) throws -> [SampledTip] {
        let count = Int(try r.u16())
        var tips: [SampledTip] = []
        for _ in 0..<count {
            let type = try r.u16()
            let size = Int(try r.u32())
            let end = r.offset + size
            defer { r.offset = end }
            guard type == 2 else { continue }   // 1 = computed brush (no pixels)
            _ = try r.u32()                      // misc
            let spacing = Float(try r.u16()) / 100
            var name: String?
            if version == 2 {
                let length = Int(try r.u32())
                let bytes = try r.bytes(length * 2)
                name = String(data: Data(bytes), encoding: .utf16BigEndian)?.trimmingCharacters(in: .controlCharacters)
            }
            _ = try r.u8()                       // anti-aliasing
            try r.skip(8)                        // short bounds
            let top = Int(try r.i32()), left = Int(try r.i32()), bottom = Int(try r.i32()), right = Int(try r.i32())
            let depth = Int(try r.u16())
            let compressed = try r.u8() != 0
            if var tip = try readPixels(&r, width: right - left, height: bottom - top, depth: depth, compressed: compressed) {
                tip.spacing = spacing > 0 ? spacing : nil
                tip.name = name
                tips.append(tip)
            }
        }
        return tips
    }

    private static func parseV6(_ r: inout Reader) throws -> [SampledTip] {
        let subversion = try r.u16()
        var tips: [SampledTip] = []
        while r.offset + 12 <= r.data.count {
            let signature = try r.ascii(4)
            guard signature == "8BIM" || signature == "8B64" else { throw ABRError.malformed("section signature") }
            let tag = try r.ascii(4)
            let length = Int(try r.u32())
            let sectionEnd = min(r.offset + length, r.data.count)
            if tag == "samp" {
                while r.offset + 4 <= sectionEnd {
                    let brushSize = Int(try r.u32())
                    var padded = brushSize
                    while padded % 4 != 0 { padded += 1 }
                    let next = r.offset + padded
                    // Skip the UUID key and header fields that precede the bounds.
                    try r.skip(subversion == 1 ? 47 : 301)
                    let top = Int(try r.i32()), left = Int(try r.i32()), bottom = Int(try r.i32()), right = Int(try r.i32())
                    let depth = Int(try r.u16())
                    let compressed = try r.u8() != 0
                    if let tip = try readPixels(&r, width: right - left, height: bottom - top, depth: depth,
                                                compressed: compressed) {
                        tips.append(tip)
                    }
                    r.offset = next
                }
            }
            r.offset = sectionEnd
        }
        return tips
    }

    private static func readPixels(_ r: inout Reader, width: Int, height: Int, depth: Int, compressed: Bool) throws -> SampledTip? {
        guard width > 0, height > 0, width <= 8192, height <= 8192, depth == 8 || depth == 16 else { return nil }
        let bytesPerPixel = depth / 8
        let rowBytes = width * bytesPerPixel
        var raw: [UInt8]
        if compressed {
            var rowLengths: [Int] = []
            for _ in 0..<height { rowLengths.append(Int(try r.u16())) }
            raw = []
            raw.reserveCapacity(rowBytes * height)
            for length in rowLengths {
                let packed = try r.bytes(length)
                var row = packBitsDecode(packed, expected: rowBytes)
                if row.count < rowBytes { row += [UInt8](repeating: 0, count: rowBytes - row.count) }
                raw += row.prefix(rowBytes)
            }
        } else {
            raw = try r.bytes(rowBytes * height)
        }
        var pixels: [UInt8]
        if bytesPerPixel == 2 {
            // Big-endian 16-bit → keep the high byte.
            pixels = stride(from: 0, to: raw.count, by: 2).map { raw[$0] }
        } else {
            pixels = raw
        }
        // Some files store dark-on-white tips; flip them so the border is transparent.
        var border = 0, borderCount = 0
        for x in 0..<width {
            border += Int(pixels[x]) + Int(pixels[(height - 1) * width + x])
            borderCount += 2
        }
        if borderCount > 0 && border / borderCount > 128 { pixels = pixels.map { 255 - $0 } }
        return SampledTip(width: width, height: height, pixels: pixels, spacing: nil, name: nil)
    }

    /// Apple/Photoshop PackBits run-length decoding.
    static func packBitsDecode(_ input: [UInt8], expected: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(expected)
        var i = 0
        while i < input.count && out.count < expected {
            let n = Int(Int8(bitPattern: input[i]))
            i += 1
            if n >= 0 {
                let end = min(i + n + 1, input.count)
                out += input[i..<end]
                i = end
            } else if n > -128 {
                guard i < input.count else { break }
                out += [UInt8](repeating: input[i], count: 1 - n)
                i += 1
            }
        }
        return out
    }

    private static func cgImage(_ tip: SampledTip) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(tip.pixels) as CFData) else { return nil }
        return CGImage(width: tip.width, height: tip.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: tip.width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Big-endian reader with bounds checks.
    struct Reader {
        let data: [UInt8]
        var offset = 0

        init(data: Data) { self.data = [UInt8](data) }

        mutating func bytes(_ n: Int) throws -> [UInt8] {
            guard n >= 0, offset + n <= data.count else { throw ABRError.malformed("unexpected end of file") }
            defer { offset += n }
            return Array(data[offset..<(offset + n)])
        }
        mutating func skip(_ n: Int) throws { _ = try bytes(n) }
        mutating func u8() throws -> UInt8 { try bytes(1)[0] }
        mutating func u16() throws -> UInt16 { let b = try bytes(2); return UInt16(b[0]) << 8 | UInt16(b[1]) }
        mutating func u32() throws -> UInt32 {
            let b = try bytes(4)
            return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
        }
        mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
        mutating func ascii(_ n: Int) throws -> String { String(decoding: try bytes(n), as: UTF8.self) }
    }
}
