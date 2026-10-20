import AppKit

/// Editing actions: ratings, tags, play counts, playlists, queue, and saved playback state.
extension AppModel {
    // MARK: Plays, ratings and tags

    func recordPlay(_ track: Track) {
        let now = Date()
        try? store?.recordPlay(trackID: track.id, at: now)
        track.playCount += 1
        track.lastPlayed = now
        noteTracksChanged()
        if selection == .history || selection == .recentlyPlayed { loadSelection() }
    }

    func recordListen(_ listen: ListenRecord, of track: Track) {
        try? store?.recordListen(listen)
        statsRevision += 1
        if listen.outcome == .skipped {
            track.skipCount += 1
            noteTracksChanged()
        }
    }

    func setRating(_ rating: Double, for tracks: [Track]) {
        update(TrackEdit(rating: rating.clamped(to: 0...5)), for: tracks, actionName: "Rating")
    }

    /// Saves tag edits to the library database and, with "Write tags to files" on, queues them
    /// to be written into the audio files.
    func update(_ edit: TrackEdit, for tracks: [Track], actionName: String = "Edit Info") {
        apply([(edit, tracks)], actionName: actionName)
    }

    /// Saves each edit for its tracks and registers an undo that puts back the values they
    /// replaced (undoing goes through here too, so it registers the redo).
    func apply(_ changes: [(edit: TrackEdit, tracks: [Track])], actionName: String, registersUndo: Bool = true) {
        let changes = changes.filter { !$0.edit.isEmpty && !$0.tracks.isEmpty }
        guard !changes.isEmpty else { return }
        var previous: [TrackEdit: [Track]] = [:]
        for change in changes {
            for track in change.tracks {
                previous[change.edit.currentValues(in: track), default: []].append(track)
            }
        }
        do {
            for change in changes { try save(change.edit, for: change.tracks) }
        } catch {
            fatalError = "Couldn't save changes: \(error.localizedDescription)"
            return
        }
        noteTracksChanged()
        artistIndex = nil
        // Sorting, search matches and album grouping may all depend on what changed.
        refreshVisible()
        guard registersUndo else { return }
        let inverse = previous.map { (edit: $0.key, tracks: $0.value) }
        registerUndo(actionName) { $0.apply(inverse, actionName: actionName) }
    }

