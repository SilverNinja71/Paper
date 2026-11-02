import Foundation
import Metal
import simd

/// A Metal shader module: Metal Shading Language source compiled at runtime.
///
/// The machine this was written on only has the Command Line Tools (no offline `metal` compiler),
/// so every shader lives in a Swift string and is compiled once, then cached by `PaperGPU`.
public protocol ShaderModule {
    static var moduleName: String { get }
    static var source: String { get }
}

/// Owns the Metal device, the command queue, compiled shaders and shared helper resources.
public final class PaperGPU {
    public enum GPUError: Error, LocalizedError {
        case noDevice
        case missingFunction(String)
        case outOfMemory(String)

        public var errorDescription: String? {
            switch self {
            case .noDevice: return "This Mac has no Metal-capable graphics card."
            case .missingFunction(let name): return "Shader function \(name) is missing."
            case .outOfMemory(let what): return "Not enough graphics memory for \(what)."
            }
        }
    }

    public let device: MTLDevice
    public let queue: MTLCommandQueue
    public let linearClamp: MTLSamplerState
    public let linearRepeat: MTLSamplerState
    public let nearestClamp: MTLSamplerState
    /// 1×1 transparent textures bound to shader slots a pass doesn't use (Metal dislikes unbound slots).
    public let dummyColor: MTLTexture
    public let dummyMask: MTLTexture

    private var libraries: [String: MTLLibrary] = [:]
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private let lock = NSLock()

    /// The app-wide GPU. Every Mac and iPad that runs macOS 14 / iPadOS 17 has Metal.
    public static let shared: PaperGPU = {
        do { return try PaperGPU() } catch { fatalError("Paper needs Metal: \(error.localizedDescription)") }
    }()

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device, let queue = device.makeCommandQueue() else { throw GPUError.noDevice }
        self.device = device
        self.queue = queue
        queue.label = "Paper"

        func sampler(_ filter: MTLSamplerMinMagFilter, _ address: MTLSamplerAddressMode, mip: Bool) -> MTLSamplerState {
            let d = MTLSamplerDescriptor()
            d.minFilter = filter
            d.magFilter = filter
            d.mipFilter = mip ? .linear : .notMipmapped
            d.sAddressMode = address
            d.tAddressMode = address
            d.normalizedCoordinates = true
            return device.makeSamplerState(descriptor: d)!
        }
        linearClamp = sampler(.linear, .clampToZero, mip: true)
        linearRepeat = sampler(.linear, .repeat, mip: true)
        nearestClamp = sampler(.nearest, .clampToEdge, mip: false)

