import Foundation

/// Tag fields the Get Info editor can change. nil means "leave as is".
struct TrackEdit: Hashable {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var genre: String?
    var composer: String?
    var grouping: String?
    var comment: String?
    var year: Int?
    var trackNumber: Int?
    var trackCount: Int?
    var discNumber: Int?
    var discCount: Int?
    var bpm: Int?
    var compilation: Bool?
    var rating: Double?

    var isEmpty: Bool { self == TrackEdit() }

    /// (column, value) pairs for the fields that are set.
    fileprivate var assignments: [(String, Any)] {
        var result: [(String, Any)] = []
        func add(_ column: String, _ value: Any?) { if let value { result.append((column, value)) } }
        add("title", title)
        add("artist", artist)
        add("album", album)
        add("album_artist", albumArtist)
        add("genre", genre)
        add("composer", composer)
        add("grouping", grouping)
        add("comment", comment)
        add("year", year)
        add("track_number", trackNumber)
        add("track_count", trackCount)
        add("disc_number", discNumber)
        add("disc_count", discCount)
        add("bpm", bpm)
        add("compilation", compilation)
        add("rating", rating)
        return result
    }

    /// The track's current values for the fields this edit sets (what undoing it puts back).
    func currentValues(in track: Track) -> TrackEdit {
        var old = TrackEdit()
        if title != nil { old.title = track.title }
        if artist != nil { old.artist = track.artist }
        if album != nil { old.album = track.album }
        if albumArtist != nil { old.albumArtist = track.albumArtist }
        if genre != nil { old.genre = track.genre }
        if composer != nil { old.composer = track.composer }
        if grouping != nil { old.grouping = track.grouping }
        if comment != nil { old.comment = track.comment }
        if year != nil { old.year = track.year }
        if trackNumber != nil { old.trackNumber = track.trackNumber }
        if trackCount != nil { old.trackCount = track.totalNumberOfTracks }
        if discNumber != nil { old.discNumber = track.discNumber }
        if discCount != nil { old.discCount = track.totalNumberOfDiscs }
        if bpm != nil { old.bpm = track.bpm }
        if compilation != nil { old.compilation = track.compilation }
        if rating != nil { old.rating = track.rating }
        return old
    }

    /// Applies the set fields to an in-memory track so the UI updates without a reload.
    func apply(to track: Track) {
        if let title { track.title = title }
        if let artist { track.artist = artist }
        if let album { track.album = album }
        if let albumArtist { track.albumArtist = albumArtist }
        if let genre { track.genre = genre }
        if let composer { track.composer = composer }
        if let grouping { track.grouping = grouping }
        if let comment { track.comment = comment }
        if let year { track.year = year }
        if let trackNumber { track.trackNumber = trackNumber }
        if let trackCount { track.totalNumberOfTracks = trackCount }
        if let discNumber { track.discNumber = discNumber }
        if let discCount { track.totalNumberOfDiscs = discCount }
        if let bpm { track.bpm = bpm }
        if let compilation { track.compilation = compilation }
        if let rating { track.rating = rating }
        track.resetSearchText()
    }
}

extension LibraryStore {
    // MARK: Tracks

    func recordPlay(trackID: Int64, at date: Date) throws {
        try db.transaction {
            try db.prepare("UPDATE track SET play_count = play_count + 1, last_played = ? WHERE id = ?")
                .run([date.timeIntervalSince1970, trackID])
            try db.prepare("INSERT INTO play_history (track_id, played_at) VALUES (?, ?)")
                .run([trackID, date.timeIntervalSince1970])
        }
    }

    func update(_ edit: TrackEdit, forTracks ids: [Int64]) throws {
        let assignments = edit.assignments
        guard !assignments.isEmpty, !ids.isEmpty else { return }
        let sql = "UPDATE track SET \(assignments.map { "\($0.0) = ?" }.joined(separator: ", ")), date_modified = ? WHERE id = ?"
        let statement = try db.prepare(sql)
        let now = Date().timeIntervalSince1970
        try db.transaction {
            for id in ids {
                try statement.run(assignments.map(\.1) + [now, id])
            }
        }
    }

    // MARK: Playlists

    private func nextPosition(under parentID: Int64?) throws -> Int {
        let statement = try db.prepare("SELECT COALESCE(MAX(position) + 1, 0) FROM playlist WHERE parent_id IS ?")
        try statement.bind([parentID])
        try statement.step()
        return Int(statement.int(0) ?? 0)
    }

    @discardableResult
    func createPlaylist(named name: String, kind: Playlist.Kind = .regular, parentID: Int64? = nil,
                        trackIDs: [Int64] = [], smartPredicate: Data? = nil, predicateFormat: String? = nil) throws -> Int64 {
        var id: Int64 = 0
        try db.transaction {
            let insert = try db.prepare("""
                INSERT INTO playlist (name, kind, parent_id, position, smart_predicate, predicate_format)
                VALUES (?, ?, ?, ?, ?, ?)
                """)
            try insert.run([name, kind.rawValue, parentID, try nextPosition(under: parentID), smartPredicate, predicateFormat])
            id = db.lastInsertID
            try insertEntries(trackIDs, into: id, startingAt: 0)
        }
        return id
    }

