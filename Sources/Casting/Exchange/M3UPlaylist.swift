import Foundation

/// Extended M3U playlists: `#EXTM3U`, then an `#EXTINF:<seconds>,<artist> - <title>` line before
/// each file's path. Written as UTF-8 (`.m3u8`); `.m3u` files from elsewhere may be Latin-1.
enum M3UPlaylist {
    struct Entry: Equatable {
        /// Absolute, as resolved when reading; as written when writing.
        var path: String
        var title: String?
        /// Whole seconds; nil when unknown (written as -1).
        var duration: Int?
    }

    enum PathStyle: String, CaseIterable {
        case relative
        case absolute

        var label: String {
            switch self {
            case .relative: "Relative to the Playlist File"
            case .absolute: "Absolute"
            }
        }
    }

    static let fileExtensions: Set<String> = ["m3u", "m3u8"]

    static func isPlaylistFile(_ url: URL) -> Bool {
        fileExtensions.contains(url.pathExtension.lowercased())
    }

    static func entry(for track: Track) -> Entry {
        let name = track.title.isEmpty ? (track.fileName as NSString).deletingPathExtension : track.title
        let artist = track.displayArtist
        return Entry(path: track.path, title: artist.isEmpty ? name : "\(artist) - \(name)",
                     duration: track.length > 0 ? Int(track.length.rounded()) : nil)
    }

    /// The playlist text. With `.relative`, paths are written relative to `directory` (the folder
    /// the playlist is saved in) wherever they share more than the root with it.
    static func text(for entries: [Entry], style: PathStyle, directory: String) -> String {
        var lines = ["#EXTM3U"]
        for entry in entries {
            // Line breaks would end the line early; commas are fine (the title is everything after the first).
            let title = (entry.title ?? "").components(separatedBy: .newlines).joined(separator: " ")
            lines.append("#EXTINF:\(entry.duration ?? -1),\(title)")
            let relative = style == .relative ? ExchangeFile.relativePath(from: directory, to: entry.path) : nil
            lines.append(relative ?? entry.path)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// UTF-8 (with or without a byte-order mark), falling back to Windows Latin-1, which is what
    /// most old `.m3u` files are.
    static func decode(_ data: Data) -> String? {
        var data = data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = data.dropFirst(3) }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
    }

    /// The playlist's entries with their paths resolved against `directory`. Accepts `file://`
    /// URLs and Windows-style backslashes; other URLs (streams) are skipped.
    static func parse(_ text: String, directory: String) -> [Entry] {
        var entries: [Entry] = []
        var pending: (title: String?, duration: Int?)?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                if line.uppercased().hasPrefix("#EXTINF:") {
                    let info = line.dropFirst("#EXTINF:".count)
                    let comma = info.firstIndex(of: ",")
                    let seconds = Double(info[..<(comma ?? info.endIndex)].trimmingCharacters(in: .whitespaces))
                    let title = comma.map { String(info[info.index(after: $0)...]).trimmingCharacters(in: .whitespaces) }
                    pending = (title?.isEmpty == false ? title : nil, seconds.flatMap { $0 >= 0 ? Int($0) : nil })
                }
                continue
            }
            if let path = resolve(line, directory: directory) {
                entries.append(Entry(path: path, title: pending?.title, duration: pending?.duration))
            }
            pending = nil
        }
        return entries
    }

    static func resolve(_ location: String, directory: String) -> String? {
        if location.lowercased().hasPrefix("file:") {
            return URL(string: location).map { ExchangeFile.normalized($0.path) }
        }
        // Another scheme (http://…) is a stream, not a file.
        if let colon = location.firstIndex(of: ":"), location.distance(from: location.startIndex, to: colon) > 1,
           location[..<colon].allSatisfy({ $0.isLetter }) {
            return nil
        }
        var path = location
        if !path.contains("/") && path.contains("\\") { path = path.replacingOccurrences(of: "\\", with: "/") }
        if path.hasPrefix("~") { path = (path as NSString).expandingTildeInPath }
        if !path.hasPrefix("/") { path = directory + "/" + path }
        return ExchangeFile.normalized(path)
    }
}
