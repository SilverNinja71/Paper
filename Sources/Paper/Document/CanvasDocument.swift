import Foundation
import Metal
import CoreGraphics
import Observation
import simd

public enum PaperTool: String, CaseIterable, Identifiable, Codable, Sendable {
    case brush, smudge, eraser, lasso, move, fill, eyedropper

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .brush: return "Brush"
        case .smudge: return "Smudge"
        case .eraser: return "Eraser"
        case .lasso: return "Lasso Select"
        case .move: return "Move / Transform"
        case .fill: return "Fill"
        case .eyedropper: return "Eyedropper"
        }
    }

    public var symbol: String {
        switch self {
        case .brush: return "paintbrush.pointed.fill"
        case .smudge: return "hand.point.up.left.fill"
        case .eraser: return "eraser.fill"
        case .lasso: return "lasso"
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        case .fill: return "drop.fill"
        case .eyedropper: return "eyedropper"
        }
    }

    public var shortcut: String {
        switch self {
        case .brush: return "B"
        case .smudge: return "S"
        case .eraser: return "E"
        case .lasso: return "L"
        case .move: return "V"
        case .fill: return "G"
        case .eyedropper: return "I"
        }
    }

    public var usesBrush: Bool { self == .brush || self == .smudge || self == .eraser }
}

/// Where the canvas sits in the view: zoom (screen points per canvas pixel), pan (points) and rotation.
public struct CanvasCamera: Equatable, Sendable {
    public var zoom: Float = 1
    public var pan: SIMD2<Float> = .zero
    public var rotation: Float = 0
    public init() {}
}

/// An in-progress move/scale/rotate of the active layer (or of the selected pixels).
public struct TransformState: Equatable {
    public var layerID: UUID
    /// Bounds of what's being transformed, before the transform.
    public var bounds: IntRect
    public var translation: SIMD2<Float> = .zero
    public var scale: SIMD2<Float> = SIMD2(1, 1)
    public var rotation: Float = 0
    public var selectionOnly: Bool

    public var pivot: SIMD2<Float> {
        SIMD2(Float(bounds.x) + Float(bounds.width) / 2, Float(bounds.y) + Float(bounds.height) / 2)
    }

    /// Source pixel → canvas pixel.
    public var matrix: simd_float3x3 {
        let p = pivot
        let toOrigin = simd_float3x3(SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(-p.x, -p.y, 1))
        let s = simd_float3x3(SIMD3(scale.x, 0, 0), SIMD3(0, scale.y, 0), SIMD3(0, 0, 1))
        let c = cos(rotation), sn = sin(rotation)
        let r = simd_float3x3(SIMD3(c, sn, 0), SIMD3(-sn, c, 0), SIMD3(0, 0, 1))
        let back = simd_float3x3(SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(p.x + translation.x, p.y + translation.y, 1))
        return back * r * s * toOrigin
    }

    public var isIdentity: Bool {
        simd_length(translation) < 0.01 && abs(scale.x - 1) < 1e-4 && abs(scale.y - 1) < 1e-4 && abs(rotation) < 1e-5
    }

    /// The four transformed corners (for drawing the transform box).
    public var corners: [SIMD2<Float>] {
        let m = matrix
        let b = bounds
        return [SIMD2(Float(b.x), Float(b.y)), SIMD2(Float(b.maxX), Float(b.y)),
                SIMD2(Float(b.maxX), Float(b.maxY)), SIMD2(Float(b.x), Float(b.maxY))].map { p in
            let v = m * SIMD3(p.x, p.y, 1)
            return SIMD2(v.x, v.y)
        }
    }
}

/// How a new lasso combines with the existing selection.
public enum SelectionCombine: UInt32, Sendable {
    case replace = 0, add = 1, subtract = 2, intersect = 3
}

/// A Paper canvas: layer tree + GPU pixels + tools + selection + undo. The UI observes it.
@MainActor
@Observable
public final class CanvasDocument {
    // MARK: Document

    public var name: String
    public var fileURL: URL?
    public let width: Int
    public let height: Int
    public private(set) var hasUnsavedChanges = false
    /// Bumped whenever the composite changes, so the canvas view knows to redraw.
    public private(set) var displayRevision = 0
    public var statusMessage: String?

    // MARK: Layers

