import AppKit
import AVFoundation
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Susurrus

/// MusicBrainz release matching, folder naming, cover art in tags and the artwork store. Uses
/// hand-written release JSON and generated files; nothing goes to the network.
@Suite struct ReleaseLookupTests {
    // MARK: Fixtures

    /// A two-disc release: disc 1 has three tracks, disc 2 has two.
    static let releaseJSON = """
    {
      "id": "11111111-2222-3333-4444-555555555555", "title": "Selected Ambient Works", "date": "2004-03-08",
      "country": "GB", "status": "Official",
      "artist-credit": [{"name": "Aphex Twin", "joinphrase": "", "artist": {"id": "a1", "name": "Aphex Twin"}}],
      "release-group": {"id": "rg1", "primary-type": "Album", "first-release-date": "1994-03-07"},
      "label-info": [{"label": {"name": "Warp"}, "catalog-number": "WARPCD21"}],
      "media": [
        {"position": 1, "format": "CD", "track-count": 3, "tracks": [
          {"id": "t1", "position": 1, "title": "Cliffs", "length": 445000},
          {"id": "t2", "position": 2, "title": "Radiator", "length": 300000},
          {"id": "t3", "position": 3, "title": "Rhubarb", "length": 466000, "artist-credit": [
            {"name": "Aphex Twin", "joinphrase": " feat. ", "artist": {"id": "a1", "name": "Aphex Twin"}},
            {"name": "Someone", "joinphrase": "", "artist": {"id": "a2", "name": "Someone"}}]}
        ]},
        {"position": 2, "format": "CD", "track-count": 2, "tracks": [
          {"id": "t4", "position": 1, "title": "Hankie", "length": 210000},
          {"id": "t5", "position": 2, "title": "Grass (Live)", "length": 400000}
        ]}
      ]
    }
    """

    static func release(_ json: String = releaseJSON) throws -> MBRelease {
        try JSONDecoder().decode(MBRelease.self, from: Data(json.utf8))
    }

    /// Tagged the way a careless rip might be: right numbers, sloppy titles, no album artist.
    static let tagged: [ReleaseMatcher.Input] = [
        .init(id: 1, title: "cliffs", artist: "aphex twin", album: "SAW II", trackNumber: 1, discNumber: 1, length: 444.2, path: "/d/01 cliffs.mp3"),
        .init(id: 2, title: "Radiator", artist: "aphex twin", album: "SAW II", trackNumber: 2, discNumber: 1, length: 301, path: "/d/02.mp3"),
        .init(id: 3, title: "Rhubarb", artist: "aphex twin", album: "SAW II", trackNumber: 3, discNumber: 1, length: 466.4, path: "/d/03.mp3"),
        .init(id: 4, title: "Hankie", artist: "aphex twin", album: "SAW II", trackNumber: 1, discNumber: 2, length: 209, path: "/d/2-01.mp3"),
        .init(id: 5, title: "Grass", artist: "aphex twin", album: "SAW II", trackNumber: 2, discNumber: 2, length: 400.5, path: "/d/2-02.mp3"),
    ]

    // MARK: Matching

    @Test func taggedFilesMatchConfidently() throws {
        let match = ReleaseMatcher.match(Self.tagged, to: try Self.release())
        #expect(match.isConfident)
        #expect(match.pairs.count == 5)
        #expect(match.pairs[4]?.slot.disc == 2 && match.pairs[4]?.slot.position == 1)
        #expect(match.pairs[5]?.slot.title == "Grass (Live)")
        #expect(match.score > 0.8)
    }

    @Test func untaggedFilesMatchByFileNameNumbersAndLengths() throws {
        let inputs: [ReleaseMatcher.Input] = [
            .init(id: 1, length: 445, path: "/d/101 - Aphex Twin - Cliffs.flac"),
            .init(id: 2, length: 300, path: "/d/102 - Aphex Twin - Radiator.flac"),
            .init(id: 3, length: 466, path: "/d/103 - Aphex Twin - Rhubarb.flac"),
            .init(id: 4, length: 210, path: "/d/201 - Aphex Twin - Hankie.flac"),
            .init(id: 5, length: 400, path: "/d/202 - Aphex Twin - Grass.flac"),
        ]
        let match = ReleaseMatcher.match(inputs, to: try Self.release())
        #expect(match.isConfident)
        #expect(match.pairs[3]?.slot.title == "Rhubarb")
        #expect(match.pairs[4]?.slot.disc == 2)
    }

