import Foundation
import Observation

/// Background queue of tag writes, one file at a time (the files sit on a slow network share).
/// Edits queued for a file that hasn't been written yet are merged into one write.
@MainActor
@Observable
final class TagWriteQueue {
    struct Failure: Identifiable {
        let id = UUID()
        let path: String
        let message: String
    }

    typealias Writer = @Sendable (TagValues, URL) async throws -> TagFileWriter.Outcome

    /// Progress through the current batch (reset when a new batch starts after the queue went idle).
    private(set) var done = 0
    private(set) var total = 0
    private(set) var written = 0
    private(set) var currentPath: String?
    /// The next file is in use (playing) and waits until it isn't.
    private(set) var waitingForPath: String?
    private(set) var failures: [Failure] = []

    var isRunning: Bool { worker != nil }

    /// Files that shouldn't be replaced right now (the track that's playing).
    @ObservationIgnored var isInUse: (String) -> Bool = { _ in false }
    /// Called after a file was rewritten, with its new size.
    @ObservationIgnored var didWrite: (String, Int64) -> Void = { _, _ in }
    /// Called with the values still waiting for a path whenever they change (nil once written or
    /// given up on), so the queue can be saved and picked up again after a quit.
    @ObservationIgnored var persist: (String, TagValues?) -> Void = { _, _ in }

    @ObservationIgnored private var pending: [String: TagValues] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private let write: Writer
    @ObservationIgnored private let retryDelay: Duration

    init(retryDelay: Duration = .seconds(3), write: @escaping Writer = { try await TagFileWriter.write($0, to: $1) }) {
        self.write = write
        self.retryDelay = retryDelay
    }

    func enqueue(_ values: TagValues, path: String) {
        guard !values.isEmpty else { return }
        if worker == nil {
            done = 0
            total = 0
            written = 0
        }
        if let existing = pending[path] {
            pending[path] = existing.merged(with: values)
        } else {
            pending[path] = values
            order.append(path)
            total += 1
        }
        persist(path, pending[path])
        if worker == nil {
            worker = Task { [weak self] in await self?.run() }
        }
    }

    func clearFailures() {
        failures.removeAll()
    }

    /// Waits until everything queued so far has been written (for tests).
    func waitUntilIdle() async {
        while let worker { await worker.value }
    }

    private func run() async {
        while !order.isEmpty {
            guard let path = order.first(where: { !isInUse($0) }) else {
                waitingForPath = order.first
                try? await Task.sleep(for: retryDelay)
                continue
            }
            waitingForPath = nil
            order.removeAll { $0 == path }
            guard let values = pending.removeValue(forKey: path) else { continue }
            currentPath = path

            let write = write
            let result: Result<TagFileWriter.Outcome, Error> = await Task.detached(priority: .utility) {
                do { return .success(try await write(values, URL(fileURLWithPath: path))) } catch { return .failure(error) }
            }.value
            switch result {
            case .success(.written(let size)):
                written += 1
                didWrite(path, size)
            case .success(.unchanged):
                break
            case .failure(let error):
                failures.append(Failure(path: path, message: error.localizedDescription))
                if failures.count > 200 { failures.removeFirst(failures.count - 200) }
            }
            // Edits that arrived while this write ran are still pending; keep those saved.
            persist(path, pending[path])
            done += 1
        }
        currentPath = nil
        waitingForPath = nil
        worker = nil
    }
}
