import Foundation
import Testing
@testable import CommonKit

@Suite("Configuration, bookkeeping and small types")
struct ConfigurationAndStateTests {
    @Test func placeholdersAndEmptyValuesCountAsNotConfigured() {
        typealias Entry = CloudProviderConfiguration.Entry
        #expect(!Entry().isConfigured)
        #expect(!Entry(clientID: "").isConfigured)
        #expect(!Entry(clientID: "   ").isConfigured)
        #expect(!Entry(clientID: "YOUR_GOOGLE_CLIENT_ID").isConfigured)
        #expect(!Entry(clientID: "<client id>").isConfigured)
        #expect(Entry(clientID: "1234-abc.apps.googleusercontent.com").isConfigured)
    }

    @Test func everyRestProviderReportsNotConfiguredWithoutCrashing() async {
        let store = InMemoryTokenStore()
        let providers: [any CloudStorageProvider] = [
            GoogleDriveProvider(configuration: .template, tokenStore: store),
            DropboxProvider(configuration: .template, tokenStore: store),
            OneDriveProvider(configuration: .template, tokenStore: store),
            GoogleDriveProvider(configuration: CloudProviderConfiguration(), tokenStore: store),
        ]
        for provider in providers {
            guard case .notConfigured(let hint) = await provider.authState() else { Issue.record("\(provider.id) should be notConfigured"); continue }
            #expect(hint.hasPrefix(provider.displayName))
            #expect(hint.contains("Register") && hint.contains("CloudKeys.plist"))
            await #expect(throws: CloudError.notConfigured(hint: hint)) { _ = try await provider.stat("/x") }
        }
    }

    @Test func configurationRoundTripsThroughACloudKeysPlist() throws {
        let box = try Sandbox("plist")
        let url = box.root.appendingPathComponent("Support/CloudKeys.plist")
        let configuration = CloudProviderConfiguration(
            googleDrive: .init(clientID: "g.apps.googleusercontent.com", clientSecret: "s", redirectURI: "com.x:/r", scopes: ["a", "b"]),
            dropbox: .init(clientID: "dbx"), oneDrive: .init(clientID: "ms", tenant: "consumers"))
        try configuration.write(to: url)
        #expect(try CloudProviderConfiguration.load(from: url) == configuration)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("<key>googleDrive</key>") && text.contains("<key>clientID</key>"))
    }

    @Test func missingOrBrokenKeyFilesGiveAnEmptyConfigurationNotAnError() throws {
        let box = try Sandbox("plist-missing")
        let configuration = CloudProviderConfiguration.loadDefault(appFolderName: "DoesNotExist-\(UUID().uuidString)", bundle: Bundle(for: Sandbox.self))
        #expect(configuration == CloudProviderConfiguration())
        let broken = try box.file("CloudKeys.plist", "this is not a plist")
        #expect(throws: (any Error).self) { try CloudProviderConfiguration.load(from: broken) }
    }

    @Test func standardCatalogHasTheFourCloudProviders() {
        let providers = CloudProviderCatalog.standardProviders(configuration: .template, tokenStore: InMemoryTokenStore())
        #expect(providers.map(\.id) == [.googleDrive, .dropbox, .oneDrive, .iCloudDrive])
        #expect(providers.map(\.displayName) == ["Google Drive", "Dropbox", "OneDrive", "iCloud Drive"])
    }

    @Test func syncStateIsStoredAtomicallyAndCorruptionIsSetAside() throws {
        let box = try Sandbox("state")
        let store = FileSyncStateStore(directory: box.root.appendingPathComponent("state"))
        let id = UUID()
        #expect(try store.load(folderID: id) == SyncFolderState())
        var state = SyncFolderState()
        state.packages["Art.paper"] = PackageSyncState(files: [
            "manifest.json": SyncFileState(remoteRevision: "r1", localHash: "abc", size: 12, localMTimeNanos: 99,
                                           remoteModified: Date(timeIntervalSince1970: 1_700_000_000)),
        ], lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_100))
        try store.save(state, folderID: id)
        #expect(try store.load(folderID: id) == state)

