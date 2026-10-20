import Foundation

/// An exported Apple Music / iTunes library (File ▸ Library ▸ Export Library… → `Library.xml`):
/// a property list with a `Tracks` dictionary and a `Playlists` array.
struct ITunesLibrary {
    struct Track: Equatable {
        let id: Int
        /// nil for tracks that aren't local files (streams, cloud-only items).
        var path: String?
        var name = ""
        /// 0–100, 20 per star. nil when unrated or only inherited from the album ("Rating Computed").
        var rating: Int?
        var playCount = 0
        var skipCount = 0
        var lastPlayed: Date?
        var dateAdded: Date?
    }

    struct Playlist: Equatable {
        var name: String
        var persistentID: String?
        var parentPersistentID: String?
        var isFolder: Bool
        var trackIDs: [Int]
    }

    struct ParseError: LocalizedError {
        var errorDescription: String? { "This isn't an exported Music or iTunes library (Library.xml)." }
    }

    var tracks: [Int: Track] = [:]
    /// The user's playlists and folders in file order (parents come before their children);
    /// built-in ones are left out.
    var playlists: [Playlist] = []
    /// Library, Music, Downloaded, Podcasts and the like.
    var skippedBuiltInPlaylists = 0

    init(data: Data) throws {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let trackDicts = root["Tracks"] as? [String: Any] else { throw ParseError() }
        for case let dict as [String: Any] in trackDicts.values {
            guard let id = dict["Track ID"] as? Int else { continue }
            var track = Track(id: id)
            if let location = dict["Location"] as? String, let url = URL(string: location), url.isFileURL {
                track.path = ExchangeFile.normalized(url.path)
            }
            track.name = dict["Name"] as? String ?? ""
            if let rating = dict["Rating"] as? Int, rating > 0, dict["Rating Computed"] as? Bool != true {
                track.rating = min(rating, 100)
            }
            track.playCount = dict["Play Count"] as? Int ?? 0
            track.skipCount = dict["Skip Count"] as? Int ?? 0
            track.lastPlayed = dict["Play Date UTC"] as? Date
            track.dateAdded = dict["Date Added"] as? Date
            tracks[id] = track
        }

        for case let dict as [String: Any] in root["Playlists"] as? [Any] ?? [] {
            let name = dict["Name"] as? String ?? ""
            let parent = dict["Parent Persistent ID"] as? String
            if Self.isBuiltIn(dict, name: name, parent: parent) {
                skippedBuiltInPlaylists += 1
                continue
            }
            let items = (dict["Playlist Items"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["Track ID"] as? Int }
            playlists.append(Playlist(name: name, persistentID: dict["Playlist Persistent ID"] as? String,
                                      parentPersistentID: parent, isFolder: dict["Folder"] as? Bool == true,
                                      trackIDs: items))
        }
    }

    /// The playlists with every folder before what's in it (exports usually list them that way,
    /// but not always). A parent that isn't one of the folders, or a loop, becomes nil: top level.
    var playlistsParentsFirst: [Playlist] {
        let folders = Set(playlists.filter(\.isFolder).compactMap(\.persistentID))
        var placed = Set<String>()
        var result: [Playlist] = []
        var pending = playlists.map { playlist in
            var playlist = playlist
            if let parent = playlist.parentPersistentID, !folders.contains(parent) { playlist.parentPersistentID = nil }
            return playlist
        }
        while !pending.isEmpty {
            var remaining: [Playlist] = []
            for playlist in pending {
                if let parent = playlist.parentPersistentID, !placed.contains(parent) {
                    remaining.append(playlist)
                    continue
                }
                result.append(playlist)
                if let id = playlist.persistentID { placed.insert(id) }
            }
            if remaining.count == pending.count {
                // Only folders inside each other are left: break the loop at the top level.
                remaining[0].parentPersistentID = nil
            }
            pending = remaining
        }
        return result
    }

    /// The whole-library list ("Master"), the media-kind lists (they carry a "Distinguished Kind":
    /// Music, Movies, Podcasts, Audiobooks, Downloaded, Purchased…), and hidden ones. Very old
    /// exports don't mark every one, so the two whole-library names at the top level count too.
    private static func isBuiltIn(_ dict: [String: Any], name: String, parent: String?) -> Bool {
        if dict["Master"] as? Bool == true || dict["Distinguished Kind"] != nil || dict["Visible"] as? Bool == false {
            return true
        }
        return parent == nil && (name == "Library" || name == "Downloaded")
    }
}

/// What importing a `Library.xml` would change, worked out before anything is touched so the
/// confirmation can show the counts.
///
/// Only fills gaps or brings values forward, never throws casting's own data away:
/// - **Rating**: taken only for tracks casting has no rating for (album-inherited ratings are
///   ignored); 0–100 becomes stars in half-star steps.
/// - **Play count**: the higher of the two (they usually count the same plays from before the
///   switch, so adding them would count those twice).
/// - **Last played**: the later of the two. **Date added**: the earlier of the two (casting's is
///   often just when the folder was scanned).
/// - Skip counts aren't brought over: casting's come from its own listen log.
struct LibraryImportPlan {
    struct Change: Equatable {
        let trackID: Int64
        var rating: Double?
        var playCount: Int?
        var lastPlayed: Date?
        var dateAdded: Date?

        var isEmpty: Bool { rating == nil && playCount == nil && lastPlayed == nil && dateAdded == nil }
    }

    /// Apple track ID → library track ID, for every track found in the library.
    var trackMap: [Int: Int64] = [:]
    /// Local files that exist but aren't in the library yet.
    var addablePaths: [String] = []
    /// Files that are neither in the library nor on disk (or not local files at all).
    var missingCount = 0
    var changes: [Change] = []
    var ratingCount = 0
    var playCountCount = 0
    var lastPlayedCount = 0
    var dateAddedCount = 0
    var playlistCount = 0
    var folderCount = 0
    var skippedBuiltInPlaylists = 0

    var matchedCount: Int { trackMap.count }

    init(library: ITunesLibrary, tracks: [Track], fileExists: (String) -> Bool) {
        let matcher = TrackPathMatcher(tracks)
        let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        for apple in library.tracks.values.sorted(by: { $0.id < $1.id }) {
            guard let path = apple.path else {
                missingCount += 1
                continue
            }
            guard let id = matcher.trackID(forPath: path), let track = byID[id] else {
                if fileExists(path), TagReader.isAudioFile(URL(fileURLWithPath: path)) {
                    addablePaths.append(path)
                } else {
                    missingCount += 1
                }
                continue
            }
            trackMap[apple.id] = id
            var change = Change(trackID: id)
            if let rating = apple.rating, track.rating == 0 {
                change.rating = (Double(rating) / 10).rounded() / 2
                ratingCount += 1
            }
            if apple.playCount > track.playCount {
                change.playCount = apple.playCount
                playCountCount += 1
            }
            if let played = apple.lastPlayed, played > (track.lastPlayed ?? .distantPast) {
                change.lastPlayed = played
                lastPlayedCount += 1
            }
            if let added = apple.dateAdded, added < (track.dateAdded ?? .distantFuture) {
                change.dateAdded = added
                dateAddedCount += 1
            }
            if !change.isEmpty { changes.append(change) }
        }
        folderCount = library.playlists.filter(\.isFolder).count
        playlistCount = library.playlists.count - folderCount
        skippedBuiltInPlaylists = library.skippedBuiltInPlaylists
    }
}
