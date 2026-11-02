import Foundation
import Metal
import CoreGraphics
import simd

// Selection (lasso, all, invert), flood fill, clearing pixels, move/scale/rotate/flip, and image import.

extension CanvasDocument {
    // MARK: Selection

    public func beginLasso(at p: SIMD2<Float>) {
        lassoPath = [p]
    }

    public func extendLasso(to p: SIMD2<Float>) {
        guard let last = lassoPath.last else { lassoPath = [p]; return }
        if simd_distance(last, p) > 1.5 / max(camera.zoom, 0.05) { lassoPath.append(p) }
    }

    /// Closes the lasso and turns it into the selection (anti-aliased, even-odd fill).
    public func endLasso(_ combine: SelectionCombine = .replace) {
        let path = lassoPath
        lassoPath = []
        guard path.count >= 3, let coverage = rasterizePolygon(path) else {
            if combine == .replace && path.count < 3 { deselect() }
            return
        }
        setSelection(combining: coverage, mode: hasSelection ? combine : .replace, name: "Lasso")
    }

    public func selectAll() {
        guard let t = try? gpu.makeTexture(width: width, height: height, format: .r16Float, label: "selection") else { return }
        gpu.run("select all") { cb in gpu.clear(t, to: SIMD4(repeating: 1), in: cb) }
        replaceSelection(t, name: "Select All")
    }

    public func deselect() {
        guard selectionTexture != nil else { return }
        replaceSelection(nil, name: "Deselect")
    }

    public func invertSelection() {
        guard let current = selectionTexture, let inverted = copyTexture(current),
              let p = try? gpu.pipeline("invertMask", in: SelectionShader.self) else { selectAll(); return }
        gpu.run("invert selection") { cb in
            let enc = cb.makeComputeCommandEncoder()!
            enc.setTexture(inverted, index: 0)
            enc.dispatch2D(p, width: width, height: height)
            enc.endEncoding()
        }
        replaceSelection(inverted, name: "Invert Selection")
    }

    private func setSelection(combining coverage: MTLTexture, mode: SelectionCombine, name: String) {
        guard mode != .replace, let current = selectionTexture, let combined = copyTexture(current),
              let p = try? gpu.pipeline("combineMasks", in: SelectionShader.self) else {
            replaceSelection(coverage, name: name)
            return
        }
        gpu.run("combine selection") { cb in
            let enc = cb.makeComputeCommandEncoder()!
            var m = mode.rawValue
            enc.setTexture(combined, index: 0)
            enc.setTexture(coverage, index: 1)
            enc.setBytes(&m, length: 4, index: 0)
            enc.dispatch2D(p, width: width, height: height)
            enc.endEncoding()
        }
        replaceSelection(combined, name: name)
    }

    func replaceSelection(_ t: MTLTexture?, name: String) {
        let old = selectionTexture
        selectionTexture = t
        hasSelection = t != nil
        history.push(name, bytes: width * height * 2, undo: { [weak self] in
            self?.selectionTexture = old
            self?.hasSelection = old != nil
            self?.invalidate(nil)
        }, redo: { [weak self] in
            self?.selectionTexture = t
            self?.hasSelection = t != nil
            self?.invalidate(nil)
        })
        invalidate(nil)
        markChanged()
    }

