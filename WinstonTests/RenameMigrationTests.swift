import Testing
import Foundation
@testable import Winston

struct RenameMigrationTests {

    private func tempDirectory(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func movesLegacyFolderAndRenamesStore() throws {
        let fm = FileManager.default
        let base = tempDirectory("RenameMigration")
        let oldRoot = base.appending(path: "Kalibre", directoryHint: .isDirectory)
        let newRoot = base.appending(path: "Winston", directoryHint: .isDirectory)
        try fm.createDirectory(at: oldRoot.appending(path: "Books"), withIntermediateDirectories: true)
        try Data("store".utf8).write(to: oldRoot.appending(path: "Kalibre.store"))
        try Data("wal".utf8).write(to: oldRoot.appending(path: "Kalibre.store-wal"))
        try Data("book".utf8).write(to: oldRoot.appending(path: "Books/a.epub"))
        defer { try? fm.removeItem(at: base) }

        RenameMigration.migrateDataFolder(from: oldRoot, to: newRoot, newStoreName: "Winston.store")

        #expect(!fm.fileExists(atPath: oldRoot.path(percentEncoded: false)))
        #expect(try Data(contentsOf: newRoot.appending(path: "Winston.store")) == Data("store".utf8))
        #expect(try Data(contentsOf: newRoot.appending(path: "Winston.store-wal")) == Data("wal".utf8))
        #expect(try Data(contentsOf: newRoot.appending(path: "Books/a.epub")) == Data("book".utf8))
    }

    @Test func existingNewRootIsNeverTouched() throws {
        let fm = FileManager.default
        let base = tempDirectory("RenameMigrationKeep")
        let oldRoot = base.appending(path: "Kalibre", directoryHint: .isDirectory)
        let newRoot = base.appending(path: "Winston", directoryHint: .isDirectory)
        try fm.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: newRoot, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: oldRoot.appending(path: "Kalibre.store"))
        try Data("new".utf8).write(to: newRoot.appending(path: "Winston.store"))
        defer { try? fm.removeItem(at: base) }

        RenameMigration.migrateDataFolder(from: oldRoot, to: newRoot, newStoreName: "Winston.store")

        #expect(try Data(contentsOf: newRoot.appending(path: "Winston.store")) == Data("new".utf8))
        #expect(fm.fileExists(atPath: oldRoot.appending(path: "Kalibre.store").path(percentEncoded: false)))
    }

    @Test func finishesStoreRenameWhenFolderWasAlreadyMoved() throws {
        let fm = FileManager.default
        let base = tempDirectory("RenameMigrationStore")
        let oldRoot = base.appending(path: "Kalibre", directoryHint: .isDirectory)
        let newRoot = base.appending(path: "Winston", directoryHint: .isDirectory)
        try fm.createDirectory(at: newRoot, withIntermediateDirectories: true)
        try Data("store".utf8).write(to: newRoot.appending(path: "Kalibre.store"))
        defer { try? fm.removeItem(at: base) }

        RenameMigration.migrateDataFolder(from: oldRoot, to: newRoot, newStoreName: "Winston.store")

        #expect(try Data(contentsOf: newRoot.appending(path: "Winston.store")) == Data("store".utf8))
        #expect(!fm.fileExists(atPath: newRoot.appending(path: "Kalibre.store").path(percentEncoded: false)))
    }

    @Test func copiesLegacyDefaultsOnceWithoutOverwriting() throws {
        let suiteName = "cz.annajung.WinstonRenameMigrationTests-\(UUID().uuidString)"
        let oldDomain = "\(suiteName).legacy"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            defaults.removePersistentDomain(forName: oldDomain)
        }

        defaults.setPersistentDomain(
            ["theme": "black", "AppleLanguages": ["cs"], "kept": "winston-value"],
            forName: oldDomain
        )
        defaults.set("winston-value-newer", forKey: "kept")

        RenameMigration.migrateDefaults(from: oldDomain, into: defaults, appDomain: suiteName)

        #expect(defaults.string(forKey: "theme") == "black")
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["cs"])
        #expect(defaults.string(forKey: "kept") == "winston-value-newer")

        defaults.setPersistentDomain(["theme": "purple"], forName: oldDomain)
        RenameMigration.migrateDefaults(from: oldDomain, into: defaults, appDomain: suiteName)
        #expect(defaults.string(forKey: "theme") == "black")
    }
}
