import AppKit
import Observation

enum SidebarItem: Hashable {
    case allTracks
    case albums
    case artists
    case browser
    case recentlyAdded
    case recentlyPlayed
    case history
    case stats
    case duplicates
    case missing
    case soulseek
    case playlist(Int64)

    /// Views that bring their own content instead of the track list.
    var isCustomView: Bool {
        switch self {
        case .artists, .stats, .soulseek: true
        default: false
        }
    }

    /// Built-in lists that open in their own order (like playlists) until a column is clicked.
    var isBuiltInList: Bool {
        switch self {
        case .recentlyAdded, .recentlyPlayed, .history, .duplicates, .missing: true
        default: false
        }
    }
}

@MainActor
@Observable
final class AppModel {
    private(set) var tracks: [Track] = []
    private(set) var playlists: [Playlist] = []
    /// Tracks for the sidebar selection, filtered by search and sorted.
    private(set) var visibleTracks: [Track] = []
    /// `visibleTracks` grouped into albums; only computed while the Albums view is showing.
    private(set) var albums: [Album] = []
    var albumSort: Album.Sort = .artist { didSet { refreshVisible() } }
    var selectedAlbumID: Album.ID?
    /// Rows selected in the track table. Menu commands (Get Info, Rate, Add to Playlist…) act on these.
    var selectedTrackIDs = Set<Int64>()

    /// Selected tracks in the order they appear in the list.
    var selectedTracks: [Track] {
        visibleTracks.filter { selectedTrackIDs.contains($0.id) }
    }
    /// Problems loading the current selection (e.g. a smart playlist that can't be evaluated).
    private(set) var selectionError: String?
    var fatalError: String? {
        didSet { if let fatalError, fatalError != oldValue { EventLog.shared.log(fatalError) } }
    }

    var selection: SidebarItem? = .allTracks { didSet { loadSelection() } }
    var searchText = "" { didSet { refreshVisible() } }
    var sortOrder: [KeyPathComparator<Track>] = AppModel.defaultSort { didSet { refreshVisible() } }

    let player = Player()
    let mixer = Mixer()
    let soulseek = SoulseekModel()

    /// The window's undo manager (set by the main view), for undoing edits and playlist changes.
    @ObservationIgnored weak var undoManager: UndoManager?
    /// Playlists deleted and then restored by Undo come back with new IDs; older undo steps
    /// still name the old ones, so they're looked up here (old → new).
    @ObservationIgnored var playlistIDRemap: [Int64: Int64] = [:]

    // MARK: Go to Current Track

    /// Asks the track list to select and scroll to a track; `token` changes on every request.
    struct RevealRequest: Equatable {
        let trackID: Int64
        let token: Int
    }

    private(set) var revealRequest: RevealRequest?

    func requestReveal(of trackID: Int64) {
        revealRequest = RevealRequest(trackID: trackID, token: (revealRequest?.token ?? 0) + 1)
    }

    // MARK: Missing files

    /// Tracks whose file couldn't be found at the last check (or when playback tried to open it).
    private(set) var unavailableTracks: [Int64: MissingFiles.Status] = [:]
    var isCheckingForMissingFiles = false
    /// Tracks waiting for the user to confirm Remove from Library.
    var pendingRemoval: [Track]?

    var missingTrackCount: Int { unavailableTracks.values.lazy.filter { $0 == .missing }.count }

    func setUnavailable(_ statuses: [Int64: MissingFiles.Status]) {
        guard statuses != unavailableTracks else { return }
        unavailableTracks = statuses
        noteTracksChanged()
        if selection == .missing { loadSelection() }
    }

    func markAvailable(_ ids: some Sequence<Int64>) {
        var statuses = unavailableTracks
        for id in ids { statuses[id] = nil }
        setUnavailable(statuses)
    }

    // MARK: MusicBrainz album lookups and covers

    /// The open Look Up Album sheet.
    var releaseLookup: ReleaseLookup?
    /// Find Missing Covers' progress while it runs.
    var coverSearch: CoverSearch?
    /// What the last Find Missing Covers found, shown in the subtitle for a while.
    var coverSearchSummary: String?
    @ObservationIgnored var coverSearchTask: Task<Void, Never>?
    /// Download folders already matched (or tried) this session, so each is cleaned up once.
    @ObservationIgnored var cleanedDownloadFolders = Set<String>()

