import Foundation
import CryptoKit

/// Keeps a security-scoped URL "open" (sandbox access granted) for as long as the object lives.
final class SecurityScopedAccess: @unchecked Sendable {
    let url: URL
    private let started: Bool

    init(url: URL) {
        self.url = url
        self.started = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if started { url.stopAccessingSecurityScopedResource() }
    }
}

/// A folder that shows up in `FileProviderDiscovery` (or that the user picked) and can be used as a sync target.
public struct DiscoveredFolder: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case googleDriveDesktop, oneDriveDesktop, dropboxDesktop, boxDesktop, iCloudDrive, otherFileProvider
    }

    public var id: String { url.path }
    public var kind: Kind
    /// For example "Google Drive (desktop app) – you@gmail.com".
    public var displayName: String
    /// Folder to use as the provider root (for Google Drive this is the "My Drive" folder inside the account folder).
    public var url: URL
    public var accountHint: String?

    public init(kind: Kind, displayName: String, url: URL, accountHint: String? = nil) {
        self.kind = kind
        self.displayName = displayName
        self.url = url
        self.accountHint = accountHint
    }
}

/// Finds cloud storage that the vendors' desktop apps already mirror into regular folders, so the user can sync
/// to Google Drive / OneDrive / Dropbox / iCloud Drive without registering any API keys.
public enum FileProviderDiscovery {
    private static var home: URL {
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
        #else
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #endif
    }

    public static var defaultCloudStorageDirectory: URL {
        home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
    }

    public static var defaultICloudDriveDirectory: URL {
        home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    /// macOS only in practice (the folders do not exist on iOS). Both directories can be overridden for tests.
    public static func discover(cloudStorageDirectory: URL = defaultCloudStorageDirectory,
                                iCloudDriveDirectory: URL? = defaultICloudDriveDirectory) -> [DiscoveredFolder] {
        let fm = FileManager.default
        var found: [DiscoveredFolder] = []

        if let names = try? fm.contentsOfDirectory(atPath: cloudStorageDirectory.path) {
            for name in names.sorted() where !name.hasPrefix(".") {
                let url = cloudStorageDirectory.appendingPathComponent(name, isDirectory: true)
                guard isDirectory(url) else { continue }
                found.append(describe(name: name, url: url))
            }
        }
        if let iCloud = iCloudDriveDirectory, isDirectory(iCloud) {
            found.append(DiscoveredFolder(kind: .iCloudDrive, displayName: "iCloud Drive (folder on this Mac)", url: iCloud))
        }
        return found
    }

    static func describe(name: String, url: URL) -> DiscoveredFolder {
        func account(after prefix: String) -> String? {
            guard name.hasPrefix(prefix) else { return nil }
            let rest = String(name.dropFirst(prefix.count))
            return rest.isEmpty ? nil : rest
        }
        func label(_ service: String, _ account: String?) -> String {
            account.map { "\(service) (desktop app) – \($0)" } ?? "\(service) (desktop app)"
        }

        if name.hasPrefix("GoogleDrive") {
            let account = account(after: "GoogleDrive-")
            return DiscoveredFolder(kind: .googleDriveDesktop, displayName: label("Google Drive", account),
                                    url: googleDriveRoot(in: url), accountHint: account)
        }
        if name.hasPrefix("OneDrive") {
            let account = account(after: "OneDrive-")
            return DiscoveredFolder(kind: .oneDriveDesktop, displayName: label("OneDrive", account), url: url, accountHint: account)
        }
        if name.hasPrefix("Dropbox") {
            let account = account(after: "Dropbox-")
            return DiscoveredFolder(kind: .dropboxDesktop, displayName: label("Dropbox", account), url: url, accountHint: account)
        }
        if name.hasPrefix("Box") {
            let account = account(after: "Box-")
            return DiscoveredFolder(kind: .boxDesktop, displayName: label("Box", account), url: url, accountHint: account)
        }
        return DiscoveredFolder(kind: .otherFileProvider, displayName: "\(name) (desktop app)", url: url)
    }

    /// The Google Drive desktop app puts "My Drive" (localised on non-English systems) next to "Shared drives"
    /// inside the account folder. Pick "My Drive" when present, otherwise the only plausible sub-folder.
    static func googleDriveRoot(in accountFolder: URL) -> URL {
        let fm = FileManager.default
        let myDrive = accountFolder.appendingPathComponent("My Drive", isDirectory: true)
        if isDirectory(myDrive) { return myDrive }
        let children = ((try? fm.contentsOfDirectory(atPath: accountFolder.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .map { accountFolder.appendingPathComponent($0, isDirectory: true) }
            .filter { isDirectory($0) }
        let candidates = children.filter { !["Shared drives", "Computers", "Other computers"].contains($0.lastPathComponent) }
        return candidates.count == 1 ? candidates[0] : accountFolder
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var flag: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &flag) && flag.boolValue
    }
}

/// Sync target that is simply a folder: an external drive, a folder the iPad user picked in the Files app
/// (kept alive with a security-scoped bookmark), or a File Provider folder created by a vendor's desktop app.
public final class LocalFolderProvider: CloudStorageProvider {
    public let id: CloudProviderID
    public let displayName: String
    public let rootURL: URL
    private let storage: FileSystemStorage
    private let scope: SecurityScopedAccess?
    /// Present when created from a bookmark; save it again if `refreshedBookmarkData` is non-nil.
    public let refreshedBookmarkData: Data?

    /// - Parameters:
    ///   - id: stable identifier; defaults to one derived from the folder path.
    ///   - useFileCoordination: wrap reads/writes in NSFileCoordinator (recommended for File Provider folders).
    ///   - pageSize: listing page size (small values are handy for testing pagination).
    public convenience init(rootURL: URL, displayName: String? = nil, id: CloudProviderID? = nil,
                            useFileCoordination: Bool = true, pageSize: Int = 500, moveToTrashOnDelete: Bool = false) {
        self.init(rootURL: rootURL, displayName: displayName, id: id, useFileCoordination: useFileCoordination,
                  pageSize: pageSize, moveToTrashOnDelete: moveToTrashOnDelete, scope: nil, refreshedBookmark: nil)
    }

    private init(rootURL: URL, displayName: String?, id: CloudProviderID?, useFileCoordination: Bool,
                 pageSize: Int, moveToTrashOnDelete: Bool, scope: SecurityScopedAccess?, refreshedBookmark: Data?) {
        let resolved = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.rootURL = resolved
        self.id = id ?? Self.defaultID(for: resolved)
        self.displayName = displayName ?? resolved.lastPathComponent
        self.scope = scope
        self.refreshedBookmarkData = refreshedBookmark
        var storage = FileSystemStorage(root: resolved)
        storage.coordinated = useFileCoordination
        storage.pageSize = pageSize
        storage.moveToTrashOnDelete = moveToTrashOnDelete
        self.storage = storage
    }

    /// Uses a folder found by `FileProviderDiscovery`.
    public convenience init(discovered: DiscoveredFolder, id: CloudProviderID? = nil) {
        self.init(rootURL: discovered.url, displayName: discovered.displayName, id: id)
    }

    /// Re-opens a folder from saved bookmark data (see `makeBookmark(for:)`) and starts security-scoped access,
    /// which is how an iPad app keeps access to a folder the user chose in the Files app.
    public convenience init(bookmarkData: Data, displayName: String? = nil, id: CloudProviderID? = nil,
                            useFileCoordination: Bool = true) throws {
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: bookmarkData, options: Self.resolveOptions,
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            throw CloudError.unavailable("The saved folder can no longer be found. Please choose it again. (\(error.localizedDescription))")
        }
        let access = SecurityScopedAccess(url: url)
        let refreshed = stale ? (try? Self.makeBookmark(for: url)) : nil
        self.init(rootURL: url, displayName: displayName, id: id, useFileCoordination: useFileCoordination,
                  pageSize: 500, moveToTrashOnDelete: false, scope: access, refreshedBookmark: refreshed)
    }

    // MARK: Bookmarks

    private static var creationOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        return [.withSecurityScope]
        #else
        return []
        #endif
    }

    private static var resolveOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        return [.withSecurityScope]
        #else
        return []
        #endif
    }

