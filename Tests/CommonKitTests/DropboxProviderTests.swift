import Foundation
import Testing
@testable import CommonKit

extension MockedHTTP {
    @Suite("Dropbox REST requests")
    struct DropboxProviderTests {
        private func provider(store: InMemoryTokenStore? = nil, simpleLimit: Int64 = 100 * 1024 * 1024, chunk: Int = 1024,
                              sleeps: SleepRecorder? = nil, retry: HTTPRetryPolicy = .none) -> (DropboxProvider, InMemoryTokenStore) {
            let tokens = store ?? TestConfig.store("oauth.dropbox")
            let transport = MockURLProtocol.transport(retry: retry, sleeper: sleeps)
            return (DropboxProvider(configuration: TestConfig.configuration, tokenStore: tokens, transport: transport,
                                    simpleUploadLimit: simpleLimit, chunkSize: chunk), tokens)
        }

        private func fileMeta(_ name: String, path: String, rev: String, size: Int = 10) -> [String: Any] {
            [".tag": "file", "name": name, "path_lower": path.lowercased(), "path_display": path, "id": "id:\(name)",
             "rev": rev, "size": size, "server_modified": "2026-10-01T12:30:00Z", "content_hash": "ABCD1234"]
        }

        @Test func listsWithCursorPagination() async throws {
            MockURLProtocol.install { [self] request in
                switch request.url.path {
                case "/2/files/list_folder":
                    return .json(["entries": [
                        [".tag": "folder", "name": "Art.paper", "id": "id:f1", "path_lower": "/paper/art.paper"],
                        fileMeta("a.bin", path: "/Paper/a.bin", rev: "0123abc"),
                        [".tag": "deleted", "name": "gone.bin"],
                    ], "cursor": "CURSOR1", "has_more": true])
                case "/2/files/list_folder/continue":
                    return .json(["entries": [fileMeta("b.bin", path: "/Paper/b.bin", rev: "ffff", size: 3)], "cursor": "CURSOR2", "has_more": false])
                default:
                    return .json(["error_summary": "unexpected"], status: 500)
                }
            }
            let (dropbox, _) = provider()
            let page = try await dropbox.listFolder("/Paper", pageToken: nil)
            #expect(page.nextPageToken == "CURSOR1")
            #expect(page.items.map(\.name) == ["Art.paper", "a.bin"]) // "deleted" entries are dropped
            #expect(page.items[1].revision == "0123abc")
            #expect(page.items[1].size == 10)
            #expect(page.items[1].contentHash == CloudContentHash(algorithm: .dropbox, value: "abcd1234"))
            #expect(page.items[1].path == "/Paper/a.bin")
            #expect(page.items[1].modified == Date(timeIntervalSince1970: 1_790_857_800))

            let all = try await dropbox.listAll("/Paper")
            #expect(all.map(\.name) == ["Art.paper", "a.bin", "b.bin"])

            let first = try #require(MockURLProtocol.requests.first)
            #expect(first.signature == "POST https://api.dropboxapi.com/2/files/list_folder")
            #expect(first.header("Authorization") == "Bearer ACCESS")
            #expect(first.header("Content-Type") == "application/json")
            #expect(first.bodyJSON?["path"] as? String == "/Paper")
            #expect(first.bodyJSON?["recursive"] as? Bool == false)
            let cont = try #require(MockURLProtocol.requests.first { $0.url.path.hasSuffix("/continue") })
            #expect(cont.bodyJSON?["cursor"] as? String == "CURSOR1")
        }

        @Test func theRootIsAnEmptyPathAndMissingFoldersAreNotFound() async throws {
            MockURLProtocol.install { request in
                if request.bodyJSON?["path"] as? String == "/Nope" {
                    return .json(["error_summary": "path/not_found/..", "error": [".tag": "path"]], status: 409)
                }
                return .json(["entries": [], "cursor": "c", "has_more": false])
            }
            let (dropbox, _) = provider()
            _ = try await dropbox.listFolder(.root, pageToken: nil)
            #expect(MockURLProtocol.requests.first?.bodyJSON?["path"] as? String == "")
            await #expect(throws: CloudError.notFound(path: "/Nope")) { _ = try await dropbox.listFolder("/Nope", pageToken: nil) }
        }

