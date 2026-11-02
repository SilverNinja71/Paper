import Foundation
import Testing
@testable import CommonKit

extension MockedHTTP {
    @Suite("OneDrive (Microsoft Graph) REST requests")
    struct OneDriveProviderTests {
        private func provider(store: InMemoryTokenStore? = nil, simpleLimit: Int64 = 4 * 1024 * 1024, chunk: Int = 320 * 1024,
                              sleeps: SleepRecorder? = nil, retry: HTTPRetryPolicy = .none) -> (OneDriveProvider, InMemoryTokenStore) {
            let tokens = store ?? TestConfig.store("oauth.oneDrive")
            let transport = MockURLProtocol.transport(retry: retry, sleeper: sleeps)
            return (OneDriveProvider(configuration: TestConfig.configuration, tokenStore: tokens, transport: transport,
                                     simpleUploadLimit: simpleLimit, chunkSize: chunk), tokens)
        }

        private func fileItem(_ name: String, etag: String, size: Int = 10, sha1: String? = nil) -> [String: Any] {
            var file: [String: Any] = ["mimeType": "application/octet-stream"]
            if let sha1 { file["hashes"] = ["sha1Hash": sha1] }
            return ["id": "ID-\(name)", "name": name, "size": size, "eTag": etag,
                    "lastModifiedDateTime": "2026-10-01T12:30:00Z", "file": file]
        }

        @Test func listsAChildrenCollectionAndFollowsNextLink() async throws {
            let nextLink = "https://graph.microsoft.com/v1.0/me/drive/root:/Paper/My%20Art.paper:/children?$skiptoken=TOKEN2"
            MockURLProtocol.install { [self] request in
                if request.url.absoluteString.contains("skiptoken=TOKEN2") {
                    return .json(["value": [fileItem("later.bin", etag: "\"{E2},1\"")]])
                }
                return .json(["value": [
                    ["id": "FOLD", "name": "layers", "folder": ["childCount": 2], "eTag": "x", "lastModifiedDateTime": "2026-10-01T12:30:00Z"],
                    fileItem("manifest.json", etag: "\"{E1},2\"", size: 120, sha1: "AABBCC"),
                    ["id": "GONE", "name": "deleted.bin", "deleted": ["state": "deleted"]],
                    ["id": "NOTE", "name": "Notebook", "package": ["type": "oneNote"]],
                ], "@odata.nextLink": nextLink])
            }
            let (onedrive, _) = provider()
            let page = try await onedrive.listFolder("/Paper/My Art.paper", pageToken: nil)
            #expect(page.items.map(\.name) == ["layers", "manifest.json"])
            #expect(page.items[0].kind == .folder)
            #expect(page.items[1].revision == "\"{E1},2\"")
            #expect(page.items[1].size == 120)
            #expect(page.items[1].contentHash == CloudContentHash(algorithm: .sha1, value: "aabbcc"))
            #expect(page.nextPageToken == nextLink)

            let all = try await onedrive.listAll("/Paper/My Art.paper")
            #expect(all.map(\.name) == ["layers", "manifest.json", "later.bin"])

            let first = try #require(MockURLProtocol.requests.first)
            #expect(first.method == "GET")
            #expect(first.header("Authorization") == "Bearer ACCESS")
            #expect(first.url.absoluteString.hasPrefix("https://graph.microsoft.com/v1.0/me/drive/root:/Paper/My%20Art.paper:/children?"))
            #expect(first.query["$top"] == "200")
        }

        @Test func theRootUsesTheRootChildrenEndpoint() async throws {
            MockURLProtocol.install { _ in .json(["value": []]) }
            let (onedrive, _) = provider()
            _ = try await onedrive.listFolder(.root, pageToken: nil)
            #expect(MockURLProtocol.requests.first?.signature == "GET https://graph.microsoft.com/v1.0/me/drive/root/children")
        }

        @Test func neverSendsTheBearerTokenToAForeignPageLink() async throws {
            MockURLProtocol.install { _ in .json(["value": []]) }
            let (onedrive, _) = provider()
            await #expect(throws: CloudError.self) {
                _ = try await onedrive.listFolder("/x", pageToken: "https://evil.example.com/steal?token=1")
            }
            #expect(MockURLProtocol.requests.isEmpty)
        }

