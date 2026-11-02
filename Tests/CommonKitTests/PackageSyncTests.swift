import Foundation
import Testing
@testable import CommonKit

/// Thread-safe list of events published by an engine.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [SyncEvent] = []
    func append(_ event: SyncEvent) { lock.withLock { items.append(event) } }
    var events: [SyncEvent] { lock.withLock { items } }
    var conflictCopies: [URL] { events.compactMap { if case .conflict(let url) = $0 { return url } else { return nil } } }
    var updatedProjects: [URL] { events.compactMap { if case .projectUpdated(let url) = $0 { return url } else { return nil } } }
}

/// One simulated device: its own local cache folder, its own sync bookkeeping, a view of the shared "cloud".
struct Device {
    let name: String
    let local: URL
    let provider: RecordingProvider
    let engine: PackageSyncEngine
    let log: EventLog
    let stateDirectory: URL
}

/// Two (or more) devices sharing one temporary "cloud" folder reached through `LocalFolderProvider`.
struct World {
    let box: Sandbox
    let cloud: URL
    static let fixedNow: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 26; c.hour = 14; c.minute = 30; c.second = 5
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }()

    init() throws {
        box = try Sandbox("world")
        cloud = try box.folder("cloud")
    }

    func device(_ name: String, policy: ConflictPolicy = .newerWins) throws -> Device {
        let local = try box.folder("device-\(name)/Projects")
        let stateDirectory = try box.folder("device-\(name)/state")
        let provider = RecordingProvider(LocalFolderProvider(rootURL: cloud, id: "test.cloud", pageSize: 2))
        let log = EventLog()
        let engine = try PackageSyncEngine(
            folderID: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!, provider: provider, localRoot: local,
            remoteRoot: "/Paper",
            options: PackageSyncOptions(conflictPolicy: policy, timeZone: TimeZone(identifier: "UTC")!),
            stateStore: FileSyncStateStore(directory: stateDirectory), now: { Self.fixedNow }, emit: { log.append($0) })
        return Device(name: name, local: local, provider: provider, engine: engine, log: log, stateDirectory: stateDirectory)
    }

    /// Same device after an app restart: new engine object, same folders and bookkeeping.
    func relaunch(_ device: Device) throws -> Device {
        let log = EventLog()
        let engine = try PackageSyncEngine(
            folderID: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!, provider: device.provider,
            localRoot: device.local, remoteRoot: "/Paper",
            options: PackageSyncOptions(timeZone: TimeZone(identifier: "UTC")!),
            stateStore: FileSyncStateStore(directory: device.stateDirectory), now: { Self.fixedNow }, emit: { log.append($0) })
        return Device(name: device.name, local: device.local, provider: device.provider, engine: engine, log: log, stateDirectory: device.stateDirectory)
    }

    var remotePackages: [String] { Fixture.packageNames(in: cloud.appendingPathComponent("Paper")) }
    func remote(_ package: String) -> [String: String] { Fixture.snapshot(package: package, in: cloud.appendingPathComponent("Paper")) }
}

/// Strips "/Paper/<package>/" so assertions read naturally.
func relative(_ paths: [String], in package: String = "Art.paper") -> [String] {
    paths.map { $0.replacingOccurrences(of: "/Paper/\(package)/", with: "") }
}

let v1: [String: String] = [
    "manifest.json": #"{"layers":["a","b"],"rev":1}"#,
    "layers/a.bin": "layer-a-v1",
    "layers/b.bin": "layer-b-v1",
    "thumbnail.png": "png-v1",
]

@Suite("Atomic delta sync between two devices", .timeLimit(.minutes(2)))
struct PackageSyncTests {
    // MARK: Upload

    @Test func firstUploadSendsEveryFileAndTheManifestLast() async throws {
        let world = try World()
        let a = try world.device("A")
        try Fixture.write(v1, toPackage: "Art.paper", in: a.local)

        let reports = try await a.engine.syncPackage(named: "Art.paper")
        #expect(reports.count == 1)
        #expect(reports[0].outcome == .uploaded)
        #expect(relative(a.provider.uploads) == ["layers/a.bin", "layers/b.bin", "thumbnail.png", "manifest.json"])
        #expect(reports[0].uploaded == ["layers/a.bin", "layers/b.bin", "thumbnail.png", "manifest.json"])
        #expect(world.remote("Art.paper") == v1)
    }

