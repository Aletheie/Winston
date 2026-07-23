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

    private final class IOThreadRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var mainThreadValues: [Bool] = []

        func recordCurrentThread() {
            lock.lock()
            mainThreadValues.append(Thread.isMainThread)
            lock.unlock()
        }

        var snapshot: [Bool] {
            lock.lock()
            defer { lock.unlock() }
            return mainThreadValues
        }
    }

    private final class ManagedProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [ManagedFileProgress] = []

        func record(_ progress: ManagedFileProgress) {
            lock.lock()
            values.append(progress)
            lock.unlock()
        }

        var snapshot: [ManagedFileProgress] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    private final class CopyCancellationLatch: @unchecked Sendable {
        private let lock = NSLock()
        private let started = DispatchSemaphore(value: 0)
        private let resume = DispatchSemaphore(value: 0)
        private var didBlock = false

        func handle(_ progress: ManagedFileProgress) {
            guard progress.phase == .copying, progress.completedBytes > 0 else { return }
            lock.lock()
            guard !didBlock else {
                lock.unlock()
                return
            }
            didBlock = true
            lock.unlock()
            started.signal()
            resume.wait()
        }

        func waitUntilCopying() async {
            await Task.detached(priority: .utility) {
                self.blockUntilStarted()
            }.value
        }

        func release() {
            resume.signal()
        }

        private func blockUntilStarted() {
            started.wait()
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

    @Test func replacementSaveFailureRestoresCatalogAndKeepsOriginalFile() async throws {
        let library = try await TestLibrary()
        let oldName = "original.epub"
        let oldURL = BookFileStore.url(for: oldName)
        try Data("original".utf8).write(to: oldURL)
        let book = Book(fileName: oldName, originalFileName: oldName)
        book.fileSizeBytes = 8
        book.drmProtected = false
        book.coverVersion = 4
        let asset = BookAsset(
            fileName: oldName,
            origin: .original,
            contentHash: "old-hash",
            sizeBytes: 8,
            validationStatus: .ok,
            book: book
        )
        library.context.insert(book)
        library.context.insert(asset)
        try library.context.save()
        let replacement = try sourceFile(in: library.root, contents: "replacement")
        let coordinator = makeCoordinator()
        let viewModel = LibraryViewModel(
            modelContext: library.context,
            settings: AppSettings(),
            toasts: ToastCenter(),
            saveAdapter: CatalogSaveAdapter { _ in throw InjectedFailure() },
            managedFiles: coordinator
        )

        await viewModel.replace(asset, in: book, from: replacement)

        #expect(book.fileName == oldName)
        #expect(book.fileSizeBytes == 8)
        #expect(book.drmProtected == false)
        #expect(book.coverVersion == 4)
        #expect(asset.fileName == oldName)
        #expect(asset.contentHash == "old-hash")
        #expect(asset.sizeBytes == 8)
        #expect(asset.origin == .original)
        #expect(asset.validationStatus == .ok)
        #expect(try Data(contentsOf: oldURL) == Data("original".utf8))
        #expect(try managedBookFiles().map(\.lastPathComponent) == [oldName])
        #expect(!library.context.hasChanges)
        #expect(await coordinator.pendingTransactions().isEmpty)
    }

    @Test func removeFileSaveFailureRestoresAssetRelationshipAndFile() async throws {
        let library = try await TestLibrary()
        let primaryName = "primary.epub"
        let secondaryName = "secondary.mobi"
        try Data("primary".utf8).write(to: BookFileStore.url(for: primaryName))
        try Data("secondary".utf8).write(to: BookFileStore.url(for: secondaryName))
        let book = Book(fileName: primaryName, originalFileName: primaryName)
        let primary = BookAsset(fileName: primaryName, book: book)
        let secondary = BookAsset(fileName: secondaryName, origin: .generated, book: book)
        library.context.insert(book)
        library.context.insert(primary)
        library.context.insert(secondary)
        try library.context.save()
        let coordinator = makeCoordinator()
        let viewModel = LibraryViewModel(
            modelContext: library.context,
            settings: AppSettings(),
            toasts: ToastCenter(),
            saveAdapter: CatalogSaveAdapter { _ in throw InjectedFailure() },
            managedFiles: coordinator
        )

        #expect(await viewModel.removeFile(secondary, from: book) == false)

        #expect(book.assets.count == 2)
        #expect(book.assets.contains(where: { $0 === secondary }))
        #expect(secondary.book === book)
        #expect(try library.context.fetch(FetchDescriptor<BookAsset>()).count == 2)
        #expect(FileManager.default.fileExists(
            atPath: BookFileStore.url(for: secondaryName).path(percentEncoded: false)
        ))
        #expect(!library.context.hasChanges)
        #expect(await coordinator.pendingTransactions().isEmpty)
    }

    @Test func deleteBookSaveFailureRestoresBookWorkAndFiles() async throws {
        let library = try await TestLibrary()
        let fileName = "keep.epub"
        try Data("keep".utf8).write(to: BookFileStore.url(for: fileName))
        let book = Book(fileName: fileName, originalFileName: fileName)
        let work = Work(title: "Keep")
        work.preferredEditionUUID = book.uuid
        let asset = BookAsset(fileName: fileName, book: book)
        library.context.insert(work)
        library.context.insert(book)
        library.context.insert(asset)
        book.work = work
        try library.context.save()
        let coordinator = makeCoordinator()
        let viewModel = LibraryViewModel(
            modelContext: library.context,
            settings: AppSettings(),
            toasts: ToastCenter(),
            saveAdapter: CatalogSaveAdapter { _ in throw InjectedFailure() },
            managedFiles: coordinator
        )

        await viewModel.remove(book)

        #expect(try library.context.fetch(FetchDescriptor<Book>()).count == 1)
        #expect(try library.context.fetch(FetchDescriptor<Work>()).count == 1)
        #expect(try library.context.fetch(FetchDescriptor<BookAsset>()).count == 1)
        #expect(book.work === work)
        #expect(work.editions.contains(where: { $0 === book }))
        #expect(work.preferredEditionUUID == book.uuid)
        #expect(FileManager.default.fileExists(
            atPath: BookFileStore.url(for: fileName).path(percentEncoded: false)
        ))
        #expect(!library.context.hasChanges)
        #expect(await coordinator.pendingTransactions().isEmpty)
    }

    @Test func standardImportSaveFailureLeavesNoCatalogRowOrManagedFile() async throws {
        let library = try await TestLibrary()
        let source = try sourceFile(in: library.root, contents: "import")
        let settings = AppSettings()
        settings.onlineMetadataEnabled = false
        let coordinator = makeCoordinator()
        let mutations = CatalogMutationService(
            modelContext: library.context,
            saveAdapter: CatalogSaveAdapter { _ in throw InjectedFailure() },
            managedFiles: coordinator
        )
        let toasts = ToastCenter()
        let importer = ImportService(
            modelContext: library.context,
            settings: settings,
            metadata: MetadataService(modelContext: library.context, settings: settings),
            wishlist: WishlistService(modelContext: library.context, toasts: toasts),
            toasts: toasts,
            mutations: mutations,
            managedFiles: coordinator
        )

        let importedCount = await withCheckedContinuation { continuation in
            importer.addBooks(from: [source]) { books in
                continuation.resume(returning: books.count)
            }
        }

        #expect(importedCount == 0)
        #expect(try library.context.fetch(FetchDescriptor<Book>()).isEmpty)
        #expect(try library.context.fetch(FetchDescriptor<Work>()).isEmpty)
        #expect(try library.context.fetch(FetchDescriptor<BookAsset>()).isEmpty)
        #expect(try managedBookFiles().isEmpty)
        let contextHasChanges = library.context.hasChanges
        #expect(contextHasChanges == false)
        #expect(await coordinator.pendingTransactions().isEmpty)
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

    @Test func copyHashPublishAndCleanupUseDedicatedExecutorAndReportProgress() async throws {
        let library = try await TestLibrary()
        let source = try sourceFile(in: library.root, contents: "replacement")
        let oldName = "old.epub"
        try Data("old".utf8).write(to: BookFileStore.url(for: oldName))
        let managedSource = try ManagedFileSource.book(sourceURL: source)
        let bookID = UUID()
        let threads = IOThreadRecorder()
        let progress = ManagedProgressRecorder()
        let coordinator = makeCoordinator { point in
            switch point {
            case .afterStaging, .duringCleanup:
                threads.recordCurrentThread()
            default:
                break
            }
        }

        let transaction = try await coordinator.stage(
            intent: .replaceBookFile,
            sources: [managedSource],
            requirement: ManagedFileRequirement(
                presentBookIDs: [bookID],
                referencedBookFileNames: [managedSource.finalRelativeName],
                unreferencedBookFileNames: [oldName]
            ),
            cleanups: [.book(oldName)],
            progress: progress.record
        )
        try await coordinator.catalogDidCommit(transaction)
        let snapshot = ManagedFileCatalogSnapshot(
            presentBookIDs: [bookID],
            referencedBookFileNames: [managedSource.finalRelativeName],
            coverVersions: [:]
        )
        #expect(
            try await coordinator.reconcile(
                transaction,
                against: snapshot,
                progress: progress.record
            ) == .completed
        )

        #expect(threads.snapshot.count == 2)
        #expect(threads.snapshot.allSatisfy { !$0 })
        let phases = Set(progress.snapshot.map(\.phase))
        #expect(phases.contains(.copying))
        #expect(phases.contains(.hashing))
        #expect(phases.contains(.publishing))
        #expect(phases.contains(.cleaning))
        #expect(phases.contains(.finished))
        let fractions = progress.snapshot.map(\.overallFraction)
        #expect(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test func cancellationDuringCopyRemovesStagingAndJournal() async throws {
        let library = try await TestLibrary()
        let source = library.root.appending(path: "large-source.epub")
        #expect(FileManager.default.createFile(atPath: source.path(percentEncoded: false), contents: nil))
        let handle = try FileHandle(forWritingTo: source)
        let megabyte = Data(repeating: 0x57, count: 1_048_576)
        for _ in 0..<8 {
            try handle.write(contentsOf: megabyte)
        }
        try handle.close()

        let managedSource = try ManagedFileSource.book(sourceURL: source)
        let coordinator = makeCoordinator()
        let latch = CopyCancellationLatch()
        let stageTask = Task {
            try await coordinator.stage(
                intent: .importBook,
                sources: [managedSource],
                requirement: ManagedFileRequirement(
                    presentBookIDs: [UUID()],
                    referencedBookFileNames: [managedSource.finalRelativeName]
                ),
                progress: latch.handle
            )
        }

        await latch.waitUntilCopying()
        stageTask.cancel()
        latch.release()
        await #expect(throws: CancellationError.self) {
            _ = try await stageTask.value
        }

        #expect(await coordinator.pendingTransactions().isEmpty)
        let staging = AppPaths.managedFilesDirectory.appending(
            path: "Staging",
            directoryHint: .isDirectory
        )
        let stagedEntries = try FileManager.default.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: nil
        )
        #expect(stagedEntries.isEmpty)
    }

    @Test func oneThousandFileCleanupIsSerializedAndProgressIsThrottled() async throws {
        let library = try await TestLibrary()
        _ = library
        var cleanups: [ManagedFileCleanup] = []
        cleanups.reserveCapacity(1_000)
        for index in 0..<1_000 {
            let fileName = "bulk-\(index).epub"
            try Data([UInt8(index % 251)]).write(to: BookFileStore.url(for: fileName))
            cleanups.append(.book(fileName))
        }
        let coordinator = makeCoordinator()
        let progress = ManagedProgressRecorder()
        let transaction = try await coordinator.prepareCleanup(
            intent: .deleteBook,
            requirement: ManagedFileRequirement(
                unreferencedBookFileNames: Set(cleanups.map(\.relativeName))
            ),
            cleanups: cleanups,
            progress: progress.record
        )
        try await coordinator.catalogDidCommit(transaction)

        #expect(
            try await coordinator.reconcile(
                transaction,
                against: emptySnapshot,
                progress: progress.record
            ) == .completed
        )

        #expect(try managedBookFiles().isEmpty)
        let cleanupUpdates = progress.snapshot.filter { $0.phase == .cleaning }
        #expect(cleanupUpdates.count <= 101)
        #expect(progress.snapshot.last?.phase == .finished)
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
