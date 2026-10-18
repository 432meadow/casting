import AVFoundation
import ObjCSupport
import Observation

/// Queue-based player on AVAudioEngine.
///
/// - Files are prepared off the main thread by `PlaybackFileCache` (copied locally when they live
///   on a network share), so the UI never waits on disk or network I/O.
/// - Gapless: the next track is prepared early and chained onto the same player node
///   shortly before the current one ends, so the audio runs back-to-back. It's chained late on
///   purpose: once scheduled, a segment can't be withdrawn from the node, so queue edits before
///   that point cost nothing. If the queue changes after chaining, the schedule is rebuilt.
/// - Graph: player node → 10-band EQ → main mixer → output device.
@MainActor
@Observable
final class Player {
    enum RepeatMode: String, CaseIterable, Identifiable {
        case off, all, one
        var id: Self { self }
    }

    struct SavedState: Codable {
        var trackIDs: [Int64]
        var index: Int
        var position: Double
    }

    private(set) var queue: [Track] = []
    private(set) var index: Int?
    private(set) var isPlaying = false
    /// True while the current track's file is being fetched/opened.
    private(set) var isLoading = false
    /// Loading has taken long enough that the network share is probably slow or unreachable.
    private(set) var isWaitingForShare = false
    private(set) var shuffle = false
    /// How many tracks right after the current one were added with Play Next / Add to Queue.
    private(set) var queuedAheadCount = 0
    private(set) var outputDeviceUID: String?
    var repeatMode: RepeatMode = .off {
        didSet {
            UserDefaults.standard.set(repeatMode.rawValue, forKey: Keys.repeatMode)
            queueDidChange()
        }
    }
    var errorMessage: String?
    var volume: Float = 0.8 {
        didSet {
            engine.mainMixerNode.outputVolume = volume
            UserDefaults.standard.set(volume, forKey: Keys.volume)
        }
    }

    let equalizer = Equalizer()
    let outputs = OutputDevices()

    var currentTrack: Track? {
        guard let index, queue.indices.contains(index) else { return nil }
        return queue[index]
    }

    /// The tracks that will play after the current one.
    var upNext: [Track] {
        guard let index, index + 1 < queue.count else { return [] }
        return Array(queue[(index + 1)...])
    }

    var upNextCount: Int {
        guard let index else { return 0 }
        return max(0, queue.count - index - 1)
    }

    /// The first `limit` upcoming tracks, for display. (Playing All Tracks queues ~50k.)
    func upNext(limit: Int) -> ArraySlice<Track> {
        guard let index, index + 1 < queue.count else { return [] }
        return queue[(index + 1)..<min(queue.count, index + 1 + limit)]
    }

    /// Resolves a track to its file (stored path first, then bookmark). Called off the main thread.
    @ObservationIgnored var locate: @Sendable (TrackRef) -> URL? = { URL(fileURLWithPath: $0.path) }
    /// Called when a track's file couldn't be opened (it's skipped).
    @ObservationIgnored var onUnplayable: ((Track) -> Void)?
    /// Called once per listen: after half the track (or 4 minutes), or when a short track ends.
    @ObservationIgnored var onTrackPlayed: ((Track) -> Void)?
    /// Called when playback moves on from a queue entry that played for at least a second, with
    /// how long it actually played and how it ended.
    @ObservationIgnored var onListenEnded: ((Track, ListenRecord) -> Void)?

    private enum Keys {
        static let volume = "player.volume"
        static let repeatMode = "player.repeat"
        static let shuffle = "player.shuffle"
        static let outputDevice = "player.outputDeviceUID"
    }

    private struct Prepared {
        let index: Int
        let trackID: Int64
        let file: AVAudioFile
    }

