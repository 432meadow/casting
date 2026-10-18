import CryptoKit
import Foundation

/// A MusicBrainz artist.
struct MBArtist: Decodable, Identifiable, Hashable, Sendable {
    struct LifeSpan: Decodable, Hashable, Sendable {
        var begin: String?
        var end: String?
        var ended: Bool?
    }

    struct Genre: Decodable, Hashable, Sendable {
        var name: String
        var count: Int?
    }

    struct Relation: Decodable, Hashable, Sendable {
        struct Target: Decodable, Hashable, Sendable { var resource: String }
        var type: String
        var url: Target?
    }

    var id: String
    var name: String
    var disambiguation: String?
    var type: String?
    var country: String?
    var score: Int?
    var lifeSpan: LifeSpan?
    var genres: [Genre]?
    var relations: [Relation]?

    enum CodingKeys: String, CodingKey {
        case id, name, disambiguation, type, country, score, genres, relations
        case lifeSpan = "life-span"
    }

    /// "Group · GB · 1986–" style line.
    var summary: String {
        var parts: [String] = []
        if let type, !type.isEmpty { parts.append(type) }
        if let country, !country.isEmpty { parts.append(country) }
        if let begin = lifeSpan?.begin?.prefix(4), !begin.isEmpty {
            let end = lifeSpan?.end?.prefix(4) ?? ""
            parts.append(lifeSpan?.ended == true || !end.isEmpty ? "\(begin)–\(end)" : "\(begin)–")
        }
        return parts.joined(separator: " · ")
    }

    var wikidataID: String? {
        relations?.first { $0.type == "wikidata" }?.url.map { URL(string: $0.resource)?.lastPathComponent ?? "" }
    }

    /// Homepage, Bandcamp, Discogs and the like, in a fixed order.
    var links: [(title: String, url: URL)] {
        let wanted: [(type: String, title: String)] = [
            ("official homepage", "Website"), ("bandcamp", "Bandcamp"), ("discogs", "Discogs"),
            ("soundcloud", "SoundCloud"), ("allmusic", "AllMusic"),
        ]
        var result: [(String, URL)] = []
        for entry in wanted {
            if let resource = relations?.first(where: { $0.type == entry.type })?.url?.resource, let url = URL(string: resource) {
                result.append((entry.title, url))
            }
        }
        result.append(("MusicBrainz", URL(string: "https://musicbrainz.org/artist/\(id)")!))
        return result
    }

    var topGenres: [String] {
        (genres ?? []).sorted { ($0.count ?? 0) > ($1.count ?? 0) }.prefix(6).map(\.name)
    }
}

/// A MusicBrainz release group: one album, EP or single, across all its editions.
struct MBReleaseGroup: Decodable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var primaryType: String?
    var secondaryTypes: [String]?
    var firstReleaseDate: String?

    enum CodingKeys: String, CodingKey {
        case id, title
        case primaryType = "primary-type"
        case secondaryTypes = "secondary-types"
        case firstReleaseDate = "first-release-date"
    }

    var year: Int? { firstReleaseDate.flatMap { Int($0.prefix(4)) } }

    /// Albums and EPs with no secondary type: the studio discography.
    var isMainRelease: Bool {
        (primaryType == "Album" || primaryType == "EP") && (secondaryTypes ?? []).isEmpty
    }

    var typeLabel: String {
        let types = [primaryType ?? "Other"] + (secondaryTypes ?? [])
        return types.joined(separator: " · ")
    }
}

struct WikipediaSummary: Decodable, Hashable, Sendable {
    struct Thumbnail: Decodable, Hashable, Sendable { var source: String }
    struct ContentURLs: Decodable, Hashable, Sendable {
        struct Desktop: Decodable, Hashable, Sendable { var page: String }
        var desktop: Desktop
    }

    var extract: String
    var thumbnail: Thumbnail?
    var contentUrls: ContentURLs?

    enum CodingKeys: String, CodingKey {
        case extract, thumbnail
        case contentUrls = "content_urls"
    }

    var pageURL: URL? { contentUrls.flatMap { URL(string: $0.desktop.page) } }
    var imageURL: URL? { thumbnail.flatMap { URL(string: $0.source) } }
}

struct SimilarArtist: Decodable, Hashable, Identifiable, Sendable {
    var artistMbid: String
    var name: String
    var score: Int?

    var id: String { artistMbid }

    enum CodingKeys: String, CodingKey {
        case name, score
        case artistMbid = "artist_mbid"
    }
}

