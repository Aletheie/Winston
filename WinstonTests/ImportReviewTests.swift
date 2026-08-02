import Foundation
import SwiftData
import Testing
@testable import Winston

private actor ImportReviewCommitGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

@MainActor
@Suite("Interactive import review", .serialized)
struct ImportReviewTests {
    @Test func preparationIsEphemeralAndApprovedMetadataIsCommitted() async throws {
        let library = try await TestLibrary()
        let source = try sourceFile(
            in: library,
            named: "Prepared.epub",
            contents: "prepared bytes"
        )
        let extracted: BookMetadata = {
            var value = BookMetadata()
            value.title = "Embedded Title"
            value.author = "Embedded Author"
            return value
        }()
        let importer = makeImporter(
            in: library,
            analyzeBook: { _ in
                ImportBookAnalysis(
                    metadata: extracted,
                    drmProtected: false,
                    validation: .ok
                )
            }
        )
        let completion = AsyncStream<[UUID]>.makeStream()

        _ = importer.beginImportReview(from: [source]) { books in
            completion.continuation.yield(books.map(\.uuid))
            completion.continuation.finish()
        }
        let batch = try await readyBatch(from: importer)
        let item = try #require(batch.items.first)

        #expect(try library.context.fetchCount(FetchDescriptor<Book>()) == 0)
        #expect(try library.context.fetchCount(FetchDescriptor<Work>()) == 0)
        #expect(try library.context.fetchCount(FetchDescriptor<BookAsset>()) == 0)
        #expect(try managedBookFiles().isEmpty)
        #expect(!library.context.hasChanges)
        #expect(await library.managedFiles.pendingTransactions().count == 1)
        #expect(item.action == .createNewWork)
        #expect(item.isSelected)

        var edited = item.metadata
        edited.title = "Approved Title"
        edited.author = "Approved Author"
        importer.updateImportReviewMetadata(itemID: item.id, metadata: edited)
        importer.commitImportReview()

        var iterator = completion.stream.makeAsyncIterator()
        let importedIDs = try #require(await iterator.next())
        #expect(importedIDs.count == 1)
        let book = try #require(library.context.allBooks().first)
        #expect(book.title == "Approved Title")
        #expect(book.author == "Approved Author")
        #expect(book.work?.title == "Approved Title")
        #expect(try managedBookFiles().count == 1)
        #expect(await library.managedFiles.pendingTransactions().isEmpty)
        #expect(!library.context.hasChanges)
    }

