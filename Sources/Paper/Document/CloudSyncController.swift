import Foundation
import Observation
import AuthenticationServices
import CommonKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Bridges the `UniversalSyncManager` actor (CommonKit) to SwiftUI: account status, sign-in, which
/// gallery folders sync where, and a live status line. Paper calls `projectDidChange` after every save;
/// the manager uploads after 10 s of quiet, or immediately on `appWillSuspend`.
@MainActor
@Observable
public final class CloudSyncController {
    public private(set) var providers: [ProviderStatus] = []
    public private(set) var folders: [SyncFolderConfig] = []
    public private(set) var statusText = "Up to date"
    public private(set) var isSyncing = false
    public private(set) var progress: Double?
    public private(set) var lastError: String?
    /// Conflicted copies created recently (both devices edited the same artwork).
    public private(set) var conflicts: [URL] = []

    /// Called when a download changed a project package (reload it if it's open).
    @ObservationIgnored public var onProjectUpdated: ((URL) -> Void)?
    /// Where the user puts `CloudKeys.plist` with their own Google/Dropbox/OneDrive app IDs.
    @ObservationIgnored public let keysFileURL: URL?
    @ObservationIgnored let manager: UniversalSyncManager
    @ObservationIgnored private var listener: Task<Void, Never>?

    public init(manager: UniversalSyncManager, providers: [any CloudStorageProvider], keysFileURL: URL?) {
        self.manager = manager
        self.keysFileURL = keysFileURL
        listener = Task { [weak self] in
            for p in providers { await manager.register(p) }
            await self?.refresh()
            await manager.syncAll()
            for await event in manager.events() {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    /// The real thing: tokens in the Keychain, app keys from Application Support/Paper/CloudKeys.plist.
    public static func live(appFolderName: String = "Paper") -> CloudSyncController? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let state = support.appendingPathComponent("\(appFolderName)/Sync", isDirectory: true)
        guard let manager = try? UniversalSyncManager(stateDirectory: state) else { return nil }
        let keys = CloudProviderConfiguration.loadDefault(appFolderName: appFolderName)
        return CloudSyncController(manager: manager,
                                   providers: CloudProviderCatalog.standardProviders(configuration: keys),
                                   keysFileURL: CloudProviderConfiguration.defaultFileURL(appFolderName: appFolderName))
    }

    deinit { listener?.cancel() }

    private func handle(_ event: SyncEvent) {
        switch event {
        case .idle:
            isSyncing = false
            progress = nil
            statusText = "Up to date"
        case .syncing(let p):
            isSyncing = true
            progress = p.totalFiles > 0 ? p.fraction : nil
            let verb = p.phase == .downloading ? "Downloading" : p.phase == .uploading ? "Uploading" : "Checking"
            statusText = "\(verb)\(p.package.map { " \(($0 as NSString).deletingPathExtension)" } ?? "")…"
        case .conflict(let copy):
            conflicts.insert(copy, at: 0)
            statusText = "Kept both versions: \(copy.deletingPathExtension().lastPathComponent)"
            onProjectUpdated?(copy)
        case .projectUpdated(let url):
            onProjectUpdated?(url)
        case .error(let message):
            lastError = message
            statusText = "Sync problem"
        case .needsSignIn(let id):
            lastError = "Please sign in to \(providers.first { $0.id == id }?.displayName ?? id.rawValue) again."
            statusText = "Sign-in needed"
        }
    }

    public func refresh() async {
        providers = await manager.providerStatuses()
        folders = await manager.syncFolders()
    }

    public func signIn(_ id: CloudProviderID) async {
        lastError = nil
        do {
            let auth = SystemWebAuthenticator { Self.presentationAnchor() }
            try await manager.signIn(to: id, using: auth)
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
    }

    public func signOut(_ id: CloudProviderID) async {
        do { try await manager.signOut(of: id) } catch { lastError = error.localizedDescription }
        await refresh()
    }

    /// Keeps `folder` (a gallery folder) in sync with `remoteFolder` on a provider.
    public func connect(folder: URL, to id: CloudProviderID, remoteFolder: String = "/Paper Artworks") async {
        do {
            try await manager.addSyncFolder(name: folder.lastPathComponent, providerID: id, localFolder: folder,
                                            remoteFolder: CloudPath(remoteFolder))
            await refresh()
            await manager.syncAll()
        } catch { lastError = error.localizedDescription }
    }

    public func disconnect(_ folderID: UUID) async {
        do { try await manager.removeSyncFolder(id: folderID) } catch { lastError = error.localizedDescription }
        await refresh()
    }

    public func projectDidChange(_ url: URL) {
        Task { await manager.projectDidChange(url) }
    }

    public func appWillSuspend() {
        Task { await manager.appWillSuspend() }
    }

    public func syncNow() {
        Task { await manager.syncAll() }
    }

    /// Writes a fill-in-the-blanks `CloudKeys.plist` (if there isn't one) and returns its location.
    @discardableResult
    public func writeKeysTemplate() -> URL? {
        guard let url = keysFileURL else { return nil }
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? CloudProviderConfiguration.template.write(to: url)
        }
        return url
    }

    private static func presentationAnchor() -> ASPresentationAnchor {
        #if os(macOS)
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
        #endif
    }
}
