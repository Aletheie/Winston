import Foundation

enum AppPaths {
    // var only as a test seam — the app never mutates it; TestLibrary swaps it under a serialized lease.
    nonisolated(unsafe) static var rootDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Winston", directoryHint: .isDirectory)
    }()

    nonisolated static var appSupportDirectory: URL { rootDirectory }

    nonisolated static var booksDirectory: URL {
        appSupportDirectory.appending(path: "Books", directoryHint: .isDirectory)
    }

    nonisolated static var coversDirectory: URL {
        appSupportDirectory.appending(path: "covers", directoryHint: .isDirectory)
    }

    nonisolated static var managedFilesDirectory: URL {
        appSupportDirectory.appending(path: "ManagedFiles", directoryHint: .isDirectory)
    }

    nonisolated static var managedFileStagingDirectory: URL {
        managedFilesDirectory.appending(path: "Staging", directoryHint: .isDirectory)
    }

    nonisolated static var managedFileJournalDirectory: URL {
        managedFilesDirectory.appending(path: "Journal", directoryHint: .isDirectory)
    }

    nonisolated static var calibreImportSessionsDirectory: URL {
        managedFilesDirectory.appending(path: "CalibreImportSessions", directoryHint: .isDirectory)
    }

    nonisolated static var pluginsDirectory: URL {
        appSupportDirectory.appending(path: "Plugins", directoryHint: .isDirectory)
    }

    nonisolated static var fullTextIndexDirectory: URL {
        appSupportDirectory.appending(path: "FullTextIndex", directoryHint: .isDirectory)
    }

    nonisolated static func pluginDataDirectory(for pluginID: String) -> URL {
        pluginDataRootDirectory.appending(path: pluginID, directoryHint: .isDirectory)
    }

    private nonisolated static var pluginDataRootDirectory: URL {
        appSupportDirectory.appending(path: "PluginData", directoryHint: .isDirectory)
    }

    nonisolated static func ensureRequiredDirectories() throws {
        for directory in [appSupportDirectory, booksDirectory, coversDirectory,
                          managedFilesDirectory, managedFileStagingDirectory,
                          managedFileJournalDirectory, calibreImportSessionsDirectory, pluginsDirectory,
                          pluginDataRootDirectory, fullTextIndexDirectory] {
            try ensureDirectory(directory)
        }
    }

    nonisolated static func ensureDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    nonisolated static func ensurePluginDataDirectory(for pluginID: String) throws {
        try ensureDirectory(pluginDataDirectory(for: pluginID))
    }
}
