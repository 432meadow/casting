import Foundation

/// iTunes-style metadata (moov/udta/meta/ilst) in M4A/MP4 files.
///
/// Only `moov` is rebuilt, and inside it only `udta/meta/ilst`: items for edited fields are
/// replaced and every other item is copied byte for byte. If `moov` changes size, a neighbouring
/// `free` atom absorbs it when possible; otherwise the chunk offsets (stco/co64) that point past
/// `moov` are shifted. Ratings aren't written: MP4 has no rating field other players agree on.
/// Fragmented MP4 (moof) is refused.
enum MP4Tag: TagFormat {
    struct Atom {
        var type: [UInt8]
        var start: Int
        var headerSize: Int
        var end: Int
        var payloadStart: Int { start + headerSize }
    }

    static func fourCC(_ string: String) -> [UInt8] { string.unicodeScalars.map { UInt8($0.value) } }

    /// Item atoms per field (the first is written; `gnre` is the old numeric genre, cleared
    /// when a genre is written).
    private static func itemTypes(for field: PartialKeyPath<TagValues>) -> [[UInt8]] {
        switch field {
        case \TagValues.title: [fourCC("©nam")]
        case \TagValues.artist: [fourCC("©ART")]
        case \TagValues.album: [fourCC("©alb")]
        case \TagValues.albumArtist: [fourCC("aART")]
        case \TagValues.genre: [fourCC("©gen"), fourCC("gnre")]
        case \TagValues.composer: [fourCC("©wrt")]
        case \TagValues.grouping: [fourCC("©grp")]
        case \TagValues.comment: [fourCC("©cmt")]
        case \TagValues.year: [fourCC("©day")]
        case \TagValues.track: [fourCC("trkn")]
        case \TagValues.disc: [fourCC("disk")]
        case \TagValues.bpm: [fourCC("tmpo")]
        case \TagValues.compilation: [fourCC("cpil")]
        default: []
        }
    }

    // MARK: Atoms

    static func atoms(in bytes: [UInt8], from start: Int, to end: Int) throws -> [Atom] {
        var result: [Atom] = []
        var pos = start
        while pos + 8 <= end {
            var size = Int(bytes.uint32BE(at: pos))
            var header = 8
            if size == 1 {
                guard pos + 16 <= end else { throw TagWriteError.malformed("truncated atom") }
                let large = bytes.uint64BE(at: pos + 8)
                guard large <= UInt64(Int.max) else { throw TagWriteError.malformed("atom too large") }
                size = Int(large)
                header = 16
            } else if size == 0 {
                size = end - pos
            }
            guard size >= header, pos + size <= end else { throw TagWriteError.malformed("atom runs past its parent") }
            result.append(Atom(type: Array(bytes[pos + 4..<pos + 8]), start: pos, headerSize: header, end: pos + size))
            pos += size
        }
        guard pos == end || end - pos < 8 && bytes[pos..<end].allSatisfy({ $0 == 0 }) else {
            throw TagWriteError.malformed("stray bytes between atoms")
        }
        return result
    }

    private static func children(of atom: Atom, in bytes: [UInt8], skipping extra: Int = 0) throws -> [Atom] {
        try atoms(in: bytes, from: atom.payloadStart + extra, to: atom.end)
    }

    /// `meta` is normally a full box (4 bytes of version/flags before its children); some
    /// QuickTime writers omit those.
    private static func metaChildOffset(_ meta: Atom, in bytes: [UInt8]) -> Int {
        let p = meta.payloadStart
        if p + 8 <= meta.end, bytes[p + 4..<p + 8].elementsEqual("hdlr".utf8) { return 0 }
        return 4
    }

    private static func atom(type: [UInt8], payload: [UInt8]) -> [UInt8] {
        [UInt8].be32(8 + payload.count) + type + payload
    }

    struct Layout {
        var top: [Atom]
        var moov: Atom
        var udta: Atom?
        var meta: Atom?
        var ilst: Atom?
    }

