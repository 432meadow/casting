import Foundation

/// Play history, removing tracks, and the saved tag-write queue.
extension LibraryStore {
    // MARK: Play history

    /// Track IDs of the most recent plays, newest first (a track played twice is listed twice).
    func historyTrackIDs(limit: Int) throws -> [Int64] {
        let statement = try db.prepare("SELECT track_id FROM play_history ORDER BY played_at DESC, id DESC LIMIT ?")
        try statement.bind([limit])
        var ids: [Int64] = []
        while try statement.step() { ids.append(statement.int(0)!) }
        return ids
    }

    func clearHistory() throws {
        try db.execute("DELETE FROM play_history")
    }

    // MARK: Removing tracks

    /// Deletes tracks from the library (their playlist entries and history go with them).
    /// The files themselves are never touched.
    func deleteTracks(_ ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        let delete = try db.prepare("DELETE FROM track WHERE id = ?")
        try db.transaction {
            for id in ids { try delete.run([id]) }
        }
    }

    // MARK: Saved tag writes

    /// Tag writes that were still queued when susurrus last quit.
    func pendingTagWrites() throws -> [(path: String, values: TagValues)] {
        let statement = try db.prepare("SELECT path, tag_values FROM tag_write_queue ORDER BY rowid")
        let decoder = JSONDecoder()
        var result: [(String, TagValues)] = []
        while try statement.step() {
            guard let path = statement.string(0), let json = statement.string(1),
                  let values = try? decoder.decode(TagValues.self, from: Data(json.utf8)) else { continue }
            result.append((path, values))
        }
        return result
    }

    /// Saves (or, with nil, forgets) the write still waiting for `path`.
    func savePendingTagWrite(_ values: TagValues?, forPath path: String) throws {
        if let values, let json = String(data: try JSONEncoder().encode(values), encoding: .utf8) {
            try db.prepare("INSERT OR REPLACE INTO tag_write_queue (path, tag_values) VALUES (?, ?)").run([path, json])
        } else {
            try db.prepare("DELETE FROM tag_write_queue WHERE path = ?").run([path])
        }
    }

    func clearPendingTagWrites() throws {
        try db.execute("DELETE FROM tag_write_queue")
    }
}
