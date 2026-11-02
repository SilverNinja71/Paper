import Foundation

// MARK: - Small helpers

/// Runs blocking file work (NSFileCoordinator, large copies, hashing) off the cooperative thread pool.
enum BlockingIO {
    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            DispatchQueue.global(qos: .utility).async {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// Size + modification time (nanoseconds) + inode of a file: a cheap, collision-resistant "version" for
/// file-system based storage. Every atomic replace creates a new inode, so even same-size, same-instant
/// rewrites get a different revision.
struct FileFingerprint: Equatable, Sendable {
    var size: Int64
    var mtimeNanos: Int64
    var inode: UInt64
    var isDirectory: Bool
    var isSymlink: Bool = false

    var revision: String { "\(size)-\(mtimeNanos)-\(inode)" }
    var modified: Date { Date(timeIntervalSince1970: TimeInterval(mtimeNanos) / 1_000_000_000) }

    /// - Parameter followSymlinks: false describes a symbolic link itself instead of what it points to.
    static func of(_ url: URL, followSymlinks: Bool = true) -> FileFingerprint? {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { pointer -> Int32 in
            guard let pointer else { return -1 }
            return followSymlinks ? stat(pointer, &info) : lstat(pointer, &info)
        }
        guard result == 0 else { return nil }
        let nanos = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return FileFingerprint(size: Int64(info.st_size), mtimeNanos: nanos, inode: UInt64(info.st_ino),
                               isDirectory: (info.st_mode & S_IFMT) == S_IFDIR,
                               isSymlink: (info.st_mode & S_IFMT) == S_IFLNK)
    }
}

/// `NSFileCoordinator` wrappers that behave like plain closures.
enum CoordinatedIO {
    static func read<T>(at url: URL, enabled: Bool, _ body: (URL) throws -> T) throws -> T {
        guard enabled else { return try body(url) }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var outcome: Result<T, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            outcome = Result { try body(readURL) }
        }
        if let outcome { return try outcome.get() }
        throw CloudError.fileSystem(coordinationError?.localizedDescription ?? "File coordination failed.")
    }

    static func write<T>(at url: URL, options: NSFileCoordinator.WritingOptions, enabled: Bool,
                         _ body: (URL) throws -> T) throws -> T {
        guard enabled else { return try body(url) }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var outcome: Result<T, Error>?
        coordinator.coordinate(writingItemAt: url, options: options, error: &coordinationError) { writeURL in
            outcome = Result { try body(writeURL) }
        }
        if let outcome { return try outcome.get() }
        throw CloudError.fileSystem(coordinationError?.localizedDescription ?? "File coordination failed.")
    }
}

// MARK: - Storage on a plain folder

/// All file operations on a folder tree. Shared by `LocalFolderProvider` (any folder, external drives,
/// File Provider folders such as ~/Library/CloudStorage/GoogleDrive-...) and `ICloudDriveProvider`.
/// Every method is synchronous and blocking; the providers call them through `BlockingIO`.
struct FileSystemStorage: Sendable {
    var root: URL
    /// Wrap reads / writes / deletes in NSFileCoordinator (right for File Provider and iCloud folders).
    var coordinated: Bool = true
    /// Understand iCloud "evicted file" placeholders and start / wait for downloads.
    var ubiquitous: Bool = false
    var pageSize: Int = 500
    var downloadTimeout: TimeInterval = 300
    var moveToTrashOnDelete: Bool = false

    static let tempPrefix = ".cloudsync-tmp-"

    private var fm: FileManager { .default }

    func url(for path: CloudPath) -> URL {
        var result = root
        for component in path.components { result.appendPathComponent(component) }
        return result
    }

    // MARK: Items

    private func makeItem(url: URL, path: CloudPath, fingerprint: FileFingerprint, includeHash: Bool) throws -> CloudItem {
        if fingerprint.isDirectory {
            return CloudItem(id: path.string, path: path, kind: .folder, modified: fingerprint.modified)
        }
        var hash: CloudContentHash?
        if includeHash {
            hash = CloudContentHash(algorithm: .sha256, value: try FileHashing.sha256Hex(ofFileAt: url))
        }
        return CloudItem(id: path.string, path: path, kind: .file, size: fingerprint.size,
                         modified: fingerprint.modified, revision: fingerprint.revision, contentHash: hash)
    }

