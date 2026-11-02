import SwiftUI
import UniformTypeIdentifiers

/// The painting screen: top bar (gallery, actions, adjustments, tools, brushes, colour), Procreate's
/// left-hand size/opacity sliders, the canvas, and an inspector (Layers / Color / Brush / Adjust).
public struct PaperWorkspaceView: View {
    @Bindable var model: PaperAppModel
    let document: CanvasDocument
    let controller: CanvasController
    @State private var tab: InspectorTab = .layers
    @State private var showInspector = true
    @State private var showBrushes = false
    @State private var showColor = false
    @State private var importingPhoto = false
    @State private var exportFormat: PhotoExportFormat?
    @State private var exportDocument: ExportedFile?

    enum InspectorTab: String, CaseIterable, Identifiable {
        case layers = "Layers", color = "Color", brush = "Brush", adjust = "Adjust"
        var id: String { rawValue }
    }

    public init(model: PaperAppModel, document: CanvasDocument, controller: CanvasController) {
        self.model = model
        self.document = document
        self.controller = controller
    }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HStack(spacing: 0) {
                sideBar
                ZStack(alignment: .top) {
                    PaperCanvasView(document: document, controller: controller)
                    if document.transformState != nil { transformBar.padding(.top, 10) }
                }
                if showInspector {
                    Divider()
                    inspector.frame(width: 320)
                }
            }
        }
        .sheet(item: $model.editingBrush) { brush in
            BrushStudioView(brush: brush, store: model.brushStore) { edited in
                if let edited, document.currentBrush.id == edited.id { document.currentBrush = edited }
                model.editingBrush = nil
            }
        }
        .fileImporter(isPresented: $importingPhoto, allowedContentTypes: [.image, .rawImage],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { urls.forEach(model.importPhoto) }
        }
        .fileExporter(isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
                      document: exportDocument, contentType: exportDocument?.type ?? .png,
                      defaultFilename: document.name) { _ in exportDocument = nil }
        .onChange(of: document.activeLayerID) { _, _ in
            if document.activeLayer?.isAdjustment == true { tab = .adjust; showInspector = true }
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 14) {
            Button { model.closeDocument() } label: { Label("Gallery", systemImage: "square.grid.2x2") }
                .help("Back to the gallery (saves automatically)")
            Menu {
                Button("Import Photo…") { importingPhoto = true }
                Menu("Export") {
                    ForEach(Array(PhotoExportFormat.menuChoices.enumerated()), id: \.offset) { _, f in
                        Button(f.displayName) { export(f) }
                    }
                }
                Divider()
                Button("Flip Layer Horizontally") { document.flipActiveLayer(horizontal: true) }
                Button("Flip Layer Vertically") { document.flipActiveLayer(horizontal: false) }
                Divider()
                Button("Select All") { document.selectAll() }
                Button("Deselect") { document.deselect() }
                Button("Invert Selection") { document.invertSelection() }
                Button("Clear Selected Pixels") { document.clearSelectedPixels() }
                Button("Fill Selection with Color") { document.fillSelection() }
            } label: { Image(systemName: "wrench.adjustable") }
                .menuStyle(.borderlessButton).fixedSize().help("Actions")
            Menu {
                ForEach(AdjustmentKind.allCases) { k in
                    Button(k.displayName) { document.addAdjustmentLayer(k); tab = .adjust; showInspector = true }
                }
            } label: { Image(systemName: "camera.filters") }
                .menuStyle(.borderlessButton).fixedSize().help("Add an adjustment layer")

            Text(document.name).font(.headline).lineLimit(1)
            if let cloud = model.cloud { CloudStatusBadge(cloud: cloud) }
            if let saved = model.lastSaved {
                Text(document.hasUnsavedChanges ? "Edited" : "Saved \(saved.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()

            HStack(spacing: 4) {
                ForEach(PaperTool.allCases) { t in
                    Button {
                        controller.perform(.tool(t))
                    } label: {
                        Image(systemName: t.symbol)
                            .frame(width: 30, height: 26)
                            .background(document.tool == t ? Color.accentColor.opacity(0.25) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("\(t.displayName) (\(t.shortcut))")
                }
            }

            Button { showBrushes.toggle() } label: {
                Label(document.currentBrush.name, systemImage: "paintbrush")
            }
            .popover(isPresented: $showBrushes, arrowEdge: .bottom) {
                BrushPickerPopover(document: document, store: model.brushStore) { brush in
                    showBrushes = false
                    model.editingBrush = brush
                }
            }
            Button { showColor.toggle() } label: {
                Circle().fill(Color(p3: document.color)).frame(width: 24, height: 24)
                    .overlay(Circle().stroke(.secondary.opacity(0.6), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showColor, arrowEdge: .bottom) {
                ColorPickerPanel(color: Binding(get: { document.color }, set: { document.color = $0 }),
                                 recent: document.recentColors)
                    .padding(14).frame(width: 300)
            }
            Button { showInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                .help("Show or hide the inspector")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    private func export(_ format: PhotoExportFormat) {
        do {
            let data = try model.exportData(format)
            let type = UTType(filenameExtension: format.fileExtension) ?? .png
            exportDocument = ExportedFile(data: data, type: type)
        } catch { model.errorMessage = error.localizedDescription }
    }

    // MARK: Left sliders (Procreate style)

    private var sideBar: some View {
        VStack(spacing: 16) {
            VerticalSlider(value: Binding(get: { sizeToSlider(document.currentSize) },
                                          set: { document.currentSize = sliderToSize($0) }))
                .frame(width: 28, height: 170)
                .help("Brush size ( [ and ] )")
            Text("\(Int(document.currentSize))").font(.caption2.monospacedDigit())
            VerticalSlider(value: Binding(get: { document.currentOpacity }, set: { document.currentOpacity = $0 }))
                .frame(width: 28, height: 130)
                .help("Opacity")
            Text("\(Int(document.currentOpacity * 100))%").font(.caption2.monospacedDigit())
            Spacer()
            Button { document.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.borderless).disabled(!document.canUndo).help("Undo (⌘Z)")
            Button { document.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(.borderless).disabled(!document.canRedo).help("Redo (⇧⌘Z)")
        }
        .padding(.vertical, 16)
        .frame(width: 52)
        .background(.bar)
    }

    // Sizes span 1…2000 px; a log scale makes small sizes easy to dial in.
    private func sizeToSlider(_ s: Float) -> Float { log(max(s, 1)) / log(2000) }
    private func sliderToSize(_ v: Float) -> Float { max(1, exp(v * log(2000))).rounded() }

    // MARK: Transform bar

    private var transformBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            Text("Drag inside to move, corners to scale, outside to rotate (⇧ snaps 15°)").font(.caption)
            Button("Flip H") { document.cancelTransform(); document.flipActiveLayer(horizontal: true); document.beginTransform() }
            Button("Cancel") { document.cancelTransform() }
            Button("Done") { document.commitTransform() }.keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: Inspector

    private var inspector: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(InspectorTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(10)
            Divider()
            switch tab {
            case .layers:
                LayerManagerSheet(document: document)
            case .color:
                ScrollView {
                    ColorPickerPanel(color: Binding(get: { document.color }, set: { document.color = $0 }),
                                     recent: document.recentColors).padding(14)
                }
            case .brush:
                brushInspector
            case .adjust:
                adjustInspector
            }
        }
        .background(.background)
    }

    private var brushInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(document.currentBrush.name).font(.title3.bold())
                Text(document.currentBrush.category).font(.caption).foregroundStyle(.secondary)
                if let img = BrushPreviewRenderer.shared.preview(for: document.currentBrush, color: document.color) {
                    Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                }
                labeledSlider("StreamLine", Binding(get: { document.currentBrush.streamline },
                                                    set: { var b = document.currentBrush; b.streamline = $0; document.currentBrush = b }))
                labeledSlider("Hardness", Binding(get: { document.currentBrush.hardness },
                                                  set: { var b = document.currentBrush; b.hardness = $0; document.currentBrush = b }))
                labeledSlider("Flow", Binding(get: { document.currentBrush.flow },
                                              set: { var b = document.currentBrush; b.flow = max($0, 0.01); document.currentBrush = b }))
                Button("Open Brush Studio…") { model.editingBrush = document.currentBrush }
                Divider()
                Text("Fill tolerance").font(.caption)
                Slider(value: Binding(get: { document.fillTolerance }, set: { document.fillTolerance = $0 }), in: 0...0.6)
            }
            .padding(14)
        }
    }

    private func labeledSlider(_ title: String, _ value: Binding<Float>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title); Spacer(); Text("\(Int(value.wrappedValue * 100))%").foregroundStyle(.secondary) }
                .font(.callout)
            Slider(value: value, in: 0...1)
        }
    }

    @ViewBuilder private var adjustInspector: some View {
        if let node = document.activeLayer, let settings = node.adjustment {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(node.name).font(.title3.bold())
                    LightroomAdjustmentsView(settings: Binding(get: { settings },
                                                               set: { document.updateAdjustment(node.id, $0) }))
                }
                .padding(14)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Adjustment layers change everything below them without touching your pixels.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(AdjustmentKind.allCases) { k in
                    Button("Add \(k.displayName)") { document.addAdjustmentLayer(k) }
                }
                Spacer()
            }
            .padding(14)
        }
    }
}

/// A vertical slider (0…1), filled from the bottom.
struct VerticalSlider: View {
    @Binding var value: Float

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack(alignment: .bottom) {
                Capsule().fill(.secondary.opacity(0.2))
                Capsule().fill(Color.accentColor.opacity(0.7))
                    .frame(height: max(geo.size.width, CGFloat(value) * h))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                value = Float(min(max(1 - g.location.y / h, 0), 1))
            })
        }
    }
}

/// Bytes handed to `fileExporter`.
struct ExportedFile: FileDocument {
    static var readableContentTypes: [UTType] { [.png, .jpeg, .tiff, .heic] }
    var data: Data
    var type: UTType

    init(data: Data, type: UTType) {
        self.data = data
        self.type = type
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        type = configuration.contentType
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
