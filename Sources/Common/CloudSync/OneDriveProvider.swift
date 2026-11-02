import Foundation

/// OneDrive through Microsoft Graph (no MSAL).
///
/// - Sign-in: OAuth 2.0 + PKCE straight against `login.microsoftonline.com/common/oauth2/v2.0`,
///   scopes `Files.ReadWrite offline_access`.
/// - Addressing: `/me/drive/root:/path:/children`, `/content`, ...
/// - Upload: simple `PUT .../content` up to 4 MiB, otherwise `createUploadSession` + `Content-Range` chunks
///   (multiples of 320 KiB). Optimistic concurrency uses `If-Match: <eTag>`; creating-only uses
///   `@microsoft.graph.conflictBehavior=fail`.
/// - The revision of a file is its `eTag`.
public final class OneDriveProvider: CloudStorageProvider {
    public let id: CloudProviderID = .oneDrive
    public let displayName = "OneDrive"

    static let graphBase = "https://graph.microsoft.com/v1.0"
    public static let defaultScopes = ["Files.ReadWrite", "offline_access"]
    static let itemFields = "id,name,size,eTag,lastModifiedDateTime,file,folder,deleted"

    private let session: OAuthSession?
    private let http: AuthorizedHTTP?
    private let transport: HTTPTransport
    private let simpleUploadLimit: Int64
    private let chunkSize: Int

    /// - Parameter chunkSize: bytes per upload-session request; rounded to a multiple of 320 KiB as Graph requires.
    public init(configuration: CloudProviderConfiguration, tokenStore: TokenStore = KeychainTokenStore(),
                transport: HTTPTransport = HTTPTransport(), simpleUploadLimit: Int64 = 4 * 1024 * 1024,
                chunkSize: Int = 10 * 320 * 1024) {
        self.transport = transport
        self.simpleUploadLimit = simpleUploadLimit
        self.chunkSize = max(320 * 1024, chunkSize / (320 * 1024) * (320 * 1024))
        let entry = configuration.oneDrive
        if entry.isConfigured, let clientID = entry.trimmedClientID {
            let tenant = entry.tenant?.trimmingCharacters(in: .whitespaces).nonEmpty ?? "common"
            let base = "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0"
            let config = OAuthClientConfig(
                authorizationEndpoint: URL(string: base + "/authorize")!, tokenEndpoint: URL(string: base + "/token")!,
                clientID: clientID, clientSecret: nil,
                redirectURI: entry.trimmedRedirectURI ?? Self.defaultRedirectURI(),
                scopes: entry.scopes ?? Self.defaultScopes,
                extraAuthorizationParameters: ["response_mode": "query"],
                sendScopeWithTokenRequests: true)
            let session = OAuthSession(providerID: .oneDrive, config: config, store: tokenStore,
                                       storeKey: "oauth.oneDrive", transport: transport)
            self.session = session
            self.http = AuthorizedHTTP(session: session, transport: transport, providerID: .oneDrive)
        } else {
            self.session = nil
            self.http = nil
        }
    }

