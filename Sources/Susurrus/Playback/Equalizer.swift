import AVFoundation
import Observation

/// 10-band graphic EQ (iTunes band layout) on an AVAudioUnitEQ in the playback graph.
@MainActor
@Observable
final class Equalizer {
    static let frequencies: [Float] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    static let gainRange: ClosedRange<Float> = -12...12

    struct Preset: Identifiable, Hashable {
        let name: String
        let gains: [Float]
        var id: String { name }
    }

    static let presets: [Preset] = [
        Preset(name: "Flat", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        Preset(name: "Bass Boost", gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        Preset(name: "Bass Cut", gains: [-6, -5, -3, -1, 0, 0, 0, 0, 0, 0]),
        Preset(name: "Treble Boost", gains: [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
        Preset(name: "Treble Cut", gains: [0, 0, 0, 0, 0, -1, -2, -4, -5, -6]),
        Preset(name: "Vocal", gains: [-2, -2, -1, 1, 3, 3, 2, 1, 0, -1]),
        Preset(name: "Loudness", gains: [5, 4, 1, 0, -1, 0, 1, 3, 4, 5]),
        Preset(name: "Dub", gains: [6, 5, 3, 0, -2, -2, 0, 1, 2, 2]),
        Preset(name: "Electronic", gains: [4, 4, 1, 0, -2, 1, 0, 1, 4, 5]),
        Preset(name: "Late Night", gains: [3, 2, 1, 0, 0, 0, -1, -2, -3, -4]),
    ]

    let unit: AVAudioUnitEQ

    var isEnabled: Bool {
        didSet {
            unit.bypass = !isEnabled
            save()
        }
    }

    /// Band gains in dB, one per `frequencies` entry.
    var gains: [Float] {
        didSet {
            applyGains()
            save()
        }
    }

    /// Overall gain in dB, to avoid clipping when boosting.
    var preamp: Float {
        didSet {
            unit.globalGain = preamp
            save()
        }
    }

    var currentPreset: Preset? { Self.presets.first { $0.gains == gains } }

    private enum Keys {
        static let enabled = "eq.enabled"
        static let gains = "eq.gains"
        static let preamp = "eq.preamp"
    }

    init() {
        let defaults = UserDefaults.standard
        unit = AVAudioUnitEQ(numberOfBands: Self.frequencies.count)
        isEnabled = defaults.bool(forKey: Keys.enabled)
        let stored = defaults.array(forKey: Keys.gains) as? [Float]
        gains = stored?.count == Self.frequencies.count ? stored! : Array(repeating: 0, count: Self.frequencies.count)
        preamp = defaults.object(forKey: Keys.preamp) as? Float ?? 0

        for (band, frequency) in zip(unit.bands, Self.frequencies) {
            band.frequency = frequency
            band.bandwidth = 1  // octaves
            band.filterType = frequency == Self.frequencies.first ? .lowShelf
                : frequency == Self.frequencies.last ? .highShelf : .parametric
            band.bypass = false
        }
        unit.bypass = !isEnabled
        unit.globalGain = preamp
        applyGains()
    }

    func apply(_ preset: Preset) {
        gains = preset.gains
        isEnabled = true
    }

    private func applyGains() {
        for (band, gain) in zip(unit.bands, gains) {
            band.gain = gain.clamped(to: Self.gainRange)
        }
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(isEnabled, forKey: Keys.enabled)
        defaults.set(gains, forKey: Keys.gains)
        defaults.set(preamp, forKey: Keys.preamp)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
