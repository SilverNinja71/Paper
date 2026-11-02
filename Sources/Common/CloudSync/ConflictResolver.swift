import Foundation

/// Which side keeps the original project name when both the local and the remote copy changed.
/// The other side is never deleted: it is branched into a sibling "Conflicted Copy" package.
public enum ConflictPolicy: String, Codable, Sendable, CaseIterable {
    /// The copy that was modified most recently keeps the name (ties go to the remote copy).
    case newerWins
    /// This device's copy always keeps the name; the cloud version becomes the Conflicted Copy.
    case keepLocal
    /// The cloud version always keeps the name; this device's version becomes the Conflicted Copy.
    case keepRemote
}

/// Pure helpers for conflicts: naming the branched copy and choosing the winner.
public enum ConflictResolver {
    public static let marker = "Conflicted Copy"

    public enum Side: Sendable, Equatable { case local, remote }

    /// `MyArt.paper` + 2026-10-26 14:30:05 -> `MyArt (Conflicted Copy 2026-10-26 14.30.05).paper`.
    ///
    /// - The extension is kept.
    /// - A conflicted copy of a conflicted copy is named after the original project (no growing chains).
    /// - If the name is already taken (compared case-insensitively, like the default macOS file system),
    ///   a counter is added: `... 14.30.05 2).paper`, `... 14.30.05 3).paper`, ...
    public static func conflictedCopyName(for packageName: String, date: Date, existingNames: Set<String>,
                                          timeZone: TimeZone = .current) -> String {
        let (stem, ext) = split(packageName)
        let base = "\(stripMarker(from: stem)) (\(marker) \(timestamp(date, timeZone: timeZone))"
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        let taken = Set(existingNames.map { $0.lowercased() })

        var candidate = "\(base))\(suffix)"
        var counter = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(base) \(counter))\(suffix)"
            counter += 1
        }
        return candidate
    }

    /// "yyyy-MM-dd HH.mm.ss" (dots instead of colons: colons are not valid in file names on every platform).
    public static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02d %02d.%02d.%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// True for names produced by `conflictedCopyName`.
    public static func isConflictedCopyName(_ packageName: String) -> Bool {
        stripMarker(from: split(packageName).stem) != split(packageName).stem
    }

    /// Chooses who keeps the original name.
    public static func winner(policy: ConflictPolicy, localModified: Date?, remoteModified: Date?) -> Side {
        switch policy {
        case .keepLocal: return .local
        case .keepRemote: return .remote
        case .newerWins:
            switch (localModified, remoteModified) {
            case let (local?, remote?): return local > remote ? .local : .remote
            case (.some, nil): return .local
            case (nil, _): return .remote
            }
        }
    }

    // MARK: Internals

    static func split(_ name: String) -> (stem: String, ext: String) {
        let ns = name as NSString
        let ext = ns.pathExtension
        return (ext.isEmpty ? name : ns.deletingPathExtension, ext)
    }

    private static let markerPattern = try! NSRegularExpression(
        pattern: #"\s*\(Conflicted Copy \d{4}-\d{2}-\d{2} \d{2}\.\d{2}\.\d{2}(?: \d+)?\)$"#)

    static func stripMarker(from stem: String) -> String {
        let range = NSRange(stem.startIndex..., in: stem)
        guard let match = markerPattern.firstMatch(in: stem, range: range),
              let swiftRange = Range(match.range, in: stem) else { return stem }
        let stripped = String(stem[..<swiftRange.lowerBound])
        return stripped.isEmpty ? stem : stripped
    }
}
