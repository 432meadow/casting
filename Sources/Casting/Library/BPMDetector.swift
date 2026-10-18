import Accelerate
import AVFoundation

/// Estimates a track's tempo from 30 seconds of audio out of its middle.
///
/// Lightweight on purpose: only about 30 seconds' worth of the file is read (around 1 MB of an MP3
/// over the share), it's mixed to mono at ~11 kHz, and the tempo is the strongest periodicity of a
/// spectral-flux onset envelope (autocorrelation, reinforced at 2, 3 and 4 beats, with a gentle
/// preference for tempos near 120 BPM). Good for steady, beat-driven music; rubato tracks get a
/// number that means little, as with any tagger, and tracks with no clear beat get none.
///
/// Tempos are folded into 70–140 BPM (a 160 BPM detection is reported as 80), the convention
/// 99% of this library's existing BPM tags follow. Against 319 of those tags the detector agreed
/// within 2% on 80% of tracks, and up to half/double or 3:2 time on 84%.
enum BPMDetector {
    struct Excerpt {
        var samples: [Float]
        var sampleRate: Double
    }

    static let excerptSeconds = 30.0
    static let tempoRange = 60.0...200.0
    static let reportedRange = 70.0..<140.0

    static func detect(fileAt url: URL) throws -> Double? {
        tempo(of: try readExcerpt(url))
    }

    // MARK: Reading the excerpt

