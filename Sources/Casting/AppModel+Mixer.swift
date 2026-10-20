import Foundation

/// The two-deck mixer: loading decks, and handing playback between it and the queue player.
extension AppModel {
    func connectMixer() {
        mixer.locate = player.locate
        mixer.setOutputDevice(player.outputDeviceUID)
        mixer.onTrackPlayed = { [weak self] track in self?.recordPlay(track) }
        mixer.onListenEnded = { [weak self] track, listen in self?.recordListen(listen, of: track) }
        mixer.onUnplayable = { [weak self] track in self?.noteUnplayable(track) }
        mixer.onAnalyzed = { [weak self] track, analysis in self?.fillIn(track, from: analysis) }
        // One or the other: the mixer and the queue player never play over each other.
        mixer.onStartedPlaying = { [weak self] in self?.player.pause() }
        player.onStartedPlaying = { [weak self] in self?.mixer.pauseAll() }
        player.onOutputDeviceChanged = { [weak self] uid in self?.mixer.setOutputDevice(uid) }
    }

    func load(_ track: Track, on side: Mixer.Side) {
        isShowingMixer = true
        mixer.load(track, on: side)
    }

    func loadTrack(id: Int64, on side: Mixer.Side) {
        guard let track = tracksByID[id] else { return }
        load(track, on: side)
    }

    /// Moves the playing track onto a free deck at the same position, so a mix can start from
    /// whatever's on. The queue player keeps going until the deck is ready, then hands over.
    func continueInMixer() {
        guard let track = player.currentTrack else { return }
        isShowingMixer = true
        let side = Mixer.Side.allCases.first { !mixer.deck($0).isPlaying } ?? .a
        mixer.moveCrossfader(to: side == .a ? 0 : 1)
        mixer.load(track, on: side, at: player.currentTime) { [weak self] deck in
            guard let self, self.player.currentTrack?.id == track.id else { return }
            deck.seek(to: self.player.currentTime)
            if self.player.isPlaying { deck.play() }  // pauses the queue player
        }
    }
}
