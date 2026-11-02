import Foundation
import CryptoKit

// MARK: - PKCE (RFC 7636)

public enum PKCE {
    public struct Pair: Sendable, Equatable {
        public let verifier: String
        public let challenge: String
    }

    /// A fresh random verifier (43 URL-safe characters) and its S256 challenge.
    public static func makePair() -> Pair {
        let verifier = randomURLSafeString(byteCount: 32)
        return Pair(verifier: verifier, challenge: challenge(forVerifier: verifier))
    }

    /// `BASE64URL(SHA256(ASCII(verifier)))` without padding.
    public static func challenge(forVerifier verifier: String) -> String {
        base64URLEncode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public static func randomURLSafeString(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: 0...255, using: &generator) }
        return base64URLEncode(Data(bytes))
    }

    public static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Form / query encoding

enum FormEncoding {
    /// RFC 3986 "unreserved" characters; everything else is percent-encoded.
    static let unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func encode(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
    }

    static func query(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }

    static func body(_ pairs: [(String, String)]) -> Data { Data(query(pairs).utf8) }

    /// Percent-encodes every path component of an already-split path (slashes between components stay).
    static func encodePath(_ components: [String]) -> String {
        components.map { encode($0) }.joined(separator: "/")
    }
}

// MARK: - OAuth configuration and pure request builders

public struct OAuthClientConfig: Sendable, Equatable {
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var clientID: String
    /// Only needed by Google "Desktop app" clients (Google's token endpoint insists on it even with PKCE).
    public var clientSecret: String?
    public var redirectURI: String
    public var scopes: [String]
    public var extraAuthorizationParameters: [String: String]
    /// Microsoft wants `scope` repeated on the token requests; the others do not.
    public var sendScopeWithTokenRequests: Bool

    public init(authorizationEndpoint: URL, tokenEndpoint: URL, clientID: String, clientSecret: String? = nil,
                redirectURI: String, scopes: [String], extraAuthorizationParameters: [String: String] = [:],
                sendScopeWithTokenRequests: Bool = false) {
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.extraAuthorizationParameters = extraAuthorizationParameters
        self.sendScopeWithTokenRequests = sendScopeWithTokenRequests
    }

    /// The scheme ASWebAuthenticationSession must listen for (taken from the redirect URI).
    public var callbackScheme: String? { URL(string: redirectURI)?.scheme }
}

public enum OAuthFlow {
    /// Builds the page the user signs in on (authorization code flow with PKCE S256).
    public static func authorizationURL(config: OAuthClientConfig, state: String, codeChallenge: String) -> URL {
        var pairs: [(String, String)] = [
            ("client_id", config.clientID),
            ("redirect_uri", config.redirectURI),
            ("response_type", "code"),
            ("code_challenge", codeChallenge),
            ("code_challenge_method", "S256"),
            ("state", state),
        ]
        if !config.scopes.isEmpty { pairs.append(("scope", config.scopes.joined(separator: " "))) }
        for key in config.extraAuthorizationParameters.keys.sorted() {
            pairs.append((key, config.extraAuthorizationParameters[key] ?? ""))
        }
        let separator = config.authorizationEndpoint.absoluteString.contains("?") ? "&" : "?"
        return URL(string: config.authorizationEndpoint.absoluteString + separator + FormEncoding.query(pairs))
            ?? config.authorizationEndpoint
    }

