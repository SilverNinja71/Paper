import Foundation
import Observation
import SwiftUI

/// App-level state shared by the Mac and iPad apps: the open document, the gallery folder, the brush
/// library, autosave, import/export, and the hook the cloud sync engine listens on.
@MainActor
@Observable
public final class PaperAppModel {
    public private(set) var document: CanvasDocument?
    public private(set) var controller: CanvasController?
    public let interaction = CanvasInteraction()
    public let brushStore: FreeBrushStore
    /// Cloud sync (nil in tests and previews, which must never touch the Keychain or network).
    public let cloud: CloudSyncController?
    /// Folder whose `.paper` packages the gallery shows (local, iCloud Drive, a cloud-provider folder…).
    public var galleryFolder: URL {
        didSet {
            UserDefaults.standard.set(galleryFolder.path, forKey: "Paper.galleryFolder")
            refreshGallery()
        }
    }
    public private(set) var galleryItems: [GalleryItem] = []
    public var errorMessage: String?
    public var editingBrush: BrushPreset?
    public var lastSaved: Date?

    /// Called after each successful save with the package URL and the files that changed (for delta sync).
    @ObservationIgnored public var onProjectSaved: ((URL, [String]) -> Void)?
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored public var autosaveDelay: UInt64 = 4_000_000_000

    public struct GalleryItem: Identifiable, Equatable {
        public var id: URL { url }
        public var url: URL
        public var name: String
        public var thumbnail: CGImage?
        public var size: String
        public var modified: Date

        public static func == (a: GalleryItem, b: GalleryItem) -> Bool { a.url == b.url && a.modified == b.modified }
    }

    public init(brushStore: FreeBrushStore? = nil, galleryFolder: URL? = nil, cloud: CloudSyncController? = nil) {
        self.brushStore = brushStore ?? FreeBrushStore()
        self.cloud = cloud
        let saved = UserDefaults.standard.string(forKey: "Paper.galleryFolder").map { URL(fileURLWithPath: $0) }
        self.galleryFolder = galleryFolder ?? saved ?? Self.defaultGalleryFolder
        refreshGallery()
        if let cloud {
            onProjectSaved = { [weak cloud] url, _ in cloud?.projectDidChange(url) }
            cloud.onProjectUpdated = { [weak self] url in self?.projectChangedOnDisk(url) }
        }
    }

    /// A newer version arrived from another device: refresh the gallery and reload the artwork if it's
    /// open and has no unsaved edits (otherwise the sync engine keeps both versions as a conflicted copy).
    func projectChangedOnDisk(_ url: URL) {
        refreshGallery()
        guard let doc = document, doc.fileURL?.standardizedFileURL == url.standardizedFileURL,
              !doc.hasUnsavedChanges, let fresh = try? CanvasDocument.open(url) else { return }
        fresh.camera = doc.camera
        fresh.tool = doc.tool
        install(fresh)
    }

    /// Call when the app goes to the background: save now and push to the cloud right away.
    public func appWillSuspend() {
        saveNow()
        cloud?.appWillSuspend()
    }

