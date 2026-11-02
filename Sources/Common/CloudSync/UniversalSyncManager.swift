import Foundation

// MARK: - Configuration types

/// One mapping "local cache folder <-> folder on a provider". Persisted by the manager as JSON.
public struct SyncFolderConfig: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var providerID: CloudProviderID
    /// Absolute path of the local cache folder (where the app reads and writes its projects).
    public var localFolderPath: String
    /// Optional security-scoped bookmark for the local folder, for sandboxed / iPadOS locations.
    public var localFolderBookmark: Data?
    /// Folder on the provider, e.g. "/Paper".
    public var remoteFolder: CloudPath
    public var isEnabled: Bool

    public var localFolderURL: URL { URL(fileURLWithPath: localFolderPath, isDirectory: true) }

    public init(id: UUID = UUID(), name: String, providerID: CloudProviderID, localFolderPath: String,
                localFolderBookmark: Data? = nil, remoteFolder: CloudPath, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.providerID = providerID
        self.localFolderPath = localFolderPath
        self.localFolderBookmark = localFolderBookmark
        self.remoteFolder = remoteFolder
        self.isEnabled = isEnabled
    }
}

/// Snapshot of a registered provider for a settings screen.
public struct ProviderStatus: Sendable, Equatable, Identifiable {
    public var id: CloudProviderID
    public var displayName: String
    public var authState: CloudAuthState
}

// MARK: - Manager

