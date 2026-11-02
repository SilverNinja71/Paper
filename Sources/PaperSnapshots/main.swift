// Headless end-to-end check of Paper: paints a demo artwork through the real engine, renders every
// built-in brush, times the hot paths, saves/reopens the file and screenshots each screen — all without
// putting a window on screen.
//
//   swift build -c release --product PaperSnapshots && .build/release/PaperSnapshots <output-dir>

import Foundation
import AppKit
import SwiftUI
import simd
import PaperCore
import CommonKit

let iconMode = CommandLine.arguments.count >= 3 && CommandLine.arguments[1] == "--icon"
let outDir = URL(fileURLWithPath: iconMode ? NSTemporaryDirectory() : (CommandLine.arguments.dropFirst().first ?? "snapshots"),
                 isDirectory: true)
if !iconMode { try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true) }
var failures = 0

func check(_ ok: Bool, _ what: String) {
    print(ok ? "✓ \(what)" : "✗ FAIL \(what)")
    if !ok { failures += 1 }
}

func writePNG(_ image: CGImage?, _ name: String) {
    guard let image else { check(false, "render \(name)"); return }
    let rep = NSBitmapImageRep(cgImage: image)
    try? rep.representation(using: .png, properties: [:])?.write(to: outDir.appendingPathComponent(name))
}

func time(_ body: () -> Void) -> Double {
    let t0 = CFAbsoluteTimeGetCurrent()
    body()
    return (CFAbsoluteTimeGetCurrent() - t0) * 1000
}

/// Wavy pen stroke with a pressure swell and pencil tilt.
func stroke(from a: SIMD2<Float>, to b: SIMD2<Float>, wave: Float = 0, steps: Int = 80, pressure: ClosedRange<Float> = 0.3...1,
            tilt: Float = 0) -> [StrokeSample] {
    (0...steps).map { i in
        let t = Float(i) / Float(steps)
        let dir = simd_normalize(b - a)
        let normal = SIMD2(-dir.y, dir.x)
        let p = a + (b - a) * t + normal * (sin(t * .pi * 2) * wave)
        let pr = pressure.lowerBound + (pressure.upperBound - pressure.lowerBound) * sin(t * .pi)
        return StrokeSample(position: p, pressure: pr, altitude: .pi / 2 - tilt, azimuth: 0.6, timestamp: Double(i) / 120)
    }
}

@MainActor
func snapshotView<V: View>(_ view: V, size: CGSize, name: String) {
    let root = view
        .frame(width: size.width, height: size.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.paperSnapshotMode, true)
        .environment(\.colorScheme, .dark)
    let host = NSHostingView(rootView: root)
    host.sizingOptions = []
    host.frame = CGRect(origin: .zero, size: size)
    // An off-screen window gives SwiftUI a real view hierarchy; it is never ordered on screen.
    let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { check(false, "screenshot \(name)"); return }
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: outDir.appendingPathComponent(name))
    window.contentView = nil
}

@MainActor
func brush(_ name: String) -> BrushPreset {
    FreeBrushStore.builtInBrushes.first { $0.name == name }!
}

