import SwiftUI
import MetalKit
import simd
import Observation

// MARK: - Camera maths

extension CanvasCamera {
    /// View point (points, origin top-left) → canvas pixel.
    public func toCanvas(_ v: SIMD2<Float>, viewSize: SIMD2<Float>, canvasSize: SIMD2<Float>) -> SIMD2<Float> {
        rotate(v - viewSize / 2 - pan, by: -rotation) / zoom + canvasSize / 2
    }

    /// Canvas pixel → view point.
    public func toView(_ c: SIMD2<Float>, viewSize: SIMD2<Float>, canvasSize: SIMD2<Float>) -> SIMD2<Float> {
        rotate((c - canvasSize / 2) * zoom, by: rotation) + viewSize / 2 + pan
    }

    private func rotate(_ v: SIMD2<Float>, by a: Float) -> SIMD2<Float> {
        let c = cos(a), s = sin(a)
        return SIMD2(c * v.x - s * v.y, s * v.x + c * v.y)
    }

    public mutating func zoom(by factor: Float, around p: SIMD2<Float>, viewSize: SIMD2<Float>, canvasSize: SIMD2<Float>) {
        let anchor = toCanvas(p, viewSize: viewSize, canvasSize: canvasSize)
        zoom = min(max(zoom * factor, 0.02), 64)
        pan += p - toView(anchor, viewSize: viewSize, canvasSize: canvasSize)
    }

    public mutating func rotate(by radians: Float, around p: SIMD2<Float>, viewSize: SIMD2<Float>, canvasSize: SIMD2<Float>) {
        let anchor = toCanvas(p, viewSize: viewSize, canvasSize: canvasSize)
        rotation += radians
        pan += p - toView(anchor, viewSize: viewSize, canvasSize: canvasSize)
    }

    public static func fit(canvasSize: SIMD2<Float>, viewSize: SIMD2<Float>, margin: Float = 0.92) -> CanvasCamera {
        var c = CanvasCamera()
        guard canvasSize.x > 0, canvasSize.y > 0, viewSize.x > 0, viewSize.y > 0 else { return c }
        c.zoom = min(viewSize.x / canvasSize.x, viewSize.y / canvasSize.y) * margin
        return c
    }
}

// MARK: - Live interaction state (hover cursor etc.) kept apart so it doesn't redraw the whole UI

@MainActor
@Observable
public final class CanvasInteraction {
    public var hover: SIMD2<Float>?
    public var viewSize: SIMD2<Float> = SIMD2(800, 600)
    public var isPenHovering = false
    /// Brief on-canvas messages ("Undo Brush", "Layer is locked").
    public var toast: String?
    public init() {}
}

// MARK: - Present shader

