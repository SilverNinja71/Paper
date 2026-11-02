import Foundation
import Metal
import simd

/// A layer being moved/scaled/rotated, shown live before it's committed.
public struct TransformPreview: Equatable {
    public var layerID: UUID
    /// Forward affine transform (source pixel → canvas pixel).
    public var transform: simd_float3x3
    /// Move only the selected pixels.
    public var selectionOnly: Bool

    public init(layerID: UUID, transform: simd_float3x3, selectionOnly: Bool) {
        self.layerID = layerID; self.transform = transform; self.selectionOnly = selectionOnly
    }
}

/// Everything the compositor reads for one pass.
public struct CompositeInputs {
    public var layers: LayerStack
    public var content: [UUID: MTLTexture]
    public var masks: [UUID: MTLTexture]
    /// Opaque background colour (straight RGB), or nil for a transparent background.
    public var background: SIMD3<Float>?
    public var liveStroke: LiveStroke?
    public var strokeTexture: MTLTexture?
    public var selection: MTLTexture?
    public var transform: TransformPreview?
}

/// Flattens the layer tree into one texture on the GPU, region by region.
///
/// Groups composite into an isolated buffer (or straight onto the backdrop for Pass Through);
/// clipping groups render the base layer into a buffer and apply each clipped layer source-atop,
/// then blend the result with the base's mode and opacity — Photoshop's behaviour. Adjustment layers
/// filter everything beneath them in their group and mix the result back by opacity × mask.
public final class Compositor {
    public let gpu: PaperGPU
    public let width: Int
    public let height: Int
    /// The flattened image (premultiplied), background included.
    public let output: MTLTexture
    public let adjustments: AdjustmentPipeline

    private enum Slot: Int { case group, clip, adjust, passBackup }
    private var scratch: [Int: MTLTexture] = [:]

    public init(gpu: PaperGPU, width: Int, height: Int) throws {
        self.gpu = gpu
        self.width = width
        self.height = height
        output = try gpu.makeTexture(width: width, height: height, label: "composite")
        adjustments = try AdjustmentPipeline(gpu: gpu)
    }

    private func buffer(_ slot: Slot, depth: Int) -> MTLTexture {
        let key = depth * 8 + slot.rawValue
        if let t = scratch[key] { return t }
        let t = try! gpu.makeTexture(width: width, height: height, label: "composite scratch \(slot) \(depth)")
        scratch[key] = t
        return t
    }

    /// Releases scratch buffers (e.g. when memory is tight).
    public func trimMemory() { scratch.removeAll() }

    /// How far adjustments make pixels depend on their neighbours (to widen dirty regions).
    public func neighborhoodRadius(_ layers: LayerStack) -> Int {
        layers.allNodes.compactMap(\.adjustment).map {
            AdjustmentPipeline.neighborhoodRadius(for: $0, canvasWidth: width, canvasHeight: height)
        }.max() ?? 0
    }

    /// Recomposites `region` (whole canvas when nil) into `output`, or into `target` if given.
    public func composite(_ inputs: CompositeInputs, region: IntRect? = nil, into target: MTLTexture? = nil) {
        let canvas = IntRect(x: 0, y: 0, width: width, height: height)
        let r = (region ?? canvas).intersection(canvas)
        guard !r.isEmpty else { return }
        let dst = target ?? output
        let cb = gpu.queue.makeCommandBuffer()!
        cb.label = "composite"
        if let bg = inputs.background {
            gpu.clear(dst, region: r, to: SIMD4(bg, 1), in: cb)
        } else {
            gpu.clear(dst, region: r, in: cb)
        }
        compositeList(inputs.layers.nodes, onto: dst, depth: 0, inputs: inputs, region: r, cb: cb)
        cb.commit()
        cb.waitUntilCompleted()
    }

    // MARK: Tree walk

