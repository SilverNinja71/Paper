import Foundation
import Testing
@testable import CommonKit

@Suite("Conflicted Copy naming and winner choice")
struct ConflictResolverTests {
    private let utc = TimeZone(identifier: "UTC")!
    /// 2026-10-26 14:30:05 UTC
    private var date: Date {
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 26
        components.hour = 14; components.minute = 30; components.second = 5
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: components)!
    }

    @Test func nameFollowsTheDocumentedPattern() {
        let name = ConflictResolver.conflictedCopyName(for: "MyArt.paper", date: date, existingNames: [], timeZone: utc)
        #expect(name == "MyArt (Conflicted Copy 2026-10-26 14.30.05).paper")
    }

    @Test func extensionIsKeptWhateverItIs() {
        #expect(ConflictResolver.conflictedCopyName(for: "Bracket.forge", date: date, existingNames: [], timeZone: utc)
                == "Bracket (Conflicted Copy 2026-10-26 14.30.05).forge")
        #expect(ConflictResolver.conflictedCopyName(for: "My.Art.v2.paper", date: date, existingNames: [], timeZone: utc)
                == "My.Art.v2 (Conflicted Copy 2026-10-26 14.30.05).paper")
        #expect(ConflictResolver.conflictedCopyName(for: "NoExtension", date: date, existingNames: [], timeZone: utc)
                == "NoExtension (Conflicted Copy 2026-10-26 14.30.05)")
    }

    @Test func collisionsGetACounter() {
        let first = "MyArt (Conflicted Copy 2026-10-26 14.30.05).paper"
        let second = ConflictResolver.conflictedCopyName(for: "MyArt.paper", date: date, existingNames: [first], timeZone: utc)
        #expect(second == "MyArt (Conflicted Copy 2026-10-26 14.30.05 2).paper")
        let third = ConflictResolver.conflictedCopyName(for: "MyArt.paper", date: date,
                                                        existingNames: [first, second], timeZone: utc)
        #expect(third == "MyArt (Conflicted Copy 2026-10-26 14.30.05 3).paper")
        // comparison is case-insensitive like the default macOS file system
        let shouty = ConflictResolver.conflictedCopyName(for: "MyArt.paper", date: date, existingNames: [first.uppercased()], timeZone: utc)
        #expect(shouty == "MyArt (Conflicted Copy 2026-10-26 14.30.05 2).paper")
    }

    @Test func conflictOfAConflictedCopyDoesNotGrowTheName() {
        let existing = "MyArt (Conflicted Copy 2026-10-25 09.00.00).paper"
        #expect(ConflictResolver.isConflictedCopyName(existing))
        #expect(!ConflictResolver.isConflictedCopyName("MyArt.paper"))
        let again = ConflictResolver.conflictedCopyName(for: existing, date: date, existingNames: [existing], timeZone: utc)
        #expect(again == "MyArt (Conflicted Copy 2026-10-26 14.30.05).paper")
        let counted = "MyArt (Conflicted Copy 2026-10-25 09.00.00 2).paper"
        #expect(ConflictResolver.conflictedCopyName(for: counted, date: date, existingNames: [], timeZone: utc)
                == "MyArt (Conflicted Copy 2026-10-26 14.30.05).paper")
    }

    @Test func timestampUsesTheRequestedTimeZone() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        #expect(ConflictResolver.timestamp(date, timeZone: tokyo) == "2026-10-26 23.30.05")
        #expect(ConflictResolver.timestamp(date, timeZone: utc) == "2026-10-26 14.30.05")
    }

    @Test func winnerPolicies() {
        let older = Date(timeIntervalSince1970: 1000), newer = Date(timeIntervalSince1970: 2000)
        #expect(ConflictResolver.winner(policy: .newerWins, localModified: newer, remoteModified: older) == .local)
        #expect(ConflictResolver.winner(policy: .newerWins, localModified: older, remoteModified: newer) == .remote)
        #expect(ConflictResolver.winner(policy: .newerWins, localModified: older, remoteModified: older) == .remote)
        #expect(ConflictResolver.winner(policy: .newerWins, localModified: older, remoteModified: nil) == .local)
        #expect(ConflictResolver.winner(policy: .keepLocal, localModified: older, remoteModified: newer) == .local)
        #expect(ConflictResolver.winner(policy: .keepRemote, localModified: newer, remoteModified: older) == .remote)
    }
}
