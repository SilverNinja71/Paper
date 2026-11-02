import SwiftUI
import UniformTypeIdentifiers

/// Where artworks live: the local Paper folder, iCloud Drive, or a cloud provider's synced folder.
public struct GalleryLocation: Identifiable, Hashable {
    public var id: URL { url }
    public var name: String
    public var symbol: String
    public var url: URL
}

extension GalleryLocation {
    /// Folders this device can save into directly. On macOS the Google Drive / OneDrive / Dropbox desktop
    /// apps mount their files under ~/Library/CloudStorage, and those folders sync themselves.
    public static func discover() -> [GalleryLocation] {
        var out = [GalleryLocation(name: "On This Device", symbol: "internaldrive", url: PaperAppModel.defaultGalleryFolder)]
        let fm = FileManager.default
        #if os(macOS)
        let home = fm.homeDirectoryForCurrentUser
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if fm.fileExists(atPath: iCloud.path) {
            out.append(GalleryLocation(name: "iCloud Drive", symbol: "icloud", url: iCloud.appendingPathComponent("Paper")))
        }
        let storage = home.appendingPathComponent("Library/CloudStorage")
        for name in ((try? fm.contentsOfDirectory(atPath: storage.path)) ?? []).sorted() where !name.hasPrefix(".") {
            let root = storage.appendingPathComponent(name)
            // Google Drive mounts "My Drive" inside the account folder.
            let myDrive = root.appendingPathComponent("My Drive")
            let base = fm.fileExists(atPath: myDrive.path) ? myDrive : root
            let (title, symbol): (String, String)
            if name.hasPrefix("GoogleDrive-") { (title, symbol) = ("Google Drive (\(name.dropFirst(12)))", "externaldrive.badge.icloud") }
            else if name.hasPrefix("OneDrive") { (title, symbol) = (name.replacingOccurrences(of: "-", with: " "), "cloud") }
            else if name.hasPrefix("Dropbox") { (title, symbol) = ("Dropbox", "shippingbox") }
            else { (title, symbol) = (name, "cloud") }
            out.append(GalleryLocation(name: title, symbol: symbol, url: base.appendingPathComponent("Paper Artworks")))
        }
        #else
        if let container = fm.url(forUbiquityContainerIdentifier: nil) {
            out.append(GalleryLocation(name: "iCloud Drive", symbol: "icloud",
                                       url: container.appendingPathComponent("Documents/Paper")))
        }
        #endif
        return out
    }
}

/// Canvas size presets for "New Canvas".
public struct CanvasPreset: Identifiable, Hashable {
    public var id: String { name }
    public var name: String
    public var width: Int
    public var height: Int

    public static let all: [CanvasPreset] = [
        CanvasPreset(name: "Square", width: 2048, height: 2048),
        CanvasPreset(name: "4K", width: 3840, height: 2160),
        CanvasPreset(name: "A4 300 dpi", width: 2480, height: 3508),
        CanvasPreset(name: "Screen (iPad Pro)", width: 2732, height: 2048),
        CanvasPreset(name: "Comic page", width: 1988, height: 3056),
        CanvasPreset(name: "Instagram post", width: 1080, height: 1350),
        CanvasPreset(name: "Small sketch", width: 1200, height: 900),
    ]
}

/// The artwork gallery: locations on the left, artworks as a thumbnail grid.
public struct GalleryView: View {
    @Bindable var model: PaperAppModel
    @State private var locations = GalleryLocation.discover()
    @State private var showNew = false
    @State private var importingPhoto = false
    @State private var importingBrushes = false
    @State private var renaming: PaperAppModel.GalleryItem?
    @State private var renameText = ""
    @State private var showCloud = false

    public init(model: PaperAppModel) { self.model = model }