enum CanvasShader: ShaderModule {
    static let moduleName = "canvas"
    static let source = """
    struct PresentUniforms {
        float2 viewSize;      // drawable pixels
        float2 canvasSize;
        float2 pan;           // drawable pixels
        float zoom;           // drawable pixels per canvas pixel
        float rotation;
        float4 backdrop;      // gamma-encoded
        uint showChecker;
        uint hasSelection;
        float time;
        uint pad;
    };

    struct VOut { float4 position [[position]]; };

    vertex VOut presentVertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VOut o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return o;
    }

    fragment float4 presentFragment(VOut in [[stage_in]],
                                    texture2d<float> composite [[texture(0)]],
                                    texture2d<float> selection [[texture(1)]],
                                    sampler linearS [[sampler(0)]],
                                    sampler nearestS [[sampler(1)]],
                                    constant PresentUniforms& U [[buffer(0)]]) {
        float2 v = in.position.xy;
        float2 c = rotate2(v - U.viewSize * 0.5 - U.pan, -U.rotation) / U.zoom + U.canvasSize * 0.5;
        float4 col;
        if (c.x < 0.0 || c.y < 0.0 || c.x >= U.canvasSize.x || c.y >= U.canvasSize.y) {
            col = U.backdrop;
        } else {
            float2 uv = c / U.canvasSize;
            if (U.zoom >= 3.0) {
                col = composite.sample(nearestS, uv);           // crisp pixels when zoomed in
            } else if (U.zoom >= 1.0) {
                col = composite.sample(linearS, uv);
            } else {
                // Zoomed out: average a 4×4 footprint so fine detail doesn't shimmer.
                float2 step = (1.0 / U.zoom) / U.canvasSize;
                col = 0.0;
                for (int j = 0; j < 4; j++) {
                    for (int i = 0; i < 4; i++) {
                        col += composite.sample(linearS, uv + (float2(i, j) - 1.5) * 0.25 * step);
                    }
                }
                col /= 16.0;
            }
            if (U.showChecker != 0) {
                float2 cell = floor(v / 12.0);
                float checker = fmod(cell.x + cell.y, 2.0) < 1.0 ? 0.92 : 0.78;
                col = col + float4(checker, checker, checker, 1.0) * (1.0 - col.a);
            }
            if (U.hasSelection != 0) {
                float d = 1.0 / U.zoom;
                float s0 = selection.sample(linearS, uv).r;
                float sx = selection.sample(linearS, (c + float2(d, 0.0)) / U.canvasSize).r;
                float sy = selection.sample(linearS, (c + float2(0.0, d)) / U.canvasSize).r;
                float edge = max(abs(s0 - sx), abs(s0 - sy));
                if (edge > 0.2) {
                    float stripe = fract((v.x + v.y + U.time * 30.0) / 10.0) < 0.5 ? 0.0 : 1.0;
                    col = float4(float3(stripe), 1.0);
                } else if (s0 < 0.5) {
                    col.rgb = mix(col.rgb, float3(0.35, 0.45, 0.75), 0.12);
                }
            }
        }
        // The drawable is extended *linear* Display P3, so values above 1.0 show as HDR on EDR screens.
        return float4(srgbToLinear(col.rgb), 1.0);
    }
    """
}

struct PresentUniforms {
    var viewSize: SIMD2<Float>
    var canvasSize: SIMD2<Float>
    var pan: SIMD2<Float>
    var zoom: Float
    var rotation: Float
    var backdrop: SIMD4<Float>
    var showChecker: UInt32
    var hasSelection: UInt32
    var time: Float
    var pad: UInt32 = 0
}

/// Draws the document's composite into an MTKView.
@MainActor
public final class CanvasRenderer: NSObject, MTKViewDelegate {
    let gpu: PaperGPU
    weak var document: CanvasDocument?
    var backdrop = SIMD4<Float>(0.16, 0.16, 0.17, 1)
    private var pipeline: MTLRenderPipelineState?
    private let start = Date()

    public init(gpu: PaperGPU = .shared) {
        self.gpu = gpu
        super.init()
        pipeline = try? Self.makePipeline(gpu: gpu, format: .rgba16Float)
    }

    static func makePipeline(gpu: PaperGPU, format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        let lib = try gpu.library(CanvasShader.self)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "presentVertex")
        d.fragmentFunction = lib.makeFunction(name: "presentFragment")
        d.colorAttachments[0].pixelFormat = format
        return try gpu.device.makeRenderPipelineState(descriptor: d)
    }

    public nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated { view.setNeedsDisplayCompat() }
    }

    public nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { render(view) }
    }

    private func render(_ view: MTKView) {
        guard let doc = document, let pipeline, let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable, let cb = gpu.queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        let scale = Float(view.drawableSize.width / max(view.bounds.width, 1))
        var u = PresentUniforms(viewSize: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
                                canvasSize: SIMD2(Float(doc.width), Float(doc.height)),
                                pan: doc.camera.pan * scale, zoom: doc.camera.zoom * scale, rotation: doc.camera.rotation,
                                backdrop: backdrop, showChecker: doc.backgroundVisible ? 0 : 1,
                                hasSelection: doc.selectionTexture == nil ? 0 : 1,
                                time: Float(Date().timeIntervalSince(start)))
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(doc.compositor.output, index: 0)
        enc.setFragmentTexture(doc.selectionTexture ?? gpu.dummyMask, index: 1)
        enc.setFragmentSamplerState(gpu.linearClamp, index: 0)
        enc.setFragmentSamplerState(gpu.nearestClamp, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<PresentUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }
}