    func renamePlaylist(_ id: Int64, to name: String) throws {
        try db.prepare("UPDATE playlist SET name = ? WHERE id = ?").run([name, id])
    }

    /// Deletes a playlist; for folders, everything inside goes too (ON DELETE CASCADE).
    func deletePlaylist(_ id: Int64) throws {
        try db.prepare("DELETE FROM playlist WHERE id = ?").run([id])
    }

    func setSmartPredicate(_ archive: Data, format: String, forPlaylist id: Int64) throws {
        try db.prepare("UPDATE playlist SET smart_predicate = ?, predicate_format = ? WHERE id = ?").run([archive, format, id])
    }

    /// Moves a playlist into `parentID` (nil = top level) at `position`, shifting its new siblings.
    func movePlaylist(_ id: Int64, toParent parentID: Int64?, position: Int) throws {
        try db.transaction {
            var siblings: [Int64] = []
            let select = try db.prepare("SELECT id FROM playlist WHERE parent_id IS ? AND id != ? ORDER BY position, name")
            try select.bind([parentID, id])
            while try select.step() { siblings.append(select.int(0)!) }
            siblings.insert(id, at: max(0, min(position, siblings.count)))
            let update = try db.prepare("UPDATE playlist SET parent_id = ?, position = ? WHERE id = ?")
            for (index, sibling) in siblings.enumerated() {
                try update.run([sibling == id ? parentID : parentIDOf(sibling), index, sibling])
            }
        }
    }

    private func parentIDOf(_ id: Int64) throws -> Int64? {
        let statement = try db.prepare("SELECT parent_id FROM playlist WHERE id = ?")
        try statement.bind([id])
        return try statement.step() ? statement.int(0) : nil
    }

    func appendTracks(_ trackIDs: [Int64], toPlaylist id: Int64) throws {
        try db.transaction {
            let count = try db.prepare("SELECT COUNT(*) FROM playlist_track WHERE playlist_id = ?")
            try count.bind([id])
            try count.step()
            try insertEntries(trackIDs, into: id, startingAt: Int(count.int(0) ?? 0))
        }
    }

    /// Removes the entries at `positions` (indexes into the playlist's order).
    func removeEntries(at positions: IndexSet, fromPlaylist id: Int64) throws {
        var entries = try trackIDs(inPlaylist: id)
        entries.remove(atOffsets: positions)
        try replaceEntries(of: id, with: entries)
    }

    func moveEntries(at positions: IndexSet, to destination: Int, inPlaylist id: Int64) throws {
        var entries = try trackIDs(inPlaylist: id)
        entries.move(fromOffsets: positions, toOffset: destination)
        try replaceEntries(of: id, with: entries)
    }

    func replaceEntries(of playlistID: Int64, with trackIDs: [Int64]) throws {
        try db.transaction {
            try db.prepare("DELETE FROM playlist_track WHERE playlist_id = ?").run([playlistID])
            try insertEntries(trackIDs, into: playlistID, startingAt: 0)
        }
    }

    private func insertEntries(_ trackIDs: [Int64], into playlistID: Int64, startingAt start: Int) throws {
        let insert = try db.prepare("INSERT INTO playlist_track (playlist_id, position, track_id) VALUES (?, ?, ?)")
        for (offset, trackID) in trackIDs.enumerated() {
            try insert.run([playlistID, start + offset, trackID])
        }
    }
}

extension LibraryStore {
    // MARK: Adding files

    /// Every path already in the library, to skip known files when scanning folders.
    func allPaths() throws -> Set<String> {
        let statement = try db.prepare("SELECT path FROM track")
        var paths = Set<String>()
        while try statement.step() { if let path = statement.string(0) { paths.insert(path) } }
        return paths
    }

    /// Inserts scanned files; paths already in the library are skipped. Returns how many were added.
    @discardableResult
    func insert(_ scanned: [ScannedTrack], addedAt date: Date = Date()) throws -> Int {
        var added = 0
        try db.transaction {
            let exists = try db.prepare("SELECT 1 FROM track WHERE path = ?")
            let insert = try db.prepare("""
                INSERT INTO track (title, artist, album, album_artist, genre, composer, comment, year,
                    track_number, track_count, disc_number, disc_count, bpm, compilation, duration, bit_rate,
                    sample_rate, channels, file_size, date_added, date_created, date_modified, path, bookmark)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            for track in scanned {
                try exists.bind([track.path])
                if try exists.step() { continue }
                try insert.run([
                    track.title, track.artist, track.album, track.albumArtist, track.genre, track.composer,
                    track.comment, track.year, track.trackNumber, track.trackCount, track.discNumber,
                    track.discCount, track.bpm, track.compilation, track.duration, track.bitRate,
                    track.sampleRate, track.channels, track.fileSize, date.timeIntervalSince1970,
                    track.dateCreated?.timeIntervalSince1970, track.dateModified?.timeIntervalSince1970,
                    track.path, track.bookmark,
                ])
                added += 1
            }
        }
        return added
    }
}
