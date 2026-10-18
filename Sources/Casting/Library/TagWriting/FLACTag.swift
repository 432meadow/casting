import Foundation

/// Vorbis comments in FLAC files.
///
/// Only the comment block changes: comments for edited fields are replaced, all others (and the
/// vendor string) are kept in order. Other metadata blocks (STREAMINFO, pictures, seek table, …)
/// are copied byte for byte; a PADDING block absorbs the size change when it can, so the audio
/// frames usually stay at the same offset.
enum FLACTag: TagFormat {
    struct Block: Equatable {
        var type: UInt8
        var body: [UInt8]
    }

    struct Parsed {
        /// Offset of "fLaC" (after an ID3v2 tag some taggers put in front, which is kept as is).
        var marker: Int
        var blocks: [Block]
        /// Offset of the first audio frame.
        var audioStart: Int
    }

    struct Comments: Equatable {
        var vendor: [UInt8]
        /// "KEY=value" strings in file order.
        var entries: [String]
    }

    /// Keys per field; the first is written, the rest are aliases that get removed.
    static let keys: [PartialKeyPath<TagValues>: [String]] = [
        \TagValues.title: ["TITLE"],
        \TagValues.artist: ["ARTIST"],
        \TagValues.album: ["ALBUM"],
        \TagValues.albumArtist: ["ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST"],
        \TagValues.genre: ["GENRE"],
        \TagValues.composer: ["COMPOSER"],
        \TagValues.grouping: ["GROUPING"],
        \TagValues.comment: ["COMMENT", "DESCRIPTION"],
        \TagValues.year: ["DATE", "YEAR"],
        \TagValues.bpm: ["BPM"],
        \TagValues.compilation: ["COMPILATION"],
        // RATING is 0–100 (20 per star), as already found in this library's FLAC files.
        \TagValues.rating: ["RATING"],
    ]
    static let trackKeys = ["TRACKNUMBER", "TRACKTOTAL", "TOTALTRACKS"]
    static let discKeys = ["DISCNUMBER", "DISCTOTAL", "TOTALDISCS"]

    static func findMarker(_ bytes: [UInt8]) -> Int? {
        var offset = 0
        if bytes.count >= 10, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33,
           bytes[6..<10].allSatisfy({ $0 < 0x80 }) {
            offset = 10 + (Int(bytes[6]) << 21 | Int(bytes[7]) << 14 | Int(bytes[8]) << 7 | Int(bytes[9]))
            if bytes[5] & 0x10 != 0 { offset += 10 }
        }
        guard offset + 4 <= bytes.count, bytes[offset..<offset + 4].elementsEqual("fLaC".utf8) else { return nil }
        return offset
    }

    static func tagRegion(in prefix: [UInt8]) -> TagRegion {
        guard let marker = findMarker(prefix) else { return .none }
        var pos = marker + 4
        while true {
            guard pos + 4 <= prefix.count else { return .needMore }
            let header = prefix[pos]
            pos += 4 + prefix.uint24BE(at: pos + 1)
            if header & 0x80 != 0 { return .length(pos) }
        }
    }

    static func parse(_ bytes: [UInt8]) throws -> Parsed {
        guard let marker = findMarker(bytes) else { throw TagWriteError.malformed("no fLaC marker") }
        var pos = marker + 4
        var blocks: [Block] = []
        while true {
            guard pos + 4 <= bytes.count else { throw TagWriteError.malformed("metadata runs past the end") }
            let header = bytes[pos]
            let length = bytes.uint24BE(at: pos + 1)
            guard pos + 4 + length <= bytes.count else { throw TagWriteError.malformed("metadata block runs past the end") }
            blocks.append(Block(type: header & 0x7F, body: Array(bytes[pos + 4..<pos + 4 + length])))
            pos += 4 + length
            if header & 0x80 != 0 { break }
        }
        guard blocks.first?.type == 0 else { throw TagWriteError.malformed("STREAMINFO isn't first") }
        guard blocks.filter({ $0.type == 4 }).count <= 1 else { throw TagWriteError.unsupportedTag("More than one Vorbis comment block") }
        return Parsed(marker: marker, blocks: blocks, audioStart: pos)
    }