    @Test func exactDuplicatesDefaultToSkipAndDRMRemainsVisibleButBlocked() async throws {
        let library = try await TestLibrary()
        let original = try sourceFile(
            in: library,
            named: "Original.epub",
            contents: "same bytes"
        )
        let duplicate = try sourceFile(
            in: library,
            named: "Duplicate.epub",
            contents: "same bytes"
        )
        let metadata: BookMetadata = {
            var value = BookMetadata()
            value.title = "Same Edition"
            value.author = "Ada Author"
            return value
        }()
        let importer = makeImporter(
            in: library,
            analyzeBook: { url in
                let contents = (try? String(contentsOf: url, encoding: .utf8))
                    ?? ""
                return ImportBookAnalysis(
                    metadata: metadata,
                    drmProtected: contents.contains("protected"),
                    validation: .ok
                )
            }
        )
        _ = await withCheckedContinuation { continuation in
            importer.addBooks(from: [original]) {
                continuation.resume(returning: $0.count)
            }
        }

        _ = importer.beginImportReview(
            from: [duplicate],
            automaticallyCommitCleanSingle: true
        )
        let duplicateBatch = try await readyBatch(from: importer)
        let duplicateItem = try #require(duplicateBatch.items.first)
        #expect(duplicateItem.proposedAction == .skip)
        #expect(duplicateItem.action == .skip)
        #expect(!duplicateItem.isSelected)
        #expect(duplicateItem.isSelectable)
        importer.cancelImportReview()
        try await waitUntilReviewCloses(importer)

        let drm = try sourceFile(
            in: library,
            named: "DRM.epub",
            contents: "protected bytes"
        )
        _ = importer.beginImportReview(
            from: [drm],
            automaticallyCommitCleanSingle: true
        )
        let drmBatch = try await readyBatch(from: importer)
        let drmItem = try #require(drmBatch.items.first)
        #expect(drmItem.drmProtected)
        #expect(!drmItem.isSelectable)
        #expect(!drmItem.isSelected)
        #expect(drmItem.warnings.contains {
            $0.localizedCaseInsensitiveContains("DRM")
        })
        importer.cancelImportReview()
        try await waitUntilReviewCloses(importer)
    }

    @Test func cleanSingleCanAutoCommitButMultipleFilesAlwaysWaitForReview() async throws {
        let library = try await TestLibrary()
        let first = try sourceFile(
            in: library,
            named: "Clean.epub",
            contents: "clean"
        )
        let importer = makeImporter(
            in: library,
            analyzeBook: { url in
                var metadata = BookMetadata()
                let contents = (try? String(contentsOf: url, encoding: .utf8))
                    ?? ""
                metadata.title = ["second", "third"].contains(contents)
                    ? "Shared Work"
                    : "Clean"
                metadata.author = "Test Author"
                metadata.publisher = "Test Publisher"
                if contents == "second" { metadata.year = "2000" }
                if contents == "third" { metadata.year = "2001" }
                return ImportBookAnalysis(
                    metadata: metadata,
                    drmProtected: false,
                    validation: .ok
                )
            }
        )
        let completion = AsyncStream<Int>.makeStream()
        _ = importer.beginImportReview(
            from: [first],
            automaticallyCommitCleanSingle: true
        ) {
            completion.continuation.yield($0.count)
            completion.continuation.finish()
        }
        var iterator = completion.stream.makeAsyncIterator()
        #expect(await iterator.next() == 1)
        if let phase = importer.preparedImportBatch?.phase,
           case .completed = phase {
            // Expected result state; no approval was required.
        } else {
            Issue.record("A clean single import did not auto-commit.")
        }
        importer.dismissImportReviewResult()

        let second = try sourceFile(
            in: library,
            named: "Second.epub",
            contents: "second"
        )
        let third = try sourceFile(
            in: library,
            named: "Third.epub",
            contents: "third"
        )
        let multiCompletion = AsyncStream<Int>.makeStream()
        _ = importer.beginImportReview(
            from: [second, third],
            automaticallyCommitCleanSingle: true
        ) {
            multiCompletion.continuation.yield($0.count)
            multiCompletion.continuation.finish()
        }
        let batch = try await readyBatch(from: importer)
        #expect(batch.items.count == 2)
        #expect(batch.items[0].proposedAction == .createNewWork)
        if case .createEdition(let workID) = batch.items[1].proposedAction {
            #expect(batch.items[1].workTargets.contains { $0.id == workID })
        } else {
            Issue.record("The second matching file was not proposed as another edition.")
        }
        #expect(library.context.allBooks().count == 1)

        importer.commitImportReview()
        var multiIterator = multiCompletion.stream.makeAsyncIterator()
        #expect(await multiIterator.next() == 2)
        let imported = library.context.allBooks()
        #expect(imported.count == 3)
        let shared = imported.filter { $0.title == "Shared Work" }
        #expect(shared.count == 2)
        #expect(Set(shared.compactMap { $0.work?.uuid }).count == 1)
        importer.dismissImportReviewResult()
    }

    @Test func unsupportedAndRepeatedSourcesRemainVisible() async throws {
        let library = try await TestLibrary()
        let supported = try sourceFile(
            in: library,
            named: "Visible.epub",
            contents: "visible"
        )
        let unsupported = try sourceFile(
            in: library,
            named: "Visible.doc",
            contents: "unsupported"
        )
        let importer = makeImporter(in: library)

        _ = importer.beginImportReview(
            from: [supported, supported, unsupported]
        )
        let batch = try await readyBatch(from: importer)

        #expect(batch.requestedCount == 3)
        #expect(batch.items.count == 3)
        #expect(batch.items.count { !$0.isSelectable } == 2)
        #expect(batch.items.contains {
            $0.sourceName == "Visible.doc"
                && !$0.isSelectable
                && $0.reasons == [
                    ImportFailureReason.unsupportedFormat.localizedLabel,
                ]
        })
        #expect(batch.items.contains {
            $0.sourceName == "Visible.epub"
                && !$0.isSelectable
                && $0.warnings == [
                    String(localized: "This source is already queued for import."),
                ]
        })

        importer.cancelImportReview()
        try await waitUntilReviewCloses(importer)
        #expect(library.context.allBooks().isEmpty)
        #expect(await library.managedFiles.pendingTransactions().isEmpty)
    }

    @Test func skippingAnInBatchDestinationNeverSilentlyReroutesItsDependent() async throws {
        let library = try await TestLibrary()
        let parent = try sourceFile(
            in: library,
            named: "Parent.epub",
            contents: "parent"
        )
        let child = try sourceFile(
            in: library,
            named: "Child.epub",
            contents: "child"
        )
        let importer = makeImporter(
            in: library,
            analyzeBook: { url in
                let contents = (try? String(contentsOf: url, encoding: .utf8))
                    ?? ""
                var metadata = BookMetadata()
                metadata.title = "Dependent Work"
                metadata.author = "Test Author"
                metadata.publisher = "Test Publisher"
                metadata.year = contents == "parent" ? "2000" : "2001"
                return ImportBookAnalysis(
                    metadata: metadata,
                    drmProtected: false,
                    validation: .ok
                )
            }
        )
        let completion = AsyncStream<Int>.makeStream()

        _ = importer.beginImportReview(from: [parent, child]) {
            completion.continuation.yield($0.count)
            completion.continuation.finish()
        }
        let batch = try await readyBatch(from: importer)
        let parentItem = try #require(batch.items.first {
            $0.proposedAction == .createNewWork
        })
        let dependent = try #require(batch.items.first {
            if case .createEdition = $0.proposedAction { return true }
            return false
        })
        #expect(dependent.isSelected)

        importer.setImportReviewSelection(
            itemID: parentItem.id,
            isSelected: false
        )
        importer.commitImportReview()

        var iterator = completion.stream.makeAsyncIterator()
        #expect(await iterator.next() == 0)
        #expect(library.context.allBooks().isEmpty)
        if let phase = importer.preparedImportBatch?.phase,
           case .completed(let summary) = phase {
            #expect(summary.skippedCount == 1)
            #expect(summary.failedCount == 1)
        } else {
            Issue.record("The invalid dependency did not produce an import result.")
        }
        importer.dismissImportReviewResult()
    }

    @Test func cancellationKeepsOwnedLeaseThroughReviewThenCleansItOnce() async throws {
        let library = try await TestLibrary()
        let store = ImportSourceLeaseStore(
            rootDirectory: library.root.appending(
                path: "ReviewLeases",
                directoryHint: .isDirectory
            )
        )
        let leaf = try #require(ManagedLeafName(rawValue: "Leased.epub"))
        let lease = try store.create(fileName: leaf)
        try Data("leased bytes".utf8).write(to: lease.fileURL)
        let importer = makeImporter(in: library, leaseStore: store)
        let completion = AsyncStream<Int>.makeStream()

        let session = try #require(
            importer.beginImportReview(from: [.winstonOwned(lease)]) {
                completion.continuation.yield($0.count)
                completion.continuation.finish()
            }
        )
        _ = try await readyBatch(from: importer)
        #expect(FileManager.default.fileExists(
            atPath: lease.fileURL.path(percentEncoded: false)
        ))
        #expect(library.context.allBooks().isEmpty)

        importer.cancelImportSession(id: session.id)
        var iterator = completion.stream.makeAsyncIterator()
        #expect(await iterator.next() == 0)
        #expect(!FileManager.default.fileExists(
            atPath: lease.directoryURL.path(percentEncoded: false)
        ))
        #expect(library.context.allBooks().isEmpty)
        #expect(await library.managedFiles.pendingTransactions().isEmpty)
    }

    @Test func cancellationBeforeReviewedCatalogSaveAbortsTheWholeTransaction() async throws {
        let library = try await TestLibrary()
        let source = try sourceFile(
            in: library,
            named: "Cancelled.epub",
            contents: "cancel before commit"
        )
        let gate = ImportReviewCommitGate()
        let coordinator = ManagedFileCoordinator(
            booksDirectory: AppPaths.booksDirectory,
            coversDirectory: AppPaths.coversDirectory,
            stateDirectory: AppPaths.managedFilesDirectory,
            catalogCommitGate: { await gate.suspend() }
        )
        let importer = makeImporter(in: library, managedFiles: coordinator)
        let completion = AsyncStream<Int>.makeStream()
        _ = importer.beginImportReview(from: [source]) {
            completion.continuation.yield($0.count)
            completion.continuation.finish()
        }
        _ = try await readyBatch(from: importer)
        importer.commitImportReview()

        await gate.waitUntilEntered()
        #expect(!library.context.hasChanges)
        #expect(library.context.allBooks().isEmpty)
        importer.cancelImportReview()
        await gate.release()

        var iterator = completion.stream.makeAsyncIterator()
        #expect(await iterator.next() == 0)
        #expect(try library.context.fetchCount(FetchDescriptor<Book>()) == 0)
        #expect(try library.context.fetchCount(FetchDescriptor<Work>()) == 0)
        #expect(try library.context.fetchCount(FetchDescriptor<BookAsset>()) == 0)
        #expect(try managedBookFiles().isEmpty)
        #expect(await coordinator.pendingTransactions().isEmpty)
        #expect(!library.context.hasChanges)
    }

    @Test func cancellationAfterReviewedCatalogSaveLeavesRecoverablePublication() async throws {
        let library = try await TestLibrary()
        let source = try sourceFile(
            in: library,
            named: "Recoverable.epub",
            contents: "recover after commit"
        )
        let gate = ImportReviewCommitGate()
        let coordinator = ManagedFileCoordinator(
            booksDirectory: AppPaths.booksDirectory,
            coversDirectory: AppPaths.coversDirectory,
            stateDirectory: AppPaths.managedFilesDirectory,
            catalogDidCommitGate: { await gate.suspend() }
        )
        let importer = makeImporter(in: library, managedFiles: coordinator)
        let completion = AsyncStream<Int>.makeStream()
        _ = importer.beginImportReview(from: [source]) {
            completion.continuation.yield($0.count)
            completion.continuation.finish()
        }
        _ = try await readyBatch(from: importer)
        importer.commitImportReview()

        await gate.waitUntilEntered()
        let verification = ModelContext(library.container)
        let book = try #require(
            try verification.fetch(FetchDescriptor<Book>()).first
        )
        let asset = try #require(book.assets.first)
        importer.cancelImportReview()
        await gate.release()

        var iterator = completion.stream.makeAsyncIterator()
        #expect(await iterator.next() == 0)
        #expect(await coordinator.pendingTransactions().count == 1)
        #expect(try managedBookFiles().isEmpty)

        let restarted = ManagedFileCoordinator(
            booksDirectory: AppPaths.booksDirectory,
            coversDirectory: AppPaths.coversDirectory,
            stateDirectory: AppPaths.managedFilesDirectory
        )
        let report = await restarted.recover(against: ManagedFileCatalogSnapshot(
            presentBookIDs: [book.uuid],
            referencedBookFileNames: [asset.fileName],
            coverVersions: [book.uuid: book.coverVersion]
        ))
        #expect(report.completedTransactionIDs.count == 1)
        #expect(await restarted.pendingTransactions().isEmpty)
        #expect(try managedBookFiles().map(\.lastPathComponent) == [asset.fileName])
    }

    @Test func `Catalog import exposes proposal context and cancellation cleans download`() async throws {
        let library = try await TestLibrary()
        let store = ImportSourceLeaseStore(
            rootDirectory: library.root.appending(
                path: "CatalogLeases",
                directoryHint: .isDirectory
            )
        )
        let leaf = try #require(
            ManagedLeafName(rawValue: "Catalog Book.epub")
        )
        let lease = try store.create(
            fileName: leaf,
            purpose: .catalogDownload
        )
        try Data("catalog bytes".utf8).write(to: lease.fileURL)
        let importer = makeImporter(
            in: library,
            leaseStore: store,
            analyzeBook: { _ in
                var metadata = BookMetadata()
                metadata.title = "Embedded Title"
                metadata.author = "Embedded Author"
                metadata.language = "cs"
                return ImportBookAnalysis(
                    metadata: metadata,
                    drmProtected: false,
                    validation: .ok
                )
            }
        )
        let context = CatalogImportContext(
            catalogID: "custom.catalog",
            catalogName: "Private Catalog",
            publicationID: "publication-1",
            publicationTitle: "Catalog Title",
            publicationAuthors: ["Catalog Author"],
            publicationLanguage: "en",
            sourceURL: try #require(
                URL(string: "https://catalog.example/books/1")
            ),
            attribution: "Catalog contributors",
            contributors: ["Ada", "Charles"],
            selectedFormat: "EPUB",
            acquisitionRelation: .openAccess
        )

        _ = importer.beginCatalogImportReview(
            from: .winstonOwned(lease),
            context: context
        )
        let item = try #require(
            try await readyBatch(from: importer).items.first
        )

        #expect(item.catalogContext == context)
        #expect(Set(item.catalogMetadataDifferences.map(\.field)) == Set([
            String(localized: "Title"),
            String(localized: "Author"),
            String(localized: "Language"),
        ]))
        #expect(item.metadata.title == "Embedded Title")
        #expect(FileManager.default.fileExists(
            atPath: lease.fileURL.path(percentEncoded: false)
        ))

        importer.cancelImportReview()
        try await waitUntilReviewCloses(importer)
        #expect(!FileManager.default.fileExists(
            atPath: lease.directoryURL.path(percentEncoded: false)
        ))
        #expect(library.context.allBooks().isEmpty)
    }

    private func makeImporter(
        in library: TestLibrary,
        managedFiles: ManagedFileCoordinator? = nil,
        leaseStore: ImportSourceLeaseStore = ImportSourceLeaseStore(),
        analyzeBook: @escaping @Sendable (URL) async -> ImportBookAnalysis = {
            _ in ImportBookAnalysis(metadata: BookMetadata(), drmProtected: false)
        }
    ) -> ImportService {
        let coordinator = managedFiles ?? library.managedFiles
        let settings = AppSettings()
        settings.onlineMetadataEnabled = false
        let mutations = CatalogMutationService(
            modelContext: library.context,
            managedFiles: coordinator
        )
        let toasts = ToastCenter()
        return ImportService(
            modelContext: library.context,
            settings: settings,
            metadata: MetadataService(
                modelContext: library.context,
                settings: settings,
                mutations: mutations
            ),
            wishlist: WishlistService(
                modelContext: library.context,
                toasts: toasts,
                mutations: mutations
            ),
            toasts: toasts,
            mutations: mutations,
            managedFiles: coordinator,
            importSourceLeases: leaseStore,
            analyzeBook: analyzeBook
        )
    }

    private func readyBatch(
        from importer: ImportService
    ) async throws -> PreparedImportBatch {
        let deadline = Date.now.addingTimeInterval(3)
        while Date.now < deadline {
            if let batch = importer.preparedImportBatch {
                switch batch.phase {
                case .ready:
                    return batch
                case .failed(let message):
                    Issue.record("Import review failed: \(message)")
                    return batch
                case .preparing, .committing, .completed:
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for import review preparation.")
        return try #require(importer.preparedImportBatch)
    }

    private func waitUntilReviewCloses(_ importer: ImportService) async throws {
        let deadline = Date.now.addingTimeInterval(3)
        while importer.preparedImportBatch != nil, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(importer.preparedImportBatch == nil)
    }

    private func sourceFile(
        in library: TestLibrary,
        named name: String,
        contents: String
    ) throws -> URL {
        let url = library.root.appending(path: name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func managedBookFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: AppPaths.booksDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
    }
}