    public internal(set) var layers = LayerStack()
    public var activeLayerID: UUID? {
        didSet { if editingMask, activeLayer?.hasMask != true { editingMask = false } }
    }
    /// Paint on the active layer's mask instead of its colour.
    public var editingMask = false
    public internal(set) var background: SIMD3<Float> = SIMD3(1, 1, 1)
    public internal(set) var backgroundVisible = true
    public private(set) var thumbnails: [UUID: CGImage] = [:]

    // MARK: Tools

    public var tool: PaperTool = .brush {
        didSet { if oldValue == .move, tool != .move { commitTransform() } }
    }
    public var paintBrush: BrushPreset
    public var smudgeBrush: BrushPreset
    public var eraserBrush: BrushPreset
    public var sizes: [PaperTool: Float] = [.brush: 24, .smudge: 60, .eraser: 40]
    public var opacities: [PaperTool: Float] = [.brush: 1, .smudge: 0.8, .eraser: 1]
    /// Current colour: straight, gamma-encoded Display P3.
    public var color = SIMD3<Float>(0.11, 0.11, 0.13)
    public private(set) var recentColors: [SIMD3<Float>] = []
    /// Flood-fill threshold (0…1).
    public var fillTolerance: Float = 0.15

    // MARK: Selection, transform, view

    public internal(set) var hasSelection = false
    public internal(set) var lassoPath: [SIMD2<Float>] = []
    public internal(set) var transformState: TransformState?
    public var camera = CanvasCamera()

    // MARK: Undo

    public private(set) var canUndo = false
    public private(set) var canRedo = false
    @ObservationIgnored public let history = UndoHistory()

    // MARK: Engine (not observed)

    @ObservationIgnored public let gpu: PaperGPU
    @ObservationIgnored public let paint: PaintEngine
    @ObservationIgnored public let compositor: Compositor
    @ObservationIgnored public internal(set) var content: [UUID: MTLTexture] = [:] {
        didSet { for (id, t) in content where oldValue[id] !== t { contentRevision[id, default: 0] += 1 } }
    }
    @ObservationIgnored public internal(set) var masks: [UUID: MTLTexture] = [:] {
        didSet { for (id, t) in masks where oldValue[id] !== t { maskRevision[id, default: 0] += 1 } }
    }
    @ObservationIgnored public internal(set) var selectionTexture: MTLTexture?
    /// Bumped on in-place pixel edits; with the texture identity it tells the saver what changed.
    @ObservationIgnored var contentRevision: [UUID: Int] = [:]
    @ObservationIgnored var maskRevision: [UUID: Int] = [:]
    @ObservationIgnored var savedContentState: [UUID: String] = [:]
    @ObservationIgnored var savedMaskState: [UUID: String] = [:]
    @ObservationIgnored private var strokeLayer: (id: UUID, isMask: Bool)?
    @ObservationIgnored private var layerCounter = 1
    /// Called after every committed change (the app uses it for autosave + cloud sync).
    @ObservationIgnored public var onChange: (() -> Void)?

    // MARK: Init

    public convenience init(width: Int, height: Int, name: String = "Untitled", background: SIMD3<Float>? = SIMD3(1, 1, 1),
                            gpu: PaperGPU = .shared) throws {
        try self.init(width: width, height: height, name: name, gpu: gpu, emptyStack: true)
        if let background { self.background = background } else { backgroundVisible = false }
        let first = LayerNode(name: "Layer 1")
        try makeContentTexture(first.id)
        layers = LayerStack(nodes: [first])
        activeLayerID = first.id
        recompositeAll()
        refreshAllThumbnails()
    }

    /// Bare document with no layers (used by the file loader).
    init(width: Int, height: Int, name: String, gpu: PaperGPU, emptyStack: Bool) throws {
        self.width = min(max(width, 16), 16384)
        self.height = min(max(height, 16), 16384)
        self.name = name
        self.gpu = gpu
        let textures = BrushTextureCache(gpu: gpu)
        paint = try PaintEngine(gpu: gpu, width: self.width, height: self.height, textures: textures)
        compositor = try Compositor(gpu: gpu, width: self.width, height: self.height)
        paintBrush = FreeBrushStore.builtInBrushes.first { $0.name == "Studio Pen" } ?? BrushPreset(name: "Round", category: "Inking")
        smudgeBrush = FreeBrushStore.builtInBrushes.first { $0.name == "Soft Blend" } ?? BrushPreset(name: "Blend", category: "Smudge")
        eraserBrush = FreeBrushStore.builtInBrushes.first { $0.name == "Hard Airbrush" } ?? BrushPreset(name: "Eraser", category: "Airbrushing")
    }

