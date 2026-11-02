import Foundation
import Testing
@testable import CommonKit

extension MockedHTTP {
@Suite("HTTP retry and OAuth session")
struct HTTPTransportTests {
    private let url = URL(string: "https://api.example.com/thing")!
    private func policy(attempts: Int = 5) -> HTTPRetryPolicy {
        HTTPRetryPolicy(maxAttempts: attempts, baseDelay: 1, maxDelay: 60, maxRetryAfter: 120, jitterFraction: 0)
    }

    @Test func backoffDoublesAndIsCapped() {
        let policy = HTTPRetryPolicy(maxAttempts: 10, baseDelay: 1, maxDelay: 10, maxRetryAfter: 120, jitterFraction: 0.5)
        #expect(policy.delay(afterFailedAttempt: 1, retryAfter: nil) == 1)
        #expect(policy.delay(afterFailedAttempt: 2, retryAfter: nil) == 2)
        #expect(policy.delay(afterFailedAttempt: 3, retryAfter: nil) == 4)
        #expect(policy.delay(afterFailedAttempt: 4, retryAfter: nil) == 8)
        #expect(policy.delay(afterFailedAttempt: 5, retryAfter: nil) == 10)
        #expect(policy.delay(afterFailedAttempt: 1, retryAfter: nil, jitter: 1) == 1.5)
        #expect(policy.delay(afterFailedAttempt: 1, retryAfter: 30) == 30) // Retry-After is a lower bound
    }

    @Test func retryAfterHeaderIsParsed() {
        #expect(HTTPRetryPolicy.parseRetryAfter("30") == 30)
        #expect(HTTPRetryPolicy.parseRetryAfter(" 2.5 ") == 2.5)
        #expect(HTTPRetryPolicy.parseRetryAfter(nil) == nil)
        #expect(HTTPRetryPolicy.parseRetryAfter("soon") == nil)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let later = now.addingTimeInterval(90)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let parsed = HTTPRetryPolicy.parseRetryAfter(formatter.string(from: later), now: now)
        #expect(parsed == 90)
    }

    @Test func serverErrorsAreRetriedWithBackoffThenSucceed() async throws {
        let attempts = Counter()
        MockURLProtocol.install { _ in
            attempts.increment() < 3 ? .empty(503) : .json(["ok": true])
        }
        let sleeps = SleepRecorder()
        let transport = MockURLProtocol.transport(retry: policy(), sleeper: sleeps)
        let (data, response) = try await transport.data(for: URLRequest(url: url))
        #expect(response.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("true"))
        #expect(MockURLProtocol.requests.count == 3)
        #expect(sleeps.durations == [1, 2])
    }

    @Test func retryAfterIsRespected() async throws {
        let attempts = Counter()
        MockURLProtocol.install { _ in
            attempts.increment() == 1 ? .empty(429, headers: ["Retry-After": "7"]) : .empty(200)
        }
        let sleeps = SleepRecorder()
        let transport = MockURLProtocol.transport(retry: policy(), sleeper: sleeps)
        let (_, response) = try await transport.data(for: URLRequest(url: url))
        #expect(response.statusCode == 200)
        #expect(sleeps.durations == [7])
    }

    @Test func aHugeRetryAfterIsReportedInsteadOfWaitedFor() async throws {
        MockURLProtocol.install { _ in .empty(429, headers: ["Retry-After": "3600"]) }
        let sleeps = SleepRecorder()
        let transport = MockURLProtocol.transport(retry: policy(), sleeper: sleeps)
        await #expect(throws: CloudError.rateLimited(retryAfter: 3600)) { _ = try await transport.data(for: URLRequest(url: url)) }
        #expect(sleeps.durations.isEmpty)
        #expect(MockURLProtocol.requests.count == 1)
    }

