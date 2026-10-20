import AppKit
import Foundation

/// A bug report, sent as a new GitHub issue the user checks and submits in their browser.
/// casting itself sends nothing.
enum BugReport {
    static let repository = "432meadow/casting"
    /// GitHub (and browsers) cope with links up to about 8 KB; longer diagnostics are trimmed.
    static let maxURLLength = 7_500

    // MARK: Redaction

    /// Takes out what would say who or where the user is, since GitHub issues are public: file
    /// paths become "<path>" (keeping the extension, which says the format), and the Mac's user
    /// and computer names go. Track titles and error text stay.
    static func redact(_ text: String, userName: String = NSUserName(),
                       computerName: String? = Host.current().localizedName) -> String {
        var text = text
        // A path runs from /Users, /Volumes and friends to a closing quote or the end of the line.
        let path = try! NSRegularExpression(
            pattern: #"(?:~|/(?:Users|Volumes|private|var|tmp|Library|Applications|System|opt))/[^\n"“”'’)\]]*"#)
        let matches = path.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed()
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            var found = String(text[range])
            // Keep a trailing " (×3)" or " — reason" out of the path.
            if let dash = found.range(of: " — ") { found = String(found[..<dash.lowerBound]) }
            let trimmed = found.trimmingCharacters(in: .whitespaces)
            let ext = (trimmed as NSString).pathExtension
            let replacement = ext.isEmpty || ext.count > 5 || ext.contains(" ") ? "<path>" : "<path>.\(ext.lowercased())"
            let end = text.index(range.lowerBound, offsetBy: found.count)
            text.replaceSubrange(range.lowerBound..<end, with: replacement + (found.hasSuffix(" ") ? " " : ""))
        }
        // Whole words only ("pat" mustn't eat "path"), the longer name first ("Pat's MacBook").
        for name in [userName, computerName].compactMap({ $0 }).sorted(by: { $0.count > $1.count }) where name.count >= 3 {
            let word = try! NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: name) + "\\b", options: .caseInsensitive)
            text = word.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "<name>")
        }
        return text
    }

    // MARK: Crash reports

    struct Crash: Equatable {
        var date: Date
        /// Exception, the app's own last words, and the crashed thread's frames.
        var summary: String
    }

    static var crashReportsDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/DiagnosticReports")
    }

    /// casting's newest crash report from the last two weeks, if any.
    static func latestCrash(in directory: URL = crashReportsDirectory, now: Date = Date()) -> Crash? {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let candidates = files
            .filter { $0.lastPathComponent.hasPrefix("casting") && $0.pathExtension == "ips" }
            .compactMap { url -> (URL, Date)? in
                guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      now.timeIntervalSince(date) < 14 * 86_400 else { return nil }
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }
        for (url, date) in candidates {
            if let data = try? Data(contentsOf: url), let summary = crashSummary(ips: data) {
                return Crash(date: date, summary: summary)
            }
        }
        return nil
    }

    /// The useful part of an .ips crash report: a JSON header line naming the app, then the report.
    static func crashSummary(ips data: Data) -> String? {
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")),
              let header = try? JSONSerialization.jsonObject(with: data[..<newline]) as? [String: Any],
              header["bundleID"] as? String == "io.github.432meadow.casting" || header["app_name"] as? String == "casting",
              let report = try? JSONSerialization.jsonObject(with: data[data.index(after: newline)...]) as? [String: Any] else { return nil }

        var lines: [String] = []
        if let version = header["app_version"] as? String { lines.append("casting \(version)") }
        if let exception = report["exception"] as? [String: Any] {
            let parts = [exception["type"], exception["signal"], exception["subtype"]].compactMap { $0 as? String }
            if !parts.isEmpty { lines.append("Exception: " + parts.joined(separator: " ")) }
        }
        // Swift's fatalError / precondition messages land here.
        if let asi = report["asi"] as? [String: [String]] {
            for (image, messages) in asi.sorted(by: { $0.key < $1.key }) {
                for message in messages { lines.append("\(image): \(message)") }
            }
        }
        let images = (report["usedImages"] as? [[String: Any]])?.map { $0["name"] as? String ?? "?" } ?? []
        let threads = report["threads"] as? [[String: Any]] ?? []
        let faulting = report["faultingThread"] as? Int ?? threads.firstIndex { $0["triggered"] as? Bool == true } ?? 0
        if threads.indices.contains(faulting), let frames = threads[faulting]["frames"] as? [[String: Any]] {
            let name = threads[faulting]["queue"] as? String ?? threads[faulting]["name"] as? String
            lines.append("Crashed thread \(faulting)" + (name.map { " (\($0))" } ?? "") + ":")
            for (index, frame) in frames.prefix(16).enumerated() {
                let image = (frame["imageIndex"] as? Int).flatMap { images.indices.contains($0) ? images[$0] : nil } ?? "?"
                let symbol = frame["symbol"] as? String ?? "0x\(String(frame["imageOffset"] as? Int ?? 0, radix: 16))"
                lines.append(String(format: "%2d  %@  %@", index, image, symbol))
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: The issue

    struct Draft {
        var title: String
        var whatHappened: String
        var steps: String
        /// Redacted diagnostics as shown to (and possibly edited by) the user; nil to leave out.
        var diagnostics: String?
    }

    static func body(_ draft: Draft) -> String {
        var sections: [String] = []
        let happened = draft.whatHappened.trimmingCharacters(in: .whitespacesAndNewlines)
        sections.append("### What happened\n\n" + (happened.isEmpty ? "_(not filled in)_" : happened))
        let steps = draft.steps.trimmingCharacters(in: .whitespacesAndNewlines)
        if !steps.isEmpty { sections.append("### Steps to reproduce\n\n" + steps) }
        if let diagnostics = draft.diagnostics?.trimmingCharacters(in: .whitespacesAndNewlines), !diagnostics.isEmpty {
            sections.append("<details><summary>Diagnostics</summary>\n\n```\n\(diagnostics)\n```\n</details>")
        }
        return sections.joined(separator: "\n\n")
    }

    /// The new-issue link with the draft filled in. Diagnostics too long for a link lose their
    /// oldest lines first; `trimmed` says whether that happened.
    static func issueURL(_ draft: Draft) -> (url: URL, trimmed: Bool) {
        var draft = draft
        var trimmed = false
        while true {
            var components = URLComponents(string: "https://github.com/\(repository)/issues/new")!
            components.queryItems = [
                URLQueryItem(name: "title", value: draft.title.trimmingCharacters(in: .whitespacesAndNewlines)),
                URLQueryItem(name: "body", value: body(draft)),
                URLQueryItem(name: "labels", value: "bug"),
            ]
            // URLComponents leaves "+" alone, which a query string reads as a space.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            let url = components.url!
            guard url.absoluteString.count > maxURLLength, var lines = draft.diagnostics?.components(separatedBy: "\n"),
                  lines.count > 1 else { return (url, trimmed) }
            // Drop the oldest event line (the events are last, oldest first), or else the last line.
            if let first = lines.firstIndex(where: { $0.hasPrefix("  20") }) {
                lines.remove(at: first)
            } else {
                lines.removeLast()
            }
            draft.diagnostics = lines.joined(separator: "\n")
            trimmed = true
        }
    }
}
