import Foundation
import SwiftData
import Testing
@testable import Winston

@Suite("Edition service", .serialized)
@MainActor
struct EditionServiceTests {
    private struct InjectedFailure: Error {}

    private func insertBook(
        _ library: TestLibrary,
        name: String,
        title: String = "Dune",
        author: String = "Frank Herbert",
        format: String = "epub"
    ) -> Book {
        let book = Book(fileName: "\(name).\(format)", originalFileName: "\(name).\(format)")
        book.title = title
        book.author = author
        let work = Work(title: title, author: author)
        let asset = BookAsset(uuid: book.uuid, fileName: book.fileName, sizeBytes: 10, book: book)
        library.context.insert(work)
        library.context.insert(book)
        library.context.insert(asset)
        book.work = work
        work.preferredEditionUUID = book.uuid
        return book
    }

    @Test func groupAndMergeFillEmptyCanonicalMetadata() async throws {
        let library = try await TestLibrary()
        let first = insertBook(library, name: "first")
        let second = insertBook(library, name: "second", title: "Duna", format: "mobi")
        first.work?.title = nil
        second.work?.originalTitle = "Dune"
        try library.context.save()

        let service = CatalogReconciliationService(modelContext: library.context)
        let merged = try #require(service.groupIntoWork([first, second]))
        #expect(merged.editions.count == 2)
        #expect(merged.title != nil)
        #expect(try library.context.fetchCount(FetchDescriptor<Work>()) == 1)
        #expect(service.editionCounts[first.uuid] == 2)
        #expect(service.editionCounts[second.uuid] == 2)
    }

    @Test func absorbKeepsFilesAndReparentsAssetsHighlightsAndCollections() async throws {
        let library = try await TestLibrary()
        let winner = insertBook(library, name: "winner", format: "mobi")
        let loser = insertBook(library, name: "loser")
        winner.isbn = "9780441013593"
        loser.isbn = "9780441013593"
        loser.translator = "Jan Novák"
        let source = library.root.appending(path: "loser-source.epub")
        try Data("loser bytes".utf8).write(to: source)
        try library.installBookFile(from: source, fileName: loser.fileName)
        let highlight = Highlight(text: "Quote", isNote: false, location: "1", addedDate: nil)
        loser.highlights.append(highlight)
        let collection = BookCollection(name: "Shelf")
        collection.books.append(loser)
        library.context.insert(collection)
        try library.context.save()

        let service = CatalogReconciliationService(modelContext: library.context)
        await service.scanLibrary()
        let proposal = try #require(service.pendingProposals.first { $0.verdict == .sameEditionOtherFormat })
        #expect(await service.approve(proposal))
        #expect(FileManager.default.fileExists(atPath: BookFileStore.url(for: "loser.epub").path(percentEncoded: false)))
        #expect(winner.assets.contains(where: { $0.fileName == "loser.epub" }))
        #expect(winner.highlights.contains(where: { $0.text == "Quote" }))
        #expect(collection.books.contains(where: { $0.uuid == winner.uuid }))
        #expect(winner.translator == "Jan Novák")
        #expect(try library.context.fetchCount(FetchDescriptor<Book>()) == 1)
        #expect(try library.context.fetchCount(FetchDescriptor<Work>()) == 1)
    }

    @Test func mergeEditionsAbsorbsSelectionIntoTheBestEdition() async throws {
        let library = try await TestLibrary()
        let epub = insertBook(library, name: "cs-epub")
        let mobi = insertBook(library, name: "cs-mobi", format: "mobi")
        epub.isbn = "9780441013593"
        mobi.isbn = "9780441013593"
        try library.context.save()
        let service = CatalogReconciliationService(modelContext: library.context)
        _ = try #require(service.groupIntoWork([epub, mobi]))

        let survivor = try #require(await service.mergeEditions([epub, mobi]))
        #expect(survivor.uuid == mobi.uuid)
        #expect(survivor.assets.count == 2)
        #expect(try library.context.fetchCount(FetchDescriptor<Book>()) == 1)
        #expect(try library.context.fetchCount(FetchDescriptor<Work>()) == 1)
    }

