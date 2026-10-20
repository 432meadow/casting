import Foundation
import Testing
@testable import Susurrus

struct BugReportTests {
    @Test func redactionTakesOutPathsAndNames() {
        let redact = { BugReport.redact($0, userName: "pat", computerName: "Pat’s MacBook") }
        #expect(redact("Player: Can't open “Xtal” — /Volumes/Music/Aphex Twin/01 Xtal.flac")
            == "Player: Can't open “Xtal” — <path>.flac")
        #expect(redact("Tag write: The file isn't there (is the share mounted?) — /Users/pat/Music/a b.mp3")
            == "Tag write: The file isn't there (is the share mounted?) — <path>.mp3")
        #expect(redact("Couldn't read ~/Library/Application Support/susurrus") == "Couldn't read <path>")
        #expect(redact("Folder “/Volumes/NAS/Incoming” isn't there") == "Folder “<path>” isn't there")
        #expect(redact("Signed in as pat on Pat’s MacBook") == "Signed in as <name> on <name>")
        #expect(redact("No paths here: 3 of 12 tracks") == "No paths here: 3 of 12 tracks")
    }

    @Test func issueLinkEncodesEverythingAndFitsInALink() throws {
        var draft = BugReport.Draft(title: "Deck B + crossfade", whatHappened: "It stopped & went quiet",
                                    steps: "1. Load\n2. Fade", diagnostics: "susurrus 0.3.0\n\nRecent events:\n  2026-10-20 08:00:00  Player: x")
        let (url, trimmed) = BugReport.issueURL(draft)
        #expect(!trimmed)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(url.absoluteString.hasPrefix("https://github.com/432meadow/susurrus/issues/new?"))
        #expect(items.first { $0.name == "title" }?.value == "Deck B + crossfade", "a plus survives the query string")
        #expect(url.absoluteString.contains("%2B"))
        let body = try #require(items.first { $0.name == "body" }?.value)
        #expect(body.contains("### What happened\n\nIt stopped & went quiet"))
        #expect(body.contains("### Steps to reproduce\n\n1. Load\n2. Fade"))
        #expect(body.contains("<details><summary>Diagnostics</summary>"))

        // Far too many events: the oldest go until the link fits.
        let events = (0..<400).map { String(format: "  2026-10-20 08:%02d:%02d  Player: Can't open “Track %d”", $0 / 60 % 60, $0 % 60, $0) }
        draft.diagnostics = "susurrus 0.3.0\n\nRecent events:\n" + events.joined(separator: "\n")
        let (long, cut) = BugReport.issueURL(draft)
        #expect(cut)
        #expect(long.absoluteString.count <= BugReport.maxURLLength)
        let kept = try #require(URLComponents(url: long, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "body" }?.value)
        #expect(kept.contains("susurrus 0.3.0") && kept.contains("Track 399") && !kept.contains("Track 0”"))
    }

    @Test func crashSummaryPicksOutTheUsefulParts() throws {
        let header = #"{"app_name":"susurrus","app_version":"0.3.0","bundleID":"io.github.432meadow.susurrus"}"#
        let report = """
            {"exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},
             "asi":{"libswiftCore.dylib":["Fatal error: Index out of range"]},
             "faultingThread":1,
             "usedImages":[{"name":"susurrus"},{"name":"libswiftCore.dylib"}],
             "threads":[{"frames":[{"imageIndex":0,"symbol":"main"}]},
                        {"queue":"com.apple.main-thread","frames":[{"imageIndex":1,"symbol":"_assertionFailure"},{"imageIndex":0,"symbol":"Player.tick()"},{"imageIndex":0,"imageOffset":4096}]}]}
            """
        let summary = try #require(BugReport.crashSummary(ips: Data((header + "\n" + report).utf8)))
        #expect(summary.contains("susurrus 0.3.0"))
        #expect(summary.contains("Exception: EXC_BREAKPOINT SIGTRAP"))
        #expect(summary.contains("libswiftCore.dylib: Fatal error: Index out of range"))
        #expect(summary.contains("Crashed thread 1 (com.apple.main-thread):"))
        #expect(summary.contains("1  susurrus  Player.tick()"))
        #expect(summary.contains("2  susurrus  0x1000"))
        #expect(!summary.contains("main\n"))

        // Another app's report isn't ours.
        let other = #"{"app_name":"Live","bundleID":"com.ableton.live"}"# + "\n" + report
        #expect(BugReport.crashSummary(ips: Data(other.utf8)) == nil)
    }

    @Test func eventLogKeepsTheLastSessionAndCollapsesRepeats() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/events.log")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = EventLog(fileURL: url)
        log.log("Launched susurrus 0.3.0", level: .info)
        log.log("Soulseek: Connection refused")
        log.log("Soulseek: Connection refused")
        log.log("Player: Can't open\na file")
        #expect(log.recent(10).map(\.message) == ["Launched susurrus 0.3.0", "Soulseek: Connection refused", "Player: Can't open a file"])
        #expect(log.recent(10)[1].count == 2)
        #expect(log.recent(1).map(\.message) == ["Player: Can't open a file"])

        // As if susurrus had crashed and started again: the old lines are still there.
        let reopened = EventLog(fileURL: url)
        #expect(reopened.recent(10).map(\.message) == log.recent(10).map(\.message))
        #expect(reopened.recent(10)[1].count == 2)
        for index in 0..<(EventLog.capacity + 20) { reopened.log("Event \(index)") }
        #expect(reopened.recent(1000).count == EventLog.capacity)
        #expect(EventLog(fileURL: url).recent(1).first?.message == "Event \(EventLog.capacity + 19)")
    }
}
