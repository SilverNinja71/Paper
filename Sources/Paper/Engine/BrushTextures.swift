import Foundation
import Metal
import CoreGraphics
import ImageIO
import simd

/// Generates the built-in brush shapes and grains procedurally (no bundled image files, so every
/// built-in brush is free and tiny), and converts custom PNG tips to greyscale.
public enum BrushTextureLibrary {
    /// Side length of every tip/grain texture.
    public static let size = 256

    public static let tipNames = ["pencil", "charcoal", "chalk", "splatter", "bristle", "flat", "square", "star",
                                  "sparkle", "ink-rough", "cloud", "halftone-dot", "leaf"]
    public static let grainNames = ["paper", "canvas", "rough", "fine", "watercolor", "halftone", "noise", "linen"]

    /// Greyscale pixels (white = paint), `size × size`, row-major.
    public static func pixels(for tip: BrushTip) -> [UInt8]? {
        switch tip {
        case .round: return nil
        case .builtin(let name): return generate(name)
        case .image(let data): return decodeGray(data)
        }
    }

    // MARK: Noise

    private static func hash(_ x: Int32, _ y: Int32, _ seed: Int32) -> Float {
        var h = UInt32(bitPattern: x &* 374_761_393 &+ y &* 668_265_263 &+ seed &* 1_442_695_041)
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Float(h & 0xFFFF) / 65535
    }

    /// Tileable value noise with period `period` (in lattice cells).
    private static func valueNoise(_ x: Float, _ y: Float, period: Int32, seed: Int32) -> Float {
        let xi = Int32(floor(x)), yi = Int32(floor(y))
        let fx = x - floor(x), fy = y - floor(y)
        func h(_ a: Int32, _ b: Int32) -> Float {
            hash(((a % period) + period) % period, ((b % period) + period) % period, seed)
        }
        let ux = fx * fx * (3 - 2 * fx), uy = fy * fy * (3 - 2 * fy)
        let a = h(xi, yi), b = h(xi + 1, yi), c = h(xi, yi + 1), d = h(xi + 1, yi + 1)
        let top = a + (b - a) * ux
        let bottom = c + (d - c) * ux
        return top + (bottom - top) * uy
    }

    /// Tileable fractal noise in [0, 1] over a `size`-pixel square.
    private static func fbm(_ px: Int, _ py: Int, baseCells: Int32, octaves: Int, seed: Int32, gain: Float = 0.5) -> Float {
        var sum: Float = 0, amp: Float = 1, norm: Float = 0
        var cells = baseCells
        for o in 0..<octaves {
            let x = Float(px) / Float(size) * Float(cells)
            let y = Float(py) / Float(size) * Float(cells)
            sum += amp * valueNoise(x, y, period: cells, seed: seed &+ Int32(o) &* 31)
            norm += amp
            amp *= gain
            cells *= 2
        }
        return sum / norm
    }

