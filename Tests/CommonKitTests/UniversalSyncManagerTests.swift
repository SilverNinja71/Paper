import Foundation
import Testing
@testable import CommonKit

/// A sleep that only ends when the test says so (or when its task is cancelled), so debounce timing is exact.
final class ManualSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var asked: [TimeInterval] = []

    var requested: [TimeInterval] { lock.withLock { asked } }
    var pendingCount: Int { lock.withLock { waiting.count } }

    func sleep(_ seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock { asked.append(seconds); waiting[id] = continuation }
                if Task.isCancelled { cancel(id) }
            }
        } onCancel: {
            cancel(id)
        }
    }

    private func cancel(_ id: UUID) {
        let continuation = lock.withLock { waiting.removeValue(forKey: id) }
        continuation?.resume(throwing: CancellationError())
    }

    func releaseAll() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            let values = Array(waiting.values)
            waiting = [:]
            return values
        }
        for continuation in all { continuation.resume() }
    }
}

/// Collects manager events in the background.
final class EventCollector: @unchecked Sendable {
    private let log = EventLog()
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<SyncEvent>) {
        let log = log
        task = Task { for await event in stream { log.append(event) } }
    }

    deinit { task?.cancel() }

    var events: [SyncEvent] { log.events }
    var errors: [String] { events.compactMap { if case .error(let message) = $0 { return message } else { return nil } } }
    var conflictCopies: [URL] { log.conflictCopies }
    func contains(_ event: SyncEvent) -> Bool { events.contains(event) }
}

/// A manager wired to a temp "cloud" folder.
struct ManagerRig {
    let box: Sandbox
    let cloud: URL
    let local: URL
    let stateDirectory: URL
    let provider: RecordingProvider
    let manager: UniversalSyncManager
    let folder: SyncFolderConfig

    static let cloudID: CloudProviderID = "test.cloud"

    init(box: Sandbox? = nil, name: String = "A", debounce: TimeInterval = 10, policy: ConflictPolicy = .newerWins,
         sleep: (@Sendable (TimeInterval) async throws -> Void)? = nil, retryBase: TimeInterval = 1,
         maxRetries: Int = 6) async throws {
        let box = try box ?? Sandbox("manager")
        self.box = box
        cloud = try box.folder("cloud")
        local = try box.folder("device-\(name)/Projects")
        stateDirectory = try box.folder("device-\(name)/state")
        provider = RecordingProvider(LocalFolderProvider(rootURL: cloud, id: Self.cloudID))
        var options = UniversalSyncManager.Options()
        options.debounceInterval = debounce
        options.retryBaseDelay = retryBase
        options.maxAutomaticRetries = maxRetries
        options.package = PackageSyncOptions(conflictPolicy: policy, timeZone: TimeZone(identifier: "UTC")!)
        if let sleep { options.sleep = sleep }
        manager = try UniversalSyncManager(stateDirectory: stateDirectory, options: options)
        await manager.register(provider)
        folder = try await manager.addSyncFolder(name: "Projects", providerID: Self.cloudID, localFolder: local, remoteFolder: "/Paper")
    }

    var project: URL { local.appendingPathComponent("Art.paper", isDirectory: true) }
    var remote: [String: String] { Fixture.snapshot(package: "Art.paper", in: cloud.appendingPathComponent("Paper")) }
}

@Suite("UniversalSyncManager", .timeLimit(.minutes(2)))
struct UniversalSyncManagerTests {
    @Test func defaultDebounceIsTenSeconds() {
        #expect(UniversalSyncManager.Options().debounceInterval == 10)
    }

    // MARK: Debounce

