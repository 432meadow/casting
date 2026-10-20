import Foundation

/// How a listen ended.
enum ListenOutcome: Int, Sendable {
    /// Played to the end (or moved on within its last 10 seconds, or last 10% if that's shorter).
    case finished = 0
    /// The player moved to another track before the end: Next, Previous, a jump in Up Next, or
    /// playing something else.
    case skipped = 1
    /// Playback stopped, or susurrus quit.
    case stopped = 2
}

/// One stretch of playing a queue entry, from when it started until playback moved on.
struct ListenRecord: Equatable, Sendable {
    var trackID: Int64
    var startedAt: Date
    /// Time actually spent playing: pauses and waiting for the network share are left out.
    var seconds: Double
    /// Where in the track it ended.
    var position: Double
    var outcome: ListenOutcome
}

/// A counted play from `play_history` (half the track, or 4 minutes).
struct PlayRecord: Equatable, Sendable {
    var trackID: Int64
    var playedAt: Date
}

/// Listens (for Stats and skip counts) and the MusicBrainz artist picked for each artist name.
extension LibraryStore {
    // MARK: Listens

    func recordListen(_ listen: ListenRecord) throws {
        try db.prepare("INSERT INTO listen (track_id, started_at, seconds, position, outcome) VALUES (?, ?, ?, ?, ?)")
            .run([listen.trackID, listen.startedAt.timeIntervalSince1970, listen.seconds, listen.position, listen.outcome.rawValue])
    }

    /// Listens that started at or after `start` (all of them for nil), oldest first.
    func listens(since start: Date?) throws -> [ListenRecord] {
        let statement = try db.prepare("""
            SELECT track_id, started_at, seconds, position, outcome FROM listen
            WHERE started_at >= ? ORDER BY started_at
            """)
        try statement.bind([start?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude])
        var result: [ListenRecord] = []
        while try statement.step() {
            result.append(ListenRecord(
                trackID: statement.int(0)!,
                startedAt: Date(timeIntervalSince1970: statement.double(1) ?? 0),
                seconds: statement.double(2) ?? 0,
                position: statement.double(3) ?? 0,
                outcome: ListenOutcome(rawValue: Int(statement.int(4) ?? 0)) ?? .finished
            ))
        }
        return result
    }

    /// Counted plays at or after `start` (all of them for nil), oldest first.
    func plays(since start: Date?) throws -> [PlayRecord] {
        let statement = try db.prepare("SELECT track_id, played_at FROM play_history WHERE played_at >= ? ORDER BY played_at")
        try statement.bind([start?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude])
        var result: [PlayRecord] = []
        while try statement.step() {
            result.append(PlayRecord(trackID: statement.int(0)!, playedAt: Date(timeIntervalSince1970: statement.double(1) ?? 0)))
        }
        return result
    }

    /// When listens started being recorded (susurrus before that only logged counted plays).
    func firstListenDate() throws -> Date? {
        let statement = try db.prepare("SELECT MIN(started_at) FROM listen")
        guard try statement.step(), let value = statement.double(0) else { return nil }
        return Date(timeIntervalSince1970: value)
    }

    /// How often each track was skipped, for the tracks that ever were.
    func skipCounts() throws -> [Int64: Int] {
        let statement = try db.prepare("SELECT track_id, COUNT(*) FROM listen WHERE outcome = ? GROUP BY track_id")
        try statement.bind([ListenOutcome.skipped.rawValue])
        var counts: [Int64: Int] = [:]
        while try statement.step() { counts[statement.int(0)!] = Int(statement.int(1) ?? 0) }
        return counts
    }

    func clearListens() throws {
        try db.execute("DELETE FROM listen")
    }

    // MARK: Artist links

    func artistMBID(forKey key: String) throws -> String? {
        let statement = try db.prepare("SELECT mbid FROM artist_link WHERE name_key = ?")
        try statement.bind([key])
        return try statement.step() ? statement.string(0) : nil
    }

    /// Remembers (or, with nil, forgets) which MusicBrainz artist a library artist is.
    func setArtistMBID(_ mbid: String?, forKey key: String) throws {
        if let mbid {
            try db.prepare("INSERT OR REPLACE INTO artist_link (name_key, mbid) VALUES (?, ?)").run([key, mbid])
        } else {
            try db.prepare("DELETE FROM artist_link WHERE name_key = ?").run([key])
        }
    }
}
