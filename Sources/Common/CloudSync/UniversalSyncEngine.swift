import Foundation

// MARK: - Provider identity and state

/// Stable identifier of a storage backend ("googleDrive", "dropbox", ...). Folder-based providers use
/// "local.<hash of path>" unless the app supplies its own id. It is persisted in sync-folder configs.
public struct CloudProviderID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static let googleDrive: CloudProviderID = "googleDrive"
    public static let dropbox: CloudProviderID = "dropbox"
    public static let oneDrive: CloudProviderID = "oneDrive"
    public static let iCloudDrive: CloudProviderID = "iCloudDrive"

    public var description: String { rawValue }
}

/// What a provider can do right now.
public enum CloudAuthState: Sendable, Equatable {
    /// The app developer has not registered an OAuth client / app key yet. `hint` explains how, in plain words.
    case notConfigured(hint: String)
    /// Configured, but the user has not signed in (or the saved sign-in was revoked / expired).
    case signedOut
    /// Ready to use. `account` is an e-mail / display name when the service told us one.
    case signedIn(account: String?)
    /// Folder-based provider whose folder cannot be reached right now (drive unplugged, iCloud off, ...).
    case unavailable(reason: String)

    public var isReady: Bool {
        if case .signedIn = self { return true }
        return false
    }
}

// MARK: - Items

public struct CloudItem: Hashable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable { case file, folder }

    /// Provider specific identifier (file id, path, ...). Not meaningful across providers.
    public var id: String
    public var path: CloudPath
    public var name: String
    public var kind: Kind
    /// Size in bytes (nil for folders, or when the service does not tell us).
    public var size: Int64?
    public var modified: Date?
    /// Opaque version marker: Dropbox `rev`, OneDrive `eTag`, Drive `version`, or a stat fingerprint for folders.
    /// Two listings with the same revision describe the same bytes. Nil for folders.
    public var revision: String?
    public var contentHash: CloudContentHash?

    public init(id: String, path: CloudPath, name: String? = nil, kind: Kind, size: Int64? = nil,
                modified: Date? = nil, revision: String? = nil, contentHash: CloudContentHash? = nil) {
        self.id = id
        self.path = path
        self.name = name ?? path.name ?? ""
        self.kind = kind
        self.size = size
        self.modified = modified
        self.revision = revision
        self.contentHash = contentHash
    }

    public var isFolder: Bool { kind == .folder }
}

/// One page of a folder listing. Pass `nextPageToken` back to `listFolder` to continue.
public struct CloudListPage: Sendable, Equatable {
    public var items: [CloudItem]
    public var nextPageToken: String?

    public init(items: [CloudItem], nextPageToken: String? = nil) {
        self.items = items
        self.nextPageToken = nextPageToken
    }
}

/// Optimistic-concurrency rule for an upload.
public enum UploadPrecondition: Sendable, Equatable {
    /// Create or overwrite without checking.
    case none
    /// Only overwrite if the file on the server still has exactly this revision.
    case revision(String)
    /// Only create; fail if something already exists at that path.
    case mustNotExist
}

// MARK: - Errors

public enum CloudError: Error, Sendable, Equatable {
    case notConfigured(hint: String)
    case notSignedIn(provider: CloudProviderID)
    case signInCancelled
    case authenticationFailed(String)
    case stateMismatch
    case notFound(path: String)
    /// The server copy changed (or already exists) so the conditional upload was refused.
    case revisionMismatch(path: String)
    case rateLimited(retryAfter: TimeInterval?)
    case http(status: Int, message: String)
    case network(String)
    case invalidResponse(String)
    case unavailable(String)
    case fileSystem(String)
    case keychain(status: Int32)
    /// A local file was modified while a sync was reading it; the sync stops and is retried a moment later.
    case localFileChanged(String)

