import Foundation
import Metal
import CoreGraphics
import ImageIO
import simd

/// `manifest.json` inside a `.paper` package.
///
/// Package layout (a folder that Finder/Files show as one document):
/// ```
/// Artwork.paper/
///   manifest.json                     ← written last: the commit point of a save
///   layers/<uuid>.rgba16f.lzfse       ← premultiplied half-float RGBA, LZFSE-compressed
///   masks/<uuid>.r16f.lzfse           ← half-float greyscale
///   thumbnail.png                     ← 512 px preview for galleries
/// ```
/// Saves are deltas: a layer file is rewritten only when that layer's pixels changed since the last save.
public struct PaperManifest: Codable {
    public var format = "paper"
    public var version = 1
    public var name: String
    public var width: Int
    public var height: Int
    public var colorSpace = "Display P3 (gamma-encoded, extended range, premultiplied)"
    public var background: SIMD3<Float>
    public var backgroundVisible: Bool
    public var layers: LayerStack
    public var activeLayerID: UUID?
    /// Layer id → file paths (relative to the package) and content fingerprints.
    public var files: [String: LayerFiles]
    public var created: Date
    public var modified: Date
    public var saveCount: Int
    public var generator = "Paper 0.1"

    public struct LayerFiles: Codable, Equatable {
        public var content: String?
        public var mask: String?
        /// Changes whenever the pixels change; lets sync and delta-save skip unchanged files.
        public var contentFingerprint: String?
        public var maskFingerprint: String?
    }
}

public enum PaperFileError: Error, LocalizedError {
    case notAPaperFile
    case newerVersion(Int)
    case missingLayerData(String)

    public var errorDescription: String? {
        switch self {
        case .notAPaperFile: return "This isn't a Paper project."
        case .newerVersion(let v): return "This project was made by a newer Paper (format \(v)). Please update."
        case .missingLayerData(let name): return "Pixel data for layer \u{201C}\(name)\u{201D} is missing."
        }
    }
}

extension CanvasDocument {
    public static let fileExtension = "paper"

    private func fingerprint(_ texture: MTLTexture, revision: Int) -> String {
        // Revisions only ever grow (in-place edits and texture swaps both bump them), so a changed
        // number always means changed pixels.
        "\(texture.width)x\(texture.height)-r\(revision)"
    }

    /// Saves to `url` (a `.paper` folder). Only layers whose pixels changed are rewritten.
    /// Returns the package-relative paths that were written (handy for delta cloud sync).
    @discardableResult
    public func save(to url: URL) throws -> [String] {
        if paint.isStroking { endStroke() }
        if transformState != nil { commitTransform() }
        let fm = FileManager.default
        let samePlace = fileURL?.standardizedFileURL == url.standardizedFileURL
        if !samePlace {
            // Saving somewhere new: everything must be written.
            savedContentState.removeAll()
            savedMaskState.removeAll()
        }
        try fm.createDirectory(at: url.appendingPathComponent("layers"), withIntermediateDirectories: true)
        try fm.createDirectory(at: url.appendingPathComponent("masks"), withIntermediateDirectories: true)

        var previous: PaperManifest?
        if let data = try? Data(contentsOf: url.appendingPathComponent("manifest.json")) {
            previous = try? JSONDecoder.paper.decode(PaperManifest.self, from: data)
        }

        var written: [String] = []
        var files: [String: PaperManifest.LayerFiles] = [:]
        for node in layers.allNodes {
            var entry = PaperManifest.LayerFiles()
            if node.isRaster, let tex = content[node.id] {
                let path = "layers/\(node.id.uuidString).rgba16f.lzfse"
                let fp = fingerprint(tex, revision: contentRevision[node.id] ?? 0)
                let onDisk = fm.fileExists(atPath: url.appendingPathComponent(path).path)
                if savedContentState[node.id] != fp || !onDisk {
                    try writeCompressed(gpu.readHalfData(tex), to: url.appendingPathComponent(path))
                    savedContentState[node.id] = fp
                    written.append(path)
                }
                entry.content = path
                entry.contentFingerprint = fp
            }
            if node.hasMask, let m = masks[node.id] {
                let path = "masks/\(node.id.uuidString).r16f.lzfse"
                let fp = fingerprint(m, revision: maskRevision[node.id] ?? 0)
                let onDisk = fm.fileExists(atPath: url.appendingPathComponent(path).path)
                if savedMaskState[node.id] != fp || !onDisk {
                    try writeCompressed(gpu.readHalfData(m), to: url.appendingPathComponent(path))
                    savedMaskState[node.id] = fp
                    written.append(path)
                }
                entry.mask = path
                entry.maskFingerprint = fp
            }
            if entry.content != nil || entry.mask != nil { files[node.id.uuidString] = entry }
        }

        // Remove files of layers that no longer exist.
        let referenced = Set(files.values.flatMap { [$0.content, $0.mask].compactMap { $0 } })
        for folder in ["layers", "masks"] {
            let dir = url.appendingPathComponent(folder)
            for f in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !referenced.contains("\(folder)/\(f)") {
                try? fm.removeItem(at: dir.appendingPathComponent(f))
            }
        }

        recompositeAll()
        if let thumb = compositeThumbnail(maxSide: 512), let png = Self.pngData(thumb) {
            try png.write(to: url.appendingPathComponent("thumbnail.png"), options: .atomic)
            written.append("thumbnail.png")
        }

        let manifest = PaperManifest(name: name, width: width, height: height, background: background,
                                       backgroundVisible: backgroundVisible, layers: layers, activeLayerID: activeLayerID,
                                       files: files, created: previous?.created ?? Date(), modified: Date(),
                                       saveCount: (previous?.saveCount ?? 0) + 1)
        try JSONEncoder.paper.encode(manifest).write(to: url.appendingPathComponent("manifest.json"), options: .atomic)
        written.append("manifest.json")
        fileURL = url
        markSaved()
        return written
    }

