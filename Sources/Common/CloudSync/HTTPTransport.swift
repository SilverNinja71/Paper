import Foundation

// MARK: - Retry policy

/// Exponential backoff for transient failures (HTTP 408/429/5xx and dropped connections).
public struct HTTPRetryPolicy: Sendable, Equatable {
    /// Total tries including the first one.
    public var maxAttempts: Int
    /// Delay before the 2nd try; doubles every time.
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    /// If the server says "Retry-After" for longer than this, we stop and report `.rateLimited` instead of waiting.
    public var maxRetryAfter: TimeInterval
    /// Random extra delay of up to this fraction of the computed delay (avoids many devices retrying in lock-step).
    public var jitterFraction: Double

    public init(maxAttempts: Int = 5, baseDelay: TimeInterval = 1, maxDelay: TimeInterval = 60,
                maxRetryAfter: TimeInterval = 120, jitterFraction: Double = 0.25) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.maxRetryAfter = maxRetryAfter
        self.jitterFraction = jitterFraction
    }

    public static let standard = HTTPRetryPolicy()
    public static let none = HTTPRetryPolicy(maxAttempts: 1)

    /// Seconds to wait after the `attempt`-th try failed (attempt starts at 1).
    /// A server supplied `Retry-After` is a lower bound. `jitter` is a number in 0...1.
    public func delay(afterFailedAttempt attempt: Int, retryAfter: TimeInterval?, jitter: Double = 0) -> TimeInterval {
        let exponent = Double(max(0, attempt - 1))
        var wait = min(maxDelay, baseDelay * pow(2, exponent))
        wait += wait * jitterFraction * min(1, max(0, jitter))
        if let retryAfter { wait = max(wait, retryAfter) }
        return wait
    }

    /// Parses a `Retry-After` header: either delta-seconds ("30") or an HTTP date.
    public static func parseRetryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let seconds = Double(raw) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return max(0, date.timeIntervalSince(now)) }
        }
        return nil
    }

    static func isRetryableStatus(_ status: Int) -> Bool {
        status == 408 || status == 429 || (500...599).contains(status)
    }
}

// MARK: - Transport

/// Thin wrapper around `URLSession` that retries transient failures with exponential backoff and
/// honours `Retry-After`. It returns non-retryable responses (including 4xx) to the caller untouched, so
/// each provider can map its own error bodies.
public final class HTTPTransport: Sendable {
    public let session: URLSession
    public let retryPolicy: HTTPRetryPolicy
    private let sleeper: @Sendable (TimeInterval) async throws -> Void

    public init(session: URLSession = HTTPTransport.makeSession(),
                retryPolicy: HTTPRetryPolicy = .standard,
                sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = HTTPTransport.realSleep) {
        self.session = session
        self.retryPolicy = retryPolicy
        self.sleeper = sleeper
    }

    @Sendable public static func realSleep(_ seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    public static func makeSession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 6 * 3600
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        return URLSession(configuration: configuration)
    }

    // MARK: Public operations

    /// Sends a request whose body (if any) is already attached.
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await run { try await self.session.data(for: request, delegate: RedirectGuard()) }
    }

    /// Uploads the contents of a file without loading it into memory.
    public func upload(_ request: URLRequest, fromFile fileURL: URL) async throws -> (Data, HTTPURLResponse) {
        try await run { try await self.session.upload(for: request, fromFile: fileURL, delegate: RedirectGuard()) }
    }

    /// Uploads an in-memory chunk.
    public func upload(_ request: URLRequest, from data: Data) async throws -> (Data, HTTPURLResponse) {
        try await run { try await self.session.upload(for: request, from: data, delegate: RedirectGuard()) }
    }

    /// Downloads to `destination` (replacing anything there). For non-2xx answers nothing is written and the
    /// (truncated) error body is returned instead.
    public func download(_ request: URLRequest, to destination: URL) async throws -> (errorBody: Data, response: HTTPURLResponse) {
        try await run {
            let (temporary, response) = try await self.session.download(for: request, delegate: RedirectGuard())
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                let fm = FileManager.default
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.moveItem(at: temporary, to: destination)
                return (Data(), response)
            }
            let body = Self.readPrefix(of: temporary, limit: 64 * 1024)
            try? FileManager.default.removeItem(at: temporary)
            return (body, response)
        }
    }

    // MARK: Retry loop

    private func run(_ perform: () async throws -> (Data, URLResponse)) async throws -> (Data, HTTPURLResponse) {
        var attempt = 1
        while true {
            try Task.checkCancellation()
            do {
                let (data, response) = try await perform()
                guard let http = response as? HTTPURLResponse else {
                    throw CloudError.invalidResponse("The server did not answer with HTTP.")
                }
                let rateLimited403 = Self.isRateLimit403(http, body: data)
                guard HTTPRetryPolicy.isRetryableStatus(http.statusCode) || rateLimited403 else { return (data, http) }

                let retryAfter = HTTPRetryPolicy.parseRetryAfter(http.value(forHTTPHeaderField: "Retry-After"))
                if let retryAfter, retryAfter > retryPolicy.maxRetryAfter {
                    throw CloudError.rateLimited(retryAfter: retryAfter)
                }
                if attempt >= retryPolicy.maxAttempts {
                    if http.statusCode == 429 || rateLimited403 { throw CloudError.rateLimited(retryAfter: retryAfter) }
                    throw CloudError.http(status: http.statusCode, message: Self.snippet(of: data))
                }
                let wait = retryPolicy.delay(afterFailedAttempt: attempt, retryAfter: retryAfter,
                                             jitter: Double.random(in: 0...1))
                try await sleeper(wait)
                attempt += 1
            } catch let error as URLError {
                if error.code == .cancelled { throw CancellationError() }
                guard Self.isTransient(error), attempt < retryPolicy.maxAttempts else {
                    throw CloudError.network(error.localizedDescription)
                }
                let wait = retryPolicy.delay(afterFailedAttempt: attempt, retryAfter: nil, jitter: Double.random(in: 0...1))
                try await sleeper(wait)
                attempt += 1
            }
        }
    }

    /// Google Drive reports "slow down" as HTTP 403 with reason rateLimitExceeded / userRateLimitExceeded.
    static func isRateLimit403(_ response: HTTPURLResponse, body: Data) -> Bool {
        guard response.statusCode == 403 else { return false }
        let text = String(decoding: body.prefix(2048), as: UTF8.self)
        return text.contains("rateLimitExceeded") || text.contains("RateLimitExceeded")
    }

    static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed, .cannotFindHost,
             .secureConnectionFailed, .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    static func snippet(of data: Data, limit: Int = 300) -> String {
        let text = String(decoding: data.prefix(limit), as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func readPrefix(of url: URL, limit: Int) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: limit)) ?? Data()
    }
}

/// Drops the `Authorization` header when a redirect leaves the original host, so a bearer token issued for
/// Google / Dropbox / Microsoft is never sent to whatever server a redirect points at.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var next = request
        let originalHost = task.originalRequest?.url?.host?.lowercased()
        if originalHost != request.url?.host?.lowercased() {
            next.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(next)
    }
}