    /// Anti-aliased polygon coverage as an r16Float mask.
    func rasterizePolygon(_ points: [SIMD2<Float>]) -> MTLTexture? {
        var bytes = [UInt8](repeating: 0, count: width * height)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            // Canvas y runs down; CoreGraphics y runs up.
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            ctx.setShouldAntialias(true)
            ctx.setFillColor(gray: 1, alpha: 1)
            let path = CGMutablePath()
            path.addLines(between: points.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) })
            path.closeSubpath()
            ctx.addPath(path)
            ctx.fillPath(using: .evenOdd)
            return true
        }
        guard ok else { return nil }
        return uploadCoverage(bytes, region: IntRect(x: 0, y: 0, width: width, height: height))
    }

    /// Uploads 8-bit coverage for `region` into a fresh canvas-sized r16Float texture (zero elsewhere).
    func uploadCoverage(_ bytes: [UInt8], region: IntRect) -> MTLTexture? {
        guard let t = try? gpu.makeTexture(width: width, height: height, format: .r16Float, label: "coverage"),
              let p = try? gpu.pipeline("importGray8", in: SelectionShader.self),
              let buffer = bytes.withUnsafeBytes({ gpu.device.makeBuffer(bytes: $0.baseAddress!, length: bytes.count,
                                                                         options: .storageModeShared) }) else { return nil }
        gpu.run("upload coverage") { cb in
            gpu.clear(t, in: cb)
            let enc = cb.makeComputeCommandEncoder()!
            var params = RegionParams(origin: region.origin32, width: UInt32(region.width))
            enc.setTexture(t, index: 0)
            enc.setBuffer(buffer, offset: 0, index: 0)
            enc.setBytes(&params, length: MemoryLayout<RegionParams>.stride, index: 1)
            enc.dispatch2D(p, width: region.width, height: region.height)
            enc.endEncoding()
        }
        return t
    }

    // MARK: Clear / fill selection

    /// Deletes the selected pixels on the active layer (everything without a selection). On a mask,
    /// hides the selected area instead.
    public func clearSelectedPixels() {
        guard canEditActiveLayer, let id = activeLayerID else { return }
        let onMask = editingMask && activeLayer?.hasMask == true
        guard let target = onMask ? masks[id] : content[id],
              let p = try? gpu.pipeline("clearSelected", in: SelectionShader.self) else { return }
        editPixels("Clear", layerID: id, isMask: onMask, texture: target, region: nil) { cb in
            let enc = cb.makeComputeCommandEncoder()!
            var params = ClearParams(origin: .zero, hasSelection: selectionTexture == nil ? 0 : 1, isMask: onMask ? 1 : 0,
                                     maskValue: 0)
            enc.setTexture(target, index: 0)
            enc.setTexture(selectionTexture ?? gpu.dummyMask, index: 1)
            enc.setBytes(&params, length: MemoryLayout<ClearParams>.stride, index: 0)
            enc.dispatch2D(p, width: width, height: height)
            enc.endEncoding()
        }
    }

    /// Fills the selection (or the whole layer) with the current colour.
    public func fillSelection() {
        guard canEditActiveLayer, let id = activeLayerID, let target = content[id] else { return }
        let coverage = selectionTexture ?? {
            let t = try? gpu.makeTexture(width: width, height: height, format: .r16Float, label: "coverage")
            if let t { gpu.run("full coverage") { cb in gpu.clear(t, to: SIMD4(repeating: 1), in: cb) } }
            return t
        }()
        guard let coverage else { return }
        applyFill(coverage: coverage, region: IntRect(x: 0, y: 0, width: width, height: height), layerID: id, texture: target)
    }

    /// Flood fill ("ColorDrop") at a canvas point. Boundaries come from the Reference layer when one is
    /// set, otherwise from the active layer. A one-pixel grow covers anti-aliased line edges.
    public func fill(at point: SIMD2<Float>) {
        guard canEditActiveLayer, let id = activeLayerID, let target = content[id] else {
            statusMessage = "Select an unlocked pixel layer to fill."
            return
        }
        let x = Int(point.x), y = Int(point.y)
        guard x >= 0, y >= 0, x < width, y < height else { return }
        let referenceID = layers.allNodes.first { $0.isReference && $0.isRaster }?.id
        let source = referenceID.flatMap { content[$0] } ?? target
        let pixels = gpu.readPixels(source)
        guard let result = FloodFill.coverage(pixels: pixels, width: width, height: height, seedX: x, seedY: y,
                                              tolerance: fillTolerance),
              let coverage = uploadCoverage(result.bytes, region: result.bounds) else { return }
        applyFill(coverage: coverage, region: result.bounds, layerID: id, texture: target)
        noteColorUsed()
    }

    private func applyFill(coverage: MTLTexture, region: IntRect, layerID: UUID, texture: MTLTexture) {
        guard let p = try? gpu.pipeline("fillWithMask", in: SelectionShader.self) else { return }
        let alphaLock = layers.node(layerID)?.alphaLocked == true
        editPixels("Fill", layerID: layerID, isMask: false, texture: texture, region: region) { cb in
            let enc = cb.makeComputeCommandEncoder()!
            var params = FillMaskParams(color: SIMD4(color, currentFillOpacity), origin: region.origin32,
                                        alphaLock: alphaLock ? 1 : 0, hasSelection: selectionTexture == nil ? 0 : 1)
            enc.setTexture(texture, index: 0)
            enc.setTexture(coverage, index: 1)
            enc.setTexture(selectionTexture ?? gpu.dummyMask, index: 2)
            enc.setBytes(&params, length: MemoryLayout<FillMaskParams>.stride, index: 0)
            enc.dispatch2D(p, width: region.width, height: region.height)
            enc.endEncoding()
        }
    }

    private var currentFillOpacity: Float { opacities[.brush] ?? 1 }

    /// Runs a GPU edit on a layer texture and records region undo for it.
    func editPixels(_ name: String, layerID: UUID, isMask: Bool, texture: MTLTexture, region: IntRect?,
                    _ encode: (MTLCommandBuffer) -> Void) {
        let r = (region ?? IntRect(x: 0, y: 0, width: width, height: height)).clamped(width: width, height: height)
        guard !r.isEmpty,
              let before = try? gpu.makeTexture(width: r.width, height: r.height, format: texture.pixelFormat, label: "undo before"),
              let after = try? gpu.makeTexture(width: r.width, height: r.height, format: texture.pixelFormat, label: "undo after")
        else { return }
        gpu.run(name) { cb in
            gpu.copy(texture, region: r, to: before, at: .zero, in: cb)
            encode(cb)
            gpu.copy(texture, region: r, to: after, at: .zero, in: cb)
        }
        if isMask { maskRevision[layerID, default: 0] += 1 } else { contentRevision[layerID, default: 0] += 1 }
        invalidate(r)
        pushRegionUndo(name, layerID: layerID, isMask: isMask, snapshot: RegionSnapshot(rect: r, before: before, after: after))
        refreshThumbnail(layerID)
    }

    // MARK: Transform

    /// Pixel bounds of non-transparent content in a texture (nil if empty).
    func contentBounds(_ tex: MTLTexture, threshold: Float = 0.004) -> IntRect? {
        let px = gpu.readPixels(tex)
        var minX = tex.width, minY = tex.height, maxX = -1, maxY = -1
        let isMask = tex.pixelFormat == .r16Float
        for y in 0..<tex.height {
            let row = y * tex.width
            for x in 0..<tex.width {
                let v = isMask ? px[row + x].x : px[row + x].w
                if v > threshold {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        return maxX < 0 ? nil : IntRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Starts moving the active layer — or just the selected pixels when there's a selection.
    public func beginTransform() {
        guard transformState == nil else { return }
        guard canEditActiveLayer, let id = activeLayerID, let tex = content[id] else {
            statusMessage = "Select an unlocked pixel layer to move."
            return
        }
        let bounds: IntRect?
        if let sel = selectionTexture {
            bounds = contentBounds(sel).flatMap { s in contentBounds(tex).map { $0.intersection(s) } }
        } else {
            bounds = contentBounds(tex)
        }
        guard let b = bounds, !b.isEmpty else { statusMessage = "Nothing to move on this layer."; return }
        transformState = TransformState(layerID: id, bounds: b, selectionOnly: selectionTexture != nil)
        invalidate(nil)
    }

    public func updateTransform(_ body: (inout TransformState) -> Void) {
        guard var t = transformState else { return }
        body(&t)
        t.scale = simd_clamp(t.scale, SIMD2(repeating: 0.01), SIMD2(repeating: 100))
        transformState = t
        invalidate(nil)
    }

    /// Bakes the transform into the layer (bilinear resampling). The selection moves with the pixels.
    public func commitTransform() {
        guard let t = transformState else { return }
        transformState = nil
        guard !t.isIdentity, let src = content[t.layerID] else { invalidate(nil); return }
        structuralChange("Transform", bytes: width * height * 8) {
            if let moved = resample(src, by: t.matrix, selectionOnly: t.selectionOnly) {
                content[t.layerID] = moved
            }
            if t.selectionOnly, let sel = selectionTexture, let movedSel = resample(sel, by: t.matrix, selectionOnly: false) {
                selectionTexture = movedSel
            }
        }
        refreshThumbnail(t.layerID)
    }

    public func cancelTransform() {
        transformState = nil
        invalidate(nil)
    }

    /// Mirrors the active layer (or selection) across its centre.
    public func flipActiveLayer(horizontal: Bool) {
        guard canEditActiveLayer, let id = activeLayerID, let tex = content[id] else { return }
        let cx = Float(width) / 2, cy = Float(height) / 2
        let m: simd_float3x3 = horizontal
            ? simd_float3x3(SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(2 * cx, 0, 1))
            : simd_float3x3(SIMD3(1, 0, 0), SIMD3(0, -1, 0), SIMD3(0, 2 * cy, 1))
        structuralChange(horizontal ? "Flip Horizontal" : "Flip Vertical", bytes: width * height * 8) {
            if let flipped = resample(tex, by: m, selectionOnly: selectionTexture != nil) { content[id] = flipped }
            if let sel = selectionTexture, let movedSel = resample(sel, by: m, selectionOnly: false) { selectionTexture = movedSel }
        }
        refreshThumbnail(id)
    }

    /// A new texture with `src` resampled through `forward` (source pixel → canvas pixel).
    func resample(_ src: MTLTexture, by forward: simd_float3x3, selectionOnly: Bool,
                  outputWidth: Int? = nil, outputHeight: Int? = nil) -> MTLTexture? {
        let ow = outputWidth ?? width, oh = outputHeight ?? height
        guard let dst = try? gpu.makeTexture(width: ow, height: oh, format: src.pixelFormat, label: src.label ?? "layer"),
              let p = try? gpu.pipeline("transformLayer", in: SelectionShader.self) else { return nil }
        let inv = forward.inverse
        var params = TransformParams(xform0: SIMD4(inv[0][0], inv[1][0], inv[2][0], 0),
                                     xform1: SIMD4(inv[0][1], inv[1][1], inv[2][1], 0),
                                     canvasSize: SIMD2(Float(src.width), Float(src.height)),
                                     selectionOnly: selectionOnly && selectionTexture != nil ? 1 : 0)
        gpu.run("resample") { cb in
            let enc = cb.makeComputeCommandEncoder()!
            enc.setTexture(src, index: 0)
            enc.setTexture(dst, index: 1)
            enc.setTexture(selectionTexture ?? gpu.dummyMask, index: 2)
            enc.setSamplerState(gpu.linearClamp, index: 0)
            enc.setBytes(&params, length: MemoryLayout<TransformParams>.stride, index: 0)
            enc.dispatch2D(p, width: ow, height: oh)
            enc.endEncoding()
        }
        return dst
    }

    // MARK: Import / export

    /// Adds an image as a new layer, centred, scaled down to fit the canvas if it's larger.
    public func importImage(_ image: PhotoImage, name: String) {
        guard image.width > 0, image.height > 0,
              let staging = try? gpu.makeTexture(width: image.width, height: image.height, label: "import") else { return }
        gpu.writePixels(image.pixels, to: staging)
        let fit = min(1, min(Float(width) / Float(image.width), Float(height) / Float(image.height)))
        let ox = (Float(width) - Float(image.width) * fit) / 2
        let oy = (Float(height) - Float(image.height) * fit) / 2
        let m = simd_float3x3(SIMD3(fit, 0, 0), SIMD3(0, fit, 0), SIMD3(ox, oy, 1))
        structuralChange("Import Image") {
            let selection = selectionTexture
            selectionTexture = nil
            defer { selectionTexture = selection }
            guard let placed = resample(staging, by: m, selectionOnly: false) else { return }
            let node = LayerNode(name: name)
            content[node.id] = placed
            contentRevision[node.id] = 1
            layers.insert(node, above: activeLayerID.flatMap { layers.node($0)?.isGroup == true ? nil : $0 })
            activeLayerID = node.id
        }
        refreshAllThumbnails()
    }

    /// The flattened picture (background included when it's visible).
    public func flattenedImage() -> PhotoImage {
        recompositeAll()
        return PhotoImage(width: width, height: height, pixels: gpu.readPixels(compositor.output))
    }
}

// MARK: - Flood fill

public enum FloodFill {
    public struct Result {
        public var bytes: [UInt8]
        public var bounds: IntRect
    }

    /// Scanline flood fill over premultiplied pixels. A pixel joins the region when every channel is
    /// within `tolerance` of the seed pixel. Returns 8-bit coverage cropped to the region's bounds
    /// (grown by one pixel so anti-aliased edges are covered).
    public static func coverage(pixels: [SIMD4<Float>], width: Int, height: Int, seedX: Int, seedY: Int,
                                tolerance: Float) -> Result? {
        guard seedX >= 0, seedY >= 0, seedX < width, seedY < height, pixels.count >= width * height else { return nil }
        let seed = pixels[seedY * width + seedX]
        let tol = max(tolerance, 0.001)
        var inside = [Bool](repeating: false, count: width * height)
        func matches(_ i: Int) -> Bool {
            let d = simd_abs(pixels[i] - seed)
            return max(max(d.x, d.y), max(d.z, d.w)) <= tol
        }
        var stack: [(Int, Int)] = [(seedX, seedY)]
        var minX = seedX, maxX = seedX, minY = seedY, maxY = seedY
        while let (sx, y) = stack.popLast() {
            var x = sx
            let row = y * width
            if inside[row + x] || !matches(row + x) { continue }
            while x > 0 && !inside[row + x - 1] && matches(row + x - 1) { x -= 1 }
            var spanAbove = false, spanBelow = false
            while x < width && !inside[row + x] && matches(row + x) {
                inside[row + x] = true
                minX = min(minX, x); maxX = max(maxX, x)
                if y > 0 {
                    let up = row - width + x
                    let m = !inside[up] && matches(up)
                    if m && !spanAbove { stack.append((x, y - 1)) }
                    spanAbove = m
                }
                if y < height - 1 {
                    let down = row + width + x
                    let m = !inside[down] && matches(down)
                    if m && !spanBelow { stack.append((x, y + 1)) }
                    spanBelow = m
                }
                x += 1
            }
            minY = min(minY, y); maxY = max(maxY, y)
        }
        let bounds = IntRect(x: minX - 1, y: minY - 1, width: maxX - minX + 3, height: maxY - minY + 3)
            .clamped(width: width, height: height)
        var bytes = [UInt8](repeating: 0, count: bounds.area)
        for y in bounds.y..<bounds.maxY {
            for x in bounds.x..<bounds.maxX {
                var covered = inside[y * width + x]
                if !covered {
                    // Grow by one pixel (8-neighbourhood).
                    outer: for dy in -1...1 {
                        for dx in -1...1 {
                            let nx = x + dx, ny = y + dy
                            if nx >= 0, ny >= 0, nx < width, ny < height, inside[ny * width + nx] { covered = true; break outer }
                        }
                    }
                }
                if covered { bytes[(y - bounds.y) * bounds.width + (x - bounds.x)] = 255 }
            }
        }
        return Result(bytes: bytes, bounds: bounds)
    }
}
