import Foundation
import Metal
import simd

/// What a stroke does to its layer.
public enum StrokeMode: Equatable, Sendable {
    case paint, erase, smudge
}

/// Where a stroke lands: a layer's colour content or its mask.
public struct StrokeTarget {
    public var layerID: UUID
    public var texture: MTLTexture
    public var isMask: Bool
    public var alphaLocked: Bool

    public init(layerID: UUID, texture: MTLTexture, isMask: Bool, alphaLocked: Bool) {
        self.layerID = layerID; self.texture = texture; self.isMask = isMask; self.alphaLocked = alphaLocked
    }
}

/// Everything the compositor needs to preview an in-progress paint/erase stroke on its layer.
public struct LiveStroke {
    public var layerID: UUID
    public var onMask: Bool
    public var params: ApplyParamsBox
}

/// Opaque wrapper so `ApplyParams` (an internal GPU struct) can travel through public API.
public struct ApplyParamsBox {
    var value: ApplyParams
}

/// Pixels of one rectangle before and after an edit, kept for undo/redo.
public final class RegionSnapshot {
    public let rect: IntRect
    public let before: MTLTexture
    public let after: MTLTexture
    public var byteCount: Int { rect.area * (before.pixelFormat == .r16Float ? 2 : 8) * 2 }

    init(rect: IntRect, before: MTLTexture, after: MTLTexture) {
        self.rect = rect; self.before = before; self.after = after
    }

    /// Captures `rect` of `beforeSource` and `afterSource` (same format) into small textures.
    static func capture(rect: IntRect, beforeSource: MTLTexture, afterSource: MTLTexture,
                        gpu: PaperGPU) -> RegionSnapshot? {
        guard !rect.isEmpty,
              let b = try? gpu.makeTexture(width: rect.width, height: rect.height, format: beforeSource.pixelFormat, label: "undo before"),
              let a = try? gpu.makeTexture(width: rect.width, height: rect.height, format: afterSource.pixelFormat, label: "undo after")
        else { return nil }
        gpu.run("capture undo") { cb in
            gpu.copy(beforeSource, region: rect, to: b, at: .zero, in: cb)
            gpu.copy(afterSource, region: rect, to: a, at: .zero, in: cb)
        }
        return RegionSnapshot(rect: rect, before: b, after: a)
    }

    /// Writes the before (undo) or after (redo) pixels back into `target`.
    func restore(_ useBefore: Bool, into target: MTLTexture, gpu: PaperGPU) {
        let src = useBefore ? before : after
        gpu.run("restore region") { cb in
            gpu.copy(src, region: IntRect(x: 0, y: 0, width: rect.width, height: rect.height), to: target,
                     at: SIMD2(rect.x, rect.y), in: cb)
        }
    }
}

/// Paints strokes on the GPU: stabilise → interpolate → dynamics → stamp dabs (compute) → merge.
public final class PaintEngine {
    public let gpu: PaperGPU
    public let width: Int
    public let height: Int
    public let textures: BrushTextureCache
    /// The in-progress stroke (premultiplied colour), shown live by the compositor.
    public let strokeTexture: MTLTexture

    private let backup: MTLTexture
    private var maskBackup: MTLTexture?
    private var snapshot: MTLTexture?

    public private(set) var isStroking = false
    public private(set) var strokeBounds: IntRect = .empty
    private var clearedBounds: IntRect = .empty
    private var mode: StrokeMode = .paint
    private var target: StrokeTarget?
    private var selection: MTLTexture?
    private var brush = BrushPreset(name: "", category: "")
    private var opacity: Float = 1
    private var stabilizer = StrokeStabilizer(streamline: 0, stabilization: 0, viewScale: 1)
    private var generator: DabGenerator?
    private var lastSmudgeCenter: SIMD2<Float>?
    private var strokeSeed: UInt64 = 1

    public init(gpu: PaperGPU, width: Int, height: Int, textures: BrushTextureCache) throws {
        self.gpu = gpu
        self.width = width
        self.height = height
        self.textures = textures
        strokeTexture = try gpu.makeTexture(width: width, height: height, label: "stroke buffer")
        backup = try gpu.makeTexture(width: width, height: height, label: "stroke backup")
        gpu.run("clear stroke") { cb in gpu.clear(strokeTexture, in: cb) }
    }

    /// Live-preview info for the compositor (nil when idle or smudging, which edits the layer directly).
    public var liveStroke: LiveStroke? {
        guard isStroking, mode != .smudge, let target else { return nil }
        return LiveStroke(layerID: target.layerID, onMask: target.isMask, params: ApplyParamsBox(value: applyParams))
    }

    private var applyParams: ApplyParams {
        ApplyParams(origin: .zero, mode: mode == .erase ? 1 : 0, opacity: opacity,
                    alphaLock: target?.alphaLocked == true && target?.isMask == false ? 1 : 0,
                    hasSelection: selection == nil ? 0 : 1, target: target?.isMask == true ? 1 : 0)
    }