    // MARK: Convenience accessors

    public var activeLayer: LayerNode? { activeLayerID.flatMap { layers.node($0) } }

    /// The brush of the current tool (the paint brush for tools that don't use one).
    public var currentBrush: BrushPreset {
        get {
            switch tool {
            case .smudge: return smudgeBrush
            case .eraser: return eraserBrush
            default: return paintBrush
            }
        }
        set {
            switch tool {
            case .smudge: smudgeBrush = newValue
            case .eraser: eraserBrush = newValue
            default: paintBrush = newValue
            }
        }
    }

    private var brushTool: PaperTool { tool.usesBrush ? tool : .brush }

    public var currentSize: Float {
        get { sizes[brushTool] ?? 24 }
        set { sizes[brushTool] = min(max(newValue, 1), 2000) }
    }

    public var currentOpacity: Float {
        get { opacities[brushTool] ?? 1 }
        set { opacities[brushTool] = min(max(newValue, 0.01), 1) }
    }

    public var undoName: String? { history.undoName }
    public var redoName: String? { history.redoName }

    public var canEditActiveLayer: Bool {
        guard let id = activeLayerID, let n = layers.node(id) else { return false }
        return n.isRaster && !layers.isEffectivelyLocked(id)
    }

    // MARK: Textures

    @discardableResult
    func makeContentTexture(_ id: UUID) throws -> MTLTexture {
        let t = try gpu.makeTexture(width: width, height: height, label: "layer")
        gpu.run("clear layer") { cb in gpu.clear(t, in: cb) }
        content[id] = t
        contentRevision[id, default: 0] += 1
        return t
    }

    @discardableResult
    func makeMaskTexture(_ id: UUID, value: Float = 1) throws -> MTLTexture {
        let t = try gpu.makeTexture(width: width, height: height, format: .r16Float, label: "mask")
        gpu.run("clear mask") { cb in gpu.clear(t, to: SIMD4(repeating: value), in: cb) }
        masks[id] = t
        maskRevision[id, default: 0] += 1
        return t
    }

    func copyTexture(_ t: MTLTexture) -> MTLTexture? {
        guard let c = try? gpu.makeTexture(width: t.width, height: t.height, format: t.pixelFormat, label: t.label ?? "copy")
        else { return nil }
        gpu.run("copy texture") { cb in gpu.copy(t, region: IntRect(x: 0, y: 0, width: t.width, height: t.height), to: c, in: cb) }
        return c
    }

    private var layerBytes: Int { width * height * 8 }

    // MARK: Compositing

    var compositeInputs: CompositeInputs {
        CompositeInputs(layers: layers, content: content, masks: masks,
                        background: backgroundVisible ? background : nil,
                        liveStroke: paint.liveStroke, strokeTexture: paint.strokeTexture,
                        selection: selectionTexture,
                        transform: transformState.map { TransformPreview(layerID: $0.layerID, transform: $0.matrix,
                                                                         selectionOnly: $0.selectionOnly) })
    }

    /// Recomposites a region (or everything) and tells the view to redraw.
    public func invalidate(_ rect: IntRect?) {
        if let rect {
            guard !rect.isEmpty else { return }
            let pad = compositor.neighborhoodRadius(layers)
            compositor.composite(compositeInputs, region: rect.insetBy(-pad))
        } else {
            compositor.composite(compositeInputs)
        }
        displayRevision &+= 1
    }

    public func recompositeAll() { invalidate(nil) }

    func markChanged() {
        hasUnsavedChanges = true
        canUndo = history.canUndo
        canRedo = history.canRedo
        onChange?()
    }

    func markSaved() { hasUnsavedChanges = false }

    // MARK: Undo plumbing

    struct StateSnapshot {
        var layers: LayerStack
        var content: [UUID: MTLTexture]
        var masks: [UUID: MTLTexture]
        var active: UUID?
        var selection: MTLTexture?
    }

    func captureState() -> StateSnapshot {
        StateSnapshot(layers: layers, content: content, masks: masks, active: activeLayerID, selection: selectionTexture)
    }