    @Test func aMissingTrackOrWrongLengthsIsNotConfident() throws {
        let release = try Self.release()
        let partial = ReleaseMatcher.match(Array(Self.tagged.prefix(4)), to: release)
        #expect(!partial.isConfident, "a track of the release is missing")
        #expect(partial.pairs.count == 4)

        var stretched = Self.tagged
        stretched[1].length = 360  // a minute longer: another version
        #expect(!ReleaseMatcher.match(stretched, to: release).isConfident)

        let extra = Self.tagged + [.init(id: 6, title: "Bonus", trackNumber: 4, discNumber: 1, length: 100)]
        let withExtra = ReleaseMatcher.match(extra, to: release)
        #expect(!withExtra.isConfident)
        #expect(withExtra.pairs[6] == nil)
    }

    @Test func rankingPutsConfidentMatchesFirst() throws {
        let good = ReleaseMatcher.match(Self.tagged, to: try Self.release())
        let other = ReleaseMatcher.match(Array(Self.tagged.prefix(2)), to: try Self.release())
        #expect(ReleaseMatcher.ranked([other, good]).first?.inputCount == 5)
    }

    @Test func editsFollowTheReleaseAndSkipWhatAlreadyAgrees() throws {
        let match = ReleaseMatcher.match(Self.tagged, to: try Self.release())
        let edits = ReleaseMatcher.edits(for: match, inputs: Self.tagged)
        let first = try #require(edits[1])
        #expect(first.title == "Cliffs")
        #expect(first.artist == "Aphex Twin")
        #expect(first.albumArtist == "Aphex Twin")
        #expect(first.album == "Selected Ambient Works")
        #expect(first.year == 1994, "the release group's first year, not this edition's")
        #expect(first.trackNumber == 1 && first.trackCount == 3 && first.discNumber == 1 && first.discCount == 2)
        #expect(first.compilation == nil)
        #expect(edits[2]?.title == nil, "already right")
        #expect(edits[3]?.artist == "Aphex Twin feat. Someone", "per-track credits")
        #expect(edits[4]?.trackCount == 2)

        let titlesOnly = ReleaseMatcher.edits(for: match, inputs: Self.tagged, fields: .titles)
        #expect(titlesOnly[1] == TrackEdit(title: "Cliffs"))
    }

    @Test func variousArtistsReleasesAreCompilations() throws {
        let json = Self.releaseJSON.replacingOccurrences(
            of: #""artist-credit": [{"name": "Aphex Twin", "joinphrase": "", "artist": {"id": "a1", "name": "Aphex Twin"}}]"#,
            with: #""artist-credit": [{"name": "Various Artists", "artist": {"id": "\#(MBRelease.variousArtistsID)", "name": "Various Artists"}}]"#)
        let release = try Self.release(json)
        #expect(release.isVariousArtists)
        let edits = ReleaseMatcher.edits(for: ReleaseMatcher.match(Self.tagged, to: release), inputs: Self.tagged)
        #expect(edits[1]?.albumArtist == "Various Artists")
        #expect(edits[1]?.compilation == true)
    }

    @Test func releaseSummaryAndYear() throws {
        let release = try Self.release()
        #expect(release.year == 1994)
        #expect(release.totalTracks == 5)
        #expect(release.summary == "2×CD · 2004-03-08 · GB · Warp (WARPCD21) · 5 tracks")
    }

    // MARK: Search terms and names

    @Test func searchTermsComeFromTagsThenTheFolderName() {
        #expect(ReleaseMatcher.searchTerms(for: Self.tagged, folderName: "whatever") == ("aphex twin", "SAW II"))
        let untagged = [ReleaseMatcher.Input(id: 1, path: "/x/01.flac")]
        #expect(ReleaseMatcher.searchTerms(for: untagged, folderName: "Boards of Canada - Geogaddi (2002) [FLAC]") == ("Boards of Canada", "Geogaddi"))
        #expect(ReleaseMatcher.parseFolderName("Autechre - 1994 - Amber [WARPCD25]") == ("Autechre", "Amber"))
        #expect(ReleaseMatcher.parseFolderName("2001 - Confield") == ("", "Confield"))
        #expect(ReleaseMatcher.parseFolderName("Music_Has_The_Right {24-96}") == ("", "Music Has The Right"))
    }

    @Test func organizedNamesAreSafe() throws {
        let root = URL(fileURLWithPath: "/m")
        #expect(ReleaseMatcher.albumFolder(under: root, albumArtist: "AC/DC", album: ".Live: 1992", year: 1992).path
            == "/m/AC-DC/Live- 1992 (1992)")
        let slots = ReleaseMatcher.slots(of: try Self.release())
        #expect(ReleaseMatcher.fileName(for: slots[0], extension: "flac") == "1-01 Cliffs.flac")
        var single = slots[0]
        single.discCount = 1
        #expect(ReleaseMatcher.fileName(for: single, extension: "mp3") == "01 Cliffs.mp3")
        #expect(ReleaseMatcher.safeName(String(repeating: "x", count: 300)).count == 120)
    }

