import Foundation
import SwiftData
import OSLog

enum PersistenceController {
    nonisolated static var storeURL: URL {
        AppPaths.appSupportDirectory.appending(path: "Winston.store")
    }

    enum Recovery: Equatable {
        case recreatedAfterCorruption(backupPath: String?)
    }

    private(set) static var lastRecovery: Recovery?

    static let shared: ModelContainer = {
        RenameMigration.runIfNeeded()
        try? AppPaths.ensureRequiredDirectories()
        LibraryBackup.applyPendingRestoreIfNeeded(storeURL: storeURL,
                                                  coversDirectory: AppPaths.coversDirectory)
        let (container, recovery) = makeContainer(storeURL: storeURL)
        lastRecovery = recovery
        return container
    }()

    static func makeContainer(storeURL: URL) -> (ModelContainer, Recovery?) {
        try? AppPaths.ensureDirectory(storeURL.deletingLastPathComponent())
        let configuration = ModelConfiguration(url: storeURL)
        do {
            let container = try ModelContainer(
                for: Book.self, BookCollection.self, Highlight.self, WishlistItem.self,
                configurations: configuration
            )
            return (container, nil)
        } catch {
            Log.persistence.error("Opening the store at \(storeURL.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public) — moving it aside and starting fresh")
            let backupPath = moveBrokenStoreAside(storeURL: storeURL)
            do {
                let container = try ModelContainer(
                    for: Book.self, BookCollection.self, Highlight.self, WishlistItem.self,
                    configurations: configuration
                )
                return (container, .recreatedAfterCorruption(backupPath: backupPath))
            } catch {
                fatalError("Failed to create a fresh model container after store recovery: \(error)")
            }
        }
    }

    // Move (not delete) so a corrupt store stays recoverable instead of crash-looping the launch.
    private static func moveBrokenStoreAside(storeURL: URL) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = ".broken-\(formatter.string(from: .now))"

        let fileManager = FileManager.default
        let base = storeURL.path(percentEncoded: false)
        var movedTo: String?
        for sidecar in ["", "-wal", "-shm"] {
            let source = URL(filePath: base + sidecar)
            guard fileManager.fileExists(atPath: base + sidecar) else { continue }
            let destination = URL(filePath: base + suffix + sidecar)
            do {
                try fileManager.moveItem(at: source, to: destination)
                if sidecar.isEmpty { movedTo = base + suffix }
            } catch {
                try? fileManager.removeItem(at: source)
            }
        }
        return movedTo
    }

    static func inMemory() -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(
                for: Book.self, BookCollection.self, Highlight.self, WishlistItem.self,
                configurations: configuration
            )
        } catch {
            fatalError("Failed to create the in-memory model container: \(error)")
        }
    }
}