        func tiny(_ format: MTLPixelFormat) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 1, height: 1, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        dummyColor = tiny(.rgba16Float)
        dummyMask = tiny(.r16Float)
        dummyColor.label = "dummy color"
        dummyMask.label = "dummy mask"
        // Private textures start with undefined contents; make the dummies transparent.
        if let cb = queue.makeCommandBuffer() {
            clear(dummyColor, in: cb)
            clear(dummyMask, in: cb)
            cb.commit()
        }
    }

    // MARK: Shaders

    public func library<M: ShaderModule>(_ module: M.Type) throws -> MTLLibrary {
        lock.lock(); defer { lock.unlock() }
        if let lib = libraries[M.moduleName] { return lib }
        let options = MTLCompileOptions()
        options.languageVersion = .version2_4
        let lib = try device.makeLibrary(source: ShaderCommon.source + "\n" + M.source, options: options)
        lib.label = M.moduleName
        libraries[M.moduleName] = lib
        return lib
    }

    /// A cached compute pipeline for `function` in `module`.
    public func pipeline<M: ShaderModule>(_ function: String, in module: M.Type) throws -> MTLComputePipelineState {
        let key = M.moduleName + "." + function
        lock.lock()
        if let p = pipelines[key] { lock.unlock(); return p }
        lock.unlock()
        let lib = try library(module)
        guard let fn = lib.makeFunction(name: function) else { throw GPUError.missingFunction(key) }
        let p = try device.makeComputePipelineState(function: fn)
        lock.lock(); pipelines[key] = p; lock.unlock()
        return p
    }

    // MARK: Textures

    /// A GPU-only texture. Layers are `rgba16Float` holding premultiplied, gamma-encoded Display P3
    /// colour (values above 1 are allowed for HDR); masks and selections are `r16Float`.
    public func makeTexture(width: Int, height: Int, format: MTLPixelFormat = .rgba16Float,
                            label: String, mipmapped: Bool = false) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(1, width),
                                                         height: max(1, height), mipmapped: mipmapped)
        d.usage = [.shaderRead, .shaderWrite, .renderTarget]
        d.storageMode = .private
        guard let t = device.makeTexture(descriptor: d) else { throw GPUError.outOfMemory(label) }
        t.label = label
        return t
    }

    /// Fills `texture` (or just `region`) with a constant colour.
    public func clear(_ texture: MTLTexture, region: IntRect? = nil, to color: SIMD4<Float> = .zero,
                      in commandBuffer: MTLCommandBuffer) {
        let r = region ?? IntRect(x: 0, y: 0, width: texture.width, height: texture.height)
        guard !r.isEmpty, let enc = commandBuffer.makeComputeCommandEncoder(),
              let p = try? pipeline("fillRegion", in: UtilityShader.self) else { return }
        var params = FillParams(origin: r.origin32, color: color)
        enc.setTexture(texture, index: 0)
        enc.setBytes(&params, length: MemoryLayout<FillParams>.stride, index: 0)
        enc.dispatch2D(p, width: r.width, height: r.height)
        enc.endEncoding()
    }

    /// Copies `region` of `source` into `destination` at `destinationOrigin` (same pixel format).
    public func copy(_ source: MTLTexture, region: IntRect, to destination: MTLTexture,
                     at destinationOrigin: SIMD2<Int>? = nil, in commandBuffer: MTLCommandBuffer) {
        guard !region.isEmpty, let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        let o = destinationOrigin ?? SIMD2(region.x, region.y)
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: region.x, y: region.y, z: 0),
                  sourceSize: MTLSize(width: region.width, height: region.height, depth: 1),
                  to: destination, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: o.x, y: o.y, z: 0))
        blit.endEncoding()
    }

    /// Runs `body` with a fresh command buffer, commits it and waits until the GPU is done.
    @discardableResult
    public func run<T>(_ label: String, _ body: (MTLCommandBuffer) throws -> T) rethrows -> T {
        let cb = queue.makeCommandBuffer()!
        cb.label = label
        let result = try body(cb)
        cb.commit()
        cb.waitUntilCompleted()
        return result
    }

    // MARK: CPU ↔ GPU transfer

    /// Reads `region` of a texture back as RGBA floats (row-major, top row first). Single-channel
    /// textures return their value in `.x`.
    public func readPixels(_ texture: MTLTexture, region: IntRect? = nil) -> [SIMD4<Float>] {
        let r = region ?? IntRect(x: 0, y: 0, width: texture.width, height: texture.height)
        let count = r.width * r.height
        guard count > 0, let buffer = device.makeBuffer(length: count * 16, options: .storageModeShared),
              let p = try? pipeline("exportFloat4", in: UtilityShader.self) else { return [] }
        run("readPixels") { cb in
            let enc = cb.makeComputeCommandEncoder()!
            var params = TransferParams(origin: r.origin32, width: UInt32(r.width))
            enc.setTexture(texture, index: 0)
            enc.setBuffer(buffer, offset: 0, index: 0)
            enc.setBytes(&params, length: MemoryLayout<TransferParams>.stride, index: 1)
            enc.dispatch2D(p, width: r.width, height: r.height)
            enc.endEncoding()
        }
        let ptr = buffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        return Array(UnsafeBufferPointer(start: ptr, count: count))
    }

    /// Writes RGBA floats into `region` of a texture (inverse of `readPixels`).
    public func writePixels(_ pixels: [SIMD4<Float>], to texture: MTLTexture, region: IntRect? = nil) {
        let r = region ?? IntRect(x: 0, y: 0, width: texture.width, height: texture.height)
        guard pixels.count >= r.width * r.height, !r.isEmpty,
              let p = try? pipeline("importFloat4", in: UtilityShader.self) else { return }
        let buffer = pixels.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: r.width * r.height * 16,
                                                                options: .storageModeShared)! }
        run("writePixels") { cb in
            let enc = cb.makeComputeCommandEncoder()!
            var params = TransferParams(origin: r.origin32, width: UInt32(r.width))
            enc.setTexture(texture, index: 0)
            enc.setBuffer(buffer, offset: 0, index: 0)
            enc.setBytes(&params, length: MemoryLayout<TransferParams>.stride, index: 1)
            enc.dispatch2D(p, width: r.width, height: r.height)
            enc.endEncoding()
        }
    }

    /// Raw half-float bytes of a whole texture (4 channels for colour, 1 for masks) — the on-disk layer format.
    public func readHalfData(_ texture: MTLTexture) -> Data {
        let channels = texture.pixelFormat == .r16Float ? 1 : 4
        let count = texture.width * texture.height
        let length = count * channels * 2
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared),
              let p = try? pipeline(channels == 1 ? "exportHalf1" : "exportHalf4", in: UtilityShader.self) else { return Data() }
        run("readHalf") { cb in
            let enc = cb.makeComputeCommandEncoder()!
            var params = TransferParams(origin: .zero, width: UInt32(texture.width))
            enc.setTexture(texture, index: 0)
            enc.setBuffer(buffer, offset: 0, index: 0)
            enc.setBytes(&params, length: MemoryLayout<TransferParams>.stride, index: 1)
            enc.dispatch2D(p, width: texture.width, height: texture.height)
            enc.endEncoding()
        }
        return Data(bytes: buffer.contents(), count: length)
    }

    /// Inverse of `readHalfData`. Returns false if `data` has the wrong size.
    @discardableResult
    public func writeHalfData(_ data: Data, to texture: MTLTexture) -> Bool {
        let channels = texture.pixelFormat == .r16Float ? 1 : 4
        guard data.count == texture.width * texture.height * channels * 2,
              let p = try? pipeline(channels == 1 ? "importHalf1" : "importHalf4", in: UtilityShader.self),
              let buffer = data.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: data.count,
                                                                     options: .storageModeShared) }) else { return false }
        run("writeHalf") { cb in
            let enc = cb.makeComputeCommandEncoder()!
            var params = TransferParams(origin: .zero, width: UInt32(texture.width))
            enc.setTexture(texture, index: 0)
            enc.setBuffer(buffer, offset: 0, index: 0)
            enc.setBytes(&params, length: MemoryLayout<TransferParams>.stride, index: 1)
            enc.dispatch2D(p, width: texture.width, height: texture.height)
            enc.endEncoding()
        }
        return true
    }
}

