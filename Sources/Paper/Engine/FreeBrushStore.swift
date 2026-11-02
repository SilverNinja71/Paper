import Foundation
import Observation
import CryptoKit

/// A named shelf of brushes in the library (Procreate's brush sets).
public struct BrushShelf: Codable, Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var brushIDs: [UUID]
    public init(name: String, brushIDs: [UUID]) { self.name = name; self.brushIDs = brushIDs }
}

/// `.paperbrushset` — a pack of brushes in one JSON file.
public struct BrushPackFile: Codable, Sendable {
    public var format = "paperbrushset"
    public var version = 1
    public var name: String
    public var author: String
    public var license: String = "CC0-1.0"
    public var brushes: [BrushPreset]
    public init(name: String, author: String, brushes: [BrushPreset]) {
        self.name = name; self.author = author; self.brushes = brushes
    }
}

/// A community feed: a JSON index anyone can host (a web page, a GitHub repo, a shared cloud folder).
/// There's no central server and nothing is ever paywalled — Paper only reads the index and
/// downloads the packs it lists.
public struct CommunityFeed: Codable, Sendable {
    public var name: String
    public var packs: [CommunityPack]
}

public struct CommunityPack: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var author: String
    public var category: String
    public var description: String
    /// Absolute URL of a `.paperbrushset`, `.paperbrush` or `.abr` file, or a path relative to the feed.
    public var url: String
    public var license: String?
    public var brushCount: Int?
}

/// The brush library: built-in brushes, the user's own brushes and shelves, file import/export
/// (.paperbrush, .paperbrushset, Photoshop .abr) and community feeds.
@MainActor
@Observable
public final class FreeBrushStore {
    public private(set) var brushes: [BrushPreset] = []
    public private(set) var shelves: [BrushShelf] = []
    public var feedURLs: [URL] = [] { didSet { persist() } }
    public private(set) var feedPacks: [(feed: String, pack: CommunityPack, base: URL)] = []
    public private(set) var feedError: String?
    public private(set) var isLoadingFeeds = false

    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private let session: URLSession

    private struct Saved: Codable {
        var brushes: [BrushPreset]
        var shelves: [BrushShelf]
        var feeds: [URL]
    }

