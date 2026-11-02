import Foundation
import Testing
@testable import CommonKit

@Suite("Folder based providers", .timeLimit(.minutes(2)))
struct LocalFolderProviderTests {
    @Test func fullRoundTrip() async throws {
        let box = try Sandbox("local")
        let provider = LocalFolderProvider(rootURL: try box.folder("remote"), displayName: "Test Drive")
        #expect(await provider.authState() == .signedIn(account: nil))

        // create folder (mkdir -p semantics, idempotent)
        let folder = try await provider.createFolder("/Projects/Art.paper/layers")
        #expect(folder.kind == .folder)
        _ = try await provider.createFolder("/Projects/Art.paper/layers")

        // upload new file
        let source = try box.file("src/layer.bin", "pixels-v1")
        let first = try await provider.upload(from: source, to: "/Projects/Art.paper/layers/layer.bin", precondition: .mustNotExist)
        #expect(first.size == 9)
        #expect(first.revision != nil)

        // list
        let listing = try await provider.listAll("/Projects/Art.paper/layers")
        #expect(listing.map(\.name) == ["layer.bin"])

        // stat includes a SHA-256
        let stat = try #require(try await provider.stat("/Projects/Art.paper/layers/layer.bin"))
        #expect(stat.contentHash?.algorithm == .sha256)
        #expect(stat.contentHash?.value == FileHashing.sha256Hex(of: Data("pixels-v1".utf8)))
        #expect(try await provider.stat("/nope") == nil)

        // download
        let target = box.root.appendingPathComponent("dl/layer.bin")
        let downloaded = try await provider.download("/Projects/Art.paper/layers/layer.bin", to: target)
        #expect(downloaded.revision == first.revision)
        #expect(try String(contentsOf: target, encoding: .utf8) == "pixels-v1")

        // optimistic concurrency
        let v2 = try box.file("src/layer2.bin", "pixels-v2-longer")
        await #expect(throws: CloudError.revisionMismatch(path: "/Projects/Art.paper/layers/layer.bin")) {
            _ = try await provider.upload(from: v2, to: "/Projects/Art.paper/layers/layer.bin", precondition: .mustNotExist)
        }
        await #expect(throws: CloudError.revisionMismatch(path: "/Projects/Art.paper/layers/layer.bin")) {
            _ = try await provider.upload(from: v2, to: "/Projects/Art.paper/layers/layer.bin", precondition: .revision("stale"))
        }
        let second = try await provider.upload(from: v2, to: "/Projects/Art.paper/layers/layer.bin", precondition: .revision(try #require(first.revision)))
        #expect(second.revision != first.revision)
        #expect(second.size == 16)

        // a stale revision is now refused
        await #expect(throws: CloudError.revisionMismatch(path: "/Projects/Art.paper/layers/layer.bin")) {
            _ = try await provider.upload(from: v2, to: "/Projects/Art.paper/layers/layer.bin", precondition: .revision(try #require(first.revision)))
        }

        // delete
        try await provider.delete("/Projects/Art.paper/layers/layer.bin")
        #expect(try await provider.stat("/Projects/Art.paper/layers/layer.bin") == nil)
        await #expect(throws: CloudError.notFound(path: "/Projects/Art.paper/layers/layer.bin")) {
            try await provider.delete("/Projects/Art.paper/layers/layer.bin")
        }
        // no temp files left behind
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: box.root.appendingPathComponent("remote/Projects/Art.paper/layers").path)
        #expect(leftovers.isEmpty)
    }

    @Test func listingIsPaginated() async throws {
        let box = try Sandbox("pages")
        let provider = LocalFolderProvider(rootURL: try box.folder("remote"), pageSize: 2)
        for index in 1...5 {
            _ = try await provider.upload(from: try box.file("src/f\(index).bin", "x\(index)"), to: CloudPath("/dir/f\(index).bin"), precondition: .none)
        }
        let page1 = try await provider.listFolder("/dir", pageToken: nil)
        #expect(page1.items.count == 2)
        let token1 = try #require(page1.nextPageToken)
        let page2 = try await provider.listFolder("/dir", pageToken: token1)
        #expect(page2.items.count == 2)
        let token2 = try #require(page2.nextPageToken)
        let page3 = try await provider.listFolder("/dir", pageToken: token2)
        #expect(page3.items.count == 1)
        #expect(page3.nextPageToken == nil)
        #expect(try await provider.listAll("/dir").map(\.name) == ["f1.bin", "f2.bin", "f3.bin", "f4.bin", "f5.bin"])
        await #expect(throws: CloudError.notFound(path: "/missing")) { _ = try await provider.listFolder("/missing", pageToken: nil) }
    }

    @Test func pathsCannotEscapeTheRoot() async throws {
        let box = try Sandbox("escape")
        let provider = LocalFolderProvider(rootURL: try box.folder("remote"))
        let source = try box.file("src/a.txt", "secret")
        _ = try await provider.upload(from: source, to: CloudPath("/../../outside.txt"), precondition: .none)
        #expect(!FileManager.default.fileExists(atPath: box.root.appendingPathComponent("outside.txt").path))
        #expect(FileManager.default.fileExists(atPath: box.root.appendingPathComponent("remote/outside.txt").path))
        #expect(CloudPath("/a/../b/./c").string == "/a/b/c")
    }

    @Test func bookmarkRoundTripResolvesTheSameFolder() async throws {
        let box = try Sandbox("bookmark")
        let folder = try box.folder("picked")
        _ = try box.file("picked/hello.txt", "hi")
        let bookmark = try LocalFolderProvider.makeBookmark(for: folder)
        let provider = try LocalFolderProvider(bookmarkData: bookmark, displayName: "Picked")
        #expect(provider.rootURL.path == folder.resolvingSymlinksInPath().path)
        #expect(try await provider.listAll(.root).map(\.name) == ["hello.txt"])
    }

    @Test func missingFolderIsReportedAsUnavailable() async throws {
        let box = try Sandbox("gone")
        let provider = LocalFolderProvider(rootURL: box.root.appendingPathComponent("unplugged"), displayName: "Backup Drive")
        guard case .unavailable(let reason) = await provider.authState() else {
            Issue.record("expected unavailable"); return
        }
        #expect(reason.contains("Backup Drive"))
    }

    @Test func discoversFileProviderFolders() throws {
        let box = try Sandbox("discover")
        let cloud = try box.folder("CloudStorage")
        _ = try box.folder("CloudStorage/GoogleDrive-me@gmail.com/My Drive")
        _ = try box.folder("CloudStorage/GoogleDrive-me@gmail.com/Shared drives")
        _ = try box.folder("CloudStorage/OneDrive-Personal")
        _ = try box.folder("CloudStorage/Dropbox")
        _ = try box.folder("CloudStorage/.hidden")
        _ = try box.file("CloudStorage/readme.txt", "not a folder")
        let iCloud = try box.folder("CloudDocs")

        let found = FileProviderDiscovery.discover(cloudStorageDirectory: cloud, iCloudDriveDirectory: iCloud)
        let byKind = Dictionary(uniqueKeysWithValues: found.map { ($0.kind, $0) })
        #expect(found.count == 4)
        let google = try #require(byKind[.googleDriveDesktop])
        #expect(google.displayName == "Google Drive (desktop app) – me@gmail.com")
        #expect(google.url.lastPathComponent == "My Drive")
        #expect(google.accountHint == "me@gmail.com")
        #expect(byKind[.oneDriveDesktop]?.displayName == "OneDrive (desktop app) – Personal")
        #expect(byKind[.dropboxDesktop]?.displayName == "Dropbox (desktop app)")
        #expect(byKind[.iCloudDrive]?.url == iCloud)

        let missing = FileProviderDiscovery.discover(cloudStorageDirectory: box.root.appendingPathComponent("none"), iCloudDriveDirectory: nil)
        #expect(missing.isEmpty)
    }

    @Test func discoveredFolderBecomesAProvider() async throws {
        let box = try Sandbox("discover2")
        let drive = try box.folder("CloudStorage/GoogleDrive-a@b.c/My Drive")
        let found = FileProviderDiscovery.discover(cloudStorageDirectory: box.root.appendingPathComponent("CloudStorage"), iCloudDriveDirectory: nil)
        let provider = LocalFolderProvider(discovered: try #require(found.first))
        #expect(provider.rootURL == drive.resolvingSymlinksInPath())
        #expect(provider.displayName.contains("Google Drive"))
        #expect(await provider.authState().isReady)
    }
}