    private func compositeList(_ nodes: [LayerNode], onto acc: MTLTexture, depth: Int, inputs: CompositeInputs,
                               region: IntRect, cb: MTLCommandBuffer) {
        var i = 0
        while i < nodes.count {
            let base = nodes[i]
            var j = i + 1
            var clipped: [LayerNode] = []
            while j < nodes.count && nodes[j].clipsToBelow {
                clipped.append(nodes[j])
                j += 1
            }
            defer { i = j }
            guard base.isVisible else { continue }
            let visibleClipped = clipped.filter(\.isVisible)
            if visibleClipped.isEmpty || base.isAdjustment {
                compositeNode(base, onto: acc, atop: false, depth: depth, inputs: inputs, region: region, cb: cb)
                // Clipped layers on an adjustment base have nothing to clip to; draw them normally.
                if base.isAdjustment {
                    for c in visibleClipped {
                        compositeNode(c, onto: acc, atop: false, depth: depth, inputs: inputs, region: region, cb: cb)
                    }
                }
                continue
            }
            let tmp = buffer(.clip, depth: depth)
            gpu.clear(tmp, region: region, in: cb)
            compositeNode(base, onto: tmp, atop: false, depth: depth + 1, inputs: inputs, region: region, cb: cb,
                          overrideOpacity: 1, overrideMode: .normal)
            for c in visibleClipped {
                compositeNode(c, onto: tmp, atop: true, depth: depth + 1, inputs: inputs, region: region, cb: cb)
            }
            let mode: BlendMode = base.blendMode == .passThrough ? .normal : base.blendMode
            drawTexture(tmp, onto: acc, mode: mode, opacity: base.opacity, mask: nil, atop: false, region: region, cb: cb)
        }
    }

    private func compositeNode(_ node: LayerNode, onto acc: MTLTexture, atop: Bool, depth: Int, inputs: CompositeInputs,
                               region: IntRect, cb: MTLCommandBuffer,
                               overrideOpacity: Float? = nil, overrideMode: BlendMode? = nil) {
        let opacity = overrideOpacity ?? node.opacity
        let mode = overrideMode ?? node.blendMode
        let mask = node.hasMask && node.maskEnabled ? inputs.masks[node.id] : nil
        switch node.content {
        case .raster:
            guard let tex = inputs.content[node.id] else { return }
            var params = CompositeParams()
            if let live = inputs.liveStroke, live.layerID == node.id, inputs.strokeTexture != nil {
                params.strokeActive = 1
                if live.onMask && mask == nil { params.strokeActive = 0 }
            }
            var maskTexture = mask
            // While painting on a mask that's switched off, still show the effect.
            if let live = inputs.liveStroke, live.layerID == node.id, live.onMask, mask == nil, let m = inputs.masks[node.id] {
                maskTexture = m
                params.strokeActive = 1
            }
            if let t = inputs.transform, t.layerID == node.id {
                let inv = t.transform.inverse
                params.hasTransform = 1
                params.transformSelectionOnly = t.selectionOnly && inputs.selection != nil ? 1 : 0
                params.xform0 = SIMD4(inv[0][0], inv[1][0], inv[2][0], 0)
                params.xform1 = SIMD4(inv[0][1], inv[1][1], inv[2][1], 0)
            }
            drawTexture(tex, onto: acc, mode: mode == .passThrough ? .normal : mode, opacity: opacity, mask: maskTexture,
                        atop: atop, region: region, cb: cb, params: params, inputs: inputs)

        case .group(let children, _):
            if mode == .passThrough && !atop {
                // Children blend straight into the backdrop; opacity/mask fade between before and after.
                let needsFade = opacity < 0.999 || mask != nil
                let backup = buffer(.passBackup, depth: depth)
                if needsFade { gpu.copy(acc, region: region, to: backup, in: cb) }
                compositeList(children, onto: acc, depth: depth + 1, inputs: inputs, region: region, cb: cb)
                if needsFade {
                    mix(backup, toward: acc, opacity: opacity, mask: mask, region: region, cb: cb)
                    gpu.copy(backup, region: region, to: acc, in: cb)
                }
            } else {
                let buf = buffer(.group, depth: depth)
                gpu.clear(buf, region: region, in: cb)
                compositeList(children, onto: buf, depth: depth + 1, inputs: inputs, region: region, cb: cb)
                drawTexture(buf, onto: acc, mode: mode == .passThrough ? .normal : mode, opacity: opacity, mask: mask,
                            atop: atop, region: region, cb: cb)
            }

        case .adjustment(let settings):
            let out = buffer(.adjust, depth: depth)
            do {
                try adjustments.encode(settings, source: acc, destination: out, region: region, commandBuffer: cb)
                mix(acc, toward: out, opacity: opacity, mask: mask, region: region, cb: cb)
            } catch {
                // A failed adjustment leaves the image below untouched.
            }
        }
    }

