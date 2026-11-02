import Foundation
import Metal
import simd

// MARK: - Public API

public enum AdjustmentPipelineError: Error, LocalizedError {
    case incompatibleTextures
    case encoderUnavailable
    case scratchAllocationFailed

    public var errorDescription: String? {
        switch self {
        case .incompatibleTextures: return "The adjustment's source and destination must be different textures of the same size."
        case .encoderUnavailable: return "The graphics card could not start an adjustment pass."
        case .scratchAllocationFailed: return "Not enough graphics memory for the adjustment's working textures."
        }
    }
}

/// Runs an `AdjustmentSettings` block on the GPU.
///
/// Textures hold premultiplied, gamma-encoded Display P3 (values above 1 are allowed). Every kernel
/// un-premultiplies, adjusts straight colour, and re-premultiplies, so output alpha equals input alpha
/// (the gradient map multiplies in the gradient stop's alpha, as Photoshop does).
///
/// Design notes
///  * **Develop** is one kernel (dehaze → exposure → white balance → contrast → highlights/shadows/whites/
///    blacks → vibrance/saturation). Clarity needs a blur of the *adjusted* luminance, so when clarity is
///    on, the kernel writes a canvas-sized scratch texture and a second kernel applies clarity.
///  * Large blurs run at reduced resolution (box downsample → Gaussian with σ≈4–9 low-res pixels →
///    bilinear upsample). That makes clarity/dehaze cost independent of the blur radius.
///  * Dehaze is the dark-channel prior: atmospheric light from the brightest dark-channel samples
///    (whole canvas, one threadgroup), transmission from a block-min / min-filtered normalised dark
///    channel, refined with an edge-aware fast guided filter (He & Sun) using luminance as the guide.
///  * `encode` is called every frame, so LUT textures and scratch textures are cached.
public final class AdjustmentPipeline {
    private let gpu: PaperGPU
    private let kernels: AdjustmentKernels
    private let atmosphere: MTLBuffer
    private let lock = NSLock()
    private var curveCache = AdjustmentLRU<ToneCurveSettings, MTLTexture>(capacity: 24)
    private var gradientCache = AdjustmentLRU<GradientMapSettings, MTLTexture>(capacity: 24)
    private var scratchSets: [AdjustmentScratch] = []

    public init(gpu: PaperGPU) throws {
        self.gpu = gpu
        kernels = try AdjustmentKernels(gpu: gpu)
        guard let buffer = gpu.device.makeBuffer(length: 16, options: .storageModePrivate) else {
            throw AdjustmentPipelineError.scratchAllocationFailed
        }
        buffer.label = "adjustment atmosphere"
        atmosphere = buffer
    }

    /// Writes the adjusted `source` into `destination` for the pixels in `region`.
    ///
    /// Both textures are canvas-sized `rgba16Float`, premultiplied, gamma-encoded Display P3.
    /// Pixels outside `region` may be read (blurs) but are not written.
    public func encode(_ settings: AdjustmentSettings, source: MTLTexture, destination: MTLTexture,
                       region: IntRect, commandBuffer: MTLCommandBuffer) throws {
        guard source !== destination, source.width == destination.width, source.height == destination.height else {
            throw AdjustmentPipelineError.incompatibleTextures
        }
        let r = region.clamped(width: destination.width, height: destination.height)
        guard !r.isEmpty else { return }

        lock.lock(); defer { lock.unlock() }
        if AdjustmentParameters.isIdentity(settings) {
            gpu.copy(source, region: r, to: destination, in: commandBuffer)
            return
        }
        guard let enc = commandBuffer.makeComputeCommandEncoder() else { throw AdjustmentPipelineError.encoderUnavailable }
        enc.label = "Adjustment \(settings.kind.rawValue)"
        defer { enc.endEncoding() }

        switch settings.kind {
        case .develop: try encodeDevelop(enc, settings.develop, source, destination, r)
        case .toneCurve: encodeToneCurve(enc, settings.curves, source, destination, r)
        case .hsl: encodeHSL(enc, settings.hsl, source, destination, r)
        case .colorGrading: encodeGrading(enc, settings.grading, source, destination, r)
        case .gradientMap: encodeGradientMap(enc, settings.gradientMap, source, destination, r)
        case .selectiveColor: encodeSelective(enc, settings.selectiveColor, source, destination, r)
        }
    }

    /// How far (pixels) an output pixel's value depends on its neighbours.
    ///
    /// Per-pixel adjustments return 0. Clarity reads a blurred copy of the image, so it reaches a few
    /// percent of the canvas. Dehaze additionally depends on a whole-canvas atmospheric-light estimate,
    /// so it reports the full canvas size: any change anywhere can change every output pixel.
    public static func neighborhoodRadius(for settings: AdjustmentSettings, canvasWidth: Int, canvasHeight: Int) -> Int {
        guard settings.kind == .develop else { return 0 }
        let w = max(1, canvasWidth), h = max(1, canvasHeight)
        let d = settings.develop
        if d.dehaze != 0 { return max(w, h) }
        if d.clarity != 0 { return AdjustmentHalo(width: w, height: h).clarityRadius }
        return 0
    }

    // MARK: Develop

    private func encodeDevelop(_ enc: MTLComputeCommandEncoder, _ d: DevelopSettings, _ source: MTLTexture,
                               _ destination: MTLTexture, _ region: IntRect) throws {
        let halo = AdjustmentHalo(width: destination.width, height: destination.height)
        let hasClarity = d.clarity != 0
        let hasDehaze = d.dehaze != 0
        let positiveDehaze = d.dehaze > 0

        let scratch: AdjustmentScratch? = (hasClarity || positiveDehaze)
            ? try scratchSet(width: destination.width, height: destination.height, halo: halo, needTemp: hasClarity) : nil

        // The first kernel must cover everything clarity will blur over.
        var developRegion = region
        if hasClarity {
            developRegion = halo.canvasRect(of: halo.lowRect(covering: region).expanded(halo.blurRadius, halo.blurRadius, halo))
                .clamped(width: destination.width, height: destination.height)
        }

        if hasDehaze {
            encodeAtmosphere(enc, source)
            if positiveDehaze, let scratch { encodeDehazeMaps(enc, source, scratch, halo, developRegion) }
        }

        var params = AdjustmentParameters.develop(d, factor: halo.factor, origin: developRegion)
        let target = hasClarity ? scratch!.temp! : destination
        enc.setTexture(source, index: 0)
        enc.setTexture(target, index: 1)
        enc.setTexture(positiveDehaze ? scratch!.lowC : gpu.dummyColor, index: 2)
        enc.setBuffer(atmosphere, offset: 0, index: 0)
        enc.setBytes(&params, length: MemoryLayout<AdjustmentDevelopParams>.stride, index: 1)
        enc.dispatch2D(kernels.develop, width: developRegion.width, height: developRegion.height)

        if hasClarity, let scratch {
            encodeClarity(enc, scratch, destination, halo, region, amount: max(-1, min(1, d.clarity / 100)))
        }
    }