    func restoreState(_ s: StateSnapshot) {
        if paint.isStroking { _ = paint.cancelStroke() }
        transformState = nil
        layers = s.layers
        content = s.content
        masks = s.masks
        selectionTexture = s.selection
        hasSelection = s.selection != nil
        activeLayerID = s.active.flatMap { layers.node($0) != nil ? $0 : nil } ?? layers.allNodes.last?.id
        recompositeAll()
        refreshAllThumbnails()
        markChanged()
    }

    /// Runs `body` and records one undo step that restores the whole layer state.
    func structuralChange(_ name: String, coalesceKey: String? = nil, bytes: Int = 0, _ body: () throws -> Void) rethrows {
        if paint.isStroking { endStroke() }
        let before = captureState()
        try body()
        let after = captureState()
        guard before.layers != after.layers || !sameTextures(before, after) else { return }
        history.push(name, bytes: bytes, coalesceKey: coalesceKey,
                     undo: { [weak self] in self?.restoreState(before) },
                     redo: { [weak self] in self?.restoreState(after) })
        recompositeAll()
        markChanged()
    }

    private func sameTextures(_ a: StateSnapshot, _ b: StateSnapshot) -> Bool {
        func ids(_ d: [UUID: MTLTexture]) -> [UUID: ObjectIdentifier] { d.mapValues { ObjectIdentifier($0) } }
        return ids(a.content) == ids(b.content) && ids(a.masks) == ids(b.masks)
            && a.selection.map(ObjectIdentifier.init) == b.selection.map(ObjectIdentifier.init)
    }

    func pushRegionUndo(_ name: String, layerID: UUID, isMask: Bool, snapshot: RegionSnapshot) {
        history.push(name, bytes: snapshot.byteCount,
                     undo: { [weak self] in self?.restoreRegion(snapshot, before: true, layerID: layerID, isMask: isMask) },
                     redo: { [weak self] in self?.restoreRegion(snapshot, before: false, layerID: layerID, isMask: isMask) })
        markChanged()
    }

    private func restoreRegion(_ snapshot: RegionSnapshot, before: Bool, layerID: UUID, isMask: Bool) {
        guard let tex = isMask ? masks[layerID] : content[layerID] else { return }
        snapshot.restore(before, into: tex, gpu: gpu)
        if isMask { maskRevision[layerID, default: 0] += 1 } else { contentRevision[layerID, default: 0] += 1 }
        invalidate(snapshot.rect)
        refreshThumbnail(layerID)
        markChanged()
    }

    public func undo() {
        if paint.isStroking { _ = paint.cancelStroke() }
        if transformState != nil { cancelTransform(); return }
        if let name = history.undo() { statusMessage = "Undo \(name)" }
        canUndo = history.canUndo
        canRedo = history.canRedo
    }

    public func redo() {
        if let name = history.redo() { statusMessage = "Redo \(name)" }
        canUndo = history.canUndo
        canRedo = history.canRedo
    }

    // MARK: Painting

    /// Starts a brush/smudge/eraser stroke on the active layer (or its mask). Returns false if the
    /// layer can't be painted (locked, hidden, a group…), with a status message saying why.
    @discardableResult
    public func beginStroke(_ sample: StrokeSample) -> Bool {
        guard tool.usesBrush else { return false }
        guard let id = activeLayerID, let node = layers.node(id) else { statusMessage = "Add a layer to paint on."; return false }
        guard node.isRaster else { statusMessage = "Select a pixel layer to paint on."; return false }
        guard !layers.isEffectivelyLocked(id) else { statusMessage = "This layer is locked."; return false }
        guard layers.isEffectivelyVisible(id) else { statusMessage = "This layer is hidden."; return false }
        let onMask = editingMask && node.hasMask
        guard let tex = onMask ? masks[id] : content[id] else { return false }
        let mode: StrokeMode = tool == .eraser ? .erase : tool == .smudge ? .smudge : .paint
        strokeLayer = (id, onMask)
        let dirty = paint.beginStroke(sample, brush: currentBrush, mode: mode, size: currentSize, opacity: currentOpacity,
                                      color: color, target: StrokeTarget(layerID: id, texture: tex, isMask: onMask,
                                                                         alphaLocked: node.alphaLocked),
                                      selection: selectionTexture, viewScale: camera.zoom)
        invalidate(dirty)
        return true
    }