    /// Validates the redirect the browser session handed back and returns the authorization code.
    /// Throws `.stateMismatch` when `state` is missing or different (CSRF protection).
    public static func authorizationCode(from callback: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false) else {
            throw CloudError.authenticationFailed("The sign-in redirect could not be read.")
        }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] { values[item.name] = item.value ?? "" }
        // Some providers (rarely) put the answer in the fragment.
        if values.isEmpty, let fragment = components.fragment {
            for part in fragment.split(separator: "&") {
                let pieces = part.split(separator: "=", maxSplits: 1).map(String.init)
                if pieces.count == 2 { values[pieces[0]] = pieces[1].removingPercentEncoding ?? pieces[1] }
            }
        }
        guard let state = values["state"], constantTimeEqual(state, expectedState) else {
            throw CloudError.stateMismatch
        }
        if let error = values["error"] {
            if error == "access_denied" { throw CloudError.signInCancelled }
            throw CloudError.authenticationFailed(values["error_description"] ?? error)
        }
        guard let code = values["code"], !code.isEmpty else {
            throw CloudError.authenticationFailed("The sign-in redirect did not contain a code.")
        }
        return code
    }

    public static func tokenExchangeRequest(config: OAuthClientConfig, code: String, codeVerifier: String) -> URLRequest {
        var pairs: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", config.redirectURI),
            ("client_id", config.clientID),
            ("code_verifier", codeVerifier),
        ]
        if let secret = config.clientSecret, !secret.isEmpty { pairs.append(("client_secret", secret)) }
        if config.sendScopeWithTokenRequests { pairs.append(("scope", config.scopes.joined(separator: " "))) }
        return formRequest(url: config.tokenEndpoint, pairs: pairs)
    }

    public static func refreshRequest(config: OAuthClientConfig, refreshToken: String) -> URLRequest {
        var pairs: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", config.clientID),
        ]
        if let secret = config.clientSecret, !secret.isEmpty { pairs.append(("client_secret", secret)) }
        if config.sendScopeWithTokenRequests { pairs.append(("scope", config.scopes.joined(separator: " "))) }
        return formRequest(url: config.tokenEndpoint, pairs: pairs)
    }

    private static func formRequest(url: URL, pairs: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = FormEncoding.body(pairs)
        return request
    }

    /// Turns the token endpoint's JSON into tokens. Servers that omit `refresh_token` on refresh
    /// (Google, Dropbox) keep the previous one.
    public static func parseTokenResponse(_ data: Data, previous: OAuthTokens?, now: Date) throws -> OAuthTokens {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudError.invalidResponse("The token response was not JSON.")
        }
        guard let access = object["access_token"] as? String, !access.isEmpty else {
            let reason = (object["error_description"] as? String) ?? (object["error"] as? String) ?? "no access token"
            throw CloudError.authenticationFailed(reason)
        }
        var expiresIn: TimeInterval?
        if let number = object["expires_in"] as? NSNumber { expiresIn = number.doubleValue }
        else if let text = object["expires_in"] as? String { expiresIn = Double(text) }
        return OAuthTokens(
            accessToken: access,
            refreshToken: (object["refresh_token"] as? String) ?? previous?.refreshToken,
            expiresAt: expiresIn.map { now.addingTimeInterval($0) },
            tokenType: (object["token_type"] as? String) ?? "Bearer",
            scope: (object["scope"] as? String) ?? previous?.scope,
            accountLabel: previous?.accountLabel
        )
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<x.count { difference |= x[index] ^ y[index] }
        return difference == 0
    }
}

// MARK: - Session (sign-in, refresh-before-expiry, sign-out)

/// Owns one account's tokens: performs the sign-in, hands out always-valid access tokens (refreshing a little
/// before they expire, and only once even if many requests ask at the same time) and forgets them on sign-out.
public actor OAuthSession {
    private let config: OAuthClientConfig
    private let store: TokenStore
    private let storeKey: String
    private let transport: HTTPTransport
    private let providerID: CloudProviderID
    private let clock: @Sendable () -> Date
    private let refreshLeeway: TimeInterval

    private var cached: OAuthTokens?
    private var loaded = false
    private var refreshTask: Task<OAuthTokens, Error>?

    public init(providerID: CloudProviderID, config: OAuthClientConfig, store: TokenStore, storeKey: String,
                transport: HTTPTransport, refreshLeeway: TimeInterval = 120,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.providerID = providerID
        self.config = config
        self.store = store
        self.storeKey = storeKey
        self.transport = transport
        self.refreshLeeway = refreshLeeway
        self.clock = clock
    }

    // MARK: State

    private func currentTokens() -> OAuthTokens? {
        if !loaded {
            cached = (try? store.loadTokens(for: storeKey)) ?? nil
            loaded = true
        }
        return cached
    }

    public var isSignedIn: Bool { currentTokens() != nil }
    public var accountLabel: String? { currentTokens()?.accountLabel }

    public func setAccountLabel(_ label: String?) {
        guard var tokens = currentTokens(), let label, !label.isEmpty else { return }
        tokens.accountLabel = label
        persist(tokens)
    }

    private func persist(_ tokens: OAuthTokens) {
        cached = tokens
        loaded = true
        try? store.saveTokens(tokens, for: storeKey)
    }

    // MARK: Sign-in / sign-out

    public func signIn(using authenticator: any WebAuthenticator) async throws {
        guard let scheme = config.callbackScheme, !scheme.isEmpty else {
            throw CloudError.notConfigured(hint: "The redirect URI \"\(config.redirectURI)\" has no scheme. Use something like com.example.app:/oauth.")
        }
        let pkce = PKCE.makePair()
        let state = PKCE.randomURLSafeString(byteCount: 24)
        let url = OAuthFlow.authorizationURL(config: config, state: state, codeChallenge: pkce.challenge)
        let callback = try await authenticator.authenticate(authorizationURL: url, callbackURLScheme: scheme)
        let code = try OAuthFlow.authorizationCode(from: callback, expectedState: state)

        let request = OAuthFlow.tokenExchangeRequest(config: config, code: code, codeVerifier: pkce.verifier)
        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw CloudError.authenticationFailed(Self.errorText(from: data, status: response.statusCode))
        }
        let tokens = try OAuthFlow.parseTokenResponse(data, previous: nil, now: clock())
        persist(tokens)
    }

    public func signOut() throws {
        refreshTask?.cancel()
        refreshTask = nil
        cached = nil
        loaded = true
        try store.deleteTokens(for: storeKey)
    }

    // MARK: Access tokens

    /// A token that is valid for at least `refreshLeeway` more seconds. Refreshes first if necessary.
    public func validAccessToken() async throws -> String {
        guard let tokens = currentTokens() else { throw CloudError.notSignedIn(provider: providerID) }
        if !tokens.needsRefresh(at: clock(), leeway: refreshLeeway) { return tokens.accessToken }
        return try await refresh().accessToken
    }

    /// Called after the API answered 401 for `staleToken`. Refreshes unless somebody else already did.
    public func tokenAfterRejection(of staleToken: String) async throws -> String {
        guard let tokens = currentTokens() else { throw CloudError.notSignedIn(provider: providerID) }
        if tokens.accessToken != staleToken { return tokens.accessToken }
        return try await refresh().accessToken
    }

    private func refresh() async throws -> OAuthTokens {
        if let refreshTask { return try await refreshTask.value }
        guard let tokens = currentTokens(), let refreshToken = tokens.refreshToken else {
            // An expired token with no way to renew it: the user has to sign in again.
            try? signOut()
            throw CloudError.notSignedIn(provider: providerID)
        }
        let task = Task<OAuthTokens, Error> { [config, transport, clock, providerID] in
            let request = OAuthFlow.refreshRequest(config: config, refreshToken: refreshToken)
            let (data, response) = try await transport.data(for: request)
            if response.statusCode == 400 || response.statusCode == 401 {
                // invalid_grant & friends: the refresh token was revoked or expired.
                throw CloudError.notSignedIn(provider: providerID)
            }
            guard (200..<300).contains(response.statusCode) else {
                throw CloudError.http(status: response.statusCode, message: Self.errorText(from: data, status: response.statusCode))
            }
            return try OAuthFlow.parseTokenResponse(data, previous: tokens, now: clock())
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let fresh = try await task.value
            persist(fresh)
            return fresh
        } catch let error as CloudError {
            if case .notSignedIn = error { try? signOut() }
            throw error
        }
    }

    static func errorText(from data: Data, status: Int) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let description = object["error_description"] as? String { return description }
            if let error = object["error"] as? String { return error }
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
        }
        let text = HTTPTransport.snippet(of: data)
        return text.isEmpty ? "HTTP \(status)" : text
    }
}