    private func encodeAtmosphere(_ enc: MTLComputeCommandEncoder, _ source: MTLTexture) {
        var params = AdjustmentAtmosphereParams(size: SIMD4(UInt32(source.width), UInt32(source.height), 32,
                                                  UInt32(max(1, min(6, max(source.width, source.height) / 512)))))
        enc.setComputePipelineState(kernels.atmosphere)
        enc.setTexture(source, index: 0)
        enc.setBuffer(atmosphere, offset: 0, index: 0)
        enc.setBytes(&params, length: MemoryLayout<AdjustmentAtmosphereParams>.stride, index: 1)
        // One threadgroup reduces the whole sample grid; use as many threads as the GPU allows (power of two ≤ 256).
        var threads = 256
        while threads > kernels.atmosphere.maxTotalThreadsPerThreadgroup && threads > 64 { threads /= 2 }
        enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: threads, height: 1, depth: 1))
    }

    /// Builds the low-resolution transmission coefficients (`lowC`) for every pixel of `region`.
    private func encodeDehazeMaps(_ enc: MTLComputeCommandEncoder, _ source: MTLTexture, _ s: AdjustmentScratch,
                                  _ halo: AdjustmentHalo, _ region: IntRect) {
        let rg = AdjustmentHalo.guideRadius, rho = AdjustmentHalo.minRadius
        let l0 = halo.lowRect(covering: region)
        let down = l0.expanded(2 * rg + rho, 2 * rg + rho, halo)
        let minH = AdjustmentLowRect(x0: l0.expanded(2 * rg, 0, halo).x0, y0: down.y0, x1: l0.expanded(2 * rg, 0, halo).x1, y1: down.y1)
        let minV = l0.expanded(2 * rg, 2 * rg, halo)
        let guide = l0.expanded(rg, rg, halo)
        let f = UInt32(halo.factor)
        let canvas = SIMD4<UInt32>(UInt32(halo.width), UInt32(halo.height), f, 0)

        // 1. block means of the guide and block minima of the normalised dark channel
        var p = AdjustmentLowParams(rect: down.packed, canvas: canvas, misc: .zero, fl: .zero)
        enc.setTexture(source, index: 0)
        enc.setTexture(s.lowA, index: 1)
        enc.setBuffer(atmosphere, offset: 0, index: 0)
        enc.setBytes(&p, length: MemoryLayout<AdjustmentLowParams>.stride, index: 1)
        enc.dispatch2D(kernels.dehazeDown, width: down.width, height: down.height)

        // 2. minimum filter (separable): lowA → lowB → lowA
        p = AdjustmentLowParams(rect: minH.packed, canvas: canvas, misc: SIMD4(1, 0, UInt32(rho), 0), fl: .zero)
        enc.setTexture(s.lowA, index: 0); enc.setTexture(s.lowB, index: 1)
        enc.setBytes(&p, length: MemoryLayout<AdjustmentLowParams>.stride, index: 0)
        enc.dispatch2D(kernels.lowMin, width: minH.width, height: minH.height)
        p = AdjustmentLowParams(rect: minV.packed, canvas: canvas, misc: SIMD4(0, 1, UInt32(rho), 0), fl: .zero)
        enc.setTexture(s.lowB, index: 0); enc.setTexture(s.lowA, index: 1)
        enc.setBytes(&p, length: MemoryLayout<AdjustmentLowParams>.stride, index: 0)
        enc.dispatch2D(kernels.lowMin, width: minV.width, height: minV.height)

        // 3. guided-filter coefficients a, b: lowA → lowB
        p = AdjustmentLowParams(rect: guide.packed, canvas: canvas, misc: SIMD4(UInt32(rg), 0, 0, 0), fl: SIMD4(AdjustmentHalo.guideEpsilon, 0, 0, 0))
        enc.setTexture(s.lowA, index: 0); enc.setTexture(s.lowB, index: 1)
        enc.setBytes(&p, length: MemoryLayout<AdjustmentLowParams>.stride, index: 0)
        enc.dispatch2D(kernels.dehazeGuide, width: guide.width, height: guide.height)

        // 4. average a, b over the same window: lowB → lowC
        p = AdjustmentLowParams(rect: l0.packed, canvas: canvas, misc: SIMD4(UInt32(rg), 0, 0, 0), fl: .zero)
        enc.setTexture(s.lowB, index: 0); enc.setTexture(s.lowC, index: 1)
        enc.setBytes(&p, length: MemoryLayout<AdjustmentLowParams>.stride, index: 0)
        enc.dispatch2D(kernels.dehazeSmooth, width: l0.width, height: l0.height)
    }

    private func encodeClarity(_ enc: MTLComputeCommandEncoder, _ s: AdjustmentScratch, _ destination: MTLTexture,
                               _ halo: AdjustmentHalo, _ region: IntRect, amount: Float) {
        let t = halo.blurRadius
        let l0 = halo.lowRect(covering: region)
        let down = l0.expanded(t, t, halo)
        let blurH = l0.expanded(0, t, halo)
        let f = UInt32(halo.factor)
        let canvas = SIMD4<UInt32>(UInt32(halo.width), UInt32(halo.height), f, 0)

        var p = AdjustmentLowParams(rect: down.packed, canvas: canvas, misc: .zero, fl: .zero)
        enc.setTexture(s.temp!, index: 0)
        enc.setTexture(s.lowA, index: 1)
        enc.setBytes(&p, length: MemoryLayout<AdjustmentLowParams>.stride, index: 0)
        enc.dispatch2D(kernels.clarityDown, width: down.width, height: down.height)

        // Gaussian blur at low resolution: lowA → lowB (horizontal) → lowA (vertical)
        p = AdjustmentLowParams(rect: blurH.packed, canvas: canvas, misc: SIMD4(1, 0, UInt32(t), 0), fl: SIMD4(halo.sigmaLow, 0, 0, 0))
        enc.setTexture(s.lowA, index: 0); enc.setTexture(s.lowB, index: 1)
        enc.setBytes(&p, length: MemoryLayout<AdjustmentLowParams>.stride, index: 0)
        enc.dispatch2D(kernels.lowBlur, width: blurH.width, height: blurH.height)
        p = AdjustmentLowParams(rect: l0.packed, canvas: canvas, misc: SIMD4(0, 1, UInt32(t), 0), fl: SIMD4(halo.sigmaLow, 0, 0, 0))
        enc.setTexture(s.lowB, index: 0); enc.setTexture(s.lowA, index: 1)
        enc.setBytes(&p, length: MemoryLayout<AdjustmentLowParams>.stride, index: 0)
        enc.dispatch2D(kernels.lowBlur, width: l0.width, height: l0.height)

        var cp = AdjustmentClarityParams(geom: SIMD4(UInt32(region.x), UInt32(region.y), f, 0), fl: SIMD4(amount, 0, 0, 0))
        enc.setTexture(s.temp!, index: 0)
        enc.setTexture(destination, index: 1)
        enc.setTexture(s.lowA, index: 2)
        enc.setBytes(&cp, length: MemoryLayout<AdjustmentClarityParams>.stride, index: 0)
        enc.dispatch2D(kernels.clarity, width: region.width, height: region.height)
    }

    // MARK: Tone curve

    private func encodeToneCurve(_ enc: MTLComputeCommandEncoder, _ c: ToneCurveSettings, _ source: MTLTexture,
                                 _ destination: MTLTexture, _ region: IntRect) {
        let lut = curveTexture(c)
        let hasRGB = !(c.master.isIdentity && c.red.isIdentity && c.green.isIdentity && c.blue.isIdentity)
        let hasLum = !c.luminance.isIdentity
        var p = AdjustmentGeomParams(geom: SIMD4(UInt32(region.x), UInt32(region.y), (hasRGB ? 1 : 0) | (hasLum ? 2 : 0), 0))
        enc.setTexture(source, index: 0)
        enc.setTexture(destination, index: 1)
        enc.setTexture(lut, index: 2)
        enc.setBytes(&p, length: MemoryLayout<AdjustmentGeomParams>.stride, index: 0)
        enc.dispatch2D(kernels.toneCurve, width: region.width, height: region.height)
    }

    private func curveTexture(_ c: ToneCurveSettings) -> MTLTexture {
        if let t = curveCache.get(c) { return t }
        let t = makeLUTTexture(AdjustmentParameters.curveLUT(c), label: "tone curve LUT")
        curveCache.put(c, t)
        return t
    }

    // MARK: HSL, grading, gradient map, selective colour

    private func encodeHSL(_ enc: MTLComputeCommandEncoder, _ h: HSLSettings, _ source: MTLTexture,
                           _ destination: MTLTexture, _ region: IntRect) {
        var p = AdjustmentGeomParams(geom: SIMD4(UInt32(region.x), UInt32(region.y), 0, 0))
        var bands = AdjustmentParameters.hslBands(h)
        enc.setTexture(source, index: 0)
        enc.setTexture(destination, index: 1)
        enc.setBytes(&p, length: MemoryLayout<AdjustmentGeomParams>.stride, index: 0)
        enc.setBytes(&bands, length: bands.count * MemoryLayout<Float>.stride, index: 1)
        enc.dispatch2D(kernels.hsl, width: region.width, height: region.height)
    }

    private func encodeGrading(_ enc: MTLComputeCommandEncoder, _ g: ColorGradingSettings, _ source: MTLTexture,
                               _ destination: MTLTexture, _ region: IntRect) {
        var p = AdjustmentParameters.grading(g, origin: region)
        enc.setTexture(source, index: 0)
        enc.setTexture(destination, index: 1)
        enc.setBytes(&p, length: MemoryLayout<AdjustmentGradingParams>.stride, index: 0)
        enc.dispatch2D(kernels.grading, width: region.width, height: region.height)
    }

    private func encodeGradientMap(_ enc: MTLComputeCommandEncoder, _ g: GradientMapSettings, _ source: MTLTexture,
                                   _ destination: MTLTexture, _ region: IntRect) {
        let lut: MTLTexture
        if let cached = gradientCache.get(g) { lut = cached } else {
            lut = makeLUTTexture(AdjustmentParameters.gradientLUT(g), label: "gradient map LUT")
            gradientCache.put(g, lut)
        }
        var p = AdjustmentGeomParams(geom: SIMD4(UInt32(region.x), UInt32(region.y), 0, 0))
        enc.setTexture(source, index: 0)
        enc.setTexture(destination, index: 1)
        enc.setTexture(lut, index: 2)
        enc.setBytes(&p, length: MemoryLayout<AdjustmentGeomParams>.stride, index: 0)
        enc.dispatch2D(kernels.gradientMap, width: region.width, height: region.height)
    }

    private func encodeSelective(_ enc: MTLComputeCommandEncoder, _ s: SelectiveColorSettings, _ source: MTLTexture,
                                 _ destination: MTLTexture, _ region: IntRect) {
        var p = AdjustmentGeomParams(geom: SIMD4(UInt32(region.x), UInt32(region.y), s.relative ? 1 : 0, 0))
        var adjustments = AdjustmentParameters.selectiveAdjustments(s)
        enc.setTexture(source, index: 0)
        enc.setTexture(destination, index: 1)
        enc.setBytes(&p, length: MemoryLayout<AdjustmentGeomParams>.stride, index: 0)
        enc.setBytes(&adjustments, length: adjustments.count * MemoryLayout<SIMD4<Float>>.stride, index: 1)
        enc.dispatch2D(kernels.selective, width: region.width, height: region.height)
    }

    // MARK: Resources

    private func makeLUTTexture(_ values: [SIMD4<Float>], label: String) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: values.count, height: 1, mipmapped: false)
        d.usage = .shaderRead
        #if os(macOS)
        d.storageMode = gpu.device.hasUnifiedMemory ? .shared : .managed     // discrete GPUs need a managed copy
        #else
        d.storageMode = .shared
        #endif
        let t = gpu.device.makeTexture(descriptor: d)!
        t.label = label
        values.withUnsafeBytes {
            t.replace(region: MTLRegionMake2D(0, 0, values.count, 1), mipmapLevel: 0, withBytes: $0.baseAddress!,
                      bytesPerRow: values.count * MemoryLayout<SIMD4<Float>>.stride)
        }
        return t
    }

    private func scratchSet(width: Int, height: Int, halo: AdjustmentHalo, needTemp: Bool) throws -> AdjustmentScratch {
        let set: AdjustmentScratch
        if let i = scratchSets.firstIndex(where: { $0.width == width && $0.height == height }) {
            set = scratchSets.remove(at: i)
        } else {
            set = try AdjustmentScratch(device: gpu.device, width: width, height: height, lowW: halo.lowW, lowH: halo.lowH)
        }
        scratchSets.append(set)
        if scratchSets.count > 3 { scratchSets.removeFirst() }
        if needTemp && set.temp == nil { try set.makeTemp(device: gpu.device) }
        return set
    }
}

