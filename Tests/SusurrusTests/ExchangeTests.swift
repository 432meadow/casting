import Foundation
import Testing
@testable import Susurrus

private func track(_ id: Int64, _ path: String, title: String = "", artist: String = "", length: Double = 0) -> Track {
    let track = Track(id: id)
    track.path = path
    track.title = title
    track.artist = artist
    track.length = length
    return track
}

@Suite struct M3UTests {
    @Test func roundTripsRelativeAndAbsolutePaths() {
        let tracks = [
            track(1, "/Volumes/Music/Artist/Album/01 Song.mp3", title: "Song", artist: "Artist", length: 241.4),
            track(2, "/Volumes/Music/Other/Café, Live #2.flac", title: "Café, Live #2", length: 59.6),
            track(3, "/Users/someone/Downloads/loose.m4a"),
        ]
        let directory = "/Volumes/Music/Playlists"
        for style in M3UPlaylist.PathStyle.allCases {
            let text = M3UPlaylist.text(for: tracks.map(M3UPlaylist.entry), style: style, directory: directory)
            let parsed = M3UPlaylist.parse(text, directory: directory)
            #expect(parsed.map(\.path) == tracks.map(\.path))
            #expect(parsed.map(\.duration) == [241, 60, nil])
            #expect(parsed.map(\.title) == ["Artist - Song", "Café, Live #2", "loose"])
        }

        let relative = M3UPlaylist.text(for: tracks.map(M3UPlaylist.entry), style: .relative, directory: directory)
        let lines = relative.split(separator: "\n").map(String.init)
        #expect(lines.first == "#EXTM3U")
        #expect(lines[1] == "#EXTINF:241,Artist - Song")
        #expect(lines[2] == "../Artist/Album/01 Song.mp3")
        // Only the root in common (another volume): stays absolute.
        #expect(lines[6] == "/Users/someone/Downloads/loose.m4a")
    }

    @Test func readsOtherAppsPlaylists() {
        let text = """
            #EXTM3U
            #PLAYLIST:Old
            #EXTINF:200,A - B
            file:///Volumes/Music/A%20B/track.mp3
            Sub\\Dir\\win.mp3
            ./here/../there.mp3
            http://radio.example/stream
            ~/Music/home.mp3

            """
        let parsed = M3UPlaylist.parse(text, directory: "/Volumes/Music/Lists")
        #expect(parsed.map(\.path) == [
            "/Volumes/Music/A B/track.mp3",
            "/Volumes/Music/Lists/Sub/Dir/win.mp3",
            "/Volumes/Music/Lists/there.mp3",
            NSHomeDirectory() + "/Music/home.mp3",
        ])
        #expect(parsed[0].title == "A - B" && parsed[0].duration == 200)
        #expect(parsed[1].title == nil)
    }

    @Test func decodesUTF8WithBOMAndLatin1() {
        #expect(M3UPlaylist.decode(Data([0xEF, 0xBB, 0xBF]) + Data("/a/é.mp3".utf8)) == "/a/é.mp3")
        #expect(M3UPlaylist.decode(Data([0x2F, 0x61, 0x2F, 0xE9, 0x2E, 0x6D, 0x70, 0x33])) == "/a/é.mp3")
    }

    @Test func matchesPathsSpelledDifferently() {
        let matcher = TrackPathMatcher([track(7, "/Volumes/Music/Café/Song.mp3")])
        #expect(matcher.trackID(forPath: "/Volumes/Music/Café/Song.mp3") == 7)
        #expect(matcher.trackID(forPath: "/Volumes/Music/Cafe\u{301}/song.MP3") == 7)
        #expect(matcher.trackID(forPath: "/Volumes/Music/x/../Café/Song.mp3") == 7)
        #expect(matcher.trackID(forPath: "/Volumes/Music/Other.mp3") == nil)
    }

    @Test func writesAtomically() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("list.m3u8")
        try ExchangeFile.write(Data("old".utf8), to: url)
        try ExchangeFile.write(Data("new".utf8), to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "new")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["list.m3u8"])
    }
}

