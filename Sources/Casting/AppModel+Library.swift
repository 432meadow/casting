import AppKit

/// Library housekeeping: Go to Current Track, missing files, removing tracks, history, and
/// tag writes saved from the last session.
extension AppModel {
    // MARK: Go to Current Track

    /// Selects the playing track in the list and scrolls to it, switching to All Tracks (and
    /// clearing the search) when the current list doesn't show it.
    func goToCurrentTrack() {
        guard let track = player.currentTrack, tracksByID[track.id] != nil else { return }
        let showsTrackList = selection != nil && selection != .albums && selection != .soulseek
        if !showsTrackList || !visibleTracks.contains(where: { $0.id == track.id }) {
            if !searchText.isEmpty { searchText = "" }
            if selection == .browser {
                browse(genre: nil)
            } else if selection != .allTracks {
                selection = .allTracks
            }
        }
        selectedTrackIDs = [track.id]
        requestReveal(of: track.id)
    }

    // MARK: Missing files

    /// Checks every track's file in the background (gently: one at a time, on a slow share).
    /// Files that moved but can still be found through their bookmark get their path updated.
    func checkForMissingFiles() {
        guard missingFilesCheck == nil, store != nil, !tracks.isEmpty else { return }
        let paths = tracks.map { (id: $0.id, path: $0.path) }
        let locate = player.locate
        isCheckingForMissingFiles = true
        missingFilesCheck = Task { [weak self] in
            let statuses = await Task.detached(priority: .utility) {
                var statuses = MissingFiles.check(paths)
                for (id, path) in paths where statuses[id] == .missing {
                    if locate(TrackRef(id: id, path: path)) != nil { statuses[id] = nil }
                }
                return statuses
            }.value
            guard let self else { return }
            self.missingFilesCheck = nil
            self.isCheckingForMissingFiles = false
            self.setUnavailable(statuses)
        }
    }

    /// Playback couldn't open the file: show the track as missing (or offline) straight away.
    func noteUnplayable(_ track: Track) {
        var statuses = unavailableTracks
        statuses[track.id] = MissingFiles.check([(track.id, track.path)])[track.id] ?? .missing
        setUnavailable(statuses)
    }

    /// Asks where a missing file went. Other missing files from the same folder are looked for
    /// in the chosen file's folder too, since they usually moved together.
    func locate(_ track: Track) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Locate"
        panel.message = "Where is “\(track.title.isEmpty ? track.fileName : track.title)”? It was at \(track.path)"
        let oldFolder = (track.path as NSString).deletingLastPathComponent
        if FileManager.default.fileExists(atPath: oldFolder) {
            panel.directoryURL = URL(fileURLWithPath: oldFolder, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        relink(track, to: url)
        var fixed = [track.id]
        let newFolder = url.deletingLastPathComponent()
        for other in tracks where other.id != track.id && unavailableTracks[other.id] != nil
            && (other.path as NSString).deletingLastPathComponent == oldFolder {
            let candidate = newFolder.appendingPathComponent(other.fileName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                relink(other, to: candidate)
                fixed.append(other.id)
            }
        }
        notePathsChanged()
        markAvailable(fixed)
    }

    private func relink(_ track: Track, to url: URL) {
        try? store?.updatePath(url.path, bookmark: try? url.bookmarkData(), forTrack: track.id)
        track.path = url.path
    }

    // MARK: Removing tracks

    /// Asks for confirmation (the alert calls `removeFromLibrary`).
    func confirmRemoveFromLibrary(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        pendingRemoval = tracks
    }

    /// Removes tracks from the library database. The files stay where they are.
    func removeFromLibrary(_ removed: [Track]) {
        guard let store, !removed.isEmpty else { return }
        let ids = Set(removed.map(\.id))
        do {
            try store.deleteTracks(Array(ids))
        } catch {
            fatalError = "Couldn't remove tracks: \(error.localizedDescription)"
            return
        }
        forgetTracks(ids)
    }

    /// Every track whose file is missing (its volume is there, the file isn't).
    var missingTracks: [Track] {
        tracks.filter { unavailableTracks[$0.id] == .missing }
    }

    // MARK: History

    func clearHistory() {
        try? store?.clearHistory()
        try? store?.clearListens()
        for track in tracks where track.skipCount > 0 { track.skipCount = 0 }
        statsRevision += 1
        noteTracksChanged()
        if selection == .history { loadSelection() }
    }

    // MARK: Saved tag writes

    /// Picks up tag writes that were still queued when casting quit.
    func restorePendingTagWrites() {
        guard let store, let pending = try? store.pendingTagWrites(), !pending.isEmpty else { return }
        guard writesTagsToFiles else {
            try? store.clearPendingTagWrites()
            return
        }
        for (path, values) in pending {
            tagWriter.enqueue(values, path: path)
        }
    }
}
