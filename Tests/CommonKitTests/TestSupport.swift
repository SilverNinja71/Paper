import Foundation
import Testing
@testable import CommonKit

// MARK: - Temp folders

/// A unique temp folder that is deleted when the object goes away. Tests never touch real user folders.
final class Sandbox: @unchecked Sendable {
    let root: URL

    init(_ label: String = "sandbox") throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("CommonKitTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base.resolvingSymlinksInPath()
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func file(_ name: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }
}

enum Fixture {
    static func write(_ files: [String: String], toPackage name: String, in root: URL) throws {
        let package = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        for (path, text) in files { try set(text, at: path, inPackage: name, in: root) }
    }

    static func set(_ text: String, at path: String, inPackage name: String, in root: URL, modified: Date? = nil) throws {
        let url = root.appendingPathComponent(name).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
    }

    static func read(_ path: String, inPackage name: String, in root: URL) -> String? {
        try? String(contentsOf: root.appendingPathComponent(name).appendingPathComponent(path), encoding: .utf8)
    }

    static func remove(_ path: String, inPackage name: String, in root: URL) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent(name).appendingPathComponent(path))
    }

    /// Package-relative file paths -> contents.
    static func snapshot(package name: String, in root: URL) -> [String: String] {
        var result: [String: String] = [:]
        func walk(_ directory: URL, prefix: String) {
            for entry in ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []) {
                let url = directory.appendingPathComponent(entry)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
                let relative = prefix.isEmpty ? entry : prefix + "/" + entry
                if isDirectory.boolValue { walk(url, prefix: relative) }
                else { result[relative] = try? String(contentsOf: url, encoding: .utf8) }
            }
        }
        walk(root.appendingPathComponent(name, isDirectory: true), prefix: "")
        return result
    }

    static func packageNames(in root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { !$0.hasPrefix(".") && $0.hasSuffix(".paper") }.sorted()
    }
}

// MARK: - Recording provider

/// Wraps a real provider and logs every call, so tests can assert what travelled and in which order.
final class RecordingProvider: CloudStorageProvider, @unchecked Sendable {
    enum Call: Equatable, Sendable {
        case upload(String)
        case download(String)
        case delete(String)
        case createFolder(String)
    }

    private let inner: any CloudStorageProvider
    private let lock = NSLock()
    private var log: [Call] = []
    private var failUploadsAfter: Int?
    private var uploadsSeen = 0
    private var beforeUploadHook: (@Sendable (String) -> Void)?
    private var failure: CloudError?

    init(_ inner: any CloudStorageProvider) { self.inner = inner }

    var id: CloudProviderID { inner.id }
    var displayName: String { inner.displayName }

    var calls: [Call] { lock.withLock { log } }
    var uploads: [String] { calls.compactMap { if case .upload(let p) = $0 { return p } else { return nil } } }
    var downloads: [String] { calls.compactMap { if case .download(let p) = $0 { return p } else { return nil } } }
    var deletes: [String] { calls.compactMap { if case .delete(let p) = $0 { return p } else { return nil } } }

    func reset() { lock.withLock { log = []; uploadsSeen = 0 } }

    /// After `count` successful uploads every further upload throws `error`.
    func failUploads(after count: Int?, with error: CloudError = .network("simulated outage")) {
        lock.withLock { failUploadsAfter = count; failure = error; uploadsSeen = 0 }
    }

    func onBeforeUpload(_ hook: (@Sendable (String) -> Void)?) { lock.withLock { beforeUploadHook = hook } }

    private func record(_ call: Call) { lock.withLock { log.append(call) } }

    func authState() async -> CloudAuthState { await inner.authState() }
    func signIn(using authenticator: any WebAuthenticator) async throws { try await inner.signIn(using: authenticator) }
    func signOut() async throws { try await inner.signOut() }
    func listFolder(_ path: CloudPath, pageToken: String?) async throws -> CloudListPage { try await inner.listFolder(path, pageToken: pageToken) }
    func stat(_ path: CloudPath) async throws -> CloudItem? { try await inner.stat(path) }

