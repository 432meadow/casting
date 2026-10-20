import Foundation

/// A short record of what went wrong lately, plus launches and quits, for bug reports.
///
/// Kept in memory and, in the installed app, in ~/Library/Logs/susurrus/events.log, so the lines
/// from a session that crashed are still there at the next launch (a session without a "Quit"
/// line ended badly). Only the last `capacity` entries are kept. Nothing here is sent anywhere:
/// a bug report shows the user what it will include before they send it.
final class EventLog: @unchecked Sendable {
    enum Level: String, Sendable {
        case info, error
    }

    struct Entry: Equatable, Sendable {
        var date: Date
        var level: Level
        var message: String
        /// The same message logged this many times in a row.
        var count = 1

        var line: String {
            let time = EventLog.timestamp.string(from: date)
            return "\(time)  \(message)" + (count > 1 ? " (×\(count))" : "")
        }
    }

    static let shared = EventLog(fileURL: EventLog.defaultFileURL)
    static let capacity = 300

    /// The installed app's log. Tests and `swift run` keep theirs in memory, so they never write
    /// into the real one; a `SUSURRUS_SUPPORT_DIR` build keeps it next to its library.
    static var defaultFileURL: URL? {
        if LibraryStore.isUsingSupportOverride {
            return LibraryStore.supportDirectory.appendingPathComponent("susurrus/events.log")
        }
        guard Bundle.main.bundleIdentifier == "io.github.432meadow.susurrus" else { return nil }
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/susurrus/events.log")
    }

    fileprivate static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let fileDate = ISO8601DateFormatter()

    private let lock = NSLock()
    private var entries: [Entry] = []
    private let fileURL: URL?

    init(fileURL: URL?) {
        self.fileURL = fileURL
        guard let fileURL else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
            entries = text.split(separator: "\n").compactMap(Self.parse).suffix(Self.capacity).map { $0 }
        }
        rewriteFile()
    }

    func log(_ message: String, level: Level = .error) {
        let message = message.replacingOccurrences(of: "\n", with: " ")
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        // A retry loop failing the same way shouldn't push everything else out.
        if var last = entries.last, last.message == message, last.level == level, now.timeIntervalSince(last.date) < 600 {
            last.count += 1
            last.date = now
            entries[entries.count - 1] = last
            rewriteFile()
            return
        }
        entries.append(Entry(date: now, level: level, message: message))
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
            rewriteFile()
        } else {
            append(entries[entries.count - 1])
        }
    }

    /// The newest `count` entries, oldest first.
    func recent(_ count: Int) -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(entries.suffix(count))
    }

    // MARK: File

    private static func serialize(_ entry: Entry) -> String {
        "\(fileDate.string(from: entry.date))\t\(entry.level.rawValue)\t\(entry.count)\t\(entry.message)\n"
    }

    private static func parse(_ line: Substring) -> Entry? {
        let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, let date = fileDate.date(from: String(parts[0])),
              let level = Level(rawValue: String(parts[1])), let count = Int(parts[2]) else { return nil }
        return Entry(date: date, level: level, message: String(parts[3]), count: count)
    }

    /// Called with the lock held.
    private func append(_ entry: Entry) {
        guard let fileURL, let handle = try? FileHandle(forWritingTo: fileURL) else { return rewriteFile() }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(Self.serialize(entry).utf8))
    }

    /// Called with the lock held (or from init).
    private func rewriteFile() {
        guard let fileURL else { return }
        try? Data(entries.map(Self.serialize).joined().utf8).write(to: fileURL, options: .atomic)
    }
}