        @Test func uploadUsesUpdateModeWithTheKnownRevision() async throws {
            let box = try Sandbox("d-up")
            let source = try box.file("a.bin", "hello bytes")
            MockURLProtocol.install { [self] _ in .json(fileMeta("a.bin", path: "/Paper/a.bin", rev: "newrev", size: 11)) }
            let (dropbox, _) = provider()
            let item = try await dropbox.upload(from: source, to: "/Paper/a.bin", precondition: .revision("oldrev"))
            #expect(item.revision == "newrev")

            let request = try #require(MockURLProtocol.requests.first)
            #expect(request.signature == "POST https://content.dropboxapi.com/2/files/upload")
            #expect(request.header("Authorization") == "Bearer ACCESS")
            #expect(request.header("Content-Type") == "application/octet-stream")
            #expect(request.bodyString == "hello bytes")
            let argument = try #require(request.dropboxArg)
            #expect(argument["path"] as? String == "/Paper/a.bin")
            #expect((argument["mode"] as? [String: Any])?[".tag"] as? String == "update")
            #expect((argument["mode"] as? [String: Any])?["update"] as? String == "oldrev")
            #expect(argument["autorename"] as? Bool == false)
            #expect(argument["mute"] as? Bool == true)
        }

        @Test func otherPreconditionsMapToDropboxWriteModes() async throws {
            let box = try Sandbox("d-modes")
            let source = try box.file("a.bin", "x")
            MockURLProtocol.install { [self] _ in .json(fileMeta("a.bin", path: "/a.bin", rev: "r")) }
            let (dropbox, _) = provider()
            _ = try await dropbox.upload(from: source, to: "/a.bin", precondition: .none)
            _ = try await dropbox.upload(from: source, to: "/a.bin", precondition: .mustNotExist)
            let modes = MockURLProtocol.requests.compactMap { $0.dropboxArg?["mode"] as? String }
            #expect(modes == ["overwrite", "add"])
        }

        @Test func aRevisionConflictBecomesRevisionMismatch() async throws {
            let box = try Sandbox("d-conflict")
            let source = try box.file("a.bin", "x")
            MockURLProtocol.install { _ in .json(["error_summary": "path/conflict/file/.."], status: 409) }
            let (dropbox, _) = provider()
            await #expect(throws: CloudError.revisionMismatch(path: "/a.bin")) {
                _ = try await dropbox.upload(from: source, to: "/a.bin", precondition: .revision("stale"))
            }
        }

