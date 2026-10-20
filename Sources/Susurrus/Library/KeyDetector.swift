import Accelerate
import Foundation

/// A musical key, shown in standard notation ("Am", "F#") or Camelot ("8A").
struct MusicalKey: Hashable, Sendable {
    /// Pitch class of the tonic: 0 is C, 11 is B.
    var tonic: Int
    var isMinor: Bool

    init(tonic: Int, isMinor: Bool) {
        self.tonic = ((tonic % 12) + 12) % 12
        self.isMinor = isMinor
    }

    private static let majorNames = ["C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    private static let minorNames = ["Cm", "C#m", "Dm", "Ebm", "Em", "Fm", "F#m", "Gm", "G#m", "Am", "Bbm", "Bm"]

    var name: String { isMinor ? Self.minorNames[tonic] : Self.majorNames[tonic] }

    /// The Camelot wheel position, 1–12: neighbours are a fifth apart. Minor keys share the
    /// number of their relative major.
    var camelotNumber: Int {
        let major = isMinor ? (tonic + 3) % 12 : tonic
        return (major * 7 % 12 + 7) % 12 + 1
    }

    var camelot: String { "\(camelotNumber)\(isMinor ? "A" : "B")" }

    /// "8A · Am"
    var label: String { "\(camelot) · \(name)" }

    /// Sorts round the Camelot wheel: 1A, 1B, 2A, …
    var sortIndex: Int { camelotNumber * 2 + (isMinor ? 0 : 1) }

    func transposed(by semitones: Int) -> MusicalKey {
        MusicalKey(tonic: tonic + semitones, isMinor: isMinor)
    }

    /// Mixes without clashing: the same key, a step round the wheel, or the relative major/minor.
    func isCompatible(with other: MusicalKey) -> Bool {
        let step = abs(camelotNumber - other.camelotNumber)
        if isMinor == other.isMinor { return step == 0 || step == 1 || step == 11 }
        return step == 0
    }

    /// Reads the notations taggers write: "Am", "A minor", "Amin", "F#", "Gb", "C♯m", "8A", "08B".
    init?(parsing text: String) {
        var text = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b")
        guard !text.isEmpty else { return nil }
        // Camelot: a number 1–12 and A (minor) or B (major).
        if let letter = text.last?.uppercased(), letter == "A" || letter == "B",
           let number = Int(text.dropLast()), (1...12).contains(number) {
            let major = ((number - 8) * 7 % 12 + 12) % 12
            self.init(tonic: letter == "A" ? major - 3 : major, isMinor: letter == "A")
            return
        }
        let letters: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
        guard let first = text.first?.uppercased().first, var tonic = letters[first] else { return nil }
        text.removeFirst()
        if text.hasPrefix("#") { tonic += 1; text.removeFirst() } else if text.hasPrefix("b") { tonic -= 1; text.removeFirst() }
        let rest = text.trimmingCharacters(in: .whitespaces).lowercased()
        switch rest {
        case "", "maj", "major", "dur": self.init(tonic: tonic, isMinor: false)
        case "m", "min", "minor", "moll": self.init(tonic: tonic, isMinor: true)
        default: return nil
        }
    }
}

/// Estimates a track's key from a minute of audio out of its middle.
///
/// Builds a chromagram (how much of each of the 12 pitch classes sounds, from 55 Hz to 1.8 kHz,
/// each frame weighted equally), then picks the major or minor key whose Krumhansl–Kessler
/// profile correlates best with it. Like any key detector it's an estimate: tonal tracks with a
/// clear centre come out reliably, modal or atonal ones less so, and drum-only tracks get none.
enum KeyDetector {
    static let excerptSeconds = 60.0

    static func detect(fileAt url: URL) throws -> MusicalKey? {
        key(of: try BPMDetector.readExcerpt(url, seconds: excerptSeconds))
    }

    private static let majorProfile: [Float] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    private static let minorProfile: [Float] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    static func key(of excerpt: BPMDetector.Excerpt) -> MusicalKey? {
        guard let chroma = chromagram(excerpt) else { return nil }
        var best: (score: Float, key: MusicalKey)?
        for tonic in 0..<12 {
            for isMinor in [false, true] {
                let profile = isMinor ? minorProfile : majorProfile
                // The profile turned round to this tonic: index i is pitch class i.
                let rotated = (0..<12).map { profile[(($0 - tonic) % 12 + 12) % 12] }
                let score = correlation(chroma, rotated)
                if score > best?.score ?? -1 { best = (score, MusicalKey(tonic: tonic, isMinor: isMinor)) }
            }
        }
        guard let best, best.score > 0.3 else { return nil }
        return best.key
    }

    private static let frameSize = 8192
    private static let hop = 4096

    /// Summed pitch-class energy, or nil when there's too little tonal content to say.
    static func chromagram(_ excerpt: BPMDetector.Excerpt) -> [Float]? {
        let samples = excerpt.samples
        let frameCount = (samples.count - frameSize) / hop + 1
        guard excerpt.sampleRate > 0, frameCount >= 4,
              let fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(frameSize))), radix: .radix2, ofType: DSPSplitComplex.self) else { return nil }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: frameSize, isHalfWindow: false)
        let bins = frameSize / 2
        let binHertz = excerpt.sampleRate / Double(frameSize)

        // Each FFT bin's share of the nearest pitch class, fading to nothing a quarter tone away.
        var binClass = [Int](repeating: -1, count: bins)
        var binWeight = [Float](repeating: 0, count: bins)
        for bin in 1..<bins {
            let hertz = Double(bin) * binHertz
            guard hertz >= 55, hertz <= 1_760 else { continue }
            let midi = 69 + 12 * log2(hertz / 440)
            let nearest = midi.rounded()
            binClass[bin] = Int(nearest) % 12
            binWeight[bin] = Float(max(0, 1 - 2 * abs(midi - nearest)))
        }

        var real = [Float](repeating: 0, count: bins)
        var imaginary = [Float](repeating: 0, count: bins)
        var windowed = [Float](repeating: 0, count: frameSize)
        var magnitudes = [Float](repeating: 0, count: bins)
        var total = [Float](repeating: 0, count: 12)
        var tonalFrames = 0
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
            var chroma = [Float](repeating: 0, count: 12)
            for bin in 1..<bins where binClass[bin] >= 0 {
                // Square-rooted so a few loud bass notes don't drown out the harmony.
                chroma[binClass[bin]] += magnitudes[bin].squareRoot() * binWeight[bin]
            }
            let sum = chroma.reduce(0, +)
            guard sum > 1e-3 else { continue }  // silence
            for index in 0..<12 { total[index] += chroma[index] / sum }
            tonalFrames += 1
        }
        guard tonalFrames >= 4 else { return nil }
        return total
    }

    private static func correlation(_ x: [Float], _ y: [Float]) -> Float {
        let meanX = vDSP.mean(x), meanY = vDSP.mean(y)
        var covariance: Float = 0, varianceX: Float = 0, varianceY: Float = 0
        for i in x.indices {
            let dx = x[i] - meanX, dy = y[i] - meanY
            covariance += dx * dy
            varianceX += dx * dx
            varianceY += dy * dy
        }
        guard varianceX > 0, varianceY > 0 else { return 0 }
        return covariance / (varianceX * varianceY).squareRoot()
    }
}
