import AVFoundation
import ObjCSupport
import Observation

/// A two-deck mixer for blending tracks by hand, on its own AVAudioEngine so the queue player's
/// gapless schedule is left alone. Only one of the two plays at a time: starting a deck pauses
/// the queue player and vice versa (wired up in `AppModel`).
///
/// Graph per deck: player node → input mixer → varispeed (tempo) → 3-band EQ → channel mixer →
/// main mixer → output. The input mixer converts every file to one fixed deck format, so loading a
/// track only rewires the player node into it. The engine allows that while the other deck keeps
/// playing, because the change is upstream of a mixer. The channel mixer's volume is the channel
/// fader times the crossfader curve.
@MainActor
@Observable
final class Mixer {
    enum Side: String, CaseIterable, Identifiable {
        case a, b
        var id: Self { self }
        var name: String { rawValue.uppercased() }
        var other: Side { self == .a ? .b : .a }
    }

    let a = Deck(side: .a)
    let b = Deck(side: .b)
    var decks: [Deck] { [a, b] }

    func deck(_ side: Side) -> Deck { side == .a ? a : b }

    /// 0 is all deck A, 1 is all deck B.
    private(set) var crossfader: Double = 0.5
    private(set) var isAutoFading = false
    var errorMessage: String?
    var masterVolume: Float = 0.8 {
        didSet {
            engine.mainMixerNode.outputVolume = masterVolume
            UserDefaults.standard.set(masterVolume, forKey: Keys.masterVolume)
        }
    }
    /// How long Auto Crossfade takes to glide from one side to the other.
    var autoFadeSeconds: Double = 8 {
        didSet { UserDefaults.standard.set(autoFadeSeconds, forKey: Keys.autoFadeSeconds) }
    }
    static let autoFadeChoices: [Double] = [4, 8, 16, 32]

    /// Resolves a track to its file. Called off the main thread.
    @ObservationIgnored var locate: @Sendable (TrackRef) -> URL? = { URL(fileURLWithPath: $0.path) }
    /// Called once per deck load, after half the track (or 4 minutes) has played.
    @ObservationIgnored var onTrackPlayed: ((Track) -> Void)?
    @ObservationIgnored var onUnplayable: ((Track) -> Void)?
    /// Called whenever a deck starts playing, so the queue player can pause.
    @ObservationIgnored var onStartedPlaying: (() -> Void)?

    private enum Keys {
        static let masterVolume = "mixer.masterVolume"
        static let autoFadeSeconds = "mixer.autoFadeSeconds"
    }

