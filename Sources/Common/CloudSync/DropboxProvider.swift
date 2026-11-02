import Foundation

/// Dropbox through API v2 (no Dropbox SDK).
///
/// - Sign-in: OAuth 2.0 + PKCE with `token_access_type=offline`, so the app gets a refresh token.
/// - Listing: `/2/files/list_folder` and `/2/files/list_folder/continue` (the cursor is the page token).
/// - Upload: `/2/files/upload` with `mode: update(rev)` for optimistic concurrency, or a chunked upload session
///   (`upload_session/start`, `append_v2`, `finish`) for files above `simpleUploadLimit`.
/// - The revision of a file is Dropbox's `rev`; its `content_hash` is reported as a `.dropbox` content hash.
public final class DropboxProvider: CloudStorageProvider {
    public let id: CloudProviderID = .dropbox
    public let displayName = "Dropbox"

    static let authorizationEndpoint = URL(string: "https://www.dropbox.com/oauth2/authorize")!
    static let tokenEndpoint = URL(string: "https://api.dropboxapi.com/oauth2/token")!
    static let rpcBase = "https://api.dropboxapi.com/2"
    static let contentBase = "https://content.dropboxapi.com/2"
    public static let defaultScopes = ["files.metadata.read", "files.metadata.write", "files.content.read", "files.content.write"]

    private let session: OAuthSession?
    private let http: AuthorizedHTTP?
    private let simpleUploadLimit: Int64
    private let chunkSize: Int

    /// - Parameters:
    ///   - simpleUploadLimit: files up to this size use one request (Dropbox allows at most 150 MB).
    ///   - chunkSize: bytes per request of a chunked upload.
    public init(configuration: CloudProviderConfiguration, tokenStore: TokenStore = KeychainTokenStore(),
                transport: HTTPTransport = HTTPTransport(), simpleUploadLimit: Int64 = 100 * 1024 * 1024,
                chunkSize: Int = 8 * 1024 * 1024) {
        self.simpleUploadLimit = simpleUploadLimit
        self.chunkSize = max(1024, chunkSize)
        let entry = configuration.dropbox
        if entry.isConfigured, let clientID = entry.trimmedClientID {
            let config = OAuthClientConfig(
                authorizationEndpoint: Self.authorizationEndpoint, tokenEndpoint: Self.tokenEndpoint,
                clientID: clientID, clientSecret: nil,
                redirectURI: entry.trimmedRedirectURI ?? Self.defaultRedirectURI(appKey: clientID),
                scopes: entry.scopes ?? Self.defaultScopes,
                extraAuthorizationParameters: ["token_access_type": "offline"])
            let session = OAuthSession(providerID: .dropbox, config: config, store: tokenStore,
                                       storeKey: "oauth.dropbox", transport: transport)
            self.session = session
            self.http = AuthorizedHTTP(session: session, transport: transport, providerID: .dropbox)
        } else {
            self.session = nil
            self.http = nil
        }
    }

    /// The redirect form Dropbox's own mobile SDKs use. Register exactly this in the Dropbox app console
    /// (Settings > OAuth 2 > Redirect URIs) unless you override `redirectURI` in CloudKeys.plist.
    public static func defaultRedirectURI(appKey: String) -> String { "db-\(appKey)://2/token" }

    // MARK: Auth

    public func authState() async -> CloudAuthState {
        guard let session else { return .notConfigured(hint: SetupHints.dropbox) }
        guard await session.isSignedIn else { return .signedOut }
        return .signedIn(account: await session.accountLabel)
    }

    public func signIn(using authenticator: any WebAuthenticator) async throws {
        guard let session, let http else { throw CloudError.notConfigured(hint: SetupHints.dropbox) }
        try await session.signIn(using: authenticator)
        // Needs the optional "account_info.read" scope; silently skipped when it was not granted.
        if let (data, response) = try? await http.data({ token in
            REST.request("POST", REST.url("\(Self.rpcBase)/users/get_current_account"), token: token)
        }), REST.isSuccess(response) {
            await session.setAccountLabel(REST.object(data)?["email"] as? String)
        }
    }

    public func signOut() async throws { try await session?.signOut() }

    private func authorized() throws -> AuthorizedHTTP {
        guard let http else { throw CloudError.notConfigured(hint: SetupHints.dropbox) }
        return http
    }

    // MARK: Helpers

    /// Dropbox wants "" for the root and "/a/b" otherwise.
    static func dropboxPath(_ path: CloudPath) -> String { path.isRoot ? "" : path.string }

