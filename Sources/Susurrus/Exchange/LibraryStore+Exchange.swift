import Foundation

/// The values a library import may change for one track (the full new state of each, so undoing
/// is the same call with the old ones).
struct ImportedTrackValues: Equatable {
    let trackID: Int64
    var rating: Double
    var playCount: Int
    var lastPlayed: Date?
    var dateAdded: Date?

    init(trackID: Int64, rating: Double, playCount: Int, lastPlayed: Date?, dateAdded: Date?) {
        self.trackID = trackID
        self.rating = rating
        self.playCount = playCount
        self.lastPlayed = lastPlayed
        self.dateAdded = dateAdded
    }

    init(_ track: Track) {
        self.init(trackID: track.id, rating: track.rating, playCount: track.playCount,
                  lastPlayed: track.lastPlayed, dateAdded: track.dateAdded)
    }

    func apply(to track: Track) {
        track.rating = rating
        track.playCount = playCount
        track.lastPlayed = lastPlayed
        track.dateAdded = dateAdded
    }
}

extension LibraryStore {
    /// Saves imported ratings, play counts and dates in one transaction. Database only: imports
    /// never queue tag writes (that would rewrite thousands of files over the share).
    func setImportedValues(_ values: [ImportedTrackValues]) throws {
        guard !values.isEmpty else { return }
        let statement = try db.prepare("UPDATE track SET rating = ?, play_count = ?, last_played = ?, date_added = ? WHERE id = ?")
        try db.transaction {
            for value in values {
                try statement.run([value.rating, value.playCount, value.lastPlayed?.timeIntervalSince1970,
                                   value.dateAdded?.timeIntervalSince1970, value.trackID])
            }
        }
    }
}