// MARK: - Dispatch helper

extension MTLComputeCommandEncoder {
    /// Dispatches one thread per pixel of a `width × height` grid.
    public func dispatch2D(_ pipeline: MTLComputePipelineState, width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        setComputePipelineState(pipeline)
        let w = pipeline.threadExecutionWidth
        let h = max(1, min(16, pipeline.maxTotalThreadsPerThreadgroup / w))
        dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    }
}

// MARK: - Integer rectangles

/// A pixel rectangle on the canvas (origin top-left, y down).
public struct IntRect: Equatable, Hashable, Codable, Sendable {
    public var x: Int, y: Int, width: Int, height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = max(0, width); self.height = max(0, height)
    }

    public static let empty = IntRect(x: 0, y: 0, width: 0, height: 0)
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var area: Int { width * height }
    var origin32: SIMD2<UInt32> { SIMD2(UInt32(max(0, x)), UInt32(max(0, y))) }

    /// The smallest integer rectangle containing a float rectangle.
    public init(covering minPoint: SIMD2<Float>, _ maxPoint: SIMD2<Float>) {
        let x0 = Int(floor(minPoint.x)), y0 = Int(floor(minPoint.y))
        let x1 = Int(ceil(maxPoint.x)), y1 = Int(ceil(maxPoint.y))
        self.init(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    public func union(_ o: IntRect) -> IntRect {
        if isEmpty { return o }
        if o.isEmpty { return self }
        let x0 = min(x, o.x), y0 = min(y, o.y)
        return IntRect(x: x0, y: y0, width: max(maxX, o.maxX) - x0, height: max(maxY, o.maxY) - y0)
    }

    public func intersection(_ o: IntRect) -> IntRect {
        let x0 = max(x, o.x), y0 = max(y, o.y)
        let x1 = min(maxX, o.maxX), y1 = min(maxY, o.maxY)
        return x1 > x0 && y1 > y0 ? IntRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0) : .empty
    }

    public func insetBy(_ d: Int) -> IntRect { IntRect(x: x + d, y: y + d, width: width - 2 * d, height: height - 2 * d) }
    public func clamped(width w: Int, height h: Int) -> IntRect { intersection(IntRect(x: 0, y: 0, width: w, height: h)) }
}

// MARK: - Parameter structs shared with UtilityShader (layouts must match the MSL structs)

struct FillParams {
    var origin: SIMD2<UInt32>
    var pad: SIMD2<UInt32> = .zero
    var color: SIMD4<Float>
    init(origin: SIMD2<UInt32>, color: SIMD4<Float>) { self.origin = origin; self.color = color }
}

struct TransferParams {
    var origin: SIMD2<UInt32>
    var width: UInt32
    var pad: UInt32 = 0
}