    func download(_ path: CloudPath, to destination: URL) async throws -> CloudItem {
        record(.download(path.string))
        return try await inner.download(path, to: destination)
    }

    func upload(from source: URL, to path: CloudPath, precondition: UploadPrecondition) async throws -> CloudItem {
        let (hook, limit, error, seen) = lock.withLock { (beforeUploadHook, failUploadsAfter, failure, uploadsSeen) }
        hook?(path.string)
        if let limit, seen >= limit, let error { throw error }
        let item = try await inner.upload(from: source, to: path, precondition: precondition)
        lock.withLock { uploadsSeen += 1 }
        record(.upload(path.string))
        return item
    }

    func createFolder(_ path: CloudPath) async throws -> CloudItem {
        record(.createFolder(path.string))
        return try await inner.createFolder(path)
    }

    func delete(_ path: CloudPath) async throws {
        record(.delete(path.string))
        try await inner.delete(path)
    }
}

// MARK: - Fake sign-in provider (no network)

struct StubProvider: CloudStorageProvider {
    var id: CloudProviderID
    var displayName: String
    var state: CloudAuthState

    func authState() async -> CloudAuthState { state }
    func signIn(using authenticator: any WebAuthenticator) async throws {}
    func signOut() async throws {}
    func listFolder(_ path: CloudPath, pageToken: String?) async throws -> CloudListPage { throw CloudError.unavailable("stub") }
    func stat(_ path: CloudPath) async throws -> CloudItem? { nil }
    func download(_ path: CloudPath, to destination: URL) async throws -> CloudItem { throw CloudError.unavailable("stub") }
    func upload(from source: URL, to path: CloudPath, precondition: UploadPrecondition) async throws -> CloudItem { throw CloudError.unavailable("stub") }
    func createFolder(_ path: CloudPath) async throws -> CloudItem { throw CloudError.unavailable("stub") }
    func delete(_ path: CloudPath) async throws {}
}

// MARK: - Web authenticator fake

/// Plays the part of the browser sheet: returns the redirect a real provider would send.
final class FakeWebAuthenticator: WebAuthenticator, @unchecked Sendable {
    enum Behavior: Sendable { case approve(code: String), wrongState, denied, cancelled }

    private let lock = NSLock()
    private var _lastURL: URL?
    private var _lastScheme: String?
    let behavior: Behavior

    init(_ behavior: Behavior = .approve(code: "AUTHCODE")) { self.behavior = behavior }

    var lastURL: URL? { lock.withLock { _lastURL } }
    var lastScheme: String? { lock.withLock { _lastScheme } }

    func authenticate(authorizationURL: URL, callbackURLScheme: String) async throws -> URL {
        lock.withLock { _lastURL = authorizationURL; _lastScheme = callbackURLScheme }
        let items = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let state = items.first { $0.name == "state" }?.value ?? ""
        let redirect = items.first { $0.name == "redirect_uri" }?.value ?? "\(callbackURLScheme):/cb"
        switch behavior {
        case .approve(let code):
            return URL(string: "\(redirect)?code=\(code)&state=\(state)")!
        case .wrongState:
            return URL(string: "\(redirect)?code=EVIL&state=not-the-state")!
        case .denied:
            return URL(string: "\(redirect)?error=access_denied&state=\(state)")!
        case .cancelled:
            throw CloudError.signInCancelled
        }
    }
}

// MARK: - Mock HTTP

