import Foundation
import SwiftData
import Testing
@testable import Winston

private actor CatalogCommitSuspensionGate {
    private var entryCount = 0
    private var enteredWaiters: [
        (count: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func suspendBeforeCatalogSave() async {
        entryCount += 1
        let ready = enteredWaiters.filter { $0.count <= entryCount }
        enteredWaiters.removeAll { $0.count <= entryCount }
        ready.forEach { $0.continuation.resume() }
        await withCheckedContinuation { releaseContinuations.append($0) }
    }

    func waitUntilEntered(count: Int = 1) async {
        guard entryCount < count else { return }
        await withCheckedContinuation {
            enteredWaiters.append((count: count, continuation: $0))
        }
    }

    func release() {
        guard !releaseContinuations.isEmpty else { return }
        releaseContinuations.removeFirst().resume()
    }

    func releaseAll() {
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}

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

    private final class DestructiveHashProbe: @unchecked Sendable {
        typealias AfterHash = @Sendable (URL) throws -> Void

        private let lock = NSLock()
        private let afterHash: AfterHash
        private var invocationCount = 0

        init(afterHash: @escaping AfterHash = { _ in }) {
            self.afterHash = afterHash
        }

        func hash(_ url: URL) throws -> String {
            let digest = try ContentHasher.sha256Cancellable(of: url)
            try afterHash(url)
            lock.lock()
            invocationCount += 1
            lock.unlock()
            return digest
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return invocationCount
        }
    }

    private final class BookTrashProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var invocations = 0

        func remove(_ fileManager: FileManager, _ url: URL) throws {
            lock.lock()
            invocations += 1
            lock.unlock()
            try fileManager.removeItem(at: url)
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return invocations
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

    @Test(arguments: [
        CocoaError.Code.fileWriteOutOfSpace,
        CocoaError.Code.fileWriteNoPermission,
    ])
    func stagingIOFailureLeavesNoJournalOrOrphan(
        _ code: CocoaError.Code
    ) async throws {
        let library = try await TestLibrary()
        let source = try sourceFile(in: library.root, contents: "input")
        let managedSource = try ManagedFileSource.book(sourceURL: source)
        let coordinator = makeCoordinator {
            if case .beforeStagingWrite = $0 {
                throw CocoaError(code)
            }
        }

        await #expect(throws: CocoaError.self) {
            _ = try await coordinator.stage(
                intent: .importBook,
                sources: [managedSource],
                requirement: ManagedFileRequirement(
                    presentBookIDs: [UUID()],
                    referencedBookFileNames: [managedSource.finalRelativeName]
                )
            )
        }
        #expect(await coordinator.pendingTransactions().isEmpty)
        let staging = AppPaths.managedFilesDirectory.appending(
            path: "Staging",
            directoryHint: .isDirectory
        )
        let entries = try FileManager.default.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: nil
        )
        #expect(entries.isEmpty)
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

    @Test
    func suspendedImportOwnsNoPendingModelsAndPreservesConcurrentCatalogWrites() async throws {
        let library = try await TestLibrary()
        let existing = try seedPhysicalBook(in: library)
        let source = try sourceFile(in: library.root, contents: "concurrent import")
        let gate = CatalogCommitSuspensionGate()
        let coordinator = ManagedFileCoordinator(
            booksDirectory: AppPaths.booksDirectory,
            coversDirectory: AppPaths.coversDirectory,
            stateDirectory: AppPaths.managedFilesDirectory,
            catalogCommitGate: {
                await gate.suspendBeforeCatalogSave()
            }
        )
        let settings = AppSettings()
        settings.onlineMetadataEnabled = false
        let viewModel = LibraryViewModel(
            modelContext: library.context,
            settings: settings,
            toasts: ToastCenter(),
            managedFiles: coordinator
        )

        let importTask = Task { @MainActor in
            await withCheckedContinuation { continuation in
                viewModel.importer.addBooks(from: [source]) { books in
                    continuation.resume(returning: books.map(\.uuid))
                }
            }
        }

        await gate.waitUntilEntered()
        #expect(!library.context.hasChanges)
        #expect(viewModel.updateRating(for: existing, rating: 4))
        let collection = try #require(
            viewModel.createCollection(named: "Concurrent", adding: [existing])
        )

        let pluginMutations = CatalogMutationService(modelContext: library.context)
        let host = PluginHostAPI(
            modelContext: library.context,
            settings: settings,
            toasts: ToastCenter(),
            mutations: pluginMutations
        )
        let manifest = PluginManifest(
            id: "cz.test.concurrent-write",
            name: "Concurrent Write",
            version: "1.0.0",
            api: "1",
            entry: "index.js",
            permissions: [.libraryWrite],
            description: nil,
            author: nil
        )
        let session = host.openSession(for: manifest, contentDigest: "concurrent-digest")
        let handler = host.makeHandler(
            for: manifest,
            granted: [.libraryWrite],
            session: session
        )
        let pluginResult = await handler(.libraryUpdate(
            uuid: existing.uuid,
            patch: PluginMetadataPatch(
                title: nil,
                author: nil,
                publisher: "Concurrent Publisher",
                year: nil,
                language: nil,
                translator: nil,
                isbn: nil,
                series: nil,
                seriesIndex: nil,
                description: nil,
                tags: nil
            )
        ))
        if case .failure(let error) = pluginResult {
            Issue.record("Concurrent plugin write failed: \(error)")
        }
        #expect(!library.context.hasChanges)

        await gate.release()
        let importedIDs = await importTask.value

        #expect(importedIDs.count == 1)
        let existingID = existing.uuid
        let collectionID = collection.id
        let verification = ModelContext(library.container)
        let storedExisting = try #require(try verification.fetch(
            FetchDescriptor<Book>(
                predicate: #Predicate { $0.uuid == existingID }
            )
        ).first)
        #expect(storedExisting.rating == 4)
        #expect(storedExisting.publisher == "Concurrent Publisher")
        let storedCollection = try #require(try verification.fetch(
            FetchDescriptor<BookCollection>(
                predicate: #Predicate { $0.id == collectionID }
            )
        ).first)
        #expect(storedCollection.books.contains { $0.uuid == existingID })
        #expect(try verification.fetchCount(FetchDescriptor<Book>()) == 2)
    }

    @Test func twoSuspendedImportSessionsCommitWithoutSharingPendingModels() async throws {
        let library = try await TestLibrary()
        let firstSource = try sourceFile(in: library.root, contents: "first session")
        let secondSource = try sourceFile(in: library.root, contents: "second session")
        let gate = CatalogCommitSuspensionGate()
        let coordinator = ManagedFileCoordinator(
            booksDirectory: AppPaths.booksDirectory,
            coversDirectory: AppPaths.coversDirectory,
            stateDirectory: AppPaths.managedFilesDirectory,
            catalogCommitGate: {
                await gate.suspendBeforeCatalogSave()
            }
        )
        let settings = AppSettings()
        settings.onlineMetadataEnabled = false
        let viewModel = LibraryViewModel(
            modelContext: library.context,
            settings: settings,
            toasts: ToastCenter(),
            managedFiles: coordinator
        )
        let firstCompletion = AsyncStream<[UUID]>.makeStream()
        let secondCompletion = AsyncStream<[UUID]>.makeStream()

        let firstSession = viewModel.importer.addBooks(from: [firstSource]) { books in
            firstCompletion.continuation.yield(books.map(\.uuid))
            firstCompletion.continuation.finish()
        }
        let secondSession = viewModel.importer.addBooks(from: [secondSource]) { books in
            secondCompletion.continuation.yield(books.map(\.uuid))
            secondCompletion.continuation.finish()
        }
        #expect(firstSession != nil)
        #expect(secondSession != nil)

        await gate.waitUntilEntered(count: 2)
        #expect(!library.context.hasChanges)
        await gate.releaseAll()

        var firstIterator = firstCompletion.stream.makeAsyncIterator()
        var secondIterator = secondCompletion.stream.makeAsyncIterator()
        let firstIDs = await firstIterator.next()
        let secondIDs = await secondIterator.next()
        #expect(firstIDs?.count == 1)
        #expect(secondIDs?.count == 1)
        #expect(Set((firstIDs ?? []) + (secondIDs ?? [])).count == 2)
        let verification = ModelContext(library.container)
        #expect(try verification.fetchCount(FetchDescriptor<Book>()) == 2)
        #expect(try verification.fetchCount(FetchDescriptor<BookAsset>()) == 2)
        #expect(try managedBookFiles().count == 2)
        #expect(await coordinator.pendingTransactions().isEmpty)
    }

    @Test func cancellationBeforeCatalogSaveAbortsWithoutPendingModels() async throws {
        let library = try await TestLibrary()
        let source = try sourceFile(in: library.root, contents: "cancel before save")
        let gate = CatalogCommitSuspensionGate()
        let coordinator = ManagedFileCoordinator(
            booksDirectory: AppPaths.booksDirectory,
            coversDirectory: AppPaths.coversDirectory,
            stateDirectory: AppPaths.managedFilesDirectory,
            catalogCommitGate: {
                await gate.suspendBeforeCatalogSave()
            }
        )
        let settings = AppSettings()
        settings.onlineMetadataEnabled = false
        let viewModel = LibraryViewModel(
            modelContext: library.context,
            settings: settings,
            toasts: ToastCenter(),
            managedFiles: coordinator
        )
        let completion = AsyncStream<[UUID]>.makeStream()
        let session = try #require(
            viewModel.importer.addBooks(from: [source]) { books in
                completion.continuation.yield(books.map(\.uuid))
                completion.continuation.finish()
            }
        )

        await gate.waitUntilEntered()
        #expect(!library.context.hasChanges)
        session.cancel()
        await gate.release()

        var iterator = completion.stream.makeAsyncIterator()
        let importedIDs = await iterator.next()
        #expect(importedIDs?.isEmpty == true)
        #expect(try library.context.fetchCount(FetchDescriptor<Book>()) == 0)
        #expect(try library.context.fetchCount(FetchDescriptor<Work>()) == 0)
        #expect(try library.context.fetchCount(FetchDescriptor<BookAsset>()) == 0)
        #expect(try managedBookFiles().isEmpty)
        #expect(await coordinator.pendingTransactions().isEmpty)
        #expect(!library.context.hasChanges)
    }

    @Test func cancellationAfterCatalogSaveLeavesDurableRecoveryWork() async throws {
        let library = try await TestLibrary()
        let source = try sourceFile(in: library.root, contents: "cancel after save")
        let gate = CatalogCommitSuspensionGate()
        let coordinator = ManagedFileCoordinator(
            booksDirectory: AppPaths.booksDirectory,
            coversDirectory: AppPaths.coversDirectory,
            stateDirectory: AppPaths.managedFilesDirectory,
            catalogDidCommitGate: {
                await gate.suspendBeforeCatalogSave()
            }
        )
        let settings = AppSettings()
        settings.onlineMetadataEnabled = false
        let viewModel = LibraryViewModel(
            modelContext: library.context,
            settings: settings,
            toasts: ToastCenter(),
            managedFiles: coordinator
        )
        let completion = AsyncStream<[UUID]>.makeStream()
        let session = try #require(
            viewModel.importer.addBooks(from: [source]) { books in
                completion.continuation.yield(books.map(\.uuid))
                completion.continuation.finish()
            }
        )

        await gate.waitUntilEntered()
        #expect(!library.context.hasChanges)
        let committedContext = ModelContext(library.container)
        let committedBook = try #require(
            try committedContext.fetch(FetchDescriptor<Book>()).first
        )
        let committedAsset = try #require(committedBook.assets.first)
        #expect(try managedBookFiles().isEmpty)

        session.cancel()
        await gate.release()
        var iterator = completion.stream.makeAsyncIterator()
        let callbackIDs = await iterator.next()
        #expect(callbackIDs?.isEmpty == true)
        #expect(await coordinator.pendingTransactions().count == 1)
        #expect(try managedBookFiles().isEmpty)

        let restarted = ManagedFileCoordinator(
            booksDirectory: AppPaths.booksDirectory,
            coversDirectory: AppPaths.coversDirectory,
            stateDirectory: AppPaths.managedFilesDirectory
        )
        let report = await restarted.recover(against: ManagedFileCatalogSnapshot(
            presentBookIDs: [committedBook.uuid],
            referencedBookFileNames: [committedAsset.fileName],
            coverVersions: [committedBook.uuid: committedBook.coverVersion]
        ))
        #expect(report.completedTransactionIDs.count == 1)
        #expect(await restarted.pendingTransactions().isEmpty)
        #expect(try managedBookFiles().map(\.lastPathComponent) == [committedAsset.fileName])
        #expect(try committedContext.fetchCount(FetchDescriptor<Book>()) == 1)
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
        let expectedHash = try ContentHasher.sha256(of: source)
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
        let oldIdentity = try await coordinator.captureIdentity(of: .book(oldName))

        let transaction = try await coordinator.stage(
            intent: .replaceBookFile,
            sources: [managedSource],
            requirement: ManagedFileRequirement(
                presentBookIDs: [bookID],
                referencedBookFileNames: [managedSource.finalRelativeName],
                unreferencedBookFileNames: [oldName]
            ),
            cleanups: [.file(oldIdentity)],
            progress: progress.record
        )
        #expect(transaction.files.first?.sourceReadPassCount == 1)
        #expect(transaction.files.first?.sha256 == expectedHash)
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

    @Test func cleanupRefusesAReplacementGenerationWithTheSameName() async throws {
        let library = try await TestLibrary()
        _ = library
        let fileName = "generation.epub"
        let url = BookFileStore.url(for: fileName)
        try Data("first".utf8).write(to: url)
        let coordinator = makeCoordinator()
        let identity = try await coordinator.captureIdentity(of: .book(fileName))
        let transaction = try await coordinator.prepareCleanup(
            intent: .deleteBookFile,
            requirement: ManagedFileRequirement(
                unreferencedBookFileNames: [fileName]
            ),
            cleanups: [.file(identity)]
        )
        try await coordinator.willCommitCatalog(transaction)
        try await coordinator.catalogDidCommit(transaction)

        try Data("second generation".utf8).write(to: url, options: .atomic)

        await #expect(
            throws: ManagedFileCoordinatorError.fileGenerationChanged(fileName)
        ) {
            _ = try await coordinator.reconcile(transaction, against: emptySnapshot)
        }
        #expect(try Data(contentsOf: url) == Data("second generation".utf8))
    }

    @Test func cleanupRefusesEqualLengthInPlaceOverwriteWithRestoredMtime() async throws {
        let library = try await TestLibrary()
        _ = library
        let fileName = "same-metadata.epub"
        let url = BookFileStore.url(for: fileName)
        let original = Data("AAAA".utf8)
        let replacement = Data("BBBB".utf8)
        try original.write(to: url)
        let stableModificationDate = Date(timeIntervalSince1970: 2_000_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: stableModificationDate],
            ofItemAtPath: url.path(percentEncoded: false)
        )
        let coordinator = makeCoordinator()
        let identity = try await coordinator.captureIdentity(of: .book(fileName))
        let generation = try #require(identity.generation)
        let transaction = try await coordinator.prepareCleanup(
            intent: .deleteBookFile,
            requirement: ManagedFileRequirement(
                unreferencedBookFileNames: [fileName]
            ),
            cleanups: [.file(identity)]
        )
        try await coordinator.willCommitCatalog(transaction)
        try await coordinator.catalogDidCommit(transaction)

        try replacement.write(to: url)
        if let modificationDate = generation.modificationDate {
            try FileManager.default.setAttributes(
                [.modificationDate: modificationDate],
                ofItemAtPath: url.path(percentEncoded: false)
            )
        }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path(percentEncoded: false)
        )
        #expect((attributes[.systemFileNumber] as? NSNumber)?.uint64Value
            == generation.fileNumber)
        #expect((attributes[.size] as? NSNumber)?.int64Value
            == generation.byteCount)

        await #expect(
            throws: ManagedFileCoordinatorError.cleanupContentChanged(fileName)
        ) {
            _ = try await coordinator.reconcile(
                transaction,
                against: emptySnapshot
            )
        }
        #expect(try Data(contentsOf: url) == replacement)
    }

    @Test func metadataChangeDuringDestructiveHashPreservesFile() async throws {
        let library = try await TestLibrary()
        _ = library
        let fileName = "changes-during-hash.epub"
        let url = BookFileStore.url(for: fileName)
        try Data("original".utf8).write(to: url)
        let probe = DestructiveHashProbe { target in
            try Data("modified".utf8).write(to: target)
        }
        let coordinator = makeCoordinator(destructiveHasher: probe.hash)
        let identity = try await coordinator.captureIdentity(of: .book(fileName))
        let transaction = try await coordinator.prepareCleanup(
            intent: .deleteBookFile,
            requirement: ManagedFileRequirement(
                unreferencedBookFileNames: [fileName]
            ),
            cleanups: [.file(identity)]
        )
        try await coordinator.willCommitCatalog(transaction)
        try await coordinator.catalogDidCommit(transaction)

        await #expect(
            throws: ManagedFileCoordinatorError.fileGenerationChanged(fileName)
        ) {
            _ = try await coordinator.reconcile(
                transaction,
                against: emptySnapshot
            )
        }
        #expect(probe.count == 1)
        #expect(try Data(contentsOf: url) == Data("modified".utf8))
    }

    @Test func symlinkSwapAfterCaptureIsPreserved() async throws {
        let library = try await TestLibrary()
        let fileName = "swapped-link.epub"
        let url = BookFileStore.url(for: fileName)
        let outside = library.root.appending(path: "outside-swap.epub")
        try Data("managed".utf8).write(to: url)
        try Data("outside".utf8).write(to: outside)
        let coordinator = makeCoordinator()
        let identity = try await coordinator.captureIdentity(of: .book(fileName))
        let transaction = try await coordinator.prepareCleanup(
            intent: .deleteBookFile,
            requirement: ManagedFileRequirement(
                unreferencedBookFileNames: [fileName]
            ),
            cleanups: [.file(identity)]
        )
        try await coordinator.willCommitCatalog(transaction)
        try await coordinator.catalogDidCommit(transaction)

        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(
            at: url,
            withDestinationURL: outside
        )

        await #expect(
            throws: ManagedFileCoordinatorError.unsafeRelativeName(fileName)
        ) {
            _ = try await coordinator.reconcile(
                transaction,
                against: emptySnapshot
            )
        }
        #expect(try Data(contentsOf: outside) == Data("outside".utf8))
        #expect(try url.resourceValues(
            forKeys: [.isSymbolicLinkKey]
        ).isSymbolicLink == true)
    }

    @Test func missingCleanupTargetRemainsIdempotentAfterCommit() async throws {
        let library = try await TestLibrary()
        _ = library
        let fileName = "already-missing.epub"
        let url = BookFileStore.url(for: fileName)
        try Data("remove externally".utf8).write(to: url)
        let coordinator = makeCoordinator()
        let identity = try await coordinator.captureIdentity(of: .book(fileName))
        let transaction = try await coordinator.prepareCleanup(
            intent: .deleteBookFile,
            requirement: ManagedFileRequirement(
                unreferencedBookFileNames: [fileName]
            ),
            cleanups: [.file(identity)]
        )
        try await coordinator.willCommitCatalog(transaction)
        try await coordinator.catalogDidCommit(transaction)
        try FileManager.default.removeItem(at: url)

        #expect(try await coordinator.reconcile(
            transaction,
            against: emptySnapshot
        ) == .completed)
        #expect(await coordinator.pendingTransactions().isEmpty)
    }

    @Test func exactLargeGenerationHashesOnceOnlyAtDestructiveCheckpoint() async throws {
        let library = try await TestLibrary()
        _ = library
        let fileName = "large-cleanup.epub"
        let url = BookFileStore.url(for: fileName)
        try Data(repeating: 0x57, count: 8 * 1_024 * 1_024).write(to: url)
        let identity = try await makeCoordinator().captureIdentity(
            of: .book(fileName)
        )
        let probe = DestructiveHashProbe()
        let coordinator = makeCoordinator(destructiveHasher: probe.hash)
        let transaction = try await coordinator.prepareCleanup(
            intent: .deleteBookFile,
            requirement: ManagedFileRequirement(
                unreferencedBookFileNames: [fileName]
            ),
            cleanups: [.file(identity)]
        )

        #expect(probe.count == 0)
        try await coordinator.willCommitCatalog(transaction)
        #expect(probe.count == 0)
        try await coordinator.catalogDidCommit(transaction)
        #expect(try await coordinator.reconcile(
            transaction,
            against: emptySnapshot
        ) == .completed)

        #expect(probe.count == 1)
        #expect(!FileManager.default.fileExists(
            atPath: url.path(percentEncoded: false)
        ))
    }

    @Test func userRemovalUsesTrashPolicyWhileArtifactCleanupIsPermanent() async throws {
        let library = try await TestLibrary()
        _ = library
        let userFile = "user-removal.epub"
        let artifactFile = "artifact-cleanup.mobi"
        try Data("user".utf8).write(to: BookFileStore.url(for: userFile))
        try Data("artifact".utf8).write(to: BookFileStore.url(for: artifactFile))
        let probe = BookTrashProbe()
        let coordinator = makeCoordinator(trashBook: probe.remove)
        let identities = try await coordinator.captureIdentities(of: [
            .book(userFile),
            .book(artifactFile),
        ])
        let transaction = try await coordinator.prepareCleanup(
            intent: .deleteBook,
            requirement: ManagedFileRequirement(
                unreferencedBookFileNames: [userFile, artifactFile]
            ),
            cleanups: [
                .file(identities[0], disposition: .trash),
                .file(identities[1], disposition: .delete),
            ]
        )
        try await coordinator.catalogDidCommit(transaction)

        #expect(
            try await coordinator.reconcile(transaction, against: emptySnapshot)
                == .completed
        )
        #expect(probe.count == 1)
        #expect(!FileManager.default.fileExists(
            atPath: BookFileStore.url(for: userFile).path(percentEncoded: false)
        ))
        #expect(!FileManager.default.fileExists(
            atPath: BookFileStore.url(for: artifactFile).path(percentEncoded: false)
        ))
    }

    @Test func aFileAppearingAfterAMissingSnapshotIsNotDeleted() async throws {
        let library = try await TestLibrary()
        _ = library
        let fileName = "appeared.epub"
        let url = BookFileStore.url(for: fileName)
        let coordinator = makeCoordinator()
        let identity = try await coordinator.captureIdentity(of: .book(fileName))
        #expect(!identity.exists)
        let transaction = try await coordinator.prepareCleanup(
            intent: .deleteBookFile,
            requirement: ManagedFileRequirement(
                unreferencedBookFileNames: [fileName]
            ),
            cleanups: [.file(identity)]
        )
        try await coordinator.willCommitCatalog(transaction)
        try await coordinator.catalogDidCommit(transaction)

        try Data("late".utf8).write(to: url)

        await #expect(
            throws: ManagedFileCoordinatorError.fileGenerationChanged(fileName)
        ) {
            _ = try await coordinator.reconcile(transaction, against: emptySnapshot)
        }
        #expect(try Data(contentsOf: url) == Data("late".utf8))
    }

    @Test func stagedArtifactIsReadOnlyAndGenerationValidatedBeforeCommit() async throws {
        let library = try await TestLibrary()
        let source = try sourceFile(in: library.root, contents: "immutable")
        let managedSource = try ManagedFileSource.book(sourceURL: source)
        let coordinator = makeCoordinator()
        let transaction = try await coordinator.stage(
            intent: .importBook,
            sources: [managedSource],
            requirement: ManagedFileRequirement(
                presentBookIDs: [UUID()],
                referencedBookFileNames: [managedSource.finalRelativeName]
            )
        )
        let staged = try #require(transaction.files.first)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: staged.stagedURL.path(percentEncoded: false)
        )
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        #expect(permissions == 0o444)

        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o644))],
            ofItemAtPath: staged.stagedURL.path(percentEncoded: false)
        )
        try Data("tampered".utf8).write(to: staged.stagedURL, options: .atomic)

        await #expect(
            throws: ManagedFileCoordinatorError.fileGenerationChanged(
                managedSource.finalRelativeName
            )
        ) {
            try await coordinator.willCommitCatalog(transaction)
        }
        await coordinator.abort(transaction)
    }

    @Test func symlinkedManagedLeafIsRejectedWithoutReadingItsTarget() async throws {
        let library = try await TestLibrary()
        let outside = library.root.appending(path: "outside.epub")
        let linkName = "linked-generation.epub"
        let link = BookFileStore.catalogURL(for: linkName)!
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let coordinator = makeCoordinator()

        await #expect(
            throws: ManagedFileCoordinatorError.unsafeRelativeName(linkName)
        ) {
            _ = try await coordinator.captureIdentity(of: .book(linkName))
        }
        #expect(try Data(contentsOf: outside) == Data("outside".utf8))
    }

    @Test func recoveryRemovesStagingDirectoriesWithoutAJournal() async throws {
        let library = try await TestLibrary()
        _ = library
        let coordinator = makeCoordinator()
        _ = try await coordinator.captureIdentity(of: .book("missing.epub"))
        let orphan = AppPaths.managedFilesDirectory
            .appending(path: "Staging", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: orphan,
            withIntermediateDirectories: true
        )
        try Data("partial".utf8).write(to: orphan.appending(path: "partial"))

        let report = await coordinator.recover(against: emptySnapshot)

        #expect(report.removedOrphanStagingURLs.count == 1)
        #expect(
            report.removedOrphanStagingURLs.first?.lastPathComponent
                == orphan.lastPathComponent
        )
        #expect(!FileManager.default.fileExists(
            atPath: orphan.path(percentEncoded: false)
        ))
    }

    @Test func destinationCollisionIsRejectedBeforeCatalogSave() async throws {
        let library = try await TestLibrary()
        let source = try sourceFile(in: library.root, contents: "incoming")
        let assetID = UUID()
        let managedSource = try ManagedFileSource.book(
            sourceURL: source,
            destination: .newAsset(assetID: assetID)
        )
        try Data("existing".utf8).write(
            to: BookFileStore.url(for: managedSource.finalRelativeName)
        )
        let coordinator = makeCoordinator()
        let transaction = try await coordinator.stage(
            intent: .importBook,
            sources: [managedSource],
            requirement: ManagedFileRequirement(
                presentBookIDs: [UUID()],
                referencedBookFileNames: [managedSource.finalRelativeName]
            )
        )

        await #expect(
            throws: ManagedFileCoordinatorError.destinationConflict(
                managedSource.finalRelativeName
            )
        ) {
            try await coordinator.willCommitCatalog(transaction)
        }
        await coordinator.abort(transaction)
    }

    @Test func oneThousandFileCleanupIsSerializedAndProgressIsThrottled() async throws {
        let library = try await TestLibrary()
        _ = library
        var cleanups: [ManagedFileCleanup] = []
        var references: [ManagedFileReference] = []
        references.reserveCapacity(1_000)
        for index in 0..<1_000 {
            let fileName = "bulk-\(index).epub"
            try Data([UInt8(index % 251)]).write(to: BookFileStore.url(for: fileName))
            references.append(.book(fileName))
        }
        let coordinator = makeCoordinator()
        cleanups = try await coordinator.captureIdentities(of: references).map {
            .file($0)
        }
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

    @Test func normalCommitVerificationFetchesOnlyTransactionEvidence() async throws {
        let library = try await TestLibrary()
        let work = Work(title: "Target work")
        work.coverVersion = 7
        let workBook = Book(
            fileName: "target-work.epub",
            originalFileName: "target-work.epub"
        )
        workBook.work = work
        #expect(workBook.selectCoverOwner(.work(work.uuid)))

        let generatedBook = Book(
            fileName: "target-generated.epub",
            originalFileName: "target-generated.epub"
        )
        let generatedAsset = BookAsset(
            fileName: "target-generated.epub",
            coverVersion: 3,
            book: generatedBook
        )
        #expect(generatedBook.selectCoverOwner(.generatedAsset(generatedAsset.uuid)))

        library.context.insert(work)
        library.context.insert(workBook)
        library.context.insert(generatedBook)
        library.context.insert(generatedAsset)
        for index in 0..<128 {
            let unrelated = Book(
                fileName: "unrelated-\(index).epub",
                originalFileName: "unrelated-\(index).epub"
            )
            library.context.insert(unrelated)
            library.context.insert(BookAsset(
                fileName: unrelated.fileName,
                book: unrelated
            ))
        }
        try library.context.save()

        let requirement = ManagedFileRequirement(
            presentBookIDs: [workBook.uuid, generatedBook.uuid],
            referencedBookFileNames: [generatedAsset.fileName],
            coverVersions: [workBook.uuid: workBook.coverVersion],
            coverRequirements: [
                ManagedCoverRequirement(
                    owner: .work(work.uuid),
                    version: work.coverVersion,
                    selectedBookIDs: [workBook.uuid]
                ),
                ManagedCoverRequirement(
                    owner: .generatedAsset(generatedAsset.uuid),
                    version: generatedAsset.coverVersion,
                    selectedBookIDs: [generatedBook.uuid]
                )
            ]
        )
        let transaction = ManagedFileTransaction(
            id: UUID(),
            intent: .importBook,
            createdAt: .now,
            files: [],
            requirement: requirement,
            cleanups: []
        )
        let mutations = CatalogMutationService(
            modelContext: library.context,
            managedFiles: makeCoordinator()
        )

        let verification = try mutations.managedFileVerificationSnapshot(
            for: [transaction]
        )

        #expect(verification.metrics.fetchCount == 3)
        #expect(verification.metrics.requestedBookCount == 2)
        #expect(verification.metrics.requestedFileNameCount == 1)
        #expect(verification.catalog.satisfies(requirement))
        #expect(verification.catalog.presentBookIDs == [workBook.uuid, generatedBook.uuid])
        #expect(verification.catalog.referencedBookFileNames == [generatedAsset.fileName])
        #expect(verification.catalog.coverReferencesByBookID.count == 2)
    }

    private var emptySnapshot: ManagedFileCatalogSnapshot {
        ManagedFileCatalogSnapshot(
            presentBookIDs: [],
            referencedBookFileNames: [],
            coverVersions: [:]
        )
    }

    private func makeCoordinator(
        _ fault: @escaping ManagedFileCoordinator.FaultInjector = { _ in },
        destructiveHasher: @escaping ManagedFileCoordinator.DestructiveHasher = {
            try ContentHasher.sha256Cancellable(of: $0)
        },
        trashBook: @escaping ManagedFileCoordinator.BookTrashHandler = {
            fileManager, url in
            try fileManager.removeItem(at: url)
        }
    ) -> ManagedFileCoordinator {
        ManagedFileCoordinator(
            booksDirectory: AppPaths.booksDirectory,
            coversDirectory: AppPaths.coversDirectory,
            stateDirectory: AppPaths.managedFilesDirectory,
            faultInjector: fault,
            destructiveHasher: destructiveHasher,
            trashBook: trashBook
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
