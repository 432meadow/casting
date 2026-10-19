import AppKit

/// The right-click menu for tracks, shared by every track list (AppKit `NSMenu` so the
/// NSTableView-based list can use it directly).
@MainActor
enum TrackMenu {
    static func make(for ids: Set<Int64>, model: AppModel) -> NSMenu {
        let menu = NSMenu()
        let tracks = model.visibleTracks.filter { ids.contains($0.id) }
        guard !tracks.isEmpty else { return menu }

        menu.addItem(ClosureMenuItem("Play") { model.play(tracks[0]) })
        menu.addItem(ClosureMenuItem("Play Next") { model.playNext(tracks) })
        menu.addItem(ClosureMenuItem("Add to Queue") { model.addToQueue(tracks) })
        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem("Load on Deck A") { model.load(tracks[0], on: .a) })
        menu.addItem(ClosureMenuItem("Load on Deck B") { model.load(tracks[0], on: .b) })
        menu.addItem(.separator())

        menu.addItem(addToPlaylistItem(tracks, model: model))
        if model.editablePlaylistID != nil {
            menu.addItem(ClosureMenuItem("Remove from Playlist") { model.removeFromCurrentPlaylist(tracks) })
        }
        menu.addItem(.separator())

        menu.addItem(ratingItem(tracks, model: model))
        menu.addItem(ClosureMenuItem(detectBPMTitle(for: tracks)) { model.detectBPM(for: tracks) })
        menu.addItem(ClosureMenuItem("Get Info") { model.showInfo(for: tracks) })
        if tracks.count == 1, !tracks[0].displayArtist.isEmpty {
            menu.addItem(ClosureMenuItem("Go to Artist") { model.showArtist(tracks[0].displayArtist) })
        }
        menu.addItem(ClosureMenuItem("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(tracks.map { URL(fileURLWithPath: $0.path) })
        })
        if tracks.count == 1, model.unavailableTracks[tracks[0].id] != nil {
            menu.addItem(ClosureMenuItem("Locate File…") { model.locate(tracks[0]) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(tracks.count == 1 ? "Remove from Library…" : "Remove \(tracks.count) Tracks from Library…") {
            model.confirmRemoveFromLibrary(tracks)
        })
        return menu
    }

    /// Detect BPM fills in missing tempos; once every selected track has one, it re-detects them.
    static func detectBPMTitle(for tracks: [Track]) -> String {
        !tracks.isEmpty && tracks.allSatisfy { $0.bpm > 0 } ? "Re-detect BPM" : "Detect BPM"
    }

    static func addToPlaylistItem(_ tracks: [Track], model: AppModel) -> NSMenuItem {
        let item = NSMenuItem(title: "Add to Playlist", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(ClosureMenuItem("New Playlist from Selection") {
            model.createPlaylist(named: "Untitled Playlist", with: tracks)
        })
        let playlists = model.editablePlaylists
        if !playlists.isEmpty { submenu.addItem(.separator()) }
        for entry in playlists {
            submenu.addItem(ClosureMenuItem(entry.path) { model.add(tracks, toPlaylist: entry.playlist.id) })
        }
        item.submenu = submenu
        return item
    }

    static func ratingItem(_ tracks: [Track], model: AppModel) -> NSMenuItem {
        let item = NSMenuItem(title: "Rating", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let current = Set(tracks.map(\.rating))
        for stars in [0, 1, 2, 3, 4, 5] {
            let title = stars == 0 ? "None" : String(repeating: "★", count: stars)
            let state: NSControl.StateValue = current == [Double(stars)] ? .on : .off
            submenu.addItem(ClosureMenuItem(title, state: state) {
                model.setRating(Double(stars), for: tracks)
            })
        }
        item.submenu = submenu
        return item
    }
}

/// NSMenuItem that runs a closure, so menus can be built without target/selector plumbing.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, keyEquivalent: String = "", state: NSControl.StateValue = .off, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
        self.state = state
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}