/// Artist details from MusicBrainz (matching, discography, links, genres), Wikipedia (biography)
/// and ListenBrainz (similar artists). None of them need an account or a key.
///
/// MusicBrainz allows one request a second per client, so requests to it are spaced out.
/// Responses are cached on disk for two weeks, and a stale copy is used when the network fails.
actor ArtistInfoService {
    static let shared = ArtistInfoService()

    struct ServiceError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let session: URLSession
    private let cacheDirectory: URL
    private var lastMusicBrainzRequest = Date.distantPast
    private static let cacheLifetime: TimeInterval = 14 * 86_400
    private static let userAgent = "casting/1.0 (https://github.com/432meadow/casting)"

    init(cacheDirectory: URL? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent, "Accept": "application/json"]
        session = URLSession(configuration: configuration)
        self.cacheDirectory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("casting/ArtistInfo", isDirectory: true)
    }

    // MARK: MusicBrainz

    func searchArtists(_ name: String) async throws -> [MBArtist] {
        struct Response: Decodable { var artists: [MBArtist] }
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let url = Self.musicBrainzURL("artist", ["query": "artist:\"\(escaped)\"", "limit": "8"])
        return try await fetch(Response.self, from: url).artists
    }

    func artist(_ mbid: String) async throws -> MBArtist {
        try await fetch(MBArtist.self, from: Self.musicBrainzURL("artist/\(mbid)", ["inc": "url-rels genres"]))
    }

    /// Every release group credited to the artist (up to 500), oldest first.
    func releaseGroups(_ mbid: String) async throws -> [MBReleaseGroup] {
        struct Response: Decodable {
            var releaseGroups: [MBReleaseGroup]
            var count: Int
            enum CodingKeys: String, CodingKey {
                case count = "release-group-count"
                case releaseGroups = "release-groups"
            }
        }
        var groups: [MBReleaseGroup] = []
        while groups.count < 500 {
            let url = Self.musicBrainzURL("release-group", ["artist": mbid, "limit": "100", "offset": String(groups.count)])
            let page = try await fetch(Response.self, from: url)
            groups += page.releaseGroups
            if page.releaseGroups.isEmpty || groups.count >= page.count { break }
        }
        return groups.sorted { ($0.firstReleaseDate ?? "9999", $0.title) < ($1.firstReleaseDate ?? "9999", $1.title) }
    }

    // MARK: Wikipedia

    /// The English Wikipedia summary for a Wikidata item, if it has an article.
    func wikipediaSummary(wikidataID: String) async throws -> WikipediaSummary? {
        struct Entities: Decodable {
            struct Entity: Decodable {
                struct Sitelink: Decodable { var title: String }
                var sitelinks: [String: Sitelink]?
            }
            var entities: [String: Entity]
        }
        let entityURL = URL(string: "https://www.wikidata.org/wiki/Special:EntityData/\(wikidataID).json")!
        let entities = try await fetch(Entities.self, from: entityURL)
        guard let title = entities.entities.values.first?.sitelinks?["enwiki"]?.title else { return nil }
        let path = title.replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?"))) ?? title
        return try await fetch(WikipediaSummary.self, from: URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(path)")!)
    }

    // MARK: ListenBrainz

    /// Artists whose listeners also listen to this one, most similar first.
    func similarArtists(_ mbid: String) async throws -> [SimilarArtist] {
        var components = URLComponents(string: "https://labs.api.listenbrainz.org/similar-artists/json")!
        components.queryItems = [
            URLQueryItem(name: "artist_mbids", value: mbid),
            URLQueryItem(name: "algorithm", value: "session_based_days_7500_session_300_contribution_5_threshold_10_limit_100_filter_True_skip_30"),
        ]
        return Array(try await fetch([SimilarArtist].self, from: components.url!).prefix(24))
    }

    // MARK: Fetching

    private static func musicBrainzURL(_ path: String, _ query: [String: String]) -> URL {
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/\(path)")!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            + [URLQueryItem(name: "fmt", value: "json")]
        return components.url!
    }

    private func fetch<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        let cacheURL = cacheFile(for: url)
        let cached = try? Data(contentsOf: cacheURL)
        if let cached,
           let modified = try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(modified) < Self.cacheLifetime,
           let value = try? JSONDecoder().decode(T.self, from: cached) {
            return value
        }

        do {
            let data = try await download(url)
            let value = try JSONDecoder().decode(T.self, from: data)
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
            return value
        } catch {
            if let cached, let value = try? JSONDecoder().decode(T.self, from: cached) { return value }
            throw error
        }
    }

    private func download(_ url: URL) async throws -> Data {
        let isMusicBrainz = url.host == "musicbrainz.org"
        for attempt in 0..<3 {
            if isMusicBrainz {
                let wait = 1.1 - Date().timeIntervalSince(lastMusicBrainzRequest)
                lastMusicBrainzRequest = Date().addingTimeInterval(max(0, wait))
                if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            }
            let (data, response) = try await session.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 503 is MusicBrainz asking to slow down.
            if status == 503 || status == 429, attempt < 2 {
                try await Task.sleep(for: .seconds(2 * Double(attempt + 1)))
                continue
            }
            guard (200..<300).contains(status) else {
                throw ServiceError(message: status == 404 ? "Not found" : "\(url.host ?? "The server") answered \(status)")
            }
            return data
        }
        throw ServiceError(message: "\(url.host ?? "The server") is busy; try again in a moment")
    }

    private func cacheFile(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(digest + ".json")
    }
}