    private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func render(_ f: (Float, Float, Int, Int) -> Float) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                let u = (Float(x) + 0.5) / Float(size) * 2 - 1
                let v = (Float(y) + 0.5) / Float(size) * 2 - 1
                out[y * size + x] = UInt8(min(max(f(u, v, x, y), 0), 1) * 255)
            }
        }
        return out
    }

    // MARK: Generators

    static func generate(_ name: String) -> [UInt8]? {
        switch name {
        // ---- Tips
        case "pencil":
            return render { u, v, x, y in
                let r = (u * u + v * v).squareRoot()
                let disc = 1 - smoothstep(0.75, 1, r)
                let grain = fbm(x, y, baseCells: 64, octaves: 2, seed: 11)
                return disc * smoothstep(0.25, 0.75, grain + 0.15)
            }
        case "charcoal":
            return render { u, v, x, y in
                let wobble = fbm(x, y, baseCells: 6, octaves: 3, seed: 3) * 0.45
                let r = (u * u + v * v).squareRoot() + wobble - 0.2
                let body = 1 - smoothstep(0.55, 0.95, r)
                let tooth = fbm(x, y, baseCells: 48, octaves: 3, seed: 5)
                return body * smoothstep(0.3, 0.7, tooth)
            }
        case "chalk":
            return render { u, v, x, y in
                let r = max(abs(u) * 0.9, abs(v)) + fbm(x, y, baseCells: 8, octaves: 2, seed: 9) * 0.25
                let body = 1 - smoothstep(0.7, 0.95, r)
                return body * smoothstep(0.42, 0.6, fbm(x, y, baseCells: 64, octaves: 2, seed: 13))
            }
        case "splatter":
            var rng = SplitMix64(seed: 77)
            var dots: [(SIMD2<Float>, Float)] = []
            for _ in 0..<60 {
                let a = rng.unit() * 2 * .pi
                let d = pow(rng.unit(), 0.7) * 0.85
                dots.append((SIMD2(cos(a) * d, sin(a) * d), 0.02 + pow(rng.unit(), 3) * 0.14))
            }
            return render { u, v, _, _ in
                var a: Float = 0
                for (c, r) in dots {
                    let d = simd_distance(SIMD2(u, v), c)
                    a = max(a, 1 - smoothstep(r * 0.8, r, d))
                }
                return a
            }
        case "bristle":
            var rng = SplitMix64(seed: 21)
            var hairs: [(SIMD2<Float>, Float, Float)] = []
            for _ in 0..<90 {
                let a = rng.unit() * 2 * .pi
                let d = rng.unit().squareRoot() * 0.9
                hairs.append((SIMD2(cos(a) * d, sin(a) * d), 0.04 + rng.unit() * 0.05, 0.5 + rng.unit() * 0.5))
            }
            return render { u, v, _, _ in
                var a: Float = 0
                for (c, r, w) in hairs {
                    let d = simd_distance(SIMD2(u, v), c)
                    a = max(a, (1 - smoothstep(r * 0.5, r, d)) * w)
                }
                return a
            }
        case "flat":
            return render { u, v, x, _ in
                let body = (1 - smoothstep(0.85, 1, abs(u))) * (1 - smoothstep(0.18, 0.3, abs(v)))
                let streak = 0.75 + 0.25 * fbm(x, 0, baseCells: 64, octaves: 2, seed: 8)
                return body * streak
            }
        case "square":
            return render { u, v, _, _ in (1 - smoothstep(0.86, 0.9, abs(u))) * (1 - smoothstep(0.86, 0.9, abs(v))) }
        case "star":
            return render { u, v, _, _ in
                let a = atan2(v, u), r = (u * u + v * v).squareRoot()
                let k = cos(5 * a) * 0.5 + 0.5
                let edge = 0.42 + 0.5 * pow(k, 3)
                return 1 - smoothstep(edge - 0.03, edge, r)
            }
        case "sparkle":
            return render { u, v, _, _ in
                let cross = max(exp(-abs(u) * 30) * exp(-abs(v) * 2.2), exp(-abs(v) * 30) * exp(-abs(u) * 2.2))
                let glow = exp(-(u * u + v * v) * 12)
                return min(1, cross + glow)
            }
        case "ink-rough":
            return render { u, v, x, y in
                let r = (u * u + v * v).squareRoot() + (fbm(x, y, baseCells: 16, octaves: 3, seed: 17) - 0.5) * 0.18
                return 1 - smoothstep(0.82, 0.88, r)
            }
        case "cloud":
            return render { u, v, x, y in
                let r = (u * u + v * v).squareRoot()
                let falloff = 1 - smoothstep(0.2, 1, r)
                return falloff * (0.55 + 0.45 * fbm(x, y, baseCells: 4, octaves: 4, seed: 23))
            }
        case "halftone-dot":
            return render { u, v, _, _ in
                let r = (u * u + v * v).squareRoot()
                guard r < 0.95 else { return 0 }
                let cell: Float = 0.2
                let gx = (u / cell).rounded() * cell, gy = (v / cell).rounded() * cell
                let d = simd_distance(SIMD2(u, v), SIMD2(gx, gy))
                return 1 - smoothstep(cell * 0.38, cell * 0.45, d)
            }
        case "leaf":
            return render { u, v, _, _ in
                let w = 0.45 * (1 - v * v)
                return (1 - smoothstep(w - 0.04, w, abs(u))) * (1 - smoothstep(0.92, 0.97, abs(v)))
            }
        // ---- Grains (tileable)
        case "paper":
            return render { _, _, x, y in 0.35 + 0.65 * fbm(x, y, baseCells: 32, octaves: 4, seed: 101) }
        case "canvas":
            return render { _, _, x, y in
                let fx = Float(x) / Float(size) * 32 * .pi, fy = Float(y) / Float(size) * 32 * .pi
                let weave = 0.5 + 0.25 * sin(fx) * cos(fy) + 0.25 * sin(fx + fy)
                return 0.4 + 0.45 * weave + 0.15 * fbm(x, y, baseCells: 64, octaves: 2, seed: 103)
            }
        case "rough":
            return render { _, _, x, y in smoothstep(0.3, 0.7, fbm(x, y, baseCells: 16, octaves: 5, seed: 105)) }
        case "fine":
            return render { _, _, x, y in 0.5 + 0.5 * fbm(x, y, baseCells: 128, octaves: 1, seed: 107) }
        case "watercolor":
            return render { _, _, x, y in 0.55 + 0.45 * fbm(x, y, baseCells: 4, octaves: 5, seed: 109, gain: 0.6) }
        case "halftone":
            return render { _, _, x, y in
                let cell = 16
                let cx = Float(x % cell) - Float(cell) / 2 + 0.5, cy = Float(y % cell) - Float(cell) / 2 + 0.5
                let d = (cx * cx + cy * cy).squareRoot()
                return 1 - smoothstep(4.5, 5.5, d)
            }
        case "noise":
            return render { _, _, x, y in hash(Int32(x), Int32(y), 111) }
        case "linen":
            return render { _, _, x, y in
                let h = fbm(x, 0, baseCells: 128, octaves: 2, seed: 113)
                let v = fbm(0, y, baseCells: 128, octaves: 2, seed: 115)
                return 0.35 + 0.65 * (h * 0.5 + v * 0.5)
            }
        default:
            return nil
        }
    }

    /// Decodes a PNG (or any ImageIO format) into `size × size` greyscale, centred, aspect kept.
    static func decodeGray(_ data: Data) -> [UInt8]? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return grayPixels(from: image)
    }

    static func grayPixels(from image: CGImage) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: size * size)
        guard let ctx = CGContext(data: &out, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let scale = CGFloat(size) / CGFloat(max(image.width, image.height))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: (CGFloat(size) - w) / 2, y: (CGFloat(size) - h) / 2, width: w, height: h))
        return out
    }

    /// Encodes greyscale pixels (`size × size`) as PNG data — used to store imported tips in presets.
    public static func pngData(gray: [UInt8], width: Int = size, height: Int = size) -> Data? {
        guard gray.count == width * height else { return nil }
        let data = NSMutableData()
        var copy = gray
        guard let provider = CGDataProvider(data: Data(bytes: &copy, count: copy.count) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

/// Uploads brush tips and grains to the GPU once and keeps them (mipmapped `r8Unorm`, 256²).
public final class BrushTextureCache {
    private let gpu: PaperGPU
    private var cache: [BrushTip: MTLTexture] = [:]
    public let white: MTLTexture

    public init(gpu: PaperGPU) {
        self.gpu = gpu
        white = Self.upload([UInt8](repeating: 255, count: 4 * 4), side: 4, gpu: gpu, label: "white tip")!
    }

    /// The texture for a tip/grain, or `white` for `.round` or anything that fails to decode.
    public func texture(for tip: BrushTip) -> MTLTexture {
        if case .round = tip { return white }
        if let t = cache[tip] { return t }
        guard let px = BrushTextureLibrary.pixels(for: tip),
              let t = Self.upload(px, side: BrushTextureLibrary.size, gpu: gpu, label: "brush texture") else { return white }
        if cache.count > 64 { cache.removeAll() }
        cache[tip] = t
        return t
    }

    static func upload(_ pixels: [UInt8], side: Int, gpu: PaperGPU, label: String) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: side, height: side, mipmapped: true)
        d.usage = [.shaderRead]
        d.storageMode = .private
        guard let tex = gpu.device.makeTexture(descriptor: d),
              let buffer = pixels.withUnsafeBytes({ gpu.device.makeBuffer(bytes: $0.baseAddress!, length: pixels.count,
                                                                          options: .storageModeShared) }) else { return nil }
        tex.label = label
        gpu.run("upload brush texture") { cb in
            let blit = cb.makeBlitCommandEncoder()!
            blit.copy(from: buffer, sourceOffset: 0, sourceBytesPerRow: side, sourceBytesPerImage: pixels.count,
                      sourceSize: MTLSize(width: side, height: side, depth: 1), to: tex, destinationSlice: 0,
                      destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.generateMipmaps(for: tex)
            blit.endEncoding()
        }
        return tex
    }
}