        // corrupt it
        let file = box.root.appendingPathComponent("state/\(id.uuidString).syncstate.json")
        try Data("{ broken".utf8).write(to: file)
        #expect(try store.load(folderID: id) == SyncFolderState())
        #expect(!FileManager.default.fileExists(atPath: file.path)) // moved aside, not trusted
        try store.save(state, folderID: id)
        try store.remove(folderID: id)
        #expect(try store.load(folderID: id) == SyncFolderState())
    }

    @Test func syncFolderConfigIsCodable() throws {
        let config = SyncFolderConfig(name: "Projects", providerID: .dropbox, localFolderPath: "/tmp/p",
                                      localFolderBookmark: Data([1, 2, 3]), remoteFolder: "/Apps/Paper")
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(SyncFolderConfig.self, from: data) == config)
    }

    @Test func cloudPathBehaves() {
        #expect(CloudPath("a/b").string == "/a/b")
        #expect(CloudPath("/a//b/").string == "/a/b")
        #expect(CloudPath.root.string == "/" && CloudPath.root.isRoot)
        #expect(CloudPath("/a/b").parent == "/a")
        #expect(CloudPath("/a").parent == .root)
        #expect(CloudPath.root.parent == nil)
        #expect(CloudPath("/a/b").name == "b")
        #expect(CloudPath("/a").appending("b/c") == "/a/b/c")
        #expect(CloudPath("/a/b/c").prefixes == ["/a", "/a/b", "/a/b/c"])
        #expect(CloudPath("/a/b/c").relativePath(from: "/a") == "b/c")
        #expect(CloudPath("/a").relativePath(from: "/a") == nil)
        #expect(CloudPath("/ab/c").isDescendant(of: "/a") == false)
    }

    @Test func errorsKnowWhetherRetryingCanHelp() {
        #expect(CloudError.network("x").isTransient)
        #expect(CloudError.rateLimited(retryAfter: 3).isTransient)
        #expect(CloudError.http(status: 503, message: "").isTransient)
        #expect(CloudError.http(status: 429, message: "").isTransient)
        #expect(!CloudError.http(status: 400, message: "").isTransient)
        #expect(!CloudError.notSignedIn(provider: "x").isTransient)
        #expect(!CloudError.notConfigured(hint: "x").isTransient)
        #expect(CloudError.rateLimited(retryAfter: 3).retryAfter == 3)
        #expect(CloudError.notFound(path: "/x").errorDescription == "Not found: /x")
    }

    @Test func contentHashesCompareAgainstLocalFiles() throws {
        let box = try Sandbox("hash")
        let file = try box.file("f.bin", "hello world")
        let sha = try FileHashing.sha256Hex(ofFileAt: file)
        #expect(sha == "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")
        #expect(try CloudContentHash(algorithm: .sha256, value: sha.uppercased()).matches(fileAt: file, sha256Hex: sha))
        #expect(try CloudContentHash(algorithm: .md5, value: "5eb63bbbe01eeed093cb22bb8f5acdc3").matches(fileAt: file, sha256Hex: sha))
        #expect(try CloudContentHash(algorithm: .sha1, value: "2aae6c35c94fcfb415dbe95f408b9ce91ee846ed").matches(fileAt: file, sha256Hex: sha))
        #expect(try !CloudContentHash(algorithm: .md5, value: "00").matches(fileAt: file, sha256Hex: sha))
        // Dropbox hash of a file shorter than one block = SHA-256 of the SHA-256 of the content
        let expected = FileHashing.hex(FileHashing.sha256Digest(of: Data(hex: sha)))
        #expect(try FileHashing.dropboxContentHashHex(ofFileAt: file) == expected)
    }
}

private extension FileHashing {
    static func sha256Digest(of data: Data) -> [UInt8] {
        Array(Data(hexString: sha256Hex(of: data)) ?? Data())
    }
}

private extension Data {
    init(hex: String) { self = Data(hexString: hex) ?? Data() }
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var data = Data()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