extension MTKView {
    func setNeedsDisplayCompat() {
        #if os(macOS)
        needsDisplay = true
        #else
        setNeedsDisplay()
        #endif
    }

    func configureForPaper(gpu: PaperGPU) {
        device = gpu.device
        colorPixelFormat = .rgba16Float
        framebufferOnly = true
        enableSetNeedsDisplay = true
        isPaused = true
        if let layer = layer as? CAMetalLayer {
            layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            #if os(macOS)
            layer.wantsExtendedDynamicRangeContent = true
            #endif
        }
    }
}

// MARK: - Tool controller (pointer → document actions)

/// Turns pointer events, gestures and keys into document actions for the current tool.
@MainActor
public final class CanvasController: PointerCaptureDelegate {
    public let document: CanvasDocument
    public let interaction: CanvasInteraction
    /// File-level shortcuts (save/export/import) the app handles.
    public var onAppCommand: ((PaperCommand) -> Void)?

    private enum Drag { case none, stroke, lasso, eyedropper, move, scale(corner: Int), rotate(start: Float, initial: Float) }
    private var drag = Drag.none
    private var dragStart = SIMD2<Float>.zero
    private var initialTransform: TransformState?

    public init(document: CanvasDocument, interaction: CanvasInteraction) {
        self.document = document
        self.interaction = interaction
    }

    private var canvasSize: SIMD2<Float> { SIMD2(Float(document.width), Float(document.height)) }

    private func canvasPoint(_ v: SIMD2<Float>) -> SIMD2<Float> {
        document.camera.toCanvas(v, viewSize: interaction.viewSize, canvasSize: canvasSize)
    }

    private func sample(_ e: PointerEvent, at v: SIMD2<Float>, pressure: Float? = nil) -> StrokeSample {
        StrokeSample(position: canvasPoint(v), pressure: pressure ?? e.pressure, altitude: e.altitude,
                     azimuth: e.azimuth - document.camera.rotation, timestamp: e.timestamp)
    }

