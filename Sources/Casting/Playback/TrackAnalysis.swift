import Accelerate
import AVFoundation

/// Where a track's beats fall: a steady tempo and the time of one beat.
struct BeatGrid: Equatable, Sendable {
    var bpm: Double
    /// The first beat at or after the start of the track, in seconds.
    var firstBeat: TimeInterval

    var period: TimeInterval { 60 / bpm }

    /// How far through its beat `time` is, 0 (on the beat) up to 1.
    func phase(at time: TimeInterval) -> Double {
        let beats = (time - firstBeat) / period
        return beats - beats.rounded(.down)
    }

    /// The beat times from `start` to `end`.
    func beats(from start: TimeInterval, to end: TimeInterval) -> [TimeInterval] {
        guard end > start else { return [] }
        let first = ((start - firstBeat) / period).rounded(.up)
        let last = ((end - firstBeat) / period).rounded(.down)
        guard last >= first else { return [] }
        return stride(from: first, through: last, by: 1).map { firstBeat + $0 * period }
    }

    /// Fits a grid to an onset envelope: tries tempos within 3% of `bpm` in steps of 0.01 and,
    /// for each, folds the envelope onto one beat. The tempo whose fold peaks hardest wins, and
    /// the peak is where the beat falls. `startTime` is when the envelope begins in the track.
    static func fit(envelope: [Float], framesPerSecond: Double, around bpm: Double, startTime: TimeInterval) -> BeatGrid? {
        guard envelope.count > Int(framesPerSecond * 8) else { return nil }
        let bins = 64
        var best: (score: Float, bpm: Double, phase: Double) = (0, bpm, 0)
        var histogram = [Float](repeating: 0, count: bins)
        for candidate in stride(from: bpm * 0.97, through: bpm * 1.03, by: 0.01) {
            let period = 60 / candidate * framesPerSecond
            for i in 0..<bins { histogram[i] = 0 }
            for (index, value) in envelope.enumerated() where value > 0 {
                let beats = Double(index) / period
                histogram[min(bins - 1, Int((beats - beats.rounded(.down)) * Double(bins)))] += value
            }
            // Smoothed around the circle, so a beat split across two bins still counts whole.
            var peak: Float = 0, peakBin = 0, total: Float = 0
            for i in 0..<bins {
                let smoothed = histogram[(i + bins - 1) % bins] + 2 * histogram[i] + histogram[(i + 1) % bins]
                total += histogram[i]
                if smoothed > peak { (peak, peakBin) = (smoothed, i) }
            }
            guard total > 0 else { continue }
            let score = peak / 4 / (total / Float(bins))
            if score > best.score { best = (score, candidate, (Double(peakBin) + 0.5) / Double(bins)) }
        }
        // A fold no peakier than ~1.6× its average means the onsets don't line up with any beat.
        guard best.score > 1.6 else { return nil }
        let period = 60 / best.bpm
        let beat = startTime + refinedPhase(envelope, period: period * framesPerSecond) * period
        return BeatGrid(bpm: (best.bpm * 100).rounded() / 100, firstBeat: beat - (beat / period).rounded(.down) * period)
    }
}

extension BeatGrid {
    /// Where in the beat the onsets fall, to a fraction of a millisecond: a finer fold at the
    /// chosen tempo, smoothed, with the peak placed between bins.
    fileprivate static func refinedPhase(_ envelope: [Float], period: Double) -> Double {
        let bins = 512
        var histogram = [Float](repeating: 0, count: bins)
        for (index, value) in envelope.enumerated() where value > 0 {
            let beats = Double(index) / period
            histogram[min(bins - 1, Int((beats - beats.rounded(.down)) * Double(bins)))] += value
        }
        let radius = 6
        var smoothed = [Float](repeating: 0, count: bins)
        for center in 0..<bins {
            var sum: Float = 0
            for offset in -radius...radius {
                let weight = Float(radius + 1 - abs(offset))
                sum += histogram[(center + offset + bins) % bins] * weight
            }
            smoothed[center] = sum
        }
        let peak = smoothed.indices.max { smoothed[$0] < smoothed[$1] }!
        let left = smoothed[(peak + bins - 1) % bins], middle = smoothed[peak], right = smoothed[(peak + 1) % bins]
        let curvature = left - 2 * middle + right
        let shift = curvature < 0 ? Double(0.5 * (left - right) / curvature) : 0
        return (Double(peak) + 0.5 + shift) / Double(bins)
    }
}

