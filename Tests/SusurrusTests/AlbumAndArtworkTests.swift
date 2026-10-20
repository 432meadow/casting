import AppKit
import CryptoKit
import Foundation
import Testing
@testable import Susurrus

@Suite struct AlbumTests {
    private func track(_ id: Int64, _ title: String, artist: String, album: String,
                       albumArtist: String = "", compilation: Bool = false, disc: Int = 1, number: Int = 0,
                       year: Int = 0) -> Track {
        let track = Track(id: id)
        track.title = title
        track.artist = artist
        track.album = album
        track.albumArtist = albumArtist
        track.compilation = compilation
        track.discNumber = disc
        track.trackNumber = number
        track.year = year
        return track
    }

    @Test func groupsByAlbumArtistAndOrdersTracks() {
        let tracks = [
            track(1, "B", artist: "X", album: "Alb", disc: 2, number: 1),
            track(2, "A", artist: "X", album: "Alb", disc: 1, number: 2),
            track(3, "C", artist: "X", album: "Alb", disc: 1, number: 1),
            track(4, "Loose", artist: "X", album: ""),
        ]
        let albums = Album.group(tracks, sortedBy: .artist)
        #expect(albums.count == 1, "tracks without an album are left out")
        #expect(albums[0].tracks.map(\.title) == ["C", "A", "B"])
    }

    @Test func compilationsGroupUnderVariousArtists() {
        let tracks = [
            track(1, "One", artist: "Alpha", album: "Comp", compilation: true),
            track(2, "Two", artist: "Beta", album: "Comp", compilation: true),
            track(3, "Solo", artist: "Alpha", album: "Comp"),
        ]
        let albums = Album.group(tracks, sortedBy: .artist)
        #expect(albums.map(\.artist).sorted() == ["Alpha", "Various Artists"])
        #expect(albums.first { $0.artist == "Various Artists" }?.tracks.count == 2)
    }

    @Test func sortOrders() {
        let tracks = [
            track(1, "a", artist: "Zed", album: "Old", year: 1990),
            track(2, "b", artist: "Abe", album: "New", year: 2020),
        ]
        #expect(Album.group(tracks, sortedBy: .artist).map(\.artist) == ["Abe", "Zed"])
        #expect(Album.group(tracks, sortedBy: .title).map(\.title) == ["New", "Old"])
        #expect(Album.group(tracks, sortedBy: .year).map(\.year) == [2020, 1990])
    }
}

@Suite struct ArtworkStoreTests {
    @Test func indexKeyIgnoresUnicodeFormCaseWhitespaceAndSlashes() {
        let composed = "Abençoada"                                  // é as one scalar
        let decomposed = "Abenc\u{0327}oada"                         // c + combining cedilla
        #expect(ArtworkStore.indexKey(artist: composed, album: "X") == ArtworkStore.indexKey(artist: decomposed, album: "x"))
        #expect(ArtworkStore.indexKey(artist: "Xiu Xiu   ", album: "A") == ArtworkStore.indexKey(artist: "xiu xiu", album: "A"))
        #expect(ArtworkStore.indexKey(artist: "AC/DC", album: "A") == ArtworkStore.indexKey(artist: "AC:DC", album: "A"))
    }

    @Test func readsDiskCacheAndRemembersMisses() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let name = SHA256.hash(data: Data("has art".utf8)).map { String(format: "%02x", $0) }.joined() + ".png"
        try Self.pngData(size: 64).write(to: cache.appendingPathComponent(name))

        let store = ArtworkStore(diskCache: cache)
        func request(_ album: String) -> ArtworkRequest {
            // A file path that doesn't exist: if the store tried embedded art it would just fail.
            ArtworkRequest(id: album, filePaths: ["/nonexistent.mp3"])
        }
        let image = await store.image(for: request("has art"), pixelSize: 32)
        #expect(image != nil)
        #expect(await store.image(for: request("no art"), pixelSize: 32) == nil)
        #expect(store.cachedImage(for: request("has art"), pixelSize: 32) != nil, "second lookup hits memory")
    }

    static func pngData(size: Int) -> Data {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.systemPink.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }
}