    private func flash(_ message: String?) {
        guard let message else { return }
        interaction.toast = message
        let current = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if self.interaction.toast == current { self.interaction.toast = nil }
        }
    }

    public func pointer(_ e: PointerEvent) {
        let doc = document
        let c = canvasPoint(e.location)
        switch e.phase {
        case .hover:
            interaction.hover = e.location
            interaction.isPenHovering = e.device == .pen
        case .began:
            interaction.hover = e.location
            dragStart = c
            if e.alternate || doc.tool == .eyedropper {
                drag = .eyedropper
                doc.pickColor(at: c)
                return
            }
            switch doc.tool {
            case .brush, .smudge, .eraser:
                doc.statusMessage = nil
                if doc.beginStroke(sample(e, at: e.location)) { drag = .stroke } else { flash(doc.statusMessage) }
            case .lasso:
                drag = .lasso
                doc.beginLasso(at: c)
            case .fill:
                doc.fill(at: c)
                flash(doc.statusMessage)
                doc.statusMessage = nil
            case .move:
                if doc.transformState == nil { doc.beginTransform() }
                guard let t = doc.transformState else { flash(doc.statusMessage); return }
                initialTransform = t
                drag = transformDrag(for: e.location, transform: t)
            case .eyedropper:
                break
            }
        case .moved:
            interaction.hover = e.location
            switch drag {
            case .stroke:
                var samples: [StrokeSample] = []
                for (i, p) in e.coalesced.enumerated() {
                    samples.append(sample(e, at: p, pressure: i < e.coalescedPressure.count ? e.coalescedPressure[i] : nil))
                }
                samples.append(sample(e, at: e.location))
                doc.continueStroke(samples)
            case .lasso: doc.extendLasso(to: c)
            case .eyedropper: doc.pickColor(at: c)
            case .move:
                guard let t0 = initialTransform else { return }
                doc.updateTransform { $0.translation = t0.translation + (c - dragStart) }
            case .scale(let corner):
                guard let t0 = initialTransform else { return }
                let corners = t0.corners
                let anchor = corners[(corner + 2) % 4]
                let from = simd_distance(dragStart, anchor), to = simd_distance(c, anchor)
                guard from > 1 else { return }
                let f = to / from
                doc.updateTransform { t in
                    t.scale = t0.scale * f
                    // Keep the opposite corner pinned.
                    let pivot = t0.pivot + t0.translation
                    t.translation = t0.translation + (anchor - pivot) * (1 - f)
                }
            case .rotate(let start, let initial):
                guard let t0 = initialTransform else { return }
                let centre = t0.pivot + t0.translation
                let angle = atan2(c.y - centre.y, c.x - centre.x)
                var r = initial + angle - start
                if e.shift { r = (r / (.pi / 12)).rounded() * (.pi / 12) }
                doc.updateTransform { $0.rotation = r }
            case .none: break
            }
        case .ended, .cancelled:
            switch drag {
            case .stroke: e.phase == .cancelled ? doc.cancelStroke() : doc.endStroke()
            case .lasso: doc.endLasso(e.shift ? .add : e.alternate ? .subtract : .replace)
            default: break
            }
            drag = .none
            initialTransform = nil
        }
    }

    /// Hit-tests the transform box: corners scale, inside moves, outside rotates.
    private func transformDrag(for v: SIMD2<Float>, transform t: TransformState) -> Drag {
        let corners = t.corners.map { document.camera.toView($0, viewSize: interaction.viewSize, canvasSize: canvasSize) }
        for (i, p) in corners.enumerated() where simd_distance(p, v) < 14 { return .scale(corner: i) }
        if pointInPolygon(v, corners) { return .move }
        let centre = t.pivot + t.translation
        let c = canvasPoint(v)
        return .rotate(start: atan2(c.y - centre.y, c.x - centre.x), initial: t.rotation)
    }

    private func pointInPolygon(_ p: SIMD2<Float>, _ poly: [SIMD2<Float>]) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    public func gesture(_ g: CanvasGesture) {
        let vs = interaction.viewSize
        switch g {
        case .pan(let d): document.camera.pan += d
        case .zoom(let f, let p): document.camera.zoom(by: f, around: p, viewSize: vs, canvasSize: canvasSize)
        case .rotate(let r, let p): document.camera.rotate(by: r, around: p, viewSize: vs, canvasSize: canvasSize)
        case .undoTap: document.undo(); flash(document.statusMessage)
        case .redoTap: document.redo(); flash(document.statusMessage)
        }
    }

    public func key(_ stroke: KeyStroke, isDown: Bool) -> Bool {
        guard isDown, let command = PaperKeymap.resolve(stroke) else { return false }
        perform(command)
        return true
    }

    public func perform(_ command: PaperCommand) {
        let vs = interaction.viewSize
        switch command {
        case .fitToScreen: document.camera = .fit(canvasSize: canvasSize, viewSize: vs)
        case .actualPixels:
            document.camera.zoom(by: 1 / document.camera.zoom, around: vs / 2, viewSize: vs, canvasSize: canvasSize)
        case .zoomIn: document.camera.zoom(by: 1.25, around: vs / 2, viewSize: vs, canvasSize: canvasSize)
        case .zoomOut: document.camera.zoom(by: 0.8, around: vs / 2, viewSize: vs, canvasSize: canvasSize)
        case .resetRotation: document.camera.rotation = 0
        case .save, .export, .importImage: onAppCommand?(command)
        default:
            document.perform(command)
            if command == .undo || command == .redo { flash(document.statusMessage) }
        }
    }
}

