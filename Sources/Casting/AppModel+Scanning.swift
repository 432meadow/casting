import AppKit

/// Adding music: Add to Library, drag and drop, and watched folders.
extension AppModel {
    var isScanning: Bool {
        if case .running = scanState { return true }
        return false
    }

    /// Opens a panel to pick files or folders to add.
    func chooseFilesToAdd() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose music files or folders to add to the library."
        guard panel.runModal() == .OK else { return }
        addToLibrary(panel.urls)
    }

    func chooseWatchedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Watch"
        panel.message = "New music in this folder will be added automatically."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !watchedFolders.contains(url.path) { watchedFolders.append(url.path) }
        addToLibrary([url])
    }

    func rescanWatchedFolders() {
        let existing = watchedFolders.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return }
        addToLibrary(existing.map { URL(fileURLWithPath: $0) })
    }

    /// Scans files/folders in the background and adds any audio files not already in the library.
    func addToLibrary(_ urls: [URL]) {
        guard !isScanning, let store else { return }
        scanState = .running(done: 0, total: 0)
        scanTask = Task { [weak self] in
            let known = (try? store.allPaths()) ?? []
            let candidates = await Task.detached(priority: .utility) {
                Self.audioFiles(in: urls).filter { !known.contains($0.path) }
            }.value
            self?.scanState = .running(done: 0, total: candidates.count)

            var scanned: [ScannedTrack] = []
            var added = 0
            // Reading tags means opening each file (over the network share, usually), so do a
            // few at a time and save in batches as we go.
            await withTaskGroup(of: ScannedTrack?.self) { group in
                var iterator = candidates.makeIterator()
                for _ in 0..<6 {
                    guard let url = iterator.next() else { break }
                    group.addTask { await TagReader.read(url) }
                }
                var done = 0
                for await result in group {
                    done += 1
                    if let result { scanned.append(result) }
                    if let url = iterator.next(), !Task.isCancelled {
                        group.addTask { await TagReader.read(url) }
                    }
                    if scanned.count >= 200 {
                        added += (try? store.insert(scanned)) ?? 0
                        scanned.removeAll()
                    }
                    if done % 20 == 0 { self?.scanState = .running(done: done, total: candidates.count) }
                }
            }
            added += (try? store.insert(scanned)) ?? 0

            guard let self else { return }
            if added > 0 { try? self.reload() }
            self.scanState = .finished(added: added)
        }
    }

    /// Audio files at or under `urls`, skipping hidden files and packages.
    nonisolated static func audioFiles(in urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue {
                if TagReader.isAudioFile(url) { result.append(url) }
                continue
            }
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let file = enumerator?.nextObject() as? URL {
                if TagReader.isAudioFile(file) { result.append(file) }
            }
        }
        return result
    }

    /// Starts the periodic watched-folder rescans.
    func startWatchingFolders() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescanWatchedFolders() }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))  // let launch settle first
            while !Task.isCancelled {
                self?.rescanWatchedFolders()
                try? await Task.sleep(for: .seconds(30 * 60))
            }
        }
    }
}
