import Foundation

/// Tracks grouped by album artist + album title, for the art grid.
struct Album: Identifiable, Hashable {
    enum Sort: String, CaseIterable, Identifiable {
        case artist = "Artist"
        case title = "Album"
        case year = "Year"
        case recentlyAdded = "Recently Added"
        var id: Self { self }
    }

    let id: String
    let title: String
    let artist: String
    let year: Int
    /// Newest `dateAdded` among the album's tracks.
    let lastAdded: Double
    /// In disc, then track-number order.
    let tracks: [Track]

    static func == (lhs: Album, rhs: Album) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var duration: Double { tracks.reduce(0) { $0 + $1.length } }

    /// Whose artist page the album belongs on: its artist, or for a compilation the artist of
    /// its tracks when they all share one.
    var pageArtist: String? {
        if !(tracks.first?.compilation ?? false), !artist.isEmpty, artist != "Various Artists" { return artist }
        let artists = Set(tracks.map(\.displayArtist).filter { !$0.isEmpty })
        return artists.count == 1 ? artists.first : nil
    }

    var artworkRequest: ArtworkRequest {
        ArtworkRequest(id: id, filePaths: tracks.prefix(3).map(\.path))
    }

    /// Groups tracks into albums. Tracks without an album name are left out.
    static func group(_ tracks: [Track], sortedBy sort: Sort) -> [Album] {
        var buckets: [String: [Track]] = [:]
        for track in tracks where !track.album.isEmpty {
            buckets[track.albumKey, default: []].append(track)
        }

        var albums = buckets.map { key, tracks -> Album in
            let first = tracks[0]
            return Album(
                id: key,
                title: first.album,
                artist: first.albumGroupArtist,
                year: tracks.map(\.year).max() ?? 0,
                lastAdded: tracks.map(\.dateAddedSortKey).max() ?? 0,
                tracks: tracks.sorted { ($0.discNumber, $0.trackNumber, $0.title) < ($1.discNumber, $1.trackNumber, $1.title) }
            )
        }

        func byText(_ a: String, _ b: String) -> Bool? {
            let order = a.localizedStandardCompare(b)
            return order == .orderedSame ? nil : order == .orderedAscending
        }
        albums.sort { a, b in
            switch sort {
            case .artist:
                return byText(a.artist, b.artist) ?? (a.year != b.year ? a.year < b.year : byText(a.title, b.title) ?? false)
            case .title:
                return byText(a.title, b.title) ?? byText(a.artist, b.artist) ?? false
            case .year:
                return a.year != b.year ? a.year > b.year : byText(a.artist, b.artist) ?? false
            case .recentlyAdded:
                return a.lastAdded != b.lastAdded ? a.lastAdded > b.lastAdded : byText(a.title, b.title) ?? false
            }
        }
        return albums
    }
}

extension Track {
    /// The artist an album is filed under: album artist, else "Various Artists" for compilations, else artist.
    var albumGroupArtist: String {
        if !albumArtist.isEmpty { return albumArtist }
        if compilation { return "Various Artists" }
        return artist
    }

    var albumKey: String {
        ArtworkStore.indexKey(artist: albumGroupArtist, album: album)
    }

    /// Artwork for this track's album. Shares the album's cache entry.
    var artworkRequest: ArtworkRequest {
        ArtworkRequest(id: albumKey, filePaths: [path])
    }
}