    // MARK: Stroke lifecycle

    /// Starts a stroke and paints its first dab. Returns the canvas rectangle that changed.
    @discardableResult
    public func beginStroke(_ sample: StrokeSample, brush: BrushPreset, mode: StrokeMode, size: Float, opacity: Float,
                            color: SIMD3<Float>, target: StrokeTarget, selection: MTLTexture?,
                            viewScale: Float) -> IntRect {
        if isStroking { _ = endStroke() }
        self.brush = brush
        self.mode = target.isMask && mode == .smudge ? .paint : mode
        self.opacity = min(max(opacity, 0), 1)
        self.target = target
        self.selection = selection
        strokeSeed = strokeSeed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        stabilizer = StrokeStabilizer(streamline: brush.streamline, stabilization: brush.stabilization, viewScale: viewScale)
        generator = DabGenerator(brush: brush, size: size, color: color, seed: strokeSeed)
        lastSmudgeCenter = nil
        isStroking = true
        strokeBounds = .empty

        // Back up the target so the stroke can be undone (or cancelled) and clear last stroke's pixels.
        let backupTexture = backupFor(target)
        gpu.run("begin stroke") { cb in
            gpu.copy(target.texture, region: IntRect(x: 0, y: 0, width: width, height: height), to: backupTexture, in: cb)
            if !clearedBounds.isEmpty { gpu.clear(strokeTexture, region: clearedBounds, in: cb) }
        }
        clearedBounds = .empty
        return continueStroke([sample])
    }

    /// Feeds more input samples (use coalesced touches for full Pencil resolution).
    @discardableResult
    public func continueStroke(_ samples: [StrokeSample]) -> IntRect {
        guard isStroking, var gen = generator else { return .empty }
        var dabs: [Dab] = []
        for s in samples { dabs += gen.add(stabilizer.process(s)) }
        generator = gen
        return render(dabs)
    }

    /// Finishes the stroke, merges it into the layer and returns the undo snapshot (nil if nothing changed).
    public func endStroke() -> RegionSnapshot? {
        guard isStroking, var gen = generator, let target else { isStroking = false; return nil }
        var dabs: [Dab] = []
        for s in stabilizer.catchUp() { dabs += gen.add(s) }
        dabs += gen.finish()
        generator = gen
        render(dabs)
        isStroking = false

        let rect = strokeBounds.clamped(width: width, height: height)
        guard !rect.isEmpty else { return nil }
        if mode != .smudge, let p = try? gpu.pipeline("applyStroke", in: StrokeShader.self) {
            gpu.run("apply stroke") { cb in
                let enc = cb.makeComputeCommandEncoder()!
                var params = applyParams
                params.origin = rect.origin32
                enc.setTexture(target.texture, index: 0)
                enc.setTexture(strokeTexture, index: 1)
                enc.setTexture(selection ?? gpu.dummyMask, index: 2)
                enc.setBytes(&params, length: MemoryLayout<ApplyParams>.stride, index: 0)
                enc.dispatch2D(p, width: rect.width, height: rect.height)
                enc.endEncoding()
            }
        }
        clearedBounds = rect
        strokeBounds = .empty
        return RegionSnapshot.capture(rect: rect, beforeSource: backupFor(target), afterSource: target.texture, gpu: gpu)
    }

    /// Abandons the stroke and restores the layer.
    public func cancelStroke() -> IntRect {
        guard isStroking, let target else { return .empty }
        isStroking = false
        let rect = strokeBounds.clamped(width: width, height: height)
        if !rect.isEmpty {
            gpu.run("cancel stroke") { cb in
                gpu.copy(backupFor(target), region: rect, to: target.texture, in: cb)
                gpu.clear(strokeTexture, region: rect, in: cb)
            }
        }
        strokeBounds = .empty
        return rect
    }

    private func backupFor(_ target: StrokeTarget) -> MTLTexture {
        guard target.isMask else { return backup }
        if let m = maskBackup { return m }
        let m = try! gpu.makeTexture(width: width, height: height, format: .r16Float, label: "mask backup")
        maskBackup = m
        return m
    }

    // MARK: Rendering dabs

    private func strokeParams(origin: IntRect, count: Int) -> (StrokeParams, MTLTexture, MTLTexture, MTLTexture) {
        var p = StrokeParams()
        p.origin = origin.origin32
        p.dabCount = UInt32(count)
        let tipTexture = textures.texture(for: brush.tip)
        if case .round = brush.tip { p.tipKind = 0 } else { p.tipKind = 1 }
        p.hardness = brush.hardness
        p.tipTexSize = Float(tipTexture.width)
        var grainTexture = textures.white
        if let g = brush.grain, g.depth > 0 {
            grainTexture = textures.texture(for: g.source)
            p.grainMode = g.mode == .moving ? 1 : 2
            p.grainScale = g.scale
            p.grainDepth = g.depth
            p.grainTexSize = Float(grainTexture.width)
        }
        var dualTexture = textures.white
        if let d = brush.dual, d.depth > 0 {
            dualTexture = textures.texture(for: d.tip)
            p.dualMode = d.blend.shaderIndex
            p.dualScale = d.scale
            p.dualDepth = d.depth
            p.dualTexSize = Float(dualTexture.width)
        }
        p.wetEdges = brush.wetEdges
        p.wetMix = target?.isMask == true ? 0 : brush.wetMix
        return (p, tipTexture, grainTexture, dualTexture)
    }

