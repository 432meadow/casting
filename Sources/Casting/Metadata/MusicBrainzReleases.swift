import Foundation
import ImageIO
import UniformTypeIdentifiers

/// "Artist A feat. Artist B": MusicBrainz artist credits, joined the way they're printed.
struct MBArtistCredit: Decodable, Hashable, Sendable {
    struct Artist: Decodable, Hashable, Sendable {
        var id: String
        var name: String
    }

    var name: String
    var joinphrase: String?
    var artist: Artist?
}

extension [MBArtistCredit] {
    var text: String { map { $0.name + ($0.joinphrase ?? "") }.joined() }
    var isVariousArtists: Bool { count == 1 && first?.artist?.id == MBRelease.variousArtistsID }
}

/// One edition of an album: its track list per disc, credits and release group.
struct MBRelease: Decodable, Identifiable, Hashable, Sendable {
    static let variousArtistsID = "89ad4ac3-39f7-470e-963a-56509c546377"

    struct Group: Decodable, Hashable, Sendable {
        var id: String
        var primaryType: String?
        var firstReleaseDate: String?

        enum CodingKeys: String, CodingKey {
            case id
            case primaryType = "primary-type"
            case firstReleaseDate = "first-release-date"
        }
    }

    struct Medium: Decodable, Hashable, Sendable {
        var position: Int?
        var format: String?
        var trackCount: Int?
        var tracks: [Track]?

        enum CodingKeys: String, CodingKey {
            case position, format, tracks
            case trackCount = "track-count"
        }
    }

    struct Track: Decodable, Hashable, Sendable {
        var id: String
        var position: Int?
        var title: String
        /// Milliseconds.
        var length: Int?
        var artistCredit: [MBArtistCredit]?

        enum CodingKeys: String, CodingKey {
            case id, position, title, length
            case artistCredit = "artist-credit"
        }
    }

    struct LabelInfo: Decodable, Hashable, Sendable {
        struct Label: Decodable, Hashable, Sendable { var name: String }
        var label: Label?
        var catalogNumber: String?

        enum CodingKeys: String, CodingKey {
            case label
            case catalogNumber = "catalog-number"
        }
    }

    var id: String
    var title: String
    var score: Int?
    var date: String?
    var country: String?
    var status: String?
    var trackCount: Int?
    var artistCredit: [MBArtistCredit]?
    var releaseGroup: Group?
    var media: [Medium]?
    var labelInfo: [LabelInfo]?

    enum CodingKeys: String, CodingKey {
        case id, title, score, date, country, status, media
        case trackCount = "track-count"
        case artistCredit = "artist-credit"
        case releaseGroup = "release-group"
        case labelInfo = "label-info"
    }

    var artist: String { artistCredit?.text ?? "" }
    var isVariousArtists: Bool { artistCredit?.isVariousArtists ?? false }

    /// The year it first came out (the release group's), else this edition's.
    var year: Int? {
        (releaseGroup?.firstReleaseDate).flatMap { Int($0.prefix(4)) } ?? date.flatMap { Int($0.prefix(4)) }
    }

    var totalTracks: Int {
        if let media, media.contains(where: { $0.tracks != nil || $0.trackCount != nil }) {
            return media.reduce(0) { $0 + ($1.tracks?.count ?? $1.trackCount ?? 0) }
        }
        return trackCount ?? 0
    }

    /// "CD · 2003 · GB · Warp (WARPCD123)" style line.
    var summary: String {
        var parts: [String] = []
        let formats = (media ?? []).compactMap(\.format)
        if let format = formats.first {
            parts.append(formats.count > 1 ? "\(formats.count)×\(format)" : format)
        }
        if let date, !date.isEmpty { parts.append(date) }
        if let country, !country.isEmpty { parts.append(country) }
        if let label = labelInfo?.first?.label?.name {
            let catalog = labelInfo?.first?.catalogNumber.map { " (\($0))" } ?? ""
            parts.append(label + catalog)
        }
        parts.append("\(totalTracks) tracks")
        return parts.joined(separator: " · ")
    }

    var url: URL { URL(string: "https://musicbrainz.org/release/\(id)")! }
}

/// A release group as album search returns it (for cover lookups).
struct MBReleaseGroupHit: Decodable, Hashable, Sendable {
    var id: String
    var title: String
    var score: Int?
    var artistCredit: [MBArtistCredit]?

    enum CodingKeys: String, CodingKey {
        case id, title, score
        case artistCredit = "artist-credit"
    }
}

extension ArtistInfoService {
    /// Releases titled like `album` by `artist` (any artist when empty), best search match first.
    func searchReleases(artist: String, album: String) async throws -> [MBRelease] {
        struct Response: Decodable { var releases: [MBRelease] }
        var query = "release:\"\(Self.escaped(album))\""
        if !artist.isEmpty { query += " AND artist:\"\(Self.escaped(artist))\"" }
        return try await fetch(Response.self, from: Self.musicBrainzURL("release", ["query": query, "limit": "15"])).releases
    }

    /// A release with its track lists, credits, release group and labels.
    func release(_ mbid: String) async throws -> MBRelease {
        try await fetch(MBRelease.self, from: Self.musicBrainzURL("release/\(mbid)", ["inc": "recordings artist-credits release-groups labels"]))
    }

    func searchReleaseGroups(artist: String, album: String) async throws -> [MBReleaseGroupHit] {
        struct Response: Decodable {
            var releaseGroups: [MBReleaseGroupHit]
            enum CodingKeys: String, CodingKey { case releaseGroups = "release-groups" }
        }
        var query = "releasegroup:\"\(Self.escaped(album))\""
        if !artist.isEmpty { query += " AND artist:\"\(Self.escaped(artist))\"" }
        return try await fetch(Response.self, from: Self.musicBrainzURL("release-group", ["query": query, "limit": "10"])).releaseGroups
    }

    /// The front cover from the Cover Art Archive, at most 1200 px, or nil if it has none.
    /// `releaseGroup` asks for the group's chosen cover instead of one edition's.
    func frontCover(mbid: String, releaseGroup: Bool = false) async throws -> Data? {
        let base = "https://coverartarchive.org/\(releaseGroup ? "release-group" : "release")/\(mbid)/front"
        for size in ["-1200", "-500", ""] {
            do {
                return CoverArt.prepared(try await download(URL(string: base + size)!))
            } catch let error as ServiceError where error.message == "Not found" {
                // No thumbnail at this size (or no cover at all); try the next.
                continue
            }
        }
        return nil
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

enum CoverArt {
    /// Covers larger than this are scaled down before they're stored or embedded in files.
    static let maxPixels = 1200

    /// The image as is when it's a reasonable JPEG/PNG, else re-encoded as a JPEG of at most
    /// `maxPixels`. nil if it isn't an image.
    static func prepared(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let type = CGImageSourceGetType(source) as String?
        if max(width, height) <= maxPixels + 200, data.count <= 1_500_000,
           type == UTType.jpeg.identifier || type == UTType.png.identifier {
            return data
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