    @Test func releaseIDsAreFoundInLinks() {
        #expect(ReleaseIdentifier.releaseID(in: "https://musicbrainz.org/release/1A2B3C4D-0000-1111-2222-333344445555/discids")
            == "1a2b3c4d-0000-1111-2222-333344445555")
        #expect(ReleaseIdentifier.releaseID(in: "not a link") == nil)
    }

    @Test func titleSimilarityIgnoresCaseAndNotes() {
        #expect(ReleaseMatcher.titleSimilarity("Grass (Live)", "grass") == 1)
        #expect(ReleaseMatcher.titleSimilarity("Avril 14th", "Avril 14th (Remastered)") == 1)
        #expect(ReleaseMatcher.titleSimilarity("Xtal", "Tha") == 0)
        #expect(abs(ReleaseMatcher.titleSimilarity("We Are the Music Makers", "Music Makers") - 0.4) < 0.01)
    }

    // MARK: Files and folders

    @Test func unusedURLsAndEmptyFolderCleanup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReleaseLookupTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("Album/CD1")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("a.mp3")
        try Data().write(to: file)
        #expect(AppModel.unusedURL(file).lastPathComponent == "a (2).mp3")
        #expect(AppModel.unusedURL(root.appendingPathComponent("b.mp3")).lastPathComponent == "b.mp3")

        try Data().write(to: nested.appendingPathComponent(".DS_Store"))
        AppModel.removeEmptyFolders(from: nested, upTo: root)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Album").path))
        #expect(FileManager.default.fileExists(atPath: root.path), "never the root itself")
    }

    // MARK: Cover art in tags

    static func jpeg(width: Int = 40, height: Int = 40, red: CGFloat = 1) -> Data {
        image(width: width, height: height, red: red, type: .jpeg)
    }

    static func image(width: Int, height: Int, red: CGFloat, type: UTType) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    private func temp(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ReleaseLookupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    @Test(arguments: [UInt8(3), 4])
    func mp3CoverReplacesTheFrontCoverAndKeepsOtherPictures(version: UInt8) async throws {
        let back: [UInt8] = [0] + Array("image/jpeg".utf8) + [0, 4, 0] + [UInt8](repeating: 0xBB, count: 50)
        let oldFront: [UInt8] = [0] + Array("image/jpeg".utf8) + [0, 3, 0] + [UInt8](repeating: 0xAA, count: 50)
        let url = try temp("cover.mp3")
        try Data(MP3Fixture.id3(version: version, frames: [
            MP3Fixture.text("TIT2", "Song", version: version),
            MP3Fixture.frame("APIC", oldFront, version: version),
            MP3Fixture.frame("APIC", back, version: version),
        ], padding: 16) + MP3Fixture.audio()).write(to: url)

        let cover = Self.jpeg()
        _ = try await TagFileWriter.write(TagValues(artwork: Artwork(data: cover)), to: url)
        let bytes = [UInt8](try Data(contentsOf: url))
        #expect(try ID3Tag.read(bytes).artwork?.data == cover)
        let pictures = try ID3Tag.parse(bytes).frames.compactMap(ID3Tag.picture)
        #expect(pictures.count == 2)
        #expect(pictures.contains { $0.type == 4 && $0.data == [UInt8](repeating: 0xBB, count: 50) }, "the back cover is kept")
        #expect(try ID3Tag.read(bytes).title == "Song")

        // AVFoundation finds the new cover too (what the artwork store reads).
        let items = try await AVURLAsset(url: url).load(.metadata)
        let artwork = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork)
        #expect(!artwork.isEmpty)

        _ = try await TagFileWriter.write(TagValues(artwork: .removed), to: url)
        let cleared = [UInt8](try Data(contentsOf: url))
        #expect(try ID3Tag.read(cleared).artwork == nil)
        #expect(try ID3Tag.parse(cleared).frames.compactMap(ID3Tag.picture).count == 1)
    }

    @Test func id3v22UsesPIC() async throws {
        let url = try temp("old.mp3")
        let tt2: [UInt8] = Array("TT2".utf8) + [0, 0, 5, 0] + Array("Song".utf8)
        let body = tt2 + [UInt8](repeating: 0, count: 16)
        let n = body.count
        try Data([0x49, 0x44, 0x33, 2, 0, 0, 0, 0, UInt8(n >> 7 & 0x7F), UInt8(n & 0x7F)] + body + MP3Fixture.audio()).write(to: url)
        let cover = Self.jpeg()
        _ = try await TagFileWriter.write(TagValues(artwork: Artwork(data: cover)), to: url)
        let tag = try ID3Tag.parse([UInt8](try Data(contentsOf: url)))
        #expect(tag.frames.map(\.id) == ["TT2", "PIC"])
        #expect(try ID3Tag.read([UInt8](try Data(contentsOf: url))).artwork?.data == cover)
    }

    @Test func flacCoverIsAPictureBlock() async throws {
        let url = try temp("cover.flac")
        try FLACFixture.write(to: url, extraComments: ["TITLE=Song"], padding: 64)
        let original = try FLACTag.parse([UInt8](try Data(contentsOf: url)))

        let cover = Self.image(width: 30, height: 20, red: 0.5, type: .png)
        _ = try await TagFileWriter.write(TagValues(artwork: Artwork(data: cover)), to: url)
        let bytes = [UInt8](try Data(contentsOf: url))
        let parsed = try FLACTag.parse(bytes)
        let picture = try #require(parsed.blocks.first { $0.type == 6 }.flatMap(FLACTag.picture))
        #expect(picture.type == 3 && picture.mimeType == "image/png" && picture.data == [UInt8](cover))
        let block = try #require(parsed.blocks.first { $0.type == 6 })
        #expect(block.body.uint32BE(at: 8 + 9 + 4) == 30 && block.body.uint32BE(at: 8 + 9 + 8) == 20, "width and height")
        #expect(try FLACTag.read(bytes).title == "Song")
        #expect(Array(bytes[parsed.audioStart...]) == Array([UInt8](try Data(contentsOf: url))[parsed.audioStart...]))
        #expect(parsed.blocks.filter { $0.type == 0 } == original.blocks.filter { $0.type == 0 }, "STREAMINFO untouched")
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(abs(duration - 0.5) < 0.05)

        // Replacing it keeps one front cover.
        let second = Self.jpeg(red: 0.1)
        _ = try await TagFileWriter.write(TagValues(artwork: Artwork(data: second)), to: url)
        let again = try FLACTag.parse([UInt8](try Data(contentsOf: url)))
        #expect(again.blocks.filter { $0.type == 6 }.count == 1)
        #expect(try FLACTag.read([UInt8](try Data(contentsOf: url))).artwork?.data == second)
    }

    @Test func m4aCoverIsTheCovrItem() async throws {
        let url = try temp("cover.m4a")
        try ToneFile.write(to: url, seconds: 0.3, format: kAudioFormatMPEG4AAC)
        let cover = Self.jpeg()
        _ = try await TagFileWriter.write(TagValues(title: "Song", artwork: Artwork(data: cover)), to: url)
        let stored = try MP4Tag.read([UInt8](try Data(contentsOf: url)))
        #expect(stored.artwork?.data == cover)
        #expect(stored.artwork?.mimeType == "image/jpeg")
        #expect(stored.title == "Song")
        let file = try AVAudioFile(forReading: url)
        #expect(abs(Double(file.length) / file.fileFormat.sampleRate - 0.3) < 0.05)
    }

    @Test func coverEditsMergeAndSurviveBeingSaved() throws {
        let cover = Artwork(data: Self.jpeg())
        let merged = TagValues(title: "A").merged(with: TagValues(artwork: cover))
        #expect(merged.title == "A" && merged.artwork == cover)
        let decoded = try JSONDecoder().decode(TagValues.self, from: try JSONEncoder().encode(merged))
        #expect(decoded == merged)
        #expect(Artwork(data: Self.image(width: 2, height: 2, red: 1, type: .png)).isPNG)
    }

    // MARK: Artwork store

    @Test func artworkStorePrefersFetchedCoversAndFindsFolderImages() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ReleaseLookupTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let music = base.appendingPathComponent("Album")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        let track = music.appendingPathComponent("01.mp3")
        try Data(MP3Fixture.audio()).write(to: track)
        let store = ArtworkStore(diskCache: base.appendingPathComponent("cache"), covers: base.appendingPathComponent("covers"))
        let request = ArtworkRequest(id: "album", filePaths: [track.path])

        #expect(await store.image(for: request, pixelSize: 64) == nil)

        try Self.image(width: 20, height: 20, red: 1, type: .png).write(to: music.appendingPathComponent("Folder.PNG"))
        #expect(ArtworkStore.folderImage(in: music.path)?.lastPathComponent == "Folder.PNG")
        store.forgetMisses()
        #expect(await store.image(for: request, pixelSize: 64) != nil)

        try store.setCover(Self.jpeg(width: 50, height: 30), for: "album")
        let image = try #require(await store.image(for: request, pixelSize: 512))
        let pixels = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(pixels.width > pixels.height, "the fetched cover wins over the (square) folder image")
        #expect(store.fetchedCover(for: "album") != nil)
    }

    @Test func bigCoversAreScaledDown() throws {
        let big = Self.image(width: 2400, height: 1800, red: 0.7, type: .png)
        let prepared = try #require(CoverArt.prepared(big))
        let source = try #require(CGImageSourceCreateWithData(prepared as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 1200)
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)

        let small = Self.jpeg()
        #expect(CoverArt.prepared(small) == small, "reasonable covers are kept as they are")
        #expect(CoverArt.prepared(Data("not an image".utf8)) == nil)
    }
}