    @discardableResult
    private func render(_ dabs: [Dab]) -> IntRect {
        guard !dabs.isEmpty, let target else { return .empty }
        let canvas = IntRect(x: 0, y: 0, width: width, height: height)
        var dirty = IntRect.empty

        if mode == .smudge {
            guard let p = try? gpu.pipeline("smudgeDab", in: StrokeShader.self) else { return .empty }
            if snapshot == nil { snapshot = try? gpu.makeTexture(width: width, height: height, label: "smudge snapshot") }
            guard let snapshot else { return .empty }
            let cb = gpu.queue.makeCommandBuffer()!
            cb.label = "smudge"
            for var dab in dabs {
                let prev = lastSmudgeCenter ?? dab.center
                lastSmudgeCenter = dab.center
                let delta = dab.center - prev
                let rect = dab.bounds.clamped(width: width, height: height)
                guard !rect.isEmpty else { continue }
                let shifted = IntRect(x: rect.x - Int(ceil(delta.x)) - 2, y: rect.y - Int(ceil(delta.y)) - 2,
                                      width: rect.width + 4, height: rect.height + 4)
                gpu.copy(target.texture, region: rect.union(shifted).intersection(canvas), to: snapshot, in: cb)
                var (params, tip, grain, dual) = strokeParams(origin: rect, count: 1)
                var smudge = SmudgeParams(delta: delta, strength: dab.flow * dab.color.w,
                                          alphaLock: target.alphaLocked ? 1 : 0, hasSelection: selection == nil ? 0 : 1)
                let enc = cb.makeComputeCommandEncoder()!
                enc.setTexture(target.texture, index: 0)
                enc.setTexture(snapshot, index: 1)
                enc.setTexture(tip, index: 2)
                enc.setTexture(grain, index: 3)
                enc.setTexture(dual, index: 4)
                enc.setTexture(selection ?? gpu.dummyMask, index: 5)
                enc.setSamplerState(gpu.linearClamp, index: 0)
                enc.setSamplerState(gpu.linearRepeat, index: 1)
                enc.setBytes(&params, length: MemoryLayout<StrokeParams>.stride, index: 0)
                enc.setBytes(&dab, length: MemoryLayout<Dab>.stride, index: 1)
                enc.setBytes(&smudge, length: MemoryLayout<SmudgeParams>.stride, index: 2)
                enc.dispatch2D(p, width: rect.width, height: rect.height)
                enc.endEncoding()
                dirty = dirty.union(rect)
            }
            cb.commit()
            cb.waitUntilCompleted()
        } else {
            guard let p = try? gpu.pipeline("stampDabs", in: StrokeShader.self) else { return .empty }
            let cb = gpu.queue.makeCommandBuffer()!
            cb.label = "stamp dabs"
            // Consecutive dabs are processed in small batches: every pixel thread composites the batch's
            // dabs in order, so overlapping dabs build up correctly without any race between threads.
            let batchSize = 32
            var start = 0
            while start < dabs.count {
                let batch = Array(dabs[start..<min(start + batchSize, dabs.count)])
                start += batchSize
                let rect = batch.reduce(IntRect.empty) { $0.union($1.bounds) }.intersection(canvas)
                guard !rect.isEmpty else { continue }
                var (params, tip, grain, dual) = strokeParams(origin: rect, count: batch.count)
                let enc = cb.makeComputeCommandEncoder()!
                enc.setTexture(strokeTexture, index: 0)
                enc.setTexture(tip, index: 1)
                enc.setTexture(grain, index: 2)
                enc.setTexture(dual, index: 3)
                enc.setTexture(target.isMask ? gpu.dummyColor : target.texture, index: 4)
                enc.setSamplerState(gpu.linearClamp, index: 0)
                enc.setSamplerState(gpu.linearRepeat, index: 1)
                enc.setBytes(&params, length: MemoryLayout<StrokeParams>.stride, index: 0)
                batch.withUnsafeBytes { enc.setBytes($0.baseAddress!, length: $0.count, index: 1) }
                enc.dispatch2D(p, width: rect.width, height: rect.height)
                enc.endEncoding()
                dirty = dirty.union(rect)
            }
            cb.commit()
            cb.waitUntilCompleted()
        }
        strokeBounds = strokeBounds.union(dirty)
        return dirty
    }
}
