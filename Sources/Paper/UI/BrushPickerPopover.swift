import SwiftUI
import UniformTypeIdentifiers
import simd

/// Paints sample strokes with the real engine for brush thumbnails, cached per brush version.
@MainActor
public final class BrushPreviewRenderer {
    public static let shared = BrushPreviewRenderer()
    private var cache: [Int: CGImage] = [:]
    private var doc: CanvasDocument?

    /// A wavy stroke with a pressure swell and some tilt, like a signature swoosh.
    public static func sampleStroke(width: Float, height: Float, tilt: Bool = true) -> [StrokeSample] {
        (0...60).map { i in
            let t = Float(i) / 60
            let x = width * (0.08 + 0.84 * t)
            let y = height * (0.5 + 0.28 * sin(t * 2 * .pi))
            let pressure = 0.25 + 0.75 * sin(t * .pi)
            return StrokeSample(position: SIMD2(x, y), pressure: pressure,
                                altitude: tilt ? .pi / 2 - 0.9 * sin(t * .pi) : .pi / 2,
                                azimuth: 0.4, timestamp: Double(i) / 120)
        }
    }

    public func preview(for brush: BrushPreset, color: SIMD3<Float>? = nil, width: Int = 300, height: Int = 72) -> CGImage? {
        var hasher = Hasher()
        hasher.combine(brush)
        hasher.combine(width)
        hasher.combine(height)
        if let color { hasher.combine(color.x); hasher.combine(color.y); hasher.combine(color.z) }
        let key = hasher.finalize()
        if let img = cache[key] { return img }
        if doc == nil || doc!.width != width || doc!.height != height {
            doc = try? CanvasDocument(width: width, height: height, name: "preview", background: nil)
        }
        guard let doc, let layer = doc.activeLayerID, let tex = doc.content[layer] else { return nil }
        doc.gpu.run("clear preview") { cb in doc.gpu.clear(tex, in: cb) }
        doc.recompositeAll()   // otherwise the last preview survives outside the new stroke's bounds
        let isSmudge = brush.category == "Smudge"
        if isSmudge {
            // Smudge previews drag across coloured stripes so the smear is visible.
            doc.tool = .brush
            let stripes: [SIMD3<Float>] = [SIMD3(0.2, 0.35, 0.8), SIMD3(0.98, 0.7, 0.2), SIMD3(0.9, 0.3, 0.35)]
            let w = Float(width) / 9
            for i in 0..<9 {
                let x = Float(i) * w
                doc.beginLasso(at: SIMD2(x, 0))
                for p in [SIMD2<Float>(x + w, 0), SIMD2(x + w, Float(height)), SIMD2(x, Float(height))] { doc.extendLasso(to: p) }
                doc.endLasso()
                doc.color = stripes[i % stripes.count]
                doc.fillSelection()
            }
            doc.deselect()
        }
        doc.tool = isSmudge ? .smudge : .brush
        doc.currentBrush = brush
        doc.currentSize = min(brush.defaultSize, Float(height) * 0.4)
        doc.currentOpacity = brush.defaultOpacity
        doc.color = color ?? SIMD3(0.12, 0.12, 0.14)
        doc.paintStroke(Self.sampleStroke(width: Float(width), height: Float(height)))
        doc.history.removeAll()
        let img = doc.renderThumbnail(doc.compositor.output, maxSide: max(width, height))
        if cache.count > 400 { cache.removeAll() }
        cache[key] = img
        return img
    }
}

/// The brush library: shelves on the left, brushes with live stroke previews on the right.
public struct BrushPickerPopover: View {
    let document: CanvasDocument
    @Bindable var store: FreeBrushStore
    var onEdit: (BrushPreset) -> Void
    @State private var shelf: String?
    @State private var importing = false
    @State private var newFeed = ""
    @State private var showCommunity = false
    @State private var message: String?

    public init(document: CanvasDocument, store: FreeBrushStore, onEdit: @escaping (BrushPreset) -> Void) {
        self.document = document
        self.store = store
        self.onEdit = onEdit
    }

    private var currentShelf: BrushShelf? {
        store.shelves.first { $0.name == (shelf ?? document.currentBrush.category) } ?? store.shelves.first
    }

