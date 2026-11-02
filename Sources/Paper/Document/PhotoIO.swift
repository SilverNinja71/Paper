import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import simd

// MARK: - Image type

/// A decoded photo: 32-bit float RGBA, premultiplied, gamma-encoded extended Display P3, top row first.
/// Values may be above 1 (HDR / RAW highlights) or slightly negative (outside the P3 gamut).
public struct PhotoImage: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [SIMD4<Float>]

    public init(width: Int, height: Int, pixels: [SIMD4<Float>]) {
        precondition(pixels.count == width * height, "PhotoImage needs width × height pixels")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Draws any `CGImage` (any colour space, bit depth or alpha) into extended Display P3 floats.
    /// `maxDimension` shrinks the longer side to at most that many pixels (never enlarges).
    /// `orientation` is an EXIF/`CGImagePropertyOrientation` value; the result is upright.
    public init?(cgImage: CGImage, maxDimension: Int? = nil, orientation: Int = 1) {
        guard let decoded = try? PhotoImporter.draw(cgImage, maxDimension: maxDimension, orientation: orientation) else { return nil }
        self = decoded
    }
}

public enum PhotoIOError: Error, LocalizedError {
    case cannotRead(String)
    case unsupportedFormat(String)
    case rawDecodeFailed(String)
    case imageTooLarge(Int, Int)
    case cannotCreateContext
    case cannotEncode(String)

    public var errorDescription: String? {
        switch self {
        case .cannotRead(let what): return "Paper couldn't open \(what)."
        case .unsupportedFormat(let what): return "Paper doesn't know how to read \(what)."
        case .rawDecodeFailed(let what): return "The camera RAW file \(what) couldn't be developed."
        case .imageTooLarge(let w, let h): return "A \(w) × \(h) picture is too large to load at full size. Try opening it at a smaller size."
        case .cannotCreateContext: return "Not enough memory to load the picture."
        case .cannotEncode(let what): return "Paper couldn't save the picture as \(what)."
        }
    }
}

// MARK: - Import

public enum PhotoImporter {
    /// Anything above this many pixels is refused rather than risking a crash (≈ 2.4 GB of floats).
    private static let maxPixelCount = 150_000_000

    private static let rawExtensions: Set<String> = [
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "rwl", "pef", "ptx",
        "srw", "raw", "3fr", "fff", "iiq", "erf", "mef", "mos", "mrw", "kdc", "dcr", "x3f", "gpr", "bay", "cap",
    ]

    /// Loads a picture file. ImageIO handles PNG, JPEG, HEIC, TIFF, GIF (first frame), BMP, flattened PSD and
    /// friends; camera RAW files (DNG, CR2/CR3, NEF, ARW, RAF, ORF, RW2 …) go through Core Image's RAW developer.
    /// `maxDimension` limits the longer side (RAW files are developed at the reduced size, which is much faster).
    public static func load(_ url: URL, maxDimension: Int? = nil) throws -> PhotoImage {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        if rawExtensions.contains(ext) || source.map(isRAW) == true {
            if let image = decodeRAW(CIRAWFilter(imageURL: url), maxDimension: maxDimension) { return image }
            // Some "RAW" extensions are really TIFF/JPEG wrappers; let ImageIO have a go before giving up.
            guard let source, CGImageSourceGetCount(source) > 0 else { throw PhotoIOError.rawDecodeFailed(name) }
        }
        guard let source else { throw PhotoIOError.cannotRead(name) }
        return try decode(source, maxDimension: maxDimension, name: name)
    }

    public static func load(data: Data) throws -> PhotoImage { try load(data: data, maxDimension: nil) }

    public static func load(data: Data, maxDimension: Int?) throws -> PhotoImage {
        let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        if let source, isRAW(source) {
            let filter = CIRAWFilter(imageData: data, identifierHint: CGImageSourceGetType(source) as String?)
            if let image = decodeRAW(filter, maxDimension: maxDimension) { return image }
        }
        guard let source else { throw PhotoIOError.cannotRead("this data") }
        return try decode(source, maxDimension: maxDimension, name: "this data")
    }

    private static func isRAW(_ source: CGImageSource) -> Bool {
        guard let id = CGImageSourceGetType(source), let type = UTType(id as String) else { return false }
        return type.conforms(to: .rawImage)
    }

    // MARK: ImageIO path