    /// `directory` holds `library.json`; nil keeps everything in memory (tests, previews).
    public init(directory: URL? = FreeBrushStore.defaultDirectory, session: URLSession = .shared) {
        self.directory = directory
        self.session = session
        if let directory, let data = try? Data(contentsOf: directory.appendingPathComponent("library.json")),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            brushes = saved.brushes
            shelves = saved.shelves
            feedURLs = saved.feeds
            // Built-ins added in newer versions appear automatically.
            for b in Self.builtInBrushes where !brushes.contains(where: { $0.id == b.id }) {
                brushes.append(b)
                addToShelf(b.id, shelf: b.category)
            }
        } else {
            brushes = Self.builtInBrushes
            shelves = Self.categories.map { cat in
                BrushShelf(name: cat, brushIDs: Self.builtInBrushes.filter { $0.category == cat }.map(\.id))
            }
        }
    }

    public nonisolated static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Paper/Brushes", isDirectory: true)
    }

    public func brushes(in shelf: BrushShelf) -> [BrushPreset] {
        shelf.brushIDs.compactMap { id in brushes.first { $0.id == id } }
    }

    public func brush(_ id: UUID) -> BrushPreset? { brushes.first { $0.id == id } }

    public func isBuiltIn(_ id: UUID) -> Bool { Self.builtInBrushes.contains { $0.id == id } }

    // MARK: Editing

    /// Saves changes to a brush (adds it if new).
    public func save(_ brush: BrushPreset) {
        if let i = brushes.firstIndex(where: { $0.id == brush.id }) {
            brushes[i] = brush
        } else {
            brushes.append(brush)
            addToShelf(brush.id, shelf: brush.category)
        }
        persist()
    }

    @discardableResult
    public func duplicate(_ id: UUID) -> BrushPreset? {
        guard let b = brush(id) else { return nil }
        let copy = b.duplicated()
        brushes.append(copy)
        if let s = shelves.firstIndex(where: { $0.brushIDs.contains(id) }),
           let i = shelves[s].brushIDs.firstIndex(of: id) {
            shelves[s].brushIDs.insert(copy.id, at: i + 1)
        } else {
            addToShelf(copy.id, shelf: copy.category)
        }
        persist()
        return copy
    }

    public func delete(_ id: UUID) {
        brushes.removeAll { $0.id == id }
        for i in shelves.indices { shelves[i].brushIDs.removeAll { $0 == id } }
        persist()
    }

    /// Puts a built-in brush back to its original settings.
    public func reset(_ id: UUID) {
        guard let original = Self.builtInBrushes.first(where: { $0.id == id }) else { return }
        save(original)
    }

    public func addShelf(named name: String) {
        guard !name.isEmpty, !shelves.contains(where: { $0.name == name }) else { return }
        shelves.append(BrushShelf(name: name, brushIDs: []))
        persist()
    }

    public func move(_ id: UUID, toShelf name: String) {
        for i in shelves.indices { shelves[i].brushIDs.removeAll { $0 == id } }
        addToShelf(id, shelf: name)
        if let i = brushes.firstIndex(where: { $0.id == id }) { brushes[i].category = name }
        persist()
    }

    private func addToShelf(_ id: UUID, shelf name: String) {
        if let i = shelves.firstIndex(where: { $0.name == name }) {
            if !shelves[i].brushIDs.contains(id) { shelves[i].brushIDs.append(id) }
        } else {
            shelves.append(BrushShelf(name: name, brushIDs: [id]))
        }
    }

    private func persist() {
        guard let directory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Saved(brushes: brushes, shelves: shelves, feeds: feedURLs))
            try data.write(to: directory.appendingPathComponent("library.json"), options: .atomic)
        } catch {
            feedError = "Couldn't save the brush library: \(error.localizedDescription)"
        }
    }

    // MARK: Files

    /// Imports `.paperbrush`, `.paperbrushset` or Photoshop `.abr`. Imported brushes get fresh IDs
    /// and land on a shelf named after the file (or the pack). Returns what was added.
    @discardableResult
    public func importFile(_ url: URL) throws -> [BrushPreset] {
        let data = try Data(contentsOf: url)
        let stem = url.deletingPathExtension().lastPathComponent
        return try importData(data, fileExtension: url.pathExtension.lowercased(), suggestedName: stem)
    }

    @discardableResult
    public func importData(_ data: Data, fileExtension: String, suggestedName: String) throws -> [BrushPreset] {
        var incoming: [BrushPreset]
        var shelfName = suggestedName
        switch fileExtension {
        case "abr":
            incoming = try ABRImporter.brushes(from: data, packName: suggestedName)
        case "paperbrush":
            incoming = [try JSONDecoder().decode(BrushPreset.self, from: data)]
            shelfName = incoming[0].category
        case "paperbrushset", "json":
            let pack = try JSONDecoder().decode(BrushPackFile.self, from: data)
            incoming = pack.brushes
            shelfName = pack.name
        default:
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        incoming = incoming.map { b in
            var c = b
            c.id = UUID()
            c.category = shelfName
            return c
        }
        for b in incoming {
            brushes.append(b)
            addToShelf(b.id, shelf: shelfName)
        }
        persist()
        return incoming
    }

    public static func exportData(_ brush: BrushPreset) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(brush)
    }

    public func exportShelf(_ shelf: BrushShelf, author: String) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(BrushPackFile(name: shelf.name, author: author, brushes: brushes(in: shelf)))
    }

    // MARK: Community feeds

    public func addFeed(_ url: URL) {
        guard !feedURLs.contains(url) else { return }
        feedURLs.append(url)
    }

    public func removeFeed(_ url: URL) {
        feedURLs.removeAll { $0 == url }
        feedPacks.removeAll { $0.base.deletingLastPathComponent() == url.deletingLastPathComponent() }
    }

    /// Loads every feed. A feed URL may be an `index.json` (web or file), or a folder (e.g. a shared
    /// Dropbox/Drive folder synced to this device) whose brush files are listed automatically.
    public func refreshFeeds() async {
        isLoadingFeeds = true
        feedError = nil
        var packs: [(String, CommunityPack, URL)] = []
        for url in feedURLs {
            do {
                if url.isFileURL, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                    for f in files where ["paperbrushset", "paperbrush", "abr"].contains(f.pathExtension.lowercased()) {
                        let name = f.deletingPathExtension().lastPathComponent
                        packs.append((url.lastPathComponent,
                                      CommunityPack(id: f.path, name: name, author: "Shared folder", category: "Community",
                                                    description: f.lastPathComponent, url: f.absoluteString),
                                      f))
                    }
                } else {
                    let data = try await fetch(url)
                    let feed = try JSONDecoder().decode(CommunityFeed.self, from: data)
                    packs += feed.packs.map { (feed.name, $0, url) }
                }
            } catch {
                feedError = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        feedPacks = packs
        isLoadingFeeds = false
    }

    /// Downloads a community pack and imports it onto its own shelf.
    @discardableResult
    public func install(_ pack: CommunityPack, base: URL) async throws -> [BrushPreset] {
        guard let url = URL(string: pack.url, relativeTo: base)?.absoluteURL else { throw URLError(.badURL) }
        let data = try await fetch(url)
        let ext = url.pathExtension.lowercased()
        return try importData(data, fileExtension: ext.isEmpty ? "paperbrushset" : ext, suggestedName: pack.name)
    }

    private func fetch(_ url: URL) async throws -> Data {
        if url.isFileURL { return try Data(contentsOf: url) }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

// MARK: - Built-in brushes

extension FreeBrushStore {
    public nonisolated static let categories = ["Sketching", "Inking", "Painting", "Watercolor", "Charcoals", "Airbrushing",
                                                "Textures", "Halftones", "FX", "Concept", "Smudge"]

    /// Stable IDs so edits to built-ins survive app updates.
    nonisolated static func stableID(_ name: String) -> UUID {
        let digest = SHA256.hash(data: Data(("paper.builtin." + name).utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    public nonisolated static let builtInBrushes: [BrushPreset] = {
        func make(_ name: String, _ category: String, _ configure: (inout BrushPreset) -> Void) -> BrushPreset {
            var b = BrushPreset(name: name, category: category)
            b.id = stableID(name)
            configure(&b)
            return b
        }
        return [
            // Sketching
            make("HB Pencil", "Sketching") {
                $0.tip = .builtin("pencil"); $0.defaultSize = 6; $0.spacing = 0.05; $0.hardness = 0.9
                $0.grain = GrainSettings(source: .builtin("paper"), scale: 0.5, depth: 0.65, mode: .texturized)
                $0.pressureSize = 0.4; $0.pressureOpacity = 0.75; $0.tiltSize = 0.8; $0.tiltRoundness = 0.7
                $0.tiltOpacity = 0.35; $0.rotationMode = .followAzimuth; $0.streamline = 0.1
            },
            make("6B Pencil", "Sketching") {
                $0.tip = .builtin("pencil"); $0.defaultSize = 12; $0.spacing = 0.05
                $0.grain = GrainSettings(source: .builtin("rough"), scale: 0.6, depth: 0.7, mode: .texturized)
                $0.pressureSize = 0.5; $0.pressureOpacity = 0.6; $0.tiltSize = 1; $0.tiltRoundness = 0.8
                $0.rotationMode = .followAzimuth; $0.streamline = 0.1
            },
            make("Technical Pencil", "Sketching") {
                $0.hardness = 0.95; $0.defaultSize = 3; $0.spacing = 0.04
                $0.grain = GrainSettings(source: .builtin("fine"), scale: 0.5, depth: 0.3, mode: .texturized)
                $0.pressureSize = 0.2; $0.pressureOpacity = 0.5; $0.streamline = 0.2
            },
            // Inking
            make("Studio Pen", "Inking") {
                $0.hardness = 0.96; $0.defaultSize = 10; $0.spacing = 0.04; $0.pressureSize = 0.9
                $0.pressureCurve = .gamma(1.3); $0.streamline = 0.45; $0.startTaper = 0.5
            },
            make("Technical Pen", "Inking") {
                $0.hardness = 1; $0.defaultSize = 5; $0.spacing = 0.03; $0.pressureSize = 0.1; $0.streamline = 0.6
            },
            make("Dry Ink", "Inking") {
                $0.tip = .builtin("ink-rough"); $0.defaultSize = 14; $0.spacing = 0.06; $0.pressureSize = 0.85
                $0.grain = GrainSettings(source: .builtin("rough"), scale: 0.8, depth: 0.45, mode: .moving)
                $0.angleJitter = 1; $0.streamline = 0.3
            },
            make("Brush Pen", "Inking") {
                $0.hardness = 0.92; $0.defaultSize = 18; $0.spacing = 0.03; $0.pressureSize = 1; $0.roundness = 0.55
                $0.rotationMode = .followAzimuth; $0.pressureCurve = .gamma(1.5); $0.streamline = 0.35; $0.startTaper = 0.6
            },
            // Painting
            make("Round Brush", "Painting") {
                $0.hardness = 0.7; $0.defaultSize = 40; $0.spacing = 0.06; $0.pressureSize = 0.5
                $0.pressureFlow = 0.6; $0.wetMix = 0.15; $0.streamline = 0.2
            },
            make("Flat Brush", "Painting") {
                $0.tip = .builtin("flat"); $0.defaultSize = 50; $0.spacing = 0.03; $0.rotationMode = .followStroke
                $0.angle = 90; $0.pressureSize = 0.3; $0.pressureFlow = 0.7; $0.wetMix = 0.2
            },
            make("Oil Paint", "Painting") {
                $0.tip = .builtin("bristle"); $0.defaultSize = 60; $0.spacing = 0.04; $0.rotationMode = .followStroke
                $0.flow = 0.85; $0.pressureSize = 0.4; $0.pressureFlow = 0.5; $0.wetMix = 0.4
                $0.grain = GrainSettings(source: .builtin("canvas"), scale: 1, depth: 0.3, mode: .texturized)
                $0.brightnessJitter = 0.03
            },
            make("Gouache", "Painting") {
                $0.hardness = 0.6; $0.defaultSize = 45; $0.spacing = 0.05; $0.flow = 0.75; $0.wetMix = 0.2
                $0.pressureSize = 0.4; $0.pressureFlow = 0.6
                $0.grain = GrainSettings(source: .builtin("paper"), scale: 1, depth: 0.3, mode: .texturized)
            },
            // Watercolor
            make("Wet Wash", "Watercolor") {
                $0.tip = .builtin("cloud"); $0.defaultSize = 90; $0.defaultOpacity = 0.6; $0.spacing = 0.05
                $0.flow = 0.25; $0.wetEdges = 0.7; $0.wetMix = 0.3; $0.pressureFlow = 0.6; $0.pressureSize = 0.3
                $0.grain = GrainSettings(source: .builtin("watercolor"), scale: 1.5, depth: 0.5, mode: .texturized)
            },
            make("Watercolor Round", "Watercolor") {
                $0.hardness = 0.4; $0.defaultSize = 40; $0.spacing = 0.05; $0.flow = 0.35; $0.wetEdges = 0.5
                $0.pressureSize = 0.6; $0.pressureFlow = 0.5; $0.wetMix = 0.25
                $0.dual = DualBrushSettings(tip: .builtin("cloud"), scale: 0.8, scatter: 0.3, depth: 0.5, blend: .multiply)
            },
            // Charcoals
            make("Vine Charcoal", "Charcoals") {
                $0.tip = .builtin("charcoal"); $0.defaultSize = 26; $0.spacing = 0.06; $0.angleJitter = 0.3
                $0.rotationMode = .followAzimuth; $0.tiltSize = 0.8; $0.tiltRoundness = 0.5; $0.pressureOpacity = 0.6
                $0.grain = GrainSettings(source: .builtin("paper"), scale: 0.8, depth: 0.85, mode: .texturized)
            },
            make("Compressed Charcoal", "Charcoals") {
                $0.tip = .builtin("chalk"); $0.defaultSize = 30; $0.spacing = 0.05; $0.flow = 0.9
                $0.rotationMode = .followStroke; $0.pressureSize = 0.4; $0.pressureOpacity = 0.5
                $0.grain = GrainSettings(source: .builtin("rough"), scale: 1, depth: 0.7, mode: .texturized)
            },
            // Airbrushing
            make("Soft Airbrush", "Airbrushing") {
                $0.hardness = 0; $0.defaultSize = 140; $0.spacing = 0.05; $0.flow = 0.12; $0.pressureSize = 0
                $0.pressureFlow = 0.8; $0.streamline = 0
            },
            make("Hard Airbrush", "Airbrushing") {
                $0.hardness = 0.85; $0.defaultSize = 50; $0.spacing = 0.05; $0.flow = 1; $0.pressureSize = 0.3
                $0.streamline = 0.1
            },
            make("Medium Airbrush", "Airbrushing") {
                $0.hardness = 0.45; $0.defaultSize = 80; $0.spacing = 0.05; $0.flow = 0.3; $0.pressureFlow = 0.7
                $0.pressureSize = 0.2
            },
            // Textures
            make("Canvas Texture", "Textures") {
                $0.hardness = 0.2; $0.defaultSize = 220; $0.flow = 0.4; $0.pressureFlow = 0.6; $0.pressureSize = 0
                $0.grain = GrainSettings(source: .builtin("canvas"), scale: 1, depth: 1, mode: .texturized)
            },
            make("Linen", "Textures") {
                $0.hardness = 0.2; $0.defaultSize = 220; $0.flow = 0.4; $0.pressureFlow = 0.6; $0.pressureSize = 0
                $0.grain = GrainSettings(source: .builtin("linen"), scale: 1, depth: 1, mode: .texturized)
            },
            make("Noise", "Textures") {
                $0.hardness = 0.3; $0.defaultSize = 160; $0.flow = 0.5; $0.pressureSize = 0
                $0.grain = GrainSettings(source: .builtin("noise"), scale: 1, depth: 1, mode: .texturized)
            },
            // Halftones
            make("Halftone Dots", "Halftones") {
                $0.hardness = 0.6; $0.defaultSize = 160; $0.flow = 1; $0.pressureFlow = 0.3; $0.pressureSize = 0
                $0.grain = GrainSettings(source: .builtin("halftone"), scale: 1, depth: 1, mode: .texturized)
            },
            make("Halftone Stamp", "Halftones") {
                $0.tip = .builtin("halftone-dot"); $0.defaultSize = 120; $0.spacing = 0.5; $0.pressureSize = 0.5
            },
            // FX
            make("Splatter", "FX") {
                $0.tip = .builtin("splatter"); $0.defaultSize = 120; $0.spacing = 0.7; $0.scatter = 0.8
                $0.sizeJitter = 0.6; $0.angleJitter = 1; $0.pressureSize = 0.5; $0.randomFlip = true
            },
            make("Sparkle", "FX") {
                $0.tip = .builtin("sparkle"); $0.defaultSize = 60; $0.spacing = 1.2; $0.scatter = 1; $0.count = 2
                $0.sizeJitter = 0.8; $0.angleJitter = 0.1; $0.brightnessJitter = 0.2; $0.pressureSize = 0.3
            },
            make("Stars", "FX") {
                $0.tip = .builtin("star"); $0.defaultSize = 50; $0.spacing = 1; $0.scatter = 0.6; $0.sizeJitter = 0.5
                $0.angleJitter = 1; $0.hueJitter = 0.15; $0.pressureSize = 0.4
            },
            make("Leaves", "FX") {
                $0.tip = .builtin("leaf"); $0.defaultSize = 50; $0.spacing = 0.7; $0.rotationMode = .followStroke
                $0.angleJitter = 0.4; $0.scatter = 0.5; $0.sizeJitter = 0.4; $0.hueJitter = 0.08
                $0.saturationJitter = 0.2; $0.brightnessJitter = 0.25; $0.randomFlip = true
            },
            // Concept
            make("Chunky Concept", "Concept") {
                $0.tip = .builtin("square"); $0.roundness = 0.5; $0.defaultSize = 50; $0.spacing = 0.04
                $0.rotationMode = .followStroke; $0.pressureOpacity = 0.6; $0.pressureSize = 0.3
                $0.grain = GrainSettings(source: .builtin("rough"), scale: 1, depth: 0.4, mode: .moving)
                $0.dual = DualBrushSettings(tip: .builtin("bristle"), scale: 0.7, scatter: 0.2, depth: 0.6, blend: .multiply)
            },
            make("Block-In", "Concept") {
                $0.tip = .builtin("square"); $0.defaultSize = 70; $0.angle = 30; $0.spacing = 0.04; $0.flow = 0.7
                $0.wetMix = 0.25; $0.pressureFlow = 0.6; $0.pressureSize = 0.2
            },
            // Smudge
            make("Soft Blend", "Smudge") {
                $0.hardness = 0.1; $0.defaultSize = 60; $0.spacing = 0.05; $0.flow = 0.7; $0.pressureFlow = 0.7
                $0.pressureSize = 0.3; $0.streamline = 0.1
            },
            make("Textured Blend", "Smudge") {
                $0.tip = .builtin("chalk"); $0.defaultSize = 50; $0.spacing = 0.05; $0.flow = 0.65; $0.pressureFlow = 0.6
                $0.grain = GrainSettings(source: .builtin("paper"), scale: 1, depth: 0.6, mode: .texturized)
            },
        ]
    }()
}