// MARK: - Geometry of the reduced-resolution passes

/// How the canvas maps onto the reduced-resolution grid used by clarity and dehaze.
/// The factor grows with the canvas so the low-res Gaussian always has σ ≈ 4.6–9.2 low-res pixels.
private struct AdjustmentHalo {
    static let minRadius = 3          // dark-channel patch half-size in low-res pixels
    static let guideRadius = 4        // guided-filter window half-size in low-res pixels
    static let guideEpsilon: Float = 1.0e-3

    let width: Int, height: Int
    let factor: Int
    let lowW: Int, lowH: Int
    let sigmaLow: Float
    let blurRadius: Int

    init(width: Int, height: Int) {
        self.width = max(1, width); self.height = max(1, height)
        let longest = max(self.width, self.height)
        var f = 1
        while f < 16 && f * 2 <= longest / 384 { f *= 2 }
        factor = f
        lowW = (self.width + f - 1) / f
        lowH = (self.height + f - 1) / f
        let sigmaCanvas = max(4.0, 0.012 * Float(longest))
        sigmaLow = sigmaCanvas / Float(f)
        blurRadius = Int((3 * sigmaLow).rounded(.up))
    }

    /// Canvas pixels the clarity blur can reach from an output pixel.
    var clarityRadius: Int { factor * (blurRadius + 2) }

    /// The low-res rectangle needed to bilinearly sample every pixel of `r`.
    func lowRect(covering r: IntRect) -> AdjustmentLowRect {
        AdjustmentLowRect(x0: max(0, r.x / factor - 1), y0: max(0, r.y / factor - 1),
                x1: min(lowW, (r.maxX - 1) / factor + 2), y1: min(lowH, (r.maxY - 1) / factor + 2))
    }

    /// The canvas pixels covered by a low-res rectangle.
    func canvasRect(of l: AdjustmentLowRect) -> IntRect {
        IntRect(x: l.x0 * factor, y: l.y0 * factor, width: (l.x1 - l.x0) * factor, height: (l.y1 - l.y0) * factor)
    }
}

/// A half-open rectangle on the low-res grid.
private struct AdjustmentLowRect {
    var x0: Int, y0: Int, x1: Int, y1: Int
    var width: Int { max(0, x1 - x0) }
    var height: Int { max(0, y1 - y0) }
    var packed: SIMD4<UInt32> { SIMD4(UInt32(x0), UInt32(y0), UInt32(width), UInt32(height)) }
    func expanded(_ dx: Int, _ dy: Int, _ halo: AdjustmentHalo) -> AdjustmentLowRect {
        AdjustmentLowRect(x0: max(0, x0 - dx), y0: max(0, y0 - dy), x1: min(halo.lowW, x1 + dx), y1: min(halo.lowH, y1 + dy))
    }
}

/// Working textures for one canvas size.
private final class AdjustmentScratch {
    let width: Int, height: Int
    let lowA: MTLTexture, lowB: MTLTexture, lowC: MTLTexture
    var temp: MTLTexture?

    init(device: MTLDevice, width: Int, height: Int, lowW: Int, lowH: Int) throws {
        self.width = width; self.height = height
        func make(_ name: String) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: lowW, height: lowH, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { throw AdjustmentPipelineError.scratchAllocationFailed }
            t.label = "adjustment \(name)"
            return t
        }
        lowA = try make("lowA"); lowB = try make("lowB"); lowC = try make("lowC")
    }

    func makeTemp(device: MTLDevice) throws {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        guard let t = device.makeTexture(descriptor: d) else { throw AdjustmentPipelineError.scratchAllocationFailed }
        t.label = "adjustment temp"
        temp = t
    }
}

private struct AdjustmentLRU<Key: Equatable, Value> {
    let capacity: Int
    private var entries: [(key: Key, value: Value)] = []
    init(capacity: Int) { self.capacity = capacity }

    mutating func get(_ key: Key) -> Value? {
        guard let i = entries.firstIndex(where: { $0.key == key }) else { return nil }
        let e = entries.remove(at: i)
        entries.append(e)
        return e.value
    }

    mutating func put(_ key: Key, _ value: Value) {
        entries.append((key, value))
        if entries.count > capacity { entries.removeFirst() }
    }
}

// MARK: - Parameter blocks (layouts mirror the MSL structs: every member is 16 bytes)

private struct AdjustmentLowParams { var rect: SIMD4<UInt32>; var canvas: SIMD4<UInt32>; var misc: SIMD4<UInt32>; var fl: SIMD4<Float> }
private struct AdjustmentAtmosphereParams { var size: SIMD4<UInt32> }
private struct AdjustmentGeomParams { var geom: SIMD4<UInt32> }
private struct AdjustmentClarityParams { var geom: SIMD4<UInt32>; var fl: SIMD4<Float> }
private struct AdjustmentDevelopParams {
    var geom: SIMD4<UInt32>      // origin x, origin y, low-res factor, flags (bit 0: white balance on)
    var basic: SIMD4<Float>      // exposure gain, contrast, vibrance, saturation
    var tone: SIMD4<Float>       // shadows, highlights, whites, blacks
    var haze: SIMD4<Float>       // dehaze amount, omega, minimum transmission, unused
    var wb0: SIMD4<Float>, wb1: SIMD4<Float>, wb2: SIMD4<Float>
}
private struct AdjustmentGradingParams {
    var geom: SIMD4<UInt32>
    var range: SIMD4<Float>      // pivot, half width
    var lum: SIMD4<Float>        // shadows, midtones, highlights, global luminance
    var offS: SIMD4<Float>, offM: SIMD4<Float>, offH: SIMD4<Float>, offG: SIMD4<Float>
}

// MARK: - CPU-side parameter maths

private enum AdjustmentParameters {
    static let lutSize = 1024