    /// `msauth.<bundle id>://auth`, the form the Azure portal suggests for "Mobile and desktop" apps.
    /// Register exactly this in the app registration (Authentication > Add a platform > Mobile and desktop).
    public static func defaultRedirectURI(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String {
        "msauth.\(bundleIdentifier ?? "app.forgepaper")://auth"
    }

    // MARK: Auth

    public func authState() async -> CloudAuthState {
        guard let session else { return .notConfigured(hint: SetupHints.oneDrive) }
        guard await session.isSignedIn else { return .signedOut }
        return .signedIn(account: await session.accountLabel)
    }

    public func signIn(using authenticator: any WebAuthenticator) async throws {
        guard let session, let http else { throw CloudError.notConfigured(hint: SetupHints.oneDrive) }
        try await session.signIn(using: authenticator)
        if let (data, response) = try? await http.data({ token in
            REST.request("GET", REST.url("\(Self.graphBase)/me/drive", query: [("$select", "id,owner")]), token: token)
        }), REST.isSuccess(response),
           let owner = (REST.object(data)?["owner"] as? [String: Any])?["user"] as? [String: Any] {
            await session.setAccountLabel((owner["email"] as? String) ?? (owner["displayName"] as? String))
        }
    }

    public func signOut() async throws { try await session?.signOut() }

    private func authorized() throws -> AuthorizedHTTP {
        guard let http else { throw CloudError.notConfigured(hint: SetupHints.oneDrive) }
        return http
    }

    // MARK: URLs and parsing

    /// `.../me/drive/root` for the root, otherwise `.../me/drive/root:/a/b:` + optional `/suffix`.
    static func itemURL(_ path: CloudPath, suffix: String? = nil, query: [(String, String)] = []) -> URL {
        var text = graphBase + "/me/drive/root"
        if path.isRoot {
            if let suffix { text += "/" + suffix }
        } else {
            text += ":/" + FormEncoding.encodePath(path.components) + ":"
            if let suffix { text += "/" + suffix }
        }
        return REST.url(text, query: query)
    }

    private func failure(_ response: HTTPURLResponse, _ data: Data, path: CloudPath) -> CloudError {
        switch response.statusCode {
        case 401: return .notSignedIn(provider: id)
        case 404: return .notFound(path: path.string)
        case 412: return .revisionMismatch(path: path.string)
        case 409:
            let code = ((REST.object(data)?["error"] as? [String: Any])?["code"] as? String) ?? ""
            if code == "nameAlreadyExists" || code == "resourceModified" || code == "conflict" || code.isEmpty {
                return .revisionMismatch(path: path.string)
            }
            return .http(status: 409, message: REST.message(from: data, status: 409))
        case 429: return .rateLimited(retryAfter: HTTPRetryPolicy.parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After")))
        default: return .http(status: response.statusCode, message: REST.message(from: data, status: response.statusCode))
        }
    }

    private func parse(_ object: [String: Any], at path: CloudPath) -> CloudItem? {
        if object["deleted"] != nil { return nil }
        guard let identifier = object["id"] as? String else { return nil }
        let name = (object["name"] as? String) ?? path.name ?? ""
        let modified = REST.date(object["lastModifiedDateTime"] as? String)
        if object["folder"] != nil {
            return CloudItem(id: identifier, path: path, name: name, kind: .folder, modified: modified)
        }
        guard let file = object["file"] as? [String: Any] else { return nil } // OneNote packages etc.
        var hash: CloudContentHash?
        if let hashes = file["hashes"] as? [String: Any] {
            if let sha256 = hashes["sha256Hash"] as? String { hash = CloudContentHash(algorithm: .sha256, value: sha256) }
            else if let sha1 = hashes["sha1Hash"] as? String { hash = CloudContentHash(algorithm: .sha1, value: sha1) }
        }
        return CloudItem(id: identifier, path: path, name: name, kind: .file,
                         size: (object["size"] as? NSNumber)?.int64Value, modified: modified,
                         revision: object["eTag"] as? String, contentHash: hash)
    }

    // MARK: Listing and metadata

    public func listFolder(_ path: CloudPath, pageToken: String?) async throws -> CloudListPage {
        let http = try authorized()
        let url: URL
        if let pageToken {
            // The next-page link must stay on Graph: never send our bearer token anywhere else.
            guard let next = URL(string: pageToken), next.scheme == "https", next.host == "graph.microsoft.com" else {
                throw CloudError.invalidResponse("OneDrive returned a page link that does not point to Microsoft Graph.")
            }
            url = next
        } else {
            url = Self.itemURL(path, suffix: "children", query: [("$top", "200"), ("$select", Self.itemFields)])
        }
        let (data, response) = try await http.data { REST.request("GET", url, token: $0) }
        guard REST.isSuccess(response) else { throw failure(response, data, path: path) }
        guard let object = REST.object(data) else { throw CloudError.invalidResponse("OneDrive returned a listing that is not JSON.") }
        let values = (object["value"] as? [[String: Any]]) ?? []
        let items = values.compactMap { entry -> CloudItem? in
            guard let name = entry["name"] as? String, !name.contains("/") else { return nil }
            return parse(entry, at: path.appending(name))
        }
        return CloudListPage(items: items, nextPageToken: object["@odata.nextLink"] as? String)
    }

    public func stat(_ path: CloudPath) async throws -> CloudItem? {
        let http = try authorized()
        let url = Self.itemURL(path, query: [("$select", Self.itemFields)])
        let (data, response) = try await http.data { REST.request("GET", url, token: $0) }
        if response.statusCode == 404 { return nil }
        guard REST.isSuccess(response) else { throw failure(response, data, path: path) }
        guard let object = REST.object(data) else { throw CloudError.invalidResponse("OneDrive returned unreadable metadata.") }
        if path.isRoot { return CloudItem(id: (object["id"] as? String) ?? "root", path: .root, name: "", kind: .folder) }
        return parse(object, at: path)
    }

    // MARK: Download

    public func download(_ path: CloudPath, to destination: URL) async throws -> CloudItem {
        let http = try authorized()
        // eTag first (it is never newer than the bytes); /content answers with a redirect to a pre-signed URL.
        guard let meta = try await stat(path), meta.kind == .file else { throw CloudError.notFound(path: path.string) }
        let url = Self.itemURL(path, suffix: "content")
        let (body, response) = try await http.download(to: destination) { REST.request("GET", url, token: $0) }
        guard REST.isSuccess(response) else { throw failure(response, body, path: path) }
        return meta
    }

    // MARK: Upload

    public func upload(from source: URL, to path: CloudPath, precondition: UploadPrecondition) async throws -> CloudItem {
        let http = try authorized()
        guard !path.isRoot, let name = path.name else { throw CloudError.fileSystem("Cannot upload over the OneDrive root.") }
        let total = try REST.fileSize(of: source)

        var conflictBehavior = "replace"
        var ifMatch: String?
        switch precondition {
        case .none: break
        case .mustNotExist: conflictBehavior = "fail"
        case .revision(let etag): ifMatch = etag
        }

        let data: Data
        let response: HTTPURLResponse
        if total <= simpleUploadLimit {
            let url = Self.itemURL(path, suffix: "content", query: [("@microsoft.graph.conflictBehavior", conflictBehavior)])
            let match = ifMatch
            (data, response) = try await http.upload(fromFile: source) { token in
                var headers = ["Content-Type": "application/octet-stream"]
                if let match { headers["If-Match"] = match }
                return REST.request("PUT", url, token: token, headers: headers)
            }
        } else {
            (data, response) = try await sessionUpload(source: source, total: total, path: path, name: name,
                                                       conflictBehavior: conflictBehavior, ifMatch: ifMatch)
        }
        guard REST.isSuccess(response) else { throw failure(response, data, path: path) }
        guard let object = REST.object(data), let item = parse(object, at: path) else {
            throw CloudError.invalidResponse("OneDrive did not return metadata for the uploaded file.")
        }
        return item
    }

    private func sessionUpload(source: URL, total: Int64, path: CloudPath, name: String, conflictBehavior: String,
                               ifMatch: String?) async throws -> (Data, HTTPURLResponse) {
        let http = try authorized()
        let body = try REST.json(["item": ["@microsoft.graph.conflictBehavior": conflictBehavior, "name": name] as [String: Any]] as [String: Any])
        let createURL = Self.itemURL(path, suffix: "createUploadSession")
        let (sessionData, sessionResponse) = try await http.data { token in
            var headers = ["Content-Type": "application/json"]
            if let ifMatch { headers["If-Match"] = ifMatch }
            return REST.request("POST", createURL, token: token, headers: headers, body: body)
        }
        guard REST.isSuccess(sessionResponse) else { throw failure(sessionResponse, sessionData, path: path) }
        guard let address = REST.object(sessionData)?["uploadUrl"] as? String, let uploadURL = URL(string: address),
              uploadURL.scheme == "https" else {
            throw CloudError.invalidResponse("OneDrive did not return an upload session address.")
        }

        // The upload URL is pre-authorised: adding our bearer token to it makes the storage servers reject the call.
        var offset: Int64 = 0
        var stalls = 0
        while true {
            let chunk = try REST.readChunk(from: source, offset: offset, length: chunkSize)
            guard !chunk.isEmpty else { throw CloudError.fileSystem("\(source.lastPathComponent) shrank while uploading.") }
            let end = offset + Int64(chunk.count) - 1
            let request = REST.request("PUT", uploadURL, token: nil, headers: [
                "Content-Range": "bytes \(offset)-\(end)/\(total)",
                "Content-Type": "application/octet-stream",
            ])
            let (data, response) = try await transport.upload(request, from: chunk)
            if response.statusCode == 202 {
                // Accepted; the next expected range tells us where to continue (usually right after this chunk).
                let previous = offset
                let ranges = REST.object(data)?["nextExpectedRanges"] as? [String]
                if let start = ranges?.first?.split(separator: "-").first.flatMap({ Int64($0) }) { offset = start }
                else { offset = end + 1 }
                // A server that never moves forward must not keep us looping forever.
                stalls = offset > previous ? 0 : stalls + 1
                if stalls > 5 { throw CloudError.invalidResponse("OneDrive keeps asking for the same part of the file.") }
                continue
            }
            return (data, response)
        }
    }

    // MARK: Folders and deletion

    public func createFolder(_ path: CloudPath) async throws -> CloudItem {
        let http = try authorized()
        if path.isRoot { return CloudItem(id: "root", path: .root, name: "", kind: .folder) }
        if let existing = try await stat(path) {
            guard existing.kind == .folder else { throw CloudError.fileSystem("\(path.string) already exists and is not a folder.") }
            return existing
        }
        var last: CloudItem?
        var createdParent = false // below a folder we just created nothing can exist yet
        for prefix in path.prefixes {
            if !createdParent, let existing = try await stat(prefix) {
                guard existing.kind == .folder else { throw CloudError.fileSystem("\(prefix.string) already exists and is not a folder.") }
                last = existing
                continue
            }
            let parent = prefix.parent ?? .root
            let body = try REST.json(["name": prefix.name ?? "", "folder": [String: Any](),
                                      "@microsoft.graph.conflictBehavior": "fail"] as [String: Any])
            let url = Self.itemURL(parent, suffix: "children")
            let (data, response) = try await http.data { token in
                REST.request("POST", url, token: token, headers: ["Content-Type": "application/json"], body: body)
            }
            if response.statusCode == 409, let existing = try await stat(prefix), existing.kind == .folder {
                last = existing // somebody created it a moment ago
                continue
            }
            guard REST.isSuccess(response) else { throw failure(response, data, path: prefix) }
            guard let object = REST.object(data), let item = parse(object, at: prefix) else {
                throw CloudError.invalidResponse("OneDrive did not return the new folder.")
            }
            last = item
            createdParent = true
        }
        guard let last else { throw CloudError.invalidResponse("OneDrive did not create \(path.string).") }
        return last
    }

    public func delete(_ path: CloudPath) async throws {
        let http = try authorized()
        guard !path.isRoot else { throw CloudError.fileSystem("Refusing to delete the OneDrive root.") }
        let url = Self.itemURL(path)
        let (data, response) = try await http.data { REST.request("DELETE", url, token: $0) }
        guard REST.isSuccess(response) else { throw failure(response, data, path: path) }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
