import AVKit
import SwiftUI

struct NowPlayingBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    /// Position while the user drags the slider; seeking happens on release.
    @State private var scrubPosition: Double?

    var body: some View {
        @Bindable var player = model.player
        @Bindable var model = model
        HStack(spacing: 14) {
            HStack(spacing: 14) {
                Button { player.previous() } label: { Image(systemName: "backward.fill") }
                    .help("Previous")
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                }
                .help(player.isPlaying ? "Pause" : "Play")
                Button { player.next() } label: { Image(systemName: "forward.fill") }
                    .help("Next")
            }
            .buttonStyle(.borderless)
            .disabled(player.currentTrack == nil)

            ArtworkView(request: player.currentTrack?.artworkRequest, pixelSize: 96)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                if let track = player.currentTrack {
                    HStack(spacing: 6) {
                        Text(track.title.isEmpty ? track.fileName : track.title).font(.headline).lineLimit(1)
                            .onTapGesture { model.goToCurrentTrack() }
                            .help("Go to Current Track (⌘L)")
                        if player.isLoading {
                            ProgressView().controlSize(.mini)
                        }
                    }
                    if player.isWaitingForShare {
                        Text("Waiting for the network share…")
                            .font(.subheadline).foregroundStyle(Palette.ochre).lineLimit(1)
                    } else {
                        Text([track.displayArtist, track.album].filter { !$0.isEmpty }.joined(separator: " — "))
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            .onTapGesture { if !track.displayArtist.isEmpty { model.showArtist(track.displayArtist) } }
                            .help("Go to Artist")
                    }
                } else if let error = player.errorMessage {
                    Text(error).font(.subheadline).foregroundStyle(.red).lineLimit(2)
                } else {
                    Text("Not Playing").foregroundStyle(.secondary)
                }
            }
            .frame(width: 230, alignment: .leading)
            .contextMenu {
                if let track = player.currentTrack {
                    Button("Go to Current Track") { model.goToCurrentTrack() }
                    if !track.displayArtist.isEmpty {
                        Button("Go to Artist") { model.showArtist(track.displayArtist) }
                    }
                    Button("Get Info") { model.showInfo(for: [track]) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: track.path)]) }
                }
            }

            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                let duration = max(player.duration, 0.1)
                let position = scrubPosition ?? player.currentTime
                HStack(spacing: 8) {
                    Text(Format.time(position)).monospacedDigit().foregroundStyle(.secondary)
                    Slider(
                        value: Binding(get: { position }, set: { scrubPosition = $0 }),
                        in: 0...duration
                    ) { editing in
                        if !editing, let target = scrubPosition {
                            player.seek(to: target)
                            scrubPosition = nil
                        }
                    }
                    Text("-" + Format.time(duration - position)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            .disabled(player.currentTrack == nil)

            HStack(spacing: 12) {
                Button { player.setShuffle(!player.shuffle) } label: {
                    Image(systemName: "shuffle").foregroundStyle(player.shuffle ? Palette.warm : .secondary)
                }
                .help(player.shuffle ? "Shuffle is on" : "Shuffle is off")
                Button { player.cycleRepeatMode() } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                        .foregroundStyle(player.repeatMode == .off ? .secondary : Palette.warm)
                }
                .help("Repeat: \(player.repeatMode.rawValue)")
                Button { model.isShowingUpNext.toggle() } label: {
                    Image(systemName: "list.bullet").foregroundStyle(model.isShowingUpNext ? Palette.warm : .secondary)
                }
                .help("Up Next")
                Button { openWindow(id: "equalizer") } label: {
                    Image(systemName: "slider.vertical.3")
                        .foregroundStyle(player.equalizer.isEnabled ? Palette.warm : .secondary)
                }
                .help("Equalizer")
                OutputMenu()
                AirPlayButton()
                    .frame(width: 22, height: 22)
                    .help("AirPlay")
            }
            .buttonStyle(.borderless)

            HStack(spacing: 6) {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: $player.volume, in: 0...1).frame(width: 80)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Picks which audio device the app plays through, independently of the system output.
private struct OutputMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        Menu {
            Button {
                player.setOutputDevice(nil)
            } label: {
                Label("System Output", systemImage: player.outputDeviceUID == nil ? "checkmark" : "")
            }
            Divider()
            ForEach(player.outputs.devices) { device in
                Button {
                    player.setOutputDevice(device.uid)
                } label: {
                    Label(device.name, systemImage: player.outputDeviceUID == device.uid ? "checkmark" : "")
                }
            }
        } label: {
            Image(systemName: "hifispeaker")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Output device")
        .onAppear { player.outputs.refresh() }
    }
}

/// The system AirPlay route picker.
private struct AirPlayButton: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        return picker
    }

    func updateNSView(_ picker: AVRoutePickerView, context: Context) {}
}