    @Test func deltaUploadSendsOnlyChangedFilesAndTheManifestLast() async throws {
        let world = try World()
        let a = try world.device("A")
        try Fixture.write(v1, toPackage: "Art.paper", in: a.local)
        _ = try await a.engine.syncPackage(named: "Art.paper")
        a.provider.reset()

        // The user repaints layer b; the app rewrites that buffer and the manifest.
        try Fixture.set("layer-b-v2-with-more-pixels", at: "layers/b.bin", inPackage: "Art.paper", in: a.local)
        try Fixture.set(#"{"layers":["a","b"],"rev":2}"#, at: "manifest.json", inPackage: "Art.paper", in: a.local)
        let reports = try await a.engine.syncPackage(named: "Art.paper")

        #expect(reports[0].outcome == .uploaded)
        #expect(relative(a.provider.uploads) == ["layers/b.bin", "manifest.json"])
        #expect(a.provider.downloads.isEmpty)
        #expect(a.provider.deletes.isEmpty)
        #expect(world.remote("Art.paper")["layers/b.bin"] == "layer-b-v2-with-more-pixels")
        #expect(world.remote("Art.paper")["layers/a.bin"] == "layer-a-v1")

        // Nothing changed -> nothing travels.
        a.provider.reset()
        let idle = try await a.engine.syncPackage(named: "Art.paper")
        #expect(idle[0].outcome == .upToDate)
        #expect(a.provider.uploads.isEmpty && a.provider.downloads.isEmpty)
    }

    @Test func manifestIsCommittedLastEvenWhenOnlyABufferChanged() async throws {
        let world = try World()
        let a = try world.device("A")
        try Fixture.write(v1, toPackage: "Art.paper", in: a.local)
        _ = try await a.engine.syncPackage(named: "Art.paper")
        a.provider.reset()

        try Fixture.set("layer-a-v2!", at: "layers/a.bin", inPackage: "Art.paper", in: a.local) // manifest untouched
        _ = try await a.engine.syncPackage(named: "Art.paper")
        #expect(relative(a.provider.uploads) == ["layers/a.bin", "manifest.json"])
    }

    @Test func removedFilesAreDeletedRemotelyAfterTheManifestCommit() async throws {
        let world = try World()
        let a = try world.device("A")
        try Fixture.write(v1, toPackage: "Art.paper", in: a.local)
        _ = try await a.engine.syncPackage(named: "Art.paper")
        a.provider.reset()

        try Fixture.remove("layers/b.bin", inPackage: "Art.paper", in: a.local)
        try Fixture.set(#"{"layers":["a"],"rev":2}"#, at: "manifest.json", inPackage: "Art.paper", in: a.local)
        let reports = try await a.engine.syncPackage(named: "Art.paper")

        #expect(reports[0].deletedRemote == ["layers/b.bin"])
        // order of calls: the commit (manifest upload) comes before the delete
        let calls = a.provider.calls.filter { if case .createFolder = $0 { return false } else { return true } }
        #expect(calls == [.upload("/Paper/Art.paper/manifest.json"), .delete("/Paper/Art.paper/layers/b.bin")])
        #expect(world.remote("Art.paper")["layers/b.bin"] == nil)
    }

    @Test func bookkeepingSurvivesARestart() async throws {
        let world = try World()
        let a = try world.device("A")
        try Fixture.write(v1, toPackage: "Art.paper", in: a.local)
        _ = try await a.engine.syncPackage(named: "Art.paper")

        let restarted = try world.relaunch(a)
        restarted.provider.reset()
        let reports = try await restarted.engine.syncAll()
        #expect(reports.reports.allSatisfy { $0.outcome == .upToDate })
        #expect(restarted.provider.uploads.isEmpty && restarted.provider.downloads.isEmpty)
    }

    // MARK: Pull

    @Test func secondDevicePullsANewProject() async throws {
        let world = try World()
        let a = try world.device("A"), b = try world.device("B")
        try Fixture.write(v1, toPackage: "Art.paper", in: a.local)
        _ = try await a.engine.syncAll()

        let run = try await b.engine.syncAll()
        #expect(run.failures.isEmpty)
        #expect(run.reports.map(\.outcome) == [.downloaded])
        #expect(Fixture.snapshot(package: "Art.paper", in: b.local) == v1)
        // manifest is fetched first over the network and put in place last
        #expect(relative(b.provider.downloads).first == "manifest.json")
        #expect(run.reports[0].downloaded.last == "manifest.json")
        #expect(b.log.updatedProjects.map(\.lastPathComponent) == ["Art.paper"])
        // nothing is left behind in the staging area
        #expect(!FileManager.default.fileExists(atPath: b.local.appendingPathComponent(".cloudsync-staging").path))
    }

    @Test func pullFetchesOnlyWhatChangedAndAppliesRemovals() async throws {
        let world = try World()
        let a = try world.device("A"), b = try world.device("B")
        try Fixture.write(v1, toPackage: "Art.paper", in: a.local)
        _ = try await a.engine.syncAll()
        _ = try await b.engine.syncAll()
        b.provider.reset()

        // A: change layer a, delete layer b, add layer c.
        try Fixture.set("layer-a-v2!!", at: "layers/a.bin", inPackage: "Art.paper", in: a.local)
        try Fixture.remove("layers/b.bin", inPackage: "Art.paper", in: a.local)
        try Fixture.set("layer-c", at: "layers/c.bin", inPackage: "Art.paper", in: a.local)
        try Fixture.set(#"{"layers":["a","c"],"rev":2}"#, at: "manifest.json", inPackage: "Art.paper", in: a.local)
        _ = try await a.engine.syncAll()

        let run = try await b.engine.syncAll()
        #expect(run.reports[0].outcome == .downloaded)
        #expect(Set(relative(b.provider.downloads)) == ["manifest.json", "layers/a.bin", "layers/c.bin"])
        #expect(!relative(b.provider.downloads).contains("thumbnail.png"))
        #expect(run.reports[0].deletedLocal == ["layers/b.bin"])
        #expect(Fixture.snapshot(package: "Art.paper", in: b.local) == Fixture.snapshot(package: "Art.paper", in: a.local))
    }

    @Test func aPackageWithoutManifestIsAnUnfinishedUploadAndIsNotPulled() async throws {
        let world = try World()
        let a = try world.device("A"), b = try world.device("B")
        try Fixture.write(v1, toPackage: "Art.paper", in: a.local)
        a.provider.failUploads(after: 2) // connection drops after two buffers: manifest never goes up
        await #expect(throws: CloudError.self) { _ = try await a.engine.syncPackage(named: "Art.paper") }
        #expect(world.remote("Art.paper")["manifest.json"] == nil)

        let early = try await b.engine.syncAll()
        #expect(early.reports.first?.outcome == .deferred(reason: "waiting for another device to finish uploading Art.paper"))
        #expect(Fixture.packageNames(in: b.local).isEmpty)

        a.provider.failUploads(after: nil)
        let resumed = try await a.engine.syncPackage(named: "Art.paper")
        #expect(resumed[0].outcome == .uploaded)
        // only what was missing is sent the second time, and the commit is still last
        #expect(relative(a.provider.uploads.suffix(2).map { $0 }) == ["thumbnail.png", "manifest.json"])
        #expect(a.provider.uploads.count == 4)
        #expect(Fixture.packageNames(in: world.cloud.appendingPathComponent("Paper")) == ["Art.paper"])

        _ = try await b.engine.syncAll()
        #expect(Fixture.snapshot(package: "Art.paper", in: b.local) == v1)
    }

    // MARK: Conflicts

    /// Both devices start in sync, then both edit layer a and the manifest.
    private func divergedWorld(policy: ConflictPolicy, bEditedAt: Date) async throws -> (World, Device, Device) {
        let world = try World()
        let a = try world.device("A", policy: policy), b = try world.device("B", policy: policy)
        try Fixture.write(v1, toPackage: "Art.paper", in: a.local)
        _ = try await a.engine.syncAll()
        _ = try await b.engine.syncAll()

        let now = Date()
        try Fixture.set("A-edit-of-layer-a", at: "layers/a.bin", inPackage: "Art.paper", in: a.local, modified: now)
        try Fixture.set(#"{"rev":"A"}"#, at: "manifest.json", inPackage: "Art.paper", in: a.local, modified: now)
        _ = try await a.engine.syncAll() // A reaches the cloud first

        try Fixture.set("B-edit-of-layer-a!", at: "layers/a.bin", inPackage: "Art.paper", in: b.local, modified: bEditedAt)
        try Fixture.set(#"{"rev":"B"}"#, at: "manifest.json", inPackage: "Art.paper", in: b.local, modified: bEditedAt)
        return (world, a, b)
    }

    private let siblingName = "Art (Conflicted Copy 2026-10-26 14.30.05).paper"

    @Test func concurrentEditsBranchTheOlderCopyAndLoseNothing_localIsNewer() async throws {
        let (world, a, b) = try await divergedWorld(policy: .newerWins, bEditedAt: Date().addingTimeInterval(3600))
        let run = try await b.engine.syncAll()
        #expect(run.failures.isEmpty)
        #expect(run.reports.first?.outcome == .conflict(createdCopy: siblingName))

        // B keeps the name (newer), the cloud's version became the Conflicted Copy.
        #expect(Fixture.read("manifest.json", inPackage: "Art.paper", in: b.local) == #"{"rev":"B"}"#)
        #expect(Fixture.read("layers/a.bin", inPackage: "Art.paper", in: b.local) == "B-edit-of-layer-a!")
        #expect(Fixture.read("layers/a.bin", inPackage: siblingName, in: b.local) == "A-edit-of-layer-a")
        #expect(Fixture.read("manifest.json", inPackage: siblingName, in: b.local) == #"{"rev":"A"}"#)
        #expect(b.log.conflictCopies.map(\.lastPathComponent) == [siblingName])
        // both are in the cloud
        #expect(world.remotePackages == [siblingName, "Art.paper"])
        #expect(world.remote("Art.paper")["layers/a.bin"] == "B-edit-of-layer-a!")
        #expect(world.remote(siblingName)["layers/a.bin"] == "A-edit-of-layer-a")
        // the copy that kept its name never lost its untouched files
        #expect(world.remote("Art.paper")["thumbnail.png"] == "png-v1")

        // A then receives both and nothing is lost anywhere.
        _ = try await a.engine.syncAll()
        #expect(Fixture.snapshot(package: "Art.paper", in: a.local) == world.remote("Art.paper"))
        #expect(Fixture.snapshot(package: siblingName, in: a.local) == world.remote(siblingName))

        // ...and everything settles: no further conflicts.
        let again = try await b.engine.syncAll()
        #expect(again.reports.allSatisfy { $0.outcome == .upToDate })
        #expect(b.log.conflictCopies.count == 1)
    }

    @Test func concurrentEditsBranchTheOlderCopyAndLoseNothing_remoteIsNewer() async throws {
        let (world, a, b) = try await divergedWorld(policy: .newerWins, bEditedAt: Date().addingTimeInterval(-3600))
        let run = try await b.engine.syncAll()
        #expect(run.reports.first?.outcome == .conflict(createdCopy: siblingName))

        // The cloud version (A's) keeps the name; B's work moved, untouched, into the Conflicted Copy.
        #expect(Fixture.read("layers/a.bin", inPackage: "Art.paper", in: b.local) == "A-edit-of-layer-a")
        #expect(Fixture.read("layers/a.bin", inPackage: siblingName, in: b.local) == "B-edit-of-layer-a!")
        #expect(Fixture.read("manifest.json", inPackage: siblingName, in: b.local) == #"{"rev":"B"}"#)
        #expect(world.remote("Art.paper")["layers/a.bin"] == "A-edit-of-layer-a")
        #expect(world.remote(siblingName)["layers/a.bin"] == "B-edit-of-layer-a!")
        #expect(world.remote(siblingName)["thumbnail.png"] == "png-v1")

        _ = try await a.engine.syncAll()
        #expect(Fixture.snapshot(package: siblingName, in: a.local) == world.remote(siblingName))
        #expect(Fixture.snapshot(package: "Art.paper", in: a.local)["layers/a.bin"] == "A-edit-of-layer-a")
    }

    @Test func keepLocalPolicyAlwaysKeepsThisDevicesCopyUnderTheOriginalName() async throws {
        let (world, _, b) = try await divergedWorld(policy: .keepLocal, bEditedAt: Date().addingTimeInterval(-3600))
        _ = try await b.engine.syncAll()
        #expect(world.remote("Art.paper")["layers/a.bin"] == "B-edit-of-layer-a!")
        #expect(world.remote(siblingName)["layers/a.bin"] == "A-edit-of-layer-a")
    }

    @Test func keepRemotePolicyAlwaysKeepsTheCloudCopyUnderTheOriginalName() async throws {
        let (world, _, b) = try await divergedWorld(policy: .keepRemote, bEditedAt: Date().addingTimeInterval(3600))
        _ = try await b.engine.syncAll()
        #expect(world.remote("Art.paper")["layers/a.bin"] == "A-edit-of-layer-a")
        #expect(world.remote(siblingName)["layers/a.bin"] == "B-edit-of-layer-a!")
        #expect(Fixture.read("layers/a.bin", inPackage: siblingName, in: b.local) == "B-edit-of-layer-a!")
    }

    @Test func twoConflictsInTheSameSecondGetDistinctNames() async throws {
        let (world, _, b) = try await divergedWorld(policy: .keepLocal, bEditedAt: Date())
        _ = try await b.engine.syncAll()
        // A edits again from a third device state: simulate by another diverging round on the same fixed clock.
        let c = try world.device("C", policy: .keepLocal)
        _ = try await c.engine.syncAll()
        try Fixture.set("C-edit", at: "layers/a.bin", inPackage: "Art.paper", in: c.local)
        try Fixture.set(#"{"rev":"C"}"#, at: "manifest.json", inPackage: "Art.paper", in: c.local)
        _ = try await c.engine.syncAll()
        try Fixture.set("B-edit-2-longer", at: "layers/a.bin", inPackage: "Art.paper", in: b.local)
        try Fixture.set(#"{"rev":"B2"}"#, at: "manifest.json", inPackage: "Art.paper", in: b.local)
        _ = try await b.engine.syncAll()
        #expect(world.remotePackages.contains(siblingName))
        #expect(world.remotePackages.contains("Art (Conflicted Copy 2026-10-26 14.30.05 2).paper"))
    }

    // MARK: First sync of existing copies

    @Test func identicalCopiesOnFirstSyncAreAdoptedWithoutTransfers() async throws {
        let world = try World()
        let a = try world.device("A")
        try Fixture.write(v1, toPackage: "Art.paper", in: a.local)
        try Fixture.write(v1, toPackage: "Art.paper", in: world.cloud.appendingPathComponent("Paper"))

        let reports = try await a.engine.syncPackage(named: "Art.paper")
        #expect(reports.map(\.outcome) == [.adopted])
        #expect(a.provider.uploads.isEmpty && a.provider.downloads.isEmpty)
        #expect(Fixture.packageNames(in: a.local) == ["Art.paper"])
        let state = await a.engine.recordedState(of: "Art.paper")
        #expect(Set((state?.files ?? [:]).keys) == Set(v1.keys))
    }

    @Test func differingCopiesOnFirstSyncAreNotOverwritten() async throws {
        let world = try World()
        let a = try world.device("A", policy: .keepLocal)
        try Fixture.write(v1, toPackage: "Art.paper", in: a.local)
        var cloudVersion = v1
        cloudVersion["layers/a.bin"] = "cloud-layer-a"
        try Fixture.write(cloudVersion, toPackage: "Art.paper", in: world.cloud.appendingPathComponent("Paper"))

        let reports = try await a.engine.syncPackage(named: "Art.paper")
        #expect(reports.first?.outcome == .conflict(createdCopy: siblingName))
        #expect(world.remote(siblingName)["layers/a.bin"] == "cloud-layer-a")
        #expect(world.remote("Art.paper")["layers/a.bin"] == "layer-a-v1")
    }

    // MARK: Robustness

    @Test func aWipedCacheRedownloadsAndNeverDeletesTheCloudCopy() async throws {
        let world = try World()
        let a = try world.device("A")
        try Fixture.write(v1, toPackage: "Art.paper", in: a.local)
        _ = try await a.engine.syncAll()
        a.provider.reset()

        // The OS purged the cache: folder is gone / emptied.
        try FileManager.default.removeItem(at: a.local.appendingPathComponent("Art.paper"))
        _ = try await a.engine.syncAll()
        #expect(a.provider.deletes.isEmpty)
        #expect(Fixture.snapshot(package: "Art.paper", in: a.local) == v1)

        for file in v1.keys { try FileManager.default.removeItem(at: a.local.appendingPathComponent("Art.paper").appendingPathComponent(file)) }
        _ = try await a.engine.syncAll()
        #expect(a.provider.deletes.isEmpty)
        #expect(Fixture.snapshot(package: "Art.paper", in: a.local) == v1)
        #expect(world.remote("Art.paper") == v1)
    }

    @Test func aFileChangedWhileSyncingDefersTheCommit() async throws {
        let world = try World()
        let a = try world.device("A")
        try Fixture.write(v1, toPackage: "Art.paper", in: a.local)
        // While the first buffer uploads, the user keeps painting on the second one.
        let local = a.local
        a.provider.onBeforeUpload { path in
            if path.hasSuffix("layers/a.bin") {
                try? Fixture.set("layer-b-changed-mid-sync", at: "layers/b.bin", inPackage: "Art.paper", in: local)
            }
        }
        let first = try await a.engine.syncPackage(named: "Art.paper")
        guard case .deferred = first[0].outcome else { Issue.record("expected deferred, got \(first[0].outcome)"); return }
        #expect(world.remote("Art.paper")["manifest.json"] == nil) // never committed a half-saved state

        a.provider.onBeforeUpload(nil)
        let second = try await a.engine.syncPackage(named: "Art.paper")
        #expect(second[0].outcome == .uploaded)
        #expect(world.remote("Art.paper")["layers/b.bin"] == "layer-b-changed-mid-sync")
        #expect(world.remote("Art.paper")["manifest.json"] == v1["manifest.json"])
        #expect(Fixture.packageNames(in: world.cloud.appendingPathComponent("Paper")) == ["Art.paper"])
    }

    @Test func deletingAProjectRemovesItEverywhere() async throws {
        let world = try World()
        let a = try world.device("A"), b = try world.device("B")
        try Fixture.write(v1, toPackage: "Art.paper", in: a.local)
        _ = try await a.engine.syncAll()
        _ = try await b.engine.syncAll()

        try await a.engine.deletePackage(named: "Art.paper")
        #expect(world.remotePackages.isEmpty)
        #expect(Fixture.packageNames(in: a.local).isEmpty)
        _ = try await a.engine.syncAll()
        #expect(Fixture.packageNames(in: a.local).isEmpty) // does not come back
    }

    @Test func changeDetectionIsPure() {
        let base = PackageSyncState(files: [
            "a": SyncFileState(remoteRevision: "r1", localHash: "h1", size: 1, localMTimeNanos: 1),
            "b": SyncFileState(remoteRevision: "r2", localHash: "h2", size: 1, localMTimeNanos: 1),
        ])
        let same: [String: LocalFile] = ["a": LocalFile(hash: "h1", size: 1, mtimeNanos: 9), "b": LocalFile(hash: "h2", size: 1, mtimeNanos: 9)]
        #expect(!PackageSyncEngine.localChanged(same, base: base)) // touched but same bytes
        var edited = same; edited["b"] = LocalFile(hash: "hX", size: 1, mtimeNanos: 9)
        #expect(PackageSyncEngine.localChanged(edited, base: base))
        var added = same; added["c"] = LocalFile(hash: "h3", size: 1, mtimeNanos: 9)
        #expect(PackageSyncEngine.localChanged(added, base: base))
        var removed = same; removed["a"] = nil
        #expect(PackageSyncEngine.localChanged(removed, base: base))

        func item(_ revision: String?) -> CloudItem { CloudItem(id: "x", path: "/x", kind: .file, revision: revision) }
        let unchanged = RemoteSnapshot(files: ["a": item("r1"), "b": item("r2")], folders: [])
        #expect(!PackageSyncEngine.remoteChanged(unchanged, base: base))
        #expect(PackageSyncEngine.remoteChanged(RemoteSnapshot(files: ["a": item("r1"), "b": item("r3")], folders: []), base: base))
        #expect(PackageSyncEngine.remoteChanged(RemoteSnapshot(files: ["a": item("r1")], folders: []), base: base))
        #expect(PackageSyncEngine.remoteChanged(RemoteSnapshot(files: ["a": item(nil), "b": item("r2")], folders: []), base: base))
    }

    @Test func namesFromTheCloudCannotEscapeTheCache() {
        #expect(PackageSyncEngine.isSafeName("Art.paper"))
        #expect(!PackageSyncEngine.isSafeName("../Art.paper"))
        #expect(!PackageSyncEngine.isSafeName("a/b.paper"))
        #expect(!PackageSyncEngine.isSafeName(".hidden.paper"))
        #expect(!PackageSyncEngine.isValidComponent(".."))
        #expect(PackageSyncEngine.isIgnored(relativePath: "layers/.DS_Store"))
        #expect(PackageSyncEngine.isIgnored(relativePath: "Thumbs.db"))
        #expect(!PackageSyncEngine.isIgnored(relativePath: "layers/a.bin"))
    }
}
