import AppKit

/// This app used to be called casting (bundle ID `io.github.432meadow.casting`). The first time
/// susurrus starts, it takes over what casting left behind, so nothing is lost:
///
/// - `~/Library/Application Support/casting` (the library, fetched covers, Soulseek conversations,
///   beat grids, playback state), `~/Library/Caches/casting` (artwork, artist pages) and
///   `~/Library/Logs/casting` are moved to their `susurrus` names. Moving is a rename on the same
///   disk, so even a large library takes no time. A folder susurrus already has is left alone.
/// - casting's settings are copied into susurrus's (keys susurrus already has win).
/// - The Soulseek password is copied from casting's keychain item (macOS may ask once whether
///   susurrus may read it).
///
/// It runs once, before anything opens those folders, and never in a build pointed at a scratch
/// folder with `SUSURRUS_SUPPORT_DIR`. While casting is still open it does nothing and asks for
/// casting to be quit first: moving a library out from under it would lose its last changes, and
/// susurrus would start an empty library of its own.
enum LegacyMigration {
    static let oldName = "casting"
    static let oldBundleID = "io.github.432meadow.casting"
    static let oldKeychainService = "casting.soulseek"
    static let doneKey = "migratedFromCasting"

    /// Folders under ~/Library that hold the app's files, by the app's name.
    static let libraryFolders = ["Application Support", "Caches", "Logs"]

    /// Migrates the real user account's files, settings and password, once.
    static func runAtLaunch() {
        guard !LibraryStore.isUsingSupportOverride, !UserDefaults.standard.bool(forKey: doneKey) else { return }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: oldBundleID).isEmpty {
            let alert = NSAlert()
            alert.messageText = "Quit casting first"
            alert.informativeText = "susurrus is casting's new name. Quit casting, then open susurrus again: it takes over casting's library, covers, settings and Soulseek password the first time it starts."
            alert.addButton(withTitle: "Quit susurrus")
            alert.runModal()
            exit(0)
        }
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let notes = migrate(library: library, defaults: .standard, oldSettings: oldSettings())
            + migrateKeychain()
        // The event log lives in one of the folders just moved, so it's written only now.
        for note in notes { EventLog.shared.log(note, level: .info) }
    }

    /// Moves the folders and copies the settings. Returns what it did, for the event log.
    @discardableResult
    static func migrate(library: URL, defaults: UserDefaults, oldSettings: [String: Any]) -> [String] {
        var notes: [String] = []
        let fileManager = FileManager.default
        for folder in libraryFolders {
            let parent = library.appendingPathComponent(folder, isDirectory: true)
            let old = parent.appendingPathComponent(oldName, isDirectory: true)
            let new = parent.appendingPathComponent("susurrus", isDirectory: true)
            guard fileManager.fileExists(atPath: old.path) else { continue }
            if fileManager.fileExists(atPath: new.path) {
                notes.append("Migration: left ~/Library/\(folder)/\(oldName) alone, susurrus already has its own")
                continue
            }
            do {
                try fileManager.moveItem(at: old, to: new)
                notes.append("Migration: moved ~/Library/\(folder)/\(oldName) to susurrus")
            } catch {
                notes.append("Migration: couldn't move ~/Library/\(folder)/\(oldName): \(error.localizedDescription)")
            }
        }

        var copied = 0
        for (key, value) in oldSettings where !key.hasPrefix("NS") && !key.hasPrefix("com.apple") && defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            copied += 1
        }
        if copied > 0 { notes.append("Migration: copied \(copied) settings from casting") }
        defaults.set(true, forKey: doneKey)
        return notes
    }

    /// casting's settings, read from its preferences domain.
    static func oldSettings() -> [String: Any] {
        let domain = oldBundleID as CFString
        guard let keys = CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String],
              let values = CFPreferencesCopyMultiple(keys as CFArray, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                as? [String: Any] else { return [:] }
        return values
    }

    private static func migrateKeychain() -> [String] {
        let account = SoulseekModel.keychainAccount
        guard Keychain.string(service: SoulseekModel.keychainService, account: account) == nil,
              let password = Keychain.string(service: oldKeychainService, account: account) else { return [] }
        Keychain.set(password, service: SoulseekModel.keychainService, account: account)
        return ["Migration: copied the Soulseek password from casting"]
    }
}
