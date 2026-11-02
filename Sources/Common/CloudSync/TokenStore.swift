import Foundation
import Security

/// OAuth tokens for one signed-in account.
public struct OAuthTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    /// When the access token stops working. Nil means "no expiry information" (treated as valid).
    public var expiresAt: Date?
    public var tokenType: String
    public var scope: String?
    /// Human readable account name (e-mail), filled in after sign-in when the service allows it.
    public var accountLabel: String?

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil,
                tokenType: String = "Bearer", scope: String? = nil, accountLabel: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.tokenType = tokenType
        self.scope = scope
        self.accountLabel = accountLabel
    }

    /// True when the token is expired or will be within `leeway` seconds (we refresh *before* expiry).
    public func needsRefresh(at date: Date, leeway: TimeInterval = 120) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(date) <= leeway
    }
}

/// Where OAuth tokens are kept between launches. Implementations must be safe to call from any thread.
public protocol TokenStore: Sendable {
    func loadTokens(for key: String) throws -> OAuthTokens?
    func saveTokens(_ tokens: OAuthTokens, for key: String) throws
    func deleteTokens(for key: String) throws
}

/// Keeps tokens in memory only. Used by tests and by apps that do not want to persist sign-in.
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: OAuthTokens] = [:]

    public init(_ initial: [String: OAuthTokens] = [:]) { storage = initial }

    public func loadTokens(for key: String) throws -> OAuthTokens? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    public func saveTokens(_ tokens: OAuthTokens, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key] = tokens
    }

    public func deleteTokens(for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key] = nil
    }

    public var keys: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage.keys.sorted()
    }
}

/// Stores tokens as generic-password Keychain items (`kSecClassGenericPassword`,
/// accessible after first unlock so background syncs work while the device is locked).
public struct KeychainTokenStore: TokenStore {
    public let service: String
    public let accessGroup: String?

    public init(service: String = "app.forgepaper.cloudsync", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func baseQuery(for key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    public func loadTokens(for key: String) throws -> OAuthTokens? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CloudError.keychain(status: status) }
        return try JSONDecoder().decode(OAuthTokens.self, from: data)
    }

    public func saveTokens(_ tokens: OAuthTokens, for key: String) throws {
        let data = try JSONEncoder().encode(tokens)
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery(for: key) as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw CloudError.keychain(status: updateStatus) }

        var add = baseQuery(for: key)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw CloudError.keychain(status: addStatus) }
    }

    public func deleteTokens(for key: String) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CloudError.keychain(status: status) }
    }
}
