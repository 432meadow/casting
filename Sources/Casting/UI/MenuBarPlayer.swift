import SwiftUI

/// A compact player in the menu bar, for controlling playback without the main window.
struct MenuBarPlayer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let player = model.player
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ArtworkView(request: player.currentTrack?.artworkRequest, pixelSize: 160, cornerRadius: 6)
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    if let track = player.currentTrack {
                        Text(track.title.isEmpty ? track.fileName : track.title).font(.headline).lineLimit(2)
                        Text(track.displayArtist).foregroundStyle(.secondary).lineLimit(1)
                        Text(track.album).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text("Not Playing").foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                ProgressView(value: min(player.currentTime, player.duration), total: max(player.duration, 0.1))
                    .progressViewStyle(.linear)
            }

            HStack(spacing: 22) {
                Button { player.setShuffle(!player.shuffle) } label: {
                    Image(systemName: "shuffle").foregroundStyle(player.shuffle ? Palette.warm : .secondary)
                }
                Button { player.previous() } label: { Image(systemName: "backward.fill") }
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title)
                }
                Button { player.next() } label: { Image(systemName: "forward.fill") }
                Button { player.cycleRepeatMode() } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                        .foregroundStyle(player.repeatMode == .off ? .secondary : Palette.warm)
                }
            }
            .buttonStyle(.borderless)
            .font(.title3)
            .disabled(player.currentTrack == nil)

            Divider()
            HStack {
                Button("Show casting") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(14)
        .frame(width: 300)
    }
}