/// Parent of every test suite that installs a global `MockURLProtocol` handler. Swift Testing runs suites in
/// parallel, so these must all live under one `.serialized` parent (the trait applies to nested suites too).
@Suite("Mocked HTTP", .serialized, .timeLimit(.minutes(2)))
enum MockedHTTP {}

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data

        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        var query: [String: String] {
            var result: [String: String] = [:]
            for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { result[item.name] = item.value ?? "" }
            return result
        }
        var bodyString: String { String(decoding: body, as: UTF8.self) }
        var bodyJSON: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
        var form: [String: String] {
            var result: [String: String] = [:]
            for pair in bodyString.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                result[parts[0].removingPercentEncoding ?? parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
            }
            return result
        }
        /// "METHOD scheme://host/path" without the query string.
        var signature: String {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.query = nil
            return "\(method) \(components?.string ?? url.absoluteString)"
        }
        /// Argument of a Dropbox-style `Dropbox-API-Arg` header, parsed.
        var dropboxArg: [String: Any]? {
            guard let text = header("Dropbox-API-Arg") else { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        }
    }

    struct Response: Sendable {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body: Data = Data()

        static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> Response {
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            return Response(status: status, headers: headers.merging(["Content-Type": "application/json"]) { first, _ in first }, body: data)
        }
        static func bytes(_ data: Data, status: Int = 200, headers: [String: String] = [:]) -> Response {
            Response(status: status, headers: headers, body: data)
        }
        static func empty(_ status: Int = 200, headers: [String: String] = [:]) -> Response {
            Response(status: status, headers: headers, body: Data())
        }
    }

    typealias Handler = @Sendable (Request) throws -> Response

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var log: [Request] = []

    /// Installs the handler and clears the request log. Mock-based suites are `.serialized`, so this is safe.
    static func install(_ newHandler: @escaping Handler) {
        lock.withLock { handler = newHandler; log = [] }
    }

    static var requests: [Request] { lock.withLock { log } }

    static func transport(retry: HTTPRetryPolicy = .none, sleeper: SleepRecorder? = nil) -> HTTPTransport {
        let noSleep: @Sendable (TimeInterval) async throws -> Void = { _ in }
        return HTTPTransport(session: HTTPTransport.makeSession(protocolClasses: [MockURLProtocol.self]),
                             retryPolicy: retry, sleeper: sleeper?.sleeper ?? noSleep)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let recorded = Request(method: request.httpMethod ?? "GET", url: url,
                               headers: request.allHTTPHeaderFields ?? [:], body: Self.readBody(request))
        let current = Self.lock.withLock { () -> Handler? in
            Self.log.append(recorded)
            return Self.handler
        }
        do {
            guard let current else { throw URLError(.badServerResponse) }
            let reply = try current(recorded)
            let http = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            if (301...303).contains(reply.status) || reply.status == 307, let target = reply.headers["Location"].flatMap(URL.init(string:)) {
                var next = request
                next.url = target
                client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: http)
                return
            }
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

/// Records the delays the transport / manager would have slept, without actually waiting.
final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval] = []

    var durations: [TimeInterval] { lock.withLock { values } }

    var sleeper: @Sendable (TimeInterval) async throws -> Void {
        { [self] seconds in
            lock.withLock { values.append(seconds) }
        }
    }
}

// MARK: - Config helpers

enum TestConfig {
    static let google = "123456-abcdef.apps.googleusercontent.com"
    static let configuration = CloudProviderConfiguration(
        googleDrive: .init(clientID: google),
        dropbox: .init(clientID: "dropboxappkey"),
        oneDrive: .init(clientID: "00000000-0000-0000-0000-000000000abc", redirectURI: "msauth.test.app://auth"))

    static func tokens(expiresIn seconds: TimeInterval = 3600, access: String = "ACCESS", refresh: String? = "REFRESH") -> OAuthTokens {
        OAuthTokens(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(seconds))
    }

    static func store(_ key: String, tokens: OAuthTokens? = nil) -> InMemoryTokenStore {
        InMemoryTokenStore([key: tokens ?? Self.tokens()])
    }
}

/// Polls until `condition` is true or `timeout` passes. Returns whether it became true.
func waitUntil(timeout: TimeInterval = 5, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}
