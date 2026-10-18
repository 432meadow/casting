import Foundation
import Observation

/// Background BPM detection, a few files at a time (each read is a short excerpt, but the files
/// sit on a slow network share). Results are handed back in small batches so the library and
/// table update as it goes without re-sorting 50k rows per track.
@MainActor
@Observable
final class BPMAnalysisQueue {
    typealias Detector = @Sendable (URL) throws -> Double?

    /// Progress through the current batch (reset when a new batch starts after the queue went idle).
    private(set) var done = 0
    private(set) var total = 0
    /// How many files gave a tempo (the rest were missing, undecodable, or had no clear beat).
    private(set) var detected = 0

    var isRunning: Bool { worker != nil }

    /// Called with (track ID, rounded BPM) pairs as they're found.
    @ObservationIgnored var didDetect: ([(Int64, Int)]) -> Void = { _ in }

    @ObservationIgnored private var pending: [(id: Int64, path: String)] = []
    @ObservationIgnored private var queued = Set<Int64>()
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private let detect: Detector
    @ObservationIgnored private let width: Int

    init(width: Int = 3, detect: @escaping Detector = { try BPMDetector.detect(fileAt: $0) }) {
        self.width = width
        self.detect = detect
    }

    func enqueue(_ tracks: [(id: Int64, path: String)]) {
        if worker == nil {
            done = 0
            total = 0
            detected = 0
        }
        for track in tracks where queued.insert(track.id).inserted {
            pending.append(track)
            total += 1
        }
        if worker == nil, !pending.isEmpty {
            worker = Task { [weak self] in await self?.run() }
        }
    }

    /// Drops everything not yet started; files already being read finish and are saved.
    func cancel() {
        total -= pending.count
        queued.subtract(pending.map(\.id))
        pending.removeAll()
    }

    /// Waits until everything queued so far has been analyzed (for tests).
    func waitUntilIdle() async {
        while let worker { await worker.value }
    }

    private func run() async {
        var results: [(Int64, Int)] = []
        var lastFlush = ContinuousClock.now
        func flush() {
            guard !results.isEmpty else { return }
            didDetect(results)
            results.removeAll()
            lastFlush = .now
        }

        await withTaskGroup(of: (Int64, Double?).self) { group in
            for _ in 0..<width where !startNext(in: &group) { break }
            for await (id, bpm) in group {
                done += 1
                queued.remove(id)
                if let bpm, bpm.isFinite, bpm > 0 {
                    detected += 1
                    results.append((id, Int(bpm.rounded())))
                }
                if results.count >= 50 || ContinuousClock.now - lastFlush > .seconds(1) { flush() }
                _ = startNext(in: &group)
            }
        }
        flush()
        worker = nil
    }

    private func startNext(in group: inout TaskGroup<(Int64, Double?)>) -> Bool {
        guard !pending.isEmpty else { return false }
        let track = pending.removeFirst()
        let detect = detect
        group.addTask(priority: .utility) {
            (track.id, try? detect(URL(fileURLWithPath: track.path)))
        }
        return true
    }
}
