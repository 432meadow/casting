import Foundation
import Testing
@testable import Casting

/// Plays real (generated) audio through the mixer's engine at zero volume.
@MainActor
@Suite(.serialized) struct MixerTests {
    let tracks: [Track]

    init() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        tracks = try (1...2).map { number in
            let url = folder.appendingPathComponent("\(number).wav")
            try ToneFile.write(to: url, seconds: 1.0, frequency: 220 * Double(number))
            let track = Track(id: Int64(number))
            track.title = "Tone \(number)"
            track.path = url.path
            track.length = 1.0
            return track
        }
    }

    private func makeMixer() -> Mixer {
        let mixer = Mixer()
        mixer.masterVolume = 0
        return mixer
    }

    private func waitUntil(timeout: Double = 8, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    @Test func crossfaderKeepsPowerConstant() {
        #expect(Mixer.crossfadeGains(0) == (1, 0))
        let end = Mixer.crossfadeGains(1)
        #expect(abs(end.a) < 0.0001 && end.b == 1)
        for position in stride(from: 0.0, through: 1.0, by: 0.1) {
            let (a, b) = Mixer.crossfadeGains(position)
            #expect(abs(a * a + b * b - 1) < 0.0001)
        }
        let middle = Mixer.crossfadeGains(0.5)
        #expect(abs(middle.a - middle.b) < 0.0001)
    }

    @Test func eqKnobRunsFromBoostToKill() {
        #expect(Deck.eqGain(0) == 0)
        #expect(Deck.eqGain(1) == 6)
        #expect(Deck.eqGain(-1) == -40)
        #expect(Deck.eqGain(-0.5) > -15, "gentle near the middle")
    }

    @Test func deckPlaysToTheEndAndStops() async {
        let mixer = makeMixer()
        var started = 0
        mixer.onStartedPlaying = { started += 1 }
        var ready = false
        mixer.load(tracks[0], on: .a) { _ in ready = true }
        #expect(await waitUntil { ready })
        #expect(mixer.a.track?.id == 1)
        #expect(abs(mixer.a.duration - 1) < 0.01)

        mixer.a.play()
        #expect(mixer.a.isPlaying)
        #expect(started == 1, "tells the queue player to pause")
        #expect(await waitUntil { mixer.a.currentTime > 0.2 })
        #expect(await waitUntil { !mixer.a.isPlaying }, "stops at the end")
        #expect(abs(mixer.a.currentTime - 1) < 0.01)
        #expect(!mixer.b.isPlaying)
    }

    @Test func cueSetsAndReturns() async {
        let mixer = makeMixer()
        var ready = false
        mixer.load(tracks[0], on: .a) { _ in ready = true }
        #expect(await waitUntil { ready })
        let deck = mixer.a

        deck.seek(to: 0.4)
        deck.cue()  // paused: the cue point moves here
        #expect(abs(deck.cuePoint - 0.4) < 0.001)
        deck.play()
        #expect(await waitUntil { deck.currentTime > 0.6 })
        deck.cue()  // playing: back to the cue point, paused
        #expect(!deck.isPlaying)
        #expect(abs(deck.currentTime - 0.4) < 0.001)
        deck.eject()
        #expect(deck.track == nil && !deck.isReady)
    }

    @Test func matchTempoFindsTheNearestMultiple() async {
        let mixer = makeMixer()
        tracks[0].bpm = 126
        tracks[1].bpm = 120
        var loaded = 0
        mixer.load(tracks[0], on: .a) { _ in loaded += 1 }
        mixer.load(tracks[1], on: .b) { _ in loaded += 1 }
        #expect(await waitUntil { loaded == 2 })

        mixer.b.matchTempo(to: mixer.a)
        #expect(abs(mixer.b.tempo - 0.05) < 0.0001)
        #expect(abs((mixer.b.effectiveBPM ?? 0) - 126) < 0.001)

        // Half-time: 64 BPM matches 126 by playing at 63.
        tracks[1].bpm = 64
        mixer.b.tempo = 0
        mixer.b.matchTempo(to: mixer.a)
        #expect(abs(mixer.b.tempo - (63.0 / 64 - 1)) < 0.0001)

        // Out of the ±8% range: no match.
        tracks[1].bpm = 100
        #expect(mixer.b.tempoMatching(mixer.a) == nil)
    }

    @Test func autoFadeGlidesAcrossAndStartsTheIncomingDeck() async {
        let mixer = makeMixer()
        mixer.autoFadeSeconds = 0.3
        var ready = false
        mixer.load(tracks[1], on: .b) { _ in ready = true }
        #expect(await waitUntil { ready })
        mixer.moveCrossfader(to: 0)

        mixer.autoFade()
        #expect(mixer.b.isPlaying, "the incoming deck starts")
        #expect(await waitUntil { !mixer.isAutoFading })
        #expect(mixer.crossfader == 1)
        mixer.pauseAll()
        mixer.autoFadeSeconds = 8
    }
}