// MARK: - SwiftUI wrapper

private struct SnapshotModeKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True while rendering headless screenshots (swaps the live Metal view for an off-screen image).
    public var paperSnapshotMode: Bool {
        get { self[SnapshotModeKey.self] }
        set { self[SnapshotModeKey.self] = newValue }
    }
}

/// The Metal canvas plus vector overlays (brush cursor, lasso, transform box).
public struct PaperCanvasView: View {
    let document: CanvasDocument
    let controller: CanvasController
    @Bindable var interaction: CanvasInteraction
    @Environment(\.paperSnapshotMode) private var snapshotMode

    public init(document: CanvasDocument, controller: CanvasController) {
        self.document = document
        self.controller = controller
        self.interaction = controller.interaction
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                if snapshotMode {
                    // Headless screenshots can't capture a live MTKView; draw the same pixels off-screen.
                    if let img = renderCanvasSnapshot(document, viewSize: SIMD2(Int(geo.size.width * 2), Int(geo.size.height * 2)),
                                                      scale: 2) {
                        Image(decorative: img, scale: 2)
                    }
                } else {
                    MetalCanvas(document: document, controller: controller, revision: document.displayRevision,
                                camera: document.camera, animating: document.hasSelection)
                }
                CanvasOverlay(document: document, interaction: interaction)
                    .allowsHitTesting(false)
                if let toast = interaction.toast {
                    Text(toast)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.top, 14)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .onAppear { updateSize(geo.size, fit: true) }
            .onChange(of: geo.size) { _, s in updateSize(s, fit: false) }
        }
        .clipped()
    }

    private func updateSize(_ s: CGSize, fit: Bool) {
        interaction.viewSize = SIMD2(Float(s.width), Float(s.height))
        if fit { controller.perform(.fitToScreen) }
    }
}

/// Brush outline, lasso path and transform handles, drawn in view space.
struct CanvasOverlay: View {
    let document: CanvasDocument
    let interaction: CanvasInteraction

    var body: some View {
        // Read observable state here (on the main actor); the Canvas closure runs separately.
        let camera = document.camera
        let cs = SIMD2(Float(document.width), Float(document.height))
        let lasso = document.lassoPath
        let transform = document.transformState
        let brushDiameter = document.tool.usesBrush ? document.currentSize * camera.zoom : 0
        let hover = interaction.hover
        return Canvas { ctx, size in
            let vs = SIMD2(Float(size.width), Float(size.height))
            func pt(_ c: SIMD2<Float>) -> CGPoint {
                let v = camera.toView(c, viewSize: vs, canvasSize: cs)
                return CGPoint(x: CGFloat(v.x), y: CGFloat(v.y))
            }
            // Lasso in progress.
            if lasso.count > 1 {
                var path = Path()
                path.addLines(lasso.map(pt))
                ctx.stroke(path, with: .color(.black.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5))
                ctx.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
            }
            // Transform box.
            if let t = transform {
                let corners = t.corners.map(pt)
                var box = Path()
                box.addLines(corners + [corners[0]])
                ctx.stroke(box, with: .color(.accentColor), lineWidth: 1.5)
                for c in corners {
                    let r = CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)
                    ctx.fill(Path(ellipseIn: r), with: .color(.white))
                    ctx.stroke(Path(ellipseIn: r), with: .color(.accentColor), lineWidth: 1.5)
                }
            }
            // Brush cursor.
            if brushDiameter > 0, let h = hover {
                let d = CGFloat(brushDiameter)
                if d > 3 {
                    let r = CGRect(x: CGFloat(h.x) - d / 2, y: CGFloat(h.y) - d / 2, width: d, height: d)
                    ctx.stroke(Path(ellipseIn: r), with: .color(.black.opacity(0.55)), lineWidth: 2)
                    ctx.stroke(Path(ellipseIn: r), with: .color(.white.opacity(0.9)), lineWidth: 1)
                }
            }
        }
    }
}