    @ObservationIgnored private let engine = AVAudioEngine()
    /// Its own folder: a cache clears its directory when created, so it can't share the player's.
    @ObservationIgnored private let files = PlaybackFileCache(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("casting/Mixer"),
        capacity: 6)
    @ObservationIgnored private var isSetUp = false
    @ObservationIgnored private var outputDeviceUID: String?
    @ObservationIgnored private var fade: Task<Void, Never>?
    @ObservationIgnored private var monitor: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        masterVolume = defaults.object(forKey: Keys.masterVolume) as? Float ?? 0.8
        autoFadeSeconds = defaults.object(forKey: Keys.autoFadeSeconds) as? Double ?? 8
        for deck in decks {
            deck.startEngine = { [weak self] in self?.startEngine() ?? false }
            deck.didStop = { [weak self] in self?.deckStopped() }
            deck.levelChanged = { [weak self] in self?.applyGains() }
        }
    }

    // MARK: Loading

    /// Opens `track` on a deck, cued at `seconds`. `whenReady` runs once it can play.
    func load(_ track: Track, on side: Side, at seconds: TimeInterval = 0, whenReady: ((Deck) -> Void)? = nil) {
        setUpIfNeeded()
        let deck = deck(side)
        let token = deck.beginLoading(track)
        let ref = TrackRef(id: track.id, path: track.path)
        Task {
            // Copied locally first when it's on the share: decks seek a lot, and the waveform reads it all.
            let file = await files.openFile(for: ref, locate: locate)
            guard deck.loadToken == token else { return }
            guard let file else {
                deck.failLoading("Can't open “\(track.title.isEmpty ? track.fileName : track.title)”")
                onUnplayable?(track)
                return
            }
            guard connect(deck, for: file.processingFormat) else {
                deck.failLoading("Unsupported audio format")
                return
            }
            deck.finishLoading(file, at: seconds)
            whenReady?(deck)
            let url = file.url
            let peaks = await Task.detached(priority: .utility) { Waveform.levels(of: url) }.value
            if deck.loadToken == token { deck.waveform = peaks }
        }
    }

    func pauseAll() {
        for deck in decks { deck.pause() }
    }

    // MARK: Crossfader

    /// Equal-power curve: the blend keeps the same loudness all the way across.
    nonisolated static func crossfadeGains(_ position: Double) -> (a: Float, b: Float) {
        let angle = min(max(position, 0), 1) * .pi / 2
        return (Float(cos(angle)), Float(sin(angle)))
    }

    /// Moves the crossfader by hand, which stops any auto crossfade.
    func moveCrossfader(to position: Double) {
        cancelAutoFade()
        setCrossfader(position)
    }

    /// Glides the crossfader to the far side over `autoFadeSeconds`, starting the incoming deck if
    /// it's loaded and paused.
    func autoFade() {
        cancelAutoFade()
        let from = crossfader
        let to: Double = crossfader < 0.5 ? 1 : 0
        let incoming = deck(to == 1 ? .b : .a)
        if incoming.isReady, !incoming.isPlaying { incoming.play() }
        let seconds = autoFadeSeconds
        isAutoFading = true
        fade = Task { [weak self] in
            let start = Date()
            while !Task.isCancelled {
                let t = min(1, Date().timeIntervalSince(start) / seconds)
                // Eased at both ends, like a hand on the fader.
                self?.setCrossfader(from + (to - from) * (1 - cos(t * .pi)) / 2)
                if t >= 1 { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            if !Task.isCancelled { self?.isAutoFading = false }
        }
    }

    func cancelAutoFade() {
        fade?.cancel()
        fade = nil
        isAutoFading = false
    }

    private func setCrossfader(_ position: Double) {
        crossfader = min(max(position, 0), 1)
        applyGains()
    }

    private func applyGains() {
        let (gainA, gainB) = Mixer.crossfadeGains(crossfader)
        // Squared so the channel fader feels even across its travel, like an audio-taper fader.
        a.channel.outputVolume = a.level * a.level * gainA
        b.channel.outputVolume = b.level * b.level * gainB
    }

    // MARK: Output device

    /// nil follows the system default output. Follows the queue player's choice.
    func setOutputDevice(_ uid: String?) {
        outputDeviceUID = uid
        guard isSetUp else { return }
        let device = uid.flatMap(OutputDevices.deviceID(forUID:)) ?? OutputDevices.defaultOutputDeviceID()
        guard let device else { return }
        let playing = decks.filter(\.isPlaying)
        for deck in playing { deck.pause(notify: false) }
        engine.stop()
        setEngineOutput(device)
        for deck in playing { deck.play() }
    }

    private func setEngineOutput(_ device: AudioDeviceID) {
        guard let unit = engine.outputNode.audioUnit else { return }
        var device = device
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                             &device, UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    // MARK: Engine

    /// Builds the graph the first time a deck is loaded, so an unused mixer costs nothing.
    private func setUpIfNeeded() {
        guard !isSetUp else { return }
        isSetUp = true
        if let uid = outputDeviceUID, let device = OutputDevices.deviceID(forUID: uid) {
            setEngineOutput(device)
        }
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let format = AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 44_100, channels: 2)!
        for deck in decks {
            for node in [deck.node, deck.input, deck.varispeed, deck.eq, deck.channel] as [AVAudioNode] {
                engine.attach(node)
            }
            engine.connect(deck.input, to: deck.varispeed, format: format)
            engine.connect(deck.varispeed, to: deck.eq, format: format)
            engine.connect(deck.eq, to: deck.channel, format: format)
            engine.connect(deck.channel, to: engine.mainMixerNode, format: format)
        }
        engine.mainMixerNode.outputVolume = masterVolume
        applyGains()

        // The engine stops itself when the output device or its format changes; pick up where we were.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for deck in self.decks where deck.isPlaying { deck.restart() }
            }
        }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.tick()
            }
        }
    }

    /// Returns false if the engine can't take this format (it raises an NSException, caught in ObjC).
    private func connect(_ deck: Deck, for format: AVAudioFormat) -> Bool {
        if let connected = deck.connectedFormat,
           connected.sampleRate == format.sampleRate, connected.channelCount == format.channelCount {
            return true
        }
        engine.disconnectNodeOutput(deck.node)
        var error: NSError?
        guard MMConnectNodes(engine, deck.node, deck.input, format, &error) else {
            deck.connectedFormat = nil
            return false
        }
        deck.connectedFormat = format
        return true
    }

    private func startEngine() -> Bool {
        do {
            if !engine.isRunning { try engine.start() }
            errorMessage = nil
            onStartedPlaying?()
            return true
        } catch {
            errorMessage = "Audio output failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Lets the audio hardware go when neither deck is playing.
    private func deckStopped() {
        if !a.isPlaying, !b.isPlaying, engine.isRunning { engine.stop() }
    }

    private func tick() {
        for deck in decks {
            if let track = deck.takeDuePlayCount() { onTrackPlayed?(track) }
        }
    }
}

// MARK: - Deck

@MainActor
@Observable
final class Deck {
    let side: Mixer.Side

    private(set) var track: Track?
    private(set) var isLoading = false
    private(set) var isPlaying = false
    private(set) var errorMessage: String?
    /// Loudness overview of the whole track, 0…1 per bin; empty until it's been read.
    fileprivate(set) var waveform: [Float] = []
    /// Where Cue jumps back to.
    private(set) var cuePoint: TimeInterval = 0
    /// Speed change as a fraction (0.02 is +2%). Pitch follows, like a turntable.
    var tempo: Double = 0 { didSet { applyRate() } }
    /// Temporary speed change while a nudge button is held, for lining up beats.
    private(set) var nudge: Double = 0
    /// Channel fader, 0…1.
    var level: Float = 1 { didSet { levelChanged() } }
    /// EQ knobs, −1…1: up to +6 dB, down to a near kill.
    var low: Float = 0 { didSet { eq.bands[0].gain = Deck.eqGain(low) } }
    var mid: Float = 0 { didSet { eq.bands[1].gain = Deck.eqGain(mid) } }
    var high: Float = 0 { didSet { eq.bands[2].gain = Deck.eqGain(high) } }

    static let tempoRange = 0.08
    static let nudgeAmount = 0.03

    @ObservationIgnored let node = AVAudioPlayerNode()
    @ObservationIgnored let input = AVAudioMixerNode()
    @ObservationIgnored let varispeed = AVAudioUnitVarispeed()
    @ObservationIgnored let eq = AVAudioUnitEQ(numberOfBands: 3)
    @ObservationIgnored let channel = AVAudioMixerNode()

    @ObservationIgnored fileprivate var connectedFormat: AVAudioFormat?
    @ObservationIgnored fileprivate var startEngine: () -> Bool = { false }
    @ObservationIgnored fileprivate var didStop: () -> Void = {}
    @ObservationIgnored fileprivate var levelChanged: () -> Void = {}
    /// Bumped per load or eject, so a slow load that's been replaced is dropped.
    @ObservationIgnored fileprivate private(set) var loadToken = 0

    @ObservationIgnored private var file: AVAudioFile?
    /// Bumped whenever the node's schedule is torn down, so stale completions are ignored.
    @ObservationIgnored private var generation = 0
    /// File frame the current segment was scheduled from.
    @ObservationIgnored private var startFrame: AVAudioFramePosition = 0
    @ObservationIgnored private var pausedFrame: AVAudioFramePosition = 0
    @ObservationIgnored private var countedPlay = false

    init(side: Mixer.Side) {
        self.side = side
        let bands = eq.bands
        bands[0].filterType = .lowShelf
        bands[0].frequency = 200
        bands[1].filterType = .parametric
        bands[1].frequency = 1_000
        bands[1].bandwidth = 2
        bands[2].filterType = .highShelf
        bands[2].frequency = 4_000
        for band in bands {
            band.gain = 0
            band.bypass = false
        }
    }

    /// Knob position → dB. Gentle near the middle, steep near the bottom so the end of the travel
    /// takes the band out.
    nonisolated static func eqGain(_ knob: Float) -> Float {
        knob >= 0 ? knob * 6 : -40 * knob * knob
    }

    var isReady: Bool { file != nil }

    var duration: TimeInterval {
        guard let file else { return track?.length ?? 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    var currentTime: TimeInterval {
        guard let file else { return 0 }
        return Double(currentFrame) / file.processingFormat.sampleRate
    }

    /// The track's BPM at the current tempo, if it has one.
    var effectiveBPM: Double? {
        guard let bpm = track?.bpm, bpm > 0 else { return nil }
        return Double(bpm) * (1 + tempo)
    }

    private var currentFrame: AVAudioFramePosition {
        guard let file else { return 0 }
        guard isPlaying else { return pausedFrame }
        guard let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else { return startFrame }
        return min(file.length, startFrame + max(0, playerTime.sampleTime))
    }

    // MARK: Transport

    func play() {
        guard let file, !isPlaying, startEngine() else { return }
        // At the end, play again from the cue point.
        let from = pausedFrame >= file.length - 1 ? frame(for: cuePoint) : pausedFrame
        schedule(from: from)
        node.play()
        isPlaying = true
    }

    func pause() {
        pause(notify: true)
    }

    fileprivate func pause(notify: Bool) {
        guard isPlaying else { return }
        pausedFrame = currentFrame
        halt()
        if notify { didStop() }
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func seek(to seconds: TimeInterval) {
        guard file != nil else { return }
        let target = frame(for: seconds)
        if isPlaying {
            halt()
            schedule(from: target)
            node.play()
            isPlaying = true
        } else {
            pausedFrame = target
        }
    }

    /// Playing: back to the cue point, paused. Paused: the cue point moves here.
    func cue() {
        guard file != nil else { return }
        if isPlaying {
            pause()
            seek(to: cuePoint)
        } else {
            cuePoint = currentTime
        }
    }

    func setNudge(_ amount: Double) {
        nudge = amount
        applyRate()
    }

    /// Sets the tempo so this deck's BPM matches `other`'s (or half/double it, whichever is
    /// closest). Only lines up the speed; the beats still need lining up by ear.
    func matchTempo(to other: Deck) {
        if let match = tempoMatching(other) { tempo = match }
    }

    func tempoMatching(_ other: Deck) -> Double? {
        guard let bpm = track?.bpm, bpm > 0, let target = other.effectiveBPM else { return nil }
        let best = [target, target * 2, target / 2]
            .map { $0 / Double(bpm) - 1 }
            .min { abs($0) < abs($1) }!
        return abs(best) <= Deck.tempoRange + 0.0001 ? best : nil
    }

    func eject() {
        halt()
        didStop()
        loadToken += 1
        track = nil
        file = nil
        waveform = []
        isLoading = false
        errorMessage = nil
        cuePoint = 0
        pausedFrame = 0
    }

    // MARK: Loading (driven by Mixer)

    fileprivate func beginLoading(_ track: Track) -> Int {
        halt()
        didStop()
        loadToken += 1
        self.track = track
        file = nil
        waveform = []
        errorMessage = nil
        isLoading = true
        countedPlay = false
        return loadToken
    }

    fileprivate func finishLoading(_ file: AVAudioFile, at seconds: TimeInterval) {
        self.file = file
        isLoading = false
        pausedFrame = frame(for: seconds)
        cuePoint = Double(pausedFrame) / file.processingFormat.sampleRate
    }

    fileprivate func failLoading(_ message: String) {
        isLoading = false
        errorMessage = message
    }

    /// The track to count as played, once, after half of it (or 4 minutes) has gone by.
    fileprivate func takeDuePlayCount() -> Track? {
        guard isPlaying, !countedPlay, let track, duration > 0,
              currentTime >= min(duration * 0.5, 240) else { return nil }
        countedPlay = true
        return track
    }

    /// Reschedules at the current position, after the engine stopped underneath us.
    fileprivate func restart() {
        guard isPlaying else { return }
        pause(notify: false)
        play()
    }

    // MARK: Scheduling

    private func frame(for seconds: TimeInterval) -> AVAudioFramePosition {
        guard let file else { return 0 }
        let frame = AVAudioFramePosition(max(0, seconds) * file.processingFormat.sampleRate)
        return min(frame, max(0, file.length - 1))
    }

    private func halt() {
        generation += 1
        node.stop()
        isPlaying = false
    }

    private func schedule(from frame: AVAudioFramePosition) {
        guard let file else { return }
        startFrame = frame
        let frames = file.length - frame
        guard frames > 0 else { return }
        let scheduled = generation
        node.scheduleSegment(file, startingFrame: frame, frameCount: AVAudioFrameCount(frames), at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.reachedEnd(generation: scheduled) }
        }
    }

    private func reachedEnd(generation finished: Int) {
        guard finished == generation, isPlaying, let file else { return }
        pausedFrame = file.length
        halt()
        didStop()
    }

    private func applyRate() {
        varispeed.rate = Float((1 + tempo) * (1 + nudge))
    }
}

// MARK: - Waveform

enum Waveform {
    static let bins = 600

    /// RMS loudness per bin across the whole file, scaled so the loudest bin is 1. RMS rather than
    /// peaks: loudly mastered tracks peak near full scale throughout, which hides breakdowns.
    static func levels(of url: URL, bins: Int = Waveform.bins) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536) else { return [] }
        let channels = Int(file.processingFormat.channelCount)
        let length = file.length
        var sums = [Double](repeating: 0, count: bins)
        var counts = [Int](repeating: 0, count: bins)
        var position: AVAudioFramePosition = 0
        while position < length {
            guard (try? file.read(into: buffer)) != nil, buffer.frameLength > 0,
                  let data = buffer.floatChannelData else { break }
            let frames = Int(buffer.frameLength)
            var offset = 0
            while offset < frames {
                let bin = Int((position + AVAudioFramePosition(offset)) * AVAudioFramePosition(bins) / length)
                // The last frame of this bin, or the end of the buffer.
                let binEnd = Int(((AVAudioFramePosition(bin) + 1) * length + AVAudioFramePosition(bins) - 1) / AVAudioFramePosition(bins) - position)
                let end = min(frames, max(offset + 1, binEnd))
                var sum: Double = 0
                for channel in 0..<channels {
                    let samples = data[channel]
                    for index in offset..<end {
                        let sample = Double(samples[index])
                        sum += sample * sample
                    }
                }
                sums[min(bin, bins - 1)] += sum / Double(channels)
                counts[min(bin, bins - 1)] += end - offset
                offset = end
            }
            position += AVAudioFramePosition(frames)
        }
        var levels = zip(sums, counts).map { sum, count in count > 0 ? Float((sum / Double(count)).squareRoot()) : 0 }
        if let loudest = levels.max(), loudest > 0 {
            levels = levels.map { $0 / loudest }
        }
        return levels
    }
}