    @ObservationIgnored private let files = PlaybackFileCache()
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let node = AVAudioPlayerNode()
    @ObservationIgnored private var connectedFormat: AVAudioFormat?
    /// Bumped whenever the node's schedule is torn down, so stale callbacks and loads are ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var scheduleCounter = 0
    @ObservationIgnored private var currentScheduleID: Int?
    @ObservationIgnored private var currentFile: AVAudioFile?
    /// The current file is being read straight from a network volume (not a local copy).
    @ObservationIgnored private var currentIsStreaming = false
    /// The following track, opened and ready (not necessarily scheduled yet).
    @ObservationIgnored private var nextFile: Prepared?
    /// Set once `nextFile` has been scheduled on the node behind the current track.
    @ObservationIgnored private var chainedScheduleID: Int?
    @ObservationIgnored private var prefetchingTrackID: Int64?
    @ObservationIgnored private var failedPrefetchTrackID: Int64?
    /// Node sample time at which the current track's audio begins (node time keeps counting across gapless chains).
    @ObservationIgnored private var currentStartSampleTime: AVAudioFramePosition = 0
    /// Frame within the current file where playback was (re)started, after a seek.
    @ObservationIgnored private var currentStartFrame: AVAudioFramePosition = 0
    @ObservationIgnored private var pausedTime: TimeInterval?
    /// Holds the playhead at a seek target until audio from there actually plays. The node's
    /// clock runs on while it waits for network data, so the slider would creep ahead otherwise.
    @ObservationIgnored private var bufferingTime: TimeInterval?
    /// Stops the queue from racing through every track when the music share is unmounted.
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var countedCurrentPlay = false
    /// The current queue entry's listen, accumulating playing time.
    @ObservationIgnored private var listen: (track: Track, record: ListenRecord)?
    @ObservationIgnored private var listenAccumulatedAt = Date()
    /// The unshuffled order, so turning shuffle off restores it.
    @ObservationIgnored private var originalQueue: [Track]?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var nowPlaying: NowPlayingCenter?

    /// Seconds before the end of a track at which the next one is chained onto the node.
    private static let chainLeadTime: TimeInterval = 12

