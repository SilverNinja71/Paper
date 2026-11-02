import Foundation
import Testing
@testable import CommonKit

extension MockedHTTP {
@Suite("Google Drive REST requests")
struct GoogleDriveProviderTests {
    private func provider(store: InMemoryTokenStore? = nil, chunk: Int = 256 * 1024, sleeps: SleepRecorder? = nil,
                          retry: HTTPRetryPolicy = .none) -> (GoogleDriveProvider, InMemoryTokenStore) {
        let tokens = store ?? TestConfig.store("oauth.googleDrive")
        let transport = MockURLProtocol.transport(retry: retry, sleeper: sleeps)
        return (GoogleDriveProvider(configuration: TestConfig.configuration, tokenStore: tokens, transport: transport, uploadChunkSize: chunk), tokens)
    }

    private let folderMime = "application/vnd.google-apps.folder"

    /// Minimal fake Drive: knows one folder "Paper" (id F1) in the root.
    private func fileJSON(id: String, name: String, size: Int? = nil, version: String = "1", md5: String? = nil,
                          mime: String = "application/octet-stream") -> [String: Any] {
        var json: [String: Any] = ["id": id, "name": name, "mimeType": mime, "version": version,
                                   "modifiedTime": "2026-10-01T12:30:00.000Z"]
        if let size { json["size"] = String(size) }
        if let md5 { json["md5Checksum"] = md5 }
        return json
    }

    @Test func listsAFolderWithPaginationAndParsesMetadata() async throws {
        MockURLProtocol.install { [self] request in
            guard request.method == "GET", request.url.path == "/drive/v3/files" else { return .json(["error": "unexpected"], status: 500) }
            let q = request.query["q"] ?? ""
            if q.contains("name = 'Paper'") { return .json(["files": [["id": "F1", "mimeType": folderMime]]]) }
            guard q.hasPrefix("'F1' in parents") else { return .json(["error": "unexpected q \(q)"], status: 500) }
            if request.query["pageToken"] == nil {
                return .json(["nextPageToken": "PAGE2", "files": [
                    fileJSON(id: "A1", name: "Art.paper", mime: folderMime),
                    fileJSON(id: "B1", name: "notes.bin", size: 42, version: "12", md5: "ABCDEF0123456789ABCDEF0123456789"),
                    fileJSON(id: "D1", name: "A Google Doc", mime: "application/vnd.google-apps.document"),
                ]])
            }
            return .json(["files": [fileJSON(id: "C1", name: "later.bin", size: 7, version: "3")]])
        }
        let (drive, _) = provider()
        let first = try await drive.listFolder("/Paper", pageToken: nil)
        #expect(first.nextPageToken == "PAGE2")
        #expect(first.items.map(\.name) == ["Art.paper", "notes.bin"]) // Google Docs are skipped
        #expect(first.items[0].kind == .folder)
        #expect(first.items[1].size == 42)
        #expect(first.items[1].revision == "12")
        #expect(first.items[1].contentHash == CloudContentHash(algorithm: .md5, value: "abcdef0123456789abcdef0123456789"))
        #expect(first.items[1].path == "/Paper/notes.bin")
        #expect(first.items[1].modified == Date(timeIntervalSince1970: 1_790_857_800))

        let all = try await drive.listAll("/Paper")
        #expect(all.map(\.name) == ["Art.paper", "notes.bin", "later.bin"])

        // every request is authorised and uses the documented endpoint
        for request in MockURLProtocol.requests {
            #expect(request.header("Authorization") == "Bearer ACCESS")
            #expect(request.method == "GET")
            #expect(request.url.host == "www.googleapis.com")
        }
        let listing = try #require(MockURLProtocol.requests.first { ($0.query["q"] ?? "").hasPrefix("'F1' in parents") })
        #expect(listing.query["q"] == "'F1' in parents and trashed = false")
        #expect(listing.query["pageSize"] == "1000")
        #expect(listing.query["fields"]?.contains("md5Checksum") == true)
        // the path "Paper" was resolved once and cached for the second listing
        #expect(MockURLProtocol.requests.filter { ($0.query["q"] ?? "").contains("name = 'Paper'") }.count == 1)
    }

    @Test func missingFolderIsNotFoundAndNamesAreEscapedInQueries() async throws {
        MockURLProtocol.install { _ in .json(["files": []]) }
        let (drive, _) = provider()
        await #expect(throws: CloudError.notFound(path: "/O'Brien")) { _ = try await drive.listFolder("/O'Brien", pageToken: nil) }
        let q = try #require(MockURLProtocol.requests.first?.query["q"])
        #expect(q == "'root' in parents and name = 'O\\'Brien' and trashed = false and mimeType = 'application/vnd.google-apps.folder'")
        #expect(try await drive.stat("/O'Brien") == nil)
    }