@Suite struct AppleLibraryImportTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// A small Library.xml as Music exports it, generated here.
    func fixture() throws -> Data {
        func trackDict(_ id: Int, _ location: String?, _ extra: [String: Any] = [:]) -> [String: Any] {
            var dict: [String: Any] = ["Track ID": id, "Name": "Track \(id)", "Kind": "MPEG audio file"]
            if let location { dict["Location"] = location }
            return dict.merging(extra) { $1 }
        }
        let tracks: [String: Any] = [
            "101": trackDict(101, "file://localhost/Volumes/Music/A/Caf%C3%A9.mp3", [
                "Rating": 80, "Play Count": 12, "Skip Count": 3,
                "Play Date UTC": now, "Date Added": now.addingTimeInterval(-86_400 * 400),
            ]),
            "102": trackDict(102, "file:///Volumes/Music/A/Two.mp3", ["Rating": 60, "Rating Computed": true, "Play Count": 1]),
            "103": trackDict(103, "file://localhost/Volumes/Music/New/Three.flac", ["Rating": 100]),
            "104": trackDict(104, "file://localhost/Volumes/Gone/Four.mp3"),
            "105": trackDict(105, nil),  // a stream or cloud item
        ]
        let playlists: [[String: Any]] = [
            ["Name": "Library", "Master": true, "Visible": false, "Playlist Persistent ID": "AAA0",
             "Playlist Items": [["Track ID": 101], ["Track ID": 102]]],
            ["Name": "Music", "Distinguished Kind": 4, "Playlist Persistent ID": "AAA1",
             "Playlist Items": [["Track ID": 101]]],
            // Listed before its folder, which happens.
            ["Name": "Warm Up", "Playlist Persistent ID": "BBB2", "Parent Persistent ID": "BBB1",
             "Playlist Items": [["Track ID": 102], ["Track ID": 101], ["Track ID": 104], ["Track ID": 103]]],
            ["Name": "Sets", "Folder": true, "Playlist Persistent ID": "BBB1"],
            ["Name": "Loose", "Playlist Persistent ID": "BBB3", "Playlist Items": [["Track ID": 101]]],
        ]
        let root: [String: Any] = ["Major Version": 1, "Minor Version": 1, "Tracks": tracks, "Playlists": playlists]
        return try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
    }

    @Test func parsesTracksAndPlaylists() throws {
        let library = try ITunesLibrary(data: try fixture())
        #expect(library.tracks.count == 5)
        let first = try #require(library.tracks[101])
        #expect(first.path == "/Volumes/Music/A/Café.mp3")
        #expect(first.rating == 80 && first.playCount == 12 && first.skipCount == 3)
        #expect(first.lastPlayed == now)
        #expect(library.tracks[102]?.rating == nil)  // computed from the album
        #expect(library.tracks[102]?.path == "/Volumes/Music/A/Two.mp3")
        #expect(library.tracks[105]?.path == nil)

        #expect(library.skippedBuiltInPlaylists == 2)
        #expect(library.playlists.map(\.name) == ["Warm Up", "Sets", "Loose"])
        #expect(library.playlists[0].trackIDs == [102, 101, 104, 103])
        #expect(library.playlistsParentsFirst.map(\.name) == ["Sets", "Loose", "Warm Up"])
    }

    @Test func rejectsOtherFiles() {
        #expect(throws: ITunesLibrary.ParseError.self) { try ITunesLibrary(data: Data("<html></html>".utf8)) }
    }

    @Test func plansOnlyImprovements() throws {
        let library = try ITunesLibrary(data: try fixture())
        let cafe = track(1, "/Volumes/Music/A/Cafe\u{301}.mp3")  // decomposed, as on HFS+
        cafe.playCount = 20
        cafe.dateAdded = now.addingTimeInterval(-86_400)
        let two = track(2, "/Volumes/Music/A/Two.mp3")
        two.rating = 3
        two.playCount = 5
        two.lastPlayed = now
        let plan = LibraryImportPlan(library: library, tracks: [cafe, two], fileExists: { $0.hasPrefix("/Volumes/Music/") })

        #expect(plan.trackMap == [101: 1, 102: 2])
        #expect(plan.addablePaths == ["/Volumes/Music/New/Three.flac"])
        #expect(plan.missingCount == 2)
        #expect(plan.playlistCount == 2 && plan.folderCount == 1 && plan.skippedBuiltInPlaylists == 2)
        // Rating where there was none, the later last-played and earlier date added; susurrus's
        // higher play count stays.
        #expect(plan.changes == [LibraryImportPlan.Change(trackID: 1, rating: 4, playCount: nil, lastPlayed: now,
                                                          dateAdded: now.addingTimeInterval(-86_400 * 400))])
        #expect(plan.ratingCount == 1 && plan.playCountCount == 0 && plan.lastPlayedCount == 1 && plan.dateAddedCount == 1)
    }

    @Test func storeSavesImportedValues() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Library.sqlite")
        let store = try LibraryStore(url: url)
        try store.insert([ScannedTrack(path: "/music/a.mp3")])
        let id = try #require(try store.loadTracks().first?.id)
        try store.setImportedValues([ImportedTrackValues(trackID: id, rating: 4.5, playCount: 9, lastPlayed: now, dateAdded: nil)])
        let saved = try #require(try store.loadTracks().first)
        #expect(saved.rating == 4.5 && saved.playCount == 9 && saved.lastPlayed == now && saved.dateAdded == nil)
    }
}