/// What a deck learns from reading a whole file: its loudness at two zoom levels, its beat grid
/// and its key.
struct TrackAnalysis: Sendable {
    /// Loudness across the whole track, `overviewBins` values scaled so the loudest is 1.
    var overview: [Float]
    /// Loudness at `detailRate` values per second, on the same scale as the loudest detail value.
    var detail: [Float]
    var detailRate: Double
    var grid: BeatGrid?
    var key: MusicalKey?

    static let overviewBins = 600
    static let detailRate = 150.0
    /// How much from the middle of the track the beat grid and key are worked out from.
    static let excerptSeconds = 120.0
    /// Where in an envelope frame (as a fraction of its length) an onset lands, measured on click
    /// tracks (see MixerTests).
    static let onsetLag = 0.71

    /// RMS loudness rather than peaks: loudly mastered tracks peak near full scale throughout,
    /// which hides the breakdowns. Reads the file once; the middle two minutes are also mixed
    /// down to ~11 kHz mono for the beat grid (tempo from `bpmHint` when it's known, detected
    /// otherwise) and the key.
    static func analyze(_ url: URL, bpmHint: Double?) -> TrackAnalysis? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536) else { return nil }
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let length = file.length
        let rate = format.sampleRate
        let framesPerDetail = max(1, Int((rate / detailRate).rounded()))
        var squares = [Double](repeating: 0, count: Int(length) / framesPerDetail + 1)

        let factor = max(1, Int(rate / 11_025))
        let excerptFrames = min(length, AVAudioFramePosition(excerptSeconds * rate))
        let excerptStart = (length - excerptFrames) / 2
        let excerptEnd = excerptStart + excerptFrames
        var mono: [Float] = []
        mono.reserveCapacity(Int(excerptFrames) / factor + 1)
        var accumulator: Float = 0
        var accumulated = 0
        let gain = 1 / Float(channels * factor)

        var position: AVAudioFramePosition = 0
        while position < length {
            guard (try? file.read(into: buffer)) != nil, buffer.frameLength > 0,
                  let data = buffer.floatChannelData else { break }
            let frames = Int(buffer.frameLength)
            for frame in 0..<frames {
                var square: Float = 0
                var sum: Float = 0
                for channel in 0..<channels {
                    let sample = data[channel][frame]
                    square += sample * sample
                    sum += sample
                }
                let absolute = position + AVAudioFramePosition(frame)
                squares[Int(absolute) / framesPerDetail] += Double(square)
                if absolute >= excerptStart, absolute < excerptEnd {
                    accumulator += sum
                    accumulated += 1
                    if accumulated == factor {
                        mono.append(accumulator * gain)
                        accumulator = 0
                        accumulated = 0
                    }
                }
            }
            position += AVAudioFramePosition(frames)
        }

        let perBin = Double(framesPerDetail * channels)
        var detail = squares.map { Float(($0 / perBin).squareRoot()) }
        var overview = [Float](repeating: 0, count: overviewBins)
        var counts = [Int](repeating: 0, count: overviewBins)
        for (index, square) in squares.enumerated() {
            let bin = min(overviewBins - 1, index * overviewBins / max(1, squares.count))
            overview[bin] += Float(square)
            counts[bin] += 1
        }
        overview = zip(overview, counts).map { sum, count in count > 0 ? (sum / (Float(count) * Float(perBin))).squareRoot() : 0 }
        if let loudest = overview.max(), loudest > 0 { overview = overview.map { $0 / loudest } }
        if let loudest = detail.max(), loudest > 0 { detail = detail.map { $0 / loudest } }

        let excerpt = BPMDetector.Excerpt(samples: mono, sampleRate: rate / Double(factor))
        let framesPerSecond = excerpt.sampleRate / Double(BPMDetector.hop)
        let envelope = BPMDetector.onsetEnvelope(mono, framesPerSecond: framesPerSecond)
        // An envelope frame peaks a little after the frame starts: a new sound counts most once
        // it's well into the analysis window.
        let onsetDelay = Double(BPMDetector.frameSize) * onsetLag / excerpt.sampleRate
        let grid = (bpmHint ?? BPMDetector.tempo(of: excerpt)).flatMap {
            BeatGrid.fit(envelope: envelope, framesPerSecond: framesPerSecond, around: $0,
                         startTime: Double(excerptStart) / rate + onsetDelay)
        }
        return TrackAnalysis(overview: overview, detail: detail, detailRate: rate / Double(framesPerDetail),
                             grid: grid, key: KeyDetector.key(of: excerpt))
    }
}