    @Test func uploadHappensOnlyAfterTheIdleInterval() async throws {
        let sleeper = ManualSleeper()
        let rig = try await ManagerRig(debounce: 10, sleep: sleeper.sleep)
        let events = EventCollector(rig.manager.events())
        try Fixture.write(v1, toPackage: "Art.paper", in: rig.local)

        await rig.manager.projectDidChange(rig.project.appendingPathComponent("layers/a.bin"))
        #expect(await rig.manager.hasPendingChanges)
        #expect(await waitUntil { sleeper.requested == [10] })
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(rig.provider.uploads.isEmpty) // 10 "seconds" have not passed

        sleeper.releaseAll()
        #expect(await waitUntil { rig.remote == v1 && rig.provider.uploads.count == 4 })
        #expect(rig.provider.uploads.last?.hasSuffix("manifest.json") == true) // commit point last
        #expect(await waitUntil { events.contains(.idle) })
        #expect(await !rig.manager.hasPendingChanges)
        #expect(events.events.contains { if case .syncing = $0 { return true } else { return false } })
    }

    @Test func everyNewChangeRestartsTheCountdown() async throws {
        let sleeper = ManualSleeper()
        let rig = try await ManagerRig(debounce: 10, sleep: sleeper.sleep)
        try Fixture.write(v1, toPackage: "Art.paper", in: rig.local)

        for step in 1...3 {
            try Fixture.set("edit \(step) of the layer", at: "layers/a.bin", inPackage: "Art.paper", in: rig.local)
            await rig.manager.projectDidChange(rig.project)
            #expect(await waitUntil { sleeper.requested.count == step })
        }
        // three countdowns were started but the first two were cancelled by the later changes
        #expect(sleeper.requested == [10, 10, 10])
        #expect(await waitUntil { sleeper.pendingCount == 1 })
        #expect(rig.provider.uploads.isEmpty)

        sleeper.releaseAll()
        #expect(await waitUntil { rig.provider.uploads.contains { $0.hasSuffix("manifest.json") } })
        #expect(rig.remote["layers/a.bin"] == "edit 3 of the layer")
        try await Task.sleep(nanoseconds: 200_000_000) // give a (wrong) second upload the chance to show up
        #expect(rig.provider.uploads.filter { $0.hasSuffix("manifest.json") }.count == 1) // one upload, not three
    }

    @Test func realTimeDebounceFiresAfterTheShortInjectedInterval() async throws {
        let rig = try await ManagerRig(debounce: 0.4)
        try Fixture.write(v1, toPackage: "Art.paper", in: rig.local)
        let started = Date()
        await rig.manager.projectDidChange(rig.project)
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(rig.provider.uploads.isEmpty)
        #expect(await waitUntil { rig.remote == v1 })
        #expect(Date().timeIntervalSince(started) >= 0.35)
    }

    @Test func changesOutsideAnyPackageAreIgnored() async throws {
        let sleeper = ManualSleeper()
        let rig = try await ManagerRig(sleep: sleeper.sleep)
        await rig.manager.projectDidChange(rig.local.appendingPathComponent("notes.txt"))
        await rig.manager.projectDidChange(rig.box.root.appendingPathComponent("elsewhere/Art.paper"))
        await rig.manager.projectDidChange(rig.local)
        #expect(await !rig.manager.hasPendingChanges)
        #expect(sleeper.requested.isEmpty)
    }

    // MARK: Suspend

    @Test func appWillSuspendUploadsEverythingRightNow() async throws {
        let sleeper = ManualSleeper() // the 10 s timer never fires in this test
        let rig = try await ManagerRig(sleep: sleeper.sleep)
        try Fixture.write(v1, toPackage: "Art.paper", in: rig.local)
        await rig.manager.projectDidChange(rig.project)
        #expect(rig.provider.uploads.isEmpty)

        await rig.manager.appWillSuspend()
        #expect(rig.remote == v1)
        #expect(await !rig.manager.hasPendingChanges)
        #expect(await waitUntil { sleeper.pendingCount == 0 }) // countdown was cancelled
    }