    static func layout(_ bytes: [UInt8]) throws -> Layout {
        let top = try atoms(in: bytes, from: 0, to: bytes.count)
        let moovs = top.filter { $0.type == fourCC("moov") }
        guard moovs.count == 1, let moov = moovs.first else { throw TagWriteError.malformed("expected one moov atom") }
        guard !top.contains(where: { $0.type == fourCC("moof") }) else { throw TagWriteError.unsupportedTag("Fragmented MP4") }
        let udta = try children(of: moov, in: bytes).first { $0.type == fourCC("udta") }
        let meta = try udta.flatMap { try children(of: $0, in: bytes).first { $0.type == fourCC("meta") } }
        let ilst = try meta.flatMap { meta in
            try children(of: meta, in: bytes, skipping: metaChildOffset(meta, in: bytes)).first { $0.type == fourCC("ilst") }
        }
        return Layout(top: top, moov: moov, udta: udta, meta: meta, ilst: ilst)
    }

    // MARK: Writing

    static func rewrite(_ bytes: [UInt8], with values: TagValues) throws -> [UInt8] {
        var values = values
        values.rating = nil
        guard !values.isEmpty else { return bytes }
        let layout = try layout(bytes)

        // New ilst
        var items: [(type: [UInt8], raw: [UInt8])] = try layout.ilst.map { ilst in
            try children(of: ilst, in: bytes).map { ($0.type, Array(bytes[$0.start..<$0.end])) }
        } ?? []
        func set(_ field: PartialKeyPath<TagValues>, dataType: UInt8, value: [UInt8]?) {
            let types = itemTypes(for: field)
            let index = items.firstIndex { types.contains($0.type) }
            items.removeAll { types.contains($0.type) }
            guard let value else { return }
            let data = atom(type: fourCC("data"), payload: [0, 0, 0, dataType, 0, 0, 0, 0] + value)
            items.insert((types[0], atom(type: types[0], payload: data)), at: index ?? items.count)
        }
        func text(_ field: KeyPath<TagValues, String?>) {
            guard let value = values[keyPath: field] else { return }
            set(field, dataType: 1, value: value.isEmpty ? nil : Array(value.utf8))
        }
        func pair(_ field: KeyPath<TagValues, TagValues.NumberPair?>, trailing: Int) {
            guard let value = values[keyPath: field] else { return }
            let empty = value.number == 0 && value.total == 0
            let payload = [0, 0] + [UInt8].be16(value.number) + [UInt8].be16(value.total) + [UInt8](repeating: 0, count: trailing)
            set(field, dataType: 0, value: empty ? nil : payload)
        }
        text(\.title)
        text(\.artist)
        text(\.album)
        text(\.albumArtist)
        text(\.genre)
        text(\.composer)
        text(\.grouping)
        text(\.comment)
        if let year = values.year { set(\TagValues.year, dataType: 1, value: year > 0 ? Array(String(year).utf8) : nil) }
        pair(\.track, trailing: 2)
        pair(\.disc, trailing: 0)
        if let bpm = values.bpm { set(\TagValues.bpm, dataType: 21, value: bpm > 0 ? [UInt8].be16(min(bpm, 0x7FFF)) : nil) }
        if let compilation = values.compilation { set(\TagValues.compilation, dataType: 21, value: compilation ? [1] : nil) }
        let ilst = atom(type: fourCC("ilst"), payload: items.flatMap(\.raw))

        // Rebuild meta → udta → moov around it, copying every sibling as is.
        func rebuilt(_ parent: Atom?, type: String, prefix: [UInt8], replacing child: Atom?, with new: [UInt8], defaults: [UInt8] = []) throws -> [UInt8] {
            guard let parent else { return atom(type: fourCC(type), payload: prefix + defaults + new) }
            let extra = type == "meta" ? metaChildOffset(parent, in: bytes) : 0
            var payload = Array(bytes[parent.payloadStart..<parent.payloadStart + extra])
            var placed = false
            for c in try children(of: parent, in: bytes, skipping: extra) {
                if let child, c.start == child.start {
                    payload += new
                    placed = true
                } else {
                    payload += bytes[c.start..<c.end]
                }
            }
            if !placed { payload += new }
            return atom(type: fourCC(type), payload: payload)
        }
        let handler = atom(type: fourCC("hdlr"), payload: [0, 0, 0, 0, 0, 0, 0, 0] + fourCC("mdirappl") + [UInt8](repeating: 0, count: 9))
        let meta = try rebuilt(layout.meta, type: "meta", prefix: [0, 0, 0, 0], replacing: layout.ilst, with: ilst, defaults: handler)
        let udta = try rebuilt(layout.udta, type: "udta", prefix: [], replacing: layout.meta, with: meta)
        var moov = try rebuilt(layout.moov, type: "moov", prefix: [], replacing: layout.udta, with: udta)

        // Keep the audio where it is if a free atom next to moov can take up the difference.
        let moov0 = layout.moov
        var delta = moov.count - (moov0.end - moov0.start)
        var tail = moov0.end
        var filler: [UInt8] = []
        if let next = layout.top.first(where: { $0.start == moov0.end }), next.type == fourCC("free") || next.type == fourCC("skip"),
           next.end - next.start - delta >= 8 {
            filler = atom(type: fourCC("free"), payload: [UInt8](repeating: 0, count: next.end - next.start - delta - 8))
            tail = next.end
            delta = 0
        } else if delta <= -8 {
            filler = atom(type: fourCC("free"), payload: [UInt8](repeating: 0, count: -delta - 8))
            delta = 0
        }
        if delta != 0 { try shiftChunkOffsets(in: &moov, after: moov0.end, by: delta) }
        return Array(bytes[..<moov0.start]) + moov + filler + Array(bytes[tail...])
    }

