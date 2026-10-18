import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            LibrarySettings()
                .tabItem { Label("Library", systemImage: "music.note.house") }
            PlaybackSettings()
                .tabItem { Label("Playback", systemImage: "play.circle") }
            SoulseekSettings()
                .tabItem { Label("Soulseek", systemImage: "point.3.connected.trianglepath.dotted") }
        }
        .frame(width: 520)
        .padding(20)
    }
}

private struct LibrarySettings: View {
    @Environment(AppModel.self) private var model
    @State private var selectedFolder: String?
    @State private var isConfirmingTagWriting = false

    var body: some View {
        Form {
            Section("Watched Folders") {
                Text("New music in these folders is added automatically at launch, when the share mounts, and every 30 minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                List(model.watchedFolders, id: \.self, selection: $selectedFolder) { path in
                    Label(path, systemImage: FileManager.default.fileExists(atPath: path) ? "folder" : "folder.badge.questionmark")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(minHeight: 100)
                HStack {
                    Button("Add Folder…") { model.chooseWatchedFolder() }
                    Button("Remove") {
                        model.watchedFolders.removeAll { $0 == selectedFolder }
                        selectedFolder = nil
                    }
                    .disabled(selectedFolder == nil)
                    Spacer()
                    Button("Scan Now") { model.rescanWatchedFolders() }
                        .disabled(model.watchedFolders.isEmpty || model.isScanning)
                }
                scanStatus
            }
            Section("Files") {
                Toggle("Write tags to files", isOn: Binding(
                    get: { model.writesTagsToFiles },
                    set: { on in
                        if on, !model.hasConfirmedTagWriting {
                            isConfirmingTagWriting = true
                        } else {
                            model.writesTagsToFiles = on
                        }
                    }))
                Text("Get Info edits and ratings are also written into MP3 (ID3), FLAC and M4A files, in the background. Each file is rewritten as a verified copy that then replaces the original; files changed by another app meanwhile are skipped. Ratings go into MP3 and FLAC files only. Play counts stay in casting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TagWriteStatus(queue: model.tagWriter)
            }
        }
        .formStyle(.grouped)
        .alert("Write tags into your music files?", isPresented: $isConfirmingTagWriting) {
            Button("Write Tags to Files") {
                model.hasConfirmedTagWriting = true
                model.writesTagsToFiles = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("From now on, tag edits and ratings change the audio files themselves, not just casting's library, and other apps will see the changes. casting checks every rewritten file before it replaces the original, but make sure you have a backup of your music first.")
        }
    }

    @ViewBuilder private var scanStatus: some View {
        switch model.scanState {
        case .idle:
            EmptyView()
        case .running(let done, let total):
            ProgressView(value: Double(done), total: Double(max(total, 1))) {
                Text(total == 0 ? "Looking for new files…" : "Reading \(done.formatted()) of \(total.formatted()) new files…")
                    .font(.caption)
            }
        case .finished(let added):
            Text(added == 0 ? "No new files found." : "Added \(added.formatted()) tracks.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SoulseekSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var soulseek = model.soulseek
        Form {
            Section("Account") {
                TextField("Username", text: $soulseek.username)
                    .autocorrectionDisabled()
                SecureField("Password", text: $soulseek.password)
                Text("The password is kept in your keychain. A username nobody has used before is registered on the Soulseek network the first time it connects — pick a throwaway password either way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Connection") {
                LabeledContent("Status") {
                    Text(soulseek.statusText)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Connect") { soulseek.connect() }
                        .disabled(!soulseek.hasCredentials || soulseek.state == .connecting)
                    Button("Disconnect") { soulseek.disconnect() }
                        .disabled(soulseek.state == .disconnected)
                }
                Toggle("Connect when casting starts", isOn: $soulseek.connectsAtLaunch)
                Text("Searching connects automatically. Staying connected keeps your share available and lets saved searches (the wishlist) run in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Sharing") {
                LabeledContent("Shared Folder") {
                    HStack {
                        Text(soulseek.sharedFolderPath.isEmpty ? "None" : soulseek.sharedFolderPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { soulseek.chooseSharedFolder() }
                        if !soulseek.sharedFolderPath.isEmpty {
                            Button("Stop Sharing") { soulseek.stopSharing() }
                        }
                    }
                }
                HStack {
                    if soulseek.shareState == .scanning { ProgressView().controlSize(.small) }
                    Text(soulseek.shareStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Rescan") { soulseek.rescanShares() }
                        .controlSize(.small)
                        .disabled(soulseek.sharedFolderPath.isEmpty || soulseek.shareState == .scanning)
                }
                Text("Other users can search this folder and download from it. Sharing back is what keeps Soulseek alive — many users only upload to people who share.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Limit upload speed", isOn: $soulseek.limitsUploadSpeed)
                if soulseek.limitsUploadSpeed {
                    LabeledContent("Upload Limit") {
                        HStack(spacing: 4) {
                            TextField("KB/s", value: $soulseek.uploadLimitKBps, format: .number)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                            Text("KB/s, for all uploads together")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Blocked Users") {
                if soulseek.blockedUsers.isEmpty {
                    Text("Nobody. Right-click a search result or an upload ▸ Block to add someone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(soulseek.blockedUsers, id: \.self) { user in
                        HStack {
                            Text(user)
                            Spacer()
                            Button("Unblock") { soulseek.unblock(user) }
                                .controlSize(.small)
                        }
                    }
                    Text("Blocked users' search results are hidden, and they can't search, browse or download your share.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Downloads") {
                LabeledContent("Download Folder") {
                    HStack {
                        Text(soulseek.downloadFolderPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { chooseDownloadFolder() }
                    }
                }
                Text("Finished downloads keep their remote folder name (so albums stay together) and are added to the library automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Notify when a download folder finishes or a saved search finds something new", isOn: $soulseek.postsNotifications)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Use"
        panel.message = "Soulseek downloads will be saved in this folder."
        panel.directoryURL = URL(fileURLWithPath: model.soulseek.downloadFolderPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.soulseek.downloadFolderPath = url.path
    }
}

/// Progress and problems for the background tag writes.
private struct TagWriteStatus: View {
    let queue: TagWriteQueue

    var body: some View {
        if queue.isRunning {
            ProgressView(value: Double(queue.done), total: Double(max(queue.total, 1))) {
                Text(label).font(.caption).lineLimit(1).truncationMode(.middle)
            }
        } else if queue.total > 0 {
            Text("Wrote tags to \(queue.written.formatted()) of \(queue.total.formatted()) files.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if !queue.failures.isEmpty {
            DisclosureGroup("\(queue.failures.count) files couldn't be written") {
                ForEach(queue.failures) { failure in
                    VStack(alignment: .leading, spacing: 2) {
                        Text((failure.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Text(failure.message).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .help(failure.path)
                }
                Button("Clear") { queue.clearFailures() }
            }
            .font(.caption)
        }
    }

    private var label: String {
        if let path = queue.waitingForPath {
            return "Waiting for “\((path as NSString).lastPathComponent)” to stop playing…"
        }
        let name = queue.currentPath.map { " — " + ($0 as NSString).lastPathComponent } ?? ""
        return "Writing tags: \(queue.done.formatted()) of \(queue.total.formatted()) files\(name)"
    }
}

private struct PlaybackSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var player = model.player
        Form {
            Picker("Repeat", selection: $player.repeatMode) {
                Text("Off").tag(Player.RepeatMode.off)
                Text("All").tag(Player.RepeatMode.all)
                Text("One").tag(Player.RepeatMode.one)
            }
            Toggle("Shuffle", isOn: Binding(get: { player.shuffle }, set: { player.setShuffle($0) }))
            Picker("Output", selection: Binding(get: { player.outputDeviceUID }, set: { player.setOutputDevice($0) })) {
                Text("System Output").tag(String?.none)
                ForEach(player.outputs.devices) { device in
                    Text(device.name).tag(String?.some(device.uid))
                }
            }
            LabeledContent("Equalizer") {
                Button("Show Equalizer…") { openWindow(id: "equalizer") }
            }
            Text("Tracks on network volumes are copied to a small local cache before playing, so network hiccups can't interrupt playback. The next track is fetched while the current one plays, for gapless transitions.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