    @Test func uploadsANewFileThroughAResumableSession() async throws {
        let box = try Sandbox("g-up")
        let source = try box.file("a.bin", "pixels!")
        MockURLProtocol.install { [self] request in
            if request.method == "GET", request.url.path == "/drive/v3/files" {
                let q = request.query["q"] ?? ""
                if q.contains("name = 'Paper'") { return .json(["files": [["id": "F1", "mimeType": folderMime]]]) }
                return .json(["files": []]) // a.bin does not exist yet
            }
            if request.method == "POST", request.url.path == "/upload/drive/v3/files" {
                return .empty(200, headers: ["Location": "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&upload_id=U1"])
            }
            if request.method == "PUT", request.query["upload_id"] == "U1" {
                return .json(fileJSON(id: "N1", name: "a.bin", size: 7, version: "3", md5: "ff"))
            }
            return .json(["error": "unexpected \(request.signature)"], status: 500)
        }
        let (drive, _) = provider()
        let item = try await drive.upload(from: source, to: "/Paper/a.bin", precondition: .mustNotExist)
        #expect(item.revision == "3" && item.id == "N1" && item.size == 7)

        let initiate = try #require(MockURLProtocol.requests.first { $0.method == "POST" })
        #expect(initiate.query["uploadType"] == "resumable")
        #expect(initiate.header("Authorization") == "Bearer ACCESS")
        #expect(initiate.header("X-Upload-Content-Length") == "7")
        #expect(initiate.header("X-Upload-Content-Type") == "application/octet-stream")
        let metadata = try #require(initiate.bodyJSON)
        #expect(metadata["name"] as? String == "a.bin")
        #expect(metadata["parents"] as? [String] == ["F1"])

        let put = try #require(MockURLProtocol.requests.first { $0.method == "PUT" })
        #expect(put.bodyString == "pixels!")
        #expect(put.header("Authorization") == "Bearer ACCESS")
    }

    @Test func largeFilesAreSentInChunksWithContentRange() async throws {
        let box = try Sandbox("g-chunk")
        let payload = Data((0..<(600 * 1024)).map { UInt8($0 % 251) })
        let source = box.root.appendingPathComponent("big.bin")
        try payload.write(to: source)
        MockURLProtocol.install { [self] request in
            if request.method == "GET" {
                let q = request.query["q"] ?? ""
                return q.contains("name = 'Paper'") ? .json(["files": [["id": "F1", "mimeType": folderMime]]]) : .json(["files": []])
            }
            if request.method == "POST" { return .empty(200, headers: ["Location": "https://www.googleapis.com/upload/drive/v3/files?upload_id=U2"]) }
            let range = request.header("Content-Range") ?? ""
            if range.hasSuffix("-262143/614400") || range.hasPrefix("bytes 0-") { return .empty(308, headers: ["Range": "bytes=0-262143"]) }
            if range.hasPrefix("bytes 262144-") { return .empty(308, headers: ["Range": "bytes=0-524287"]) }
            return .json(fileJSON(id: "N2", name: "big.bin", size: 614400, version: "9"))
        }
        let (drive, _) = provider(chunk: 256 * 1024)
        let item = try await drive.upload(from: source, to: "/Paper/big.bin", precondition: .none)
        #expect(item.revision == "9")
        let puts = MockURLProtocol.requests.filter { $0.method == "PUT" }
        #expect(puts.map { $0.header("Content-Range") } == ["bytes 0-262143/614400", "bytes 262144-524287/614400", "bytes 524288-614399/614400"])
        #expect(puts.map(\.body.count) == [262144, 262144, 90112])
        #expect(puts.reduce(Data()) { $0 + $1.body } == payload)
    }