    @Test func givingUpAfterTheLastAttempt() async throws {
        MockURLProtocol.install { _ in .json(["error": "down"], status: 503) }
        let sleeps = SleepRecorder()
        let transport = MockURLProtocol.transport(retry: policy(attempts: 3), sleeper: sleeps)
        await #expect(throws: CloudError.self) { _ = try await transport.data(for: URLRequest(url: url)) }
        #expect(MockURLProtocol.requests.count == 3)
        #expect(sleeps.durations == [1, 2])
        do { _ = try await transport.data(for: URLRequest(url: url)) } catch let error as CloudError {
            #expect(error.isTransient)
            if case .http(let status, _) = error { #expect(status == 503) } else { Issue.record("expected http error, got \(error)") }
        }
    }

    @Test func clientErrorsAreNotRetried() async throws {
        MockURLProtocol.install { _ in .json(["error": "nope"], status: 404) }
        let transport = MockURLProtocol.transport(retry: policy(), sleeper: SleepRecorder())
        let (_, response) = try await transport.data(for: URLRequest(url: url))
        #expect(response.statusCode == 404)
        #expect(MockURLProtocol.requests.count == 1)
    }

    @Test func droppedConnectionsAreRetried() async throws {
        let attempts = Counter()
        MockURLProtocol.install { _ in
            if attempts.increment() == 1 { throw URLError(.networkConnectionLost) }
            return .empty(200)
        }
        let sleeps = SleepRecorder()
        let transport = MockURLProtocol.transport(retry: policy(), sleeper: sleeps)
        let (_, response) = try await transport.data(for: URLRequest(url: url))
        #expect(response.statusCode == 200)
        #expect(sleeps.durations == [1])

        MockURLProtocol.install { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: CloudError.self) { _ = try await transport.data(for: URLRequest(url: url)) }
        #expect(MockURLProtocol.requests.count == 1) // offline: no point hammering
    }

    @Test func googleStyleRateLimit403IsRetried() async throws {
        let attempts = Counter()
        MockURLProtocol.install { _ in
            attempts.increment() == 1
                ? .json(["error": ["errors": [["reason": "userRateLimitExceeded"]]]], status: 403)
                : .empty(200)
        }
        let sleeps = SleepRecorder()
        let transport = MockURLProtocol.transport(retry: policy(), sleeper: sleeps)
        let (_, response) = try await transport.data(for: URLRequest(url: url))
        #expect(response.statusCode == 200)
        #expect(sleeps.durations == [1])
    }

    @Test func downloadsLandAtomicallyAndErrorsLeaveNoFile() async throws {
        let box = try Sandbox("download")
        MockURLProtocol.install { request in
            request.url.path.hasSuffix("/ok") ? .bytes(Data("payload".utf8)) : .json(["error": "gone"], status: 404)
        }
        let transport = MockURLProtocol.transport()
        let target = box.root.appendingPathComponent("out/file.bin")
        let ok = try await transport.download(URLRequest(url: URL(string: "https://x.example.com/ok")!), to: target)
        #expect(ok.response.statusCode == 200)
        #expect(try String(contentsOf: target, encoding: .utf8) == "payload")

        let missing = box.root.appendingPathComponent("out/missing.bin")
        let bad = try await transport.download(URLRequest(url: URL(string: "https://x.example.com/missing")!), to: missing)
        #expect(bad.response.statusCode == 404)
        #expect(String(decoding: bad.errorBody, as: UTF8.self).contains("gone"))
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func bearerTokensDoNotFollowRedirectsToOtherHosts() async throws {
        MockURLProtocol.install { request in
            switch request.url.host {
            case "graph.example.com": return .empty(302, headers: ["Location": "https://storage.example.net/blob/123"])
            case "same.example.com" where request.url.path == "/start": return .empty(302, headers: ["Location": "https://same.example.com/final"])
            default: return .bytes(Data("bytes".utf8))
            }
        }
        let transport = MockURLProtocol.transport()
        var crossHost = URLRequest(url: URL(string: "https://graph.example.com/content")!)
        crossHost.setValue("Bearer SECRET", forHTTPHeaderField: "Authorization")
        let (data, _) = try await transport.data(for: crossHost)
        #expect(String(decoding: data, as: UTF8.self) == "bytes")
        let hops = MockURLProtocol.requests
        #expect(hops.map { $0.url.host } == ["graph.example.com", "storage.example.net"])
        #expect(hops[0].header("Authorization") == "Bearer SECRET")
        #expect(hops[1].header("Authorization") == nil) // not leaked to the other host

        MockURLProtocol.install { request in
            request.url.path == "/start" ? .empty(302, headers: ["Location": "https://same.example.com/final"]) : .bytes(Data("ok".utf8))
        }
        var sameHost = URLRequest(url: URL(string: "https://same.example.com/start")!)
        sameHost.setValue("Bearer SECRET", forHTTPHeaderField: "Authorization")
        _ = try await transport.data(for: sameHost)
        #expect(MockURLProtocol.requests.last?.header("Authorization") == "Bearer SECRET") // same host keeps it
    }

    // MARK: OAuth session

    private func session(store: InMemoryTokenStore, transport: HTTPTransport) -> OAuthSession {
        let config = OAuthClientConfig(authorizationEndpoint: URL(string: "https://auth.example.com/authorize")!,
                                       tokenEndpoint: URL(string: "https://auth.example.com/token")!,
                                       clientID: "cid", redirectURI: "app.test:/cb", scopes: ["s"])
        return OAuthSession(providerID: "test", config: config, store: store, storeKey: "k", transport: transport)
    }

    @Test func expiredTokensAreRefreshedBeforeUseAndSavedWithTheOldRefreshToken() async throws {
        MockURLProtocol.install { _ in .json(["access_token": "NEW", "expires_in": 3600]) }
        let store = TestConfig.store("k", tokens: TestConfig.tokens(expiresIn: -600, access: "OLD", refresh: "RT"))
        let session = session(store: store, transport: MockURLProtocol.transport())
        #expect(try await session.validAccessToken() == "NEW")
        let request = try #require(MockURLProtocol.requests.first)
        #expect(request.signature == "POST https://auth.example.com/token")
        #expect(request.form["grant_type"] == "refresh_token")
        #expect(request.form["refresh_token"] == "RT")
        #expect(request.form["client_id"] == "cid")
        let saved = try #require(try store.loadTokens(for: "k"))
        #expect(saved.accessToken == "NEW" && saved.refreshToken == "RT")
        // fresh now: no second refresh
        #expect(try await session.validAccessToken() == "NEW")
        #expect(MockURLProtocol.requests.count == 1)
    }

    @Test func aTokenAboutToExpireIsRefreshedEarly() async throws {
        MockURLProtocol.install { _ in .json(["access_token": "NEW", "expires_in": 3600]) }
        let store = TestConfig.store("k", tokens: TestConfig.tokens(expiresIn: 30, access: "OLD")) // < 120 s leeway
        #expect(try await session(store: store, transport: MockURLProtocol.transport()).validAccessToken() == "NEW")
    }

    @Test func concurrentRequestsShareOneRefresh() async throws {
        MockURLProtocol.install { _ in .json(["access_token": "NEW", "expires_in": 3600]) }
        let store = TestConfig.store("k", tokens: TestConfig.tokens(expiresIn: -10, access: "OLD"))
        let session = session(store: store, transport: MockURLProtocol.transport())
        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<5 { group.addTask { try await session.validAccessToken() } }
            var all: [String] = []
            for try await token in group { all.append(token) }
            return all
        }
        #expect(results == Array(repeating: "NEW", count: 5))
        #expect(MockURLProtocol.requests.count == 1)
    }

    @Test func aRevokedRefreshTokenMeansSignInAgain() async throws {
        MockURLProtocol.install { _ in .json(["error": "invalid_grant"], status: 400) }
        let store = TestConfig.store("k", tokens: TestConfig.tokens(expiresIn: -10))
        let session = session(store: store, transport: MockURLProtocol.transport())
        await #expect(throws: CloudError.notSignedIn(provider: "test")) { _ = try await session.validAccessToken() }
        #expect(try store.loadTokens(for: "k") == nil)
        #expect(await !session.isSignedIn)
    }

    @Test func noTokensMeansNotSignedIn() async throws {
        let session = session(store: InMemoryTokenStore(), transport: MockURLProtocol.transport())
        await #expect(throws: CloudError.notSignedIn(provider: "test")) { _ = try await session.validAccessToken() }
    }
}
}

/// Thread-safe counter for mock handlers.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    /// Increments and returns the new value.
    func increment() -> Int { lock.withLock { value += 1; return value } }
    var current: Int { lock.withLock { value } }
}
