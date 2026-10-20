import Foundation

/// The app's own library database.
final class LibraryStore {
    static let schemaVersion = 4

    static var defaultURL: URL {
        supportDirectory.appendingPathComponent("susurrus/Library.sqlite")
    }

    /// ~/Library/Application Support, or `SUSURRUS_SUPPORT_DIR` to try a build against a throwaway
    /// library.
    static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["SUSURRUS_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static var isUsingSupportOverride: Bool { ProcessInfo.processInfo.environment["SUSURRUS_SUPPORT_DIR"]?.isEmpty == false }

    let url: URL
    let db: Database

    init(url: URL = LibraryStore.defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.url = url
        db = try Database(path: url.path)
        try db.execute("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")
        try LibraryStore.migrate(db)
    }

    static func migrate(_ db: Database) throws {
        let version = try db.prepare("PRAGMA user_version")
        try version.step()
        let current = version.int(0) ?? 0
        guard current < schemaVersion else { return }

        try db.transaction {
            if current < 1 { try createVersion1(db) }
            if current < 2 { try upgradeToVersion2(db) }
            if current < 3 { try upgradeToVersion3(db) }
            if current < 4 { try upgradeToVersion4(db) }
            try db.execute("PRAGMA user_version = \(schemaVersion)")
        }
    }

    private static func createVersion1(_ db: Database) throws {
        try db.execute("""
            CREATE TABLE track (
                id INTEGER PRIMARY KEY,
                source_id INTEGER UNIQUE,
                import_stamp REAL,
                title TEXT NOT NULL DEFAULT '',
                artist TEXT NOT NULL DEFAULT '',
                album TEXT NOT NULL DEFAULT '',
                album_artist TEXT NOT NULL DEFAULT '',
                genre TEXT NOT NULL DEFAULT '',
                composer TEXT NOT NULL DEFAULT '',
                grouping TEXT NOT NULL DEFAULT '',
                comment TEXT NOT NULL DEFAULT '',
                year INTEGER NOT NULL DEFAULT 0,
                track_number INTEGER NOT NULL DEFAULT 0,
                track_count INTEGER NOT NULL DEFAULT 0,
                disc_number INTEGER NOT NULL DEFAULT 0,
                disc_count INTEGER NOT NULL DEFAULT 0,
                duration REAL NOT NULL DEFAULT 0,
                bit_rate INTEGER NOT NULL DEFAULT 0,
                sample_rate INTEGER NOT NULL DEFAULT 0,
                bit_depth INTEGER NOT NULL DEFAULT 0,
                channels INTEGER NOT NULL DEFAULT 0,
                bpm INTEGER NOT NULL DEFAULT 0,
                file_size INTEGER NOT NULL DEFAULT 0,
                compilation INTEGER NOT NULL DEFAULT 0,
                enabled INTEGER NOT NULL DEFAULT 1,
                rating REAL NOT NULL DEFAULT 0,
                play_count INTEGER NOT NULL DEFAULT 0,
                date_added REAL,      -- Unix time
                last_played REAL,     -- Unix time
                date_modified REAL,   -- Unix time
                date_created REAL,    -- Unix time
                path TEXT NOT NULL,
                bookmark BLOB         -- macOS URL bookmark, used when `path` has moved
            );
            CREATE INDEX track_path ON track (path);

            CREATE TABLE playlist (
                id INTEGER PRIMARY KEY,
                source_id INTEGER UNIQUE,
                parent_id INTEGER REFERENCES playlist (id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                kind INTEGER NOT NULL DEFAULT 0,  -- Playlist.Kind
                position INTEGER NOT NULL DEFAULT 0,
                smart_predicate BLOB,             -- NSKeyedArchiver'd NSPredicate
                predicate_format TEXT
            );

            CREATE TABLE playlist_track (
                playlist_id INTEGER NOT NULL REFERENCES playlist (id) ON DELETE CASCADE,
                position INTEGER NOT NULL,
                track_id INTEGER NOT NULL REFERENCES track (id) ON DELETE CASCADE,
                PRIMARY KEY (playlist_id, position)
            );
            CREATE INDEX playlist_track_track ON playlist_track (track_id);
            """)
    }

    /// Version 2: a log of every play (for History), seeded with each track's last play, and the
    /// tag writes still waiting to go into files (so quitting doesn't drop them).
    private static func upgradeToVersion2(_ db: Database) throws {
        try db.execute("""
            CREATE TABLE play_history (
                id INTEGER PRIMARY KEY,
                track_id INTEGER NOT NULL REFERENCES track (id) ON DELETE CASCADE,
                played_at REAL NOT NULL   -- Unix time
            );
            CREATE INDEX play_history_played_at ON play_history (played_at);
            CREATE INDEX play_history_track ON play_history (track_id);
            INSERT INTO play_history (track_id, played_at)
                SELECT id, last_played FROM track WHERE last_played IS NOT NULL ORDER BY last_played;

            CREATE TABLE tag_write_queue (
                path TEXT PRIMARY KEY,
                tag_values TEXT NOT NULL   -- JSON-encoded TagValues
            );
            """)
    }

    /// Version 3: every listen with the time actually spent playing and how it ended (for Stats
    /// and skip counts), and the MusicBrainz artist picked for each library artist name.
    private static func upgradeToVersion3(_ db: Database) throws {
        try db.execute("""
            CREATE TABLE listen (
                id INTEGER PRIMARY KEY,
                track_id INTEGER NOT NULL REFERENCES track (id) ON DELETE CASCADE,
                started_at REAL NOT NULL,  -- Unix time
                seconds REAL NOT NULL,     -- time spent playing (pauses and loading left out)
                position REAL NOT NULL,    -- where in the track it ended, in seconds
                outcome INTEGER NOT NULL   -- ListenOutcome
            );
            CREATE INDEX listen_started_at ON listen (started_at);
            CREATE INDEX listen_track ON listen (track_id);

            CREATE TABLE artist_link (
                name_key TEXT PRIMARY KEY,  -- ArtistIndex.key(for:)
                mbid TEXT NOT NULL
            );
            """)
    }

    /// Version 4: each track's musical key.
    private static func upgradeToVersion4(_ db: Database) throws {
        try db.execute("ALTER TABLE track ADD COLUMN musical_key TEXT NOT NULL DEFAULT ''")
    }

    func loadTracks() throws -> [Track] {
        let statement = try db.prepare("""
            SELECT id, title, artist, album, album_artist, genre, composer, grouping, comment,
                   year, track_number, track_count, disc_number, disc_count, duration,
                   bit_rate, sample_rate, bit_depth, channels, bpm, file_size, compilation, enabled,
                   rating, play_count, date_added, last_played, date_modified, date_created, path, musical_key
            FROM track
            """)
        func date(_ column: Int32) -> Date? {
            statement.double(column).map { Date(timeIntervalSince1970: $0) }
        }

        var tracks: [Track] = []
        while try statement.step() {
            let track = Track(id: statement.int(0)!)
            track.title = statement.string(1) ?? ""
            track.artist = statement.string(2) ?? ""
            track.album = statement.string(3) ?? ""
            track.albumArtist = statement.string(4) ?? ""
            track.genre = statement.string(5) ?? ""
            track.composer = statement.string(6) ?? ""
            track.grouping = statement.string(7) ?? ""
            track.comment = statement.string(8) ?? ""
            track.year = Int(statement.int(9) ?? 0)
            track.trackNumber = Int(statement.int(10) ?? 0)
            track.totalNumberOfTracks = Int(statement.int(11) ?? 0)
            track.discNumber = Int(statement.int(12) ?? 0)
            track.totalNumberOfDiscs = Int(statement.int(13) ?? 0)
            track.length = statement.double(14) ?? 0
            track.bitRate = Int(statement.int(15) ?? 0)
            track.sampleRate = Int(statement.int(16) ?? 0)
            track.bitDepth = Int(statement.int(17) ?? 0)
            track.channels = Int(statement.int(18) ?? 0)
            track.bpm = Int(statement.int(19) ?? 0)
            track.fileSize = statement.int(20) ?? 0
            track.compilation = (statement.int(21) ?? 0) != 0
            track.enabled = (statement.int(22) ?? 1) != 0
            track.rating = statement.double(23) ?? 0
            track.playCount = Int(statement.int(24) ?? 0)
            track.dateAdded = date(25)
            track.lastPlayed = date(26)
            track.dateModified = date(27)
            track.dateCreated = date(28)
            track.path = statement.string(29) ?? ""
            track.musicalKey = statement.string(30) ?? ""
            tracks.append(track)
        }
        return tracks
    }

    /// Top-level playlists in sidebar order, with folder contents nested in `children`.
    func loadPlaylists() throws -> [Playlist] {
        let statement = try db.prepare("""
            SELECT id, name, kind, parent_id, position, predicate_format
            FROM playlist ORDER BY position, name
            """)
        var all: [Playlist] = []
        while try statement.step() {
            all.append(Playlist(
                id: statement.int(0)!,
                name: statement.string(1) ?? "",
                kind: Playlist.Kind(rawValue: Int(statement.int(2) ?? 0)) ?? .regular,
                parentID: statement.int(3),
                position: Int(statement.int(4) ?? 0),
                predicateFormat: statement.string(5)
            ))
        }

        let childrenByParent = Dictionary(grouping: all.filter { $0.parentID != nil }, by: { $0.parentID! })
        func attachChildren(_ playlist: Playlist) -> Playlist {
            var playlist = playlist
            if playlist.kind == .folder {
                playlist.children = (childrenByParent[playlist.id] ?? []).map(attachChildren)
            }
            return playlist
        }
        return all.filter { $0.parentID == nil }.map(attachChildren)
    }

    func trackIDs(inPlaylist playlistID: Int64) throws -> [Int64] {
        let statement = try db.prepare("SELECT track_id FROM playlist_track WHERE playlist_id = ? ORDER BY position")
        try statement.bind([playlistID])
        var ids: [Int64] = []
        while try statement.step() { ids.append(statement.int(0)!) }
        return ids
    }

    func smartPredicateArchive(forPlaylist playlistID: Int64) throws -> Data? {
        let statement = try db.prepare("SELECT smart_predicate FROM playlist WHERE id = ?")
        try statement.bind([playlistID])
        return try statement.step() ? statement.data(0) : nil
    }

    func bookmark(forTrack trackID: Int64) throws -> Data? {
        let statement = try db.prepare("SELECT bookmark FROM track WHERE id = ?")
        try statement.bind([trackID])
        return try statement.step() ? statement.data(0) : nil
    }

    /// Called when a bookmark resolved to a new location, so the next lookup is direct.
    func updateFileSize(_ size: Int64, forPath path: String) throws {
        try db.prepare("UPDATE track SET file_size = ? WHERE path = ?").run([size, path])
    }

    func updatePath(_ path: String, bookmark: Data?, forTrack trackID: Int64) throws {
        let statement = try db.prepare("UPDATE track SET path = ?, bookmark = COALESCE(?, bookmark) WHERE id = ?")
        try statement.run([path, bookmark, trackID])
    }
}