    static func parseComments(_ body: [UInt8]) throws -> Comments {
        var pos = 0
        func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, pos + count <= body.count else { throw TagWriteError.malformed("truncated Vorbis comment") }
            defer { pos += count }
            return body[pos..<pos + count]
        }
        func length() throws -> Int { let slice = Array(try take(4)); return Int(slice.uint32LE(at: 0)) }
        let vendor = Array(try take(try length()))
        let count = try length()
        var entries: [String] = []
        for _ in 0..<count {
            guard let entry = String(bytes: try take(try length()), encoding: .utf8) else {
                throw TagWriteError.malformed("comment isn't UTF-8")
            }
            entries.append(entry)
        }
        return Comments(vendor: vendor, entries: entries)
    }

    static func encodeComments(_ comments: Comments) -> [UInt8] {
        var out = [UInt8].le32(comments.vendor.count) + comments.vendor + [UInt8].le32(comments.entries.count)
        for entry in comments.entries {
            let utf8 = Array(entry.utf8)
            out += [UInt8].le32(utf8.count) + utf8
        }
        return out
    }

    private static func key(of entry: String) -> String {
        String(entry.prefix { $0 != "=" }).uppercased()
    }

    /// Keys whose comments an edit replaces.
    static func touchedKeys(_ values: TagValues) -> Set<String> {
        var result = Set<String>()
        for field in values.setFields { result.formUnion(keys[field] ?? []) }
        if values.track != nil { result.formUnion(trackKeys) }
        if values.disc != nil { result.formUnion(discKeys) }
        return result
    }

    static func rewrite(_ bytes: [UInt8], with values: TagValues) throws -> [UInt8] {
        let parsed = try parse(bytes)
        var blocks = parsed.blocks
        let commentIndex = blocks.firstIndex { $0.type == 4 }
        var comments = try commentIndex.map { try parseComments(blocks[$0].body) }
            ?? Comments(vendor: Array("casting".utf8), entries: [])

        let touched = touchedKeys(values)
        comments.entries.removeAll { touched.contains(key(of: $0)) }
        func add(_ key: String, _ value: String) { if !value.isEmpty { comments.entries.append("\(key)=\(value)") } }
        func number(_ n: Int) -> String { n > 0 ? String(n) : "" }
        if let v = values.title { add("TITLE", v) }
        if let v = values.artist { add("ARTIST", v) }
        if let v = values.album { add("ALBUM", v) }
        if let v = values.albumArtist { add("ALBUMARTIST", v) }
        if let v = values.genre { add("GENRE", v) }
        if let v = values.composer { add("COMPOSER", v) }
        if let v = values.grouping { add("GROUPING", v) }
        if let v = values.comment { add("COMMENT", v) }
        if let v = values.year { add("DATE", number(v)) }
        if let v = values.track {
            add("TRACKNUMBER", number(v.number))
            add("TRACKTOTAL", number(v.total))
        }
        if let v = values.disc {
            add("DISCNUMBER", number(v.number))
            add("DISCTOTAL", number(v.total))
        }
        if let v = values.bpm { add("BPM", number(v)) }
        if let v = values.compilation { add("COMPILATION", v ? "1" : "") }
        if let v = values.rating { add("RATING", number(Int((v.clamped(to: 0...5) * 20).rounded()))) }

        let body = encodeComments(comments)
        guard body.count < 1 << 24 else { throw TagWriteError.malformed("comments too large") }
        let oldSize: Int
        if let commentIndex {
            oldSize = blocks[commentIndex].body.count
            blocks[commentIndex].body = body
        } else {
            oldSize = -4  // a new block also adds its 4-byte header
            blocks.insert(Block(type: 4, body: body), at: 1)
        }
        // Let padding absorb the difference so the audio doesn't move.
        let growth = body.count - oldSize
        if let padding = blocks.firstIndex(where: { $0.type == 1 }), blocks[padding].body.count >= growth {
            blocks[padding].body = [UInt8](repeating: 0, count: blocks[padding].body.count - growth)
        }

        var out = Array(bytes[..<parsed.marker]) + Array("fLaC".utf8)
        for (index, block) in blocks.enumerated() {
            let last: UInt8 = index == blocks.count - 1 ? 0x80 : 0
            out += [last | block.type] + [UInt8].be24(block.body.count) + block.body
        }
        return out + Array(bytes[parsed.audioStart...])
    }

    static func read(_ bytes: [UInt8]) throws -> TagValues {
        let parsed = try parse(bytes)
        guard let block = parsed.blocks.first(where: { $0.type == 4 }) else { return TagValues() }
        let entries = try parseComments(block.body).entries
        func value(_ key: String) -> String? {
            entries.first { Self.key(of: $0) == key }.map { String($0.drop { $0 != "=" }.dropFirst()) }
        }
        func int(_ key: String) -> Int? { value(key).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
        func pair(_ numberKey: String, _ totalKey: String) -> TagValues.NumberPair? {
            guard value(numberKey) != nil || value(totalKey) != nil else { return nil }
            let (n, t) = TagReader.numberPair(value(numberKey) ?? "")
            return TagValues.NumberPair(number: n, total: int(totalKey) ?? t)
        }
        var values = TagValues()
        values.title = value("TITLE")
        values.artist = value("ARTIST")
        values.album = value("ALBUM")
        values.albumArtist = value("ALBUMARTIST")
        values.genre = value("GENRE")
        values.composer = value("COMPOSER")
        values.grouping = value("GROUPING")
        values.comment = value("COMMENT")
        values.year = value("DATE").flatMap { Int($0.prefix(4)) }
        values.track = pair("TRACKNUMBER", "TRACKTOTAL")
        values.disc = pair("DISCNUMBER", "DISCTOTAL")
        values.bpm = int("BPM")
        values.compilation = value("COMPILATION").map { $0 == "1" }
        values.rating = int("RATING").map { (Double($0) / 10).rounded() / 2 }
        return values
    }

    static func verify(original: [UInt8], rewritten: [UInt8], values: TagValues) throws {
        let before = try parse(original)
        let after: Parsed
        do { after = try parse(rewritten) } catch { throw TagWriteError.verificationFailed("metadata doesn't parse") }
        guard rewritten[..<after.marker] == original[..<before.marker],
              rewritten[after.audioStart...] == original[before.audioStart...] else {
            throw TagWriteError.verificationFailed("audio data differs")
        }
        func others(_ blocks: [Block]) -> [Block] { blocks.filter { $0.type != 4 && $0.type != 1 } }
        guard others(before.blocks) == others(after.blocks) else { throw TagWriteError.verificationFailed("other metadata changed") }
        let touched = touchedKeys(values)
        func untouched(_ parsed: Parsed) throws -> [String] {
            guard let block = parsed.blocks.first(where: { $0.type == 4 }) else { return [] }
            return try parseComments(block.body).entries.filter { !touched.contains(key(of: $0)) }
        }
        guard try untouched(before) == untouched(after) else { throw TagWriteError.verificationFailed("other comments changed") }
        guard values.isSatisfied(by: try read(rewritten)) else { throw TagWriteError.verificationFailed("tags read back differently") }
    }
}