    /// Creates bookmark data for a folder the user picked. Persist it and later call `init(bookmarkData:)`.
    /// (Call this while you still hold access, e.g. right after the document picker returns the URL.)
    public static func makeBookmark(for url: URL) throws -> Data {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return try url.bookmarkData(options: creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func defaultID(for url: URL) -> CloudProviderID {
        let digest = SHA256.hash(data: Data(url.path.utf8))
        return CloudProviderID(rawValue: "local." + FileHashing.hex(digest.prefix(6)))
    }

    // MARK: CloudStorageProvider

    public func authState() async -> CloudAuthState {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return .signedIn(account: nil)
        }
        return .unavailable(reason: "The folder \"\(displayName)\" is not available. Reconnect the drive or choose the folder again.")
    }

    public func signIn(using authenticator: any WebAuthenticator) async throws {
        if case .unavailable(let reason) = await authState() { throw CloudError.unavailable(reason) }
    }

    public func signOut() async throws {}

    public func listFolder(_ path: CloudPath, pageToken: String?) async throws -> CloudListPage {
        let storage = storage
        return try await BlockingIO.run { try storage.listPage(path, token: pageToken) }
    }

    /// Unlike listings, `stat` includes a SHA-256 content hash.
    public func stat(_ path: CloudPath) async throws -> CloudItem? {
        let storage = storage
        return try await BlockingIO.run { try storage.stat(path, includeHash: true) }
    }

    public func download(_ path: CloudPath, to destination: URL) async throws -> CloudItem {
        let storage = storage
        return try await BlockingIO.run { try storage.download(path, to: destination) }
    }

    public func upload(from source: URL, to path: CloudPath, precondition: UploadPrecondition) async throws -> CloudItem {
        let storage = storage
        return try await BlockingIO.run { try storage.upload(from: source, to: path, precondition: precondition) }
    }

    public func createFolder(_ path: CloudPath) async throws -> CloudItem {
        let storage = storage
        return try await BlockingIO.run { try storage.createFolder(path) }
    }

    public func delete(_ path: CloudPath) async throws {
        let storage = storage
        try await BlockingIO.run { try storage.delete(path) }
    }
}
