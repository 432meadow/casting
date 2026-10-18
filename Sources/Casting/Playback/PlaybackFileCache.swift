import AVFoundation
import Foundation

/// Identifies a track's file without touching the (main-actor) `Track` object.
struct TrackRef: Sendable, Hashable {
    let id: Int64
    let path: String
}

/// Makes audio files safe to play from a network share.
///
/// AVAudioPlayerNode reads lazily from the file while playing. For files on SMB that means every
/// network hiccup stalls the audio, and for FLAC without a seek table AudioToolbox scans the
/// whole file (`FLACAudioFile::ScanForPackets`) over the network. So files on non-local volumes
/// are copied into a small local cache first; local files are played in place.
actor PlaybackFileCache {
    private let directory: URL
    private let capacity: Int
    /// One task per track, so the current and prefetched next track never copy twice.
    private var tasks: [Int64: Task<URL?, Never>] = [:]
    /// Track ids, least recently used first.
    private var recent: [Int64] = []

    init(
        directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("casting/Playback"),
        capacity: Int = 8
    ) {
        self.directory = directory
        self.capacity = capacity
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// A readable local URL for the track, or nil if the file can't be found.
    func localURL(for track: TrackRef, locate: @escaping @Sendable (TrackRef) -> URL?) async -> URL? {
        touch(track.id)
        if let existing = tasks[track.id] { return await existing.value }

        let directory = directory
        let task = Task.detached(priority: .userInitiated) { () -> URL? in
            guard let source = locate(track) else { return nil }
            let isLocal = (try? source.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) ?? true
            if isLocal { return source }

            let destination = directory.appendingPathComponent("\(track.id).\(source.pathExtension)")
            let partial = destination.appendingPathExtension("partial")
            do {
                try? FileManager.default.removeItem(at: partial)
                try FileManager.default.copyItem(at: source, to: partial)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: partial, to: destination)
                return destination
            } catch {
                // Copy failed (share dropped mid-copy, disk full): fall back to streaming from the share.
                try? FileManager.default.removeItem(at: partial)
                return source
            }
        }
        tasks[track.id] = task
        evict()
        return await task.value
    }

    /// Formats AudioToolbox must scan end to end to find packets (no reliable seek table).
    /// These are always copied first; streaming them reads the whole file over the network anyway.
    private static let scanFirstExtensions: Set<String> = ["flac"]

    /// Opens the track for playback, entirely off the main thread. Reading `length` up front
    /// forces any packet-table scan to happen here, not during playback.
    ///
    /// `immediate` is for a track the user just asked to hear: lossy/PCM files on a slow share
    /// then play straight from it (they need ~40 KB/s) instead of waiting for a full copy. Tracks
    /// fetched ahead of time (`immediate == false`) are copied locally for glitch-free gapless playback.
    func openFile(for track: TrackRef, immediate: Bool = false, locate: @escaping @Sendable (TrackRef) -> URL?) async -> AVAudioFile? {
        let url: URL?
        let ext = (track.path as NSString).pathExtension.lowercased()
        if immediate, tasks[track.id] == nil, !Self.scanFirstExtensions.contains(ext) {
            url = await Task.detached(priority: .userInitiated) { locate(track) }.value
        } else {
            url = await localURL(for: track, locate: locate)
        }
        guard let url else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> AVAudioFile? in
            guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
            return file
        }.value
    }

    private func touch(_ id: Int64) {
        recent.removeAll { $0 == id }
        recent.append(id)
    }

    private func evict() {
        while recent.count > capacity {
            let id = recent.removeFirst()
            guard let task = tasks.removeValue(forKey: id) else { continue }
            let directory = directory
            Task.detached(priority: .utility) {
                // Only delete our own copies, never a file played in place from its real location.
                if let url = await task.value, url.deletingLastPathComponent().path == directory.path {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }
}
