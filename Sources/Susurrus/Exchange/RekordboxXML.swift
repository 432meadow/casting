import Foundation

/// Rekordbox's library exchange format (`DJ_PLAYLISTS`), as Rekordbox reads it through
/// Preferences ▸ Advanced ▸ rekordbox xml: a COLLECTION of TRACK elements and a PLAYLISTS tree
/// whose entries point back at them by TrackID.
enum RekordboxXML {
    indirect enum Node: Equatable {
        case folder(name: String, children: [Node])
        case playlist(name: String, trackIDs: [Int64])
    }

    /// Everything from the track's database row; no audio file is read.
    static func document(tracks: [Track], beatGrids: [Int64: BeatGrid], playlists: [Node], version: String) -> String {
        var xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <DJ_PLAYLISTS Version="1.0.0">
              <PRODUCT Name="susurrus" Version="\(escape(version))" Company=""/>
              <COLLECTION Entries="\(tracks.count)">

            """
        for track in tracks {
            let grid = beatGrids[track.id]
            xml += "    <TRACK" + attributes(for: track, grid: grid).map { " \($0.0)=\"\(escape($0.1))\"" }.joined()
            if let grid {
                // One tempo for the whole track, starting at its first beat (Battito 1 of a 4/4 bar).
                xml += ">\n      <TEMPO Inizio=\"\(String(format: "%.3f", grid.firstBeat))\" Bpm=\"\(String(format: "%.2f", grid.bpm))\" Metro=\"4/4\" Battito=\"1\"/>\n    </TRACK>\n"
            } else {
                xml += "/>\n"
            }
        }
        xml += "  </COLLECTION>\n  <PLAYLISTS>\n"
        xml += node(.folder(name: "ROOT", children: playlists), indent: "    ")
        xml += "  </PLAYLISTS>\n</DJ_PLAYLISTS>\n"
        return xml
    }

    private static func node(_ node: Node, indent: String) -> String {
        switch node {
        case let .folder(name, children):
            var xml = "\(indent)<NODE Type=\"0\" Name=\"\(escape(name))\" Count=\"\(children.count)\">\n"
            for child in children { xml += self.node(child, indent: indent + "  ") }
            return xml + "\(indent)</NODE>\n"
        case let .playlist(name, trackIDs):
            // KeyType 0: entries name tracks by TrackID (1 would mean by Location).
            var xml = "\(indent)<NODE Type=\"1\" Name=\"\(escape(name))\" KeyType=\"0\" Entries=\"\(trackIDs.count)\">\n"
            for id in trackIDs { xml += "\(indent)  <TRACK Key=\"\(id)\"/>\n" }
            return xml + "\(indent)</NODE>\n"
        }
    }

    private static func attributes(for track: Track, grid: BeatGrid?) -> [(String, String)] {
        var result: [(String, String)] = [
            ("TrackID", "\(track.id)"),
            ("Name", track.title.isEmpty ? (track.fileName as NSString).deletingPathExtension : track.title),
            ("Artist", track.artist),
            ("Composer", track.composer),
            ("Album", track.album),
            ("Grouping", track.grouping),
            ("Genre", track.genre),
            ("Kind", kind(forPath: track.path)),
            ("Size", "\(track.fileSize)"),
            ("TotalTime", "\(Int(track.length.rounded()))"),
            ("DiscNumber", "\(track.discNumber)"),
            ("TrackNumber", "\(track.trackNumber)"),
            ("Year", "\(track.year)"),
            // The fitted grid's tempo is finer than the whole-number tag.
            ("AverageBpm", String(format: "%.2f", grid?.bpm ?? Double(track.bpm))),
        ]
        if let added = track.dateAdded { result.append(("DateAdded", dateFormatter.string(from: added))) }
        result += [
            ("BitRate", "\(track.bitRate)"),
            ("SampleRate", "\(track.sampleRate)"),
            ("Comments", track.comment),
            ("PlayCount", "\(track.playCount)"),
            ("Rating", "\(rating(forStars: track.rating))"),
            ("Location", location(forPath: track.path)),
        ]
        // Standard notation (Am, F#, Ebm) is what Rekordbox itself writes here.
        if let key = track.key { result.append(("Tonality", key.name)) }
        return result
    }

    /// Rekordbox stores whole stars as 0, 51, 102, 153, 204, 255; half stars round up.
    static func rating(forStars stars: Double) -> Int {
        Int((stars.clamped(to: 0...5)).rounded(.toNearestOrAwayFromZero)) * 51
    }

    /// `file://localhost/` and the path with everything outside a small safe set percent-encoded
    /// as UTF-8 (Rekordbox decodes it; a stray `#` or `%` left as is would break the path).
    static func location(forPath path: String) -> String {
        "file://localhost" + (path.addingPercentEncoding(withAllowedCharacters: locationAllowed) ?? path)
    }

    private static let locationAllowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")

    static func kind(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "mp3": "MP3 File"
        case "m4a", "m4b", "mp4", "aac", "alac": "M4A File"
        case "flac": "FLAC File"
        case "wav": "WAV File"
        case "aif", "aiff", "aifc": "AIFF File"
        case let other: "\(other.uppercased()) File"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Escapes for an attribute value and drops characters XML 1.0 can't hold at all.
    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            case "\n": result += "&#10;"
            case "\r": result += "&#13;"
            case "\t": result += "&#9;"
            default:
                if scalar.value >= 0x20, scalar.value != 0xFFFE, scalar.value != 0xFFFF { result.unicodeScalars.append(scalar) }
            }
        }
        return result
    }
}