    /// stco/co64 tables inside a moov atom's bytes, as (entry offset in `moov`, is 64-bit, count).
    private static func chunkTables(in moov: [UInt8]) throws -> [(start: Int, wide: Bool, count: Int)] {
        var tables: [(Int, Bool, Int)] = []
        func walk(_ from: Int, _ to: Int) throws {
            for a in try atoms(in: moov, from: from, to: to) {
                switch String(decoding: a.type, as: UTF8.self) {
                case "trak", "mdia", "minf", "stbl":
                    try walk(a.payloadStart, a.end)
                case "stco", "co64":
                    let wide = a.type == fourCC("co64")
                    guard a.payloadStart + 8 <= a.end else { throw TagWriteError.malformed("short chunk table") }
                    let count = Int(moov.uint32BE(at: a.payloadStart + 4))
                    guard a.payloadStart + 8 + count * (wide ? 8 : 4) <= a.end else { throw TagWriteError.malformed("short chunk table") }
                    tables.append((a.payloadStart + 8, wide, count))
                default: break
                }
            }
        }
        let top = try atoms(in: moov, from: 0, to: moov.count)
        guard let root = top.first else { return [] }
        try walk(root.payloadStart, root.end)
        return tables
    }

    private static func chunkOffsets(in moov: [UInt8]) throws -> [Int] {
        try chunkTables(in: moov).flatMap { table in
            (0..<table.count).map { i in
                table.wide ? Int(moov.uint64BE(at: table.start + i * 8)) : Int(moov.uint32BE(at: table.start + i * 4))
            }
        }
    }

    private static func shiftChunkOffsets(in moov: inout [UInt8], after boundary: Int, by delta: Int) throws {
        for table in try chunkTables(in: moov) {
            for i in 0..<table.count {
                if table.wide {
                    let at = table.start + i * 8
                    let offset = Int(moov.uint64BE(at: at))
                    guard offset >= boundary else { continue }
                    let new = offset + delta
                    moov.replaceSubrange(at..<at + 8, with: [UInt8].be32(new >> 32) + [UInt8].be32(new & 0xFFFF_FFFF))
                } else {
                    let at = table.start + i * 4
                    let offset = Int(moov.uint32BE(at: at))
                    guard offset >= boundary else { continue }
                    let new = offset + delta
                    guard new >= 0, new <= Int(UInt32.max) else { throw TagWriteError.unsupportedTag("A chunk offset past 4 GB") }
                    moov.replaceSubrange(at..<at + 4, with: [UInt8].be32(new))
                }
            }
        }
    }

    // MARK: Reading back