@MainActor
func paintDemo() throws -> CanvasDocument {
    let doc = try CanvasDocument(width: 1600, height: 1000, name: "Demo", background: SIMD3(0.96, 0.93, 0.86))

    // Sky: soft airbrush washes.
    doc.rename(doc.activeLayerID!, to: "Sky")
    doc.paintBrush = brush("Soft Airbrush")
    doc.sizes[.brush] = 520
    doc.opacities[.brush] = 1
    for (y, c) in [(Float(80), SIMD3<Float>(0.36, 0.55, 0.86)), (220, SIMD3(0.55, 0.7, 0.92)), (360, SIMD3(0.95, 0.75, 0.6))] {
        doc.color = c
        for _ in 0..<3 { doc.paintStroke(stroke(from: SIMD2(-200, y), to: SIMD2(1800, y + 30), wave: 40, pressure: 0.8...1)) }
    }

    // Sun, screened.
    doc.addLayer(name: "Sun")
    doc.paintBrush = brush("Hard Airbrush")
    doc.color = SIMD3(1, 0.86, 0.45)
    doc.sizes[.brush] = 200
    doc.paintStroke(stroke(from: SIMD2(1180, 250), to: SIMD2(1181, 251), steps: 2, pressure: 1...1))
    doc.setBlendMode(doc.activeLayerID!, .screen)

    // Hills with gouache.
    doc.addLayer(name: "Hills")
    let hills = doc.activeLayerID!
    doc.paintBrush = brush("Gouache")
    doc.sizes[.brush] = 260
    for (y, c) in [(Float(720), SIMD3<Float>(0.32, 0.55, 0.36)), (840, SIMD3(0.22, 0.42, 0.28)), (960, SIMD3(0.15, 0.3, 0.2))] {
        doc.color = c
        doc.paintStroke(stroke(from: SIMD2(-100, y), to: SIMD2(1700, y - 60), wave: 70, pressure: 0.9...1))
        doc.paintStroke(stroke(from: SIMD2(-100, y + 120), to: SIMD2(1700, y + 60), wave: 50, pressure: 0.9...1))
    }

    // Canvas texture clipped to the hills, multiplied.
    doc.addLayer(name: "Texture")
    doc.paintBrush = brush("Canvas Texture")
    doc.color = SIMD3(0.45, 0.4, 0.3)
    doc.sizes[.brush] = 700
    doc.paintStroke(stroke(from: SIMD2(0, 850), to: SIMD2(1600, 850), pressure: 0.7...1))
    doc.setClipping(doc.activeLayerID!, true)
    doc.setBlendMode(doc.activeLayerID!, .multiply)

    // Ink line work with pressure.
    doc.addLayer(name: "Ink")
    doc.paintBrush = brush("Studio Pen")
    doc.color = SIMD3(0.08, 0.08, 0.1)
    doc.sizes[.brush] = 14
    for k in 0..<5 {
        let y = Float(560 + k * 22)
        doc.paintStroke(stroke(from: SIMD2(160, y), to: SIMD2(820, y + 40), wave: 30, pressure: 0.1...1))
    }
    doc.paintBrush = brush("HB Pencil")
    doc.sizes[.brush] = 10
    doc.paintStroke(stroke(from: SIMD2(900, 520), to: SIMD2(1450, 600), wave: 25, pressure: 0.2...0.9, tilt: 0.9))

    // Sparkles and stars.
    doc.addLayer(name: "FX")
    doc.paintBrush = brush("Stars")
    doc.color = SIMD3(1, 0.95, 0.7)
    doc.sizes[.brush] = 40
    doc.paintStroke(stroke(from: SIMD2(150, 120), to: SIMD2(900, 160), wave: 60))
    doc.setBlendMode(doc.activeLayerID!, .linearDodge)

    // A Lightroom-style grade on top.
    doc.addAdjustmentLayer(.develop)
    if let id = doc.activeLayerID, var s = doc.layers.node(id)?.adjustment {
        s.develop.exposure = 0.15
        s.develop.vibrance = 30
        s.develop.clarity = 15
        doc.updateAdjustment(id, s)
    }
    doc.activeLayerID = hills
    return doc
}

