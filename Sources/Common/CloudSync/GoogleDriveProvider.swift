import Foundation

/// Google Drive through the REST API v3 (no Google SDK).
///
/// - Sign-in: OAuth 2.0 authorization-code flow with PKCE (installed-app flow), refresh tokens, via
///   `ASWebAuthenticationSession`.
/// - Drive identifies files by ID, not by path, so every path is resolved to an ID by walking the folder names
///   (results are cached and re-resolved if Drive says an ID no longer exists).
/// - Default scope is `drive.file`: the app only sees files it created itself, which needs no Google review.
///   Put `https://www.googleapis.com/auth/drive` in `scopes` to see the whole Drive.
/// - Drive has no "If-Match" for uploads, so the optimistic-concurrency check (`UploadPrecondition.revision`) is
///   done by comparing Drive's `version` number just before the upload (a small race window remains).
/// - Deleting moves the file to Drive's trash (recoverable) instead of erasing it.
public final class GoogleDriveProvider: CloudStorageProvider {
    public let id: CloudProviderID = .googleDrive
    public let displayName = "Google Drive"

    static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    static let filesEndpoint = "https://www.googleapis.com/drive/v3/files"
    static let uploadEndpoint = "https://www.googleapis.com/upload/drive/v3/files"
    static let aboutEndpoint = "https://www.googleapis.com/drive/v3/about"
    static let folderMimeType = "application/vnd.google-apps.folder"
    static let fileFields = "id,name,mimeType,size,modifiedTime,md5Checksum,version"
    public static let defaultScopes = ["https://www.googleapis.com/auth/drive.file"]

    private let oauthConfig: OAuthClientConfig?
    private let session: OAuthSession?
    private let http: AuthorizedHTTP?
    private let uploadChunkSize: Int
    private let idCache = IDCache()

    private actor IDCache {
        private var ids: [CloudPath: String] = [:]
        func id(for path: CloudPath) -> String? { ids[path] }
        func set(_ id: String, for path: CloudPath) { ids[path] = id }
        func removeSubtree(_ path: CloudPath) { ids = ids.filter { $0.key != path && !$0.key.isDescendant(of: path) } }
    }

    /// - Parameter uploadChunkSize: bytes per resumable-upload request (must be a multiple of 256 KiB).
    public init(configuration: CloudProviderConfiguration, tokenStore: TokenStore = KeychainTokenStore(),
                transport: HTTPTransport = HTTPTransport(), uploadChunkSize: Int = 8 * 1024 * 1024) {
        self.uploadChunkSize = max(256 * 1024, uploadChunkSize / (256 * 1024) * (256 * 1024))
        let entry = configuration.googleDrive
        if entry.isConfigured, let clientID = entry.trimmedClientID {
            let redirect = entry.trimmedRedirectURI ?? Self.defaultRedirectURI(clientID: clientID)
            let config = OAuthClientConfig(
                authorizationEndpoint: Self.authorizationEndpoint, tokenEndpoint: Self.tokenEndpoint,
                clientID: clientID, clientSecret: entry.secretOrNil, redirectURI: redirect,
                scopes: entry.scopes ?? Self.defaultScopes,
                extraAuthorizationParameters: ["access_type": "offline", "prompt": "consent"])
            let session = OAuthSession(providerID: .googleDrive, config: config, store: tokenStore,
                                       storeKey: "oauth.googleDrive", transport: transport)
            self.oauthConfig = config
            self.session = session
            self.http = AuthorizedHTTP(session: session, transport: transport, providerID: .googleDrive)
        } else {
            self.oauthConfig = nil
            self.session = nil
            self.http = nil
        }
    }

    /// Redirect URI Google expects for "iOS" type clients: the reversed client ID as a custom URL scheme.
    public static func defaultRedirectURI(clientID: String) -> String {
        let prefix = clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        return "com.googleusercontent.apps.\(prefix):/oauth2redirect"
    }

    // MARK: Auth

    public func authState() async -> CloudAuthState {
        guard let session else { return .notConfigured(hint: SetupHints.google) }
        guard await session.isSignedIn else { return .signedOut }
        return .signedIn(account: await session.accountLabel)
    }

    public func signIn(using authenticator: any WebAuthenticator) async throws {
        guard let session, let http else { throw CloudError.notConfigured(hint: SetupHints.google) }
        try await session.signIn(using: authenticator)
        if let (data, response) = try? await http.data({ token in
            REST.request("GET", REST.url(Self.aboutEndpoint, query: [("fields", "user(emailAddress,displayName)")]), token: token)
        }), REST.isSuccess(response), let user = REST.object(data)?["user"] as? [String: Any] {
            await session.setAccountLabel((user["emailAddress"] as? String) ?? (user["displayName"] as? String))
        }
    }