    private static func decode(_ source: CGImageSource, maxDimension: Int?, name: String) throws -> PhotoImage {
        guard CGImageSourceGetCount(source) > 0 else { throw PhotoIOError.unsupportedFormat(name) }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let orientation = (props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1

        let options: [CFString: Any] = [kCGImageSourceShouldAllowFloat: true, kCGImageSourceShouldCache: false]
        var image: CGImage?
        // Photos with an HDR gain map keep their extra highlight range when decoded for HDR.
        if hasGainMap(source, index) {
            if #available(macOS 14.0, iOS 17.0, *) {
                var hdr = options
                hdr[kCGImageSourceDecodeRequest] = kCGImageSourceDecodeToHDR
                image = CGImageSourceCreateImageAtIndex(source, index, hdr as CFDictionary)
            }
        }
        if image == nil { image = CGImageSourceCreateImageAtIndex(source, index, options as CFDictionary) }
        guard let image else { throw PhotoIOError.unsupportedFormat(name) }
        return try draw(image, maxDimension: maxDimension, orientation: orientation)
    }

    private static func hasGainMap(_ source: CGImageSource, _ index: Int) -> Bool {
        if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, kCGImageAuxiliaryDataTypeHDRGainMap) != nil { return true }
        if #available(macOS 15.0, iOS 18.0, *) {
            if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, kCGImageAuxiliaryDataTypeISOGainMap) != nil { return true }
        }
        return false
    }

    /// Draws `image` into a float extended-Display-P3 bitmap, applying EXIF orientation and optional shrinking.
    fileprivate static func draw(_ image: CGImage, maxDimension: Int?, orientation: Int) throws -> PhotoImage {
        let swap = (5...8).contains(orientation)
        let ow = swap ? image.height : image.width            // upright size
        let oh = swap ? image.width : image.height
        var tw = ow, th = oh
        if let limit = maxDimension, limit > 0, max(ow, oh) > limit {
            let scale = Double(limit) / Double(max(ow, oh))
            tw = max(1, Int((Double(ow) * scale).rounded()))
            th = max(1, Int((Double(oh) * scale).rounded()))
        }
        guard tw * th <= maxPixelCount else { throw PhotoIOError.imageTooLarge(tw, th) }
        guard let space = CGColorSpace(name: CGColorSpace.extendedDisplayP3) else { throw PhotoIOError.cannotCreateContext }

        let count = tw * th
        var pixels = [SIMD4<Float>](repeating: .zero, count: count)
        let ok: Bool = pixels.withUnsafeMutableBytes { raw in
            let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            guard let ctx = CGContext(data: raw.baseAddress, width: tw, height: th, bitsPerComponent: 32, bytesPerRow: tw * 16,
                                      space: space, bitmapInfo: info) else { return false }
            ctx.interpolationQuality = .high
            ctx.setBlendMode(.copy)
            ctx.scaleBy(x: CGFloat(tw) / CGFloat(ow), y: CGFloat(th) / CGFloat(oh))
            ctx.concatenate(orientationTransform(orientation, width: ow, height: oh))
            let w = CGFloat(image.width), h = CGFloat(image.height)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw PhotoIOError.cannotCreateContext }
        sanitise(&pixels)
        return PhotoImage(width: tw, height: th, pixels: pixels)
    }

    /// Maps raw image space (origin bottom-left, size = stored image) onto the upright image of size `width × height`.
    private static func orientationTransform(_ orientation: Int, width w: Int, height h: Int) -> CGAffineTransform {
        let w = CGFloat(w), h = CGFloat(h)
        var t = CGAffineTransform.identity
        switch orientation {
        case 3, 4: t = t.translatedBy(x: w, y: h).rotated(by: .pi)
        case 5, 8: t = t.translatedBy(x: w, y: 0).rotated(by: .pi / 2)       // "left"
        case 6, 7: t = t.translatedBy(x: 0, y: h).rotated(by: -.pi / 2)      // "right"
        default: break
        }
        switch orientation {
        case 2, 4: t = t.translatedBy(x: w, y: 0).scaledBy(x: -1, y: 1)
        case 5, 7: t = t.translatedBy(x: h, y: 0).scaledBy(x: -1, y: 1)
        default: break
        }
        return t
    }

    private static func sanitise(_ pixels: inout [SIMD4<Float>]) {
        pixels.withUnsafeMutableBufferPointer { buf in
            for i in buf.indices where !(buf[i].x.isFinite && buf[i].y.isFinite && buf[i].z.isFinite && buf[i].w.isFinite) {
                buf[i] = .zero
            }
        }
    }

    // MARK: RAW path

    /// Develops a camera RAW with Core Image, keeping highlights above 1.0 (extended dynamic range) in extended Display P3.
    private static func decodeRAW(_ filter: CIRAWFilter?, maxDimension: Int?) -> PhotoImage? {
        guard let filter, let space = CGColorSpace(name: CGColorSpace.extendedDisplayP3) else { return nil }
        let native = filter.nativeSize
        if let limit = maxDimension, limit > 0, max(native.width, native.height) > CGFloat(limit) {
            filter.scaleFactor = Float(CGFloat(limit) / max(native.width, native.height))
        }
        filter.extendedDynamicRangeAmount = 1
        guard let output = filter.outputImage else { return nil }
        let extent = output.extent.integral
        guard extent.width >= 1, extent.height >= 1, !extent.isInfinite else { return nil }
        let w = Int(extent.width), h = Int(extent.height)
        guard w * h <= maxPixelCount else { return nil }

        let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf,
                                          .outputColorSpace: space, .cacheIntermediates: false])
        var pixels = [SIMD4<Float>](repeating: .zero, count: w * h)
        pixels.withUnsafeMutableBytes { raw in
            context.render(output, toBitmap: raw.baseAddress!, rowBytes: w * 16, bounds: extent, format: .RGBAf, colorSpace: space)
        }
        sanitise(&pixels)
        return PhotoImage(width: w, height: h, pixels: pixels)
    }
}