    // MARK: Artists

    /// Built on first use and dropped whenever track tags change (see `artists`).
    @ObservationIgnored var artistIndex: ArtistIndex?
    /// The artist open in the Artists view (`ArtistIndex.Artist.id`).
    var selectedArtistID: String?

    // MARK: Column browser

    /// Genre / Artist / Album filters for the Browse view (nil = All).
    private(set) var browserGenre: String?
    private(set) var browserArtist: String?
    private(set) var browserAlbum: String?
    private(set) var browserGenres: [String] = []
    private(set) var browserArtists: [String] = []
    private(set) var browserAlbums: [String] = []

    func browse(genre: String?) {
        browserGenre = genre
        browserArtist = nil
        browserAlbum = nil
        refreshVisible()
    }

    func browse(artist: String?) {
        browserArtist = artist
        browserAlbum = nil
        refreshVisible()
    }

    func browse(album: String?) {
        browserAlbum = album
        refreshVisible()
    }

    /// Narrows `tracks` by the browser columns, filling each column from the level above it.
    private func applyBrowser(to tracks: [Track]) -> [Track] {
        func distinct(_ values: some Sequence<String>) -> [String] {
            Set(values.filter { !$0.isEmpty }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        browserGenres = distinct(tracks.lazy.map(\.genre))
        if let genre = browserGenre, !browserGenres.contains(genre) { browserGenre = nil }
        let byGenre = browserGenre.map { genre in tracks.filter { $0.genre == genre } } ?? tracks

        browserArtists = distinct(byGenre.lazy.map(\.albumGroupArtist))
        if let artist = browserArtist, !browserArtists.contains(artist) { browserArtist = nil }
        let byArtist = browserArtist.map { artist in byGenre.filter { $0.albumGroupArtist == artist } } ?? byGenre

        browserAlbums = distinct(byArtist.lazy.map(\.album))
        if let album = browserAlbum, !browserAlbums.contains(album) { browserAlbum = nil }
        return browserAlbum.map { album in byArtist.filter { $0.album == album } } ?? byArtist
    }

    // MARK: Adding files

    enum ScanState: Equatable {
        case idle
        case running(done: Int, total: Int)
        case finished(added: Int)
    }

    var scanState: ScanState = .idle
    /// Folders rescanned for new music at launch, when a volume mounts, and every 30 minutes.
    var watchedFolders: [String] = UserDefaults.standard.stringArray(forKey: "library.watchedFolders") ?? [] {
        didSet { UserDefaults.standard.set(watchedFolders, forKey: "library.watchedFolders") }
    }
    @ObservationIgnored var scanTask: Task<Void, Never>?

    // MARK: Writing tags to files

    /// Off by default: edits then only change casting's database.
    var writesTagsToFiles: Bool = UserDefaults.standard.bool(forKey: "library.writeTagsToFiles") {
        didSet { UserDefaults.standard.set(writesTagsToFiles, forKey: "library.writeTagsToFiles") }
    }
    /// Set once the user has accepted the first-use warning.
    var hasConfirmedTagWriting: Bool = UserDefaults.standard.bool(forKey: "library.writeTagsConfirmed") {
        didSet { UserDefaults.standard.set(hasConfirmedTagWriting, forKey: "library.writeTagsConfirmed") }
    }
    let tagWriter = TagWriteQueue()

    // MARK: BPM and key detection

    let bpmAnalyzer = TrackAnalysisQueue.bpm()
    let keyAnalyzer = TrackAnalysisQueue.key()

    // MARK: Panels and sheets

    /// Tracks being edited in the Get Info sheet.
    var infoTracks: [Track]?
    /// The smart playlist being created or edited.
    var smartPlaylistDraft: SmartPlaylistDraft?
    /// Whether the Up Next panel is open.
    var isShowingUpNext = false
    /// Whether the two-deck mixer sits above the now-playing bar.
    var isShowingMixer = UserDefaults.standard.bool(forKey: "mixer.isShowing") {
        didSet { UserDefaults.standard.set(isShowingMixer, forKey: "mixer.isShowing") }
    }
    /// Whether the mixer shows both decks' beats close up above the decks.
    var isShowingBeatView = UserDefaults.standard.object(forKey: "mixer.isShowingBeats") as? Bool ?? true {
        didSet { UserDefaults.standard.set(isShowingBeatView, forKey: "mixer.isShowingBeats") }
    }

    func showInfo(for tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        infoTracks = tracks
    }

    /// Bumped whenever track metadata changes in place (ratings, play counts, tag edits), so views
    /// that show those values know to redraw even though the track objects are the same.
    private(set) var libraryRevision = 0
    /// Bumped whenever a listen is recorded or history is cleared, so Stats knows to recompute.
    var statsRevision = 0

    private static let defaultSort = [KeyPathComparator(\Track.dateAddedSortKey, order: .reverse)]
    @ObservationIgnored private(set) var store: LibraryStore?
    @ObservationIgnored private(set) var tracksByID: [Int64: Track] = [:]
    @ObservationIgnored private var pathIndex: [String: Track]?
    /// Selection contents in their natural order (playlist order, or library order).
    @ObservationIgnored private var selectionTracks: [Track] = []
    @ObservationIgnored private var predicateCache: [Int64: NSPredicate] = [:]
    @ObservationIgnored private var selectionLoad: Task<Void, Never>?
    /// Which playlist or built-in list `selectionTracks` holds, so reloading it keeps the user's column sort.
    @ObservationIgnored private var loadedItem: SidebarItem?
    @ObservationIgnored var missingFilesCheck: Task<Void, Never>?
    static let recentDays = 30
    static let historyLimit = 2000
    /// True while a playlist (usually a smart one) is being evaluated.
    private(set) var isLoadingSelection = false

    init() {
        do {
            store = try LibraryStore()
            try reload()
        } catch {
            fatalError = "Couldn't open the library: \(error.localizedDescription)"
        }
        let info = Bundle.main.infoDictionary ?? [:]
        EventLog.shared.log("Launched casting \(info["CFBundleShortVersionString"] as? String ?? "(development build)")", level: .info)
        player.locate = makeLocator()
        player.onTrackPlayed = { [weak self] track in self?.recordPlay(track) }
        player.onListenEnded = { [weak self] track, listen in self?.recordListen(listen, of: track) }
        connectMixer()
        soulseek.importFolders = { [weak self] folders in
            guard let self, !self.isScanning, self.store != nil else { return false }
            self.addToLibrary(folders)
            if self.soulseek.tagsDownloads { self.cleanUpDownloads(in: folders) }
            return true
        }
        // Shared files that are in the library advertise bitrate/duration/depth in search results.
        soulseek.libraryAttributes = { [weak self] in
            guard let self else { return [:] }
            var known: [String: SlskFileAttributes] = [:]
            known.reserveCapacity(self.tracks.count)
            for track in self.tracks {
                known[track.path] = SlskFileAttributes(
                    bitrate: track.bitRate > 0 ? track.bitRate : nil,
                    durationSeconds: track.length > 0 ? Int(track.length) : nil,
                    sampleRate: track.sampleRate > 0 ? track.sampleRate : nil,
                    bitDepth: track.bitDepth > 0 ? track.bitDepth : nil
                )
            }
            return known
        }
        // Don't swap a file out from under the player.
        tagWriter.isInUse = { [weak self] path in
            guard let self else { return false }
            return self.player.currentTrack?.path == path || self.mixer.decks.contains { $0.track?.path == path }
        }
        tagWriter.didWrite = { [weak self] path, size in self?.noteFileRewritten(path: path, size: size) }
        tagWriter.persist = { [weak self] path, values in try? self?.store?.savePendingTagWrite(values, forPath: path) }
        restorePendingTagWrites()
        player.onUnplayable = { [weak self] track in self?.noteUnplayable(track) }
        bpmAnalyzer.didDetect = { [weak self] results in self?.saveDetectedBPMs(results) }
        keyAnalyzer.didDetect = { [weak self] results in self?.saveDetectedKeys(results) }
        restorePlaybackState()
        startWatchingFolders()
        if soulseek.connectsAtLaunch, soulseek.hasCredentials { soulseek.connect() }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.savePlaybackState()
                self?.player.endCurrentListen()
                self?.mixer.endListens()
                EventLog.shared.log("Quit", level: .info)
            }
        }

        // Covers that failed while the music share was unmounted are worth retrying once it's back;
        // so are files that looked missing.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            ArtworkStore.shared.forgetMisses()
            MainActor.assumeIsolated { self?.checkForMissingFiles() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForMissingFiles() }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))  // after launch has settled and the share has had time to mount
            self?.checkForMissingFiles()
        }
    }

    var playlistsByID: [Int64: Playlist] {
        var result: [Int64: Playlist] = [:]
        func walk(_ items: [Playlist]) {
            for item in items {
                result[item.id] = item
                walk(item.children ?? [])
            }
        }
        walk(playlists)
        return result
    }

    // MARK: Library

    func reload() throws {
        guard let store else { return }
        tracks = try store.loadTracks()
        tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        for (id, count) in try store.skipCounts() { tracksByID[id]?.skipCount = count }
        artistIndex = nil
        pathIndex = nil
        playlists = try store.loadPlaylists()
        predicateCache = [:]
        if case .playlist(let id) = selection, playlistsByID[id] == nil {
            selection = .allTracks  // its didSet loads the selection
        } else {
            loadSelection()
        }
    }

    // MARK: Selection

    /// Reloads the sidebar selection's tracks (call after its contents change).
    func loadSelection() {
        selectionError = nil
        selectionLoad?.cancel()
        switch selection {
        case .allTracks, .albums, .browser, nil:
            isLoadingSelection = false
            loadedItem = nil
            selectionTracks = tracks
            applySort(sortOrder.isEmpty ? AppModel.defaultSort : sortOrder)
        case .soulseek, .artists, .stats:
            // These views bring their own content; nothing to load from the library.
            isLoadingSelection = false
            loadedItem = nil
            selectionTracks = []
            refreshVisible()
        case .playlist(let id):
            loadInOwnOrder(.playlist(id)) { model in await model.tracks(inPlaylist: id) }
        case .recentlyAdded, .recentlyPlayed, .history, .duplicates, .missing:
            let item = selection!
            loadInOwnOrder(item) { model in await model.builtInListTracks(item) }
        }
    }

    /// Playlists and built-in lists open in their own order until a column header is clicked;
    /// reloading the one already showing keeps the user's sort.
    private func loadInOwnOrder(_ item: SidebarItem, load: @escaping (AppModel) async -> [Track]) {
        let keepSort = selectionTracks.isEmpty == false && loadedItem == item
        if !keepSort { applySort([]) }
        isLoadingSelection = true
        selectionLoad = Task { [weak self] in
            guard let self else { return }
            let result = await load(self)
            guard !Task.isCancelled, self.selection == item else { return }
            self.selectionTracks = result
            self.loadedItem = item
            self.isLoadingSelection = false
            self.refreshVisible()
        }
    }

    private func builtInListTracks(_ item: SidebarItem) async -> [Track] {
        let cutoff = Date().addingTimeInterval(-Double(Self.recentDays) * 86_400)
        switch item {
        case .recentlyAdded:
            return tracks.filter { ($0.dateAdded ?? .distantPast) >= cutoff }
                .sorted { $0.dateAddedSortKey > $1.dateAddedSortKey }
        case .recentlyPlayed:
            return tracks.filter { ($0.lastPlayed ?? .distantPast) >= cutoff }
                .sorted { $0.lastPlayedSortKey > $1.lastPlayedSortKey }
        case .history:
            return ((try? store?.historyTrackIDs(limit: Self.historyLimit)) ?? []).compactMap { tracksByID[$0] }
        case .duplicates:
            let all = tracks
            return await Task.detached(priority: .userInitiated) { Duplicates.find(in: all) }.value
        case .missing:
            return tracks.filter { unavailableTracks[$0.id] == .missing }
        default:
            return []
        }
    }

    /// Assigning sortOrder already refreshes (didSet); only refresh directly when it's unchanged,
    /// so 50k rows aren't filtered, sorted and rebuilt twice.
    private func applySort(_ sort: [KeyPathComparator<Track>]) {
        if sort != sortOrder {
            sortOrder = sort
        } else {
            refreshVisible()
        }
    }

    /// Smart playlist rules run off the main thread: a KVC predicate over 50k tracks takes a
    /// noticeable moment, and a folder of smart playlists multiplies that.
    private func tracks(inPlaylist id: Int64) async -> [Track] {
        guard let store, let playlist = playlistsByID[id] else { return [] }
        do {
            switch playlist.kind {
            case .regular:
                return try store.trackIDs(inPlaylist: id).compactMap { tracksByID[$0] }
            case .smart:
                let predicate = try predicate(for: id)
                let all = tracks
                return try await Task.detached(priority: .userInitiated) {
                    try SmartPredicate.evaluate(predicate, on: all)
                }.value
            case .folder:
                // A folder shows everything in its playlists, once each.
                var seen = Set<Int64>()
                var result: [Track] = []
                for child in playlist.children ?? [] {
                    result += await tracks(inPlaylist: child.id).filter { seen.insert($0.id).inserted }
                }
                return result
            }
        } catch {
            selectionError = "“\(playlist.name)”: \(error.localizedDescription)"
            return []
        }
    }

    private func predicate(for playlistID: Int64) throws -> NSPredicate {
        if let cached = predicateCache[playlistID] { return cached }
        guard let data = try store?.smartPredicateArchive(forPlaylist: playlistID) else {
            throw DatabaseError(message: "This smart playlist has no rules")
        }
        let predicate = try SmartPredicate.unarchive(data)
        predicateCache[playlistID] = predicate
        return predicate
    }

    /// Re-reads the sidebar's playlists after they were created, renamed, moved or deleted.
    func reloadPlaylists() {
        guard let store else { return }
        playlists = (try? store.loadPlaylists()) ?? playlists
        predicateCache = [:]
    }

    /// The library track for a file path (for drops from the track list or Finder).
    func track(atPath path: String) -> Track? {
        if pathIndex == nil {
            pathIndex = Dictionary(tracks.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        }
        return pathIndex?[path]
    }

    func noteTracksChanged() {
        libraryRevision += 1
    }

    /// Call after track paths change, so drops and lookups by path see the new ones.
    func notePathsChanged() {
        pathIndex = nil
    }

    /// Drops tracks deleted from the database from everything in memory.
    func forgetTracks(_ ids: Set<Int64>) {
        guard !ids.isEmpty else { return }
        tracks.removeAll { ids.contains($0.id) }
        artistIndex = nil
        for id in ids {
            tracksByID[id] = nil
            unavailableTracks[id] = nil
        }
        pathIndex = nil
        selectedTrackIDs.subtract(ids)
        loadSelection()
    }

    func refreshVisible() {
        var result = selectionTracks
        // Every word must match somewhere, so "aphex ambient" works; scopes like bpm:120-128 too.
        let query = SearchQuery(searchText)
        if !query.isEmpty {
            let now = Date()
            result = result.filter { query.matches($0, now: now) }
        }
        if selection == .browser {
            result = applyBrowser(to: result)
        }
        if !sortOrder.isEmpty {
            result = TrackSort.sorted(result, by: sortOrder)
        }
        visibleTracks = result
        albums = selection == .albums ? Album.group(result, sortedBy: albumSort) : []
    }

    var selectedAlbum: Album? {
        selectedAlbumID.flatMap { id in albums.first { $0.id == id } }
    }

    func play(_ album: Album, startingAt index: Int = 0) {
        player.play(album.tracks, startingAt: index)
    }

    // MARK: Playback

    func play(_ track: Track) {
        guard let start = visibleTracks.firstIndex(where: { $0.id == track.id }) else { return }
        player.play(visibleTracks, startingAt: start)
    }

    /// Builds the player's file locator. It runs off the main thread (file checks on the network
    /// share can block), so it only captures the store, never `self` or `Track` objects.
    /// Order: stored path, then the stored macOS bookmark (which follows moved/renamed files).
    private func makeLocator() -> @Sendable (TrackRef) -> URL? {
        let store = store
        return { [weak self] ref in
            if FileManager.default.fileExists(atPath: ref.path) {
                return URL(fileURLWithPath: ref.path)
            }
            guard let store, let bookmark = try? store.bookmark(forTrack: ref.id) else { return nil }
            var isStale = false
            // .withoutMounting: never block trying to mount the SMB share from a bookmark.
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &isStale),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            let refreshed = isStale ? try? url.bookmarkData() : nil
            try? store.updatePath(url.path, bookmark: refreshed, forTrack: ref.id)
            Task { @MainActor in self?.tracksByID[ref.id]?.path = url.path }
            return url
        }
    }
}