    public var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.galleryFolder }, set: { if let u = $0 { model.galleryFolder = u } })) {
                Section("Locations") {
                    ForEach(locations) { loc in
                        Label(loc.name, systemImage: loc.symbol).tag(loc.url)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 20)], spacing: 24) {
                    newTile
                    ForEach(model.galleryItems) { item in tile(item) }
                }
                .padding(24)
            }
            .navigationTitle("Paper")
            .toolbar {
                if let cloud = model.cloud {
                    Button { showCloud = true } label: { CloudStatusBadge(cloud: cloud) }
                        .help("Cloud accounts and synced folders")
                }
                Button { importingPhoto = true } label: { Label("Edit Photo…", systemImage: "photo") }
                Button { importingBrushes = true } label: { Label("Import Brushes…", systemImage: "paintbrush") }
                Button { model.refreshGallery() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        }
        .sheet(isPresented: $showNew) { NewCanvasSheet(model: model) }
        .sheet(isPresented: $showCloud) {
            if let cloud = model.cloud { CloudSettingsView(cloud: cloud, galleryFolder: model.galleryFolder) }
        }
        .fileImporter(isPresented: $importingPhoto, allowedContentTypes: [.image, .rawImage]) { result in
            if case .success(let url) = result { model.newDocument(fromPhoto: url) }
        }
        .fileImporter(isPresented: $importingBrushes,
                      allowedContentTypes: [UTType(filenameExtension: "abr") ?? .data,
                                            UTType(filenameExtension: "paperbrush") ?? .json,
                                            UTType(filenameExtension: "paperbrushset") ?? .json],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { urls.forEach(model.importBrushes) }
        }
        .alert("Rename Artwork", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { if let r = renaming { model.renameArtwork(r, to: renameText) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .onAppear { model.refreshGallery() }
    }

    private var newTile: some View {
        Button { showNew = true } label: {
            VStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 40, weight: .light))
                Text("New Canvas").font(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 190)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6])).foregroundStyle(.secondary))
        }
        .buttonStyle(.plain)
    }

    private func tile(_ item: PaperAppModel.GalleryItem) -> some View {
        Button { model.open(item.url) } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    CheckerboardView()
                    if let t = item.thumbnail {
                        Image(decorative: t, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    }
                }
                .frame(height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                Text(item.name).font(.callout.weight(.medium)).lineLimit(1)
                Text("\(item.size) · \(item.modified.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open") { model.open(item.url) }
            Button("Rename…") { renameText = item.name; renaming = item }
            Button("Duplicate") { model.duplicateArtwork(item) }
            Divider()
            Button("Move to Trash", role: .destructive) { model.trashArtwork(item) }
        }
    }
}

struct NewCanvasSheet: View {
    @Bindable var model: PaperAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Untitled Artwork"
    @State private var width = 2048
    @State private var height = 2048
    @State private var transparent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Canvas").font(.title2.bold())
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 8) {
                ForEach(CanvasPreset.all) { p in
                    Button {
                        width = p.width; height = p.height
                    } label: {
                        VStack(alignment: .leading) {
                            Text(p.name).font(.callout.weight(.medium))
                            Text("\(p.width) × \(p.height)").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(width == p.width && height == p.height ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Text("Custom")
                TextField("Width", value: $width, format: .number).textFieldStyle(.roundedBorder).frame(width: 90)
                Text("×")
                TextField("Height", value: $height, format: .number).textFieldStyle(.roundedBorder).frame(width: 90)
                Text("px").foregroundStyle(.secondary)
            }
            Toggle("Transparent background", isOn: $transparent)
            Text("Display P3 wide colour · 16-bit float layers · HDR-ready").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    model.newDocument(width: min(max(width, 16), 16384), height: min(max(height, 16), 16384), name: name,
                                      background: transparent ? nil : SIMD3(1, 1, 1))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// Root view: the gallery, or the workspace when an artwork is open.
public struct PaperRootView: View {
    @Bindable var model: PaperAppModel

    public init(model: PaperAppModel) { self.model = model }

    public var body: some View {
        Group {
            if let doc = model.document, let controller = model.controller {
                PaperWorkspaceView(model: model, document: doc, controller: controller)
            } else {
                GalleryView(model: model)
            }
        }
        .alert("Paper", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
