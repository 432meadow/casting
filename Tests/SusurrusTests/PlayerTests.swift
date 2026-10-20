import Foundation
import Testing
@testable import Susurrus

/// Plays real (generated) audio through AVAudioEngine at zero volume.
@MainActor
@Suite(.serialized) struct PlayerTests {
    let tracks: [Track]

    init() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        tracks = try (1...4).map { number in
            let url = folder.appendingPathComponent("\(number).wav")
            try ToneFile.write(to: url, seconds: 1.0, frequency: 220 * Double(number))
            let track = Track(id: Int64(number))
            track.title = "Tone \(number)"
            track.path = url.path
            track.length = 1.0
            return track
        }
    }

    private func makePlayer() -> Player {
        let player = Player()
        player.volume = 0
        player.repeatMode = .off
        player.setShuffle(false)
        return player
    }

    /// Waits until `condition` holds, polling the main actor.
    private func waitUntil(timeout: Double = 8, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    @Test func playsThroughQueueGaplesslyAndCountsPlays() async {
        let player = makePlayer()
        var played: [Int64] = []
        player.onTrackPlayed = { played.append($0.id) }
        let start = Date()
        player.play(Array(tracks.prefix(3)), startingAt: 0)

        #expect(await waitUntil { player.currentTrack?.id == 2 })
        #expect(await waitUntil { player.currentTrack?.id == 3 })
        #expect(await waitUntil { player.currentTrack == nil }, "stops at the end of the queue")
        let elapsed = Date().timeIntervalSince(start)
        // Three 1-second files back to back. A non-gapless restart per track would add load time.
        #expect(elapsed < 3.8, "took \(elapsed)s for 3s of audio")
        #expect(played == [1, 2, 3])
        player.stop()
    }

    @Test func playNextAndAddToQueueOrder() async {
        let player = makePlayer()
        player.play([tracks[0], tracks[1]], startingAt: 0)
        #expect(await waitUntil { player.isPlaying })
        player.addToQueue([tracks[3]])
        player.playNext([tracks[2]])
        // Play Next goes first, then queued tracks, then the rest of the original list.
        #expect(player.upNext.map(\.id) == [3, 4, 2])
        #expect(player.queuedAheadCount == 2)

        player.next()
        #expect(await waitUntil { player.currentTrack?.id == 3 })
        #expect(player.queuedAheadCount == 1)
        player.removeFromUpNext(at: [0])
        #expect(player.upNext.map(\.id) == [2])
        player.stop()
    }

    @Test func shuffleKeepsCurrentTrackFirstAndRestoresOrder() async {
        let player = makePlayer()
        player.play(tracks, startingAt: 2)
        #expect(await waitUntil { player.isPlaying })
        player.setShuffle(true)
        #expect(player.currentTrack?.id == 3)
        #expect(Set(player.upNext.map(\.id)) == [1, 2, 4])
        player.setShuffle(false)
        #expect(player.currentTrack?.id == 3)
        #expect(player.upNext.map(\.id) == [4])
        player.stop()
    }

    @Test func repeatOneReplaysAndNextStillAdvances() async {
        let player = makePlayer()
        var played: [Int64] = []
        player.onTrackPlayed = { played.append($0.id) }
        player.repeatMode = .one
        player.play([tracks[0], tracks[1]], startingAt: 0)
        #expect(await waitUntil { played.count >= 2 })
        #expect(played.prefix(2) == [1, 1])
        #expect(player.currentTrack?.id == 1)
        player.next()
        #expect(await waitUntil { player.currentTrack?.id == 2 })
        player.repeatMode = .off
        player.stop()
    }

    @Test func seekWhilePausedStaysPaused() async {
        let player = makePlayer()
        player.play([tracks[0]], startingAt: 0)
        #expect(await waitUntil { player.isPlaying })
        player.togglePlayPause()
        player.seek(to: 0.5)
        #expect(!player.isPlaying)
        #expect(abs(player.currentTime - 0.5) < 0.05)
        player.stop()
    }

    @Test func missingFilesAreSkippedThenPlaybackGivesUp() async {
        let player = makePlayer()
        let missing = (10...14).map { number -> Track in
            let track = Track(id: Int64(number))
            track.path = "/nonexistent/\(number).mp3"
            return track
        }
        player.play(missing, startingAt: 0)
        #expect(await waitUntil { player.currentTrack == nil }, "stops after a few failures instead of walking the whole queue")
        #expect(player.errorMessage != nil)
    }
}
