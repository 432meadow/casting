import AVFoundation
import Foundation
import Testing
@testable import Susurrus

/// Beat grids and keys from generated audio.
struct AnalysisTests {
    /// Writes mono `samples(t)` for `seconds` as a 44.1 kHz stereo WAV.
    static func write(seconds: Double, sampleRate: Double = 44_100, _ sample: (Double) -> Float) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ])
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            let value = sample(Double(frame) / sampleRate)
            buffer.floatChannelData![0][frame] = value
            buffer.floatChannelData![1][frame] = value
        }
        try file.write(from: buffer)
        return url
    }

    /// Kick-like clicks: a decaying 60 Hz thump plus a short noise burst on every beat.
    static func clicks(bpm: Double, firstBeat: Double, seconds: Double) throws -> URL {
        let period = 60 / bpm
        var noise = SystemRandomNumberGenerator()
        let bursts = (0..<64).map { _ in Float.random(in: -1...1, using: &noise) }
        return try write(seconds: seconds) { t in
            guard t >= firstBeat else { return 0 }
            let since = (t - firstBeat).truncatingRemainder(dividingBy: period)
            let thump = Float(sin(2 * .pi * 60 * since) * exp(-since * 30)) * 0.6
            let burst = since < 0.004 ? bursts[Int(since * 44_100) % 64] * 0.3 : 0
            return thump + burst
        }
    }

    @Test(arguments: [(123.4, 0.31, 123.0), (97.3, 0.12, 97.0), (140.0, 0.05, 140.0)])
    func fitsTheBeatGridOfAClickTrack(bpm: Double, firstBeat: Double, tag: Double) throws {
        let url = try Self.clicks(bpm: bpm, firstBeat: firstBeat, seconds: 40)
        defer { try? FileManager.default.removeItem(at: url) }
        // The tag is whole BPM; the grid finds the real tempo.
        let analysis = try #require(TrackAnalysis.analyze(url, bpmHint: tag))
        let grid = try #require(analysis.grid)
        #expect(abs(grid.bpm - bpm) < 0.03)
        let period = 60 / bpm
        var error = (grid.firstBeat - firstBeat).truncatingRemainder(dividingBy: period)
        if error > period / 2 { error -= period }
        if error < -period / 2 { error += period }
        // The onset envelope's resolution is ~6 ms.
        #expect(abs(error) < 0.008, "beat off by \(Int((error * 1000).rounded())) ms")
        #expect(grid.phase(at: firstBeat + period * 10) < 0.01 || grid.phase(at: firstBeat + period * 10) > 0.99)
        #expect(analysis.overview.count == TrackAnalysis.overviewBins)
        #expect(abs(analysis.detailRate - 150) < 1)
    }

    @Test func detectsTheTempoWithoutATag() throws {
        let url = try Self.clicks(bpm: 126, firstBeat: 0.2, seconds: 40)
        defer { try? FileManager.default.removeItem(at: url) }
        let grid = try #require(TrackAnalysis.analyze(url, bpmHint: nil)?.grid)
        #expect(abs(grid.bpm - 126) < 0.05)
    }

    // MARK: Keys

    /// Each chord's notes as MIDI numbers, two seconds apiece, with a few harmonics.
    static func chords(_ progression: [[Int]], repeats: Int = 4) -> BPMDetector.Excerpt {
        let rate = 11_025.0
        var samples: [Float] = []
        for _ in 0..<repeats {
            for chord in progression {
                for n in 0..<Int(2 * rate) {
                    let t = Double(n) / rate
                    var value = 0.0
                    for note in chord {
                        let hertz = 440 * pow(2, Double(note - 69) / 12)
                        for harmonic in 1...4 where hertz * Double(harmonic) < rate / 2 {
                            value += sin(2 * .pi * hertz * Double(harmonic) * t) / Double(harmonic * harmonic)
                        }
                    }
                    samples.append(Float(value * 0.1))
                }
            }
        }
        return BPMDetector.Excerpt(samples: samples, sampleRate: rate)
    }

    @Test func detectsMajorAndMinorKeys() {
        // I–IV–V–I in C, with the bass note under each chord.
        let cMajor = Self.chords([[48, 60, 64, 67], [41, 60, 65, 69], [43, 59, 62, 67], [48, 60, 64, 67]])
        #expect(KeyDetector.key(of: cMajor) == MusicalKey(tonic: 0, isMinor: false))
        // i–iv–V–i in A minor (the V has G#).
        let aMinor = Self.chords([[45, 57, 60, 64], [50, 57, 62, 65], [52, 56, 59, 64], [45, 57, 60, 64]])
        #expect(KeyDetector.key(of: aMinor) == MusicalKey(tonic: 9, isMinor: true))
        // i–VI–VII–i in F# minor.
        let fSharpMinor = Self.chords([[42, 54, 57, 61], [38, 54, 57, 62], [40, 56, 59, 64], [42, 54, 57, 61]])
        #expect(KeyDetector.key(of: fSharpMinor) == MusicalKey(tonic: 6, isMinor: true))
        // Silence has no key.
        #expect(KeyDetector.key(of: BPMDetector.Excerpt(samples: [Float](repeating: 0, count: 200_000), sampleRate: 11_025)) == nil)
    }

    @Test func keyNotationsAndTheCamelotWheel() throws {
        let aMinor = MusicalKey(tonic: 9, isMinor: true)
        #expect(aMinor.name == "Am" && aMinor.camelot == "8A")
        #expect(MusicalKey(tonic: 0, isMinor: false).camelot == "8B")
        #expect(MusicalKey(tonic: 7, isMinor: false).camelot == "9B")
        #expect(MusicalKey(tonic: 5, isMinor: false).camelot == "7B")
        #expect(MusicalKey(tonic: 4, isMinor: true).camelot == "9A")
        #expect(MusicalKey(tonic: 11, isMinor: false).camelot == "1B")
        for text in ["Am", "A minor", "Amin", "a m", "8A", "08A"] {
            #expect(MusicalKey(parsing: text) == aMinor, "\(text)")
        }
        #expect(MusicalKey(parsing: "F#") == MusicalKey(tonic: 6, isMinor: false))
        #expect(MusicalKey(parsing: "Gb") == MusicalKey(tonic: 6, isMinor: false))
        #expect(MusicalKey(parsing: "C♯m") == MusicalKey(tonic: 1, isMinor: true))
        #expect(MusicalKey(parsing: "12B") == MusicalKey(tonic: 4, isMinor: false))
        #expect(MusicalKey(parsing: "13A") == nil && MusicalKey(parsing: "H") == nil && MusicalKey(parsing: "") == nil)
        // Every key reads back from both of its notations.
        for tonic in 0..<12 {
            for isMinor in [false, true] {
                let key = MusicalKey(tonic: tonic, isMinor: isMinor)
                #expect(MusicalKey(parsing: key.name) == key && MusicalKey(parsing: key.camelot) == key)
            }
        }
        // Compatible: same key, a step round the wheel, the relative major. Not: two steps, a tritone.
        #expect(aMinor.isCompatible(with: try #require(MusicalKey(parsing: "9A"))))
        #expect(aMinor.isCompatible(with: try #require(MusicalKey(parsing: "7A"))))
        #expect(aMinor.isCompatible(with: try #require(MusicalKey(parsing: "C"))))
        #expect(try #require(MusicalKey(parsing: "1A")).isCompatible(with: try #require(MusicalKey(parsing: "12A"))))
        #expect(!aMinor.isCompatible(with: try #require(MusicalKey(parsing: "10A"))))
        #expect(!aMinor.isCompatible(with: try #require(MusicalKey(parsing: "D#m"))))
        #expect(aMinor.transposed(by: 1) == MusicalKey(parsing: "Bbm"))
    }
}