@MainActor
func run() throws {
    _ = NSApplication.shared
    print("Paper headless check → \(outDir.path)")

    // 1. Demo artwork.
    var doc: CanvasDocument!
    let paintMs = time { doc = try! paintDemo() }
    check(doc.layers.count == 7, "demo has 7 layers (got \(doc.layers.count))")
    print("  painted demo in \(Int(paintMs)) ms")
    doc.camera = .fit(canvasSize: SIMD2(1600, 1000), viewSize: SIMD2(1200, 760))
    writePNG(doc.compositeThumbnail(maxSide: 1600), "demo-artwork.png")
    let sky = doc.gpu.readPixels(doc.compositor.output, region: IntRect(x: 400, y: 120, width: 1, height: 1))[0]
    check(sky.z > sky.x, "sky is blue (\(sky))")
    let hill = doc.gpu.readPixels(doc.compositor.output, region: IntRect(x: 800, y: 900, width: 1, height: 1))[0]
    check(hill.y > hill.x && hill.y > hill.z, "hills are green (\(hill))")

    // 2. Performance on an iPad-Pro-sized canvas.
    let big = try CanvasDocument(width: 2732, height: 2048, name: "Perf")
    for _ in 0..<7 { big.addLayer() }
    big.paintBrush = brush("Round Brush")
    big.sizes[.brush] = 60
    let samples = stroke(from: SIMD2(100, 1000), to: SIMD2(2600, 1100), wave: 300, steps: 240)
    _ = big.beginStroke(samples[0])
    var worst = 0.0, total = 0.0
    for i in stride(from: 1, to: samples.count, by: 2) {
        let ms = time { big.continueStroke(Array(samples[i..<min(i + 2, samples.count)])) }
        worst = max(worst, ms)
        total += ms
    }
    big.endStroke()
    let avg = total / Double(samples.count / 2)
    print(String(format: "  stroke update on 2732×2048 × 8 layers: avg %.1f ms, worst %.1f ms", avg, worst))
    check(avg < 16, "stroke updates fit in a 60 fps frame on average")
    let fullMs = time { big.recompositeAll() }
    print(String(format: "  full recomposite (8 layers, 2732×2048): %.1f ms", fullMs))

    // 3. Save, reopen, compare.
    let file = outDir.appendingPathComponent("Demo.paper")
    try? FileManager.default.removeItem(at: file)
    var written: [String] = []
    let saveMs = time { written = try! doc.save(to: file) }
    let size = (try? FileManager.default.subpathsOfDirectory(atPath: file.path))?.reduce(0) { sum, sub in
        sum + ((try? FileManager.default.attributesOfItem(atPath: file.appendingPathComponent(sub).path)[.size] as? Int) ?? 0)
    } ?? 0
    print("  saved \(written.count) files, \(size / 1024) KB in \(Int(saveMs)) ms")
    let reopened = try CanvasDocument.open(file)
    let a = doc.gpu.readPixels(doc.compositor.output, region: IntRect(x: 0, y: 0, width: 1600, height: 1000))
    let b = reopened.gpu.readPixels(reopened.compositor.output, region: IntRect(x: 0, y: 0, width: 1600, height: 1000))
    let maxDiff = zip(a, b).reduce(Float(0)) { max($0, simd_reduce_max(simd_abs($1.0 - $1.1))) }
    check(maxDiff < 0.004, "reopened file matches (max difference \(maxDiff))")
    doc.paintStroke(stroke(from: SIMD2(100, 100), to: SIMD2(300, 140)))
    let delta = try doc.save(to: file)
    check(delta.filter { $0.hasPrefix("layers/") }.count == 1, "delta save rewrote only the edited layer (\(delta))")

    // 4. Every built-in brush.
    let sampler = BrushSamplerView(brushes: FreeBrushStore.builtInBrushes)
    snapshotView(sampler, size: CGSize(width: 1300, height: 1500), name: "brush-library.png")

    // 5. Screens.
    let model = PaperAppModel(brushStore: FreeBrushStore(directory: nil), galleryFolder: outDir)
    model.open(file)
    if let d = model.document, let c = model.controller {
        model.interaction.viewSize = SIMD2(780, 640)
        d.camera = .fit(canvasSize: SIMD2(Float(d.width), Float(d.height)), viewSize: SIMD2(780, 640))
        snapshotView(PaperWorkspaceView(model: model, document: d, controller: c), size: CGSize(width: 1280, height: 800),
                     name: "workspace.png")
        snapshotView(LayerManagerSheet(document: d).frame(width: 320, height: 640), size: CGSize(width: 320, height: 640),
                     name: "layers-panel.png")
        snapshotView(BrushPickerPopover(document: d, store: model.brushStore) { _ in }, size: CGSize(width: 520, height: 470),
                     name: "brush-picker.png")
        snapshotView(BrushStudioView(brush: brush("Oil Paint"), store: model.brushStore) { _ in },
                     size: CGSize(width: 1000, height: 600), name: "brush-studio.png")
        snapshotView(ColorPickerPanel(color: .constant(SIMD3(0.9, 0.4, 0.2)), recent: d.recentColors).padding(14),
                     size: CGSize(width: 320, height: 470), name: "color-picker.png")
        if let adj = d.layers.allNodes.first(where: { $0.isAdjustment }) {
            d.activeLayerID = adj.id
            snapshotView(ScrollView { LightroomAdjustmentsView(settings: .constant(adj.adjustment!)).padding(14) },
                         size: CGSize(width: 320, height: 800), name: "adjustments-panel.png")
        }
    }
    model.closeDocument()
    snapshotView(GalleryView(model: model), size: CGSize(width: 1100, height: 700), name: "gallery.png")

    try cloudCheck()
    print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
}