    /// acc = mix(acc, other, opacity × mask).
    private func mix(_ acc: MTLTexture, toward other: MTLTexture, opacity: Float, mask: MTLTexture?, region: IntRect,
                     cb: MTLCommandBuffer) {
        guard let p = try? gpu.pipeline("mixRegion", in: UtilityShader.self), let enc = cb.makeComputeCommandEncoder() else { return }
        var params = MixParams(origin: region.origin32, hasMask: mask == nil ? 0 : 1, opacity: opacity)
        enc.setTexture(acc, index: 0)
        enc.setTexture(other, index: 1)
        enc.setTexture(mask ?? gpu.dummyMask, index: 2)
        enc.setBytes(&params, length: MemoryLayout<MixParams>.stride, index: 0)
        enc.dispatch2D(p, width: region.width, height: region.height)
        enc.endEncoding()
    }

    private func drawTexture(_ src: MTLTexture, onto acc: MTLTexture, mode: BlendMode, opacity: Float, mask: MTLTexture?,
                             atop: Bool, region: IntRect, cb: MTLCommandBuffer,
                             params extra: CompositeParams = CompositeParams(), inputs: CompositeInputs? = nil) {
        guard let p = try? gpu.pipeline("compositeLayer", in: CompositeShader.self),
              let enc = cb.makeComputeCommandEncoder() else { return }
        var params = extra
        params.origin = region.origin32
        params.blendMode = mode.shaderIndex
        params.opacity = opacity
        params.hasMask = mask == nil ? 0 : 1
        params.atop = atop ? 1 : 0
        params.canvasSize = SIMD2(Float(width), Float(height))
        params.hasSelection = inputs?.selection == nil ? 0 : 1
        var apply = inputs?.liveStroke?.params.value
            ?? ApplyParams(origin: .zero, mode: 0, opacity: 1, alphaLock: 0, hasSelection: 0, target: 0)
        enc.setTexture(src, index: 0)
        enc.setTexture(acc, index: 1)
        enc.setTexture(mask ?? gpu.dummyMask, index: 2)
        enc.setTexture(params.strokeActive != 0 ? (inputs?.strokeTexture ?? gpu.dummyColor) : gpu.dummyColor, index: 3)
        enc.setTexture(inputs?.selection ?? gpu.dummyMask, index: 4)
        enc.setSamplerState(gpu.linearClamp, index: 0)
        enc.setBytes(&params, length: MemoryLayout<CompositeParams>.stride, index: 0)
        enc.setBytes(&apply, length: MemoryLayout<ApplyParams>.stride, index: 1)
        enc.dispatch2D(p, width: region.width, height: region.height)
        enc.endEncoding()
    }

    /// Copies the composite (optionally over an opaque colour) into `target` — used for exports.
    public func flatten(onto background: SIMD4<Float>?, into target: MTLTexture) {
        guard let p = try? gpu.pipeline("flatten", in: CompositeShader.self) else { return }
        gpu.run("flatten") { cb in
            let enc = cb.makeComputeCommandEncoder()!
            var params = FlattenParams(background: background ?? .zero, hasBackground: background == nil ? 0 : 1)
            enc.setTexture(output, index: 0)
            enc.setTexture(target, index: 1)
            enc.setBytes(&params, length: MemoryLayout<FlattenParams>.stride, index: 0)
            enc.dispatch2D(p, width: width, height: height)
            enc.endEncoding()
        }
    }
}