    private func placeholderURL(for fileURL: URL) -> URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("." + fileURL.lastPathComponent + ".icloud")
    }

    private func placeholderSize(at url: URL) -> Int64? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let number = plist["NSURLFileSizeKey"] as? NSNumber else { return nil }
        return number.int64Value
    }

    // MARK: List

    func listPage(_ path: CloudPath, token: String?) throws -> CloudListPage {
        let directory = url(for: path)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CloudError.notFound(path: path.string)
        }
        var entries: [(name: String, placeholder: Bool)] = []
        for raw in try fm.contentsOfDirectory(atPath: directory.path) {
            if raw.hasPrefix(Self.tempPrefix) { continue }
            if ubiquitous, raw.hasPrefix("."), raw.hasSuffix(".icloud"), raw.count > ".x.icloud".count - 1 {
                entries.append((String(raw.dropFirst().dropLast(".icloud".count)), true))
                continue
            }
            if raw.hasPrefix(".") { continue }
            entries.append((raw, false))
        }
        entries.sort { $0.name < $1.name }

        let start = min(max(0, Int(token ?? "") ?? 0), entries.count)
        let end = min(entries.count, start + max(1, pageSize))
        var items: [CloudItem] = []
        for entry in entries[start..<end] {
            let childPath = path.appending(entry.name)
            let childURL = directory.appendingPathComponent(entry.name)
            if entry.placeholder {
                try? fm.startDownloadingUbiquitousItem(at: childURL)
                let holder = placeholderURL(for: childURL)
                items.append(CloudItem(id: childPath.string, path: childPath, kind: .file,
                                       size: placeholderSize(at: holder),
                                       modified: FileFingerprint.of(holder)?.modified))
            } else if let fingerprint = FileFingerprint.of(childURL) {
                items.append(try makeItem(url: childURL, path: childPath, fingerprint: fingerprint, includeHash: false))
            }
        }
        return CloudListPage(items: items, nextPageToken: end < entries.count ? String(end) : nil)
    }

    // MARK: Stat

    func stat(_ path: CloudPath, includeHash: Bool) throws -> CloudItem? {
        let target = url(for: path)
        if path.isRoot {
            guard let fingerprint = FileFingerprint.of(target), fingerprint.isDirectory else { return nil }
            return CloudItem(id: "/", path: .root, name: "", kind: .folder, modified: fingerprint.modified)
        }
        if ubiquitous, FileFingerprint.of(target) == nil, fm.fileExists(atPath: placeholderURL(for: target).path) {
            try ensureLocallyAvailable(target)
        }
        guard let fingerprint = FileFingerprint.of(target) else { return nil }
        if includeHash && !fingerprint.isDirectory && ubiquitous { try ensureLocallyAvailable(target) }
        return try makeItem(url: target, path: path, fingerprint: fingerprint, includeHash: includeHash)
    }

    // MARK: Download (provider -> local file)

    func download(_ path: CloudPath, to destination: URL) throws -> CloudItem {
        let source = url(for: path)
        if ubiquitous { try ensureLocallyAvailable(source) }
        return try CoordinatedIO.read(at: source, enabled: coordinated) { readURL in
            guard let fingerprint = FileFingerprint.of(readURL), !fingerprint.isDirectory else {
                throw CloudError.notFound(path: path.string)
            }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: readURL, to: destination)
            return CloudItem(id: path.string, path: path, kind: .file, size: fingerprint.size,
                             modified: fingerprint.modified, revision: fingerprint.revision)
        }
    }

    // MARK: Upload (local file -> provider)

    func upload(from source: URL, to path: CloudPath, precondition: UploadPrecondition) throws -> CloudItem {
        guard !path.isRoot else { throw CloudError.fileSystem("Cannot upload over the root folder.") }
        let destination = url(for: path)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try CoordinatedIO.write(at: destination, options: .forReplacing, enabled: coordinated) { writeURL in
            let current = FileFingerprint.of(writeURL)
            switch precondition {
            case .none:
                break
            case .mustNotExist:
                if current != nil { throw CloudError.revisionMismatch(path: path.string) }
            case .revision(let expected):
                guard let current, !current.isDirectory, current.revision == expected else {
                    throw CloudError.revisionMismatch(path: path.string)
                }
            }
            if current?.isDirectory == true { throw CloudError.fileSystem("\(path.string) is a folder.") }

            // Copy next to the destination first, then swap in with one atomic rename, so a reader (or a crash)
            // never sees half a file.
            let temporary = writeURL.deletingLastPathComponent()
                .appendingPathComponent(Self.tempPrefix + UUID().uuidString)
            do {
                try fm.copyItem(at: source, to: temporary)
                if current != nil {
                    _ = try fm.replaceItemAt(writeURL, withItemAt: temporary)
                } else {
                    try fm.moveItem(at: temporary, to: writeURL)
                }
            } catch {
                try? fm.removeItem(at: temporary)
                throw error
            }
            guard let fingerprint = FileFingerprint.of(writeURL) else {
                throw CloudError.fileSystem("The uploaded file disappeared: \(path.string)")
            }
            return try makeItem(url: writeURL, path: path, fingerprint: fingerprint, includeHash: false)
        }
    }

    // MARK: Folders and deletion

    func createFolder(_ path: CloudPath) throws -> CloudItem {
        let target = url(for: path)
        if let existing = FileFingerprint.of(target) {
            guard existing.isDirectory else { throw CloudError.fileSystem("\(path.string) already exists and is not a folder.") }
        } else {
            try CoordinatedIO.write(at: target, options: [], enabled: coordinated) { writeURL in
                try fm.createDirectory(at: writeURL, withIntermediateDirectories: true)
            }
        }
        guard let fingerprint = FileFingerprint.of(target) else {
            throw CloudError.fileSystem("Could not create \(path.string).")
        }
        return CloudItem(id: path.string, path: path, kind: .folder, modified: fingerprint.modified)
    }

    func delete(_ path: CloudPath) throws {
        guard !path.isRoot else { throw CloudError.fileSystem("Refusing to delete the root folder.") }
        let target = url(for: path)
        var exists = FileFingerprint.of(target) != nil
        if !exists, ubiquitous, fm.fileExists(atPath: placeholderURL(for: target).path) {
            try CoordinatedIO.write(at: placeholderURL(for: target), options: .forDeleting, enabled: coordinated) {
                try fm.removeItem(at: $0)
            }
            exists = true
            return
        }
        guard exists else { throw CloudError.notFound(path: path.string) }
        try CoordinatedIO.write(at: target, options: .forDeleting, enabled: coordinated) { deleteURL in
            if moveToTrashOnDelete, (try? fm.trashItem(at: deleteURL, resultingItemURL: nil)) != nil { return }
            try fm.removeItem(at: deleteURL)
        }
    }

    // MARK: iCloud availability

    /// Makes sure the bytes of `fileURL` are on this device: starts the iCloud download for evicted files
    /// (old-style `.name.icloud` placeholders and new-style dataless files) and waits for it to finish.
    func ensureLocallyAvailable(_ fileURL: URL) throws {
        let deadline = Date().addingTimeInterval(downloadTimeout)
        let holder = placeholderURL(for: fileURL)

        if FileFingerprint.of(fileURL) == nil, fm.fileExists(atPath: holder.path) {
            try? fm.startDownloadingUbiquitousItem(at: fileURL)
            while FileFingerprint.of(fileURL) == nil {
                if Date() > deadline { throw CloudError.unavailable("\(fileURL.lastPathComponent) is still downloading from iCloud. Try again in a moment.") }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }

        func status() -> URLUbiquitousItemDownloadingStatus? {
            (try? fileURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
        }
        guard status() == .notDownloaded else { return }
        try? fm.startDownloadingUbiquitousItem(at: fileURL)
        while status() == .notDownloaded {
            if Date() > deadline { throw CloudError.unavailable("\(fileURL.lastPathComponent) is still downloading from iCloud. Try again in a moment.") }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }
}