// MARK: - Authorised requests (bearer token + one refresh-and-retry on 401)

struct AuthorizedHTTP: Sendable {
    let session: OAuthSession
    let transport: HTTPTransport
    let providerID: CloudProviderID

    func data(_ build: @Sendable (String) throws -> URLRequest) async throws -> (Data, HTTPURLResponse) {
        let token = try await session.validAccessToken()
        let first = try await transport.data(for: build(token))
        guard first.1.statusCode == 401 else { return first }
        let fresh = try await session.tokenAfterRejection(of: token)
        let second = try await transport.data(for: build(fresh))
        if second.1.statusCode == 401 { throw CloudError.notSignedIn(provider: providerID) }
        return second
    }

    func upload(fromFile fileURL: URL, _ build: @Sendable (String) throws -> URLRequest) async throws -> (Data, HTTPURLResponse) {
        let token = try await session.validAccessToken()
        let first = try await transport.upload(build(token), fromFile: fileURL)
        guard first.1.statusCode == 401 else { return first }
        let fresh = try await session.tokenAfterRejection(of: token)
        let second = try await transport.upload(build(fresh), fromFile: fileURL)
        if second.1.statusCode == 401 { throw CloudError.notSignedIn(provider: providerID) }
        return second
    }

    func upload(data: Data, _ build: @Sendable (String) throws -> URLRequest) async throws -> (Data, HTTPURLResponse) {
        let token = try await session.validAccessToken()
        let first = try await transport.upload(build(token), from: data)
        guard first.1.statusCode == 401 else { return first }
        let fresh = try await session.tokenAfterRejection(of: token)
        let second = try await transport.upload(build(fresh), from: data)
        if second.1.statusCode == 401 { throw CloudError.notSignedIn(provider: providerID) }
        return second
    }

    func download(to destination: URL, _ build: @Sendable (String) throws -> URLRequest) async throws -> (errorBody: Data, response: HTTPURLResponse) {
        let token = try await session.validAccessToken()
        let first = try await transport.download(build(token), to: destination)
        guard first.response.statusCode == 401 else { return first }
        let fresh = try await session.tokenAfterRejection(of: token)
        let second = try await transport.download(build(fresh), to: destination)
        if second.response.statusCode == 401 { throw CloudError.notSignedIn(provider: providerID) }
        return second
    }
}
