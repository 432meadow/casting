import Foundation

/// Artist pages, listening stats, and handing searches over to Soulseek.
extension AppModel {
    // MARK: Artists

    /// The library's artists (rebuilt after tags change or tracks come and go).
    var artists: ArtistIndex {
        if let artistIndex { return artistIndex }
        let index = ArtistIndex(tracks: tracks)
        artistIndex = index
        return index
    }

    /// Opens the artist's page in the Artists view.
    func showArtist(_ name: String) {
        guard let artist = artists.artist(named: name) else { return }
        selectedArtistID = artist.id
        searchText = ""
        selection = .artists
    }

    /// The MusicBrainz artist picked by hand for this artist, if any.
    func linkedMBID(for artist: ArtistIndex.Artist) -> String? {
        try? store?.artistMBID(forKey: artist.id)
    }

    func setLinkedMBID(_ mbid: String?, for artist: ArtistIndex.Artist) {
        try? store?.setArtistMBID(mbid, forKey: artist.id)
    }

    /// Plays every track by the artist, album by album.
    func playArtist(_ artist: ArtistIndex.Artist, shuffled: Bool = false) {
        let albums = Album.group(artists.tracks(for: artist), sortedBy: .year).reversed()
        let ordered = albums.flatMap(\.tracks) + artists.tracks(for: artist).filter(\.album.isEmpty)
        guard !ordered.isEmpty else { return }
        if shuffled {
            player.setShuffle(true)
            player.play(ordered, startingAt: Int.random(in: ordered.indices))
        } else {
            player.play(ordered, startingAt: 0)
        }
    }

    // MARK: Soulseek

    /// Runs a Soulseek search and shows its results.
    func searchSoulseek(_ query: String) {
        soulseek.query = query
        soulseek.search()
        searchText = ""
        selection = .soulseek
    }

    /// "Artist Title" with bracketed edition notes and punctuation dropped, since Soulseek
    /// matches whole words in file paths. Apostrophes join their word ("Tomorrows"), and lone
    /// letters ("A", or the "s" of a split possessive) are left out as too short to match.
    static func soulseekQuery(artist: String, title: String) -> String {
        func clean(_ text: String) -> [Substring] {
            let withoutNotes = text.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
            let base = (withoutNotes.trimmingCharacters(in: .whitespaces).isEmpty ? text : withoutNotes)
                .replacingOccurrences(of: "[’'`]", with: "", options: .regularExpression)
            let kept = String(base.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " })
            let words = kept.split(separator: " ")
            let long = words.filter { $0.count > 1 || $0.allSatisfy(\.isNumber) }
            return long.isEmpty ? words : long
        }
        return (clean(artist) + clean(title)).joined(separator: " ")
    }

    // MARK: Stats

    func listeningStats(for range: ListeningStats.Range) async -> ListeningStats {
        guard let store else { return ListeningStats() }
        let now = Date()
        let calendar = Calendar.current
        let start = ListeningStats.loadStart(for: range, now: now, calendar: calendar)
        let listens = (try? store.listens(since: start)) ?? []
        let plays = (try? store.plays(since: start)) ?? []
        let firstListen = try? store.firstListenDate()
        var info: [Int64: ListeningStats.TrackInfo] = [:]
        for id in Set(listens.map(\.trackID)).union(plays.map(\.trackID)) {
            if let track = tracksByID[id] { info[id] = ListeningStats.TrackInfo(track) }
        }
        return await Task.detached(priority: .userInitiated) {
            ListeningStats.compute(range: range, listens: listens, plays: plays, firstListen: firstListen,
                                   tracks: info, now: now, calendar: calendar)
        }.value
    }

    /// Library tracks of one album, in order (for playing a top album).
    func albumTracks(albumOf track: Track) -> [Track] {
        let key = track.albumKey
        return tracks.filter { $0.albumKey == key }
            .sorted { ($0.discNumber, $0.trackNumber, $0.title) < ($1.discNumber, $1.trackNumber, $1.title) }
    }
}
