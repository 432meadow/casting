import Foundation

/// The tag fields to write into one file. nil = leave that field in the file alone;
/// an empty string or 0 = remove it from the file.
struct TagValues: Equatable, Sendable, Codable {
    struct NumberPair: Equatable, Sendable, Codable {
        var number: Int
        var total: Int
    }

    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var genre: String?
    var composer: String?
    var grouping: String?
    var comment: String?
    var year: Int?
    var track: NumberPair?
    var disc: NumberPair?
    var bpm: Int?
    /// Standard notation ("Am"). Not written to MP4 files, which have no standard key item.
    var key: String?
    var compilation: Bool?
    /// 0–5 in half-star steps.
    var rating: Double?
    /// The front cover. Empty data removes the file's front covers; other pictures are kept.
    var artwork: Artwork?

    var isEmpty: Bool { self == TagValues() }

    /// Key paths of the fields that are set.
    var setFields: [PartialKeyPath<TagValues>] {
        let all: [(PartialKeyPath<TagValues>, Bool)] = [
            (\.title, title != nil), (\.artist, artist != nil), (\.album, album != nil),
            (\.albumArtist, albumArtist != nil), (\.genre, genre != nil), (\.composer, composer != nil),
            (\.grouping, grouping != nil), (\.comment, comment != nil), (\.year, year != nil),
            (\.track, track != nil), (\.disc, disc != nil), (\.bpm, bpm != nil), (\.key, key != nil),
            (\.compilation, compilation != nil), (\.rating, rating != nil), (\.artwork, artwork != nil),
        ]
        return all.filter(\.1).map(\.0)
    }

    /// The fields `edit` changes, with values taken from `track` after the edit was applied
    /// (so "track 3" keeps the track's existing "of 12").
    init(edit: TrackEdit, track: Track) {
        if edit.title != nil { title = track.title }
        if edit.artist != nil { artist = track.artist }
        if edit.album != nil { album = track.album }
        if edit.albumArtist != nil { albumArtist = track.albumArtist }
        if edit.genre != nil { genre = track.genre }
        if edit.composer != nil { composer = track.composer }
        if edit.grouping != nil { grouping = track.grouping }
        if edit.comment != nil { comment = track.comment }
        if edit.year != nil { year = track.year }
        if edit.trackNumber != nil || edit.trackCount != nil {
            self.track = NumberPair(number: track.trackNumber, total: track.totalNumberOfTracks)
        }
        if edit.discNumber != nil || edit.discCount != nil {
            disc = NumberPair(number: track.discNumber, total: track.totalNumberOfDiscs)
        }
        if edit.bpm != nil { bpm = track.bpm }
        if edit.musicalKey != nil { key = track.musicalKey }
        if edit.compilation != nil { compilation = track.compilation }
        if edit.rating != nil { rating = track.rating }
    }

    init(title: String? = nil, artist: String? = nil, album: String? = nil, albumArtist: String? = nil,
         genre: String? = nil, composer: String? = nil, grouping: String? = nil, comment: String? = nil,
         year: Int? = nil, track: NumberPair? = nil, disc: NumberPair? = nil, bpm: Int? = nil,
         key: String? = nil, compilation: Bool? = nil, rating: Double? = nil, artwork: Artwork? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.genre = genre
        self.composer = composer
        self.grouping = grouping
        self.comment = comment
        self.year = year
        self.track = track
        self.disc = disc
        self.bpm = bpm
        self.key = key
        self.compilation = compilation
        self.rating = rating
        self.artwork = artwork
    }

    /// Later values win; used to merge edits queued for the same file.
    func merged(with newer: TagValues) -> TagValues {
        var result = self
        if let v = newer.title { result.title = v }
        if let v = newer.artist { result.artist = v }
        if let v = newer.album { result.album = v }
        if let v = newer.albumArtist { result.albumArtist = v }
        if let v = newer.genre { result.genre = v }
        if let v = newer.composer { result.composer = v }
        if let v = newer.grouping { result.grouping = v }
        if let v = newer.comment { result.comment = v }
        if let v = newer.year { result.year = v }
        if let v = newer.track { result.track = v }
        if let v = newer.disc { result.disc = v }
        if let v = newer.bpm { result.bpm = v }
        if let v = newer.key { result.key = v }
        if let v = newer.compilation { result.compilation = v }
        if let v = newer.rating { result.rating = v }
        if let v = newer.artwork { result.artwork = v }
        return result
    }

    /// Whether every field set here has the same value in `stored` (a tag read back from a file).
    /// Removed fields (empty / 0 / false) must read back as absent, which `stored` reports the same way.
    func isSatisfied(by stored: TagValues) -> Bool {
        func same(_ wanted: String?, _ got: String?) -> Bool { wanted == nil || wanted == (got ?? "") }
        func same(_ wanted: Int?, _ got: Int?) -> Bool { wanted == nil || wanted == (got ?? 0) }
        func same(_ wanted: NumberPair?, _ got: NumberPair?) -> Bool {
            wanted == nil || wanted == (got ?? NumberPair(number: 0, total: 0))
        }
        return same(title, stored.title) && same(artist, stored.artist) && same(album, stored.album)
            && same(albumArtist, stored.albumArtist) && same(genre, stored.genre) && same(composer, stored.composer)
            && same(grouping, stored.grouping) && same(comment, stored.comment) && same(year, stored.year)
            && same(track, stored.track) && same(disc, stored.disc) && same(bpm, stored.bpm) && same(key, stored.key)
            && (compilation == nil || compilation == (stored.compilation ?? false))
            && (rating == nil || rating == (stored.rating ?? 0))
            && (artwork.map { $0.data.isEmpty ? stored.artwork == nil : stored.artwork?.data == $0.data } ?? true)
    }

    /// "3/12", "3", or "" for (0, 0). A total without a number is written as "0/12".
    static func numberText(_ pair: NumberPair) -> String {
        if pair.number == 0 && pair.total == 0 { return "" }
        return pair.total > 0 ? "\(pair.number)/\(pair.total)" : "\(pair.number)"
    }
}

/// An embedded picture: the image bytes as stored in the file, and their type.
struct Artwork: Equatable, Sendable, Codable {
    var data: Data
    /// "image/jpeg" or "image/png".
    var mimeType: String

    /// Takes the type from the image's first bytes (JPEG unless it's a PNG).
    init(data: Data) {
        self.data = data
        mimeType = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
    }

    init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }

    /// Removes the front cover.
    static let removed = Artwork(data: Data(), mimeType: "")

    var isPNG: Bool { mimeType == "image/png" }
}

/// Star ratings ↔ the byte stored in ID3 POPM frames. These are the values MusicBee writes and
/// that most players read back; whole stars also land in the ranges
/// Windows Media Player uses.
enum POPMRating {
    private static let table: [(stars: Double, byte: UInt8)] = [
        (0, 0), (0.5, 13), (1, 1), (1.5, 54), (2, 64), (2.5, 118), (3, 128), (3.5, 186), (4, 196), (4.5, 242), (5, 255),
    ]

    static func byte(for rating: Double) -> UInt8 {
        let half = (rating.clamped(to: 0...5) * 2).rounded() / 2
        return table.first { $0.stars == half }?.byte ?? 0
    }

    static func rating(for byte: UInt8) -> Double {
        if let exact = table.first(where: { $0.byte == byte }) { return exact.stars }
        // Other players' values: WMP's ranges for whole stars.
        switch byte {
        case 0: return 0
        case 1...31: return 1
        case 32...95: return 2
        case 96...159: return 3
        case 160...223: return 4
        default: return 5
        }
    }
}