/// Against the real MusicBrainz and Cover Art Archive; only with SUSURRUS_LIVE_TESTS=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SUSURRUS_LIVE_TESTS"] == "1"))
struct ReleaseLookupLiveTests {
    @Test func findsAReleaseItsTrackListAndCover() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("ReleaseLookupLive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let service = ArtistInfoService(cacheDirectory: cache)
        let hits = try await service.searchReleases(artist: "Boards of Canada", album: "Geogaddi")
        #expect(!hits.isEmpty)
        #expect(hits.contains { $0.totalTracks >= 20 })
        let release = try await service.release(try #require(hits.first).id)
        let slots = ReleaseMatcher.slots(of: release)
        #expect(slots.count >= 20)
        #expect(slots.allSatisfy { $0.length != nil })
        #expect(release.year == 2002)

        // Files that are exactly that release match it with certainty.
        let inputs = slots.enumerated().map { index, slot in
            ReleaseMatcher.Input(id: Int64(index), title: slot.title, trackNumber: slot.position, discNumber: slot.disc,
                                 length: (slot.length ?? 0) + 0.4, path: "/x/\(index).flac")
        }
        let matches = try await ReleaseIdentifier.candidates(for: inputs, artist: "Boards of Canada", album: "Geogaddi", service: service)
        #expect(matches.first?.isConfident == true)

        let groups = try await service.searchReleaseGroups(artist: "Boards of Canada", album: "Geogaddi")
        let group = try #require(groups.first)
        let cover = try #require(try await service.frontCover(mbid: group.id, releaseGroup: true))
        #expect(NSImage(data: cover) != nil)
    }
}