    /// True when trying again later has a realistic chance of working.
    public var isTransient: Bool {
        switch self {
        case .rateLimited, .network, .localFileChanged, .revisionMismatch: return true
        case .http(let status, _): return status == 408 || status == 429 || (500...599).contains(status)
        default: return false
        }
    }

    /// Server asked us to wait this long (seconds) before retrying.
    public var retryAfter: TimeInterval? {
        if case .rateLimited(let seconds) = self { return seconds }
        return nil
    }
}

extension CloudError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConfigured(let hint): return hint
        case .notSignedIn(let provider): return "Not signed in to \(provider.rawValue). Please sign in again."
        case .signInCancelled: return "Sign-in was cancelled."
        case .authenticationFailed(let message): return "Sign-in failed: \(message)"
        case .stateMismatch: return "Sign-in response did not match the request (possible forgery). Please try again."
        case .notFound(let path): return "Not found: \(path)"
        case .revisionMismatch(let path): return "\(path) was changed by someone else while syncing."
        case .rateLimited(let seconds):
            if let seconds { return "The service is busy; try again in \(Int(seconds.rounded(.up))) seconds." }
            return "The service is busy; try again shortly."
        case .http(let status, let message): return "Server error \(status): \(message)"
        case .network(let message): return "Network problem: \(message)"
        case .invalidResponse(let message): return "Unexpected response from the service: \(message)"
        case .unavailable(let message): return message
        case .fileSystem(let message): return "File problem: \(message)"
        case .keychain(let status): return "Keychain error \(status)."
        case .localFileChanged(let name): return "\(name) changed while syncing."
        }
    }
}

// MARK: - Interactive sign-in hook

/// Shows the provider's sign-in page and returns the URL the page redirected to.
/// The real implementation is `SystemWebAuthenticator` (ASWebAuthenticationSession); tests use a fake.
public protocol WebAuthenticator: Sendable {
    func authenticate(authorizationURL: URL, callbackURLScheme: String) async throws -> URL
}

// MARK: - Storage backend protocol

/// A storage backend the sync engine can talk to. All paths are relative to the backend's own root.
///
/// Conventions every implementation follows:
/// - `listFolder` throws `CloudError.notFound` when the folder does not exist.
/// - `createFolder` behaves like `mkdir -p` and succeeds when the folder already exists.
/// - `upload` honours `precondition` and throws `CloudError.revisionMismatch` when it is violated.
/// - `download` writes to `destination` (replacing anything there) and returns the metadata of the bytes it wrote.
/// - Methods that need credentials throw `CloudError.notSignedIn` / `.notConfigured` instead of crashing.
public protocol CloudStorageProvider: Sendable {
    var id: CloudProviderID { get }
    var displayName: String { get }

    func authState() async -> CloudAuthState
    /// Runs the interactive sign-in. Folder-based providers just verify their folder is reachable.
    func signIn(using authenticator: any WebAuthenticator) async throws
    func signOut() async throws

    func listFolder(_ path: CloudPath, pageToken: String?) async throws -> CloudListPage
    /// Metadata for one file or folder, or nil if it does not exist.
    func stat(_ path: CloudPath) async throws -> CloudItem?
    func download(_ path: CloudPath, to destination: URL) async throws -> CloudItem
    func upload(from source: URL, to path: CloudPath, precondition: UploadPrecondition) async throws -> CloudItem
    func createFolder(_ path: CloudPath) async throws -> CloudItem
    func delete(_ path: CloudPath) async throws
}

public extension CloudStorageProvider {
    /// Follows pagination to the end and returns every child of `path`.
    func listAll(_ path: CloudPath) async throws -> [CloudItem] {
        var items: [CloudItem] = []
        var token: String?
        var seenTokens = Set<String>()
        repeat {
            let page = try await listFolder(path, pageToken: token)
            items.append(contentsOf: page.items)
            token = page.nextPageToken
            if let next = token, !seenTokens.insert(next).inserted {
                throw CloudError.invalidResponse("The service returned the same page token twice.")
            }
        } while token != nil
        return items
    }
}