    public func signOut() async throws {
        try await session?.signOut()
        await idCache.removeSubtree(.root)
    }

    private func authorized() throws -> AuthorizedHTTP {
        guard let http else { throw CloudError.notConfigured(hint: SetupHints.google) }
        return http
    }

    // MARK: Errors and parsing

    private func failure(_ response: HTTPURLResponse, _ data: Data, path: CloudPath) -> CloudError {
        switch response.statusCode {
        case 404: return .notFound(path: path.string)
        case 401: return .notSignedIn(provider: id)
        case 412: return .revisionMismatch(path: path.string)
        case 403 where HTTPTransport.isRateLimit403(response, body: data): return .rateLimited(retryAfter: nil)
        default: return .http(status: response.statusCode, message: REST.message(from: data, status: response.statusCode))
        }
    }

    private func parse(_ object: [String: Any], parent: CloudPath) -> CloudItem? {
        guard let fileID = object["id"] as? String, let name = object["name"] as? String, !name.contains("/") else { return nil }
        let mime = object["mimeType"] as? String ?? ""
        let path = parent.appending(name)
        let modified = REST.date(object["modifiedTime"] as? String)
        if mime == Self.folderMimeType {
            return CloudItem(id: fileID, path: path, name: name, kind: .folder, modified: modified)
        }
        // Google Docs / Sheets / Slides have no downloadable bytes; they are not part of any project package.
        if mime.hasPrefix("application/vnd.google-apps.") { return nil }
        let md5 = (object["md5Checksum"] as? String).map { CloudContentHash(algorithm: .md5, value: $0) }
        return CloudItem(id: fileID, path: path, name: name, kind: .file,
                         size: (object["size"] as? String).flatMap { Int64($0) } ?? (object["size"] as? NSNumber)?.int64Value,
                         modified: modified, revision: stringValue(object["version"]), contentHash: md5)
    }