        @Test func simpleUploadCarriesIfMatchAndConflictBehavior() async throws {
            let box = try Sandbox("o-up")
            let source = try box.file("a.bin", "small payload")
            MockURLProtocol.install { [self] _ in .json(fileItem("a.bin", etag: "\"{NEW},3\"", size: 13), status: 200) }
            let (onedrive, _) = provider()
            let item = try await onedrive.upload(from: source, to: "/Paper/a b.bin", precondition: .revision("\"{OLD},2\""))
            #expect(item.revision == "\"{NEW},3\"")

            let request = try #require(MockURLProtocol.requests.first)
            #expect(request.method == "PUT")
            #expect(request.url.absoluteString.hasPrefix("https://graph.microsoft.com/v1.0/me/drive/root:/Paper/a%20b.bin:/content?"))
            #expect(request.query["@microsoft.graph.conflictBehavior"] == "replace")
            #expect(request.header("If-Match") == "\"{OLD},2\"")
            #expect(request.header("Authorization") == "Bearer ACCESS")
            #expect(request.header("Content-Type") == "application/octet-stream")
            #expect(request.bodyString == "small payload")

            _ = try await onedrive.upload(from: source, to: "/Paper/new.bin", precondition: .mustNotExist)
            let create = MockURLProtocol.requests.last
            #expect(create?.query["@microsoft.graph.conflictBehavior"] == "fail")
            #expect(create?.header("If-Match") == nil)
        }

