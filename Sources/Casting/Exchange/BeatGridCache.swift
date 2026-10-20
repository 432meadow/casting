import Foundation

/// The beat grids the mixer has fitted (one per track loaded on a deck), kept so exports can
/// include them without reading any audio. A small JSON file next to the library database.
final class BeatGridCache {
    private struct Entry: Codable {
        var bpm: Double
        var firstBeat: Double
    }

    let url: URL
    private var grids: [Int64: BeatGrid]?

    init(url: URL = LibraryStore.defaultURL.deletingLastPathComponent().appendingPathComponent("BeatGrids.json")) {
        self.url = url
    }

    var all: [Int64: BeatGrid] {
        if let grids { return grids }
        var loaded: [Int64: BeatGrid] = [:]
        if let data = try? Data(contentsOf: url), let entries = try? JSONDecoder().decode([String: Entry].self, from: data) {
            for (key, entry) in entries {
                if let id = Int64(key) { loaded[id] = BeatGrid(bpm: entry.bpm, firstBeat: entry.firstBeat) }
            }
        }
        grids = loaded
        return loaded
    }

    func remember(_ grid: BeatGrid, forTrack id: Int64) {
        var updated = all
        guard updated[id] != grid else { return }
        updated[id] = grid
        grids = updated
        let entries = Dictionary(uniqueKeysWithValues: updated.map { (String($0.key), Entry(bpm: $0.value.bpm, firstBeat: $0.value.firstBeat)) })
        if let data = try? JSONEncoder().encode(entries) { try? ExchangeFile.write(data, to: url) }
    }
}
