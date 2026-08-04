import Foundation
import SwiftData
import Testing
@testable import Winston

@Suite("Library integrity and import recovery", .serialized)
@MainActor
struct LibraryIntegrityTests {
    private enum InjectedFailure: Error {
        case save
    }

    @Test
    func integrityReportFindsCatalogAndManagedFileDrift() async throws {
        let library = try await TestLibrary()
        let book = Book(
            fileName: "missing.epub",
            originalFileName: "Integrity Book.epub"
        )
        let asset = BookAsset(
            uuid: book.uuid,
            fileName: book.fileName,
            book: book
        )
        asset.formatRaw = "PDF"
        asset.sourceProvenanceRaw = nil
        book.primaryAssetUUID = nil
        library.context.insert(book)
        library.context.insert(asset)
        try library.context.save()

        let health = LibraryHealthService(modelContext: library.context)
        let report = try await health.integrityReport()

        #expect(report.bookCount == 1)
        #expect(report.assetCount == 1)
        #expect(report.catalogIssueCount >= 3)
        #expect(report.fileIssueCount == 1)
        #expect(report.repairableBookIDs == [book.uuid])
        #expect(
            report.issues.contains {
                $0.bookID == book.uuid
                    && $0.id.hasSuffix("missing-work")
            }
        )
    }

    @Test
    func integrityReportFindsUnrecognizedLanguageAndInvalidISBN() async throws {
        let library = try await TestLibrary()
        let book = Book(
            fileName: "metadata-health.epub",
            originalFileName: "Metadata Health.epub"
        )
        book.title = "Metadata Health"
        book.language = "zzq"
        book.isbn = "978-0-306-40615-8"
        library.context.insert(book)
        try library.context.save()

        let report = try await LibraryHealthService(
            modelContext: library.context
        ).integrityReport()
        let metadataIssues = report.issues.filter {
            $0.bookID == book.uuid
                && ($0.id.hasSuffix("unrecognized-language")
                    || $0.id.hasSuffix("invalid-isbn"))
        }

        #expect(metadataIssues.count == 2)
        #expect(metadataIssues.allSatisfy { !$0.isAutomaticallyRepairable })
        #expect(metadataIssues.contains { $0.detail.contains("zzq") })
        #expect(metadataIssues.contains { $0.detail.contains("978-0-306-40615-8") })
        #expect(book.language == "zzq")
        #expect(book.isbn == "978-0-306-40615-8")
    }

    @Test
    func safeIntegrityRepairConvergesDerivedCatalogState() async throws {
        let library = try await TestLibrary()
        let book = Book(
            fileName: "repair.epub",
            originalFileName: "Repair Me.epub"
        )
        let asset = BookAsset(
            uuid: book.uuid,
            fileName: book.fileName,
            book: book
        )
        asset.formatRaw = "PDF"
        asset.sourceProvenanceRaw = nil
        asset.availabilityRaw = nil
        book.primaryAssetUUID = nil
        library.context.insert(book)
        library.context.insert(asset)
        try library.context.save()

        let health = LibraryHealthService(modelContext: library.context)
        let before = try await health.integrityReport()
        let result = try await health.repairCatalogInvariants(
            from: before,
            chunkSize: 1
        )

        #expect(result.repairedBookCount == 1)
        #expect(book.work != nil)
        #expect(book.primaryAssetUUID == asset.uuid)
        #expect(asset.formatRaw == "EPUB")
        #expect(asset.sourceProvenanceRaw != nil)
        #expect(asset.availability == .available)
        #expect(CatalogModelInvariantService.violations(in: book).isEmpty)
        #expect(book.work.map { WorkService.violations(in: $0).isEmpty } == true)

        let after = try await health.integrityReport()
        #expect(after.catalogIssueCount == 0)
        #expect(after.fileIssueCount == 1)
    }

    @Test
    func failedIntegrityRepairRestoresOwnedChanges() async throws {
        let library = try await TestLibrary()
        let book = Book(
            fileName: "rollback.epub",
            originalFileName: "Rollback.epub"
        )
        let asset = BookAsset(
            uuid: book.uuid,
            fileName: book.fileName,
            book: book
        )
        asset.formatRaw = "PDF"
        asset.sourceProvenanceRaw = nil
        book.primaryAssetUUID = nil
        library.context.insert(book)
        library.context.insert(asset)
        try library.context.save()

        let mutations = CatalogMutationService(
            modelContext: library.context,
            saveAdapter: CatalogSaveAdapter { _ in throw InjectedFailure.save }
        )
        let health = LibraryHealthService(
            modelContext: library.context,
            mutations: mutations
        )
        let report = try await health.integrityReport()

        await #expect(throws: CatalogMutationError.self) {
            try await health.repairCatalogInvariants(from: report)
        }
        #expect(book.work == nil)
        #expect(book.primaryAssetUUID == nil)
        #expect(asset.formatRaw == "PDF")
        #expect(asset.sourceProvenanceRaw == nil)
        #expect(!library.context.hasChanges)
    }

    @Test
    func importRecoveryQueuePersistsDeduplicatesAndDismisses() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "WinstonImportRecovery-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appending(path: "queue.json")
        let firstStore = ImportRecoveryQueueStore(fileURL: fileURL)
        let source = root.appending(path: "failed.epub")
        let failure = ImportFailure(
            sourceURL: source,
            requestedBookID: UUID(),
            reason: .validation,
            detail: "First failure"
        )

        let first = try await firstStore.record([failure])
        #expect(first.count == 1)
        let firstID = try #require(first.first?.id)

        let restarted = ImportRecoveryQueueStore(fileURL: fileURL)
        let loaded = try await restarted.load()
        #expect(loaded.map(\.id) == [firstID])

        let updated = try await restarted.record([
            ImportFailure(
                sourceURL: failure.sourceURL,
                requestedBookID: failure.requestedBookID,
                reason: failure.reason,
                detail: "Updated failure"
            ),
        ])
        #expect(updated.count == 1)
        #expect(updated.first?.id == firstID)
        #expect(updated.first?.detail == "Updated failure")

        let dismissed = try await restarted.dismiss(ids: [firstID])
        #expect(dismissed.isEmpty)
        #expect(try await ImportRecoveryQueueStore(fileURL: fileURL).load().isEmpty)
    }

    @Test
    func validationFailureIsVisibleAfterQueueReload() async throws {
        let library = try await TestLibrary()
        let source = library.root.appending(path: "unsupported.invalid")
        try Data("not an ebook".utf8).write(to: source)
        let settings = AppSettings()
        settings.onlineMetadataEnabled = false
        let toasts = ToastCenter()
        let queue = ImportRecoveryQueueStore(
            fileURL: library.root.appending(path: "import-recovery.json")
        )
        let metadata = MetadataService(
            modelContext: library.context,
            settings: settings
        )
        let importer = ImportService(
            modelContext: library.context,
            settings: settings,
            metadata: metadata,
            wishlist: WishlistService(
                modelContext: library.context,
                toasts: toasts
            ),
            toasts: toasts,
            recoveryQueue: queue
        )

        #expect(importer.addBooks(from: [source]) == nil)
        await importer.reloadImportRecoveryQueue()

        #expect(importer.importRecoveryItems.count == 1)
        #expect(importer.importRecoveryItems.first?.sourceURL == source)
        #expect(importer.importRecoveryItems.first?.reason == .unsupportedFormat)
        #expect(importer.lastRecoveryQueueError == nil)
    }

    @Test
    func corruptImportQueueFailsClosedWithoutReplacingEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "WinstonImportRecoveryCorrupt-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let fileURL = root.appending(path: "queue.json")
        let evidence = Data("{not-json".utf8)
        try evidence.write(to: fileURL)
        let store = ImportRecoveryQueueStore(fileURL: fileURL)

        await #expect(throws: (any Error).self) {
            try await store.load()
        }
        #expect(try Data(contentsOf: fileURL) == evidence)
    }

    @Test
    func pendingInspectionReportsUnreadableJournal() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "WinstonPendingInspection-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let books = root.appending(path: "Books", directoryHint: .isDirectory)
        let covers = root.appending(path: "Covers", directoryHint: .isDirectory)
        let state = root.appending(path: "Managed", directoryHint: .isDirectory)
        let journal = state.appending(path: "Journal", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: journal,
            withIntermediateDirectories: true
        )
        try Data("broken".utf8).write(
            to: journal.appending(path: "\(UUID().uuidString).json")
        )
        let coordinator = ManagedFileCoordinator(
            booksDirectory: books,
            coversDirectory: covers,
            stateDirectory: state
        )

        let inspection = try await coordinator.inspectPendingTransactions()

        #expect(inspection.items.isEmpty)
        #expect(inspection.unreadableJournalURLs.count == 1)
        #expect(inspection.hasUnreadableState)
    }
}
