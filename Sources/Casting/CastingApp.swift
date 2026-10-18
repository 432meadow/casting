import AppKit
import SwiftUI

@main
struct CastingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("casting", id: "main") {
            ContentView()
                .environment(model)
                .tint(Palette.warm)
                .frame(minWidth: 900, minHeight: 500)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Playlist") { model.createPlaylist() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Playlist from Selection") { model.createPlaylist(with: model.selectedTracks) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(model.selectedTrackIDs.isEmpty)
                Button("New Smart Playlist…") { model.smartPlaylistDraft = .new() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                Button("New Playlist Folder") { model.createFolder() }
                Divider()
                Button("Add to Library…") { model.chooseFilesToAdd() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(model.isScanning)
                Divider()
                Button(model.isCheckingForMissingFiles ? "Checking for Missing Files…" : "Check for Missing Files") {
                    model.checkForMissingFiles()
                }
                .disabled(model.isCheckingForMissingFiles)
                Button("Remove Missing Tracks from Library…") { model.confirmRemoveFromLibrary(model.missingTracks) }
                    .disabled(model.missingTrackCount == 0)
            }
            TrackCommands(model: model)
            ControlsCommands(model: model)
        }

        Window("Equalizer", id: "equalizer") {
            EqualizerView()
                .environment(model)
                .tint(Palette.warm)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environment(model)
                .tint(Palette.warm)
        }

        MenuBarExtra("casting", systemImage: model.player.isPlaying ? "music.note" : "music.note.list") {
            MenuBarPlayer()
                .environment(model)
                .tint(Palette.warm)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct TrackCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Track") {
            let selected = model.selectedTracks
            Button("Get Info") { model.showInfo(for: selected) }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(selected.isEmpty)
            Menu("Rating") {
                ForEach(0...5, id: \.self) { stars in
                    Button(stars == 0 ? "None" : String(repeating: "★", count: stars)) {
                        model.setRating(Double(stars), for: selected)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(stars))), modifiers: .command)
                }
            }
            .disabled(selected.isEmpty)
            Button(TrackMenu.detectBPMTitle(for: selected)) { model.detectBPM(for: selected) }
                .disabled(selected.isEmpty)
            if model.bpmAnalyzer.isRunning {
                Button("Stop Detecting BPM") { model.bpmAnalyzer.cancel() }
            }
            Divider()
            Button("Play Next") { model.playNext(selected) }
                .keyboardShortcut(.return, modifiers: .option)
                .disabled(selected.isEmpty)
            Button("Add to Queue") { model.addToQueue(selected) }
                .keyboardShortcut(.return, modifiers: [.option, .shift])
                .disabled(selected.isEmpty)
            Divider()
            Button("Remove from Playlist") { model.removeFromCurrentPlaylist(selected) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(selected.isEmpty || model.editablePlaylistID == nil)
            Button("Remove from Library…") { model.confirmRemoveFromLibrary(selected) }
                .keyboardShortcut(.delete, modifiers: [.command, .option])
                .disabled(selected.isEmpty)
            Button("Locate File…") { if let track = selected.first { model.locate(track) } }
                .disabled(selected.count != 1 || model.unavailableTracks[selected[0].id] == nil)
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(selected.map { URL(fileURLWithPath: $0.path) })
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(selected.isEmpty)
        }
    }
}

private struct ControlsCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Controls") {
            let player = model.player
            Button(player.isPlaying ? "Pause" : "Play") { player.togglePlayPause() }
                .keyboardShortcut("p", modifiers: .command)
            Button("Next") { player.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Previous") { player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button("Stop") { player.stop() }
                .keyboardShortcut(".", modifiers: .command)
            Button("Go to Current Track") { model.goToCurrentTrack() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(player.currentTrack == nil)
            Divider()
            Toggle("Shuffle", isOn: Binding(get: { player.shuffle }, set: { player.setShuffle($0) }))
                .keyboardShortcut("s", modifiers: [.command, .option])
            Picker("Repeat", selection: Binding(get: { player.repeatMode }, set: { player.repeatMode = $0 })) {
                Text("Off").tag(Player.RepeatMode.off)
                Text("All").tag(Player.RepeatMode.all)
                Text("One").tag(Player.RepeatMode.one)
            }
            Button("Cycle Repeat") { player.cycleRepeatMode() }
                .keyboardShortcut("r", modifiers: .command)
            Divider()
            Button("Volume Up") { player.volume = min(1, player.volume + 0.1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Volume Down") { player.volume = max(0, player.volume - 0.1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Divider()
            Button(model.isShowingUpNext ? "Hide Up Next" : "Show Up Next") { model.isShowingUpNext.toggle() }
                .keyboardShortcut("u", modifiers: [.command, .option])
            Button("Equalizer") { openWindow(id: "equalizer") }
                .keyboardShortcut("e", modifiers: [.command, .option])
        }
    }
}

/// Lets the app run as a normal foreground app straight from `swift run`, without a bundle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Keep running with the window closed so the menu bar player keeps working.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