    public func continueStroke(_ samples: [StrokeSample]) {
        guard paint.isStroking else { return }
        let dirty = paint.continueStroke(samples)
        if !dirty.isEmpty { invalidate(dirty) }
    }

    public func endStroke() {
        guard paint.isStroking, let target = strokeLayer else { return }
        strokeLayer = nil
        let name = tool.displayName
        guard let snapshot = paint.endStroke() else { invalidate(nil); return }
        if target.isMask { maskRevision[target.id, default: 0] += 1 } else { contentRevision[target.id, default: 0] += 1 }
        invalidate(snapshot.rect)
        pushRegionUndo(name, layerID: target.id, isMask: target.isMask, snapshot: snapshot)
        refreshThumbnail(target.id)
        if tool == .brush { noteColorUsed() }
    }

    public func cancelStroke() {
        strokeLayer = nil
        invalidate(paint.cancelStroke())
    }

    /// Paints a full stroke from samples in one call (scripts, tests, the brush preview).
    public func paintStroke(_ samples: [StrokeSample]) {
        guard let first = samples.first, beginStroke(first) else { return }
        continueStroke(Array(samples.dropFirst()))
        endStroke()
    }

    public func noteColorUsed() {
        recentColors.removeAll { simd_distance($0, color) < 0.002 }
        recentColors.insert(color, at: 0)
        if recentColors.count > 12 { recentColors.removeLast(recentColors.count - 12) }
    }

    /// `[` / `]`: scale the brush size.
    public func adjustSize(by factor: Float) { currentSize = (currentSize * factor).rounded() }

    /// `Shift+[` / `Shift+]`: change the edge softness of the current brush.
    public func adjustHardness(by delta: Float) {
        var b = currentBrush
        b.hardness = min(max(b.hardness + delta, 0), 1)
        currentBrush = b
    }

    // MARK: Eyedropper

    /// Samples the composite at a canvas point and makes it the current colour.
    @discardableResult
    public func pickColor(at p: SIMD2<Float>) -> SIMD3<Float>? {
        let x = Int(p.x), y = Int(p.y)
        guard x >= 0, y >= 0, x < width, y < height,
              let px = gpu.readPixels(compositor.output, region: IntRect(x: x, y: y, width: 1, height: 1)).first,
              px.w > 0.001 else { return nil }
        color = simd_clamp(SIMD3(px.x, px.y, px.z) / px.w, .zero, SIMD3(repeating: 1))
        noteColorUsed()
        return color
    }

    // MARK: Layer operations

    private func nextLayerName() -> String {
        layerCounter += 1
        let names = Set(layers.allNodes.map(\.name))
        while names.contains("Layer \(layerCounter)") { layerCounter += 1 }
        return "Layer \(layerCounter)"
    }

    private func insertNode(_ node: LayerNode) {
        if let a = activeLayer, a.isGroup, a.isExpanded {
            layers.insert(node, intoGroup: a.id)
        } else {
            layers.insert(node, above: activeLayerID)
        }
    }

    public func addLayer(name: String? = nil) {
        structuralChange("New Layer") {
            let node = LayerNode(name: name ?? nextLayerName())
            guard (try? makeContentTexture(node.id)) != nil else { statusMessage = "Not enough memory for another layer."; return }
            insertNode(node)
            activeLayerID = node.id
        }
        refreshThumbnail(activeLayerID)
    }

    /// A new, empty group above the active layer.
    public func addGroup() {
        structuralChange("New Group") {
            let g = LayerNode(name: "Group", content: .group(children: [], expanded: true))
            layers.insert(g, above: activeLayerID)
            activeLayerID = g.id
        }
    }

    /// Wraps the active layer in a new group.
    public func groupActiveLayer() {
        guard let id = activeLayerID else { return }
        structuralChange("Group Layer") {
            if let g = layers.group([id], name: "Group") { activeLayerID = g }
        }
    }

    public func ungroup(_ id: UUID) {
        guard layers.node(id)?.isGroup == true else { return }
        structuralChange("Ungroup") {
            let first = layers.node(id)?.children.last?.id
            layers.ungroup(id)
            activeLayerID = first
        }
    }

