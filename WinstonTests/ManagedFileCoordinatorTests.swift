import Foundation
import SwiftData
import Testing
@testable import Winston

@Suite("Managed file transactions", .serialized)
@MainActor
struct ManagedFileCoordinatorTests {
    private struct InjectedFailure: Error {}

    private final class SecondPublishFault: @unchecked Sendable {
        private let lock = NSLock()
        private var publishCount = 0

        func inject(at point: ManagedFileFaultPoint) throws {
            guard case .duringPublish = point else { return }
            lock.lock()
            defer { lock.unlock() }
            publishCount += 1
            if publishCount == 2 { throw InjectedFailure() }
        }
    }

    @Test func failureAfterStagingLeavesRecoverableJournalAndNoOrphan() async throws {
        let library = try await TestLibrary()
        let source = try sourceFile(in: library.root, contents: "staged")
        let bookID = UUID()
        let managedSource = try ManagedFileSource.book(sourceURL: source)
        let coordinator = makeCoordinator {
            if $0 == .afterStaging { throw InjectedFailure() }
        }

        await #expect(throws: InjectedFailure.self) {
            _ = try await coordinator.stage(
                intent: .importBook,
                sources: [managedSource],
                requirement: ManagedFileRequirement(
                    presentBookIDs: [bookID],
                    referencedBookFileNames: [managedSource.finalRelativeName]
                )
            )
        }
        #expect(await coordinator.pendingTransactions().count == 1)

        let restarted = makeCoordinator()
        let report = await restarted.recover(against: emptySnapshot)