    @Test func stalePreferredEditionFallsBackToBestAvailableFormat() async throws {
        let library = try await TestLibrary()
        let epub = insertBook(library, name: "epub")
        let mobi = insertBook(library, name: "mobi", format: "mobi")
        try library.context.save()
        let service = CatalogReconciliationService(modelContext: library.context)
        let work = try #require(service.groupIntoWork([epub, mobi]))
        work.preferredEditionUUID = UUID()

        #expect(WorkService.preferredEdition(in: work)?.uuid == mobi.uuid)
    }

    @Test func dismissalMemoryHidesProposalOnLaterScan() async throws {
        let library = try await TestLibrary()
        let first = insertBook(library, name: "one")
        let second = insertBook(library, name: "two", format: "pdf")
        first.isbn = "9780441013593"
        second.isbn = "9780441013593"
        try library.context.save()
        let suite = "EditionServiceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = CatalogReconciliationService(modelContext: library.context, defaults: defaults)

        await service.scanLibrary()
        let proposal = try #require(service.pendingProposals.first)
        service.dismiss(proposal)
        await service.scanLibrary()
        #expect(service.pendingProposals.isEmpty)
    }

    @Test func destructiveApprovalRevalidatesChangedHashes() async throws {
        let library = try await TestLibrary()
        let first = insertBook(library, name: "first")
        let second = insertBook(library, name: "second")
        first.assets.first?.contentHash = "identical"
        second.assets.first?.contentHash = "identical"
        try library.context.save()
        let service = CatalogReconciliationService(modelContext: library.context)
        await service.scanLibrary()
        let stale = try #require(service.pendingProposals.first(where: { $0.verdict == .duplicateFile }))

        second.assets.first?.contentHash = "replacement"
        try library.context.save()

        #expect(!(await service.approve(stale)))
        #expect(try library.context.fetchCount(FetchDescriptor<Book>()) == 2)
        #expect(!service.pendingProposals.contains(where: {
            $0.pairKey == stale.pairKey && $0.verdict == .duplicateFile
        }))
    }

    @Test func absorbPreservesTheStrongerReadingHistory() async throws {
        let library = try await TestLibrary()
        let winner = insertBook(library, name: "winner", format: "mobi")
        let loser = insertBook(library, name: "loser")
        winner.isbn = "9780441013593"
        loser.isbn = "9780441013593"
        let started = Date(timeIntervalSince1970: 100)
        let finished = Date(timeIntervalSince1970: 200)
        loser.readingStatus = .finished
        loser.dateStarted = started
        loser.dateFinished = finished
        try library.context.save()

        let service = CatalogReconciliationService(modelContext: library.context)
        await service.scanLibrary()
        let proposal = try #require(service.pendingProposals.first { $0.verdict == .sameEditionOtherFormat })
        #expect(await service.approve(proposal))

        #expect(winner.readingStatus == .finished)
        #expect(winner.dateStarted == started)
        #expect(winner.dateFinished == finished)
    }

    @Test func absorbReparentsEveryReadingCycle() async throws {
        let library = try await TestLibrary()
        let winner = insertBook(library, name: "winner", format: "mobi")
        let loser = insertBook(library, name: "loser")
        winner.isbn = "9780441013593"
        loser.isbn = "9780441013593"
        loser.setStatus(.reading, at: Date(timeIntervalSince1970: 100))
        loser.setStatus(.finished, at: Date(timeIntervalSince1970: 200))
        loser.setStatus(.reading, at: Date(timeIntervalSince1970: 300))
        try library.context.save()

        let service = CatalogReconciliationService(modelContext: library.context)
        await service.scanLibrary()
        let proposal = try #require(service.pendingProposals.first { $0.verdict == .sameEditionOtherFormat })
        #expect(await service.approve(proposal))

        #expect(winner.readingSessions.count == 2)
        #expect(winner.readingSessions.allSatisfy { $0.book?.uuid == winner.uuid })
        #expect(winner.readingStatus == .reading)
        #expect(winner.dateStarted == Date(timeIntervalSince1970: 300))
        #expect(try library.context.fetchCount(FetchDescriptor<ReadingSession>()) == 2)
    }

    @Test func absorbingOneBookRemovesEveryProposalThatReferencesIt() async throws {
        let library = try await TestLibrary()
        let books = [
            insertBook(library, name: "one"),
            insertBook(library, name: "two"),
            insertBook(library, name: "three")
        ]
        let bytes = Data("same content".utf8)
        for book in books {
            try bytes.write(to: BookFileStore.url(for: book.fileName))
            book.assets.first?.contentHash = try ContentHasher.sha256(
                of: BookFileStore.url(for: book.fileName)
            )
        }
        try library.context.save()
        let service = CatalogReconciliationService(modelContext: library.context)
        await service.scanLibrary()
        let proposal = try #require(service.pendingProposals.first)

        #expect(await service.approve(proposal))

        let remaining = Set(library.context.allBooks().map(\.uuid))
        #expect(service.pendingProposals.allSatisfy { proposal in
            proposal.memberUUIDs.allSatisfy(remaining.contains)
        })
    }

    @Test func exactMatchPreventsAutomaticWorkAssignmentAndStaysReviewable() async throws {
        let library = try await TestLibrary()
        let newBook = insertBook(library, name: "new")
        let duplicate = insertBook(library, name: "duplicate")
        let sameWork = insertBook(library, name: "translation", title: "Duna")
        newBook.assets.first?.contentHash = "duplicate-content"
        duplicate.assets.first?.contentHash = "duplicate-content"
        newBook.work?.openLibraryWorkKey = "/works/OL1W"
        sameWork.work?.openLibraryWorkKey = "/works/OL1W"
        let originalWorkUUID = try #require(newBook.work?.uuid)
        try library.context.save()
        let service = CatalogReconciliationService(modelContext: library.context)

        service.evaluate(newBook)

        #expect(newBook.work?.uuid == originalWorkUUID)
        #expect(service.pendingProposals.contains(where: {
            $0.verdict == .duplicateFile && $0.memberUUIDs.contains(newBook.uuid)
        }))
    }

    @Test func batchEvaluationNeverGroupsNonHashMatchesAutomatically() async throws {
        let library = try await TestLibrary()
        let existing = insertBook(library, name: "existing", title: "Original")
        let first = insertBook(library, name: "first", title: "Translation One")
        let second = insertBook(library, name: "second", title: "Translation Two")
        for book in [existing, first, second] {
            book.work?.openLibraryWorkKey = "/works/OL-BATCH"
        }
        let firstWorkUUID = try #require(first.work?.uuid)
        let secondWorkUUID = try #require(second.work?.uuid)
        try library.context.save()
        let service = CatalogReconciliationService(modelContext: library.context)

        service.evaluate([first, second])

        #expect(first.work?.uuid == firstWorkUUID)
        #expect(second.work?.uuid == secondWorkUUID)
        #expect(service.pendingProposals.contains { proposal in
            proposal.verdict == .sameWorkOtherEdition
                && proposal.memberUUIDs.contains(existing.uuid)
                && proposal.memberUUIDs.contains(first.uuid)
        })
    }

    @Test func catalogDeltaRefreshFetchesAndEvaluatesOnlyChangedBook() async throws {
        let library = try await TestLibrary()
        let existing = insertBook(
            library,
            name: "indexed-existing",
            title: "Indexed Title",
            author: "Indexed Author"
        )
        for index in 0..<250 {
            _ = insertBook(
                library,
                name: "unrelated-\(index)",
                title: "Unrelated \(index)",
                author: "Author \(index)"
            )
        }
        try library.context.save()
        let service = CatalogReconciliationService(modelContext: library.context)
        #expect(service.lastIndexSynchronizationFetchCount == 251)

        let changed = insertBook(
            library,
            name: "indexed-changed",
            title: "Indexed Title",
            author: "Indexed Author",
            format: "mobi"
        )
        try library.context.saveAndPublish(
            affectedBookIDs: [changed.uuid],
            changesBookMembership: true
        )

        service.refreshEditionCounts()

        #expect(service.lastIndexSynchronizationFetchCount == 1)
        #expect(service.lastEvaluationComparisonCount == 1)
        #expect(service.pendingProposals.contains { proposal in
            proposal.memberUUIDs.contains(existing.uuid)
                && proposal.memberUUIDs.contains(changed.uuid)
        })

        let stalePair = EditionMatcher.pairKey(existing.uuid, changed.uuid)
        changed.title = "A Completely Different Title"
        changed.work?.title = changed.title
        changed.work?.refreshMatchKey()
        try library.context.saveAndPublish(affectedBookIDs: [changed.uuid])
        service.refreshEditionCounts()

        #expect(service.lastIndexSynchronizationFetchCount == 1)
        #expect(!service.pendingProposals.contains { $0.pairKey == stalePair })
    }

    @Test func incrementalCountsStayConsistentAfterGroupingAndDelete() async throws {
        let library = try await TestLibrary()
        let first = insertBook(library, name: "count-first")
        let second = insertBook(library, name: "count-second")
        try library.context.save()
        let service = CatalogReconciliationService(modelContext: library.context)

        _ = try #require(service.groupIntoWork([first, second]))

        #expect(service.editionCounts[first.uuid] == 2)
        #expect(service.editionCounts[second.uuid] == 2)
        #expect(service.lastIndexSynchronizationFetchCount == 2)

        second.work = nil
        library.context.delete(second)
        try library.context.saveAndPublish(
            affectedBookIDs: [second.uuid],
            changesBookMembership: true
        )
        service.refreshEditionCounts()

        #expect(service.editionCounts[first.uuid] == nil)
        #expect(service.editionCounts[second.uuid] == nil)
        #expect(service.lastIndexSynchronizationFetchCount == 0)
    }

    @Test func sameEditionApprovalRetainsEveryBookAssetAndPhysicalFile() async throws {
        let library = try await TestLibrary()
        let epub = insertBook(library, name: "edition-epub")
        let mobi = insertBook(library, name: "edition-mobi", format: "mobi")
        epub.isbn = "9780441013593"
        mobi.isbn = "9780441013593"
        try Data("epub bytes".utf8).write(to: BookFileStore.url(for: epub.fileName))
        try Data("mobi bytes".utf8).write(to: BookFileStore.url(for: mobi.fileName))
        epub.assets.first?.contentHash = try ContentHasher.sha256(of: BookFileStore.url(for: epub.fileName))
        mobi.assets.first?.contentHash = try ContentHasher.sha256(of: BookFileStore.url(for: mobi.fileName))
        try library.context.save()
        let service = CatalogReconciliationService(modelContext: library.context)

        await service.scanLibrary()
        let proposal = try #require(service.pendingProposals.first {
            $0.verdict == .sameEditionOtherFormat
        })

        #expect(await service.approve(proposal))
        let survivor = try #require(try library.context.fetch(FetchDescriptor<Book>()).first)
        #expect(Set(survivor.assets.map(\.fileName)) == [epub.fileName, mobi.fileName])
        #expect(FileManager.default.fileExists(atPath: BookFileStore.url(for: epub.fileName).path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: BookFileStore.url(for: mobi.fileName).path(percentEncoded: false)))
    }

    @Test func translationApprovalGroupsEditionsWithoutRemovingBooksOrFiles() async throws {
        let library = try await TestLibrary()
        let english = insertBook(library, name: "translation-en")
        let czech = insertBook(library, name: "translation-cs")
        english.language = "en"
        czech.language = "cs"
        czech.translator = "Jan Novák"
        try Data("english".utf8).write(to: BookFileStore.url(for: english.fileName))
        try Data("czech".utf8).write(to: BookFileStore.url(for: czech.fileName))
        try library.context.save()
        let service = CatalogReconciliationService(modelContext: library.context)

        await service.scanLibrary()
        let proposal = try #require(service.pendingProposals.first {
            $0.verdict == .sameWorkOtherEdition
        })

        #expect(await service.approve(proposal))
        let storedBooks = try library.context.fetch(FetchDescriptor<Book>())
        #expect(storedBooks.count == 2)
        #expect(Set(storedBooks.compactMap { $0.work?.uuid }).count == 1)
        #expect(await service.mergeEditions(storedBooks) == nil)
        #expect(try library.context.fetchCount(FetchDescriptor<Book>()) == 2)
        #expect(FileManager.default.fileExists(atPath: BookFileStore.url(for: english.fileName).path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: BookFileStore.url(for: czech.fileName).path(percentEncoded: false)))
    }

    @Test func similarTitleDifferentAuthorCannotBeApproved() async throws {
        let library = try await TestLibrary()
        let first = insertBook(library, name: "similar-one", author: "Author One")
        let second = insertBook(library, name: "similar-two", author: "Author Two")
        try library.context.save()
        let service = CatalogReconciliationService(modelContext: library.context)

        await service.scanLibrary()
        let proposal = try #require(service.pendingProposals.first { $0.verdict == .similarItem })

        #expect(!(await service.approve(proposal)))
        #expect(try library.context.fetchCount(FetchDescriptor<Book>()) == 2)
        #expect(first.assets.count == 1)
        #expect(second.assets.count == 1)
    }

    @Test func exactDuplicateCleanupIsJournaledAndResumesAfterFailure() async throws {
        let library = try await TestLibrary()
        let retained = insertBook(library, name: "retained", format: "mobi")
        let redundant = insertBook(library, name: "redundant")
        let retainedFileName = retained.fileName
        let redundantFileName = redundant.fileName
        let bytes = Data("identical bytes".utf8)
        try bytes.write(to: BookFileStore.url(for: retainedFileName))
        try bytes.write(to: BookFileStore.url(for: redundantFileName))
        let hash = try ContentHasher.sha256(of: BookFileStore.url(for: retainedFileName))
        retained.assets.first?.contentHash = hash
        redundant.assets.first?.contentHash = hash
        try library.context.save()
        let coordinator = makeCoordinator { point in
            if case .duringCleanup = point { throw InjectedFailure() }
        }
        let mutations = CatalogMutationService(
            modelContext: library.context,
            managedFiles: coordinator
        )
        let service = CatalogReconciliationService(
            modelContext: library.context,
            mutations: mutations,
            managedFiles: coordinator
        )

        await service.scanLibrary()
        let proposal = try #require(service.pendingProposals.first { $0.verdict == .duplicateFile })

        #expect(await service.approve(proposal))
        #expect(try library.context.fetchCount(FetchDescriptor<Book>()) == 1)
        #expect(FileManager.default.fileExists(atPath: BookFileStore.url(for: redundantFileName).path(percentEncoded: false)))
        #expect(await coordinator.pendingTransactions().count == 1)

        let recoveringCoordinator = makeCoordinator()
        let recovery = await CatalogMutationService(
            modelContext: library.context,
            managedFiles: recoveringCoordinator
        ).recoverManagedFiles()

        #expect(recovery.completedTransactionIDs.count == 1)
        #expect(!FileManager.default.fileExists(atPath: BookFileStore.url(for: redundantFileName).path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: BookFileStore.url(for: retainedFileName).path(percentEncoded: false)))
    }

    @Test func storedHashWithoutMatchingBytesCannotAuthorizeMergeOrDeletion() async throws {
        let library = try await TestLibrary()
        let retained = insertBook(library, name: "stored-hash-retained", format: "mobi")
        let changed = insertBook(library, name: "stored-hash-changed")
        let retainedFileName = retained.fileName
        let changedFileName = changed.fileName
        try Data("original bytes".utf8).write(to: BookFileStore.url(for: retainedFileName))
        try Data("different bytes".utf8).write(to: BookFileStore.url(for: changedFileName))
        let staleHash = try ContentHasher.sha256(of: BookFileStore.url(for: retainedFileName))
        retained.assets.first?.contentHash = staleHash
        changed.assets.first?.contentHash = staleHash
        try library.context.save()
        let service = CatalogReconciliationService(modelContext: library.context)

        await service.scanLibrary()
        let proposal = try #require(service.pendingProposals.first { $0.verdict == .duplicateFile })

        #expect(!(await service.approve(proposal)))
        #expect(try library.context.fetchCount(FetchDescriptor<Book>()) == 2)
        #expect(try Data(contentsOf: BookFileStore.url(for: retainedFileName)) == Data("original bytes".utf8))
        #expect(try Data(contentsOf: BookFileStore.url(for: changedFileName)) == Data("different bytes".utf8))
    }

    @Test func fileChangingAfterVerificationIsLeftForReviewInsteadOfDeleted() async throws {
        let library = try await TestLibrary()
        let retained = insertBook(library, name: "race-retained", format: "mobi")
        let redundant = insertBook(library, name: "race-redundant")
        let retainedFileName = retained.fileName
        let redundantFileName = redundant.fileName
        let identicalBytes = Data("initially identical".utf8)
        try identicalBytes.write(to: BookFileStore.url(for: retainedFileName))
        try identicalBytes.write(to: BookFileStore.url(for: redundantFileName))
        let hash = try ContentHasher.sha256(of: BookFileStore.url(for: retainedFileName))
        retained.assets.first?.contentHash = hash
        redundant.assets.first?.contentHash = hash
        try library.context.save()
        let changedBytes = Data("changed after review".utf8)
        let redundantURL = BookFileStore.url(for: redundantFileName)
        let coordinator = makeCoordinator { point in
            if case .afterCatalogSave = point {
                try changedBytes.write(to: redundantURL)
            }
        }
        let mutations = CatalogMutationService(
            modelContext: library.context,
            managedFiles: coordinator
        )
        let service = CatalogReconciliationService(
            modelContext: library.context,
            mutations: mutations,
            managedFiles: coordinator
        )

        await service.scanLibrary()
        let proposal = try #require(service.pendingProposals.first { $0.verdict == .duplicateFile })

        #expect(await service.approve(proposal))
        #expect(try library.context.fetchCount(FetchDescriptor<Book>()) == 1)
        #expect(try Data(contentsOf: redundantURL) == changedBytes)
        #expect(await coordinator.pendingTransactions().count == 1)
    }

    @Test func reconciliationSaveFailureRestoresBooksRelationshipsAndFiles() async throws {
        let library = try await TestLibrary()
        let epub = insertBook(library, name: "failed-epub")
        let mobi = insertBook(library, name: "failed-mobi", format: "mobi")
        epub.isbn = "9780441013593"
        mobi.isbn = "9780441013593"
        try Data("epub".utf8).write(to: BookFileStore.url(for: epub.fileName))
        try Data("mobi".utf8).write(to: BookFileStore.url(for: mobi.fileName))
        try library.context.save()
        let coordinator = makeCoordinator()
        let mutations = CatalogMutationService(
            modelContext: library.context,
            saveAdapter: CatalogSaveAdapter { _ in throw InjectedFailure() },
            managedFiles: coordinator
        )
        let service = CatalogReconciliationService(
            modelContext: library.context,
            mutations: mutations,
            managedFiles: coordinator
        )
        await service.scanLibrary()
        let proposal = try #require(service.pendingProposals.first {
            $0.verdict == .sameEditionOtherFormat
        })

        #expect(!(await service.approve(proposal)))
        #expect(try library.context.fetchCount(FetchDescriptor<Book>()) == 2)
        #expect(try library.context.fetchCount(FetchDescriptor<BookAsset>()) == 2)
        #expect(epub.assets.count == 1)
        #expect(mobi.assets.count == 1)
        #expect(!library.context.hasChanges)
        #expect(await coordinator.pendingTransactions().isEmpty)
        #expect(FileManager.default.fileExists(atPath: BookFileStore.url(for: epub.fileName).path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: BookFileStore.url(for: mobi.fileName).path(percentEncoded: false)))
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
}