/// The one object the apps talk to.
///
///     let manager = try UniversalSyncManager(stateDirectory: appSupport.appendingPathComponent("CloudSync"))
///     await manager.register(GoogleDriveProvider(configuration: keys))
///     let folder = try await manager.addSyncFolder(providerID: .googleDrive, localFolder: projectsURL,
///                                                  remoteFolder: "/Paper")
///     Task { for await event in manager.events() { ... } }
///     await manager.projectDidChange(projectURL)        // after every save: uploads 10 s after the last change
///     await manager.appWillSuspend()                    // on background / quit: upload everything right now
///     await manager.syncAll()                           // on launch / foreground: pull + push
///
/// Local-first: the app only ever reads and writes the local cache. The manager mirrors it to the cloud.
public actor UniversalSyncManager {
    public struct Options: Sendable {
        /// Quiet time after the last `projectDidChange` before the project is uploaded.
        public var debounceInterval: TimeInterval = 10
        public var package = PackageSyncOptions()
        /// Automatic retries (after the transport's own retries) for transient failures.
        public var maxAutomaticRetries = 6
        public var retryBaseDelay: TimeInterval = 15
        public var retryMaxDelay: TimeInterval = 600
        /// Injection points for tests.
        public var sleep: @Sendable (TimeInterval) async throws -> Void = HTTPTransport.realSleep
        public var now: @Sendable () -> Date = { Date() }

        public init() {}
    }

    private struct PackageKey: Hashable, Sendable {
        let folderID: UUID
        let package: String
    }

    private enum Scope: Sendable {
        case all
        case package(String)
    }

    private struct Issue: Sendable {
        var package: String?
        var transient: Bool
        var retryAfter: TimeInterval?
        /// Not an error: something changed mid-sync, try again soon.
        var deferred: Bool
    }

    private let options: Options
    private let configURL: URL
    private let stateStore: FileSyncStateStore
    private let hub = EventHub()

    private var providers: [CloudProviderID: any CloudStorageProvider] = [:]
    private var folders: [SyncFolderConfig] = []
    private var engines: [UUID: PackageSyncEngine] = [:]
    private var tails: [UUID: Task<Void, Never>] = [:]
    private var timers: [PackageKey: (generation: Int, task: Task<Void, Never>)] = [:]
    private var dirty: [PackageKey: Int] = [:]
    private var generationCounter = 0
    private var activeSyncs = 0

    /// - Parameter stateDirectory: where the manager keeps its own small files (folder list, sync bookkeeping).
    public init(stateDirectory: URL, options: Options = Options()) throws {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        self.options = options
        self.configURL = stateDirectory.appendingPathComponent("SyncFolders.json")
        self.stateStore = FileSyncStateStore(directory: stateDirectory)
        if let data = try? Data(contentsOf: configURL),
           let saved = try? JSONDecoder().decode([SyncFolderConfig].self, from: data) {
            self.folders = saved
        }
    }

    /// Status updates. Every call returns an independent stream, so several screens can listen at once.
    public nonisolated func events() -> AsyncStream<SyncEvent> { hub.makeStream() }

    // MARK: Providers

    public func register(_ provider: any CloudStorageProvider) {
        providers[provider.id] = provider
        for folder in folders where folder.providerID == provider.id { engines[folder.id] = nil }
    }

    public func unregisterProvider(_ id: CloudProviderID) {
        providers[id] = nil
        for folder in folders where folder.providerID == id { engines[folder.id] = nil }
    }

    public func providerStatuses() async -> [ProviderStatus] {
        var result: [ProviderStatus] = []
        for provider in providers.values.sorted(by: { $0.displayName < $1.displayName }) {
            result.append(ProviderStatus(id: provider.id, displayName: provider.displayName, authState: await provider.authState()))
        }
        return result
    }

    public func signIn(to providerID: CloudProviderID, using authenticator: any WebAuthenticator) async throws {
        guard let provider = providers[providerID] else {
            throw CloudError.unavailable("\(providerID.rawValue) is not registered.")
        }
        try await provider.signIn(using: authenticator)
    }

    public func signOut(of providerID: CloudProviderID) async throws {
        guard let provider = providers[providerID] else { return }
        try await provider.signOut()
    }

    // MARK: Sync folders

    public func syncFolders() -> [SyncFolderConfig] { folders }

    /// Maps a local cache folder to a folder on a provider and remembers the mapping across launches.
    @discardableResult
    public func addSyncFolder(name: String? = nil, providerID: CloudProviderID, localFolder: URL,
                              remoteFolder: CloudPath, localBookmark: Data? = nil) throws -> SyncFolderConfig {
        let path = localFolder.standardizedFileURL.path
        if let existing = folders.first(where: { $0.providerID == providerID && $0.localFolderPath == path && $0.remoteFolder == remoteFolder }) {
            return existing
        }
        try FileManager.default.createDirectory(at: localFolder, withIntermediateDirectories: true)
        let config = SyncFolderConfig(name: name ?? localFolder.lastPathComponent, providerID: providerID, localFolderPath: path,
                                      localFolderBookmark: localBookmark, remoteFolder: remoteFolder)
        folders.append(config)
        try saveFolders()
        return config
    }

    public func removeSyncFolder(id: UUID, forgetSyncState: Bool = true) throws {
        folders.removeAll { $0.id == id }
        engines[id] = nil
        for key in timers.keys where key.folderID == id { timers[key]?.task.cancel(); timers[key] = nil }
        for key in dirty.keys where key.folderID == id { dirty[key] = nil }
        if forgetSyncState { try stateStore.remove(folderID: id) }
        try saveFolders()
    }

    public func setSyncFolder(id: UUID, enabled: Bool) throws {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].isEnabled = enabled
        try saveFolders()
    }

    private func saveFolders() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(folders).write(to: configURL, options: .atomic)
    }

    // MARK: Syncing

    /// Pull + push for every enabled sync folder. Call on launch and when the app returns to the foreground.
    public func syncAll() async {
        for folder in folders where folder.isEnabled {
            let issues = await runSync(folderID: folder.id, scope: .all)
            followUp(on: issues, folderID: folder.id, attempt: 0)
        }
    }

    public func sync(folderID: UUID) async {
        let issues = await runSync(folderID: folderID, scope: .all)
        followUp(on: issues, folderID: folderID, attempt: 0)
    }

    /// Immediately syncs one project (both directions), skipping the debounce.
    public func syncProject(at url: URL) async {
        guard let (folder, package) = locate(url) else { return }
        let key = PackageKey(folderID: folder.id, package: package)
        timers[key]?.task.cancel()
        timers[key] = nil
        dirty[key] = nil
        let issues = await runSync(folderID: folder.id, scope: .package(package))
        followUp(on: issues, folderID: folder.id, attempt: 0)
    }

    /// Tell the manager that a project (or a file inside it) changed on disk. The upload happens after
    /// `debounceInterval` seconds without further changes.
    public func projectDidChange(_ url: URL) {
        guard let (folder, package) = locate(url) else { return }
        schedule(PackageKey(folderID: folder.id, package: package), after: options.debounceInterval, attempt: 0)
    }

    /// Whether any project is waiting for its debounced upload (or a retry).
    public var hasPendingChanges: Bool { !dirty.isEmpty }

    /// Call when the app is about to go to the background or quit: uploads every pending change right now.
    /// On iOS this asks the system for extra background time while it runs.
    public func appWillSuspend() async {
        let pending = Set(dirty.keys).union(timers.keys)
        for (_, timer) in timers { timer.task.cancel() }
        timers = [:]
        await BackgroundActivity.run(reason: "Uploading projects before the app is suspended") { [self] in
            await self.flush(pending)
        }
    }

    private func flush(_ keys: Set<PackageKey>) async {
        for key in keys.sorted(by: { ($0.folderID.uuidString, $0.package) < ($1.folderID.uuidString, $1.package) }) {
            dirty[key] = nil
            let issues = await runSync(folderID: key.folderID, scope: .package(key.package))
            followUp(on: issues, folderID: key.folderID, attempt: 0, immediateRetry: false)
        }
        // Also wait for anything that is already running.
        let running = Array(tails.values)
        for task in running { await task.value }
    }

    /// Deletes a project locally and on the provider (the only way a whole package is ever deleted remotely).
    public func deleteProject(at url: URL) async throws {
        guard let (folder, package) = locate(url) else {
            throw CloudError.fileSystem("\(url.lastPathComponent) is not inside a sync folder.")
        }
        let key = PackageKey(folderID: folder.id, package: package)
        timers[key]?.task.cancel()
        timers[key] = nil
        dirty[key] = nil
        guard let engine = try engine(for: folder) else {
            throw CloudError.unavailable("\(folder.providerID.rawValue) is not registered.")
        }
        let result: Result<Void, Error> = await serialized(folder.id) {
            do { try await engine.deletePackage(named: package); return .success(()) }
            catch { return .failure(error) }
        }
        try result.get()
    }

    /// Cancels timers; pending changes are kept in the sync bookkeeping and picked up by the next `syncAll`.
    public func shutdown() {
        for (_, timer) in timers { timer.task.cancel() }
        timers = [:]
    }

    // MARK: Internals

    private func engine(for folder: SyncFolderConfig) throws -> PackageSyncEngine? {
        if let existing = engines[folder.id] { return existing }
        guard let provider = providers[folder.providerID] else { return nil }
        let hub = hub
        let engine = try PackageSyncEngine(
            folderID: folder.id, provider: provider, localRoot: folder.localFolderURL, remoteRoot: folder.remoteFolder,
            options: options.package, stateStore: stateStore, now: options.now, emit: { hub.send($0) })
        engines[folder.id] = engine
        return engine
    }

    private func locate(_ url: URL) -> (SyncFolderConfig, String)? {
        let target = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        for folder in folders where folder.isEnabled {
            let root = folder.localFolderURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            guard target.count > root.count, Array(target.prefix(root.count)) == root else { continue }
            let name = target[root.count]
            guard PackageSyncEngine.isSafeName(name),
                  options.package.packageExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
            return (folder, name)
        }
        return nil
    }

    /// Runs `work` after everything previously queued for the same folder has finished.
    private func serialized<T: Sendable>(_ folderID: UUID, _ work: @escaping @Sendable () async -> T) async -> T {
        let previous = tails[folderID]
        let task = Task<T, Never> {
            await previous?.value
            return await work()
        }
        tails[folderID] = Task { _ = await task.value }
        return await task.value
    }

    private func runSync(folderID: UUID, scope: Scope) async -> [Issue] {
        await serialized(folderID) { await self.perform(folderID: folderID, scope: scope) }
    }

    private func perform(folderID: UUID, scope: Scope) async -> [Issue] {
        guard let folder = folders.first(where: { $0.id == folderID }), folder.isEnabled else { return [] }
        guard let provider = providers[folder.providerID] else {
            hub.send(.error("\(folder.name): \(folder.providerID.rawValue) is not registered."))
            return []
        }
        activeSyncs += 1
        defer {
            activeSyncs -= 1
            if activeSyncs == 0 { hub.send(.idle) }
        }

        switch await provider.authState() {
        case .signedIn: break
        case .signedOut:
            hub.send(.needsSignIn(provider.id))
            return []
        case .notConfigured(let hint):
            hub.send(.error(hint))
            return []
        case .unavailable(let reason):
            hub.send(.error(reason))
            return []
        }

        let engine: PackageSyncEngine
        do {
            guard let created = try self.engine(for: folder) else { return [] }
            engine = created
        } catch {
            hub.send(.error("\(folder.name): \(error.localizedDescription)"))
            return []
        }

        var scopedPackage: String?
        do {
            var issues: [Issue] = []
            switch scope {
            case .all:
                let run = try await engine.syncAll()
                for failure in run.failures {
                    hub.send(.error("\(failure.package): \(failure.message)"))
                    issues.append(Issue(package: failure.package, transient: failure.error?.isTransient ?? false,
                                        retryAfter: failure.error?.retryAfter, deferred: false))
                }
                for report in run.reports { if case .deferred = report.outcome { issues.append(Issue(package: report.package, transient: true, retryAfter: nil, deferred: true)) } }
            case .package(let name):
                scopedPackage = name
                for report in try await engine.syncPackage(named: name) {
                    if case .deferred = report.outcome { issues.append(Issue(package: report.package, transient: true, retryAfter: nil, deferred: true)) }
                }
            }
            return issues
        } catch let error as CloudError {
            if case .notSignedIn = error {
                hub.send(.needsSignIn(provider.id))
                return []
            }
            hub.send(.error(error.localizedDescription))
            return [Issue(package: scopedPackage, transient: error.isTransient, retryAfter: error.retryAfter, deferred: false)]
        } catch is CancellationError {
            return []
        } catch {
            hub.send(.error(error.localizedDescription))
            return []
        }
    }

    // MARK: Debounce and retry

    private func schedule(_ key: PackageKey, after delay: TimeInterval, attempt: Int) {
        timers[key]?.task.cancel()
        generationCounter += 1
        let generation = generationCounter
        dirty[key] = attempt
        let sleep = options.sleep
        let task = Task { [self] in
            do { try await sleep(delay) } catch { return }
            await self.timerFired(key, generation: generation)
        }
        timers[key] = (generation, task)
    }

    private func timerFired(_ key: PackageKey, generation: Int) async {
        guard timers[key]?.generation == generation else { return } // superseded by a newer change
        timers[key] = nil
        let attempt = dirty[key] ?? 0
        dirty[key] = nil
        let issues = await runSync(folderID: key.folderID, scope: .package(key.package))
        followUp(on: issues, folderID: key.folderID, attempt: attempt)
    }

    /// Re-schedules packages whose sync hit a transient problem or was deferred, with exponential backoff
    /// (1x, 2x, 4x ... of the base delay) and a limit, so a permanently stuck package cannot poll forever.
    private func followUp(on issues: [Issue], folderID: UUID, attempt: Int, immediateRetry: Bool = true) {
        guard immediateRetry else { return }
        for issue in issues where issue.transient {
            guard let package = issue.package else { continue }
            let key = PackageKey(folderID: folderID, package: package)
            if timers[key] != nil { continue } // a newer change already scheduled an upload
            let next = attempt + 1
            guard next <= options.maxAutomaticRetries else {
                if !issue.deferred {
                    hub.send(.error("Giving up on \(package) for now after \(attempt) retries. It will be tried again on the next sync."))
                }
                continue
            }
            // "Deferred" means the package changed under us or another device is mid-upload: wait a debounce interval
            // first. Real failures start from the (longer) retry base delay.
            let base = issue.deferred ? options.debounceInterval : options.retryBaseDelay
            let backoff = min(options.retryMaxDelay, base * pow(2, Double(attempt)))
            schedule(key, after: max(backoff, issue.retryAfter ?? 0), attempt: next)
        }
    }
}

