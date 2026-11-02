import Foundation

// MARK: - Public types

public struct PackageSyncOptions: Sendable, Equatable {
    /// Folder extensions (lower case, no dot) that count as project packages.
    public var packageExtensions: Set<String>
    public var conflictPolicy: ConflictPolicy
    public var timeZone: TimeZone
    /// The commit-point file: uploaded last, downloaded first (but moved into place last).
    public var manifestFileName: String

    public init(packageExtensions: Set<String> = ["paper", "forge"], conflictPolicy: ConflictPolicy = .newerWins,
                timeZone: TimeZone = .current, manifestFileName: String = "manifest.json") {
        self.packageExtensions = Set(packageExtensions.map { $0.lowercased() })
        self.conflictPolicy = conflictPolicy
        self.timeZone = timeZone
        self.manifestFileName = manifestFileName
    }
}

public struct PackageSyncReport: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case upToDate
        case uploaded
        case downloaded
        /// Both copies already had identical content; only the bookkeeping was updated.
        case adopted
        /// Both sides changed. The losing side now lives in the sibling package with this name.
        case conflict(createdCopy: String)
        /// Something changed while syncing (a file being saved, or the server copy); it will be retried.
        case deferred(reason: String)
    }

    public var package: String
    public var outcome: Outcome
    /// Package-relative paths in the order they were uploaded (the manifest is always last).
    public var uploaded: [String] = []
    /// Package-relative paths in the order they were put in place locally (the manifest is always last).
    public var downloaded: [String] = []
    public var deletedRemote: [String] = []
    public var deletedLocal: [String] = []

    public init(package: String, outcome: Outcome = .upToDate) {
        self.package = package
        self.outcome = outcome
    }
}

public struct PackageSyncFailure: Sendable, Equatable {
    public var package: String
    public var message: String
    public var error: CloudError?
}

public struct SyncRunReport: Sendable, Equatable {
    public var reports: [PackageSyncReport] = []
    public var failures: [PackageSyncFailure] = []
    public init() {}
}

// MARK: - Internal models

struct LocalFile: Sendable, Equatable {
    var hash: String
    var size: Int64
    var mtimeNanos: Int64
}

struct RemoteSnapshot: Sendable {
    var files: [String: CloudItem]
    var folders: Set<String>
}

// MARK: - Engine