#if os(macOS)
struct MetalCanvas: NSViewRepresentable {
    let document: CanvasDocument
    let controller: CanvasController
    let revision: Int
    let camera: CanvasCamera
    let animating: Bool

    func makeCoordinator() -> CanvasRenderer { CanvasRenderer() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let mtk = MTKView(frame: .zero)
        mtk.configureForPaper(gpu: context.coordinator.gpu)
        mtk.delegate = context.coordinator
        context.coordinator.document = document
        let capture = PointerCaptureView()
        capture.delegate = controller
        for v in [mtk, capture] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                v.topAnchor.constraint(equalTo: container.topAnchor),
                v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.document = document
        guard let mtk = container.subviews.first as? MTKView else { return }
        if let capture = container.subviews.last as? PointerCaptureView { capture.delegate = controller }
        mtk.isPaused = !animating
        mtk.preferredFramesPerSecond = animating ? 30 : 60
        mtk.needsDisplay = true
    }
}
#else
struct MetalCanvas: UIViewRepresentable {
    let document: CanvasDocument
    let controller: CanvasController
    let revision: Int
    let camera: CanvasCamera
    let animating: Bool

    func makeCoordinator() -> CanvasRenderer { CanvasRenderer() }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        let mtk = MTKView(frame: .zero)
        mtk.configureForPaper(gpu: context.coordinator.gpu)
        mtk.delegate = context.coordinator
        context.coordinator.document = document
        let capture = PointerCaptureView(frame: .zero)
        capture.delegate = controller
        for v in [mtk, capture] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                v.topAnchor.constraint(equalTo: container.topAnchor),
                v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        context.coordinator.document = document
        guard let mtk = container.subviews.first as? MTKView else { return }
        if let capture = container.subviews.last as? PointerCaptureView { capture.delegate = controller }
        mtk.isPaused = !animating
        mtk.preferredFramesPerSecond = animating ? 30 : 60
        mtk.setNeedsDisplay()
    }
}
#endif

/// Off-screen render of what the canvas view shows (used for headless snapshots).
@MainActor
public func renderCanvasSnapshot(_ doc: CanvasDocument, viewSize: SIMD2<Int>, scale: Float = 1) -> CGImage? {
    let gpu = doc.gpu
    guard let pipeline = try? CanvasRenderer.makePipeline(gpu: gpu, format: .rgba16Float),
          let target = try? gpu.makeTexture(width: viewSize.x, height: viewSize.y, label: "snapshot") else { return nil }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    var u = PresentUniforms(viewSize: SIMD2(Float(viewSize.x), Float(viewSize.y)),
                            canvasSize: SIMD2(Float(doc.width), Float(doc.height)),
                            pan: doc.camera.pan * scale, zoom: doc.camera.zoom * scale, rotation: doc.camera.rotation,
                            backdrop: SIMD4(0.16, 0.16, 0.17, 1), showChecker: doc.backgroundVisible ? 0 : 1,
                            hasSelection: doc.selectionTexture == nil ? 0 : 1, time: 0)
    gpu.run("snapshot") { cb in
        let enc = cb.makeRenderCommandEncoder(descriptor: pass)!
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(doc.compositor.output, index: 0)
        enc.setFragmentTexture(doc.selectionTexture ?? gpu.dummyMask, index: 1)
        enc.setFragmentSamplerState(gpu.linearClamp, index: 0)
        enc.setFragmentSamplerState(gpu.nearestClamp, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<PresentUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }
    // The target holds linear light; convert back to gamma for an ordinary PNG.
    let px = gpu.readPixels(target).map { p -> SIMD4<Float> in
        func enc(_ x: Float) -> Float { x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055 }
        return SIMD4(enc(p.x), enc(p.y), enc(p.z), 1)
    }
    return ImageConversion.cgImage(premultiplied: px, width: viewSize.x, height: viewSize.y)
}
