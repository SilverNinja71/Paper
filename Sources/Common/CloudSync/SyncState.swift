import Foundation

// MARK: - Records

/// What we know about one file the last time local and remote were identical ("sync base").
public struct SyncFileState: Codable, Sendable, Equatable {
    /// Revision (rev / eTag / version) of the remote file at that moment. Nil = unknown.
    public var remoteRevision: String?
    /// SHA-256 (hex) of the local bytes at that moment. Empty = "treat as changed" (used after a conflict re-base).
    public var localHash: String
    public var size: Int64
    /// Local modification time (ns since 1970) at the moment `localHash` was computed. Lets the next scan skip
    /// re-hashing files whose size and mtime did not change.
    public var localMTimeNanos: Int64
    public var remoteModified: Date?

    public init(remoteRevision: String?, localHash: String, size: Int64, localMTimeNanos: Int64, remoteModified: Date? = nil) {
        self.remoteRevision = remoteRevision
        self.localHash = localHash
        self.size = size
        self.localMTimeNanos = localMTimeNanos
        self.remoteModified = remoteModified
    }
}

/// Sync base of one project package: every file's last-synced revision and hash, keyed by path inside the package.
public struct PackageSyncState: Codable, Sendable, Equatable {
    public var files: [String: SyncFileState] = [:]
    public var lastSyncedAt: Date?

    public init(files: [String: SyncFileState] = [:], lastSyncedAt: Date? = nil) {
        self.files = files
        self.lastSyncedAt = lastSyncedAt
    }
}

/// Everything remembered for one sync folder (one local cache folder <-> one remote folder).
public struct SyncFolderState: Codable, Sendable, Equatable {
    public var version: Int = 1
    public var packages: [String: PackageSyncState] = [:]

    public init(packages: [String: PackageSyncState] = [:]) { self.packages = packages }
}

// MARK: - Persistence

public protocol SyncStateStore: Sendable {
    func load(folderID: UUID) throws -> SyncFolderState
    func save(_ state: SyncFolderState, folderID: UUID) throws
    func remove(folderID: UUID) throws
}

/// Stores each sync folder's state as `<directory>/<folder id>.syncstate.json`, written atomically.
public struct FileSyncStateStore: SyncStateStore {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    private func fileURL(_ folderID: UUID) -> URL {
        directory.appendingPathComponent("\(folderID.uuidString).syncstate.json")
    }

    public func load(folderID: UUID) throws -> SyncFolderState {
        let url = fileURL(folderID)
        guard FileManager.default.fileExists(atPath: url.path) else { return SyncFolderState() }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(SyncFolderState.self, from: Data(contentsOf: url))
        } catch {
            // Unreadable state is set aside, not trusted. Without a base, the next sync compares both sides
            // file by file and creates Conflicted Copies where they differ, so nothing is lost.
            let aside = url.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: aside)
            return SyncFolderState()
        }
    }

    public func save(_ state: SyncFolderState, folderID: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: fileURL(folderID), options: .atomic)
    }

    public func remove(folderID: UUID) throws {
        let url = fileURL(folderID)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

// MARK: - Events

public struct SyncProgress: Sendable, Equatable {
    public enum Phase: String, Sendable { case scanning, downloading, uploading, finishing }

    public var folderID: UUID
    public var package: String?
    public var phase: Phase
    public var completedFiles: Int
    public var totalFiles: Int
    public var completedBytes: Int64
    public var totalBytes: Int64

    /// 0...1 (1 when there is nothing to transfer).
    public var fraction: Double {
        if totalBytes > 0 { return min(1, Double(completedBytes) / Double(totalBytes)) }
        if totalFiles > 0 { return min(1, Double(completedFiles) / Double(totalFiles)) }
        return 1
    }
}

/// Status updates published by `UniversalSyncManager.events()`.
public enum SyncEvent: Sendable, Equatable {
    /// Nothing is syncing any more.
    case idle
    case syncing(SyncProgress)
    /// Both sides had changes; the losing side was saved as this sibling package (in the local cache folder).
    case conflict(createdCopy: URL)
    /// A package in the local cache was changed by a download. Reload it if it is open.
    case projectUpdated(URL)
    case error(String)
    /// The provider needs the user to sign in (again).
    case needsSignIn(CloudProviderID)
}

/// Fan-out of events to any number of `AsyncStream` subscribers.
final class EventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<SyncEvent>.Continuation] = [:]

    func makeStream() -> AsyncStream<SyncEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[id] = nil
                self.lock.unlock()
            }
        }
    }

    func send(_ event: SyncEvent) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets { continuation.yield(event) }
    }
}
