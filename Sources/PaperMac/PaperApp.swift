import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PaperCore

@main
struct PaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = PaperAppModel(cloud: CloudSyncController.live())

    var body: some Scene {
        WindowGroup("Paper") {
            PaperRootView(model: model)
                .frame(minWidth: 1100, minHeight: 720)
                .onAppear { appDelegate.model = model }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
                    model.appWillSuspend()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.cloud?.syncNow()
                }
        }
        .commands { PaperCommands(model: model) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: PaperAppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.appWillSuspend() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls {
                switch url.pathExtension.lowercased() {
                case "paper": model?.open(url)
                case "abr", "paperbrush", "paperbrushset": model?.importBrushes(url)
                default: model?.newDocument(fromPhoto: url)
                }
            }
        }
    }
}

/// Menu bar commands. The canvas also handles these keys directly when it has focus, so the menus
/// mostly document the shortcuts and work when focus is elsewhere.
struct PaperCommands: Commands {
    let model: PaperAppModel

    private var doc: CanvasDocument? { model.document }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Canvas (2048 × 2048)") { model.newDocument(width: 2048, height: 2048) }
                .keyboardShortcut("n")
            Button("Open Photo for Editing…") { openPanel(types: [.image, .rawImage]) { model.newDocument(fromPhoto: $0) } }
            Button("Open Paper File…") {
                openPanel(types: [.package, .folder]) { model.open($0) }
            }
            .keyboardShortcut("o")
            Divider()
            Button("Back to Gallery") { model.closeDocument() }
                .keyboardShortcut("w")
                .disabled(doc == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { model.saveNow() }
                .keyboardShortcut("s")
                .disabled(doc == nil)
            Button("Import Photo as Layer…") { openPanel(types: [.image, .rawImage]) { model.importPhoto($0) } }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(doc == nil)
            Button("Import Brushes…") {
                openPanel(types: [.data, .json]) { model.importBrushes($0) }
            }
            Menu("Export") {
                ForEach(Array(PhotoExportFormat.menuChoices.enumerated()), id: \.offset) { _, format in
                    Button(format.displayName) { export(format) }
                }
            }
            .disabled(doc == nil)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { doc?.undo() }.keyboardShortcut("z")
            Button("Redo") { doc?.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandMenu("Layer") {
            Button("New Layer") { doc?.addLayer() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Duplicate Layer") { doc?.duplicateLayer() }.keyboardShortcut("j")
            Button("Merge Down") { doc?.mergeDown() }.keyboardShortcut("e")
            Button("Group Layer") { doc?.groupActiveLayer() }.keyboardShortcut("g")
            Button("Delete Layer") { doc?.deleteLayer() }
            Divider()
            Button("Add Layer Mask") { doc?.addMask() }
            Button("Toggle Clipping Mask") {
                if let d = doc, let id = d.activeLayerID { d.setClipping(id, !(d.activeLayer?.clipsToBelow ?? false)) }
            }
            .keyboardShortcut("g", modifiers: [.command, .option])
            Menu("New Adjustment Layer") {
                ForEach(AdjustmentKind.allCases) { k in Button(k.displayName) { doc?.addAdjustmentLayer(k) } }
            }
            Divider()
            Button("Flip Horizontally") { doc?.flipActiveLayer(horizontal: true) }
            Button("Flip Vertically") { doc?.flipActiveLayer(horizontal: false) }
        }
        CommandMenu("Select") {
            Button("All") { doc?.selectAll() }.keyboardShortcut("a")
            Button("Deselect") { doc?.deselect() }.keyboardShortcut("d")
            Button("Inverse") { doc?.invertSelection() }.keyboardShortcut("i", modifiers: [.command, .shift])
            Divider()
            Button("Clear Pixels") { doc?.clearSelectedPixels() }
            Button("Fill with Color") { doc?.fillSelection() }
        }
        CommandGroup(after: .toolbar) {
            Button("Fit to Screen") { model.controller?.perform(.fitToScreen) }
                .keyboardShortcut("0", modifiers: [.command, .option])
            Button("Actual Pixels") { model.controller?.perform(.actualPixels) }.keyboardShortcut("1")
            Button("Zoom In") { model.controller?.perform(.zoomIn) }.keyboardShortcut("=")
            Button("Zoom Out") { model.controller?.perform(.zoomOut) }.keyboardShortcut("-")
            Button("Reset Rotation") { model.controller?.perform(.resetRotation) }
        }
    }

    private func openPanel(types: [UTType], _ action: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = types.contains(.folder) || types.contains(.package)
        panel.treatsFilePackagesAsDirectories = false
        if panel.runModal() == .OK, let url = panel.url { action(url) }
    }

    private func export(_ format: PhotoExportFormat) {
        guard let doc else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = doc.name + "." + format.fileExtension
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.exportData(format).write(to: url, options: .atomic)
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}