        @Test func failedPreconditionsBecomeRevisionMismatch() async throws {
            let box = try Sandbox("o-412")
            let source = try box.file("a.bin", "x")
            let (onedrive, _) = provider()
            MockURLProtocol.install { _ in .json(["error": ["code": "resourceModified"]], status: 412) }
            await #expect(throws: CloudError.revisionMismatch(path: "/a.bin")) {
                _ = try await onedrive.upload(from: source, to: "/a.bin", precondition: .revision("\"stale\""))
            }
            MockURLProtocol.install { _ in .json(["error": ["code": "nameAlreadyExists"]], status: 409) }
            await #expect(throws: CloudError.revisionMismatch(path: "/a.bin")) {
                _ = try await onedrive.upload(from: source, to: "/a.bin", precondition: .mustNotExist)
            }
        }

        @Test func largeUploadsUseAnUploadSessionWithoutTheBearerToken() async throws {
            let box = try Sandbox("o-chunk")
            let payload = Data((0..<(700 * 1024)).map { UInt8($0 % 239) })
            let source = box.root.appendingPathComponent("big.bin")
            try payload.write(to: source)
            let uploadURL = "https://upload.example-storage.net/sessions/abc123"
            MockURLProtocol.install { [self] request in
                if request.url.path.hasSuffix(":/createUploadSession") { return .json(["uploadUrl": uploadURL, "expirationDateTime": "2026-10-02T00:00:00Z"]) }
                if request.url.absoluteString.hasPrefix(uploadURL) {
                    let range = request.header("Content-Range") ?? ""
                    if range.hasSuffix("/716800") && range.hasPrefix("bytes 655360-") {
                        return .json(fileItem("big.bin", etag: "\"{BIG},1\"", size: 716800), status: 201)
                    }
                    // acknowledge exactly what was sent: next expected range starts right after this chunk
                    let sent = (range.split(separator: " ").last ?? "").split(separator: "/").first ?? ""
                    let end = Int(sent.split(separator: "-").last ?? "0") ?? 0
                    return .json(["nextExpectedRanges": ["\(end + 1)-"]], status: 202)
                }
                return .json(["error": "unexpected"], status: 500)
            }
            let (onedrive, _) = provider(simpleLimit: 1024, chunk: 320 * 1024)
            let item = try await onedrive.upload(from: source, to: "/Paper/big.bin", precondition: .revision("\"{OLD},1\""))
            #expect(item.revision == "\"{BIG},1\"")

            let create = try #require(MockURLProtocol.requests.first)
            #expect(create.method == "POST")
            #expect(create.header("If-Match") == "\"{OLD},1\"")
            let item1 = try #require(create.bodyJSON?["item"] as? [String: Any])
            #expect(item1["@microsoft.graph.conflictBehavior"] as? String == "replace")
            #expect(item1["name"] as? String == "big.bin")

            let puts = MockURLProtocol.requests.filter { $0.method == "PUT" }
            #expect(puts.map { $0.header("Content-Range") } == ["bytes 0-327679/716800", "bytes 327680-655359/716800", "bytes 655360-716799/716800"])
            #expect(puts.reduce(Data()) { $0 + $1.body } == payload)
            for put in puts { #expect(put.header("Authorization") == nil) } // pre-authorised URL: no bearer token
        }

        @Test func aServerThatNeverAdvancesIsAbandonedInsteadOfLoopingForever() async throws {
            let box = try Sandbox("o-stall")
            let source = box.root.appendingPathComponent("big.bin")
            try Data(repeating: 7, count: 700 * 1024).write(to: source)
            MockURLProtocol.install { request in
                if request.url.path.hasSuffix(":/createUploadSession") { return .json(["uploadUrl": "https://upload.example-storage.net/s/1"]) }
                return .json(["nextExpectedRanges": ["0-"]], status: 202) // always "start over"
            }
            let (onedrive, _) = provider(simpleLimit: 1024, chunk: 320 * 1024)
            await #expect(throws: CloudError.self) { _ = try await onedrive.upload(from: source, to: "/big.bin", precondition: .none) }
            #expect(MockURLProtocol.requests.count < 20)
        }

        @Test func downloadReadsTheETagFirstThenTheContent() async throws {
            let box = try Sandbox("o-down")
            MockURLProtocol.install { [self] request in
                if request.url.path.hasSuffix(":/content") { return .bytes(Data("content!".utf8)) }
                return .json(fileItem("a.bin", etag: "\"{ET},9\"", size: 8))
            }
            let (onedrive, _) = provider()
            let target = box.root.appendingPathComponent("a.bin")
            let item = try await onedrive.download("/Paper/a.bin", to: target)
            #expect(item.revision == "\"{ET},9\"")
            #expect(try String(contentsOf: target, encoding: .utf8) == "content!")
            #expect(MockURLProtocol.requests.map(\.method) == ["GET", "GET"])
            #expect(MockURLProtocol.requests[1].url.absoluteString.hasPrefix("https://graph.microsoft.com/v1.0/me/drive/root:/Paper/a.bin:/content"))
        }

        @Test func createFolderMakesEachMissingLevelAndDeleteUsesTheItemUrl() async throws {
            MockURLProtocol.install { request in
                if request.method == "GET" { return .json(["error": ["code": "itemNotFound"]], status: 404) }
                if request.method == "POST" {
                    let name = request.bodyJSON?["name"] as? String ?? "?"
                    return .json(["id": "ID-\(name)", "name": name, "folder": [String: Any]()], status: 201)
                }
                if request.method == "DELETE" { return request.url.path.contains("missing") ? .json(["error": ["code": "itemNotFound"]], status: 404) : .empty(204) }
                return .empty(500)
            }
            let (onedrive, _) = provider()
            let folder = try await onedrive.createFolder("/Paper/Art.paper")
            #expect(folder.kind == .folder && folder.name == "Art.paper")
            let posts = MockURLProtocol.requests.filter { $0.method == "POST" }
            #expect(posts.map { $0.url.absoluteString } == [
                "https://graph.microsoft.com/v1.0/me/drive/root/children",
                "https://graph.microsoft.com/v1.0/me/drive/root:/Paper:/children",
            ])
            #expect(posts[0].bodyJSON?["name"] as? String == "Paper")
            #expect(posts[0].bodyJSON?["@microsoft.graph.conflictBehavior"] as? String == "fail")
            #expect(posts[0].bodyJSON?["folder"] != nil)

            try await onedrive.delete("/Paper/Art.paper")
            #expect(MockURLProtocol.requests.last?.signature == "DELETE https://graph.microsoft.com/v1.0/me/drive/root:/Paper/Art.paper:")
            await #expect(throws: CloudError.notFound(path: "/missing.bin")) { try await onedrive.delete("/missing.bin") }
            #expect(try await onedrive.stat("/missing.bin") == nil)
        }

        @Test func throttlingIsRetriedWithRetryAfter() async throws {
            let attempts = Counter()
            MockURLProtocol.install { _ in
                attempts.increment() < 3 ? .json(["error": ["code": "activityLimitReached"]], status: 429, headers: ["Retry-After": "4"]) : .json(["value": []])
            }
            let sleeps = SleepRecorder()
            let (onedrive, _) = provider(sleeps: sleeps, retry: HTTPRetryPolicy(maxAttempts: 4, baseDelay: 1, maxDelay: 60, maxRetryAfter: 120, jitterFraction: 0))
            _ = try await onedrive.listFolder(.root, pageToken: nil)
            #expect(sleeps.durations == [4, 4])
        }

        // MARK: Auth

        @Test func reportsNotConfigured() async throws {
            let onedrive = OneDriveProvider(configuration: CloudProviderConfiguration(), tokenStore: InMemoryTokenStore(), transport: MockURLProtocol.transport())
            guard case .notConfigured(let hint) = await onedrive.authState() else { Issue.record("expected notConfigured"); return }
            #expect(hint.contains("Register") && hint.contains("CloudKeys.plist") && hint.contains("oneDrive"))
            await #expect(throws: CloudError.notConfigured(hint: hint)) { try await onedrive.delete("/x") }
        }

        @Test func signsInAgainstTheCommonV2EndpointWithoutMSAL() async throws {
            MockURLProtocol.install { request in
                if request.url.host == "login.microsoftonline.com" {
                    return .json(["access_token": "MS-AT", "refresh_token": "MS-RT", "expires_in": 3599, "scope": "Files.ReadWrite offline_access"])
                }
                if request.url.path == "/v1.0/me/drive" { return .json(["owner": ["user": ["displayName": "Ada Artist"]]]) }
                return .json(["error": "unexpected"], status: 500)
            }
            let store = InMemoryTokenStore()
            let (onedrive, _) = provider(store: store)
            let browser = FakeWebAuthenticator()
            try await onedrive.signIn(using: browser)

            let url = try #require(browser.lastURL)
            let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            #expect(url.absoluteString.hasPrefix("https://login.microsoftonline.com/common/oauth2/v2.0/authorize?"))
            #expect(items["scope"] == "Files.ReadWrite offline_access")
            #expect(items["redirect_uri"] == "msauth.test.app://auth")
            #expect(browser.lastScheme == "msauth.test.app")
            #expect(items["code_challenge_method"] == "S256")

            let exchange = try #require(MockURLProtocol.requests.first)
            #expect(exchange.signature == "POST https://login.microsoftonline.com/common/oauth2/v2.0/token")
            #expect(exchange.form["scope"] == "Files.ReadWrite offline_access")
            #expect(PKCE.challenge(forVerifier: try #require(exchange.form["code_verifier"])) == items["code_challenge"])
            #expect(await onedrive.authState() == .signedIn(account: "Ada Artist"))
            #expect(try store.loadTokens(for: "oauth.oneDrive")?.refreshToken == "MS-RT")
        }

        @Test func microsoftRotatesRefreshTokensAndWeKeepTheNewOne() async throws {
            MockURLProtocol.install { request in
                request.url.host == "login.microsoftonline.com"
                    ? .json(["access_token": "FRESH", "refresh_token": "ROTATED", "expires_in": 3600])
                    : .json(["value": []])
            }
            let store = TestConfig.store("oauth.oneDrive", tokens: TestConfig.tokens(expiresIn: -5, access: "OLD", refresh: "RT-1"))
            let (onedrive, _) = provider(store: store)
            _ = try await onedrive.listFolder(.root, pageToken: nil)
            #expect(MockURLProtocol.requests.first?.form["refresh_token"] == "RT-1")
            #expect(MockURLProtocol.requests.first?.form["scope"] == "Files.ReadWrite offline_access")
            #expect(try store.loadTokens(for: "oauth.oneDrive")?.refreshToken == "ROTATED")
            #expect(MockURLProtocol.requests.last?.header("Authorization") == "Bearer FRESH")
        }

        @Test func defaultRedirectUriFollowsTheAzurePortalConvention() {
            #expect(OneDriveProvider.defaultRedirectURI(bundleIdentifier: "com.example.paper") == "msauth.com.example.paper://auth")
            #expect(GoogleDriveProvider.defaultRedirectURI(clientID: "1-abc.apps.googleusercontent.com") == "com.googleusercontent.apps.1-abc:/oauth2redirect")
            #expect(DropboxProvider.defaultRedirectURI(appKey: "k") == "db-k://2/token")
        }
    }
}
