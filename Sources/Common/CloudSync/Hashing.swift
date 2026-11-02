import Foundation
import CryptoKit

/// Streaming file hashing helpers. Nothing here ever loads a whole file into memory.
enum FileHashing {
    static let chunkSize = 1 << 20

    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        var out = ""
        for byte in bytes {
            out.append(Self.hexDigits[Int(byte >> 4)])
            out.append(Self.hexDigits[Int(byte & 0x0F)])
        }
        return out
    }

    private static let hexDigits = Array("0123456789abcdef")

    static func sha256Hex(of data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    static func sha256Hex(ofFileAt url: URL) throws -> String {
        var hasher = SHA256()
        try forEachChunk(of: url, size: chunkSize) { hasher.update(data: $0) }
        return hex(hasher.finalize())
    }

    static func md5Hex(ofFileAt url: URL) throws -> String {
        var hasher = Insecure.MD5()
        try forEachChunk(of: url, size: chunkSize) { hasher.update(data: $0) }
        return hex(hasher.finalize())
    }

    static func sha1Hex(ofFileAt url: URL) throws -> String {
        var hasher = Insecure.SHA1()
        try forEachChunk(of: url, size: chunkSize) { hasher.update(data: $0) }
        return hex(hasher.finalize())
    }

    /// Dropbox's "content_hash": SHA-256 of the concatenated SHA-256 digests of every 4 MiB block.
    static func dropboxContentHashHex(ofFileAt url: URL) throws -> String {
        let block = 4 * 1024 * 1024
        var concatenated = Data()
        try forEachChunk(of: url, size: block) { concatenated.append(contentsOf: SHA256.hash(data: $0)) }
        return hex(SHA256.hash(data: concatenated))
    }

    /// Reads `url` in chunks of exactly `size` bytes (the last chunk may be shorter) and hands each to `body`.
    static func forEachChunk(of url: URL, size: Int, _ body: (Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while true {
            let finished: Bool = try autoreleasepool {
                var chunk = Data()
                while chunk.count < size {
                    guard let piece = try handle.read(upToCount: size - chunk.count), !piece.isEmpty else { break }
                    chunk.append(piece)
                }
                if chunk.isEmpty { return true }
                try body(chunk)
                return chunk.count < size
            }
            if finished { break }
        }
    }
}

/// A content hash reported by a cloud provider, normalised to lowercase hex.
public struct CloudContentHash: Hashable, Sendable, Codable {
    public enum Algorithm: String, Sendable, Codable {
        case sha256
        case sha1
        case md5
        /// Dropbox's block-wise SHA-256 (see `FileHashing.dropboxContentHashHex`).
        case dropbox
    }

    public var algorithm: Algorithm
    public var value: String

    public init(algorithm: Algorithm, value: String) {
        self.algorithm = algorithm
        self.value = value.lowercased()
    }

    /// Compares this remote hash against a local file. `sha256Hex` is the already-known SHA-256 of that file,
    /// so the common case costs nothing extra; other algorithms re-read the file once.
    func matches(fileAt url: URL, sha256Hex: String) throws -> Bool {
        switch algorithm {
        case .sha256: return value == sha256Hex
        case .md5: return try FileHashing.md5Hex(ofFileAt: url) == value
        case .sha1: return try FileHashing.sha1Hex(ofFileAt: url) == value
        case .dropbox: return try FileHashing.dropboxContentHashHex(ofFileAt: url) == value
        }
    }
}