@Suite("iCloud Drive provider")
struct ICloudDriveProviderTests {
    @Test func usesTheUbiquityContainerWhenAvailable() async throws {
        let box = try Sandbox("icloud-container")
        let container = try box.folder("container")
        let provider = ICloudDriveProvider(fallbackRoot: nil, containerResolver: { _ in container }, identityTokenAvailable: { true })
        #expect(await provider.authState().isReady)
        let root = try #require(await provider.resolvedRootURL())
        #expect(root.lastPathComponent == "Documents")
        _ = try await provider.upload(from: try box.file("a.txt", "hello"), to: "/Paper/a.txt", precondition: .none)
        #expect(FileManager.default.fileExists(atPath: container.appendingPathComponent("Documents/Paper/a.txt").path))
        #expect(try await provider.listAll("/Paper").map(\.name) == ["a.txt"])
    }

    @Test func fallsBackToTheICloudDriveFolderOnTheMac() async throws {
        let box = try Sandbox("icloud-fallback")
        let cloudDocs = try box.folder("com~apple~CloudDocs")
        let provider = ICloudDriveProvider(fallbackRoot: cloudDocs, containerResolver: { _ in nil }, identityTokenAvailable: { false })
        #expect(await provider.authState().isReady)
        #expect(await provider.resolvedRootURL() == cloudDocs.resolvingSymlinksInPath())
        _ = try await provider.upload(from: try box.file("b.txt", "x"), to: "/b.txt", precondition: .none)
        #expect(FileManager.default.fileExists(atPath: cloudDocs.appendingPathComponent("b.txt").path))
    }