@Suite struct RekordboxExportTests {
    @Test func documentHasTheRekordboxShape() throws {
        let a = track(11, "/Volumes/Music/A & B/Café #1.mp3", title: "Café #1", artist: "A & B", length: 301.6)
        a.bpm = 124
        a.musicalKey = "8A"
        a.rating = 4
        a.playCount = 7
        a.fileSize = 7_340_032
        a.year = 1999
        a.dateAdded = DateComponents(calendar: .current, year: 2024, month: 3, day: 9, hour: 12).date
        let b = track(12, "/Volumes/Music/b.flac", title: "B")
        b.rating = 2.5
        let grid = BeatGrid(bpm: 124.03, firstBeat: 0.1234)
        let xml = RekordboxXML.document(
            tracks: [a, b], beatGrids: [11: grid],
            playlists: [.folder(name: "Sets", children: [.playlist(name: "Warm <Up>", trackIDs: [12, 11])]),
                        .playlist(name: "Empty", trackIDs: [])],
            version: "1.2.3")

        let document = try XMLDocument(xmlString: xml)
        let root = try #require(document.rootElement())
        #expect(root.name == "DJ_PLAYLISTS")
        #expect(try document.nodes(forXPath: "/DJ_PLAYLISTS/PRODUCT/@Name").first?.stringValue == "susurrus")
        let collection = try #require(try document.nodes(forXPath: "/DJ_PLAYLISTS/COLLECTION").first as? XMLElement)
        #expect(collection.attribute(forName: "Entries")?.stringValue == "2")

        let tracks = try document.nodes(forXPath: "/DJ_PLAYLISTS/COLLECTION/TRACK").compactMap { $0 as? XMLElement }
        #expect(tracks.count == 2)
        func value(_ element: XMLElement, _ name: String) -> String? { element.attribute(forName: name)?.stringValue }
        let first = tracks[0]
        #expect(value(first, "TrackID") == "11")
        #expect(value(first, "Name") == "Café #1")
        #expect(value(first, "Artist") == "A & B")
        #expect(value(first, "Kind") == "MP3 File")
        #expect(value(first, "Size") == "7340032")
        #expect(value(first, "TotalTime") == "302")
        #expect(value(first, "Year") == "1999")
        #expect(value(first, "AverageBpm") == "124.03")
        #expect(value(first, "Tonality") == "Am")
        #expect(value(first, "Rating") == "204")
        #expect(value(first, "PlayCount") == "7")
        #expect(value(first, "DateAdded") == "2024-03-09")
        #expect(value(first, "Location") == "file://localhost/Volumes/Music/A%20%26%20B/Caf%C3%A9%20%231.mp3")
        #expect(URL(string: value(first, "Location")!)?.path == a.path)
        let tempo = try #require(first.elements(forName: "TEMPO").first)
        #expect(value(tempo, "Inizio") == "0.123" && value(tempo, "Bpm") == "124.03")
        #expect(value(tempo, "Metro") == "4/4" && value(tempo, "Battito") == "1")

        #expect(value(tracks[1], "Rating") == "153")  // 2½ stars round up
        #expect(value(tracks[1], "Tonality") == nil)
        #expect(tracks[1].elements(forName: "TEMPO").isEmpty)

        let rootNode = try #require(try document.nodes(forXPath: "/DJ_PLAYLISTS/PLAYLISTS/NODE").first as? XMLElement)
        #expect(value(rootNode, "Type") == "0" && value(rootNode, "Name") == "ROOT" && value(rootNode, "Count") == "2")
        let warmUp = try #require(try document.nodes(forXPath: "//NODE[@Name='Sets']/NODE").first as? XMLElement)
        #expect(value(warmUp, "Name") == "Warm <Up>")
        #expect(value(warmUp, "Type") == "1" && value(warmUp, "KeyType") == "0" && value(warmUp, "Entries") == "2")
        #expect(warmUp.elements(forName: "TRACK").compactMap { value($0, "Key") } == ["12", "11"])
    }