    private func stringValue(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    // MARK: Path -> ID

    private static func escapeQuery(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }

    private func findChild(named name: String, parentID: String, mustBeFolder: Bool) async throws -> (id: String, isFolder: Bool)? {
        let http = try authorized()
        var q = "'\(parentID)' in parents and name = '\(Self.escapeQuery(name))' and trashed = false"
        if mustBeFolder { q += " and mimeType = '\(Self.folderMimeType)'" }
        let url = REST.url(Self.filesEndpoint, query: [
            ("q", q), ("fields", "files(id,mimeType)"), ("pageSize", "10"), ("orderBy", "createdTime"), ("spaces", "drive"),
        ])
        let (data, response) = try await http.data { REST.request("GET", url, token: $0) }
        guard REST.isSuccess(response) else { throw failure(response, data, path: CloudPath(components: [name])) }
        guard let files = REST.object(data)?["files"] as? [[String: Any]], let first = files.first,
              let id = first["id"] as? String else { return nil }
        return (id, (first["mimeType"] as? String) == Self.folderMimeType)
    }

    /// - Parameter lastMustBeFolder: the final component has to be a folder (listing / uploading into it).
    private func resolveID(_ path: CloudPath, lastMustBeFolder: Bool = false) async throws -> String? {
        if path.isRoot { return "root" }
        if let cached = await idCache.id(for: path) { return cached }
        var parentID = "root"
        var current = CloudPath.root
        for component in path.components {
            current = current.appending(component)
            if let cached = await idCache.id(for: current) { parentID = cached; continue }
            guard let child = try await findChild(named: component, parentID: parentID, mustBeFolder: current != path || lastMustBeFolder) else {
                return nil
            }
            await idCache.set(child.id, for: current)
            parentID = child.id
        }
        return parentID
    }

    /// Runs `body` with the ID for `path`; if Drive says the cached ID is gone, forgets the cache and tries once more.
    private func withID<T>(_ path: CloudPath, folder: Bool = false, _ body: (String) async throws -> T) async throws -> T? {
        guard let first = try await resolveID(path, lastMustBeFolder: folder) else { return nil }
        do {
            return try await body(first)
        } catch CloudError.notFound {
            await idCache.removeSubtree(path)
            guard let second = try await resolveID(path, lastMustBeFolder: folder) else { return nil }
            return try await body(second)
        }
    }

    // MARK: Listing and metadata

    public func listFolder(_ path: CloudPath, pageToken: String?) async throws -> CloudListPage {
        let http = try authorized()
        let page: CloudListPage? = try await withID(path, folder: true) { folderID in
            var query: [(String, String)] = [
                ("q", "'\(folderID)' in parents and trashed = false"),
                ("fields", "nextPageToken,files(\(Self.fileFields))"),
                ("pageSize", "1000"), ("orderBy", "name"), ("spaces", "drive"),
            ]
            if let pageToken { query.append(("pageToken", pageToken)) }
            let url = REST.url(Self.filesEndpoint, query: query)
            let (data, response) = try await http.data { REST.request("GET", url, token: $0) }
            guard REST.isSuccess(response) else { throw failure(response, data, path: path) }
            guard let object = REST.object(data) else { throw CloudError.invalidResponse("Drive returned a listing that is not JSON.") }
            let files = (object["files"] as? [[String: Any]]) ?? []
            let items = files.compactMap { parse($0, parent: path) }
            for item in items { await idCache.set(item.id, for: item.path) }
            return CloudListPage(items: items, nextPageToken: (object["nextPageToken"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
        guard let page else { throw CloudError.notFound(path: path.string) }
        return page
    }

    public func stat(_ path: CloudPath) async throws -> CloudItem? {
        let http = try authorized()
        if path.isRoot { return CloudItem(id: "root", path: .root, name: "", kind: .folder) }
        return try await withID(path) { fileID in
            let url = REST.url("\(Self.filesEndpoint)/\(fileID)", query: [("fields", Self.fileFields), ("supportsAllDrives", "true")])
            let (data, response) = try await http.data { REST.request("GET", url, token: $0) }
            guard REST.isSuccess(response) else { throw failure(response, data, path: path) }
            guard let object = REST.object(data), let item = parse(object, parent: path.parent ?? .root) else {
                throw CloudError.invalidResponse("Drive returned unreadable metadata for \(path.string).")
            }
            return item
        }
    }

    // MARK: Download

    public func download(_ path: CloudPath, to destination: URL) async throws -> CloudItem {
        let http = try authorized()
        // Metadata first: its version is what we remember, and it is never newer than the bytes we fetch.
        guard let meta = try await stat(path), meta.kind == .file else { throw CloudError.notFound(path: path.string) }
        let url = REST.url("\(Self.filesEndpoint)/\(meta.id)", query: [("alt", "media"), ("supportsAllDrives", "true")])
        let (body, response) = try await http.download(to: destination) { REST.request("GET", url, token: $0) }
        guard REST.isSuccess(response) else {
            if response.statusCode == 404 { await idCache.removeSubtree(path) }
            throw failure(response, body, path: path)
        }
        return meta
    }

    // MARK: Upload

    public func upload(from source: URL, to path: CloudPath, precondition: UploadPrecondition) async throws -> CloudItem {
        let http = try authorized()
        guard let parent = path.parent, let name = path.name else {
            throw CloudError.fileSystem("Cannot upload over the Drive root.")
        }
        guard let parentID = try await resolveID(parent, lastMustBeFolder: true) else { throw CloudError.notFound(path: parent.string) }
        let existing = try await stat(path)
        if let existing, existing.kind == .folder { throw CloudError.fileSystem("\(path.string) is a folder.") }
        switch precondition {
        case .none: break
        case .mustNotExist:
            if existing != nil { throw CloudError.revisionMismatch(path: path.string) }
        case .revision(let expected):
            guard let existing, existing.revision == expected else { throw CloudError.revisionMismatch(path: path.string) }
        }

        let total = try REST.fileSize(of: source)
        let fields = Self.fileFields
        var initiateURL: URL
        var method: String
        var metadata: [String: Any]
        if let existing {
            initiateURL = REST.url("\(Self.uploadEndpoint)/\(existing.id)", query: [("uploadType", "resumable"), ("fields", fields), ("supportsAllDrives", "true")])
            method = "PATCH"
            metadata = [:]
        } else {
            initiateURL = REST.url(Self.uploadEndpoint, query: [("uploadType", "resumable"), ("fields", fields), ("supportsAllDrives", "true")])
            method = "POST"
            metadata = ["name": name, "parents": [parentID], "mimeType": "application/octet-stream"]
        }
        let metadataBody = try REST.json(metadata)
        let initiate = (initiateURL, method)
        let (initData, initResponse) = try await http.data { token in
            REST.request(initiate.1, initiate.0, token: token, headers: [
                "Content-Type": "application/json; charset=UTF-8",
                "X-Upload-Content-Type": "application/octet-stream",
                "X-Upload-Content-Length": String(total),
            ], body: metadataBody)
        }
        guard REST.isSuccess(initResponse) else { throw failure(initResponse, initData, path: path) }
        guard let location = initResponse.value(forHTTPHeaderField: "Location"), let sessionURL = URL(string: location),
              sessionURL.host == "www.googleapis.com" || sessionURL.host?.hasSuffix(".googleapis.com") == true else {
            throw CloudError.invalidResponse("Drive did not return a valid upload session address.")
        }

        var finalData = Data()
        if total <= Int64(uploadChunkSize) {
            let (data, response) = try await http.upload(fromFile: source) { token in
                REST.request("PUT", sessionURL, token: token, headers: ["Content-Type": "application/octet-stream"])
            }
            guard REST.isSuccess(response) else { throw failure(response, data, path: path) }
            finalData = data
        } else {
            var offset: Int64 = 0
            var stalls = 0
            while true {
                let chunk = try REST.readChunk(from: source, offset: offset, length: uploadChunkSize)
                guard !chunk.isEmpty else { throw CloudError.fileSystem("\(source.lastPathComponent) shrank while uploading.") }
                let end = offset + Int64(chunk.count) - 1
                let range = "bytes \(offset)-\(end)/\(total)"
                let (data, response) = try await http.upload(data: chunk) { token in
                    REST.request("PUT", sessionURL, token: token,
                                 headers: ["Content-Type": "application/octet-stream", "Content-Range": range])
                }
                if response.statusCode == 308 {
                    // "Resume incomplete": Range tells us how many bytes the server really holds.
                    let previous = offset
                    if let received = response.value(forHTTPHeaderField: "Range"),
                       let last = received.split(separator: "-").last.flatMap({ Int64($0) }) {
                        offset = last + 1
                    } else {
                        offset = 0
                    }
                    // A server that never moves forward must not keep us looping forever.
                    stalls = offset > previous ? 0 : stalls + 1
                    if stalls > 5 { throw CloudError.invalidResponse("Drive keeps asking for the same part of the file.") }
                    continue
                }
                guard REST.isSuccess(response) else { throw failure(response, data, path: path) }
                finalData = data
                break
            }
        }
        guard let object = REST.object(finalData), let item = parse(object, parent: parent) else {
            throw CloudError.invalidResponse("Drive did not return metadata for the uploaded file.")
        }
        await idCache.set(item.id, for: path)
        return item
    }

    // MARK: Folders and deletion

    public func createFolder(_ path: CloudPath) async throws -> CloudItem {
        let http = try authorized()
        if path.isRoot { return CloudItem(id: "root", path: .root, name: "", kind: .folder) }
        var parentID = "root"
        var last: CloudItem?
        for prefix in path.prefixes {
            if let cached = await idCache.id(for: prefix) {
                parentID = cached
                last = CloudItem(id: cached, path: prefix, kind: .folder)
                continue
            }
            if let child = try await findChild(named: prefix.name ?? "", parentID: parentID, mustBeFolder: true) {
                await idCache.set(child.id, for: prefix)
                parentID = child.id
                last = CloudItem(id: child.id, path: prefix, kind: .folder)
                continue
            }
            let body = try REST.json(["name": prefix.name ?? "", "mimeType": Self.folderMimeType, "parents": [parentID]] as [String: Any])
            let url = REST.url(Self.filesEndpoint, query: [("fields", Self.fileFields), ("supportsAllDrives", "true")])
            let (data, response) = try await http.data { token in
                REST.request("POST", url, token: token, headers: ["Content-Type": "application/json; charset=UTF-8"], body: body)
            }
            guard REST.isSuccess(response) else { throw failure(response, data, path: prefix) }
            guard let object = REST.object(data), let item = parse(object, parent: prefix.parent ?? .root) else {
                throw CloudError.invalidResponse("Drive did not return the new folder.")
            }
            await idCache.set(item.id, for: prefix)
            parentID = item.id
            last = item
        }
        guard let last else { throw CloudError.invalidResponse("Drive did not create \(path.string).") }
        return last
    }

    public func delete(_ path: CloudPath) async throws {
        let http = try authorized()
        guard !path.isRoot else { throw CloudError.fileSystem("Refusing to delete the Drive root.") }
        let body = try REST.json(["trashed": true] as [String: Any])
        let done: Bool? = try await withID(path) { fileID in
            let url = REST.url("\(Self.filesEndpoint)/\(fileID)", query: [("fields", "id"), ("supportsAllDrives", "true")])
            let (data, response) = try await http.data { token in
                REST.request("PATCH", url, token: token, headers: ["Content-Type": "application/json; charset=UTF-8"], body: body)
            }
            guard REST.isSuccess(response) else { throw failure(response, data, path: path) }
            return true
        }
        await idCache.removeSubtree(path)
        guard done != nil else { throw CloudError.notFound(path: path.string) }
    }
}