// MARK: - Export

public enum PhotoExportFormat: Equatable, Sendable {
    /// 8-bit PNG with alpha.
    case png8
    /// 16-bit PNG with alpha.
    case png16
    /// JPEG (no alpha: composited on white), quality 0…1.
    case jpeg(quality: Double)
    /// 16-bit TIFF with alpha.
    case tiff16
    /// HEIC (no alpha: composited on white), quality 0…1.
    case heic(quality: Double)
}

public enum PhotoExporter {
    /// Writes `image` to `url`: un-premultiplied, clamped to 0…1, with the Display P3 profile embedded.
    public static func write(_ image: PhotoImage, to url: URL, format: PhotoExportFormat) throws {
        let type: UTType, name: String
        var sixteen = false, alpha = true
        var properties: [CFString: Any] = [:]
        switch format {
        case .png8: type = .png; name = "an 8-bit PNG"
        case .png16: type = .png; name = "a 16-bit PNG"; sixteen = true
        case .tiff16:
            type = .tiff; name = "a 16-bit TIFF"; sixteen = true
            properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5]     // LZW
        case .jpeg(let q):
            type = .jpeg; name = "a JPEG"; alpha = false
            properties[kCGImageDestinationLossyCompressionQuality] = max(0, min(1, q))
        case .heic(let q):
            type = .heic; name = "a HEIC"; alpha = false
            properties[kCGImageDestinationLossyCompressionQuality] = max(0, min(1, q))
        }
        guard image.width > 0, image.height > 0, let cg = makeCGImage(image, sixteenBit: sixteen, keepAlpha: alpha) else {
            throw PhotoIOError.cannotEncode(name)
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw PhotoIOError.cannotEncode(name)
        }
        CGImageDestinationAddImage(destination, cg, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PhotoIOError.cannotEncode(name) }
    }

    /// A `CGImage` (straight alpha, Display P3 profile) of the photo, 8 or 16 bits per channel.
    public static func cgImage(_ image: PhotoImage, sixteenBit: Bool) -> CGImage? {
        makeCGImage(image, sixteenBit: sixteenBit, keepAlpha: true)
    }

    private static func makeCGImage(_ image: PhotoImage, sixteenBit: Bool, keepAlpha: Bool) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, image.pixels.count == w * h, let space = CGColorSpace(name: CGColorSpace.displayP3) else { return nil }
        let bytesPerPixel = sixteenBit ? 8 : 4
        let rowBytes = w * bytesPerPixel
        var data = Data(count: rowBytes * h)

        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let base = raw.baseAddress!
            image.pixels.withUnsafeBufferPointer { src in
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    let row = base + y * rowBytes
                    for x in 0..<w {
                        let p = src[y * w + x]
                        let a = max(0, min(1, p.w))
                        var rgb = SIMD3<Float>(p.x, p.y, p.z)
                        if keepAlpha {
                            rgb = a > 0 ? rgb / a : .zero                // un-premultiply
                        } else {
                            rgb = rgb + (1 - a)                          // premultiplied colour over white
                        }
                        rgb = simd_clamp(rgb, .zero, .one)
                        if sixteenBit {
                            let out = (row + x * 8).assumingMemoryBound(to: UInt16.self)
                            out[0] = UInt16(rgb.x * 65535 + 0.5); out[1] = UInt16(rgb.y * 65535 + 0.5); out[2] = UInt16(rgb.z * 65535 + 0.5)
                            out[3] = keepAlpha ? UInt16(a * 65535 + 0.5) : 65535
                        } else {
                            let out = (row + x * 4).assumingMemoryBound(to: UInt8.self)
                            out[0] = UInt8(rgb.x * 255 + 0.5); out[1] = UInt8(rgb.y * 255 + 0.5); out[2] = UInt8(rgb.z * 255 + 0.5)
                            out[3] = keepAlpha ? UInt8(a * 255 + 0.5) : 255
                        }
                    }
                }
            }
        }

        var info: UInt32 = keepAlpha ? CGImageAlphaInfo.last.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        if sixteenBit { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: sixteenBit ? 16 : 8, bitsPerPixel: bytesPerPixel * 8,
                       bytesPerRow: rowBytes, space: space, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
