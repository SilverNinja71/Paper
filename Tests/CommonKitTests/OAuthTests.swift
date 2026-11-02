import Foundation
import Testing
@testable import CommonKit

@Suite("PKCE and OAuth building blocks")
struct OAuthTests {
    // RFC 7636 appendix B. The RFC lists the 32 random octets, the verifier is their base64url form, and the
    // challenge is S256 of the verifier. (Note: the verifier is "...OhbUJU1p1r_..."; a copy of it with "U2p9r"
    // floating around does not hash to this challenge.)
    @Test func pkceMatchesRFC7636Vector() {
        let octets: [UInt8] = [116, 24, 223, 180, 151, 153, 224, 37, 79, 250, 96, 125, 216, 173, 187, 186,
                               22, 212, 37, 77, 105, 214, 191, 240, 91, 88, 5, 88, 83, 132, 141, 121]
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(PKCE.base64URLEncode(Data(octets)) == verifier)
        #expect(PKCE.challenge(forVerifier: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func generatedPairsAreValidAndUnique() {
        let a = PKCE.makePair(), b = PKCE.makePair()
        #expect(a.verifier != b.verifier)
        #expect(a.verifier.count == 43)
        #expect(a.verifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(PKCE.challenge(forVerifier: a.verifier) == a.challenge)
        #expect(!a.challenge.contains("=") && !a.challenge.contains("+") && !a.challenge.contains("/"))
    }

    private var config: OAuthClientConfig {
        OAuthClientConfig(authorizationEndpoint: URL(string: "https://auth.example.com/authorize")!,
                          tokenEndpoint: URL(string: "https://auth.example.com/token")!,
                          clientID: "client 1", redirectURI: "com.example.app:/cb",
                          scopes: ["files.read", "offline access"], extraAuthorizationParameters: ["access_type": "offline"])
    }

    @Test func authorizationURLCarriesPKCEAndState() throws {
        let url = OAuthFlow.authorizationURL(config: config, state: "STATE123", codeChallenge: "CHALLENGE")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(url.host == "auth.example.com")
        #expect(items["response_type"] == "code")
        #expect(items["client_id"] == "client 1")
        #expect(items["redirect_uri"] == "com.example.app:/cb")
        #expect(items["code_challenge"] == "CHALLENGE")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["state"] == "STATE123")
        #expect(items["scope"] == "files.read offline access")
        #expect(items["access_type"] == "offline")
        #expect(config.callbackScheme == "com.example.app")
    }

    @Test func callbackValidatesStateAndExtractsCode() throws {
        let ok = URL(string: "com.example.app:/cb?code=abc%2F123&state=S1")!
        #expect(try OAuthFlow.authorizationCode(from: ok, expectedState: "S1") == "abc/123")

        #expect(throws: CloudError.stateMismatch) {
            try OAuthFlow.authorizationCode(from: URL(string: "com.example.app:/cb?code=x&state=OTHER")!, expectedState: "S1")
        }
        #expect(throws: CloudError.stateMismatch) {
            try OAuthFlow.authorizationCode(from: URL(string: "com.example.app:/cb?code=x")!, expectedState: "S1")
        }
        #expect(throws: CloudError.signInCancelled) {
            try OAuthFlow.authorizationCode(from: URL(string: "com.example.app:/cb?error=access_denied&state=S1")!, expectedState: "S1")
        }
        #expect(throws: CloudError.authenticationFailed("boom")) {
            try OAuthFlow.authorizationCode(from: URL(string: "com.example.app:/cb?error=server_error&error_description=boom&state=S1")!, expectedState: "S1")
        }
    }

    @Test func tokenRequestsAreFormEncoded() {
        var withSecret = config
        withSecret.clientSecret = "sec ret"
        let exchange = OAuthFlow.tokenExchangeRequest(config: withSecret, code: "C&D", codeVerifier: "VERIFIER")
        #expect(exchange.httpMethod == "POST")
        #expect(exchange.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let body = String(decoding: exchange.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("code=C%26D"))
        #expect(body.contains("code_verifier=VERIFIER"))
        #expect(body.contains("client_secret=sec%20ret"))
        #expect(!body.contains("scope="))

        var microsoft = config
        microsoft.sendScopeWithTokenRequests = true
        let refresh = OAuthFlow.refreshRequest(config: microsoft, refreshToken: "RT")
        let refreshBody = String(decoding: refresh.httpBody ?? Data(), as: UTF8.self)
        #expect(refreshBody.contains("grant_type=refresh_token"))
        #expect(refreshBody.contains("refresh_token=RT"))
        #expect(refreshBody.contains("scope=files.read%20offline%20access"))
    }

    @Test func tokenResponseKeepsPreviousRefreshToken() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let previous = OAuthTokens(accessToken: "old", refreshToken: "KEEP", accountLabel: "me@example.com")
        let json = Data(#"{"access_token":"new","expires_in":3600,"token_type":"Bearer"}"#.utf8)
        let tokens = try OAuthFlow.parseTokenResponse(json, previous: previous, now: now)
        #expect(tokens.accessToken == "new")
        #expect(tokens.refreshToken == "KEEP")
        #expect(tokens.accountLabel == "me@example.com")
        #expect(tokens.expiresAt == now.addingTimeInterval(3600))

        let stringExpiry = Data(#"{"access_token":"a","refresh_token":"r2","expires_in":"120"}"#.utf8)
        let second = try OAuthFlow.parseTokenResponse(stringExpiry, previous: previous, now: now)
        #expect(second.refreshToken == "r2")
        #expect(second.expiresAt == now.addingTimeInterval(120))

        #expect(throws: CloudError.authenticationFailed("bad code")) {
            try OAuthFlow.parseTokenResponse(Data(#"{"error":"invalid_grant","error_description":"bad code"}"#.utf8), previous: nil, now: now)
        }
    }

    @Test func refreshLeewayMeansBeforeExpiry() {
        let now = Date()
        #expect(OAuthTokens(accessToken: "a", expiresAt: now.addingTimeInterval(30)).needsRefresh(at: now, leeway: 120))
        #expect(!OAuthTokens(accessToken: "a", expiresAt: now.addingTimeInterval(600)).needsRefresh(at: now, leeway: 120))
        #expect(!OAuthTokens(accessToken: "a", expiresAt: nil).needsRefresh(at: now))
    }

    @Test func inMemoryTokenStoreRoundTrip() throws {
        let store = InMemoryTokenStore()
        #expect(try store.loadTokens(for: "k") == nil)
        try store.saveTokens(OAuthTokens(accessToken: "a", refreshToken: "r"), for: "k")
        #expect(try store.loadTokens(for: "k")?.refreshToken == "r")
        try store.deleteTokens(for: "k")
        #expect(try store.loadTokens(for: "k") == nil)
    }
}