    /// Registers `action` as the undo of what was just done, under `name` ("Undo Rating").
    func registerUndo(_ name: String, _ action: @escaping (AppModel) -> Void) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { action(model) }
        }
        undoManager.setActionName(name)
    }

    private func save(_ edit: TrackEdit, for tracks: [Track]) throws {
        try store?.update(edit, forTracks: tracks.map(\.id))
        for track in tracks { edit.apply(to: track) }
        if writesTagsToFiles {
            for track in tracks {
                var values = TagValues(edit: edit, track: track)
                // MP4 has no standard key item; don't rewrite a file over the share for nothing.
                if Self.mp4Extensions.contains((track.path as NSString).pathExtension.lowercased()) { values.key = nil }
                tagWriter.enqueue(values, path: track.path)
            }
        }
    }

    // MARK: BPM detection

    /// Detects the tempo of the tracks that have no BPM yet, or of all of them when every one
    /// already has one (so the same command re-detects a selection).
    func detectBPM(for tracks: [Track]) {
        let missing = tracks.filter { $0.bpm == 0 }
        bpmAnalyzer.enqueue((missing.isEmpty ? tracks : missing).map { ($0.id, $0.path) })
    }

    /// Saves the BPM and key a deck found for a track that had neither, like detected ones.
    func fillIn(_ track: Track, from analysis: TrackAnalysis) {
        guard tracksByID[track.id] === track else { return }
        var edit = TrackEdit()
        if track.bpm == 0, let bpm = analysis.grid?.bpm { edit.bpm = Int(bpm.rounded()) }
        if track.musicalKey.isEmpty, let key = analysis.key { edit.musicalKey = key.name }
        guard !edit.isEmpty else { return }
        do {
            try save(edit, for: [track])
            noteTracksChanged()
            refreshVisible()
        } catch {
            fatalError = "Couldn't save changes: \(error.localizedDescription)"
        }
    }

    private static let mp4Extensions: Set<String> = ["m4a", "m4b", "mp4", "aac", "alac"]

    /// Detects the key of the tracks that have none yet, or of all of them when every one already
    /// has one (so the same command re-detects a selection).
    func detectKey(for tracks: [Track]) {
        let missing = tracks.filter { $0.musicalKey.isEmpty }
        keyAnalyzer.enqueue((missing.isEmpty ? tracks : missing).map { ($0.id, $0.path) })
    }

    func saveDetectedKeys(_ results: [(Int64, MusicalKey)]) {
        do {
            for (id, key) in results {
                guard let track = tracksByID[id], track.musicalKey != key.name else { continue }
                try save(TrackEdit(musicalKey: key.name), for: [track])
            }
            noteTracksChanged()
            refreshVisible()
        } catch {
            fatalError = "Couldn't save changes: \(error.localizedDescription)"
        }
    }

    /// Saves a batch of detected tempos like Get Info edits (so they're written into the files
    /// too when that's on), refreshing the list once per batch.
    func saveDetectedBPMs(_ results: [(Int64, Int)]) {
        do {
            for (id, bpm) in results {
                guard let track = tracksByID[id], track.bpm != bpm else { continue }
                try save(TrackEdit(bpm: bpm), for: [track])
            }
            noteTracksChanged()
            refreshVisible()
        } catch {
            fatalError = "Couldn't save changes: \(error.localizedDescription)"
        }
    }

    /// Keeps the library's file size in step after a tag write.
    func noteFileRewritten(path: String, size: Int64) {
        try? store?.updateFileSize(size, forPath: path)
        track(atPath: path)?.fileSize = size
    }

    // MARK: Queue

    func playNext(_ tracks: [Track]) { player.playNext(tracks) }
    func addToQueue(_ tracks: [Track]) { player.addToQueue(tracks) }

    // MARK: Playlists

    @discardableResult
    func createPlaylist(named name: String = "Untitled Playlist", with tracks: [Track] = [], in folderID: Int64? = nil) -> Int64? {
        guard let store, let id = try? store.createPlaylist(named: name, parentID: folderID, trackIDs: tracks.map(\.id)) else { return nil }
        reloadPlaylists()
        selection = .playlist(id)
        registerUndo("New Playlist") { $0.deletePlaylist($0.resolvedPlaylistID(id), actionName: "New Playlist") }
        return id
    }

    @discardableResult
    func createFolder(named name: String = "Untitled Folder", in folderID: Int64? = nil) -> Int64? {
        guard let store, let id = try? store.createPlaylist(named: name, kind: .folder, parentID: folderID) else { return nil }
        reloadPlaylists()
        registerUndo("New Folder") { $0.deletePlaylist($0.resolvedPlaylistID(id), actionName: "New Folder") }
        return id
    }

    @discardableResult
    func createSmartPlaylist(named name: String, predicate: NSPredicate, in folderID: Int64? = nil) -> Int64? {
        guard let store, let archive = try? SmartPredicate.archive(predicate),
              let id = try? store.createPlaylist(named: name, kind: .smart, parentID: folderID,
                                                 smartPredicate: archive, predicateFormat: predicate.predicateFormat) else { return nil }
        reloadPlaylists()
        selection = .playlist(id)
        registerUndo("New Smart Playlist") { $0.deletePlaylist($0.resolvedPlaylistID(id), actionName: "New Smart Playlist") }
        return id
    }

    func updateSmartPlaylist(_ id: Int64, name: String, predicate: NSPredicate) {
        guard let store, let archive = try? SmartPredicate.archive(predicate) else { return }
        let oldName = playlistsByID[id]?.name
        let oldPredicate = smartPredicate(forPlaylist: id)
        try? store.renamePlaylist(id, to: name)
        try? store.setSmartPredicate(archive, format: predicate.predicateFormat, forPlaylist: id)
        reloadPlaylists()
        if selection == .playlist(id) { loadSelection() }
        if let oldName, let oldPredicate {
            registerUndo("Edit Smart Playlist") { $0.updateSmartPlaylist($0.resolvedPlaylistID(id), name: oldName, predicate: oldPredicate) }
        }
    }

    func smartPredicate(forPlaylist id: Int64) -> NSPredicate? {
        guard let data = try? store?.smartPredicateArchive(forPlaylist: id) else { return nil }
        return try? SmartPredicate.unarchive(data)
    }

    func renamePlaylist(_ id: Int64, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let oldName = playlistsByID[id]?.name, oldName != name else { return }
        try? store?.renamePlaylist(id, to: name)
        reloadPlaylists()
        registerUndo("Rename Playlist") { $0.renamePlaylist($0.resolvedPlaylistID(id), to: oldName) }
    }

    /// Deletes a playlist (a folder with everything in it). Undo puts it back, contents and all.
    func deletePlaylist(_ id: Int64, actionName: String = "Delete Playlist") {
        guard let snapshot = snapshot(ofPlaylist: id) else { return }
        try? store?.deletePlaylist(id)
        reloadPlaylists()
        if case .playlist(let selected) = selection, playlistsByID[selected] == nil {
            selection = .allTracks
        }
        registerUndo(actionName) { $0.restore(snapshot, actionName: actionName) }
    }

    func movePlaylist(_ id: Int64, toFolder folderID: Int64?, position: Int) {
        guard id != folderID, let playlist = playlistsByID[id] else { return }
        // Don't allow moving a folder into its own descendant.
        if let folderID, isDescendant(folderID, of: id) { return }
        let oldParent = playlist.parentID
        let oldIndex = siblingIndex(of: playlist)
        try? store?.movePlaylist(id, toParent: folderID, position: position)
        reloadPlaylists()
        registerUndo("Move Playlist") { model in
            model.movePlaylist(model.resolvedPlaylistID(id), toFolder: oldParent.map(model.resolvedPlaylistID), position: oldIndex)
        }
    }

    // MARK: Undoing playlist deletion

    /// Everything needed to recreate a deleted playlist.
    struct PlaylistSnapshot {
        let id: Int64
        let name: String
        let kind: Playlist.Kind
        let parentID: Int64?
        let index: Int
        let smartPredicate: Data?
        let predicateFormat: String?
        let entries: [Int64]
        let children: [PlaylistSnapshot]
    }

    func resolvedPlaylistID(_ id: Int64) -> Int64 {
        var id = id
        while let newer = playlistIDRemap[id] { id = newer }
        return id
    }

    private func siblingIndex(of playlist: Playlist) -> Int {
        let siblings = playlist.parentID.flatMap { playlistsByID[$0]?.children } ?? playlists
        return siblings.firstIndex { $0.id == playlist.id } ?? 0
    }

    private func snapshot(ofPlaylist id: Int64) -> PlaylistSnapshot? {
        guard let store, let playlist = playlistsByID[id] else { return nil }
        return PlaylistSnapshot(
            id: id, name: playlist.name, kind: playlist.kind, parentID: playlist.parentID,
            index: siblingIndex(of: playlist),
            smartPredicate: playlist.kind == .smart ? (try? store.smartPredicateArchive(forPlaylist: id)) ?? nil : nil,
            predicateFormat: playlist.predicateFormat,
            entries: playlist.kind == .regular ? (try? store.trackIDs(inPlaylist: id)) ?? [] : [],
            children: (playlist.children ?? []).compactMap { snapshot(ofPlaylist: $0.id) }
        )
    }

    private func restore(_ snapshot: PlaylistSnapshot, actionName: String) {
        guard let id = insert(snapshot, parentID: snapshot.parentID.map(resolvedPlaylistID)) else { return }
        reloadPlaylists()
        registerUndo(actionName) { $0.deletePlaylist($0.resolvedPlaylistID(id), actionName: actionName) }
    }

    private func insert(_ snapshot: PlaylistSnapshot, parentID: Int64?) -> Int64? {
        guard let store else { return nil }
        // Tracks removed from the library since can't come back into the playlist.
        let entries = snapshot.entries.filter { tracksByID[$0] != nil }
        func create(under parent: Int64?) -> Int64? {
            try? store.createPlaylist(named: snapshot.name, kind: snapshot.kind, parentID: parent, trackIDs: entries,
                                      smartPredicate: snapshot.smartPredicate, predicateFormat: snapshot.predicateFormat)
        }
        // If its folder is gone too, it comes back at the top level.
        var parent = parentID
        guard let id = create(under: parent) ?? { parent = nil; return create(under: nil) }() else { return nil }
        try? store.movePlaylist(id, toParent: parent, position: snapshot.index)
        playlistIDRemap[snapshot.id] = id
        for child in snapshot.children {
            _ = insert(child, parentID: id)
        }
        return id
    }

    private func isDescendant(_ candidate: Int64, of ancestor: Int64) -> Bool {
        var current = playlistsByID[candidate]?.parentID
        while let id = current {
            if id == ancestor { return true }
            current = playlistsByID[id]?.parentID
        }
        return false
    }

    /// Regular playlists that tracks can be added to, with their folder path for menus.
    var editablePlaylists: [(playlist: Playlist, path: String)] {
        var result: [(Playlist, String)] = []
        func walk(_ items: [Playlist], prefix: String) {
            for item in items {
                switch item.kind {
                case .regular: result.append((item, prefix + item.name))
                case .folder: walk(item.children ?? [], prefix: prefix + item.name + " ▸ ")
                case .smart: break
                }
            }
        }
        walk(playlists, prefix: "")
        return result
    }

    func add(_ tracks: [Track], toPlaylist id: Int64) {
        guard !tracks.isEmpty, playlistsByID[id]?.kind == .regular,
              let entries = try? store?.trackIDs(inPlaylist: id) else { return }
        setEntries(entries + tracks.map(\.id), ofPlaylist: id, actionName: "Add to Playlist")
    }

    /// Replaces a playlist's contents; undo puts the old order back.
    func setEntries(_ ids: [Int64], ofPlaylist id: Int64, actionName: String) {
        guard let store, let old = try? store.trackIDs(inPlaylist: id) else { return }
        let ids = ids.filter { tracksByID[$0] != nil }
        guard ids != old, (try? store.replaceEntries(of: id, with: ids)) != nil else { return }
        if selection == .playlist(id) { loadSelection() }
        registerUndo(actionName) { $0.setEntries(old, ofPlaylist: $0.resolvedPlaylistID(id), actionName: actionName) }
    }

    /// The playlist shown in the main list, if it's one whose contents can be edited.
    var editablePlaylistID: Int64? {
        guard case .playlist(let id) = selection, playlistsByID[id]?.kind == .regular else { return nil }
        return id
    }

    /// Removes every entry of `tracks` from the playlist being shown.
    func removeFromCurrentPlaylist(_ tracks: [Track]) {
        guard let id = editablePlaylistID, let store else { return }
        let ids = Set(tracks.map(\.id))
        guard let entries = try? store.trackIDs(inPlaylist: id) else { return }
        selectedTrackIDs.subtract(ids)
        setEntries(entries.filter { !ids.contains($0) }, ofPlaylist: id, actionName: "Remove from Playlist")
    }

    /// Reorders the playlist being shown. Only meaningful in playlist order (no column sort or search).
    func moveInCurrentPlaylist(_ tracks: [Track], toPosition destination: Int) {
        guard let id = editablePlaylistID, let store, sortOrder.isEmpty, searchText.isEmpty,
              let entries = try? store.trackIDs(inPlaylist: id) else { return }
        let ids = Set(tracks.map(\.id))
        var moved = entries
        moved.move(fromOffsets: IndexSet(entries.indices.filter { ids.contains(entries[$0]) }), toOffset: destination)
        setEntries(moved, ofPlaylist: id, actionName: "Reorder Playlist")
    }

    // MARK: Saved playback state

    private static var playbackStateURL: URL {
        LibraryStore.defaultURL.deletingLastPathComponent().appendingPathComponent("PlaybackState.json")
    }

    func savePlaybackState() {
        guard let state = player.savedState, let data = try? JSONEncoder().encode(state) else {
            try? FileManager.default.removeItem(at: Self.playbackStateURL)
            return
        }
        try? data.write(to: Self.playbackStateURL, options: .atomic)
    }

    /// Puts back the queue and position from last time, paused.
    func restorePlaybackState() {
        guard let data = try? Data(contentsOf: Self.playbackStateURL),
              let state = try? JSONDecoder().decode(Player.SavedState.self, from: data) else { return }
        let queue = state.trackIDs.compactMap { tracksByID[$0] }
        guard state.trackIDs.indices.contains(state.index), let current = tracksByID[state.trackIDs[state.index]],
              let index = queue.firstIndex(where: { $0 === current }) else { return }
        player.restore(queue, index: index, position: state.position)
    }
}