    private func failure(_ response: HTTPURLResponse, _ data: Data, path: CloudPath) -> CloudError {
        let summary = (REST.object(data)?["error_summary"] as? String) ?? ""
        switch response.statusCode {
        case 401: return .notSignedIn(provider: id)
        case 409:
            if summary.contains("not_found") || summary.contains("not_folder") { return .notFound(path: path.string) }
            if summary.contains("conflict") { return .revisionMismatch(path: path.string) }
            return .http(status: 409, message: summary.isEmpty ? HTTPTransport.snippet(of: data) : summary)
        case 429: return .rateLimited(retryAfter: nil)
        default: return .http(status: response.statusCode, message: REST.message(from: data, status: response.statusCode))
        }
    }

    private func parse(_ object: [String: Any], at path: CloudPath) -> CloudItem? {
        guard let tag = object[".tag"] as? String else { return nil }
        let name = (object["name"] as? String) ?? path.name ?? ""
        let identifier = (object["id"] as? String) ?? path.string
        switch tag {
        case "folder":
            return CloudItem(id: identifier, path: path, name: name, kind: .folder)
        case "file":
            let hash = (object["content_hash"] as? String).map { CloudContentHash(algorithm: .dropbox, value: $0) }
            return CloudItem(id: identifier, path: path, name: name, kind: .file,
                             size: (object["size"] as? NSNumber)?.int64Value,
                             modified: REST.date(object["server_modified"] as? String),
                             revision: object["rev"] as? String, contentHash: hash)
        default:
            return nil // "deleted" entries and anything new Dropbox invents
        }
    }

    private func rpc(_ endpoint: String, _ body: [String: Any], path: CloudPath) async throws -> [String: Any] {
        let http = try authorized()
        let payload = try REST.json(body)
        let url = REST.url("\(Self.rpcBase)/\(endpoint)")
        let (data, response) = try await http.data { token in
            REST.request("POST", url, token: token, headers: ["Content-Type": "application/json"], body: payload)
        }
        guard REST.isSuccess(response) else { throw failure(response, data, path: path) }
        return REST.object(data) ?? [:]
    }

    // MARK: Listing and metadata

    public func listFolder(_ path: CloudPath, pageToken: String?) async throws -> CloudListPage {
        let object: [String: Any]
        if let pageToken {
            object = try await rpc("files/list_folder/continue", ["cursor": pageToken], path: path)
        } else {
            object = try await rpc("files/list_folder", [
                "path": Self.dropboxPath(path), "recursive": false, "include_deleted": false,
                "include_non_downloadable_files": false, "limit": 2000,
            ], path: path)
        }
        let entries = (object["entries"] as? [[String: Any]]) ?? []
        let items = entries.compactMap { entry -> CloudItem? in
            guard let name = entry["name"] as? String, !name.contains("/") else { return nil }
            return parse(entry, at: path.appending(name))
        }
        let hasMore = (object["has_more"] as? Bool) ?? false
        let cursor = object["cursor"] as? String
        return CloudListPage(items: items, nextPageToken: hasMore ? cursor : nil)
    }

    public func stat(_ path: CloudPath) async throws -> CloudItem? {
        if path.isRoot { return CloudItem(id: "", path: .root, name: "", kind: .folder) }
        do {
            let object = try await rpc("files/get_metadata", ["path": Self.dropboxPath(path), "include_deleted": false], path: path)
            return parse(object, at: path)
        } catch CloudError.notFound {
            return nil
        }
    }

    // MARK: Download

    public func download(_ path: CloudPath, to destination: URL) async throws -> CloudItem {
        let http = try authorized()
        let argument = try REST.asciiJSONHeader(["path": Self.dropboxPath(path)])
        let url = REST.url("\(Self.contentBase)/files/download")
        let (errorBody, response) = try await http.download(to: destination) { token in
            REST.request("POST", url, token: token, headers: ["Dropbox-API-Arg": argument])
        }
        guard REST.isSuccess(response) else { throw failure(response, errorBody, path: path) }
        if let result = response.value(forHTTPHeaderField: "Dropbox-API-Result"),
           let object = REST.object(Data(result.utf8)), let item = parse(object, at: path) {
            return item
        }
        guard let item = try await stat(path) else { throw CloudError.notFound(path: path.string) }
        return item
    }

    // MARK: Upload

    private func writeMode(_ precondition: UploadPrecondition) -> Any {
        switch precondition {
        case .none: return "overwrite"
        case .mustNotExist: return "add"
        case .revision(let rev): return [".tag": "update", "update": rev]
        }
    }

