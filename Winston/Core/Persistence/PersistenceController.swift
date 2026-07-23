import Foundation
import SwiftData
import OSLog

enum PersistenceController {
    nonisolated static var storeURL: URL {
        AppPaths.appSupportDirectory.appending(path: "Winston.store")
    }

    enum Recovery: Equatable {
        case retryableFailure(StoreOpenFailure)
        case migrationRequired(StoreOpenFailure)
        case quarantined(snapshotURL: URL)
        case readOnlyRecovery(snapshotURL: URL?, failure: StoreOpenFailure)

        var allowsLibraryAccess: Bool {
            if case .quarantined = self { return true }
            return false
        }
    }

    private(set) static var lastRecovery: Recovery?
    private(set) static var restoreAppliedAtLaunch = false

    static let shared: ModelContainer = {
        RenameMigration.runIfNeeded()
        // Recovery must observe the exact filesystem left by the previous process. Recreating
        // missing covers/Books/ManagedFiles directories before journal replay would look like an
        // external mutation after a crash between two restore renames.
        try? AppPaths.ensureDirectory(AppPaths.appSupportDirectory)
        let restoreOutcome = LibraryBackup.restorePendingSnapshotIfNeeded(
            storeURL: storeURL,
            coversDirectory: AppPaths.coversDirectory
        )
        restoreAppliedAtLaunch = restoreOutcome == .committed
        if case .blocked(let message) = restoreOutcome {
            let failure = StoreOpenFailure(
                kind: .retryable,
                domain: "Winston.LibraryRestore",
                code: 1,
                message: message
            )
            Log.persistence.fault(
                "The live store was not opened because restore recovery is unresolved: \(message, privacy: .public)"
            )
            lastRecovery = .retryableFailure(failure)
            return inMemory()
        }
        try? AppPaths.ensureRequiredDirectories()
        let (container, recovery) = makeContainer(storeURL: storeURL)
        lastRecovery = recovery
        return container
    }()

    static func makeContainer(
        storeURL: URL,
        coordinator: StoreRecoveryCoordinator = StoreRecoveryCoordinator(),
        opener: StoreRecoveryCoordinator.StoreOpener? = nil
    ) -> (ModelContainer, Recovery?) {
        try? AppPaths.ensureDirectory(storeURL.deletingLastPathComponent())
        let storeOpener = opener ?? { url in try persistentContainer(at: url) }
        switch coordinator.open(storeURL: storeURL, opener: storeOpener) {
        case .opened(let container):
            return (container, nil)
        case .retryableFailure(let failure):
            Log.persistence.error("Opening the store failed with a retryable error; the original store was left untouched: \(failure.message, privacy: .public)")
            return (inMemory(), .retryableFailure(failure))
        case .migrationRequired(let failure):
            Log.persistence.error("Opening the store requires migration; the original store was left untouched: \(failure.message, privacy: .public)")
            return (inMemory(), .migrationRequired(failure))
        case .quarantined(let container, let snapshotURL):
            return (container, .quarantined(snapshotURL: snapshotURL))
        case .readOnlyRecovery(let snapshotURL, let failure):
            Log.persistence.error("Store recovery stopped without activating an empty persistent library: \(failure.message, privacy: .public)")
            return (inMemory(), .readOnlyRecovery(snapshotURL: snapshotURL, failure: failure))
        }
    }

    private static func persistentContainer(at storeURL: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(url: storeURL)
        return try ModelContainer(
            for: Work.self, Book.self, ReadingSession.self, BookAsset.self, BookCollection.self, Highlight.self, WishlistItem.self,
            LibraryNotice.self, SeriesCatalogSnapshot.self,
            configurations: configuration
        )
    }

    static func inMemory() -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(
                for: Work.self, Book.self, ReadingSession.self, BookAsset.self, BookCollection.self, Highlight.self, WishlistItem.self,
                LibraryNotice.self, SeriesCatalogSnapshot.self,
                configurations: configuration
            )
        } catch {
            fatalError("Failed to create the in-memory model container: \(error)")
        }
    }
}