    /// Opens a `.paper` package.
    public static func open(_ url: URL, gpu: PaperGPU = .shared) throws -> CanvasDocument {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("manifest.json")) else {
            throw PaperFileError.notAPaperFile
        }
        let manifest = try JSONDecoder.paper.decode(PaperManifest.self, from: data)
        guard manifest.format == "paper" else { throw PaperFileError.notAPaperFile }
        guard manifest.version <= 1 else { throw PaperFileError.newerVersion(manifest.version) }

        let doc = try CanvasDocument(width: manifest.width, height: manifest.height, name: manifest.name, gpu: gpu,
                                     emptyStack: true)
        doc.background = manifest.background
        doc.backgroundVisible = manifest.backgroundVisible
        for node in manifest.layers.allNodes {
            let entry = manifest.files[node.id.uuidString]
            if node.isRaster {
                let tex = try doc.makeContentTexture(node.id)
                if let path = entry?.content {
                    let raw = try readCompressed(url.appendingPathComponent(path))
                    guard gpu.writeHalfData(raw, to: tex) else { throw PaperFileError.missingLayerData(node.name) }
                    doc.savedContentState[node.id] = doc.fingerprint(tex, revision: doc.contentRevision[node.id] ?? 0)
                }
            }
            if node.hasMask {
                let m = try doc.makeMaskTexture(node.id)
                if let path = entry?.mask {
                    let raw = try readCompressed(url.appendingPathComponent(path))
                    guard gpu.writeHalfData(raw, to: m) else { throw PaperFileError.missingLayerData(node.name) }
                    doc.savedMaskState[node.id] = doc.fingerprint(m, revision: doc.maskRevision[node.id] ?? 0)
                }
            }
        }
        doc.layers = manifest.layers
        doc.activeLayerID = manifest.activeLayerID ?? manifest.layers.allNodes.last?.id
        doc.fileURL = url
        doc.recompositeAll()
        doc.refreshAllThumbnails()
        doc.markSaved()
        return doc
    }

    /// Reads just the thumbnail and canvas size (for gallery grids) without loading layers.
    public static func peek(_ url: URL) -> (thumbnail: CGImage?, width: Int, height: Int, modified: Date)? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("manifest.json")),
              let m = try? JSONDecoder.paper.decode(PaperManifest.self, from: data) else { return nil }
        var thumb: CGImage?
        if let src = CGImageSourceCreateWithURL(url.appendingPathComponent("thumbnail.png") as CFURL, nil) {
            thumb = CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        return (thumb, m.width, m.height, m.modified)
    }

    private func writeCompressed(_ raw: Data, to url: URL) throws {
        let packed = try (raw as NSData).compressed(using: .lzfse) as Data
        try packed.write(to: url, options: .atomic)
    }

    private static func readCompressed(_ url: URL) throws -> Data {
        let packed = try Data(contentsOf: url)
        return try (packed as NSData).decompressed(using: .lzfse) as Data
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

extension JSONEncoder {
    static var paper: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var paper: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