    public func upload(from source: URL, to path: CloudPath, precondition: UploadPrecondition) async throws -> CloudItem {
        let http = try authorized()
        guard !path.isRoot else { throw CloudError.fileSystem("Cannot upload over the Dropbox root.") }
        let total = try REST.fileSize(of: source)
        let commit: [String: Any] = [
            "path": Self.dropboxPath(path), "mode": writeMode(precondition), "autorename": false,
            "mute": true, "strict_conflict": true,
        ]

        let responseData: Data
        let response: HTTPURLResponse
        if total <= simpleUploadLimit {
            let argument = try REST.asciiJSONHeader(commit)
            let url = REST.url("\(Self.contentBase)/files/upload")
            (responseData, response) = try await http.upload(fromFile: source) { token in
                REST.request("POST", url, token: token,
                             headers: ["Dropbox-API-Arg": argument, "Content-Type": "application/octet-stream"])
            }
        } else {
            (responseData, response) = try await chunkedUpload(source: source, total: total, commit: commit, path: path)
        }
        guard REST.isSuccess(response) else { throw failure(response, responseData, path: path) }
        guard let object = REST.object(responseData) else {
            throw CloudError.invalidResponse("Dropbox did not return metadata for the uploaded file.")
        }
        // Defence in depth: if Dropbox silently renamed the file ("conflicted copy"), remove it and report the conflict.
        if let landed = object["path_lower"] as? String, landed != Self.dropboxPath(path).lowercased() {
            _ = try? await rpc("files/delete_v2", ["path": landed], path: path)
            throw CloudError.revisionMismatch(path: path.string)
        }
        guard let item = parse(object, at: path) else {
            throw CloudError.invalidResponse("Dropbox returned unreadable metadata for the uploaded file.")
        }
        return item
    }

    private func chunkedUpload(source: URL, total: Int64, commit: [String: Any], path: CloudPath) async throws -> (Data, HTTPURLResponse) {
        let http = try authorized()
        let contentType = ["Content-Type": "application/octet-stream"]

        // 1. start with the first chunk
        let first = try REST.readChunk(from: source, offset: 0, length: chunkSize)
        let startArgument = try REST.asciiJSONHeader(["close": false])
        let startURL = REST.url("\(Self.contentBase)/files/upload_session/start")
        let (startData, startResponse) = try await http.upload(data: first) { token in
            REST.request("POST", startURL, token: token, headers: contentType.merging(["Dropbox-API-Arg": startArgument]) { $1 })
        }
        guard REST.isSuccess(startResponse) else { throw failure(startResponse, startData, path: path) }
        guard let sessionID = REST.object(startData)?["session_id"] as? String else {
            throw CloudError.invalidResponse("Dropbox did not return an upload session.")
        }
        var offset = Int64(first.count)

        // 2. append the middle chunks
        let appendURL = REST.url("\(Self.contentBase)/files/upload_session/append_v2")
        while total - offset > Int64(chunkSize) {
            let chunk = try REST.readChunk(from: source, offset: offset, length: chunkSize)
            guard !chunk.isEmpty else { throw CloudError.fileSystem("\(source.lastPathComponent) shrank while uploading.") }
            let argument = try REST.asciiJSONHeader(["cursor": ["session_id": sessionID, "offset": offset] as [String: Any], "close": false] as [String: Any])
            let (data, response) = try await http.upload(data: chunk) { token in
                REST.request("POST", appendURL, token: token, headers: contentType.merging(["Dropbox-API-Arg": argument]) { $1 })
            }
            guard REST.isSuccess(response) else { throw failure(response, data, path: path) }
            offset += Int64(chunk.count)
        }

        // 3. finish with the remainder and commit
        let last = try REST.readChunk(from: source, offset: offset, length: Int(total - offset))
        let finishArgument = try REST.asciiJSONHeader([
            "cursor": ["session_id": sessionID, "offset": offset] as [String: Any], "commit": commit,
        ] as [String: Any])
        let finishURL = REST.url("\(Self.contentBase)/files/upload_session/finish")
        return try await http.upload(data: last) { token in
            REST.request("POST", finishURL, token: token, headers: contentType.merging(["Dropbox-API-Arg": finishArgument]) { $1 })
        }
    }

    // MARK: Folders and deletion

    public func createFolder(_ path: CloudPath) async throws -> CloudItem {
        if path.isRoot { return CloudItem(id: "", path: .root, name: "", kind: .folder) }
        do {
            let object = try await rpc("files/create_folder_v2", ["path": Self.dropboxPath(path), "autorename": false], path: path)
            if let metadata = object["metadata"] as? [String: Any], let item = parse(metadata, at: path) { return item }
            throw CloudError.invalidResponse("Dropbox did not return the new folder.")
        } catch CloudError.revisionMismatch {
            // 409 path/conflict: something is already there. Fine if it is a folder.
            guard let existing = try await stat(path), existing.kind == .folder else {
                throw CloudError.fileSystem("\(path.string) already exists and is not a folder.")
            }
            return existing
        }
    }

    public func delete(_ path: CloudPath) async throws {
        guard !path.isRoot else { throw CloudError.fileSystem("Refusing to delete the Dropbox root.") }
        _ = try await rpc("files/delete_v2", ["path": Self.dropboxPath(path)], path: path)
    }
}