/// Syncs one local cache folder with one remote folder, package by package and file by file.
///
/// Rules (the "atomic delta sync"):
/// - Local state is always the source the app reads and writes; the engine only mirrors it.
/// - A package counts as *changed locally* when any file's SHA-256 differs from the recorded sync base (or files
///   were added / removed), and as *changed remotely* when any file's revision differs from that base.
/// - Only changed files travel. Uploads go first, `manifest.json` last (the commit point), deletions after that.
///   Downloads fetch the manifest first, are staged in a temp folder, then moved into place one file at a time
///   with the manifest last.
/// - If both sides changed, nothing is overwritten: the losing side is branched into a
///   `<Name> (Conflicted Copy <date>).<ext>` sibling, and both packages keep syncing.
/// - Whole packages are never deleted implicitly (a wiped cache just re-downloads); use `deletePackage`.
///
/// Run one operation at a time (the manager does); concurrent calls are queued.
public actor PackageSyncEngine {
    private let folderID: UUID
    private let provider: any CloudStorageProvider
    private let localRoot: URL
    private let remoteRoot: CloudPath
    private let options: PackageSyncOptions
    private let stateStore: SyncStateStore
    private let emit: @Sendable (SyncEvent) -> Void
    private let now: @Sendable () -> Date

    private var state: SyncFolderState
    private var ensuredFolders: Set<CloudPath> = []
    private var running = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    static let stagingFolderName = ".cloudsync-staging"
    private static let ignoredNames: Set<String> = ["Thumbs.db", "desktop.ini", "Icon\r"]

    public init(folderID: UUID, provider: any CloudStorageProvider, localRoot: URL, remoteRoot: CloudPath,
                options: PackageSyncOptions = PackageSyncOptions(), stateStore: SyncStateStore,
                now: @escaping @Sendable () -> Date = { Date() },
                emit: @escaping @Sendable (SyncEvent) -> Void = { _ in }) throws {
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        self.folderID = folderID
        self.provider = provider
        self.localRoot = localRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.remoteRoot = remoteRoot
        self.options = options
        self.stateStore = stateStore
        self.now = now
        self.emit = emit
        self.state = try stateStore.load(folderID: folderID)
    }

    // MARK: Exclusive access

    private func acquire() async {
        if !running { running = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { running = false } else { waiters.removeFirst().resume() }
    }

    // MARK: Public operations

    public func syncAll() async throws -> SyncRunReport {
        await acquire()
        defer { release() }
        removeStaging()
        let remoteNames = try await remotePackageNames()
        let names = Set(localPackageNames()).union(remoteNames)

        // Forget bookkeeping for packages that exist nowhere any more.
        for key in state.packages.keys where !names.contains(key) { state.packages[key] = nil }
        try persist()

        var run = SyncRunReport()
        for name in names.sorted() {
            try Task.checkCancellation()
            do {
                run.reports += try await runPackage(name)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as CloudError {
                if case .notSignedIn = error { throw error }
                run.failures.append(PackageSyncFailure(package: name, message: error.localizedDescription, error: error))
            } catch {
                run.failures.append(PackageSyncFailure(package: name, message: error.localizedDescription, error: nil))
            }
        }
        return run
    }

    /// Two-way sync of one package (and, after a conflict, of the Conflicted Copy it created).
    public func syncPackage(named name: String) async throws -> [PackageSyncReport] {
        await acquire()
        defer { release() }
        return try await runPackage(name)
    }

    /// Deletes a project everywhere: the remote folder first, then the local package, then the bookkeeping.
    public func deletePackage(named name: String) async throws {
        await acquire()
        defer { release() }
        guard Self.isSafeName(name) else { throw CloudError.fileSystem("Invalid package name: \(name)") }
        do { try await provider.delete(remoteRoot.appending(name)) } catch CloudError.notFound {}
        let local = localRoot.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: local.path) { try FileManager.default.removeItem(at: local) }
        state.packages[name] = nil
        try persist()
    }

    /// Names of the package folders currently in the local cache.
    public func localPackageNames() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: localRoot.path)) ?? []
        return names.filter { name in
            guard !name.hasPrefix("."), isPackageName(name) else { return false }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: localRoot.appendingPathComponent(name).path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }.sorted()
    }

    public func remotePackageNames() async throws -> [String] {
        let items: [CloudItem]
        do { items = try await provider.listAll(remoteRoot) } catch CloudError.notFound { return [] }
        return items.filter { $0.kind == .folder && Self.isSafeName($0.name) && isPackageName($0.name) }.map(\.name).sorted()
    }

    /// The recorded sync base of a package (for diagnostics and tests).
    public func recordedState(of name: String) -> PackageSyncState? { state.packages[name] }

    // MARK: Names

    private func isPackageName(_ name: String) -> Bool {
        options.packageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// A single path component that can never escape its folder.
    static func isValidComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    /// A usable package folder name (valid component, not hidden).
    static func isSafeName(_ name: String) -> Bool {
        isValidComponent(name) && !name.hasPrefix(".")
    }

    static func isIgnored(relativePath: String) -> Bool {
        for part in relativePath.split(separator: "/") {
            if part.hasPrefix(".") || ignoredNames.contains(String(part)) { return true }
        }
        return false
    }

    private func remotePath(_ package: String, _ relative: String? = nil) -> CloudPath {
        let base = remoteRoot.appending(package)
        guard let relative, !relative.isEmpty else { return base }
        return base.appending(CloudPath(relative))
    }

    private func localDirectory(_ package: String) -> URL {
        localRoot.appendingPathComponent(package, isDirectory: true)
    }

    private func persist() throws {
        try stateStore.save(state, folderID: folderID)
    }

    private func progress(_ package: String, _ phase: SyncProgress.Phase, files: Int, of totalFiles: Int,
                          bytes: Int64 = 0, of totalBytes: Int64 = 0) {
        emit(.syncing(SyncProgress(folderID: folderID, package: package, phase: phase, completedFiles: files,
                                   totalFiles: totalFiles, completedBytes: bytes, totalBytes: totalBytes)))
    }

    // MARK: One package

    /// `syncPackageInternal` plus translation of "try again in a moment" conditions into a `.deferred` report.
    private func runPackage(_ name: String) async throws -> [PackageSyncReport] {
        do {
            return try await syncPackageInternal(name, depth: 0)
        } catch CloudError.localFileChanged(let file) {
            return [PackageSyncReport(package: name, outcome: .deferred(reason: "\(file) changed while syncing"))]
        } catch CloudError.revisionMismatch(let path) {
            return [PackageSyncReport(package: name, outcome: .deferred(reason: "\(path) changed on the server while syncing"))]
        }
    }

    private func syncPackageInternal(_ name: String, depth: Int) async throws -> [PackageSyncReport] {
        guard Self.isSafeName(name) else { throw CloudError.fileSystem("Invalid package name: \(name)") }
        ensuredFolders = []
        let localDir = localDirectory(name)
        let base = state.packages[name]

        progress(name, .scanning, files: 0, of: 0)
        var local = try await scanLocal(localDir, base: base)
        let remote = try await listRemote(name)

        // An existing-but-empty package folder next to a non-empty sync base means the cache was wiped, not that
        // the user deleted every file. Treat it as missing so the files come back instead of being deleted remotely.
        if let files = local, files.isEmpty, let base, !base.files.isEmpty { local = nil }

        var report = PackageSyncReport(package: name)
        switch (local, remote) {
        case (nil, nil):
            state.packages[name] = nil
            try persist()
            return [report]

        case (nil, let remote?):
            // The manifest is the commit point: a remote package without one is another device's unfinished
            // upload, so do not pull half a project. (We keep going if our own earlier upload left it that way.)
            let manifest = options.manifestFileName
            if !remote.files.isEmpty, remote.files[manifest] == nil, base == nil || base?.files[manifest] != nil {
                report.outcome = .deferred(reason: "waiting for another device to finish uploading \(name)")
                return [report]
            }
            try await pull(name, remote: remote, local: [:], base: nil, report: &report)
            return [report]

        case (let local?, nil):
            try await push(name, local: local, remote: nil, base: nil, report: &report)
            return [report]

        case let (local?, remote?):
            guard let base else {
                if try await converges(name, local: local, remote: remote) {
                    adopt(name, local: local, remote: remote)
                    try persist()
                    report.outcome = .adopted
                    return [report]
                }
                return try await resolveConflict(name, local: local, remote: remote, base: nil, depth: depth)
            }
            switch (Self.localChanged(local, base: base), Self.remoteChanged(remote, base: base)) {
            case (false, false):
                refreshLocalCache(name, local: local)
                return [report]
            case (true, false):
                try await push(name, local: local, remote: remote, base: base, report: &report)
                return [report]
            case (false, true):
                try await pull(name, remote: remote, local: local, base: base, report: &report)
                return [report]
            case (true, true):
                if try await converges(name, local: local, remote: remote) {
                    adopt(name, local: local, remote: remote)
                    try persist()
                    report.outcome = .adopted
                    return [report]
                }
                return try await resolveConflict(name, local: local, remote: remote, base: base, depth: depth)
            }
        }
    }

    // MARK: Change detection (pure)

    static func localChanged(_ local: [String: LocalFile], base: PackageSyncState) -> Bool {
        if Set(local.keys) != Set(base.files.keys) { return true }
        for (path, file) in local where base.files[path]?.localHash != file.hash { return true }
        return false
    }

    static func remoteChanged(_ remote: RemoteSnapshot, base: PackageSyncState) -> Bool {
        if Set(remote.files.keys) != Set(base.files.keys) { return true }
        for (path, item) in remote.files {
            guard let revision = item.revision, base.files[path]?.remoteRevision == revision else { return true }
        }
        return false
    }

    // MARK: Scanning

    private func scanLocal(_ directory: URL, base: PackageSyncState?) async throws -> [String: LocalFile]? {
        let cache = base?.files ?? [:]
        return try await BlockingIO.run { try Self.scanPackage(at: directory, cache: cache) }
    }

    /// Hashes every regular file below `root`. Files whose size and mtime match the cache are not re-read.
    /// Returns nil when `root` does not exist.
    ///
    /// The tree is walked by name (not with `FileManager.enumerator`) because the enumerator reports canonical
    /// paths (`/private/var/...`) that do not share a string prefix with the folder URL we were given.
    static func scanPackage(at root: URL, cache: [String: SyncFileState]) throws -> [String: LocalFile]? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }

        var result: [String: LocalFile] = [:]
        func walk(_ directory: URL, prefix: String) throws {
            for name in try fm.contentsOfDirectory(atPath: directory.path).sorted() {
                let relative = prefix.isEmpty ? name : prefix + "/" + name
                if isIgnored(relativePath: relative) { continue }
                let url = directory.appendingPathComponent(name)
                guard let before = FileFingerprint.of(url, followSymlinks: false) else { continue }
                if before.isSymlink { continue }
                if before.isDirectory { try walk(url, prefix: relative); continue }

                if let cached = cache[relative], !cached.localHash.isEmpty, cached.size == before.size,
                   cached.localMTimeNanos == before.mtimeNanos {
                    result[relative] = LocalFile(hash: cached.localHash, size: before.size, mtimeNanos: before.mtimeNanos)
                    continue
                }
                let hash = try FileHashing.sha256Hex(ofFileAt: url)
                guard let after = FileFingerprint.of(url), after.size == before.size, after.mtimeNanos == before.mtimeNanos else {
                    throw CloudError.localFileChanged(relative) // being written right now
                }
                result[relative] = LocalFile(hash: hash, size: before.size, mtimeNanos: before.mtimeNanos)
            }
        }
        try walk(root, prefix: "")
        return result
    }

    /// Lists a remote package recursively. Returns nil when the remote folder does not exist.
    private func listRemote(_ name: String) async throws -> RemoteSnapshot? {
        var files: [String: CloudItem] = [:]
        var folders = Set<String>()
        var queue: [(path: CloudPath, prefix: String)] = [(remotePath(name), "")]
        var isFirst = true
        while !queue.isEmpty {
            try Task.checkCancellation()
            let (path, prefix) = queue.removeFirst()
            let items: [CloudItem]
            do {
                items = try await provider.listAll(path)
            } catch CloudError.notFound {
                if isFirst { return nil }
                continue
            }
            isFirst = false
            for item in items {
                guard Self.isValidComponent(item.name) else { continue }
                let relative = prefix.isEmpty ? item.name : prefix + "/" + item.name
                if Self.isIgnored(relativePath: relative) { continue }
                switch item.kind {
                case .file: files[relative] = item
                case .folder:
                    folders.insert(relative)
                    queue.append((path.appending(item.name), relative))
                }
            }
        }
        return RemoteSnapshot(files: files, folders: folders)
    }

    // MARK: Staging

    private func removeStaging() {
        try? FileManager.default.removeItem(at: localRoot.appendingPathComponent(Self.stagingFolderName))
    }

    private func makeStagingDirectory() throws -> URL {
        let directory = localRoot.appendingPathComponent(Self.stagingFolderName, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func discard(_ stagingDirectory: URL) {
        try? FileManager.default.removeItem(at: stagingDirectory)
        // Remove the shared parent too when nothing else uses it.
        let parent = stagingDirectory.deletingLastPathComponent()
        if ((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []).isEmpty {
            try? FileManager.default.removeItem(at: parent)
        }
    }

    // MARK: Content comparison

    /// True when the remote file has exactly the bytes of the local file. Uses sizes and provider hashes when
    /// possible and only downloads as a last resort.
    private func sameContent(_ name: String, relative: String, remote item: CloudItem, local: LocalFile) async throws -> Bool {
        if let size = item.size, size != local.size { return false }
        let localURL = localDirectory(name).appendingPathComponent(relative)
        var hash = item.contentHash
        if hash == nil, let detailed = try? await provider.stat(remotePath(name, relative)) { hash = detailed.contentHash }
        if let hash {
            let sha = local.hash
            return try await BlockingIO.run { try hash.matches(fileAt: localURL, sha256Hex: sha) }
        }
        let staging = try makeStagingDirectory()
        defer { discard(staging) }
        let target = staging.appendingPathComponent("compare")
        _ = try await provider.download(remotePath(name, relative), to: target)
        let remoteHash = try await BlockingIO.run { try FileHashing.sha256Hex(ofFileAt: target) }
        return remoteHash == local.hash
    }

    private func converges(_ name: String, local: [String: LocalFile], remote: RemoteSnapshot) async throws -> Bool {
        guard Set(local.keys) == Set(remote.files.keys) else { return false }
        for path in local.keys.sorted() {
            guard let item = remote.files[path], let file = local[path] else { return false }
            if try await !sameContent(name, relative: path, remote: item, local: file) { return false }
        }
        return true
    }

    private func adopt(_ name: String, local: [String: LocalFile], remote: RemoteSnapshot) {
        var package = PackageSyncState(lastSyncedAt: now())
        for (path, file) in local {
            package.files[path] = SyncFileState(remoteRevision: remote.files[path]?.revision, localHash: file.hash,
                                                size: file.size, localMTimeNanos: file.mtimeNanos,
                                                remoteModified: remote.files[path]?.modified)
        }
        state.packages[name] = package
    }

    /// Keeps the "skip re-hashing" cache fresh when files were merely touched.
    private func refreshLocalCache(_ name: String, local: [String: LocalFile]) {
        guard var package = state.packages[name] else { return }
        var changed = false
        for (path, file) in local {
            guard var entry = package.files[path], entry.localHash == file.hash,
                  entry.size != file.size || entry.localMTimeNanos != file.mtimeNanos else { continue }
            entry.size = file.size
            entry.localMTimeNanos = file.mtimeNanos
            package.files[path] = entry
            changed = true
        }
        if changed {
            state.packages[name] = package
            try? persist()
        }
    }

    /// For files whose content is unchanged, remember their current size / mtime so the next scan can skip hashing.
    private static func refreshCache(_ package: inout PackageSyncState, local: [String: LocalFile]) {
        for (path, file) in local {
            guard var entry = package.files[path], entry.localHash == file.hash else { continue }
            entry.size = file.size
            entry.localMTimeNanos = file.mtimeNanos
            package.files[path] = entry
        }
    }

    // MARK: Push (local -> remote)

    private enum UploadDecision { case upload, unchanged, identical }

    private func decision(_ name: String, relative: String, local: LocalFile, remote item: CloudItem?,
                          base entry: SyncFileState?) async throws -> UploadDecision {
        guard let item else { return .upload }
        if let entry, let revision = item.revision, entry.remoteRevision == revision {
            // Server copy is what we last synced, so the local hash alone tells whether to upload.
            return entry.localHash == local.hash ? .unchanged : .upload
        }
        // First sight of this file, or the server copy moved on: maybe the bytes are already identical.
        return try await sameContent(name, relative: relative, remote: item, local: local) ? .identical : .upload
    }

    private func ensureRemoteFolder(_ path: CloudPath) async throws {
        if ensuredFolders.contains(path) { return }
        _ = try await provider.createFolder(path)
        for prefix in path.prefixes { ensuredFolders.insert(prefix) }
    }

    private func verifyUnchanged(_ relative: String, expected: LocalFile, in directory: URL) throws {
        guard let fingerprint = FileFingerprint.of(directory.appendingPathComponent(relative)),
              fingerprint.size == expected.size, fingerprint.mtimeNanos == expected.mtimeNanos else {
            throw CloudError.localFileChanged(relative)
        }
    }

    private func push(_ name: String, local: [String: LocalFile], remote: RemoteSnapshot?, base: PackageSyncState?,
                      report: inout PackageSyncReport) async throws {
        let localDir = localDirectory(name)
        let manifest = options.manifestFileName
        var package = base ?? PackageSyncState()
        var remoteFiles = remote?.files ?? [:]

        if remote != nil {
            ensuredFolders.insert(remotePath(name))
            for folder in remote?.folders ?? [] { ensuredFolders.insert(remotePath(name, folder)) }
        }

        // 1. Decide what has to travel.
        var uploads: [String] = []
        for path in local.keys.sorted() where path != manifest {
            guard let file = local[path] else { continue }
            switch try await decision(name, relative: path, local: file, remote: remoteFiles[path], base: package.files[path]) {
            case .upload:
                uploads.append(path)
            case .unchanged:
                break
            case .identical:
                if let item = remoteFiles[path] {
                    package.files[path] = SyncFileState(remoteRevision: item.revision, localHash: file.hash, size: file.size,
                                                        localMTimeNanos: file.mtimeNanos, remoteModified: item.modified)
                }
            }
        }
        var manifestNeedsUpload = false
        if let file = local[manifest] {
            switch try await decision(name, relative: manifest, local: file, remote: remoteFiles[manifest], base: package.files[manifest]) {
            case .upload: manifestNeedsUpload = true
            case .unchanged: break
            case .identical:
                if let item = remoteFiles[manifest] {
                    package.files[manifest] = SyncFileState(remoteRevision: item.revision, localHash: file.hash, size: file.size,
                                                            localMTimeNanos: file.mtimeNanos, remoteModified: item.modified)
                }
            }
        }
        // Forget files that are gone on both sides, then find those gone locally that still exist remotely.
        for path in package.files.keys where local[path] == nil && remoteFiles[path] == nil { package.files[path] = nil }
        let deletions = package.files.keys.filter { local[$0] == nil && remoteFiles[$0] != nil }.sorted()

        // The manifest is the commit: whenever anything else in the package changes, it goes up again last.
        if local[manifest] != nil && (!uploads.isEmpty || !deletions.isEmpty) { manifestNeedsUpload = true }
        let ordered = uploads + (manifestNeedsUpload ? [manifest] : [])

        guard !ordered.isEmpty || !deletions.isEmpty else {
            package.lastSyncedAt = now()
            Self.refreshCache(&package, local: local)
            state.packages[name] = package
            try persist()
            return
        }

        // 2. Make sure the remote folders exist, then upload.
        try await ensureRemoteFolder(remotePath(name))
        let totalBytes = ordered.reduce(Int64(0)) { $0 + (local[$1]?.size ?? 0) }
        var doneBytes: Int64 = 0
        for (index, path) in ordered.enumerated() {
            try Task.checkCancellation()
            guard let file = local[path] else { continue }
            progress(name, .uploading, files: index, of: ordered.count, bytes: doneBytes, of: totalBytes)
            try verifyUnchanged(path, expected: file, in: localDir)

            let parent = (path as NSString).deletingLastPathComponent
            if !parent.isEmpty { try await ensureRemoteFolder(remotePath(name, parent)) }

            let precondition: UploadPrecondition
            if let existing = remoteFiles[path] {
                precondition = existing.revision.map { .revision($0) } ?? .none
            } else {
                precondition = .mustNotExist
            }
            let item = try await provider.upload(from: localDir.appendingPathComponent(path),
                                                 to: remotePath(name, path), precondition: precondition)
            remoteFiles[path] = item
            package.files[path] = SyncFileState(remoteRevision: item.revision, localHash: file.hash, size: file.size,
                                                localMTimeNanos: file.mtimeNanos, remoteModified: item.modified ?? now())
            // Saved after every file: if we crash now, the next run sees these files as already in sync.
            state.packages[name] = package
            try persist()
            report.uploaded.append(path)
            doneBytes += file.size
        }

        // 3. Deletions come after the commit so an older manifest never points at a missing file.
        for path in deletions {
            try Task.checkCancellation()
            do { try await provider.delete(remotePath(name, path)) } catch CloudError.notFound {}
            package.files[path] = nil
            remoteFiles[path] = nil
            report.deletedRemote.append(path)
        }

        progress(name, .finishing, files: ordered.count, of: ordered.count, bytes: totalBytes, of: totalBytes)
        Self.refreshCache(&package, local: local)
        package.lastSyncedAt = now()
        state.packages[name] = package
        try persist()
        report.outcome = .uploaded
    }

    // MARK: Pull (remote -> local)

    private func pull(_ name: String, remote: RemoteSnapshot, local: [String: LocalFile], base: PackageSyncState?,
                      report: inout PackageSyncReport) async throws {
        let localDir = localDirectory(name)
        let manifest = options.manifestFileName
        var package = base ?? PackageSyncState()

        // 1. Which files differ from what we have? (manifest first)
        var downloads: [String] = []
        for path in remote.files.keys.sorted() {
            guard let item = remote.files[path] else { continue }
            if let file = local[path], let entry = package.files[path], let revision = item.revision,
               entry.remoteRevision == revision, entry.localHash == file.hash { continue }
            downloads.append(path)
        }
        downloads.sort { ($0 == manifest ? 0 : 1, $0) < ($1 == manifest ? 0 : 1, $1) }

        // 2. Download everything into a temp folder first.
        struct Staged { var path: String; var url: URL; var item: CloudItem; var hash: String; var size: Int64 }
        let staging = try makeStagingDirectory()
        defer { discard(staging) }
        let totalBytes = downloads.reduce(Int64(0)) { $0 + (remote.files[$1]?.size ?? 0) }
        var doneBytes: Int64 = 0
        var staged: [Staged] = []
        for (index, path) in downloads.enumerated() {
            try Task.checkCancellation()
            progress(name, .downloading, files: index, of: downloads.count, bytes: doneBytes, of: totalBytes)
            let destination = staging.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let received = try await provider.download(remotePath(name, path), to: destination)
            let (hash, size) = try await BlockingIO.run {
                (try FileHashing.sha256Hex(ofFileAt: destination), try REST.fileSize(of: destination))
            }
            if let expected = received.size ?? remote.files[path]?.size, expected != size {
                throw CloudError.invalidResponse("\(path) arrived incomplete (\(size) of \(expected) bytes).")
            }
            staged.append(Staged(path: path, url: destination, item: received, hash: hash, size: size))
            doneBytes += size
        }

        // 3. Move into place: everything else first, manifest last.
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        for folder in remote.folders.sorted() {
            try? FileManager.default.createDirectory(at: localDir.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let order = staged.filter { $0.path != manifest } + staged.filter { $0.path == manifest }
        for file in order {
            let destination = localDir.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.moveReplacing(file.url, to: destination)
            let listed = remote.files[file.path]
            package.files[file.path] = SyncFileState(
                remoteRevision: file.item.revision ?? listed?.revision, localHash: file.hash, size: file.size,
                localMTimeNanos: FileFingerprint.of(destination)?.mtimeNanos ?? 0,
                remoteModified: file.item.modified ?? listed?.modified)
            report.downloaded.append(file.path)
        }

        // 4. Files that no longer exist remotely are removed locally.
        for path in package.files.keys.sorted() where remote.files[path] == nil {
            let target = localDir.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
                Self.pruneEmptyDirectories(from: target.deletingLastPathComponent(), stopAt: localDir)
            }
            package.files[path] = nil
            report.deletedLocal.append(path)
        }

        // Files we did not need to download keep their revision but may have a newer mtime.
        Self.refreshCache(&package, local: local.filter { !downloads.contains($0.key) })
        package.lastSyncedAt = now()
        state.packages[name] = package
        try persist()

        report.outcome = (report.downloaded.isEmpty && report.deletedLocal.isEmpty) ? .upToDate : .downloaded
        progress(name, .finishing, files: downloads.count, of: downloads.count, bytes: doneBytes, of: totalBytes)
        if report.outcome == .downloaded { emit(.projectUpdated(localDir)) }
    }

    private static func moveReplacing(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            do { _ = try fm.replaceItemAt(destination, withItemAt: source); return }
            catch { try fm.removeItem(at: destination) }
        }
        try fm.moveItem(at: source, to: destination)
    }

    private static func pruneEmptyDirectories(from directory: URL, stopAt root: URL) {
        var current = directory
        let fm = FileManager.default
        while current.path != root.path, current.path.hasPrefix(root.path) {
            guard let contents = try? fm.contentsOfDirectory(atPath: current.path), contents.isEmpty else { return }
            try? fm.removeItem(at: current)
            current = current.deletingLastPathComponent()
        }
    }

    // MARK: Conflicts

    private func resolveConflict(_ name: String, local: [String: LocalFile], remote: RemoteSnapshot,
                                 base: PackageSyncState?, depth: Int) async throws -> [PackageSyncReport] {
        guard depth < 3 else { throw CloudError.fileSystem("Too many nested conflicts for \(name).") }
        let localDir = localDirectory(name)

        // Who is newer? Compare only the files that changed since the sync base (all files on a first sync).
        let changedLocal = local.filter { base?.files[$0.key]?.localHash != $0.value.hash }
        let localTimes = (changedLocal.isEmpty ? local : changedLocal).values
            .map { Date(timeIntervalSince1970: TimeInterval($0.mtimeNanos) / 1_000_000_000) }
        let changedRemote = remote.files.filter { base?.files[$0.key]?.remoteRevision != $0.value.revision }
        let remoteTimes = (changedRemote.isEmpty ? remote.files : changedRemote).values.compactMap(\.modified)
        let winner = ConflictResolver.winner(policy: options.conflictPolicy, localModified: localTimes.max(), remoteModified: remoteTimes.max())

        let taken = Set(localPackageNames()).union(try await remotePackageNames()).union(state.packages.keys)
        let sibling = ConflictResolver.conflictedCopyName(for: name, date: now(), existingNames: taken, timeZone: options.timeZone)
        let siblingURL = localDirectory(sibling)
        var reports: [PackageSyncReport] = []

        switch winner {
        case .remote:
            // This device's version loses: it moves, untouched, to the sibling; the server version is pulled in.
            try FileManager.default.moveItem(at: localDir, to: siblingURL)
            state.packages[name] = nil
            try persist()
            emit(.conflict(createdCopy: siblingURL))
            reports += try await syncPackageInternal(name, depth: depth + 1)
            reports += try await syncPackageInternal(sibling, depth: depth + 1)

        case .local:
            // The server version loses: save it as the sibling first, then let this device's version overwrite it.
            let reusable = local.filter { path, file in
                guard let entry = base?.files[path], let revision = remote.files[path]?.revision else { return false }
                return entry.remoteRevision == revision && entry.localHash == file.hash
            }
            try await materializeRemote(name, remote: remote, reusableLocal: Set(reusable.keys), into: siblingURL)
            var rebased = PackageSyncState()
            for (path, item) in remote.files {
                // Empty hash = "differs from whatever is local", so the next push uploads this file.
                rebased.files[path] = SyncFileState(remoteRevision: item.revision, localHash: "", size: item.size ?? 0,
                                                    localMTimeNanos: 0, remoteModified: item.modified)
            }
            state.packages[name] = rebased
            try persist()
            emit(.conflict(createdCopy: siblingURL))
            reports += try await syncPackageInternal(sibling, depth: depth + 1)
            reports += try await syncPackageInternal(name, depth: depth + 1)
        }

        reports.insert(PackageSyncReport(package: name, outcome: .conflict(createdCopy: sibling)), at: 0)
        return reports
    }

    /// Builds a complete local package from the remote files (re-using local files known to be identical).
    private func materializeRemote(_ name: String, remote: RemoteSnapshot, reusableLocal: Set<String>, into destination: URL) async throws {
        let fm = FileManager.default
        let staging = try makeStagingDirectory()
        defer { discard(staging) }
        let package = staging.appendingPathComponent("package", isDirectory: true)
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        for folder in remote.folders.sorted() {
            try fm.createDirectory(at: package.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for path in remote.files.keys.sorted() {
            try Task.checkCancellation()
            let target = package.appendingPathComponent(path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if reusableLocal.contains(path) {
                try fm.copyItem(at: localDirectory(name).appendingPathComponent(path), to: target)
            } else {
                let received = try await provider.download(remotePath(name, path), to: target)
                let size = try REST.fileSize(of: target)
                if let expected = received.size ?? remote.files[path]?.size, expected != size {
                    throw CloudError.invalidResponse("\(path) arrived incomplete (\(size) of \(expected) bytes).")
                }
            }
        }
        try fm.moveItem(at: package, to: destination)
    }
}