    public func addAdjustmentLayer(_ kind: AdjustmentKind) {
        structuralChange("New \(kind.displayName)") {
            let node = LayerNode(name: kind.displayName, content: .adjustment(AdjustmentSettings(kind: kind)))
            insertNode(node)
            activeLayerID = node.id
        }
    }

    public func updateAdjustment(_ id: UUID, _ settings: AdjustmentSettings) {
        guard layers.node(id)?.adjustment != settings else { return }
        structuralChange("Adjust", coalesceKey: "adjust-\(id)") {
            layers.update(id) { $0.adjustment = settings }
        }
    }

    public func duplicateLayer(_ id: UUID? = nil) {
        guard let id = id ?? activeLayerID, let node = layers.node(id) else { return }
        structuralChange("Duplicate Layer") {
            var copy = cloneNode(node)
            copy.name = node.name + " copy"
            layers.insert(copy, above: id)
            activeLayerID = copy.id
        }
        refreshAllThumbnails()
    }

    private func cloneNode(_ n: LayerNode) -> LayerNode {
        var c = n
        c.id = UUID()
        if n.isRaster, let t = content[n.id], let copy = copyTexture(t) {
            content[c.id] = copy
            contentRevision[c.id] = 1
        }
        if n.hasMask, let m = masks[n.id], let copy = copyTexture(m) {
            masks[c.id] = copy
            maskRevision[c.id] = 1
        }
        if n.isGroup { c.children = n.children.map(cloneNode) }
        return c
    }

    public func deleteLayer(_ id: UUID? = nil) {
        guard let id = id ?? activeLayerID, layers.node(id) != nil else { return }
        guard !layers.isEffectivelyLocked(id) else { statusMessage = "Unlock the layer to delete it."; return }
        structuralChange("Delete Layer", bytes: layerBytes) {
            let neighbour = layers.nodeBelow(id)?.id ?? layers.nodeAbove(id)?.id ?? layers.parentID(of: id)
            if let removed = layers.remove(id) {
                for n in [removed] + LayerStack(nodes: removed.children).allNodes {
                    content[n.id] = nil
                    masks[n.id] = nil
                }
            }
            if layers.allNodes.isEmpty {
                let fresh = LayerNode(name: nextLayerName())
                _ = try? makeContentTexture(fresh.id)
                layers.nodes = [fresh]
                activeLayerID = fresh.id
            } else {
                activeLayerID = neighbour ?? layers.allNodes.last?.id
            }
        }
        refreshAllThumbnails()
    }

    /// Merges a layer (raster, group or adjustment) into the raster layer below it (Cmd+E).
    public func mergeDown(_ id: UUID? = nil) {
        guard let id = id ?? activeLayerID, let upper = layers.node(id) else { return }
        guard let lower = layers.nodeBelow(id), lower.isRaster else { statusMessage = "Nothing to merge into below."; return }
        guard !layers.isEffectivelyLocked(lower.id), !layers.isEffectivelyLocked(id) else {
            statusMessage = "Unlock both layers to merge them."; return
        }
        structuralChange("Merge Down", bytes: layerBytes * 2) {
            guard let merged = try? gpu.makeTexture(width: width, height: height, label: "layer") else { return }
            var base = lower
            base.opacity = 1
            base.blendMode = .normal
            base.clipsToBelow = false
            base.isVisible = true
            var top = upper
            top.isVisible = upper.isVisible
            let temp = LayerStack(nodes: [base, top])
            compositor.composite(CompositeInputs(layers: temp, content: content, masks: masks, background: nil,
                                                 liveStroke: nil, strokeTexture: nil, selection: nil, transform: nil),
                                 into: merged)
            content[lower.id] = merged
            masks[lower.id] = nil
            layers.update(lower.id) { $0.hasMask = false }
            layers.remove(id)
            content[id] = nil
            masks[id] = nil
            activeLayerID = lower.id
        }
        refreshAllThumbnails()
    }

