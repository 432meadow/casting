import Foundation
import Testing
@testable import Susurrus

/// Taking over casting's folders and settings, in a temp folder standing in for ~/Library.
@Suite struct LegacyMigrationTests {
    @Test func movesCastingsFoldersAndCopiesItsSettings() throws {
        let library = FileManager.default.temporaryDirectory.appendingPathComponent("LegacyMigrationTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: library) }
        let fileManager = FileManager.default
        func folder(_ parts: String...) -> URL { parts.reduce(library) { $0.appendingPathComponent($1) } }

        try fileManager.createDirectory(at: folder("Application Support", "casting", "Covers"), withIntermediateDirectories: true)
        try Data("db".utf8).write(to: folder("Application Support", "casting", "Library.sqlite"))
        try fileManager.createDirectory(at: folder("Caches", "casting", "Artwork"), withIntermediateDirectories: true)
        // susurrus already has logs of its own: casting's are left where they are.
        try fileManager.createDirectory(at: folder("Logs", "casting"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: folder("Logs", "susurrus"), withIntermediateDirectories: true)

        let suite = "LegacyMigrationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/new/choice", forKey: "soulseek.downloadFolder")

        let notes = LegacyMigration.migrate(library: library, defaults: defaults, oldSettings: [
            "soulseek.username": "someone",
            "library.watchedFolders": ["/Volumes/music"],
            "soulseek.downloadFolder": "/old/choice",
            "NSWindow Frame main": "0 0 100 100",
        ])

        #expect(try Data(contentsOf: folder("Application Support", "susurrus", "Library.sqlite")) == Data("db".utf8))
        #expect(fileManager.fileExists(atPath: folder("Application Support", "susurrus", "Covers").path))
        #expect(!fileManager.fileExists(atPath: folder("Application Support", "casting").path))
        #expect(fileManager.fileExists(atPath: folder("Caches", "susurrus", "Artwork").path))
        #expect(fileManager.fileExists(atPath: folder("Logs", "casting").path), "not merged into an existing folder")

        #expect(defaults.string(forKey: "soulseek.username") == "someone")
        #expect(defaults.stringArray(forKey: "library.watchedFolders") == ["/Volumes/music"])
        #expect(defaults.string(forKey: "soulseek.downloadFolder") == "/new/choice", "susurrus's own settings win")
        #expect(defaults.object(forKey: "NSWindow Frame main") == nil)
        #expect(defaults.bool(forKey: LegacyMigration.doneKey))
        #expect(notes.contains { $0.contains("copied 2 settings") })
    }
}