    init() {
        let defaults = UserDefaults.standard
        volume = defaults.object(forKey: Keys.volume) as? Float ?? 0.8
        repeatMode = RepeatMode(rawValue: defaults.string(forKey: Keys.repeatMode) ?? "") ?? .off
        shuffle = defaults.bool(forKey: Keys.shuffle)
        outputDeviceUID = defaults.string(forKey: Keys.outputDevice)

        engine.attach(node)
        engine.attach(equalizer.unit)
        engine.mainMixerNode.outputVolume = volume
        if let uid = outputDeviceUID, let device = OutputDevices.deviceID(forUID: uid) {
            setEngineOutput(device)
        }

        // The engine stops itself when the output device or its format changes (headphones
        // unplugged, AirPlay switch). Rebuild the schedule at the same position on the new device.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.outputConfigurationChanged() }
        }

        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.tick()
            }
        }
        nowPlaying = NowPlayingCenter(player: self)
    }

    // MARK: Transport

    func play(_ tracks: [Track], startingAt start: Int) {
        guard tracks.indices.contains(start) else { return }
        consecutiveFailures = 0
        queuedAheadCount = 0
        if shuffle {
            originalQueue = tracks
            var rest = tracks
            let first = rest.remove(at: start)
            rest.shuffle()
            queue = [first] + rest
            startTrack(at: 0, newQueue: true)
        } else {
            originalQueue = nil
            queue = tracks
            startTrack(at: start, newQueue: true)
        }
    }

    func togglePlayPause() {
        guard index != nil, currentFile != nil else { return }
        accumulateListen()
        if isPlaying {
            pausedTime = currentTime
            node.pause()
            isPlaying = false
            // A pending after-seek probe can't finish while paused; don't spin forever.
            isLoading = false
            isWaitingForShare = false
        } else {
            do {
                if !engine.isRunning { try engine.start() }
                pausedTime = nil
                node.play()
                isPlaying = true
            } catch {
                errorMessage = "Audio output failed: \(error.localizedDescription)"
            }
        }
        nowPlaying?.update()
    }

    func next() {
        guard let index else { return }
        if let target = followingIndex(after: index, automatic: false) {
            startTrack(at: target, reuse: preparedFile(for: target))
        } else {
            stop()
        }
    }

    /// Restarts the current track if more than 3 s in, like most players.
    func previous() {
        guard let index else { return }
        if currentTime > 3 {
            seek(to: 0)
        } else if index > 0 {
            startTrack(at: index - 1)
        } else if repeatMode != .off, queue.count > 1 {
            startTrack(at: queue.count - 1)
        } else {
            seek(to: 0)
        }
    }

    func stop() {
        endListen(.stopped)
        generation += 1
        node.stop()
        engine.stop()
        isPlaying = false
        isLoading = false
        isWaitingForShare = false
        index = nil
        currentFile = nil
        nextFile = nil
        chainedScheduleID = nil
        currentScheduleID = nil
        pausedTime = nil
        bufferingTime = nil
        queuedAheadCount = 0
        nowPlaying?.update()
    }

    func seek(to seconds: TimeInterval) {
        guard let index, let file = currentFile else { return }
        let target = max(0, min(seconds, Double(file.length) / file.processingFormat.sampleRate - 0.05))
        startTrack(at: index, fromSeconds: target, reuse: file, startPaused: !isPlaying)
    }

    // MARK: Modes

    func setShuffle(_ on: Bool) {
        guard on != shuffle else { return }
        shuffle = on
        UserDefaults.standard.set(on, forKey: Keys.shuffle)
        guard !queue.isEmpty else { return }

        let current = currentTrack
        if on {
            originalQueue = queue
            var rest = queue
            if let index { rest.remove(at: index) }
            rest.shuffle()
            queue = (current.map { [$0] } ?? []) + rest
            index = current == nil ? nil : 0
        } else if let original = originalQueue {
            if let current {
                if let position = original.firstIndex(where: { $0.id == current.id }) {
                    queue = original
                    index = position
                } else {
                    queue = [current] + original
                    index = 0
                }
            } else {
                queue = original
            }
            originalQueue = nil
        }
        queuedAheadCount = 0
        queueDidChange()
    }

    func cycleRepeatMode() {
        repeatMode = switch repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    // MARK: Up Next

    /// Plays `tracks` right after the current track.
    func playNext(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        guard let index else {
            play(tracks, startingAt: 0)
            return
        }
        queue.insert(contentsOf: tracks, at: index + 1)
        insertIntoOriginal(tracks, afterQueued: false)
        queuedAheadCount += tracks.count
        queueDidChange()
    }

    /// Adds `tracks` after anything already queued with Play Next / Add to Queue.
    func addToQueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        guard let index else {
            play(tracks, startingAt: 0)
            return
        }
        queue.insert(contentsOf: tracks, at: min(index + 1 + queuedAheadCount, queue.count))
        insertIntoOriginal(tracks, afterQueued: true)
        queuedAheadCount += tracks.count
        queueDidChange()
    }

    /// Offsets are positions in `upNext`.
    func removeFromUpNext(at offsets: IndexSet) {
        guard let index else { return }
        let removedQueued = offsets.filter { $0 < queuedAheadCount }.count
        queue.remove(atOffsets: IndexSet(offsets.map { $0 + index + 1 }))
        queuedAheadCount -= removedQueued
        queueDidChange()
    }

    func moveInUpNext(from offsets: IndexSet, to destination: Int) {
        guard let index else { return }
        var upcoming = upNext
        upcoming.move(fromOffsets: offsets, toOffset: destination)
        queue.replaceSubrange((index + 1)..., with: upcoming)
        queueDidChange()
    }

    func clearUpNext() {
        guard let index, index + 1 < queue.count else { return }
        queue.removeSubrange((index + 1)...)
        queuedAheadCount = 0
        queueDidChange()
    }

    /// Starts the track at `offset` in `upNext`, dropping everything before it.
    func jump(toUpNext offset: Int) {
        guard let index, queue.indices.contains(index + 1 + offset) else { return }
        queuedAheadCount = max(0, queuedAheadCount - offset - 1)
        let target = index + 1 + offset
        startTrack(at: target, reuse: preparedFile(for: target))
    }

    private func insertIntoOriginal(_ tracks: [Track], afterQueued: Bool) {
        guard var original = originalQueue else { return }
        let anchor = currentTrack.flatMap { current in original.firstIndex { $0.id == current.id } }
        original.insert(contentsOf: tracks, at: anchor.map { $0 + 1 } ?? original.count)
        originalQueue = original
    }

    // MARK: Saved state

    var savedState: SavedState? {
        guard let index else { return nil }
        return SavedState(trackIDs: queue.map(\.id), index: index, position: currentTime)
    }

    /// Restores a queue paused at `position`, as it was when the app quit.
    func restore(_ tracks: [Track], index: Int, position: Double) {
        guard tracks.indices.contains(index) else { return }
        queue = tracks
        originalQueue = nil
        startTrack(at: index, fromSeconds: position, startPaused: true, newQueue: true)
    }

    // MARK: Output device

    /// nil follows the system default output.
    func setOutputDevice(_ uid: String?) {
        outputDeviceUID = uid
        UserDefaults.standard.set(uid, forKey: Keys.outputDevice)
        let device = uid.flatMap(OutputDevices.deviceID(forUID:)) ?? OutputDevices.defaultOutputDeviceID()
        guard let device else { return }
        let position = currentTime
        let wasPlaying = isPlaying
        engine.stop()
        setEngineOutput(device)
        connectedFormat = nil
        if let index, let file = currentFile {
            startTrack(at: index, fromSeconds: position, reuse: file, startPaused: !wasPlaying)
        }
    }

    private func setEngineOutput(_ device: AudioDeviceID) {
        guard let unit = engine.outputNode.audioUnit else { return }
        var device = device
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                             &device, UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    private func outputConfigurationChanged() {
        connectedFormat = nil  // force a reconnect to the new output
        resync()
    }

    // MARK: Time

    var duration: TimeInterval {
        guard let file = currentFile else { return currentTrack?.length ?? 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    var currentTime: TimeInterval {
        if let pausedTime { return pausedTime }
        if let bufferingTime { return bufferingTime }
        guard let file = currentFile,
              let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else { return 0 }
        let frames = currentStartFrame + playerTime.sampleTime - currentStartSampleTime
        return max(0, min(Double(frames) / file.processingFormat.sampleRate, duration))
    }

    // MARK: Scheduling

    /// What plays after `index`. `automatic` is a track ending on its own (repeat-one replays it);
    /// otherwise the user pressed Next.
    private func followingIndex(after index: Int, automatic: Bool) -> Int? {
        if automatic, repeatMode == .one { return index }
        if index + 1 < queue.count { return index + 1 }
        if repeatMode != .off, !queue.isEmpty { return 0 }
        return nil
    }

    private func preparedFile(for target: Int) -> AVAudioFile? {
        guard let prepared = nextFile, prepared.index == target,
              queue.indices.contains(target), queue[target].id == prepared.trackID else { return nil }
        return prepared.file
    }

    private func prepareFile(for track: Track, immediate: Bool = false) async -> AVAudioFile? {
        await files.openFile(for: TrackRef(id: track.id, path: track.path), immediate: immediate, locate: locate)
    }

    private func startTrack(at newIndex: Int, fromSeconds: TimeInterval = 0, reuse: AVAudioFile? = nil,
                            startPaused: Bool = false, newQueue: Bool = false) {
        accumulateListen()
        // Read before the node stops: where the outgoing track got to.
        let endedAt = currentTime
        let endedDuration = duration
        generation += 1
        let startGeneration = generation
        node.stop()
        chainedScheduleID = nil
        currentScheduleID = nil
        if let reuse, nextFile?.file === reuse { nextFile = nil }
        if newQueue { nextFile = nil }
        pausedTime = nil
        bufferingTime = nil

        let previousIndex = index
        index = newIndex
        if !newQueue, let previousIndex, newIndex == previousIndex + 1, queuedAheadCount > 0 {
            queuedAheadCount -= 1
        }
        if newIndex != previousIndex || newQueue {
            countedCurrentPlay = false
            let finished = endedDuration - endedAt <= min(Player.finishedWithin, endedDuration * 0.1)
            endListen(finished ? .finished : .skipped, at: endedAt)
        }
        if listen == nil { beginListen(queue[newIndex]) }

        if let reuse {
            begin(reuse, at: newIndex, fromSeconds: fromSeconds, startPaused: startPaused)
            return
        }

        currentFile = nil
        bufferingTime = fromSeconds
        isPlaying = false
        isLoading = true
        isWaitingForShare = false
        nowPlaying?.update()
        let track = queue[newIndex]
        Task {
            try? await Task.sleep(for: .seconds(8))
            if startGeneration == generation, isLoading { isWaitingForShare = true }
        }
        Task {
            let file = await prepareFile(for: track, immediate: true)
            // The user may have skipped or stopped while this loaded.
            guard startGeneration == generation else { return }
            isLoading = false
            isWaitingForShare = false
            guard let file else {
                errorMessage = "Can't open “\(track.title)” — \(track.path)"
                onUnplayable?(track)
                skipUnplayable(at: newIndex)
                return
            }
            begin(file, at: newIndex, fromSeconds: fromSeconds, startPaused: startPaused)
        }
    }

    private func skipUnplayable(at failedIndex: Int) {
        consecutiveFailures += 1
        // Skip unplayable files, but give up if the whole share seems to be gone.
        if consecutiveFailures < 3, let target = followingIndex(after: failedIndex, automatic: false), target != failedIndex {
            startTrack(at: target)
        } else {
            stop()
        }
    }

    private func begin(_ file: AVAudioFile, at newIndex: Int, fromSeconds: TimeInterval, startPaused: Bool) {
        guard connect(for: file.processingFormat) else {
            errorMessage = "Unsupported audio format: \(file.processingFormat)"
            skipUnplayable(at: newIndex)
            return
        }
        consecutiveFailures = 0
        errorMessage = nil
        currentFile = file
        currentIsStreaming = !((try? file.url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) ?? true)

        let rate = file.processingFormat.sampleRate
        let startFrame = max(0, min(AVAudioFramePosition(fromSeconds * rate), file.length - 1))
        currentStartFrame = startFrame
        currentStartSampleTime = 0
        bufferingTime = nil

        // Over the network share the node can sit silent for a while after a seek, waiting for
        // data at the new offset. Schedule a short probe segment first: the moment its audio has
        // actually played, the spinner stops. Local files skip this (data is instant).
        let probeFrames = AVAudioFramePosition(rate / 4)
        if currentIsStreaming, !startPaused, file.length - startFrame > probeFrames * 2 {
            isLoading = true
            isWaitingForShare = false
            bufferingTime = Double(startFrame) / rate
            let probeGeneration = generation
            Task {
                try? await Task.sleep(for: .seconds(8))
                if probeGeneration == generation, isLoading { isWaitingForShare = true }
            }
            node.scheduleSegment(file, startingFrame: startFrame, frameCount: AVAudioFrameCount(probeFrames),
                                 at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.generation == probeGeneration else { return }
                    self.isLoading = false
                    self.isWaitingForShare = false
                    // Re-anchor the clock: the probe has just finished, so the node is now at
                    // the frame right after it, however long it sat waiting for data.
                    if let nodeTime = self.node.lastRenderTime,
                       let playerTime = self.node.playerTime(forNodeTime: nodeTime) {
                        self.currentStartFrame = startFrame + probeFrames
                        self.currentStartSampleTime = playerTime.sampleTime
                    }
                    self.bufferingTime = nil
                }
            }
            currentScheduleID = schedule(file, from: startFrame + probeFrames,
                                         frames: AVAudioFrameCount(file.length - startFrame - probeFrames))
        } else {
            currentScheduleID = schedule(file, from: startFrame, frames: AVAudioFrameCount(file.length - startFrame))
        }

        do {
            if !engine.isRunning { try engine.start() }
            if startPaused {
                pausedTime = Double(startFrame) / rate
                isPlaying = false
            } else {
                node.play()
                isPlaying = true
            }
        } catch {
            errorMessage = "Audio output failed: \(error.localizedDescription)"
            isPlaying = false
        }
        nowPlaying?.update()
        tick()
    }

    /// Returns false if the engine can't play this format (it raises an NSException, caught in ObjC).
    private func connect(for format: AVAudioFormat) -> Bool {
        guard !Player.sameLayout(connectedFormat, format) else { return true }
        engine.disconnectNodeOutput(node)
        engine.disconnectNodeOutput(equalizer.unit)
        // The mixer converts to the output device's rate.
        var error: NSError?
        guard MMConnectNodes(engine, node, equalizer.unit, format, &error),
              MMConnectNodes(engine, equalizer.unit, engine.mainMixerNode, format, &error) else {
            connectedFormat = nil
            return false
        }
        connectedFormat = format
        return true
    }

    private static func sameLayout(_ a: AVAudioFormat?, _ b: AVAudioFormat) -> Bool {
        guard let a else { return false }
        return a.sampleRate == b.sampleRate && a.channelCount == b.channelCount
    }

    private func schedule(_ file: AVAudioFile, from frame: AVAudioFramePosition, frames: AVAudioFrameCount) -> Int {
        scheduleCounter += 1
        let scheduleID = scheduleCounter
        let scheduledGeneration = generation
        node.scheduleSegment(file, startingFrame: frame, frameCount: frames, at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.didFinish(scheduleID: scheduleID, generation: scheduledGeneration) }
        }
        return scheduleID
    }

    /// Runs twice a second: counts plays, prefetches the next track, and chains it near the end.
    private func tick() {
        accumulateListen()
        guard let index, currentFile != nil else { return }

        if isPlaying, !countedCurrentPlay, duration > 0, currentTime >= min(duration * 0.5, 240) {
            countedCurrentPlay = true
            onTrackPlayed?(queue[index])
        }

        guard let upcoming = followingIndex(after: index, automatic: true) else {
            nextFile = nil
            return
        }
        let upcomingTrack = queue[upcoming]
        if let prepared = nextFile, prepared.index != upcoming || prepared.trackID != upcomingTrack.id {
            // Keep the file if the same track just moved position; otherwise it's stale.
            nextFile = prepared.trackID == upcomingTrack.id
                ? Prepared(index: upcoming, trackID: prepared.trackID, file: prepared.file)
                : nil
        }
        // While the current track streams from the network share, don't compete with it for
        // bandwidth right away: fetch the next one once it's 20 s in or in its last minute.
        let streamIsSettled = !currentIsStreaming || currentTime > 20 || duration - currentTime < 60
        if nextFile == nil, streamIsSettled, prefetchingTrackID != upcomingTrack.id, failedPrefetchTrackID != upcomingTrack.id {
            prefetch(upcomingTrack)
        }

        if isPlaying, chainedScheduleID == nil, let prepared = nextFile,
           Player.sameLayout(connectedFormat, prepared.file.processingFormat),
           duration - currentTime < Player.chainLeadTime {
            chainedScheduleID = schedule(prepared.file, from: 0, frames: AVAudioFrameCount(prepared.file.length))
        }
    }

    private func prefetch(_ track: Track) {
        prefetchingTrackID = track.id
        Task {
            let file = await prepareFile(for: track)
            if prefetchingTrackID == track.id { prefetchingTrackID = nil }
            guard let file else {
                failedPrefetchTrackID = track.id
                return
            }
            guard let index, let upcoming = followingIndex(after: index, automatic: true),
                  queue[upcoming].id == track.id else { return }
            nextFile = Prepared(index: upcoming, trackID: track.id, file: file)
            tick()
        }
    }

    private func didFinish(scheduleID: Int, generation finishedGeneration: Int) {
        guard finishedGeneration == generation, scheduleID == currentScheduleID,
              let index, let file = currentFile else { return }
        if !countedCurrentPlay {
            countedCurrentPlay = true
            onTrackPlayed?(queue[index])
        }
        endListen(.finished, at: duration)
        // Repeat One starts the same entry again: that's a new play and a new listen.
        countedCurrentPlay = false

        if let chained = chainedScheduleID, let prepared = nextFile {
            // Already playing gaplessly; just advance our bookkeeping.
            currentStartSampleTime += file.length - currentStartFrame
            currentStartFrame = 0
            currentFile = prepared.file
            currentIsStreaming = false  // prefetched files are local copies
            currentScheduleID = chained
            chainedScheduleID = nil
            nextFile = nil
            if prepared.index == index + 1, queuedAheadCount > 0 { queuedAheadCount -= 1 }
            self.index = prepared.index
            beginListen(queue[prepared.index])
            nowPlaying?.update()
            tick()
            return
        }

        guard let target = followingIndex(after: index, automatic: true) else {
            stop()
            return
        }
        startTrack(at: target, reuse: preparedFile(for: target))
    }

    // MARK: Listens

    /// A track left this close to its end (or within its last 10%, if shorter) counts as
    /// finished, not skipped.
    private static let finishedWithin: TimeInterval = 10

    private func beginListen(_ track: Track) {
        accumulateListen()
        listen = (track, ListenRecord(trackID: track.id, startedAt: Date(), seconds: 0, position: 0, outcome: .finished))
    }

    /// Adds the time since the last call, if audio was playing (not paused or waiting for data).
    /// Called before every state change, so the state now is the state since the last call.
    private func accumulateListen() {
        let now = Date()
        if listen != nil, isPlaying, !isLoading {
            listen?.record.seconds += now.timeIntervalSince(listenAccumulatedAt)
        }
        listenAccumulatedAt = now
    }

    private func endListen(_ outcome: ListenOutcome, at position: TimeInterval? = nil) {
        accumulateListen()
        guard var ended = listen else { return }
        listen = nil
        ended.record.outcome = outcome
        ended.record.position = position ?? currentTime
        guard ended.record.seconds >= 1 else { return }
        onListenEnded?(ended.track, ended.record)
    }

    /// Ends the current listen as stopped, for when casting quits.
    func endCurrentListen() {
        endListen(.stopped)
    }

    /// Call after any change to the queue, shuffle or repeat.
    private func queueDidChange() {
        // A segment already chained onto the node can't be withdrawn. If it's no longer what should
        // play next, rebuild the schedule from the current position.
        if chainedScheduleID != nil, let index {
            let expected = followingIndex(after: index, automatic: true)
            if expected == nil || nextFile?.index != expected || nextFile?.trackID != expected.map({ queue[$0].id }) {
                resync()
            }
        }
        tick()
    }

    /// Restarts the current file at the current position with a fresh schedule.
    private func resync() {
        guard let index, let file = currentFile else { return }
        startTrack(at: index, fromSeconds: currentTime, reuse: file, startPaused: !isPlaying)
    }
}