    /// About `seconds` from the middle of the file, mixed to mono and decimated to ~11–12 kHz.
    ///
    /// AudioToolbox walks a whole MP3 or FLAC file to find its packets before it can seek, which
    /// over the share means reading all of it. So for those two, a byte range from the middle is
    /// copied into a small temp file that decodes on its own (MP3 frames resync by themselves; FLAC
    /// gets its STREAMINFO header put back in front of the first whole frame). Other formats seek
    /// through their headers' packet tables, so they're opened in place.
    static func readExcerpt(_ url: URL, seconds: Double = excerptSeconds) throws -> Excerpt {
        let fragment: (data: Data, pathExtension: String)?
        switch url.pathExtension.lowercased() {
        case "mp3": fragment = try mp3Fragment(url, seconds: seconds).map { ($0, "mp3") }
        case "flac": fragment = try flacFragment(url, seconds: seconds).map { ($0, "flac") }
        default: fragment = nil
        }
        guard let fragment else {
            return try decode(AVAudioFile(forReading: url), seconds: seconds, fromMiddle: true)
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("casting-bpm-\(UUID().uuidString).\(fragment.pathExtension)")
        try fragment.data.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        return try decode(AVAudioFile(forReading: temp), seconds: seconds, fromMiddle: false)
    }

    private static func decode(_ file: AVAudioFile, seconds: Double, fromMiddle: Bool) throws -> Excerpt {
        let format = file.processingFormat
        let factor = max(1, Int(format.sampleRate / 11025))
        let wanted = AVAudioFramePosition(seconds * format.sampleRate)
        // A fragment's length is unknown (0), so it's read until it runs out.
        var remaining = wanted
        if fromMiddle {
            let start = max(0, (file.length - wanted) / 2)
            file.framePosition = start
            remaining = min(wanted, file.length - start)
        }

        let chunk: AVAudioFrameCount = 1 << 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return Excerpt(samples: [], sampleRate: 0) }
        var samples: [Float] = []
        samples.reserveCapacity(Int(remaining) / factor + 1)
        var accumulator: Float = 0
        var accumulated = 0
        let gain = 1 / Float(format.channelCount * UInt32(factor))
        while remaining > 0 {
            do {
                try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(chunk), remaining)))
            } catch {
                // The end of a fragment reads as an error rather than as zero frames.
                if samples.isEmpty { throw error }
                break
            }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channels = buffer.floatChannelData else { break }
            remaining -= Int64(frames)
            for frame in 0..<frames {
                for channel in 0..<Int(format.channelCount) { accumulator += channels[channel][frame] }
                accumulated += 1
                if accumulated == factor {
                    samples.append(accumulator * gain)
                    accumulator = 0
                    accumulated = 0
                }
            }
        }
        return Excerpt(samples: samples, sampleRate: format.sampleRate / Double(factor))
    }

    /// The middle of an MP3, enough for `seconds` at 320 kbps, starting on a frame. nil for files
    /// small enough to read whole.
    private static func mp3Fragment(_ url: URL, seconds: Double) throws -> Data? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        // Skip an ID3v2 tag: with cover art embedded it can be most of a small file.
        try handle.seek(toOffset: 0)
        var audioStart: UInt64 = 0
        if let header = try handle.read(upToCount: 10), header.count == 10, header.prefix(3) == Data("ID3".utf8) {
            let tagSize = header[6...9].reduce(UInt64(0)) { $0 << 7 | UInt64($1 & 0x7F) }
            audioStart = 10 + tagSize + (header[5] & 0x10 != 0 ? 10 : 0)
        }
        let length = UInt64((seconds + 2) * 320_000 / 8)
        guard size > audioStart, size - audioStart > length * 2 else { return nil }
        try handle.seek(toOffset: audioStart + (size - audioStart - length) / 2)
        // AudioToolbox only recognizes the file if it starts on a frame. No frames at all means a
        // damaged file; opening it whole instead would only read megabytes more of the same.
        guard let chunk = try handle.read(upToCount: Int(length)), let start = firstMP3Frame(in: chunk) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
        }
        return chunk[(chunk.startIndex + start)...]
    }

    /// Offset of the first MPEG layer III frame header in `data` that's followed by two more
    /// where its length says they should be (a lone 0xFFF… in the audio data is common).
    static func firstMP3Frame(in data: Data) -> Int? {
        let bytes = [UInt8](data)
        func frameLength(at index: Int) -> Int? {
            guard index + 4 <= bytes.count, bytes[index] == 0xFF, bytes[index + 1] & 0xE0 == 0xE0 else { return nil }
            let version = (bytes[index + 1] >> 3) & 0x03  // 3 = MPEG-1, 2 = MPEG-2, 0 = MPEG-2.5
            let layer = (bytes[index + 1] >> 1) & 0x03     // 1 = layer III
            let bitrateIndex = Int(bytes[index + 2] >> 4), rateIndex = Int((bytes[index + 2] >> 2) & 0x03)
            guard version != 1, layer == 1, (1...14).contains(bitrateIndex), rateIndex != 3 else { return nil }
            let mpeg1 = version == 3
            let kbps = (mpeg1 ? [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
                              : [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160])[bitrateIndex - 1]
            let sampleRate = [44100, 48000, 32000][rateIndex] >> (mpeg1 ? 0 : version == 2 ? 1 : 2)
            return (mpeg1 ? 144 : 72) * kbps * 1000 / sampleRate + Int((bytes[index + 2] >> 1) & 0x01)
        }
        for index in bytes.indices {
            guard let first = frameLength(at: index), let second = frameLength(at: index + first),
                  frameLength(at: index + first + second) != nil else { continue }
            return index
        }
        return nil
    }

    /// A playable FLAC file made of the original STREAMINFO and frames from the middle of the
    /// stream. nil when the file is small or its header isn't FLAC's (then it's opened as is).
    private static func flacFragment(_ url: URL, seconds: Double) throws -> Data? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        guard let marker = try handle.read(upToCount: 4), marker == Data("fLaC".utf8) else { return nil }

        // Metadata blocks: STREAMINFO first, then whatever (cover art can be megabytes; skip it).
        var streamInfo: Data?
        var offset: UInt64 = 4
        while true {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 4), header.count == 4 else { return nil }
            let length = UInt64(header[1]) << 16 | UInt64(header[2]) << 8 | UInt64(header[3])
            if header[0] & 0x7F == 0 { streamInfo = try handle.read(upToCount: Int(length)) }
            offset += 4 + length
            if header[0] & 0x80 != 0 { break }
        }
        guard var info = streamInfo, info.count == 34 else { return nil }

        // 20-bit sample rate and 36-bit sample count, packed from byte 10.
        let sampleRate = Int(info[10]) << 12 | Int(info[11]) << 4 | Int(info[12]) >> 4
        let totalSamples = UInt64(info[13] & 0x0F) << 32 | UInt64(info[14]) << 24 | UInt64(info[15]) << 16
            | UInt64(info[16]) << 8 | UInt64(info[17])
        guard sampleRate > 0, totalSamples > 0, size > offset else { return nil }
        let bytesPerSecond = Double(size - offset) / (Double(totalSamples) / Double(sampleRate))
        let length = UInt64((seconds + 2) * bytesPerSecond)
        guard size - offset > length * 2 else { return nil }

        try handle.seek(toOffset: offset + (size - offset - length) / 2)
        guard let chunk = try handle.read(upToCount: Int(length)), let sync = firstFLACFrame(in: chunk) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
        }

        // The fragment's length is unknown to the decoder: zero the sample count and MD5.
        info[13] &= 0xF0
        info.replaceSubrange(14..<34, with: Data(count: 20))
        var result = Data("fLaC".utf8)
        result.append(contentsOf: [0x80, 0, 0, 34])  // last metadata block, STREAMINFO, 34 bytes
        result.append(info)
        result.append(chunk[(chunk.startIndex + sync)...])
        return result
    }

    /// Offset of the first byte in `data` that starts a FLAC frame header with a valid CRC-8.
    static func firstFLACFrame(in data: Data) -> Int? {
        let bytes = [UInt8](data)
        var index = 0
        while index + 16 < bytes.count {
            defer { index += 1 }
            guard bytes[index] == 0xFF, bytes[index + 1] & 0xFE == 0xF8 else { continue }
            let blockSizeCode = bytes[index + 2] >> 4, rateCode = bytes[index + 2] & 0x0F
            guard blockSizeCode != 0, rateCode != 0x0F, bytes[index + 3] >> 4 <= 10,
                  bytes[index + 3] & 0x06 != 0x06, bytes[index + 3] & 0x01 == 0 else { continue }
            // UTF-8-style coded frame or sample number.
            var end = index + 4
            let lead = bytes[end]
            let extra = lead < 0x80 ? 0 : lead >= 0xFE ? 6 : lead >= 0xFC ? 5 : lead >= 0xF8 ? 4
                : lead >= 0xF0 ? 3 : lead >= 0xE0 ? 2 : lead >= 0xC0 ? 1 : -1
            guard extra >= 0 else { continue }
            end += 1 + extra
            end += blockSizeCode == 6 ? 1 : blockSizeCode == 7 ? 2 : 0
            end += rateCode == 12 ? 1 : rateCode == 13 || rateCode == 14 ? 2 : 0
            guard end < bytes.count else { return nil }
            var crc: UInt8 = 0
            for byte in bytes[index..<end] {
                crc ^= byte
                for _ in 0..<8 { crc = crc & 0x80 != 0 ? (crc << 1) ^ 0x07 : crc << 1 }
            }
            if crc == bytes[end] { return index }
        }
        return nil
    }

    /// Beats per minute within `reportedRange`, or nil when the excerpt is too short or has no
    /// rhythm to speak of.
    static func tempo(of excerpt: Excerpt) -> Double? {
        guard var bpm = strongestTempo(of: excerpt) else { return nil }
        while bpm >= reportedRange.upperBound { bpm /= 2 }
        while bpm < reportedRange.lowerBound { bpm *= 2 }
        return bpm
    }

    /// How many beats out the autocorrelation is checked (each adds evidence for the same tempo).
    private static let beatMultiples = 4

    private static func strongestTempo(of excerpt: Excerpt) -> Double? {
        let framesPerSecond = excerpt.sampleRate / Double(hop)
        var envelope = onsetEnvelope(excerpt.samples, framesPerSecond: framesPerSecond)
        // Centered, so a steady texture (noise, a held chord) correlates to ~0 at every lag.
        vDSP.add(-vDSP.mean(envelope), envelope, result: &envelope)
        guard envelope.count > Int(framesPerSecond * 8) else { return nil }

        // Autocorrelation out to four beats at the slowest tempo.
        let maxLag = Int(Double(beatMultiples) * 60 / tempoRange.lowerBound * framesPerSecond) + 2
        guard maxLag < envelope.count / 2 else { return nil }
        var correlation = [Float](repeating: 0, count: maxLag + 1)
        envelope.withUnsafeBufferPointer { e in
            for lag in 0...maxLag {
                var sum: Float = 0
                vDSP_dotpr(e.baseAddress!, 1, e.baseAddress! + lag, 1, &sum, vDSP_Length(e.count - lag))
                correlation[lag] = sum / Float(e.count - lag)
            }
        }
        guard correlation[0] > 0 else { return nil }

        func interpolated(at lag: Double) -> Double {
            let index = Int(lag)
            guard index + 1 < correlation.count else { return 0 }
            let fraction = Float(lag - Double(index))
            return Double(correlation[index] * (1 - fraction) + correlation[index + 1] * fraction)
        }
        func score(_ bpm: Double) -> Double {
            let beat = 60 / bpm * framesPerSecond
            var periodicity = 0.0
            for multiple in 1...beatMultiples { periodicity += interpolated(at: beat * Double(multiple)) }
            let octaves = log2(bpm / 120)
            return periodicity * exp(-0.5 * octaves * octaves)
        }

        // Coarse grid, then a fine one around the best candidate.
        var best = tempoRange.lowerBound
        var bestScore = -Double.infinity
        for bpm in stride(from: tempoRange.lowerBound, through: tempoRange.upperBound, by: 0.5) {
            let s = score(bpm)
            if s > bestScore { (best, bestScore) = (bpm, s) }
        }
        for bpm in stride(from: best - 0.5, through: best + 0.5, by: 0.02) {
            let s = score(bpm)
            if s > bestScore { (best, bestScore) = (bpm, s) }
        }
        // A flat autocorrelation means there's no beat to report. (Normalized like this, real
        // tracks with a tagged tempo the detector agrees with mostly score 0.15–0.6.)
        guard bestScore / Double(correlation[0]) / Double(beatMultiples) > 0.05 else { return nil }
        return best
    }

    // MARK: Onset envelope

    private static let frameSize = 512
    private static let hop = 64

    /// Half-wave-rectified spectral flux of log magnitudes, with its slow drift removed.
    static func onsetEnvelope(_ samples: [Float], framesPerSecond: Double) -> [Float] {
        let frameCount = (samples.count - frameSize) / hop
        guard frameCount > 2, let fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(frameSize))), radix: .radix2, ofType: DSPSplitComplex.self) else { return [] }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: frameSize, isHalfWindow: false)
        let bins = frameSize / 2

        var real = [Float](repeating: 0, count: bins)
        var imaginary = [Float](repeating: 0, count: bins)
        var windowed = [Float](repeating: 0, count: frameSize)
        var magnitudes = [Float](repeating: 0, count: bins)
        var previous = [Float](repeating: 0, count: bins)
        var flux = [Float](repeating: 0, count: frameCount)

        for frame in 0..<frameCount {
            samples.withUnsafeBufferPointer { s in
                vDSP.multiply(UnsafeBufferPointer(rebasing: s[frame * hop ..< frame * hop + frameSize]), window, result: &windowed)
            }
            real.withUnsafeMutableBufferPointer { r in
                imaginary.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    windowed.withUnsafeBytes { vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(bins)) }
                    fft.forward(input: split, output: &split)
                    vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(bins))
                }
            }
            // log(1 + γ·|X|) so quiet and loud passages count alike.
            for bin in 0..<bins { magnitudes[bin] = log1p(magnitudes[bin]) }
            if frame > 0 {
                var sum: Float = 0
                for bin in 1..<bins { sum += max(0, magnitudes[bin] - previous[bin]) }
                flux[frame] = sum
            }
            swap(&magnitudes, &previous)
        }

        // Subtract a ~0.5 s moving average and keep what sticks out: the onsets.
        let radius = max(1, Int(0.25 * framesPerSecond))
        var running = [Float](repeating: 0, count: frameCount + 1)
        for frame in 0..<frameCount { running[frame + 1] = running[frame] + flux[frame] }
        return (0..<frameCount).map { frame in
            let lower = max(0, frame - radius), upper = min(frameCount, frame + radius + 1)
            return max(0, flux[frame] - (running[upper] - running[lower]) / Float(upper - lower))
        }
    }
}