        @Test func aSilentlyRenamedUploadIsUndoneAndReportedAsConflict() async throws {
            let box = try Sandbox("d-rename")
            let source = try box.file("a.bin", "x")
            MockURLProtocol.install { [self] request in
                if request.url.path == "/2/files/delete_v2" { return .json(["metadata": [".tag": "file"]]) }
                var meta = fileMeta("a (conflicted copy).bin", path: "/a (conflicted copy).bin", rev: "r2")
                meta["path_lower"] = "/a (conflicted copy).bin"
                return .json(meta)
            }
            let (dropbox, _) = provider()
            await #expect(throws: CloudError.revisionMismatch(path: "/a.bin")) {
                _ = try await dropbox.upload(from: source, to: "/a.bin", precondition: .revision("stale"))
            }
            let cleanup = try #require(MockURLProtocol.requests.last)
            #expect(cleanup.url.path == "/2/files/delete_v2")
            #expect(cleanup.bodyJSON?["path"] as? String == "/a (conflicted copy).bin")
        }

        @Test func bigFilesUseAnUploadSessionWithCursorOffsets() async throws {
            let box = try Sandbox("d-chunk")
            let payload = Data((0..<2500).map { UInt8($0 % 241) })
            let source = box.root.appendingPathComponent("big.bin")
            try payload.write(to: source)
            MockURLProtocol.install { [self] request in
                switch request.url.path {
                case "/2/files/upload_session/start": return .json(["session_id": "SESSION-1"])
                case "/2/files/upload_session/append_v2": return .empty(200)
                case "/2/files/upload_session/finish": return .json(fileMeta("big.bin", path: "/Paper/big.bin", rev: "bigrev", size: 2500))
                default: return .json(["error_summary": "unexpected \(request.url.path)"], status: 500)
                }
            }
            let (dropbox, _) = provider(simpleLimit: 100, chunk: 1024)
            let item = try await dropbox.upload(from: source, to: "/Paper/big.bin", precondition: .mustNotExist)
            #expect(item.revision == "bigrev")

            let calls = MockURLProtocol.requests
            #expect(calls.map { $0.url.path.replacingOccurrences(of: "/2/files/upload_session/", with: "") } == ["start", "append_v2", "finish"])
            #expect(calls.map(\.body.count) == [1024, 1024, 452])
            #expect(calls.reduce(Data()) { $0 + $1.body } == payload)
            let append = try #require(calls[1].dropboxArg?["cursor"] as? [String: Any])
            #expect(append["session_id"] as? String == "SESSION-1")
            #expect((append["offset"] as? NSNumber)?.intValue == 1024)
            let finish = try #require(calls[2].dropboxArg)
            #expect(((finish["cursor"] as? [String: Any])?["offset"] as? NSNumber)?.intValue == 2048)
            let commit = try #require(finish["commit"] as? [String: Any])
            #expect(commit["path"] as? String == "/Paper/big.bin")
            #expect(commit["mode"] as? String == "add")
            for call in calls { #expect(call.header("Authorization") == "Bearer ACCESS") }
        }

        @Test func headerJSONIsPureASCII() throws {
            let header = try REST.asciiJSONHeader(["path": "/Café 🎨.paper/manifest.json"])
            #expect(header.allSatisfy { $0.isASCII })
            #expect(header == #"{"path":"/Caf\u00e9 \ud83c\udfa8.paper/manifest.json"}"#)
            let data = Data(header.utf8)
            let decoded = try JSONSerialization.jsonObject(with: data) as? [String: String]
            #expect(decoded?["path"] == "/Café 🎨.paper/manifest.json")
        }

        @Test func downloadReadsRevisionFromTheResultHeader() async throws {
            let box = try Sandbox("d-down")
            MockURLProtocol.install { [self] _ in
                let result = String(decoding: try JSONSerialization.data(withJSONObject: fileMeta("a.bin", path: "/Paper/a.bin", rev: "rev77", size: 5)), as: UTF8.self)
                return .bytes(Data("12345".utf8), headers: ["Dropbox-API-Result": result])
            }
            let (dropbox, _) = provider()
            let target = box.root.appendingPathComponent("a.bin")
            let item = try await dropbox.download("/Paper/Café.bin", to: target)
            #expect(item.revision == "rev77")
            #expect(try String(contentsOf: target, encoding: .utf8) == "12345")
            let request = try #require(MockURLProtocol.requests.first)
            #expect(request.signature == "POST https://content.dropboxapi.com/2/files/download")
            #expect(request.dropboxArg?["path"] as? String == "/Paper/Café.bin")
            #expect(request.header("Dropbox-API-Arg")?.allSatisfy { $0.isASCII } == true)
        }

        @Test func statCreateFolderAndDelete() async throws {
            MockURLProtocol.install { [self] request in
                switch request.url.path {
                case "/2/files/get_metadata":
                    if request.bodyJSON?["path"] as? String == "/missing" { return .json(["error_summary": "path/not_found/"], status: 409) }
                    return .json(fileMeta("a.bin", path: "/a.bin", rev: "r1"))
                case "/2/files/create_folder_v2":
                    if request.bodyJSON?["path"] as? String == "/exists" { return .json(["error_summary": "path/conflict/folder/.."], status: 409) }
                    return .json(["metadata": [".tag": "folder", "name": "Art.paper", "id": "id:new", "path_lower": "/paper/art.paper"]])
                case "/2/files/delete_v2":
                    if request.bodyJSON?["path"] as? String == "/missing" { return .json(["error_summary": "path_lookup/not_found/.."], status: 409) }
                    return .json(["metadata": [".tag": "file"]])
                default: return .json(["error_summary": "unexpected"], status: 500)
                }
            }
            let (dropbox, _) = provider()
            #expect(try await dropbox.stat("/a.bin")?.revision == "r1")
            #expect(try await dropbox.stat("/missing") == nil)
            let folder = try await dropbox.createFolder("/Paper/Art.paper")
            #expect(folder.kind == .folder)
            #expect(MockURLProtocol.requests.last?.bodyJSON?["autorename"] as? Bool == false)
            try await dropbox.delete("/a.bin")
            await #expect(throws: CloudError.notFound(path: "/missing")) { try await dropbox.delete("/missing") }
        }

        @Test func rateLimitingBacksOffAndHonoursRetryAfter() async throws {
            let attempts = Counter()
            MockURLProtocol.install { _ in
                attempts.increment() == 1
                    ? .json(["error_summary": "too_many_requests/.."], status: 429, headers: ["Retry-After": "5"])
                    : .json(["entries": [], "cursor": "c", "has_more": false])
            }
            let sleeps = SleepRecorder()
            let (dropbox, _) = provider(sleeps: sleeps, retry: HTTPRetryPolicy(maxAttempts: 3, baseDelay: 1, maxDelay: 60, maxRetryAfter: 120, jitterFraction: 0))
            _ = try await dropbox.listFolder("/x", pageToken: nil)
            #expect(sleeps.durations == [5])
        }

        // MARK: Auth

        @Test func reportsNotConfigured() async throws {
            let dropbox = DropboxProvider(configuration: CloudProviderConfiguration(), tokenStore: InMemoryTokenStore(), transport: MockURLProtocol.transport())
            guard case .notConfigured(let hint) = await dropbox.authState() else { Issue.record("expected notConfigured"); return }
            #expect(hint.contains("Register") && hint.contains("dropbox.com/developers/apps") && hint.contains("CloudKeys.plist"))
            await #expect(throws: CloudError.notConfigured(hint: hint)) { try await dropbox.createFolder("/x") }
        }

        @Test func signsInWithOfflineAccessAndPKCE() async throws {
            MockURLProtocol.install { request in
                if request.url.path == "/oauth2/token" {
                    return .json(["access_token": "sl.AT", "refresh_token": "RT-D", "expires_in": 14400, "token_type": "bearer", "account_id": "dbid:1"])
                }
                if request.url.path == "/2/users/get_current_account" { return .json(["email": "me@dropbox.example"]) }
                return .json(["error_summary": "unexpected"], status: 500)
            }
            let store = InMemoryTokenStore()
            let (dropbox, _) = provider(store: store)
            let browser = FakeWebAuthenticator()
            try await dropbox.signIn(using: browser)

            let url = try #require(browser.lastURL)
            let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            #expect(url.absoluteString.hasPrefix("https://www.dropbox.com/oauth2/authorize?"))
            #expect(items["token_access_type"] == "offline")
            #expect(items["client_id"] == "dropboxappkey")
            #expect(items["redirect_uri"] == "db-dropboxappkey://2/token")
            #expect(browser.lastScheme == "db-dropboxappkey")
            #expect(items["code_challenge_method"] == "S256")
            #expect(items["scope"] == "files.metadata.read files.metadata.write files.content.read files.content.write")

            let exchange = try #require(MockURLProtocol.requests.first)
            #expect(exchange.signature == "POST https://api.dropboxapi.com/oauth2/token")
            #expect(exchange.form["code"] == "AUTHCODE")
            #expect(PKCE.challenge(forVerifier: try #require(exchange.form["code_verifier"])) == items["code_challenge"])
            #expect(try store.loadTokens(for: "oauth.dropbox")?.refreshToken == "RT-D")
            #expect(await dropbox.authState() == .signedIn(account: "me@dropbox.example"))
        }

        @Test func refreshesWithoutAClientSecret() async throws {
            MockURLProtocol.install { request in
                request.url.path == "/oauth2/token" ? .json(["access_token": "FRESH", "expires_in": 14400]) : .json(["entries": [], "cursor": "c", "has_more": false])
            }
            let store = TestConfig.store("oauth.dropbox", tokens: TestConfig.tokens(expiresIn: -1, access: "OLD", refresh: "RT-D"))
            let (dropbox, _) = provider(store: store)
            _ = try await dropbox.listFolder("/x", pageToken: nil)
            let refresh = try #require(MockURLProtocol.requests.first)
            #expect(refresh.form["grant_type"] == "refresh_token")
            #expect(refresh.form["refresh_token"] == "RT-D")
            #expect(refresh.form["client_id"] == "dropboxappkey")
            #expect(refresh.form["client_secret"] == nil)
            #expect(MockURLProtocol.requests.last?.header("Authorization") == "Bearer FRESH")
        }
    }
}