    static func isIdentity(_ s: AdjustmentSettings) -> Bool {
        switch s.kind {
        case .develop: return s.develop == DevelopSettings()
        case .toneCurve:
            let c = s.curves
            return c.master.isIdentity && c.red.isIdentity && c.green.isIdentity && c.blue.isIdentity && c.luminance.isIdentity
        case .hsl:
            let h = s.hsl
            return (h.hue + h.saturation + h.luminance).allSatisfy { $0 == 0 }
        case .colorGrading:
            let g = s.grading
            return [g.shadows, g.midtones, g.highlights, g.global].allSatisfy { $0.saturation == 0 && $0.luminance == 0 }
        case .gradientMap: return false
        case .selectiveColor:
            return s.selectiveColor.ranges.allSatisfy { $0 == CMYKAdjustment() }
        }
    }

    private static func unit(_ v: Float) -> Float { max(-1, min(1, v / 100)) }

    static func develop(_ d: DevelopSettings, factor: Int, origin: IntRect) -> AdjustmentDevelopParams {
        let hasWB = d.temperature != 0 || d.tint != 0
        let wb = hasWB ? AdjustmentWhiteBalance.matrix(temperature: unit(d.temperature), tint: unit(d.tint)) : matrix_identity_float3x3
        return AdjustmentDevelopParams(
            geom: SIMD4(UInt32(origin.x), UInt32(origin.y), UInt32(factor), hasWB ? 1 : 0),
            basic: SIMD4(exp2(max(-10, min(10, d.exposure))), unit(d.contrast), unit(d.vibrance), unit(d.saturation)),
            tone: SIMD4(unit(d.shadows), unit(d.highlights), unit(d.whites), unit(d.blacks)),
            haze: SIMD4(unit(d.dehaze), 0.72, 0.4, 0),
            wb0: SIMD4(wb.columns.0, 0), wb1: SIMD4(wb.columns.1, 0), wb2: SIMD4(wb.columns.2, 0))
    }

    /// Lookup table for the tone curve: `rgba32Float`, `lutSize` × 1.
    /// RGB channels hold `channelCurve(master(x))`; alpha holds the luminance curve.
    static func curveLUT(_ c: ToneCurveSettings) -> [SIMD4<Float>] {
        let n = lutSize
        let master = c.master.lut(count: n)
        let fine = 4096
        func composed(_ curve: ResponseCurve) -> [Float] {
            if curve.isIdentity { return master }
            let table = curve.lut(count: fine)
            return master.map { m in
                let f = max(0, min(1, m)) * Float(fine - 1)
                let i = min(Int(f), fine - 2)
                let t = f - Float(i)
                return table[i] + (table[i + 1] - table[i]) * t
            }
        }
        let r = composed(c.red), g = composed(c.green), b = composed(c.blue)
        let l = c.luminance.lut(count: n)
        return (0..<n).map { SIMD4(r[$0], g[$0], b[$0], l[$0]) }
    }

    /// Gradient lookup table: straight RGBA, `lutSize` × 1, already reversed if requested.
    static func gradientLUT(_ g: GradientMapSettings) -> [SIMD4<Float>] {
        let stops = g.stops.sorted { $0.location < $1.location }
        let n = lutSize
        return (0..<n).map { i in
            var t = Float(i) / Float(n - 1)
            if g.reversed { t = 1 - t }
            guard let first = stops.first, let last = stops.last else { return SIMD4(t, t, t, 1) }
            if t <= first.location { return first.color }
            if t >= last.location { return last.color }
            for k in 0..<(stops.count - 1) where t <= stops[k + 1].location {
                let a = stops[k], b = stops[k + 1]
                let span = b.location - a.location
                let u = span > 1e-6 ? (t - a.location) / span : 1
                return a.color + (b.color - a.color) * u
            }
            return last.color
        }
    }

    /// 24 floats: hue[8], saturation[8], luminance[8], each scaled to −1…+1.
    static func hslBands(_ h: HSLSettings) -> [Float] {
        func eight(_ a: [Float]) -> [Float] { (0..<8).map { $0 < a.count ? unit(a[$0]) : 0 } }
        return eight(h.hue) + eight(h.saturation) + eight(h.luminance)
    }

    /// Nine (cyan, magenta, yellow, black) vectors scaled to −1…+1.
    static func selectiveAdjustments(_ s: SelectiveColorSettings) -> [SIMD4<Float>] {
        (0..<9).map { i in
            guard i < s.ranges.count else { return .zero }
            let a = s.ranges[i]
            return SIMD4(unit(a.cyan), unit(a.magenta), unit(a.yellow), unit(a.black))
        }
    }

    /// A colour offset with zero luminance in the direction of `hue`, scaled by saturation and `strength`.
    private static func wheelOffset(_ w: ColorWheel, strength: Float) -> SIMD4<Float> {
        let s = max(0, min(1, w.saturation / 100))
        guard s > 0 else { return .zero }
        let h = (w.hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        // hsv → rgb with s = v = 1
        func ch(_ n: Float) -> Float { max(0, min(1, abs((h * 6 + n).truncatingRemainder(dividingBy: 6) - 3) - 1)) }
        let rgb = SIMD3<Float>(ch(0), ch(4), ch(2))
        let luma = simd_dot(rgb, SIMD3<Float>(0.2289746, 0.6917385, 0.0792869))
        return SIMD4((rgb - luma) * s * strength, 0)
    }

    static func grading(_ g: ColorGradingSettings, origin: IntRect) -> AdjustmentGradingParams {
        let blending = max(0, min(1, g.blending / 100))
        let balance = unit(g.balance)
        return AdjustmentGradingParams(
            geom: SIMD4(UInt32(origin.x), UInt32(origin.y), 0, 0),
            range: SIMD4(0.5 - 0.25 * balance, 0.12 + 0.33 * blending, 0, 0),
            lum: SIMD4(unit(g.shadows.luminance), unit(g.midtones.luminance), unit(g.highlights.luminance), unit(g.global.luminance)),
            offS: wheelOffset(g.shadows, strength: 0.35), offM: wheelOffset(g.midtones, strength: 0.30),
            offH: wheelOffset(g.highlights, strength: 0.35), offG: wheelOffset(g.global, strength: 0.25))
    }
}

// MARK: - White balance

/// Temperature/tint as a von Kries adaptation in Bradford cone space.
///
/// The slider describes the illuminant the photo is *assumed* to have been lit by. Positive temperature
/// assumes a bluer illuminant (higher CCT, ±70 mired at ±100), so correcting for it warms the picture;
/// positive tint assumes a greener one (Δuv ±0.02 at ±100), so correcting for it adds magenta — matching
/// Lightroom's slider directions. Offsets are measured from the Display P3 white (D65), so zero is
/// exactly the identity. The result is one 3×3 matrix in linear Display P3, normalised to keep the
/// luminance of white.
private enum AdjustmentWhiteBalance {
    static let p3ToXYZ = simd_double3x3(columns: (SIMD3(0.4865709, 0.2289746, 0.0),
                                                  SIMD3(0.2656677, 0.6917385, 0.0451134),
                                                  SIMD3(0.1982173, 0.0792869, 1.0439444)))
    static let bradford = simd_double3x3(columns: (SIMD3(0.8951, -0.7502, 0.0389),
                                                   SIMD3(0.2664, 1.7135, -0.0685),
                                                   SIMD3(-0.1614, 0.0367, 1.0296)))

    /// CIE xy of the Planckian locus (Kim et al. cubic spline, 1667–25000 K).
    static func planckianXY(_ kelvin: Double) -> SIMD2<Double> {
        let t = min(max(kelvin, 1667), 25000)
        let x: Double
        if t <= 4000 {
            x = -0.2661239e9 / (t * t * t) - 0.2343589e6 / (t * t) + 0.8776956e3 / t + 0.179910
        } else {
            x = -3.0258469e9 / (t * t * t) + 2.1070379e6 / (t * t) + 0.2226347e3 / t + 0.240390
        }
        let y: Double
        if t <= 2222 {
            y = -1.1063814 * x * x * x - 1.34811020 * x * x + 2.18555832 * x - 0.20219683
        } else if t <= 4000 {
            y = -0.9549476 * x * x * x - 1.37418593 * x * x + 2.09137015 * x - 0.16748867
        } else {
            y = 3.0817580 * x * x * x - 5.87338670 * x * x + 3.75112997 * x - 0.37001483
        }
        return SIMD2(x, y)
    }

    static func uv(_ xy: SIMD2<Double>) -> SIMD2<Double> {
        let d = -2 * xy.x + 12 * xy.y + 3
        return SIMD2(4 * xy.x / d, 6 * xy.y / d)
    }