    @Test func backgroundActivityRunsTheWorkInsideTheSystemHook() async {
        let ran = Counter()
        await BackgroundActivity.run(reason: "test", hook: { reason, block in
            DispatchQueue.global().async { block(false) }
        }, body: { _ = ran.increment() })
        #expect(ran.current == 1)

        // The system refuses to give time: do not hang.
        await BackgroundActivity.run(reason: "test", hook: { _, block in
            DispatchQueue.global().async { block(true) }
        }, body: { _ = ran.increment() })
        #expect(ran.current == 1)

        // Time runs out while working: the work is cancelled and the caller continues.
        let cancelled = Counter()
        await BackgroundActivity.run(reason: "test", hook: { _, block in
            DispatchQueue.global().async {
                block(false)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { block(true) }
        }, body: {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if Task.isCancelled { _ = cancelled.increment() }
        })
        #expect(await waitUntil { cancelled.current == 1 })
    }

    @Test func macOSFallbackUsesAProcessActivity() async {
        let ran = Counter()
        await BackgroundActivity.run(reason: "test", hook: nil, body: { _ = ran.increment() })
        #expect(ran.current == 1)
    }

    // MARK: syncAll, events, conflicts

    @Test func syncAllPullsOtherDevicesAndReportsEvents() async throws {
        let box = try Sandbox("two-managers")
        let a = try await ManagerRig(box: box, name: "A")
        let b = try await ManagerRig(box: box, name: "B")
        try Fixture.write(v1, toPackage: "Art.paper", in: a.local)
        await a.manager.syncAll()
        #expect(a.remote == v1)

        let events = EventCollector(b.manager.events())
        await b.manager.syncAll()
        #expect(Fixture.snapshot(package: "Art.paper", in: b.local) == v1)
        #expect(await waitUntil { events.contains(.idle) })
        #expect(events.events.contains(.projectUpdated(b.project.resolvingSymlinksInPath())) || events.events.contains { if case .projectUpdated(let url) = $0 { return url.lastPathComponent == "Art.paper" } else { return false } })
        #expect(events.errors.isEmpty)
    }

    @Test func conflictsAreAnnouncedWithTheCreatedCopy() async throws {
        let box = try Sandbox("conflict-managers")
        let a = try await ManagerRig(box: box, name: "A", policy: .keepLocal)
        let b = try await ManagerRig(box: box, name: "B", policy: .keepLocal)
        try Fixture.write(v1, toPackage: "Art.paper", in: a.local)
        await a.manager.syncAll()
        await b.manager.syncAll()

        try Fixture.set("A changed it", at: "layers/a.bin", inPackage: "Art.paper", in: a.local)
        try Fixture.set("{\"a\":1}", at: "manifest.json", inPackage: "Art.paper", in: a.local)
        await a.manager.syncAll()
        try Fixture.set("B changed it too!", at: "layers/a.bin", inPackage: "Art.paper", in: b.local)
        try Fixture.set("{\"b\":1}", at: "manifest.json", inPackage: "Art.paper", in: b.local)

        let events = EventCollector(b.manager.events())
        await b.manager.syncAll()
        #expect(await waitUntil { !events.conflictCopies.isEmpty })
        let copy = try #require(events.conflictCopies.first)
        #expect(copy.lastPathComponent.hasPrefix("Art (Conflicted Copy "))
        #expect(copy.lastPathComponent.hasSuffix(").paper"))
        #expect(FileManager.default.fileExists(atPath: copy.path))
        #expect(Fixture.read("layers/a.bin", inPackage: copy.lastPathComponent, in: b.local) == "A changed it")
        #expect(Fixture.read("layers/a.bin", inPackage: "Art.paper", in: b.local) == "B changed it too!")
    }

    @Test func signedOutProvidersAskForSignIn() async throws {
        let rig = try await ManagerRig()
        await rig.manager.register(StubProvider(id: "stub.cloud", displayName: "Stub Cloud", state: .signedOut))
        _ = try await rig.manager.addSyncFolder(providerID: "stub.cloud", localFolder: try rig.box.folder("stub-local"), remoteFolder: "/Paper")
        let events = EventCollector(rig.manager.events())
        await rig.manager.syncAll()
        #expect(await waitUntil { events.contains(.needsSignIn("stub.cloud")) })
        #expect(await waitUntil { events.contains(.idle) })

        let statuses = await rig.manager.providerStatuses()
        #expect(statuses.first { $0.id == "stub.cloud" }?.authState == .signedOut)
        #expect(statuses.first { $0.id == ManagerRig.cloudID }?.authState == .signedIn(account: nil))
    }

    @Test func unconfiguredProvidersExplainWhatToDo() async throws {
        let rig = try await ManagerRig()
        let google = GoogleDriveProvider(configuration: CloudProviderConfiguration(), tokenStore: InMemoryTokenStore())
        await rig.manager.register(google)
        _ = try await rig.manager.addSyncFolder(providerID: .googleDrive, localFolder: try rig.box.folder("g-local"), remoteFolder: "/Paper")
        let events = EventCollector(rig.manager.events())
        await rig.manager.syncAll()
        #expect(await waitUntil { events.errors.contains { $0.contains("Register") && $0.contains("CloudKeys.plist") } })
    }

    @Test func eachCallToEventsIsAnIndependentStream() async throws {
        let rig = try await ManagerRig()
        let first = EventCollector(rig.manager.events())
        let second = EventCollector(rig.manager.events())
        try Fixture.write(v1, toPackage: "Art.paper", in: rig.local)
        await rig.manager.syncAll()
        #expect(await waitUntil { first.contains(.idle) && second.contains(.idle) })
    }

    // MARK: Persistence

    @Test func foldersAndSyncStateSurviveARestart() async throws {
        let rig = try await ManagerRig()
        try Fixture.write(v1, toPackage: "Art.paper", in: rig.local)
        await rig.manager.syncAll()
        #expect(rig.remote == v1)

        let reborn = try UniversalSyncManager(stateDirectory: rig.stateDirectory)
        #expect(await reborn.syncFolders() == [rig.folder])
        let provider = RecordingProvider(LocalFolderProvider(rootURL: rig.cloud, id: ManagerRig.cloudID))
        await reborn.register(provider)
        await reborn.syncAll()
        #expect(provider.uploads.isEmpty && provider.downloads.isEmpty) // remembered what was already synced
    }

    @Test func removingAFolderForgetsItsBookkeeping() async throws {
        let rig = try await ManagerRig()
        try await rig.manager.removeSyncFolder(id: rig.folder.id)
        #expect(await rig.manager.syncFolders().isEmpty)
        let reborn = try UniversalSyncManager(stateDirectory: rig.stateDirectory)
        #expect(await reborn.syncFolders().isEmpty)
    }

    @Test func addingTheSameMappingTwiceReturnsTheExistingOne() async throws {
        let rig = try await ManagerRig()
        let again = try await rig.manager.addSyncFolder(providerID: ManagerRig.cloudID, localFolder: rig.local, remoteFolder: "/Paper")
        #expect(again.id == rig.folder.id)
        #expect(await rig.manager.syncFolders().count == 1)
    }

    // MARK: Retries

    @Test func transientFailuresAreRetriedWithExponentialBackoff() async throws {
        let durations = SleepRecorder()
        let box = try Sandbox("retry")
        let cloud = try box.folder("cloud")
        let inner = RecordingProvider(LocalFolderProvider(rootURL: cloud, id: ManagerRig.cloudID))
        // Fail the first two attempts, then let the cloud recover.
        inner.failUploads(after: 0, with: .network("offline"))
        let counter = Counter()
        let rig = try await ManagerRig(box: box, name: "R", debounce: 10, sleep: { seconds in
            try await durations.sleeper(seconds)
            if counter.increment() == 3 { inner.failUploads(after: nil) } // recovery before the third attempt
        }, retryBase: 1)
        await rig.manager.register(inner) // replaces the rig's own provider (same id)
        try Fixture.write(v1, toPackage: "Art.paper", in: rig.local)

        let events = EventCollector(rig.manager.events())
        await rig.manager.projectDidChange(rig.project)
        #expect(await waitUntil(timeout: 10) { rig.remote == v1 })
        #expect(durations.durations == [10, 1, 2]) // debounce, then 1 s, then 2 s of backoff
        #expect(events.errors.count == 2)
        #expect(events.errors.allSatisfy { $0.contains("offline") })
    }

    @Test func retryAfterFromTheServerIsAtLeastRespected() async throws {
        let durations = SleepRecorder()
        let box = try Sandbox("retry-after")
        let cloud = try box.folder("cloud")
        let inner = RecordingProvider(LocalFolderProvider(rootURL: cloud, id: ManagerRig.cloudID))
        inner.failUploads(after: 0, with: .rateLimited(retryAfter: 30))
        let counter = Counter()
        let rig = try await ManagerRig(box: box, name: "R", debounce: 10, sleep: { seconds in
            try await durations.sleeper(seconds)
            if counter.increment() == 2 { inner.failUploads(after: nil) }
        }, retryBase: 1)
        await rig.manager.register(inner)
        try Fixture.write(v1, toPackage: "Art.paper", in: rig.local)
        await rig.manager.projectDidChange(rig.project)
        #expect(await waitUntil(timeout: 10) { rig.remote == v1 })
        #expect(durations.durations == [10, 30])
    }

    @Test func givesUpAfterTheConfiguredNumberOfRetries() async throws {
        let box = try Sandbox("giveup")
        let cloud = try box.folder("cloud")
        let inner = RecordingProvider(LocalFolderProvider(rootURL: cloud, id: ManagerRig.cloudID))
        inner.failUploads(after: 0, with: .http(status: 503, message: "down"))
        let rig = try await ManagerRig(box: box, name: "R", debounce: 0, sleep: { _ in }, retryBase: 1, maxRetries: 3)
        await rig.manager.register(inner)
        try Fixture.write(v1, toPackage: "Art.paper", in: rig.local)
        let events = EventCollector(rig.manager.events())
        await rig.manager.projectDidChange(rig.project)
        #expect(await waitUntil(timeout: 10) { events.errors.contains { $0.contains("Giving up") } })
        #expect(rig.remote.isEmpty)
        // 1 first attempt + 3 retries
        #expect(await waitUntil { events.errors.filter { $0.contains("down") }.count == 4 })
    }

    @Test func waitingForAnotherDevicesUnfinishedUploadBacksOffAndStops() async throws {
        let durations = SleepRecorder()
        let box = try Sandbox("deferred")
        let rig = try await ManagerRig(box: box, name: "B", debounce: 10, sleep: { seconds in try await durations.sleeper(seconds) },
                                       retryBase: 1, maxRetries: 4)
        // Another device left a package in the cloud that never got its manifest.
        try Fixture.write(["layers/a.bin": "half-uploaded"], toPackage: "Art.paper", in: rig.cloud.appendingPathComponent("Paper"))
        let events = EventCollector(rig.manager.events())
        await rig.manager.syncAll()
        #expect(await waitUntil { durations.durations.count == 4 })
        #expect(durations.durations == [10, 20, 40, 80]) // doubles, then stops after maxAutomaticRetries
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(durations.durations.count == 4)
        #expect(events.errors.isEmpty) // waiting is not an error
        #expect(Fixture.packageNames(in: rig.local).isEmpty)

        // The other device finishes: the next sync picks the project up.
        try Fixture.write(v1, toPackage: "Art.paper", in: rig.cloud.appendingPathComponent("Paper"))
        await rig.manager.syncAll()
        #expect(Fixture.snapshot(package: "Art.paper", in: rig.local) == v1)
    }

    // MARK: Deleting

    @Test func deleteProjectRemovesLocalAndCloudCopies() async throws {
        let rig = try await ManagerRig()
        try Fixture.write(v1, toPackage: "Art.paper", in: rig.local)
        await rig.manager.syncAll()
        try await rig.manager.deleteProject(at: rig.project)
        #expect(!FileManager.default.fileExists(atPath: rig.project.path))
        #expect(rig.remote.isEmpty)
        await rig.manager.syncAll()
        #expect(!FileManager.default.fileExists(atPath: rig.project.path))
        await #expect(throws: CloudError.self) { try await rig.manager.deleteProject(at: rig.box.root.appendingPathComponent("nowhere/X.paper")) }
    }

    @Test func syncProjectSkipsTheCountdown() async throws {
        let sleeper = ManualSleeper()
        let rig = try await ManagerRig(sleep: sleeper.sleep)
        try Fixture.write(v1, toPackage: "Art.paper", in: rig.local)
        await rig.manager.projectDidChange(rig.project)
        await rig.manager.syncProject(at: rig.project)
        #expect(rig.remote == v1)
        #expect(await !rig.manager.hasPendingChanges)
    }
}