    @Test func updatesAnExistingFileOnlyIfTheRevisionStillMatches() async throws {
        let box = try Sandbox("g-update")
        let source = try box.file("a.bin", "new-bytes")
        MockURLProtocol.install { [self] request in
            if request.method == "GET", request.url.path == "/drive/v3/files" {
                let q = request.query["q"] ?? ""
                if q.contains("name = 'Paper'") { return .json(["files": [["id": "F1", "mimeType": folderMime]]]) }
                return .json(["files": [["id": "X1", "mimeType": "application/octet-stream"]]])
            }
            if request.method == "GET", request.url.path == "/drive/v3/files/X1" {
                return .json(fileJSON(id: "X1", name: "a.bin", size: 3, version: "5"))
            }
            if request.method == "PATCH", request.url.path == "/upload/drive/v3/files/X1" {
                return .empty(200, headers: ["Location": "https://www.googleapis.com/upload/drive/v3/files/X1?upload_id=U3"])
            }
            if request.method == "PUT" { return .json(fileJSON(id: "X1", name: "a.bin", size: 9, version: "6")) }
            return .json(["error": "unexpected \(request.signature)"], status: 500)
        }
        let (drive, _) = provider()
        await #expect(throws: CloudError.revisionMismatch(path: "/Paper/a.bin")) {
            _ = try await drive.upload(from: source, to: "/Paper/a.bin", precondition: .revision("4"))
        }
        #expect(!MockURLProtocol.requests.contains { $0.method == "PATCH" || $0.method == "PUT" })
        await #expect(throws: CloudError.revisionMismatch(path: "/Paper/a.bin")) {
            _ = try await drive.upload(from: source, to: "/Paper/a.bin", precondition: .mustNotExist)
        }
        let item = try await drive.upload(from: source, to: "/Paper/a.bin", precondition: .revision("5"))
        #expect(item.revision == "6")
        #expect(MockURLProtocol.requests.contains { $0.method == "PATCH" && $0.body == Data("{}".utf8) })
    }

    @Test func downloadsBytesAfterReadingMetadata() async throws {
        let box = try Sandbox("g-down")
        MockURLProtocol.install { [self] request in
            if request.url.path == "/drive/v3/files", request.method == "GET" {
                let q = request.query["q"] ?? ""
                return q.contains("name = 'Paper'") ? .json(["files": [["id": "F1", "mimeType": folderMime]]])
                    : .json(["files": [["id": "X1", "mimeType": "application/octet-stream"]]])
            }
            if request.url.path == "/drive/v3/files/X1" {
                return request.query["alt"] == "media" ? .bytes(Data("file-bytes".utf8)) : .json(fileJSON(id: "X1", name: "a.bin", size: 10, version: "8"))
            }
            return .json(["error": "unexpected"], status: 500)
        }
        let (drive, _) = provider()
        let target = box.root.appendingPathComponent("out/a.bin")
        let item = try await drive.download("/Paper/a.bin", to: target)
        #expect(item.revision == "8")
        #expect(try String(contentsOf: target, encoding: .utf8) == "file-bytes")
        let media = try #require(MockURLProtocol.requests.last)
        #expect(media.query["alt"] == "media")
        #expect(media.header("Authorization") == "Bearer ACCESS")
    }

    @Test func createsFoldersLikeMkdirPAndTrashesInsteadOfErasing() async throws {
        MockURLProtocol.install { [self] request in
            if request.method == "GET", request.url.path == "/drive/v3/files" {
                let q = request.query["q"] ?? ""
                if q.contains("name = 'Done'") { return .json(["files": [["id": "F9", "mimeType": folderMime]]]) }
                return .json(["files": []])
            }
            if request.method == "POST", request.url.path == "/drive/v3/files" {
                let name = request.bodyJSON?["name"] as? String ?? "?"
                return .json(fileJSON(id: "id-\(name)", name: name, mime: folderMime))
            }
            if request.method == "PATCH", request.url.path == "/drive/v3/files/F9" { return .json(["id": "F9"]) }
            return .json(["error": "unexpected \(request.signature)"], status: 500)
        }
        let (drive, _) = provider()
        let folder = try await drive.createFolder("/Paper/Art.paper")
        #expect(folder.id == "id-Art.paper" && folder.kind == .folder)
        let posts = MockURLProtocol.requests.filter { $0.method == "POST" }
        #expect(posts.count == 2)
        #expect(posts[0].bodyJSON?["name"] as? String == "Paper")
        #expect(posts[0].bodyJSON?["parents"] as? [String] == ["root"])
        #expect(posts[0].bodyJSON?["mimeType"] as? String == folderMime)
        #expect(posts[1].bodyJSON?["parents"] as? [String] == ["id-Paper"])

        try await drive.delete("/Done")
        let trash = try #require(MockURLProtocol.requests.last)
        #expect(trash.method == "PATCH")
        #expect(trash.bodyJSON?["trashed"] as? Bool == true)
        await #expect(throws: CloudError.notFound(path: "/Nothing")) { try await drive.delete("/Nothing") }
    }

    // MARK: Auth

    @Test func reportsNotConfiguredWithAHintInsteadOfCrashing() async throws {
        for configuration in [CloudProviderConfiguration(), CloudProviderConfiguration.template] {
            let drive = GoogleDriveProvider(configuration: configuration, tokenStore: InMemoryTokenStore(), transport: MockURLProtocol.transport())
            guard case .notConfigured(let hint) = await drive.authState() else { Issue.record("expected notConfigured"); continue }
            #expect(hint.contains("Register") && hint.contains("console.cloud.google.com") && hint.contains("CloudKeys.plist"))
            await #expect(throws: CloudError.notConfigured(hint: hint)) { _ = try await drive.listFolder(.root, pageToken: nil) }
            await #expect(throws: CloudError.notConfigured(hint: hint)) { try await drive.signIn(using: FakeWebAuthenticator()) }
        }
    }

    @Test func signsInWithPKCEAndStoresTheTokens() async throws {
        MockURLProtocol.install { request in
            if request.url.host == "oauth2.googleapis.com" {
                return .json(["access_token": "AT-1", "refresh_token": "RT-1", "expires_in": 3599, "token_type": "Bearer"])
            }
            if request.url.path == "/drive/v3/about" { return .json(["user": ["emailAddress": "artist@example.com"]]) }
            return .json(["error": "unexpected"], status: 500)
        }
        let store = InMemoryTokenStore()
        let (drive, _) = provider(store: store)
        #expect(await drive.authState() == .signedOut)

        let browser = FakeWebAuthenticator()
        try await drive.signIn(using: browser)

        let authURL = try #require(browser.lastURL)
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: authURL, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(authURL.host == "accounts.google.com")
        #expect(items["client_id"] == TestConfig.google)
        #expect(items["redirect_uri"] == "com.googleusercontent.apps.123456-abcdef:/oauth2redirect")
        #expect(browser.lastScheme == "com.googleusercontent.apps.123456-abcdef")
        #expect(items["scope"] == "https://www.googleapis.com/auth/drive.file")
        #expect(items["access_type"] == "offline")
        #expect(items["code_challenge_method"] == "S256")

        let exchange = try #require(MockURLProtocol.requests.first { $0.url.host == "oauth2.googleapis.com" })
        #expect(exchange.method == "POST")
        #expect(exchange.form["grant_type"] == "authorization_code")
        #expect(exchange.form["code"] == "AUTHCODE")
        #expect(exchange.form["client_id"] == TestConfig.google)
        #expect(exchange.form["redirect_uri"] == items["redirect_uri"])
        #expect(exchange.form["client_secret"] == nil)
        // the verifier sent to the token endpoint is the one behind the challenge shown to the browser
        #expect(PKCE.challenge(forVerifier: try #require(exchange.form["code_verifier"])) == items["code_challenge"])

        #expect(try store.loadTokens(for: "oauth.googleDrive")?.refreshToken == "RT-1")
        #expect(await drive.authState() == .signedIn(account: "artist@example.com"))

        try await drive.signOut()
        #expect(await drive.authState() == .signedOut)
        #expect(try store.loadTokens(for: "oauth.googleDrive") == nil)
    }

    @Test func rejectsForgedOrDeniedSignInResponses() async throws {
        MockURLProtocol.install { _ in .json(["access_token": "never"]) }
        let (drive, store) = provider(store: InMemoryTokenStore())
        await #expect(throws: CloudError.stateMismatch) { try await drive.signIn(using: FakeWebAuthenticator(.wrongState)) }
        await #expect(throws: CloudError.signInCancelled) { try await drive.signIn(using: FakeWebAuthenticator(.denied)) }
        await #expect(throws: CloudError.signInCancelled) { try await drive.signIn(using: FakeWebAuthenticator(.cancelled)) }
        #expect(MockURLProtocol.requests.isEmpty) // no token request was ever made
        #expect(try store.loadTokens(for: "oauth.googleDrive") == nil)
    }

    @Test func expiredTokenIsRefreshedBeforeTheFirstApiCall() async throws {
        MockURLProtocol.install { request in
            if request.url.host == "oauth2.googleapis.com" { return .json(["access_token": "FRESH", "expires_in": 3600]) }
            return .json(["files": []])
        }
        let store = TestConfig.store("oauth.googleDrive", tokens: TestConfig.tokens(expiresIn: -60, access: "STALE", refresh: "RT"))
        let (drive, _) = provider(store: store)
        _ = try await drive.listFolder(.root, pageToken: nil)
        let requests = MockURLProtocol.requests
        #expect(requests.first?.signature == "POST https://oauth2.googleapis.com/token")
        #expect(requests.first?.form["refresh_token"] == "RT")
        #expect(requests.dropFirst().allSatisfy { $0.header("Authorization") == "Bearer FRESH" })
        #expect(try store.loadTokens(for: "oauth.googleDrive")?.accessToken == "FRESH")
    }

    @Test func a401TriggersOneRefreshAndRetry() async throws {
        MockURLProtocol.install { request in
            if request.url.host == "oauth2.googleapis.com" { return .json(["access_token": "FRESH", "expires_in": 3600]) }
            return request.header("Authorization") == "Bearer FRESH" ? .json(["files": []]) : .empty(401)
        }
        let (drive, _) = provider()
        let page = try await drive.listFolder(.root, pageToken: nil)
        #expect(page.items.isEmpty)
        #expect(MockURLProtocol.requests.map(\.signature) == [
            "GET https://www.googleapis.com/drive/v3/files",
            "POST https://oauth2.googleapis.com/token",
            "GET https://www.googleapis.com/drive/v3/files",
        ])
    }
}
}
