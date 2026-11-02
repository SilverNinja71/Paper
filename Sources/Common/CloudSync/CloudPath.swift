import Foundation

/// A location inside a cloud provider's storage, always relative to that provider's root folder.
///
/// `CloudPath("/Paper/MyArt.paper/manifest.json")` and `CloudPath("Paper/MyArt.paper/manifest.json")`
/// are the same value. Empty components and `.` are dropped and `..` is never allowed, so a path can never
/// climb out of the provider's root (important because names coming back from a remote server are untrusted).
public struct CloudPath: Hashable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let components: [String]

    public init(components: [String]) {
        var cleaned: [String] = []
        for raw in components {
            for piece in raw.split(separator: "/", omittingEmptySubsequences: true) {
                let part = String(piece)
                if part == "." || part == ".." { continue }
                cleaned.append(part)
            }
        }
        self.components = cleaned
    }

    public init(_ string: String) { self.init(components: [string]) }
    public init(stringLiteral value: String) { self.init(value) }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }

    public static let root = CloudPath(components: [])

    public var isRoot: Bool { components.isEmpty }

    /// Always starts with "/" ("/" alone for the root).
    public var string: String { "/" + components.joined(separator: "/") }

    public var description: String { string }

    /// The last component, or nil for the root.
    public var name: String? { components.last }

    public var parent: CloudPath? {
        isRoot ? nil : CloudPath(components: Array(components.dropLast()))
    }

    public func appending(_ component: String) -> CloudPath {
        CloudPath(components: components + [component])
    }

    public func appending(_ other: CloudPath) -> CloudPath {
        CloudPath(components: components + other.components)
    }

    /// Every prefix of this path from the shallowest folder down to the path itself (the root is not included).
    /// Used to implement "mkdir -p".
    public var prefixes: [CloudPath] {
        guard !components.isEmpty else { return [] }
        return (1...components.count).map { CloudPath(components: Array(components.prefix($0))) }
    }

    public func isDescendant(of base: CloudPath) -> Bool {
        components.count > base.components.count && Array(components.prefix(base.components.count)) == base.components
    }

    /// "a/b" for `/x/a/b` relative to `/x`, nil when this path is not below `base`.
    public func relativePath(from base: CloudPath) -> String? {
        guard isDescendant(of: base) else { return nil }
        return components.dropFirst(base.components.count).joined(separator: "/")
    }
}