    static func xy(_ uv: SIMD2<Double>) -> SIMD2<Double> {
        let d = 2 * uv.x - 8 * uv.y + 4
        return SIMD2(3 * uv.x / d, 2 * uv.y / d)
    }

    /// `temperature` and `tint` are −1…+1. Returns a matrix on linear Display P3.
    static func matrix(temperature: Float, tint: Float) -> simd_float3x3 {
        let white = p3ToXYZ * SIMD3<Double>(1, 1, 1)                       // Y = 1
        let whiteXY = SIMD2(white.x / (white.x + white.y + white.z), white.y / (white.x + white.y + white.z))
        let mired0 = 1.0e6 / 6504.0
        let kelvin = 1.0e6 / (mired0 - 70.0 * Double(temperature))
        var assumedUV = uv(whiteXY) + (uv(planckianXY(kelvin)) - uv(planckianXY(6504.0)))
        assumedUV.y += 0.02 * Double(tint)
        let axy = xy(assumedUV)
        let assumed = SIMD3<Double>(axy.x / axy.y, 1, (1 - axy.x - axy.y) / axy.y)

        let lmsWhite = bradford * white
        let lmsAssumed = bradford * assumed
        let gains = lmsWhite / lmsAssumed
        let diag = simd_double3x3(diagonal: gains)
        var m = p3ToXYZ.inverse * bradford.inverse * diag * bradford * p3ToXYZ
        let w = m * SIMD3<Double>(1, 1, 1)
        let lum = 0.2289746 * w.x + 0.6917385 * w.y + 0.0792869 * w.z
        m = m * (1 / lum)
        return simd_float3x3(columns: (SIMD3<Float>(m.columns.0), SIMD3<Float>(m.columns.1), SIMD3<Float>(m.columns.2)))
    }
}

// MARK: - Kernels

private struct AdjustmentKernels {
    let atmosphere, dehazeDown, lowMin, dehazeGuide, dehazeSmooth, clarityDown, lowBlur: MTLComputePipelineState
    let develop, clarity, toneCurve, hsl, grading, gradientMap, selective: MTLComputePipelineState

    init(gpu: PaperGPU) throws {
        func k(_ name: String) throws -> MTLComputePipelineState { try gpu.pipeline(name, in: AdjustmentShader.self) }
        atmosphere = try k("adjAtmosphere"); dehazeDown = try k("adjDehazeDown"); lowMin = try k("adjLowMin")
        dehazeGuide = try k("adjDehazeGuide"); dehazeSmooth = try k("adjDehazeSmooth")
        clarityDown = try k("adjClarityDown"); lowBlur = try k("adjLowBlur")
        develop = try k("adjDevelop"); clarity = try k("adjClarity"); toneCurve = try k("adjToneCurve")
        hsl = try k("adjHSL"); grading = try k("adjGrading"); gradientMap = try k("adjGradientMap")
        selective = try k("adjSelective")
    }
}

private enum AdjustmentShader: ShaderModule {
    static let moduleName = "adjustment"

    static var source: String {
        let centers = HueBand.allCases.map { String(format: "%.1f", $0.centerDegrees) }.joined(separator: ", ")
        return "constant float kAdjBandCenters[8] = {\(centers)};\n" + body
    }