    /// Turns a group (or adjustment applied to nothing) into a single raster layer.
    public func flattenGroup(_ id: UUID) {
        guard let g = layers.node(id), g.isGroup else { return }
        structuralChange("Flatten Group", bytes: layerBytes) {
            guard let flat = try? gpu.makeTexture(width: width, height: height, label: "layer") else { return }
            var inner = g
            inner.opacity = 1
            inner.blendMode = .normal
            inner.hasMask = false
            inner.clipsToBelow = false
            compositor.composite(CompositeInputs(layers: LayerStack(nodes: [inner]), content: content, masks: masks,
                                                 background: nil, liveStroke: nil, strokeTexture: nil, selection: nil,
                                                 transform: nil), into: flat)
            var raster = LayerNode(name: g.name)
            raster.opacity = g.opacity
            raster.blendMode = g.blendMode == .passThrough ? .normal : g.blendMode
            raster.isVisible = g.isVisible
            raster.clipsToBelow = g.clipsToBelow
            raster.hasMask = g.hasMask
            raster.maskEnabled = g.maskEnabled
            content[raster.id] = flat
            if g.hasMask { masks[raster.id] = masks[g.id] }
            layers.insert(raster, above: id)
            layers.remove(id)
            activeLayerID = raster.id
        }
        refreshAllThumbnails()
    }

    public func setVisible(_ id: UUID, _ visible: Bool) {
        structuralChange(visible ? "Show Layer" : "Hide Layer") { layers.update(id) { $0.isVisible = visible } }
    }

    public func setOpacity(_ id: UUID, _ opacity: Float) {
        structuralChange("Layer Opacity", coalesceKey: "opacity-\(id)") {
            layers.update(id) { $0.opacity = min(max(opacity, 0), 1) }
        }
    }

    public func setBlendMode(_ id: UUID, _ mode: BlendMode) {
        guard mode != .passThrough || layers.node(id)?.isGroup == true else { return }
        structuralChange("Blend Mode") { layers.update(id) { $0.blendMode = mode } }
    }

    public func setLocked(_ id: UUID, _ locked: Bool) {
        structuralChange(locked ? "Lock Layer" : "Unlock Layer") { layers.update(id) { $0.isLocked = locked } }
    }

    public func setAlphaLocked(_ id: UUID, _ on: Bool) {
        structuralChange("Alpha Lock") { layers.update(id) { $0.alphaLocked = on } }
    }

    public func setClipping(_ id: UUID, _ on: Bool) {
        structuralChange(on ? "Clipping Mask" : "Release Clipping Mask") { layers.update(id) { $0.clipsToBelow = on } }
    }

    /// Only one layer is the fill reference at a time.
    public func setReference(_ id: UUID, _ on: Bool) {
        structuralChange("Reference") {
            for n in layers.allNodes where n.isReference { layers.update(n.id) { $0.isReference = false } }
            layers.update(id) { $0.isReference = on }
        }
    }