    static func read(_ bytes: [UInt8]) throws -> TagValues {
        let layout = try layout(bytes)
        guard let ilst = layout.ilst else { return TagValues() }
        var data: [[UInt8]: [UInt8]] = [:]
        for item in try children(of: ilst, in: bytes) where data[item.type] == nil {
            guard let d = try children(of: item, in: bytes).first(where: { $0.type == fourCC("data") }),
                  d.payloadStart + 8 <= d.end else { continue }
            data[item.type] = Array(bytes[d.payloadStart + 8..<d.end])
        }
        func text(_ type: String) -> String? { data[fourCC(type)].map { String(decoding: $0, as: UTF8.self) } }
        func pair(_ type: String) -> TagValues.NumberPair? {
            data[fourCC(type)].map { let (n, t) = TagReader.mp4Pair(Data($0)); return TagValues.NumberPair(number: n, total: t) }
        }
        var values = TagValues()
        values.title = text("©nam")
        values.artist = text("©ART")
        values.album = text("©alb")
        values.albumArtist = text("aART")
        values.genre = text("©gen")
        values.composer = text("©wrt")
        values.grouping = text("©grp")
        values.comment = text("©cmt")
        values.year = text("©day").flatMap { Int($0.prefix(4)) }
        values.track = pair("trkn")
        values.disc = pair("disk")
        values.bpm = data[fourCC("tmpo")].flatMap { $0.count >= 2 ? Int($0[0]) << 8 | Int($0[1]) : nil }
        values.compilation = data[fourCC("cpil")].map { $0.first == 1 }
        return values
    }

    // MARK: Verifying

    static func verify(original: [UInt8], rewritten: [UInt8], values: TagValues) throws {
        var values = values
        values.rating = nil
        values.key = nil
        let before = try layout(original)
        let after: Layout
        do { after = try layout(rewritten) } catch { throw TagWriteError.verificationFailed("atoms don't parse") }

        // Every top-level atom other than moov and padding is identical, in order.
        func others(_ layout: Layout, _ bytes: [UInt8]) -> [ArraySlice<UInt8>] {
            layout.top.filter { ![fourCC("moov"), fourCC("free"), fourCC("skip")].contains($0.type) }.map { bytes[$0.start..<$0.end] }
        }
        guard others(before, original) == others(after, rewritten) else { throw TagWriteError.verificationFailed("audio data differs") }

        // Every chunk offset still points at the same audio bytes.
        let oldOffsets = try chunkOffsets(in: Array(original[before.moov.start..<before.moov.end]))
        let newOffsets = try chunkOffsets(in: Array(rewritten[after.moov.start..<after.moov.end]))
        guard oldOffsets.count == newOffsets.count else { throw TagWriteError.verificationFailed("chunk tables changed") }
        for (old, new) in zip(oldOffsets, newOffsets) {
            let length = min(32, original.count - old)
            guard old >= 0, new >= 0, length > 0, new + length <= rewritten.count,
                  rewritten[new..<new + length] == original[old..<old + length] else {
                throw TagWriteError.verificationFailed("chunk offsets don't line up")
            }
        }

        // moov's other children are unchanged apart from those chunk offsets.
        func moovChildren(_ layout: Layout, _ bytes: [UInt8]) throws -> [[UInt8]] {
            try children(of: layout.moov, in: bytes).filter { $0.type != fourCC("udta") && $0.type != fourCC("trak") }.map { Array(bytes[$0.start..<$0.end]) }
        }
        guard try moovChildren(before, original) == moovChildren(after, rewritten) else {
            throw TagWriteError.verificationFailed("other movie metadata changed")
        }

        var touched = Set<[UInt8]>()
        for field in values.setFields { touched.formUnion(itemTypes(for: field)) }
        func untouched(_ layout: Layout, _ bytes: [UInt8]) throws -> [ArraySlice<UInt8>] {
            guard let ilst = layout.ilst else { return [] }
            return try children(of: ilst, in: bytes).filter { !touched.contains($0.type) }.map { bytes[$0.start..<$0.end] }
        }
        guard try untouched(before, original) == untouched(after, rewritten) else {
            throw TagWriteError.verificationFailed("other items changed")
        }
        guard values.isSatisfied(by: try read(rewritten)) else { throw TagWriteError.verificationFailed("tags read back differently") }
    }
}