    @Test func reportsUnavailableWithAHintWhenNothingIsThere() async throws {
        let box = try Sandbox("icloud-none")
        let provider = ICloudDriveProvider(fallbackRoot: box.root.appendingPathComponent("missing"),
                                           containerResolver: { _ in nil }, identityTokenAvailable: { false })
        guard case .unavailable(let reason) = await provider.authState() else { Issue.record("expected unavailable"); return }
        #expect(reason.contains("iCloud"))
        await #expect(throws: CloudError.self) { _ = try await provider.listFolder(.root, pageToken: nil) }
    }

    @Test func evictedPlaceholdersAppearUnderTheirRealName() async throws {
        let box = try Sandbox("icloud-placeholder")
        let cloudDocs = try box.folder("CloudDocs")
        // Old-style evicted file: ".name.icloud" containing a small property list.
        let plist: [String: Any] = ["NSURLNameKey": "big.bin", "NSURLFileSizeKey": 4096]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try data.write(to: cloudDocs.appendingPathComponent(".big.bin.icloud"))
        _ = try box.file("CloudDocs/normal.bin", "n")
        let provider = ICloudDriveProvider(fallbackRoot: cloudDocs, containerResolver: { _ in nil }, identityTokenAvailable: { false })
        let items = try await provider.listAll(.root)
        #expect(items.map(\.name) == ["big.bin", "normal.bin"])
        #expect(items.first?.size == 4096)
        #expect(items.first?.revision == nil) // not downloaded yet: revision unknown
    }
}