    public nonisolated static var defaultGalleryFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("Paper", isDirectory: true)
    }

    // MARK: Gallery

    public func refreshGallery() {
        let fm = FileManager.default
        try? fm.createDirectory(at: galleryFolder, withIntermediateDirectories: true)
        let urls = (try? fm.contentsOfDirectory(at: galleryFolder, includingPropertiesForKeys: nil)) ?? []
        galleryItems = urls.filter { $0.pathExtension == CanvasDocument.fileExtension }.compactMap { url in
            guard let peek = CanvasDocument.peek(url) else { return nil }
            return GalleryItem(url: url, name: url.deletingPathExtension().lastPathComponent, thumbnail: peek.thumbnail,
                               size: "\(peek.width) × \(peek.height)", modified: peek.modified)
        }
        .sorted { $0.modified > $1.modified }
    }

    private func uniqueURL(for name: String) -> URL {
        let base = name.isEmpty ? "Untitled Artwork" : name
        var url = galleryFolder.appendingPathComponent(base).appendingPathExtension(CanvasDocument.fileExtension)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = galleryFolder.appendingPathComponent("\(base) \(n)").appendingPathExtension(CanvasDocument.fileExtension)
            n += 1
        }
        return url
    }

    public func duplicateArtwork(_ item: GalleryItem) {
        do {
            try FileManager.default.copyItem(at: item.url, to: uniqueURL(for: item.name + " copy"))
        } catch { errorMessage = error.localizedDescription }
        refreshGallery()
    }

    /// Moves the artwork to the Trash (recoverable).
    public func trashArtwork(_ item: GalleryItem) {
        do {
            #if os(macOS)
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            #else
            try FileManager.default.removeItem(at: item.url)
            #endif
        } catch { errorMessage = error.localizedDescription }
        refreshGallery()
    }

    public func renameArtwork(_ item: GalleryItem, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try FileManager.default.moveItem(at: item.url, to: uniqueURL(for: trimmed))
        } catch { errorMessage = error.localizedDescription }
        refreshGallery()
    }

    // MARK: Documents

    public func newDocument(width: Int, height: Int, name: String = "Untitled Artwork",
                            background: SIMD3<Float>? = SIMD3(1, 1, 1)) {
        do {
            let doc = try CanvasDocument(width: width, height: height, name: name, background: background)
            doc.fileURL = uniqueURL(for: name)
            install(doc)
            saveNow()
        } catch { errorMessage = error.localizedDescription }
    }

    public func open(_ url: URL) {
        do {
            install(try CanvasDocument.open(url))
        } catch { errorMessage = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)" }
    }

    private func install(_ doc: CanvasDocument) {
        closeDocument()
        doc.paintBrush = brushStore.brush(doc.paintBrush.id) ?? doc.paintBrush
        let controller = CanvasController(document: doc, interaction: interaction)
        controller.onAppCommand = { [weak self] command in
            if command == .save { self?.saveNow() }
        }
        doc.onChange = { [weak self] in self?.scheduleAutosave() }
        document = doc
        self.controller = controller
    }

    /// Saves and closes the open artwork (back to the gallery).
    public func closeDocument() {
        guard document != nil else { return }
        saveNow()
        document = nil
        controller = nil
        refreshGallery()
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        let delay = autosaveDelay
        autosaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Saves the open artwork into its gallery package right away (also used when the app goes to the background).
    public func saveNow() {
        autosaveTask?.cancel()
        guard let doc = document, doc.hasUnsavedChanges || doc.fileURL.map({ !FileManager.default.fileExists(atPath: $0.path) }) == true
        else { return }
        let url = doc.fileURL ?? uniqueURL(for: doc.name)
        do {
            let written = try doc.save(to: url)
            lastSaved = Date()
            onProjectSaved?(url, written)
        } catch {
            errorMessage = "Couldn't save: \(error.localizedDescription)"
        }
    }

    // MARK: Import / export

    public func importPhoto(_ url: URL) {
        guard let doc = document else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let maxSide = max(doc.width, doc.height) * 2
            let image = try PhotoImporter.load(url, maxDimension: maxSide)
            doc.importImage(image, name: url.deletingPathExtension().lastPathComponent)
        } catch { errorMessage = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)" }
    }

    /// Starts a new artwork sized to a photo, with the photo as its first layer (Lightroom-style editing).
    public func newDocument(fromPhoto url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let image = try PhotoImporter.load(url, maxDimension: 8192)
            newDocument(width: image.width, height: image.height, name: url.deletingPathExtension().lastPathComponent,
                        background: nil)
            document?.importImage(image, name: "Photo")
            document?.addAdjustmentLayer(.develop)
        } catch { errorMessage = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)" }
    }

    /// Encoded bytes of the flattened artwork.
    public func exportData(_ format: PhotoExportFormat) throws -> Data {
        guard let doc = document else { throw CocoaError(.fileNoSuchFile) }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try PhotoExporter.write(doc.flattenedImage(), to: tmp, format: format)
        return try Data(contentsOf: tmp)
    }

    public func importBrushes(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { _ = try brushStore.importFile(url) } catch { errorMessage = error.localizedDescription }
    }
}

extension PhotoExportFormat {
    public var fileExtension: String {
        switch self {
        case .png8, .png16: return "png"
        case .jpeg: return "jpg"
        case .tiff16: return "tiff"
        case .heic: return "heic"
        }
    }

    public var displayName: String {
        switch self {
        case .png8: return "PNG"
        case .png16: return "PNG (16-bit)"
        case .jpeg: return "JPEG"
        case .tiff16: return "TIFF (16-bit)"
        case .heic: return "HEIC"
        }
    }

    public static var menuChoices: [PhotoExportFormat] { [.png8, .png16, .jpeg(quality: 0.92), .tiff16, .heic(quality: 0.9)] }
}