    public func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        structuralChange("Rename Layer") { layers.update(id) { $0.name = trimmed } }
    }

    public func setExpanded(_ id: UUID, _ expanded: Bool) {
        layers.update(id) { $0.isExpanded = expanded }
    }

    public func moveLayer(_ id: UUID, above target: UUID?) {
        structuralChange("Move Layer") { layers.move(id, above: target) }
    }

    public func moveLayer(_ id: UUID, below target: UUID) {
        structuralChange("Move Layer") { layers.move(id, below: target) }
    }

    public func moveLayer(_ id: UUID, intoGroup group: UUID) {
        structuralChange("Move Layer") { layers.move(id, intoGroup: group) }
    }

    /// Moves the layer one step up (+1) or down (−1) among its siblings.
    public func nudgeLayer(_ id: UUID, by step: Int) {
        if step > 0, let above = layers.nodeAbove(id) { moveLayer(id, above: above.id) }
        if step < 0, let below = layers.nodeBelow(id) { moveLayer(id, below: below.id) }
    }

    // MARK: Masks

    /// Adds a layer mask. With a selection, the mask reveals only the selected area.
    public func addMask(_ id: UUID? = nil) {
        guard let id = id ?? activeLayerID, let node = layers.node(id), !node.hasMask else { return }
        structuralChange("Add Mask") {
            guard let m = try? makeMaskTexture(id, value: selectionTexture == nil ? 1 : 0) else { return }
            if let sel = selectionTexture {
                gpu.run("mask from selection") { cb in
                    gpu.copy(sel, region: IntRect(x: 0, y: 0, width: width, height: height), to: m, in: cb)
                }
            }
            layers.update(id) { $0.hasMask = true; $0.maskEnabled = true }
            activeLayerID = id
            editingMask = true
        }
    }

    public func deleteMask(_ id: UUID) {
        structuralChange("Delete Mask") {
            masks[id] = nil
            layers.update(id) { $0.hasMask = false }
            editingMask = false
        }
    }

    public func setMaskEnabled(_ id: UUID, _ on: Bool) {
        structuralChange(on ? "Enable Mask" : "Disable Mask") { layers.update(id) { $0.maskEnabled = on } }
    }

    /// Bakes the mask into the layer's pixels.
    public func applyMask(_ id: UUID) {
        guard let node = layers.node(id), node.isRaster, node.hasMask else { return }
        structuralChange("Apply Mask", bytes: layerBytes) {
            guard let baked = try? gpu.makeTexture(width: width, height: height, label: "layer") else { return }
            var flat = node
            flat.opacity = 1
            flat.blendMode = .normal
            flat.clipsToBelow = false
            flat.isVisible = true
            compositor.composite(CompositeInputs(layers: LayerStack(nodes: [flat]), content: content, masks: masks,
                                                 background: nil, liveStroke: nil, strokeTexture: nil, selection: nil,
                                                 transform: nil), into: baked)
            content[id] = baked
            masks[id] = nil
            layers.update(id) { $0.hasMask = false }
            editingMask = false
        }
        refreshThumbnail(id)
    }

    // MARK: Background

    public func setBackground(_ color: SIMD3<Float>, visible: Bool) {
        let old = (background, backgroundVisible)
        background = color
        backgroundVisible = visible
        history.push("Background", coalesceKey: "background", undo: { [weak self] in
            self?.background = old.0; self?.backgroundVisible = old.1; self?.recompositeAll()
        }, redo: { [weak self] in
            self?.background = color; self?.backgroundVisible = visible; self?.recompositeAll()
        })
        recompositeAll()
        markChanged()
    }

    // MARK: Thumbnails

    func refreshThumbnail(_ id: UUID?) {
        guard let id else { return }
        if let tex = content[id] { thumbnails[id] = renderThumbnail(tex, maxSide: 96) } else { thumbnails[id] = nil }
    }

    func refreshAllThumbnails() {
        var fresh: [UUID: CGImage] = [:]
        for id in layers.rasterIDs {
            if let tex = content[id], let img = renderThumbnail(tex, maxSide: 96) { fresh[id] = img }
        }
        thumbnails = fresh
    }

    /// Downscaled, premultiplied preview of a texture.
    public func renderThumbnail(_ tex: MTLTexture, maxSide: Int) -> CGImage? {
        let scale = Float(maxSide) / Float(max(tex.width, tex.height))
        let tw = max(1, Int(Float(tex.width) * scale)), th = max(1, Int(Float(tex.height) * scale))
        guard let small = try? gpu.makeTexture(width: tw, height: th, label: "thumbnail"),
              let p = try? gpu.pipeline("downsample", in: UtilityShader.self) else { return nil }
        gpu.run("thumbnail") { cb in
            let enc = cb.makeComputeCommandEncoder()!
            enc.setTexture(tex, index: 0)
            enc.setTexture(small, index: 1)
            enc.setSamplerState(gpu.linearClamp, index: 0)
            enc.dispatch2D(p, width: tw, height: th)
            enc.endEncoding()
        }
        return ImageConversion.cgImage(premultiplied: gpu.readPixels(small), width: tw, height: th)
    }

    /// The whole picture, small (for galleries and the file's thumbnail.png).
    public func compositeThumbnail(maxSide: Int = 512) -> CGImage? {
        renderThumbnail(compositor.output, maxSide: maxSide)
    }
}

/// Float pixels → CGImage.
public enum ImageConversion {
    public static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!

    /// 8-bit premultiplied RGBA in Display P3 from premultiplied float pixels (top row first).
    public static func cgImage(premultiplied pixels: [SIMD4<Float>], width: Int, height: Int) -> CGImage? {
        guard pixels.count >= width * height, width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let p = simd_clamp(pixels[i], .zero, SIMD4(repeating: 1))
            let a = p.w
            let c = SIMD4(min(p.x, a), min(p.y, a), min(p.z, a), a) * 255
            bytes[i * 4] = UInt8(c.x.rounded())
            bytes[i * 4 + 1] = UInt8(c.y.rounded())
            bytes[i * 4 + 2] = UInt8(c.z.rounded())
            bytes[i * 4 + 3] = UInt8(c.w.rounded())
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: displayP3, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