/// Runs `body` on the main actor and pumps the run loop until it finishes (we're in a command-line tool).
@MainActor
func waitFor(_ body: @escaping @MainActor () async -> Void) {
    var done = false
    Task { @MainActor in await body(); done = true }
    while !done { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
}

/// End-to-end: Paper saves an artwork, the gallery folder is linked to a "cloud" (a local folder through
/// the same provider interface the real clouds use), and the package arrives intact, manifest included.
@MainActor
func cloudCheck() throws {
    let root = outDir.appendingPathComponent("cloud-check")
    try? FileManager.default.removeItem(at: root)
    let gallery = root.appendingPathComponent("Gallery"), fakeCloud = root.appendingPathComponent("FakeCloud")
    try FileManager.default.createDirectory(at: fakeCloud, withIntermediateDirectories: true)
    let manager = try UniversalSyncManager(stateDirectory: root.appendingPathComponent("SyncState"))
    let cloudFolder = LocalFolderProvider(rootURL: fakeCloud, displayName: "Test Cloud", id: "testCloud")
    // Real provider objects with an in-memory token store: they report "not configured", never touch the Keychain.
    let rest = CloudProviderCatalog.standardProviders(configuration: CloudProviderConfiguration(),
                                                      tokenStore: InMemoryTokenStore()).filter { $0.id != .iCloudDrive }
    let cloud = CloudSyncController(manager: manager, providers: [cloudFolder] + rest, keysFileURL: nil)
    let model = PaperAppModel(brushStore: FreeBrushStore(directory: nil), galleryFolder: gallery, cloud: cloud)
    model.newDocument(width: 400, height: 300, name: "Synced Sketch")
    model.document?.paintStroke(stroke(from: SIMD2(20, 150), to: SIMD2(380, 150), wave: 40))
    model.saveNow()
    waitFor {
        await cloud.connect(folder: gallery, to: "testCloud", remoteFolder: "/Paper Artworks")
        await manager.syncAll()
        await cloud.refresh()
    }
    let remote = fakeCloud.appendingPathComponent("Paper Artworks/Synced Sketch.paper")
    check(FileManager.default.fileExists(atPath: remote.appendingPathComponent("manifest.json").path),
          "artwork synced to the cloud folder")
    if let copy = try? CanvasDocument.open(remote), let doc = model.document {
        let a = copy.gpu.readPixels(copy.compositor.output, region: IntRect(x: 200, y: 150, width: 1, height: 1))[0]
        let b = doc.gpu.readPixels(doc.compositor.output, region: IntRect(x: 200, y: 150, width: 1, height: 1))[0]
        check(simd_reduce_max(simd_abs(a - b)) < 0.004, "cloud copy opens with the same pixels")
    } else {
        check(false, "cloud copy opens")
    }
    check(cloud.providers.contains { if case .notConfigured = $0.authState { return true }; return false },
          "unconfigured providers explain how to set up keys")
    snapshotView(CloudSettingsView(cloud: cloud, galleryFolder: gallery), size: CGSize(width: 620, height: 640),
                 name: "cloud-settings.png")
    model.closeDocument()
}

/// Grid of every brush with its name and a stroke drawn by the real engine.
struct BrushSamplerView: View {
    let brushes: [BrushPreset]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
            ForEach(brushes) { b in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(b.name) · \(b.category)").font(.caption).foregroundStyle(.secondary)
                    if let img = MainActor.assumeIsolated({ BrushPreviewRenderer.shared.preview(for: b) }) {
                        Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
        .padding(16)
        .background(Color(white: 0.12))
    }
}

/// App icon: three painted strokes on warm paper, drawn by the real brush engine.
@MainActor
func paintIcon(to path: String) throws {
    let doc = try CanvasDocument(width: 1024, height: 1024, name: "Icon", background: nil)
    // Rounded "paper" tile.
    doc.beginLasso(at: SIMD2(100, 100))
    let r: Float = 180
    var pts: [SIMD2<Float>] = []
    for (cx, cy, a0) in [(Float(924) - r, Float(100) + r, -Float.pi / 2), (924 - r, 924 - r, 0),
                         (100 + r, 924 - r, Float.pi / 2), (100 + r, 100 + r, Float.pi)] {
        for k in 0...12 { let a = a0 + Float(k) / 12 * .pi / 2; pts.append(SIMD2(cx + cos(a) * r, cy + sin(a) * r)) }
    }
    for p in pts { doc.extendLasso(to: p) }
    doc.endLasso()
    doc.color = SIMD3(0.97, 0.93, 0.84)
    doc.fillSelection()
    doc.paintBrush = brush("Canvas Texture")
    doc.color = SIMD3(0.8, 0.72, 0.58)
    doc.sizes[.brush] = 900
    doc.opacities[.brush] = 0.5
    doc.paintStroke(stroke(from: SIMD2(512, 100), to: SIMD2(512, 924), pressure: 1...1))
    doc.opacities[.brush] = 1
    doc.paintBrush = brush("Oil Paint")
    doc.sizes[.brush] = 210
    for (y, c) in [(Float(340), SIMD3<Float>(0.93, 0.36, 0.25)), (520, SIMD3(0.98, 0.72, 0.2)), (700, SIMD3(0.2, 0.5, 0.85))] {
        doc.color = c
        doc.paintStroke(stroke(from: SIMD2(220, y + 40), to: SIMD2(800, y - 40), wave: 50, pressure: 0.6...1))
    }
    doc.deselect()
    guard let img = doc.compositeThumbnail(maxSide: 1024) else { return }
    try NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

MainActor.assumeIsolated {
    if iconMode {
        do { try paintIcon(to: CommandLine.arguments[2]) } catch { print("icon failed: \(error)"); exit(1) }
        exit(0)
    }
    do { try run() } catch { print("✗ FAIL \(error)"); failures += 1 }
}
exit(failures == 0 ? 0 : 1)