        #expect(report.abortedTransactionIDs.count == 1)
        #expect(await restarted.pendingTransactions().isEmpty)
        #expect(try managedBookFiles().isEmpty)
    }

    @Test func failureBeforeCatalogSaveAbortsStageAndKeepsCatalogClean() async throws {
        let library = try await TestLibrary()
        let book = try seedPhysicalBook(in: library)
        let source = try sourceFile(in: library.root, contents: "before-save")
        let coordinator = makeCoordinator {
            if $0 == .beforeCatalogSave { throw InjectedFailure() }
        }
        let viewModel = LibraryViewModel(
            modelContext: library.context,
            settings: AppSettings(),
            toasts: ToastCenter(),
            managedFiles: coordinator
        )

        let asset = await viewModel.addFile(to: book, from: source)

        #expect(asset == nil)
        #expect(book.fileName.isEmpty)
        #expect(book.assets.isEmpty)
        #expect(!library.context.hasChanges)
        #expect(await coordinator.pendingTransactions().isEmpty)
        #expect(try managedBookFiles().isEmpty)
    }

    @Test func failedCatalogSaveRollsBackModelsAndAbortsStage() async throws {
        let library = try await TestLibrary()
        let book = try seedPhysicalBook(in: library)
        let source = try sourceFile(in: library.root, contents: "save-failure")
        let coordinator = makeCoordinator()
        let viewModel = LibraryViewModel(
            modelContext: library.context,
            settings: AppSettings(),
            toasts: ToastCenter(),
            saveAdapter: CatalogSaveAdapter { _ in throw InjectedFailure() },
            managedFiles: coordinator
        )

        let asset = await viewModel.addFile(to: book, from: source)

        #expect(asset == nil)
        #expect(book.fileName.isEmpty)
        #expect(book.assets.isEmpty)
        #expect(!library.context.hasChanges)
        #expect(await coordinator.pendingTransactions().isEmpty)
        #expect(try managedBookFiles().isEmpty)

        book.notes = "unrelated"
        try library.context.save()
        #expect(book.fileName.isEmpty)
    }

    @Test func crashAfterCatalogSavePublishesOnRestart() async throws {
        let library = try await TestLibrary()
        let book = try seedPhysicalBook(in: library)
        let source = try sourceFile(in: library.root, contents: "after-save")
        let coordinator = makeCoordinator {
            if $0 == .afterCatalogSave { throw InjectedFailure() }
        }
        let viewModel = LibraryViewModel(
            modelContext: library.context,
            settings: AppSettings(),
            toasts: ToastCenter(),
            managedFiles: coordinator
        )

        #expect(await viewModel.addFile(to: book, from: source) == nil)
        let committedName = book.fileName
        #expect(!committedName.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: BookFileStore.url(for: committedName).path(percentEncoded: false)
        ))
        #expect(await coordinator.pendingTransactions().count == 1)

        let restarted = makeCoordinator()
        let recovery = CatalogMutationService(
            modelContext: library.context,
            managedFiles: restarted
        )
        let report = await recovery.recoverManagedFiles()

        #expect(!report.hasPendingWork)
        #expect(report.completedTransactionIDs.count == 1)
        #expect(FileManager.default.fileExists(
            atPath: BookFileStore.url(for: committedName).path(percentEncoded: false)
        ))
        #expect(await restarted.pendingTransactions().isEmpty)
    }

    @Test func publishIOFailureRecoversMissingCommittedFileOnRestart() async throws {
        let library = try await TestLibrary()
        let book = try seedPhysicalBook(in: library)
        let source = try sourceFile(in: library.root, contents: "publish-failure")
        let coordinator = makeCoordinator {
            if case .duringPublish = $0 { throw InjectedFailure() }
        }
        let viewModel = LibraryViewModel(
            modelContext: library.context,
            settings: AppSettings(),
            toasts: ToastCenter(),
            managedFiles: coordinator
        )

        #expect(await viewModel.addFile(to: book, from: source) == nil)
        let committedName = book.fileName
        #expect(!FileManager.default.fileExists(
            atPath: BookFileStore.url(for: committedName).path(percentEncoded: false)
        ))

        let restarted = makeCoordinator()
        let recovery = CatalogMutationService(
            modelContext: library.context,
            managedFiles: restarted
        )
        #expect(!(await recovery.recoverManagedFiles()).hasPendingWork)
        #expect(try Data(contentsOf: BookFileStore.url(for: committedName)) == Data("publish-failure".utf8))
    }

    @Test func replacementCleanupFailureRetiresOldGenerationOnRestart() async throws {
        let library = try await TestLibrary()
        let oldName = "old.epub"
        let oldURL = BookFileStore.url(for: oldName)
        try Data("old".utf8).write(to: oldURL)
        let book = Book(fileName: oldName, originalFileName: oldName)
        let asset = BookAsset(fileName: oldName, sizeBytes: 3, book: book)
        library.context.insert(book)
        library.context.insert(asset)
        try library.context.save()
        let replacement = try sourceFile(in: library.root, contents: "new")
        let coordinator = makeCoordinator {
            if case .duringCleanup = $0 { throw InjectedFailure() }
        }
        let viewModel = LibraryViewModel(
            modelContext: library.context,
            settings: AppSettings(),
            toasts: ToastCenter(),
            managedFiles: coordinator
        )

        await viewModel.replace(asset, in: book, from: replacement)

        let newName = book.fileName
        #expect(newName != oldName)
        #expect(FileManager.default.fileExists(atPath: oldURL.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(
            atPath: BookFileStore.url(for: newName).path(percentEncoded: false)
        ))
        #expect(await coordinator.pendingTransactions().count == 1)

        let restarted = makeCoordinator()
        let recovery = CatalogMutationService(
            modelContext: library.context,
            managedFiles: restarted
        )
        #expect(!(await recovery.recoverManagedFiles()).hasPendingWork)
        #expect(!FileManager.default.fileExists(atPath: oldURL.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(
            atPath: BookFileStore.url(for: newName).path(percentEncoded: false)
        ))
    }

    @Test func deletionTombstoneRemovesFilesAndCoverAfterRestart() async throws {
        let library = try await TestLibrary()
        let fileName = "delete-me.epub"
        let fileURL = BookFileStore.url(for: fileName)
        try Data("book".utf8).write(to: fileURL)
        let book = Book(fileName: fileName, originalFileName: fileName)
        let bookID = book.uuid
        let asset = BookAsset(fileName: fileName, book: book)
        library.context.insert(book)
        library.context.insert(asset)
        try library.context.save()
        try Data("cover".utf8).write(
            to: AppPaths.coversDirectory.appending(path: "\(bookID.uuidString).jpg")
        )
        let coordinator = makeCoordinator {
            if $0 == .afterCatalogSave { throw InjectedFailure() }
        }
        let viewModel = LibraryViewModel(
            modelContext: library.context,
            settings: AppSettings(),
            toasts: ToastCenter(),
            managedFiles: coordinator
        )

        await viewModel.remove(book)

        #expect(try library.context.fetch(FetchDescriptor<Book>()).isEmpty)
        #expect(FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
        #expect(CoverStore.exists(for: bookID))

        let restarted = makeCoordinator()
        let recovery = CatalogMutationService(
            modelContext: library.context,
            managedFiles: restarted
        )
        #expect(!(await recovery.recoverManagedFiles()).hasPendingWork)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
        #expect(!CoverStore.exists(for: bookID))
    }

    @Test func multiPayloadTransactionResumesAfterFirstPayload() async throws {
        let library = try await TestLibrary()
        let source = try sourceFile(in: library.root, contents: "book-payload")
        let bookID = UUID()
        let bookSource = try ManagedFileSource.book(sourceURL: source)
        let coverSource = ManagedFileSource.cover(data: Data("cover-payload".utf8), bookID: bookID)
        let fault = SecondPublishFault()
        let coordinator = makeCoordinator(fault.inject)
        let transaction = try await coordinator.stage(
            intent: .calibreImport,
            sources: [bookSource, coverSource],
            requirement: ManagedFileRequirement(
                presentBookIDs: [bookID],
                referencedBookFileNames: [bookSource.finalRelativeName],
                coverVersions: [bookID: 1]
            )
        )
        try await coordinator.catalogDidCommit(transaction)
        let snapshot = ManagedFileCatalogSnapshot(
            presentBookIDs: [bookID],
            referencedBookFileNames: [bookSource.finalRelativeName],
            coverVersions: [bookID: 1]
        )

        await #expect(throws: InjectedFailure.self) {
            _ = try await coordinator.reconcile(transaction, against: snapshot)
        }
        #expect(FileManager.default.fileExists(
            atPath: BookFileStore.url(for: bookSource.finalRelativeName).path(percentEncoded: false)
        ))
        #expect(!CoverStore.exists(for: bookID))

        let restarted = makeCoordinator()
        let report = await restarted.recover(against: snapshot)
        #expect(!report.hasPendingWork)
        #expect(CoverStore.exists(for: bookID))
        #expect(await restarted.pendingTransactions().isEmpty)
    }

    @Test func oneThousandInterruptedStagesProduceZeroOrphans() async throws {
        let library = try await TestLibrary()
        let source = try sourceFile(in: library.root, contents: "x")
        let coordinator = makeCoordinator()

        for _ in 0..<1_000 {
            let bookID = UUID()
            let managedSource = try ManagedFileSource.book(sourceURL: source)
            _ = try await coordinator.stage(
                intent: .importBook,
                sources: [managedSource],
                requirement: ManagedFileRequirement(
                    presentBookIDs: [bookID],
                    referencedBookFileNames: [managedSource.finalRelativeName]
                )
            )
        }
        #expect(await coordinator.pendingTransactions().count == 1_000)

        let restarted = makeCoordinator()
        let report = await restarted.recover(against: emptySnapshot)

        #expect(report.abortedTransactionIDs.count == 1_000)
        #expect(await restarted.pendingTransactions().isEmpty)
        #expect(try managedBookFiles().isEmpty)
    }

    private var emptySnapshot: ManagedFileCatalogSnapshot {
        ManagedFileCatalogSnapshot(
            presentBookIDs: [],
            referencedBookFileNames: [],
            coverVersions: [:]
        )
    }

    private func makeCoordinator(
        _ fault: @escaping ManagedFileCoordinator.FaultInjector = { _ in }
    ) -> ManagedFileCoordinator {
        ManagedFileCoordinator(
            booksDirectory: AppPaths.booksDirectory,
            coversDirectory: AppPaths.coversDirectory,
            stateDirectory: AppPaths.managedFilesDirectory,
            faultInjector: fault
        )
    }

    private func sourceFile(in root: URL, contents: String) throws -> URL {
        let url = root.appending(path: "source-\(UUID().uuidString).epub")
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func seedPhysicalBook(in library: TestLibrary) throws -> Book {
        let book = Book(fileName: "", originalFileName: "Physical")
        book.hasPhysicalCopy = true
        library.context.insert(book)
        try library.context.save()
        return book
    }

    private func managedBookFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: AppPaths.booksDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
    }
}