    @Test func ratingsAndKinds() {
        #expect([0, 1, 2, 3, 4, 5].map { RekordboxXML.rating(forStars: Double($0)) } == [0, 51, 102, 153, 204, 255])
        #expect(RekordboxXML.kind(forPath: "/a.M4A") == "M4A File")
        #expect(RekordboxXML.kind(forPath: "/a.aiff") == "AIFF File")
        #expect(RekordboxXML.escape("a\u{1}b\"c") == "ab&quot;c")
    }

    @Test func beatGridsAreRemembered() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        BeatGridCache(url: url).remember(BeatGrid(bpm: 128, firstBeat: 0.5), forTrack: 42)
        #expect(BeatGridCache(url: url).all == [42: BeatGrid(bpm: 128, firstBeat: 0.5)])
    }
}

/// The app-level flows, against a throwaway library: playlists created, values saved, one undo.
@MainActor
@Suite struct ExchangeAppModelTests {
    @Test func importsPlaylistsAndLibraryWithOneUndo() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = AppModel(libraryURL: folder.appendingPathComponent("Library.sqlite"))
        let store = try #require(model.store)
        let a = folder.appendingPathComponent("a.mp3").path, b = folder.appendingPathComponent("b.mp3").path
        try store.insert([ScannedTrack(path: a, title: "A"), ScannedTrack(path: b, title: "B")])
        try model.reload()

        let list = folder.appendingPathComponent("Set.m3u8")
        try "#EXTM3U\nb.mp3\n#EXTINF:10,Gone\ngone.mp3\n\(a)\n".write(to: list, atomically: true, encoding: .utf8)
        let summary = await model.importPlaylist(at: list, into: nil)
        #expect(summary.contains("2 in the library") && summary.contains("1 not found") && summary.contains("Gone"))
        let imported = try #require(model.playlists.first { $0.name == "Set" })
        #expect(try store.trackIDs(inPlaylist: imported.id) == [b, a].compactMap { model.track(atPath: $0)?.id })

        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        let root: [String: Any] = [
            "Tracks": ["1": ["Track ID": 1, "Location": URL(fileURLWithPath: a).absoluteString, "Rating": 100, "Play Count": 4]],
            "Playlists": [
                ["Name": "Folder", "Folder": true, "Playlist Persistent ID": "F"],
                ["Name": "Inside", "Parent Persistent ID": "F", "Playlist Persistent ID": "P", "Playlist Items": [["Track ID": 1]]],
            ],
        ]
        let library = try ITunesLibrary(data: try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0))
        model.applyLibraryImport(library, plan: LibraryImportPlan(library: library, tracks: model.tracks, fileExists: { _ in false }))

        func check(imported: Bool) throws {
            let track = try #require(model.track(atPath: a))
            #expect(track.rating == (imported ? 5 : 0) && track.playCount == (imported ? 4 : 0))
            let saved = try #require(try store.loadTracks().first { $0.path == a })
            #expect(saved.rating == track.rating)
            let wrapper = model.playlists.first { $0.name == AppModel.importFolderName }
            #expect((wrapper != nil) == imported)
            if let wrapper {
                let inner = try #require(wrapper.children?.first)
                #expect(inner.name == "Folder" && inner.children?.map(\.name) == ["Inside"])
                #expect(try store.trackIDs(inPlaylist: inner.children![0].id) == [track.id])
            }
        }
        try check(imported: true)
        #expect(undo.undoActionName == "Import Library")
        undo.undo()
        try check(imported: false)
        undo.redo()
        try check(imported: true)
    }
}
