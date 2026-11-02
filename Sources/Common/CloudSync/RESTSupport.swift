import Foundation

/// Small helpers shared by the Google Drive, Dropbox and OneDrive providers.
enum REST {
    static func request(_ method: String, _ url: URL, token: String?, headers: [String: String] = [:],
                        body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body
        return request
    }

    static func url(_ base: String, query: [(String, String)] = []) -> URL {
        let text = query.isEmpty ? base : base + (base.contains("?") ? "&" : "?") + FormEncoding.query(query)
        // Only fails for a malformed base string, which would be a programming error in this file.
        return URL(string: text) ?? URL(string: "https://invalid.invalid/")!
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func json(_ object: Any, sortedKeys: Bool = true) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: sortedKeys ? [.sortedKeys, .withoutEscapingSlashes] : [.withoutEscapingSlashes])
    }

    /// JSON for a `Dropbox-API-Arg` style header: HTTP headers must be ASCII, so every non-ASCII character is
    /// written as a \uXXXX escape (surrogate pairs above U+FFFF).
    static func asciiJSONHeader(_ object: Any) throws -> String {
        let data = try json(object)
        var out = ""
        for scalar in String(decoding: data, as: UTF8.self).unicodeScalars {
            if scalar.value < 0x80 {
                out.unicodeScalars.append(scalar)
            } else if scalar.value <= 0xFFFF {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                let value = scalar.value - 0x10000
                out += String(format: "\\u%04x\\u%04x", 0xD800 + (value >> 10), 0xDC00 + (value & 0x3FF))
            }
        }
        return out
    }

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
        return try? Date(text, strategy: Date.ISO8601FormatStyle())
    }

    static func fileSize(of url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes[.size] as? NSNumber)?.int64Value else {
            throw CloudError.fileSystem("Cannot read the size of \(url.lastPathComponent).")
        }
        return size
    }

    /// Reads `length` bytes starting at `offset` (fewer at the end of the file).
    static func readChunk(from url: URL, offset: Int64, length: Int) throws -> Data {
        guard length > 0 else { return Data() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        var chunk = Data()
        while chunk.count < length {
            guard let piece = try handle.read(upToCount: length - chunk.count), !piece.isEmpty else { break }
            chunk.append(piece)
        }
        return chunk
    }

    static func isSuccess(_ response: HTTPURLResponse) -> Bool { (200..<300).contains(response.statusCode) }

    /// Best human-readable message found in an error body.
    static func message(from data: Data, status: Int) -> String {
        if let object = object(data) {
            if let summary = object["error_summary"] as? String { return summary }
            if let error = object["error"] as? [String: Any] {
                if let message = error["message"] as? String { return message }
                if let code = error["code"] as? String { return code }
            }
            if let error = object["error"] as? String { return (object["error_description"] as? String) ?? error }
        }
        let text = HTTPTransport.snippet(of: data)
        return text.isEmpty ? "HTTP \(status)" : text
    }
}

/// Setup text shown through `CloudAuthState.notConfigured(hint:)`.
enum SetupHints {
    static let google = "Google Drive isn't set up yet. Register an OAuth client at https://console.cloud.google.com/apis/credentials (enable the Google Drive API; client type \"iOS\" works on Mac and iPad, with your app's bundle ID) and put the client ID in CloudKeys.plist under googleDrive > clientID."
    static let dropbox = "Dropbox isn't set up yet. Register an app at https://www.dropbox.com/developers/apps (Scoped access; enable files.metadata.read/write and files.content.read/write; add the redirect URI shown in the sample CloudKeys.plist) and put the app key in CloudKeys.plist under dropbox > clientID."
    static let oneDrive = "OneDrive isn't set up yet. Register an app at https://entra.microsoft.com (App registrations > New registration, accounts in any directory and personal Microsoft accounts; add a \"Mobile and desktop\" redirect URI) and put the Application (client) ID in CloudKeys.plist under oneDrive > clientID."
}
