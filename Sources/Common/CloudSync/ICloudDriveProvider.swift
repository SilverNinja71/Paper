import Foundation

/// iCloud Drive without any web API.
///
/// 1. If the app has the iCloud Documents entitlement, uses its ubiquity container
///    (`FileManager.url(forUbiquityContainerIdentifier:)`), folder "Documents" (visible in the Files app / Finder).
/// 2. On macOS, if there is no container (no entitlement, e.g. an unsigned or non-sandboxed build), falls back to
///    the user's iCloud Drive folder `~/Library/Mobile Documents/com~apple~CloudDocs/`.
///
/// Reads and writes go through NSFileCoordinator, and evicted files are downloaded on demand
/// (`startDownloadingUbiquitousItem`, then wait until the file is really on disk).
public final class ICloudDriveProvider: CloudStorageProvider {
    public let id: CloudProviderID = .iCloudDrive
    public let displayName: String = "iCloud Drive"

    /// Default location of the user's iCloud Drive folder on a Mac (nil on iOS).
    public static var defaultFallbackRoot: URL? {
        #if os(macOS)
        return FileProviderDiscovery.defaultICloudDriveDirectory
        #else
        return nil
        #endif
    }

    private let containerIdentifier: String?
    private let documentsSubfolder: String
    private let fallbackRoot: URL?
    private let containerResolver: @Sendable (String?) -> URL?
    private let identityTokenAvailable: @Sendable () -> Bool
    private let resolution = Resolution()

    private actor Resolution {
        var storage: FileSystemStorage?
        func set(_ value: FileSystemStorage) { storage = value }
    }

    /// - Parameters:
    ///   - containerIdentifier: your iCloud container id, or nil for the app's default container.
    ///   - fallbackRoot: where to go when no container is available (pass nil to disable the fallback).
    ///   - containerResolver: injection point for tests; the default asks `FileManager`.
    public init(containerIdentifier: String? = nil,
                documentsSubfolder: String = "Documents",
                fallbackRoot: URL? = ICloudDriveProvider.defaultFallbackRoot,
                containerResolver: @escaping @Sendable (String?) -> URL? = { FileManager.default.url(forUbiquityContainerIdentifier: $0) },
                identityTokenAvailable: @escaping @Sendable () -> Bool = { FileManager.default.ubiquityIdentityToken != nil }) {
        self.containerIdentifier = containerIdentifier
        self.documentsSubfolder = documentsSubfolder
        self.fallbackRoot = fallbackRoot
        self.containerResolver = containerResolver
        self.identityTokenAvailable = identityTokenAvailable
    }

    static let unavailableHint = "iCloud Drive isn't available. Sign in to iCloud in System Settings (Apple ID > iCloud) and turn on iCloud Drive. To use the app's own iCloud container the app also needs the \"iCloud Documents\" capability."

    /// Finds the folder to use. Must not run on the main thread (the container lookup can block).
    private func resolveStorage() async throws -> FileSystemStorage {
        if let cached = await resolution.storage { return cached }
        let containerIdentifier = containerIdentifier
        let subfolder = documentsSubfolder
        let fallback = fallbackRoot
        let resolver = containerResolver
        let hasIdentity = identityTokenAvailable
        let storage: FileSystemStorage = try await BlockingIO.run {
            let fm = FileManager.default
            var root: URL?
            if hasIdentity(), let container = resolver(containerIdentifier) {
                let documents = container.appendingPathComponent(subfolder, isDirectory: true)
                try? fm.createDirectory(at: documents, withIntermediateDirectories: true)
                root = documents
            }
            if root == nil, let fallback {
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: fallback.path, isDirectory: &isDirectory), isDirectory.boolValue { root = fallback }
            }
            guard let root else { throw CloudError.unavailable(Self.unavailableHint) }
            var storage = FileSystemStorage(root: root.standardizedFileURL.resolvingSymlinksInPath())
            storage.coordinated = true
            storage.ubiquitous = true
            return storage
        }
        await resolution.set(storage)
        return storage
    }

    /// The folder currently in use, or nil when iCloud Drive is not reachable.
    public func resolvedRootURL() async -> URL? {
        try? await resolveStorage().root
    }

    // MARK: CloudStorageProvider

    public func authState() async -> CloudAuthState {
        do {
            _ = try await resolveStorage()
            return .signedIn(account: nil)
        } catch {
            return .unavailable(reason: Self.unavailableHint)
        }
    }

    public func signIn(using authenticator: any WebAuthenticator) async throws {
        _ = try await resolveStorage()
    }

    public func signOut() async throws {}

    public func listFolder(_ path: CloudPath, pageToken: String?) async throws -> CloudListPage {
        let storage = try await resolveStorage()
        return try await BlockingIO.run { try storage.listPage(path, token: pageToken) }
    }

    public func stat(_ path: CloudPath) async throws -> CloudItem? {
        let storage = try await resolveStorage()
        return try await BlockingIO.run { try storage.stat(path, includeHash: false) }
    }

    public func download(_ path: CloudPath, to destination: URL) async throws -> CloudItem {
        let storage = try await resolveStorage()
        return try await BlockingIO.run { try storage.download(path, to: destination) }
    }

    public func upload(from source: URL, to path: CloudPath, precondition: UploadPrecondition) async throws -> CloudItem {
        let storage = try await resolveStorage()
        return try await BlockingIO.run { try storage.upload(from: source, to: path, precondition: precondition) }
    }

    public func createFolder(_ path: CloudPath) async throws -> CloudItem {
        let storage = try await resolveStorage()
        return try await BlockingIO.run { try storage.createFolder(path) }
    }

    public func delete(_ path: CloudPath) async throws {
        let storage = try await resolveStorage()
        try await BlockingIO.run { try storage.delete(path) }
    }
}
