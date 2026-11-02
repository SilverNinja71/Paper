import Foundation

/// The OAuth client IDs / app keys the developer registers once per service.
///
/// Keep them in a property list called `CloudKeys.plist` inside the app's Application Support folder
/// (`~/Library/Application Support/<AppName>/CloudKeys.plist`) or in the app bundle, or build the value in code.
/// A missing or placeholder value is not an error: the matching provider simply reports `.notConfigured(hint:)`.
public struct CloudProviderConfiguration: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        /// Google "client ID", Dropbox "app key", Microsoft "Application (client) ID".
        public var clientID: String?
        /// Only for Google "Desktop app" OAuth clients (not really secret; Google requires sending it).
        public var clientSecret: String?
        /// Optional override; a sensible default is derived from the client ID / bundle ID (see each provider).
        public var redirectURI: String?
        /// Optional override of the default scopes.
        public var scopes: [String]?
        /// Microsoft only: "common" (default), "consumers", "organizations" or a tenant ID.
        public var tenant: String?

        public init(clientID: String? = nil, clientSecret: String? = nil, redirectURI: String? = nil,
                    scopes: [String]? = nil, tenant: String? = nil) {
            self.clientID = clientID
            self.clientSecret = clientSecret
            self.redirectURI = redirectURI
            self.scopes = scopes
            self.tenant = tenant
        }

        /// True when `clientID` holds a real-looking value (not empty, not a "YOUR_..." / "<...>" placeholder).
        public var isConfigured: Bool {
            guard let id = clientID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return false }
            let upper = id.uppercased()
            if upper.hasPrefix("YOUR_") || upper.hasPrefix("YOUR-") || upper.contains("PLACEHOLDER") { return false }
            if id.hasPrefix("<") && id.hasSuffix(">") { return false }
            return true
        }

        var trimmedClientID: String? { clientID?.trimmingCharacters(in: .whitespacesAndNewlines) }
        var trimmedRedirectURI: String? {
            guard let value = redirectURI?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        var secretOrNil: String? {
            guard let value = clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
                  !value.uppercased().hasPrefix("YOUR_") else { return nil }
            return value
        }
    }

    public var googleDrive: Entry
    public var dropbox: Entry
    public var oneDrive: Entry

    public init(googleDrive: Entry = Entry(), dropbox: Entry = Entry(), oneDrive: Entry = Entry()) {
        self.googleDrive = googleDrive
        self.dropbox = dropbox
        self.oneDrive = oneDrive
    }

    public static let fileName = "CloudKeys.plist"

    // MARK: Loading

    /// `~/Library/Application Support/<appFolderName>/CloudKeys.plist` (nil if Application Support is unavailable).
    public static func defaultFileURL(appFolderName: String) -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(appFolderName, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    public static func load(from url: URL) throws -> CloudProviderConfiguration {
        let data = try Data(contentsOf: url)
        return try PropertyListDecoder().decode(CloudProviderConfiguration.self, from: data)
    }

    /// Looks for `CloudKeys.plist` in Application Support, then in `bundle`. Never throws: when nothing usable is
    /// found you get an empty configuration and every provider reports `.notConfigured`.
    public static func loadDefault(appFolderName: String, bundle: Bundle = .main) -> CloudProviderConfiguration {
        var candidates: [URL] = []
        if let url = defaultFileURL(appFolderName: appFolderName) { candidates.append(url) }
        if let url = bundle.url(forResource: "CloudKeys", withExtension: "plist") { candidates.append(url) }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let configuration = try? load(from: url) { return configuration }
        }
        return CloudProviderConfiguration()
    }

    public func write(to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// A ready-to-fill file with placeholder values (which count as "not configured").
    public static var template: CloudProviderConfiguration {
        CloudProviderConfiguration(
            googleDrive: Entry(clientID: "YOUR_GOOGLE_CLIENT_ID.apps.googleusercontent.com"),
            dropbox: Entry(clientID: "YOUR_DROPBOX_APP_KEY"),
            oneDrive: Entry(clientID: "YOUR_MICROSOFT_APPLICATION_CLIENT_ID"))
    }
}

/// Convenience for building the standard set of providers from one configuration.
public enum CloudProviderCatalog {
    /// Google Drive, Dropbox, OneDrive and iCloud Drive. Folder providers (external drives, File Provider
    /// folders) are created on demand with `LocalFolderProvider`.
    public static func standardProviders(configuration: CloudProviderConfiguration,
                                         tokenStore: TokenStore = KeychainTokenStore(),
                                         transport: HTTPTransport = HTTPTransport()) -> [any CloudStorageProvider] {
        [
            GoogleDriveProvider(configuration: configuration, tokenStore: tokenStore, transport: transport),
            DropboxProvider(configuration: configuration, tokenStore: tokenStore, transport: transport),
            OneDriveProvider(configuration: configuration, tokenStore: tokenStore, transport: transport),
            ICloudDriveProvider(),
        ]
    }
}