    public var body: some View {
        HStack(spacing: 0) {
            List(selection: Binding(get: { currentShelf?.name }, set: { shelf = $0 })) {
                Section("Brush Library") {
                    ForEach(store.shelves) { s in
                        Text(s.name).tag(Optional(s.name))
                    }
                }
                Section {
                    Button { showCommunity = true } label: { Label("Community", systemImage: "globe") }
                    Button { importing = true } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 170)

            Divider()

            ScrollView {
                LazyVStack(spacing: 6) {
                    if let s = currentShelf {
                        ForEach(store.brushes(in: s)) { brush in
                            brushRow(brush)
                        }
                    }
                }
                .padding(10)
            }
            .frame(width: 340)
        }
        .frame(height: 460)
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [UTType(filenameExtension: "abr") ?? .data,
                                            UTType(filenameExtension: "paperbrush") ?? .json,
                                            UTType(filenameExtension: "paperbrushset") ?? .json, .json],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            var count = 0
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do { count += try store.importFile(url).count } catch { message = error.localizedDescription }
            }
            if count > 0 { message = "Imported \(count) brush\(count == 1 ? "" : "es")." }
        }
        .sheet(isPresented: $showCommunity) { CommunityBrushesView(store: store) }
        .overlay(alignment: .bottom) {
            if let message {
                Text(message).font(.caption).padding(8).background(.thinMaterial, in: Capsule()).padding(8)
                    .onTapGesture { self.message = nil }
            }
        }
    }

    private func brushRow(_ brush: BrushPreset) -> some View {
        let selected = document.currentBrush.id == brush.id
        return Button {
            document.currentBrush = brush
            document.currentSize = brush.defaultSize
            document.currentOpacity = brush.defaultOpacity
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(brush.name).font(.callout.weight(selected ? .semibold : .regular))
                if let img = BrushPreviewRenderer.shared.preview(for: brush) {
                    Image(decorative: img, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 48)
                        .background(Color(white: 0.97), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit in Brush Studio…") { onEdit(brush) }
            Button("Duplicate") { store.duplicate(brush.id) }
            if store.isBuiltIn(brush.id) {
                Button("Reset to Default") { store.reset(brush.id) }
            } else {
                Button("Delete", role: .destructive) { store.delete(brush.id) }
            }
        }
    }
}

/// Browse and install brush packs from community feeds. Feeds are plain JSON anyone can host.
struct CommunityBrushesView: View {
    @Bindable var store: FreeBrushStore
    @Environment(\.dismiss) private var dismiss
    @State private var feedText = ""
    @State private var status: String?
    @State private var addingFolder = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Community Brushes").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            Text("Every brush in Paper is free. Add a feed URL (an index.json anyone can host) or a shared folder synced to this device, then install packs with one click.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("https://example.com/paper-brushes/index.json", text: $feedText)
                    .textFieldStyle(.roundedBorder)
                Button("Add Feed") {
                    if let url = URL(string: feedText), url.scheme != nil { store.addFeed(url); feedText = "" }
                }
                Button("Add Folder…") { addingFolder = true }
            }
            ForEach(store.feedURLs, id: \.self) { url in
                HStack {
                    Image(systemName: url.isFileURL ? "folder" : "globe")
                    Text(url.isFileURL ? url.path : url.absoluteString).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(role: .destructive) { store.removeFeed(url) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
                .font(.caption)
            }
            Divider()
            if store.isLoadingFeeds { ProgressView("Loading feeds…") }
            if let e = store.feedError { Text(e).font(.caption).foregroundStyle(.red) }
            List(store.feedPacks, id: \.pack.id) { entry in
                HStack {
                    VStack(alignment: .leading) {
                        Text(entry.pack.name).font(.headline)
                        Text("\(entry.pack.author) · \(entry.pack.category)").font(.caption).foregroundStyle(.secondary)
                        if !entry.pack.description.isEmpty { Text(entry.pack.description).font(.caption) }
                    }
                    Spacer()
                    Button("Install") {
                        Task {
                            do {
                                let added = try await store.install(entry.pack, base: entry.base)
                                status = "Installed \(added.count) brushes from \(entry.pack.name)."
                            } catch { status = error.localizedDescription }
                        }
                    }
                }
            }
            if let status { Text(status).font(.caption) }
            HStack {
                Spacer()
                Button("Refresh") { Task { await store.refreshFeeds() } }
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 480)
        .task { await store.refreshFeeds() }
        .fileImporter(isPresented: $addingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { store.addFeed(url); Task { await store.refreshFeeds() } }
        }
    }
}