// MARK: - Background time

/// Keeps the process running while an upload finishes.
///
/// macOS: `ProcessInfo.beginActivity` (prevents sudden termination). iOS / iPadOS: `performExpiringActivity`,
/// the only place in this library that is iOS-only (see `platformHook`); the rest of the logic is shared and tested.
enum BackgroundActivity {
    typealias Hook = @Sendable (_ reason: String, _ block: @escaping @Sendable (_ expired: Bool) -> Void) -> Void

    static var platformHook: Hook? {
        #if os(iOS)
        return { reason, block in
            ProcessInfo.processInfo.performExpiringActivity(withReason: reason, using: block)
        }
        #else
        return nil
        #endif
    }

    private final class Runner: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?
        private var finished = false
        private var cancelRequested = false
        private var continuation: CheckedContinuation<Void, Never>?

        func setContinuation(_ value: CheckedContinuation<Void, Never>) {
            lock.lock(); continuation = value; lock.unlock()
        }
        func setTask(_ value: Task<Void, Never>) {
            lock.lock()
            task = value
            let alreadyExpired = cancelRequested
            lock.unlock()
            if alreadyExpired { value.cancel() } // expiry arrived before the work started
        }
        func cancelWork() {
            lock.lock()
            cancelRequested = true
            let current = task
            lock.unlock()
            current?.cancel()
        }
        func finish() {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume()
        }
    }

    static func run(reason: String, hook: Hook? = platformHook, body: @escaping @Sendable () async -> Void) async {
        guard let hook else {
            let token = ProcessInfo.processInfo.beginActivity(options: [.suddenTerminationDisabled, .automaticTerminationDisabled], reason: reason)
            await body()
            ProcessInfo.processInfo.endActivity(token)
            return
        }
        let runner = Runner()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            runner.setContinuation(continuation)
            hook(reason) { expired in
                if expired {
                    // The system wants its time back: stop the work and let the caller continue.
                    runner.cancelWork()
                    runner.finish()
                    return
                }
                let done = DispatchSemaphore(value: 0)
                runner.setTask(Task {
                    await body()
                    done.signal()
                })
                done.wait() // the activity lasts as long as this block runs
                runner.finish()
            }
        }
    }
}