    private static let body = """
    constant float kAdjPivot = 0.46;          // mid-grey (18 % reflectance) in sRGB-encoded terms
    constant float kAdjKr = 0.2289746;
    constant float kAdjKg = 0.6917385;
    constant float kAdjKb = 0.0792869;

    struct AdjLowParams { uint4 rect; uint4 canvas; uint4 misc; float4 fl; };
    struct AdjAtmosphereParams { uint4 size; };
    struct AdjGeomParams { uint4 geom; };
    struct AdjClarityParams { uint4 geom; float4 fl; };
    struct AdjDevelopParams { uint4 geom; float4 basic; float4 tone; float4 haze; float4 wb0; float4 wb1; float4 wb2; };
    struct AdjGradingParams { uint4 geom; float4 range; float4 lum; float4 offS; float4 offM; float4 offH; float4 offG; };

    // ---------- helpers ----------

    inline float adjMax3(float3 c) { return max(max(c.r, c.g), c.b); }
    inline float adjMin3(float3 c) { return min(min(c.r, c.g), c.b); }

    /// NaN/Inf guard that survives fast-math, and a clamp into half-float range.
    inline float3 adjSane(float3 c) {
        uint3 b = as_type<uint3>(c);
        bool3 bad = (b & 0x7f800000u) == 0x7f800000u;
        return clamp(select(c, float3(0.0), bad), float3(-60000.0), float3(60000.0));
    }

    inline void adjStore(texture2d<float, access::write> dst, uint2 pix, float3 c, float a) {
        dst.write(float4(adjSane(c) * a, a), pix);
    }

    /// Bilinear read of a low-res texture at `p`, given in low-res pixel units (pixel centres at i + 0.5).
    inline float4 adjBilerp(texture2d<float, access::read> t, float2 p) {
        float2 q = p - 0.5;
        float2 fr = fract(q);
        int2 i0 = int2(floor(q));
        int2 hi = int2(t.get_width(), t.get_height()) - 1;
        int2 a = clamp(i0, int2(0), hi);
        int2 b = clamp(i0 + 1, int2(0), hi);
        float4 v00 = t.read(uint2(a.x, a.y));
        float4 v10 = t.read(uint2(b.x, a.y));
        float4 v01 = t.read(uint2(a.x, b.y));
        float4 v11 = t.read(uint2(b.x, b.y));
        return mix(mix(v00, v10, fr.x), mix(v01, v11, fr.x), fr.y);
    }

    /// Re-lights `c` (luma L0) so its luma becomes Ln0 while keeping hue.
    /// Darkening scales RGB by the luma ratio. Brightening scales too, but never past the gamut ceiling
    /// max(1, max channel); any remaining luma is made up by mixing toward that ceiling (adding white).
    /// Near black the ratio is unstable, so a flat grey offset (which also preserves hue) takes over.
    inline float3 adjRelight(float3 c, float L0, float Ln0) {
        float L = max(L0, 0.0);
        float Ln = max(Ln0, 0.0);
        if (abs(Ln - L) < 1.0e-7) return c;
        if (L < 1.0e-6) return c + (Ln - L0);
        if (Ln < L) return c * (Ln / L);
        float cmax = adjMax3(c);
        float top = max(1.0, cmax);
        float s = min(Ln / L, top / max(cmax, 1.0e-6));
        float3 c1 = c * s;
        float L1 = luma(c1);
        float k = saturate((Ln - L1) / max(top - L1, 1.0e-6));
        float3 scaled = mix(c1, float3(top), k);
        float3 added = c + (Ln - L);
        return mix(added, scaled, smoothstep(0.0, 0.08, L));
    }

    /// Scales chroma about luma by f. Boosts stop short of pushing any channel below zero.
    inline float3 adjScaleChroma(float3 c, float f) {
        float L = luma(c);
        float mn = adjMin3(c);
        float fe = f;
        if (f > 1.0) {
            if (mn >= 0.0 && L > mn) fe = min(f, L / (L - mn));
            else if (mn < 0.0) fe = 1.0;
        }
        return L + (c - L) * fe;
    }

    /// Pulls negative channels back to zero along the chroma axis, keeping luma.
    inline float3 adjFitGamut(float3 c) {
        float mn = adjMin3(c);
        if (mn >= 0.0) return c;
        float L = luma(c);
        if (L <= 0.0) return float3(0.0);
        return L + (c - L) * (L / (L - mn));
    }

    /// Y (luma) + scaled colour differences; rotating (U, V) rotates hue at constant luma and chroma.
    inline float3 adjToYUV(float3 c) {
        float Y = luma(c);
        return float3(Y, (c.b - Y) / (2.0 * (1.0 - kAdjKb)), (c.r - Y) / (2.0 * (1.0 - kAdjKr)));
    }
    inline float3 adjFromYUV(float3 yuv) {
        float Y = yuv.x;
        float B = Y + 2.0 * (1.0 - kAdjKb) * yuv.y;
        float R = Y + 2.0 * (1.0 - kAdjKr) * yuv.z;
        float G = (Y - kAdjKr * R - kAdjKb * B) / kAdjKg;
        return float3(R, G, B);
    }

    /// Contrast about mid-grey. Positive: a symmetric power S-curve (slope 1 + 0.9c at the pivot, flat at
    /// 0 and 1; values outside [0, 1] pass through). Negative: a straight slope reduction about the pivot.
    inline float adjContrast(float x, float cv) {
        if (cv < 0.0) return kAdjPivot + (x - kAdjPivot) * (1.0 + 0.7 * cv);
        if (x <= 0.0 || x >= 1.0) return x;
        float k = 1.0 + 0.9 * cv;
        if (x < kAdjPivot) return kAdjPivot * pow(x / kAdjPivot, k);
        return 1.0 - (1.0 - kAdjPivot) * pow((1.0 - x) / (1.0 - kAdjPivot), k);
    }

    /// 1-D LUT lookup (texture is N x 1) with linear interpolation and linear extension outside [0, 1].
    inline float adjLut(texture2d<float, access::read> lut, float x, uint ch) {
        int n = int(lut.get_width());
        float fx = x * float(n - 1);
        if (fx <= 0.0) {
            float y0 = lut.read(uint2(0, 0))[ch];
            float y1 = lut.read(uint2(1, 0))[ch];
            return y0 + fx * (y1 - y0);
        }
        if (fx >= float(n - 1)) {
            float yl = lut.read(uint2(n - 1, 0))[ch];
            float yp = lut.read(uint2(n - 2, 0))[ch];
            return yl + (fx - float(n - 1)) * (yl - yp);
        }
        int i = int(fx);
        float t = fx - float(i);
        return mix(lut.read(uint2(i, 0))[ch], lut.read(uint2(i + 1, 0))[ch], t);
    }

    inline float4 adjLut4(texture2d<float, access::read> lut, float x) {
        int n = int(lut.get_width());
        float fx = clamp(x, 0.0, 1.0) * float(n - 1);
        int i = min(int(fx), n - 2);
        return mix(lut.read(uint2(i, 0)), lut.read(uint2(i + 1, 0)), fx - float(i));
    }

    // ---------- dehaze: atmospheric light ----------

    /// One threadgroup scans a gridxgrid set of samples over the whole canvas. A sample's "dark" value is the
    /// minimum RGB channel over a small patch; the atmospheric light is the average colour of the samples whose
    /// dark value is within 10 % of the maximum (weighted by it).
    kernel void adjAtmosphere(texture2d<float, access::read> src [[texture(0)]],
                              device float4* outA [[buffer(0)]],
                              constant AdjAtmosphereParams& p [[buffer(1)]],
                              uint tid [[thread_index_in_threadgroup]],
                              uint threads [[threads_per_threadgroup]]) {
        threadgroup float tgMax[256];
        threadgroup float4 tgSum[256];
        const uint kMaxPer = 16;
        uint grid = p.size.z;
        uint total = grid * grid;
        int2 size = int2(p.size.x, p.size.y);
        int patch = int(p.size.w);

        float dark[kMaxPer];
        float3 col[kMaxPer];
        float localMax = 0.0;
        for (uint k = 0; k < kMaxPer; k++) {
            dark[k] = 0.0; col[k] = float3(0.0);
            uint idx = tid + k * threads;
            if (idx >= total) continue;
            float2 g = (float2(idx % grid, idx / grid) + 0.5) / float(grid);
            int2 centre = int2(g * float2(size));
            float4 cs = src.read(uint2(clamp(centre, int2(0), size - 1)));
            if (cs.a < 0.5) continue;
            float d = 1.0e9;
            for (int dy = -patch; dy <= patch; dy++) {
                for (int dx = -patch; dx <= patch; dx++) {
                    float4 v = src.read(uint2(clamp(centre + int2(dx, dy), int2(0), size - 1)));
                    if (v.a > 0.5) d = min(d, adjMin3(v.rgb / v.a));
                }
            }
            if (d > 1.0e8) continue;
            d = clamp(d, 0.0, 1.0);
            dark[k] = d;
            col[k] = clamp(cs.rgb / cs.a, float3(0.0), float3(1.5));
            localMax = max(localMax, d);
        }
        tgMax[tid] = localMax;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint s = threads / 2; s > 0; s >>= 1) {
            if (tid < s) tgMax[tid] = max(tgMax[tid], tgMax[tid + s]);
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        float dmax = tgMax[0];
        threadgroup_barrier(mem_flags::mem_threadgroup);

        float4 sum = float4(0.0);
        for (uint k = 0; k < kMaxPer; k++) {
            if (dark[k] > 0.0 && dark[k] >= 0.9 * dmax) sum += float4(col[k] * dark[k], dark[k]);
        }
        tgSum[tid] = sum;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint s = threads / 2; s > 0; s >>= 1) {
            if (tid < s) tgSum[tid] += tgSum[tid + s];
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        if (tid == 0) {
            float4 t = tgSum[0];
            float3 A = t.w > 1.0e-6 ? t.xyz / t.w : float3(0.9);
            A = clamp(A, float3(0.4), float3(1.0));
            // A strongly coloured atmosphere makes the recovery push single channels to zero; stay mostly neutral.
            A = mix(float3(luma(A)), A, 0.4);
            outA[0] = float4(A, 1.0);
        }
    }

    // ---------- dehaze: low-resolution maps ----------

    /// Per low-res pixel: (mean guide luma, block minimum of min_c(I_c / A_c)).
    kernel void adjDehazeDown(texture2d<float, access::read> src [[texture(0)]],
                              texture2d<float, access::write> dst [[texture(1)]],
                              device const float4* atmo [[buffer(0)]],
                              constant AdjLowParams& p [[buffer(1)]],
                              uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.rect.z || gid.y >= p.rect.w) return;
        uint2 low = p.rect.xy + gid;
        uint f = p.canvas.z;
        uint2 b0 = low * f;
        uint2 b1 = min(b0 + f, p.canvas.xy);
        float3 invA = 1.0 / max(atmo[0].xyz, float3(0.05));
        float sumI = 0.0, sumA = 0.0, pmin = 1.0;
        for (uint y = b0.y; y < b1.y; y++) {
            for (uint x = b0.x; x < b1.x; x++) {
                float4 s = src.read(uint2(x, y));
                if (s.a <= 1.0e-4) continue;
                float3 c = s.rgb / s.a;
                sumI += s.a * saturate(luma(c));
                sumA += s.a;
                pmin = min(pmin, saturate(adjMin3(c * invA)));
            }
        }
        dst.write(float4(sumA > 0.0 ? sumI / sumA : 0.0, pmin, 0.0, 0.0), low);
    }

    /// Separable minimum filter on the .g channel (the dark channel); .r passes through.
    kernel void adjLowMin(texture2d<float, access::read> src [[texture(0)]],
                          texture2d<float, access::write> dst [[texture(1)]],
                          constant AdjLowParams& p [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.rect.z || gid.y >= p.rect.w) return;
        uint2 pix = p.rect.xy + gid;
        int2 size = int2(src.get_width(), src.get_height());
        int2 dir = int2(p.misc.xy);
        int radius = int(p.misc.z);
        float4 centre = src.read(pix);
        float m = centre.g;
        for (int i = -radius; i <= radius; i++) {
            int2 q = clamp(int2(pix) + dir * i, int2(0), size - 1);
            m = min(m, src.read(uint2(q)).g);
        }
        dst.write(float4(centre.r, m, 0.0, 0.0), pix);
    }

    /// Fast guided filter step 1: per-window linear model p ~ a*I + b (I = guide luma, p = dark channel).
    kernel void adjDehazeGuide(texture2d<float, access::read> src [[texture(0)]],
                               texture2d<float, access::write> dst [[texture(1)]],
                               constant AdjLowParams& p [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.rect.z || gid.y >= p.rect.w) return;
        uint2 pix = p.rect.xy + gid;
        int2 size = int2(src.get_width(), src.get_height());
        int r = int(p.misc.x);
        float sI = 0.0, sP = 0.0, sIP = 0.0, sII = 0.0;
        for (int dy = -r; dy <= r; dy++) {
            for (int dx = -r; dx <= r; dx++) {
                float2 v = src.read(uint2(clamp(int2(pix) + int2(dx, dy), int2(0), size - 1))).xy;
                sI += v.x; sP += v.y; sIP += v.x * v.y; sII += v.x * v.x;
            }
        }
        float n = float((2 * r + 1) * (2 * r + 1));
        float mI = sI / n, mP = sP / n;
        float variance = max(sII / n - mI * mI, 0.0);
        float cov = sIP / n - mI * mP;
        float a = cov / (variance + p.fl.x);
        dst.write(float4(a, mP - a * mI, 0.0, 0.0), pix);
    }

    /// Fast guided filter step 2: average a and b over the window.
    kernel void adjDehazeSmooth(texture2d<float, access::read> src [[texture(0)]],
                                texture2d<float, access::write> dst [[texture(1)]],
                                constant AdjLowParams& p [[buffer(0)]],
                                uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.rect.z || gid.y >= p.rect.w) return;
        uint2 pix = p.rect.xy + gid;
        int2 size = int2(src.get_width(), src.get_height());
        int r = int(p.misc.x);
        float2 sum = float2(0.0);
        for (int dy = -r; dy <= r; dy++) {
            for (int dx = -r; dx <= r; dx++) {
                sum += src.read(uint2(clamp(int2(pix) + int2(dx, dy), int2(0), size - 1))).xy;
            }
        }
        float n = float((2 * r + 1) * (2 * r + 1));
        dst.write(float4(sum / n, 0.0, 0.0), pix);
    }

    // ---------- clarity: low-resolution luminance blur ----------

    /// Per low-res pixel: (mean of alpha*luma, mean alpha). Blurring both and dividing keeps transparent
    /// areas from darkening the blur.
    kernel void adjClarityDown(texture2d<float, access::read> src [[texture(0)]],
                               texture2d<float, access::write> dst [[texture(1)]],
                               constant AdjLowParams& p [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.rect.z || gid.y >= p.rect.w) return;
        uint2 low = p.rect.xy + gid;
        uint f = p.canvas.z;
        uint2 b0 = low * f;
        uint2 b1 = min(b0 + f, p.canvas.xy);
        float sumL = 0.0, sumA = 0.0;
        for (uint y = b0.y; y < b1.y; y++) {
            for (uint x = b0.x; x < b1.x; x++) {
                float4 s = src.read(uint2(x, y));
                if (s.a <= 1.0e-5) continue;
                sumL += s.a * clamp(luma(s.rgb / s.a), 0.0, 8.0);
                sumA += s.a;
            }
        }
        float n = float((b1.x - b0.x) * (b1.y - b0.y));
        dst.write(float4(sumL / n, sumA / n, 0.0, 0.0), low);
    }

    /// Separable Gaussian on all four channels, edge-clamped; weights from sigma = fl.x, radius = misc.z.
    kernel void adjLowBlur(texture2d<float, access::read> src [[texture(0)]],
                           texture2d<float, access::write> dst [[texture(1)]],
                           constant AdjLowParams& p [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= p.rect.z || gid.y >= p.rect.w) return;
        uint2 pix = p.rect.xy + gid;
        int2 size = int2(src.get_width(), src.get_height());
        int2 dir = int2(p.misc.xy);
        int radius = int(p.misc.z);
        float inv = -0.5 / (p.fl.x * p.fl.x);
        float4 acc = float4(0.0);
        float wsum = 0.0;
        for (int i = -radius; i <= radius; i++) {
            float w = exp(inv * float(i * i));
            acc += w * src.read(uint2(clamp(int2(pix) + dir * i, int2(0), size - 1)));
            wsum += w;
        }
        dst.write(acc / wsum, pix);
    }

    // ---------- develop ----------

    kernel void adjDevelop(texture2d<float, access::read> src [[texture(0)]],
                           texture2d<float, access::write> dst [[texture(1)]],
                           texture2d<float, access::read> hazeCoef [[texture(2)]],
                           device const float4* atmo [[buffer(0)]],
                           constant AdjDevelopParams& p [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
        uint2 pix = p.geom.xy + gid;
        if (pix.x >= src.get_width() || pix.y >= src.get_height()) return;
        float4 s = src.read(pix);
        if (s.a < 1.0e-5) { dst.write(s, pix); return; }
        float3 c = s.rgb / s.a;

        // Dehaze (dark-channel prior). Transmission is estimated from gamma-encoded values (as in the
        // original paper's code) and the haze removal itself is done in linear light.
        float dehaze = p.haze.x;
        if (dehaze != 0.0) {
            float3 A = atmo[0].xyz;
            float3 Alin = srgbToLinear(A);
            float3 lin = srgbToLinear(c);
            if (dehaze > 0.0) {
                float guide = saturate(luma(c));
                float2 ab = adjBilerp(hazeCoef, (float2(pix) + 0.5) / float(p.geom.z)).xy;
                float dp = saturate(ab.x * guide + ab.y);
                float t = max(1.0 - p.haze.y * dp, p.haze.z);
                // J = A + (I - A) / t, but values at or above the atmosphere level cannot have been dimmed
                // by haze, so they are left alone (fades in over +-0.08). This stops white objects blowing out.
                float3 x = lin - Alin;
                float3 gain = mix(float3(1.0 / t), float3(1.0), smoothstep(float3(-0.08), float3(0.08), x));
                float3 J = Alin + x * gain;
                // Dehaze may change brightness freely but may only boost chroma by 25 %; this keeps skin and
                // other pale subjects from turning neon and leaves neutral pixels neutral.
                float lj = luma(J), li = luma(lin);
                float3 cj = J - lj;
                float nj = length(cj), ni = length(lin - li);
                if (nj > 1.25 * ni + 1.0e-5) cj *= (1.25 * ni + 1.0e-5) / nj;
                J = max(lj + cj, float3(0.0));
                lin = mix(lin, J, dehaze);
            } else {
                lin = mix(lin, Alin, -dehaze * 0.45);
            }
            c = linearToSrgb(lin);
        }

        // Exposure (stops) and white balance, in linear light.
        bool hasWB = (p.geom.w & 1u) != 0u;
        if (p.basic.x != 1.0 || hasWB) {
            float3 lin = srgbToLinear(c);
            lin *= p.basic.x;
            if (hasWB) lin = float3x3(p.wb0.xyz, p.wb1.xyz, p.wb2.xyz) * lin;
            c = linearToSrgb(lin);
        }

        // Contrast.
        float cv = p.basic.y;
        if (cv != 0.0) c = float3(adjContrast(c.r, cv), adjContrast(c.g, cv), adjContrast(c.b, cv));

        // Highlights / shadows / whites / blacks, as luminance-masked changes that keep hue.
        if (any(p.tone != 0.0)) {
            float L = max(luma(c), 0.0);
            float wS = 1.0 - smoothstep(0.08, 0.60, L);
            float wH = smoothstep(0.35, 0.92, L);
            float wW = smoothstep(0.60, 1.05, L);
            float stops = p.tone.x * 0.7 * wS + p.tone.y * 0.7 * wH + p.tone.z * 0.5 * wW;
            float Ln = L * exp2(stops);
            if (p.tone.w != 0.0) Ln += p.tone.w * 0.10 * (1.0 - smoothstep(0.0, 0.4, Ln));
            c = adjRelight(c, L, Ln);
        }

        // Vibrance (weighted toward muted, non-skin colours) and saturation.
        float vib = p.basic.z, sat = p.basic.w;
        if (vib != 0.0 || sat != 0.0) {
            float f = 1.0 + sat;
            if (vib != 0.0) {
                float3 hsv = rgb2hsv(max(c, 0.0));
                float S = saturate(hsv.y);
                float dh = abs(fmod(hsv.x * 360.0 - 25.0 + 540.0, 360.0) - 180.0);
                float skin = 1.0 - smoothstep(15.0, 45.0, dh);
                float amount = vib > 0.0 ? vib * pow(1.0 - S, 1.5) * (1.0 - 0.6 * skin)
                                         : vib * (0.3 + 0.7 * S);
                f *= 1.0 + amount;
            }
            c = adjScaleChroma(c, max(f, 0.0));
        }

        adjStore(dst, pix, c, s.a);
    }

    /// Local contrast: adds a midtone-weighted fraction of (luma - blurred luma).
    kernel void adjClarity(texture2d<float, access::read> src [[texture(0)]],
                           texture2d<float, access::write> dst [[texture(1)]],
                           texture2d<float, access::read> blur [[texture(2)]],
                           constant AdjClarityParams& p [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
        uint2 pix = p.geom.xy + gid;
        if (pix.x >= src.get_width() || pix.y >= src.get_height()) return;
        float4 s = src.read(pix);
        if (s.a < 1.0e-5) { dst.write(s, pix); return; }
        float3 c = s.rgb / s.a;
        float L = max(luma(c), 0.0);
        float4 b = adjBilerp(blur, (float2(pix) + 0.5) / float(p.geom.z));
        float Lb = b.y > 1.0e-4 ? b.x / b.y : L;
        float lc = saturate(L);
        float wm = mix(0.2, 1.0, 4.0 * lc * (1.0 - lc));
        // Soft-limit the detail so a bright subject on a dark ground doesn't get a black outline.
        float detail = 0.15 * tanh((L - Lb) / 0.15);
        float Ln = L + p.fl.x * wm * detail;
        adjStore(dst, pix, adjRelight(c, L, Ln), s.a);
    }

    // ---------- tone curve ----------

    kernel void adjToneCurve(texture2d<float, access::read> src [[texture(0)]],
                             texture2d<float, access::write> dst [[texture(1)]],
                             texture2d<float, access::read> lut [[texture(2)]],
                             constant AdjGeomParams& p [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
        uint2 pix = p.geom.xy + gid;
        if (pix.x >= src.get_width() || pix.y >= src.get_height()) return;
        float4 s = src.read(pix);
        if (s.a < 1.0e-5) { dst.write(s, pix); return; }
        float3 c = s.rgb / s.a;
        if ((p.geom.z & 1u) != 0u) {
            c = float3(adjLut(lut, c.r, 0), adjLut(lut, c.g, 1), adjLut(lut, c.b, 2));
        }
        if ((p.geom.z & 2u) != 0u) {
            float L = luma(c);
            c = adjRelight(c, L, adjLut(lut, max(L, 0.0), 3));
        }
        adjStore(dst, pix, c, s.a);
    }

    // ---------- HSL ----------

    kernel void adjHSL(texture2d<float, access::read> src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       constant AdjGeomParams& p [[buffer(0)]],
                       constant float* bands [[buffer(1)]],      // hue[8], sat[8], lum[8], each -1...1
                       uint2 gid [[thread_position_in_grid]]) {
        uint2 pix = p.geom.xy + gid;
        if (pix.x >= src.get_width() || pix.y >= src.get_height()) return;
        float4 s = src.read(pix);
        if (s.a < 1.0e-5) { dst.write(s, pix); return; }
        float3 c = max(s.rgb / s.a, 0.0);

        float3 hsv = rgb2hsv(c);
        float hueDeg = fmod(hsv.x * 360.0, 360.0);
        int k = 7;
        for (int i = 0; i < 8; i++) { if (hueDeg >= kAdjBandCenters[i]) k = i; }
        int k1 = (k + 1) & 7;
        float c0 = kAdjBandCenters[k];
        float c1 = k == 7 ? 360.0 : kAdjBandCenters[k + 1];
        float t = (hueDeg - c0) / (c1 - c0);
        float w1 = 0.5 - 0.5 * cos(3.14159265 * t);      // raised cosine: weights sum to 1 across a segment
        float w0 = 1.0 - w1;
        float dh = w0 * bands[k] + w1 * bands[k1];
        float ds = w0 * bands[8 + k] + w1 * bands[8 + k1];
        float dl = w0 * bands[16 + k] + w1 * bands[16 + k1];

        // Near-grey pixels have no meaningful hue, so they are affected proportionally less.
        float reach = smoothstep(0.0, 0.3, hsv.y);
        dh *= reach; ds *= reach; dl *= reach;

        float3 out = c;
        if (dh != 0.0) {
            float3 yuv = adjToYUV(c);
            float ang = dh * 0.5235988;                    // +-30 degrees at +-100
            float cs = cos(ang), sn = sin(ang);
            out = adjFitGamut(adjFromYUV(float3(yuv.x, yuv.y * cs - yuv.z * sn, yuv.y * sn + yuv.z * cs)));
        }
        if (ds != 0.0) out = adjScaleChroma(out, max(1.0 + ds, 0.0));
        if (dl != 0.0) {
            float Y = luma(out);
            out = adjRelight(out, Y, Y * (dl > 0.0 ? 1.0 + 0.75 * dl : 1.0 + 0.9 * dl));
        }
        // Keep any extended-range excess the clamp above removed.
        adjStore(dst, pix, out + (s.rgb / s.a - c), s.a);
    }

    // ---------- colour grading ----------

    kernel void adjGrading(texture2d<float, access::read> src [[texture(0)]],
                           texture2d<float, access::write> dst [[texture(1)]],
                           constant AdjGradingParams& p [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
        uint2 pix = p.geom.xy + gid;
        if (pix.x >= src.get_width() || pix.y >= src.get_height()) return;
        float4 s = src.read(pix);
        if (s.a < 1.0e-5) { dst.write(s, pix); return; }
        float3 c = s.rgb / s.a;
        float L = max(luma(c), 0.0);

        // Range weights: a smooth shadows/highlights split around the balance pivot, midtones in between.
        float h = smoothstep(p.range.x - p.range.y, p.range.x + p.range.y, L);
        float3 w = float3(1.0 - h, 4.0 * h * (1.0 - h), h);

        // Lift (shadows), gamma (midtones), gain (highlights) and an overall exposure-like gain.
        if (any(p.lum != 0.0)) {
            float Ln = L + p.lum.x * 0.18 * w.x;
            float e = exp2(-p.lum.y * 0.6);
            Ln = mix(Ln, pow(max(Ln, 1.0e-5), e), w.y);
            Ln *= (1.0 + p.lum.z * 0.4 * w.z) * exp2(p.lum.w * 0.5);
            c = adjRelight(c, L, Ln);
        }
        // Colour: zero-luma offsets per range.
        float3 off = p.offS.xyz * w.x + p.offM.xyz * w.y + p.offH.xyz * w.z + p.offG.xyz;
        if (any(off != 0.0)) {
            bool inGamut = adjMin3(c) >= 0.0;
            c += off;
            if (inGamut) c = adjFitGamut(c);
        }
        adjStore(dst, pix, c, s.a);
    }

    // ---------- gradient map ----------

    kernel void adjGradientMap(texture2d<float, access::read> src [[texture(0)]],
                               texture2d<float, access::write> dst [[texture(1)]],
                               texture2d<float, access::read> lut [[texture(2)]],
                               constant AdjGeomParams& p [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]]) {
        uint2 pix = p.geom.xy + gid;
        if (pix.x >= src.get_width() || pix.y >= src.get_height()) return;
        float4 s = src.read(pix);
        if (s.a < 1.0e-5) { dst.write(s, pix); return; }
        float L = saturate(luma(s.rgb / s.a));
        float4 g = adjLut4(lut, L);
        adjStore(dst, pix, g.rgb, s.a * saturate(g.a));
    }

    // ---------- selective colour (Photoshop's algorithm) ----------

    kernel void adjSelective(texture2d<float, access::read> src [[texture(0)]],
                             texture2d<float, access::write> dst [[texture(1)]],
                             constant AdjGeomParams& p [[buffer(0)]],
                             constant float4* adj [[buffer(1)]],     // 9 ranges: C, M, Y, K in -1...1
                             uint2 gid [[thread_position_in_grid]]) {
        uint2 pix = p.geom.xy + gid;
        if (pix.x >= src.get_width() || pix.y >= src.get_height()) return;
        float4 s = src.read(pix);
        if (s.a < 1.0e-5) { dst.write(s, pix); return; }
        float3 straight = s.rgb / s.a;
        float3 c = saturate(straight);
        float3 excess = straight - c;

        float mx = adjMax3(c), mn = adjMin3(c);
        float mid = c.r + c.g + c.b - mx - mn;
        // Any colour is  min*white + (mid - min)*secondary + (max - mid)*primary.
        // Ranges: 0 reds, 1 yellows, 2 greens, 3 cyans, 4 blues, 5 magentas, 6 whites, 7 neutrals, 8 blacks.
        float4 total = float4(0.0);
        float wp = mx - mid, ws = mid - mn;
        int primary, secondary;
        if (c.r >= c.g && c.r >= c.b)      { primary = 0; secondary = c.g >= c.b ? 1 : 5; }
        else if (c.g >= c.b)               { primary = 2; secondary = c.r >= c.b ? 1 : 3; }
        else                               { primary = 4; secondary = c.r >= c.g ? 5 : 3; }
        total += wp * adj[primary] + ws * adj[secondary];
        total += mn * adj[6];
        total += max(1.0 - (abs(mx - 0.5) + abs(mn - 0.5)), 0.0) * adj[7];
        total += (1.0 - mx) * adj[8];

        // RGB -> CMYK with K = 1 - max, then Photoshop's Relative (percentage of existing ink) or Absolute.
        float K = 1.0 - mx;
        float3 cmy = mx > 1.0e-6 ? (mx - c) / mx : float3(0.0);
        bool relative = p.geom.z != 0u;
        float3 cmy2 = relative ? cmy * (1.0 + total.xyz) : cmy + total.xyz;
        float K2 = relative ? K * (1.0 + total.w) : K + total.w;
        cmy2 = saturate(cmy2);
        K2 = saturate(K2);
        float3 outc = (1.0 - cmy2) * (1.0 - K2);
        adjStore(dst, pix, outc + excess, s.a);
    }
    """
}
