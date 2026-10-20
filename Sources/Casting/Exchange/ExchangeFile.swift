import Foundation

/// Helpers shared by the playlist and library exchange formats: writing exports safely, and
/// comparing paths from other apps' files with the library's.
enum ExchangeFile {
    /// Writes to a hidden temp file next to `url` and renames it over the target, so a failed or
    /// interrupted export never leaves half a file (or a half-overwritten old one) behind.
    static func write(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temp)
        guard rename(temp.path, url.path) == 0 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// Collapses `.`, `..` and repeated slashes without touching the disk (resolving symlinks would
    /// mean a round trip to the network share per entry).
    static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// `path` relative to `directory` ("../Music/a.mp3"), or nil when the two only share the root
    /// (another volume), where a relative path would be more fragile than an absolute one.
    static func relativePath(from directory: String, to path: String) -> String? {
        let base = normalized(directory).split(separator: "/")
        let target = normalized(path).split(separator: "/")
        var common = 0
        while common < base.count, common < target.count - 1, base[common] == target[common] { common += 1 }
        guard common > 0 else { return nil }
        let ups = Array(repeating: "..", count: base.count - common)
        return (ups + target[common...].map(String.init)).joined(separator: "/")
    }

    /// The same file can come back spelled differently: decomposed accents (HFS+, some exports),
    /// another case (case-insensitive volumes). This key ignores both.
    static func looseKey(_ path: String) -> String {
        normalized(path).precomposedStringWithCanonicalMapping.lowercased()
    }
}

/// Finds library tracks by file path: exactly first, then ignoring case and Unicode normalization.
struct TrackPathMatcher {
    private var exact: [String: Int64] = [:]
    private var loose: [String: Int64] = [:]

    init(_ tracks: some Sequence<(id: Int64, path: String)>) {
        for track in tracks {
            if exact[track.path] == nil { exact[track.path] = track.id }
            let key = ExchangeFile.looseKey(track.path)
            if loose[key] == nil { loose[key] = track.id }
        }
    }

    init(_ tracks: [Track]) {
        self.init(tracks.lazy.map { (id: $0.id, path: $0.path) })
    }

    func trackID(forPath path: String) -> Int64? {
        exact[path] ?? exact[ExchangeFile.normalized(path)] ?? loose[ExchangeFile.looseKey(path)]
    }
}
