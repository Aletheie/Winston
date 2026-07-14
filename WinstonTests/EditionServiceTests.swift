import Foundation
import SwiftData
import Testing
@testable import Winston

@Suite("Edition service", .serialized)
@MainActor
struct EditionServiceTests {
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

        let service = EditionService(modelContext: library.context)
        let merged = try #require(service.groupIntoWork([first, second]))
        #expect(merged.editions.count == 2)
        #expect(merged.title != nil)
        #expect(try library.context.fetchCount(FetchDescriptor<Work>()) == 1)
        #expect(service.editionCounts[first.uuid] == 2)
        #expect(service.editionCounts[second.uuid] == 2)
    }

    @Test func absorbKeepsFilesAndReparentsAssetsHighlightsAndCollections() async throws {
        let library = try await TestLibrary()
        let winner = insertBook(library, name: "winner")
        let loser = insertBook(library, name: "loser", format: "mobi")
        loser.translator = "Jan Novák"
        let source = library.root.appending(path: "loser-source.mobi")
        try Data("loser bytes".utf8).write(to: source)
        try library.installBookFile(from: source, fileName: loser.fileName)
        let highlight = Highlight(text: "Quote", isNote: false, location: "1", addedDate: nil)
        loser.highlights.append(highlight)
        let collection = BookCollection(name: "Shelf")
        collection.books.append(loser)
        library.context.insert(collection)
        try library.context.save()

        let service = EditionService(modelContext: library.context)
        #expect(service.absorb(loser, into: winner))
        #expect(FileManager.default.fileExists(atPath: BookFileStore.url(for: "loser.mobi").path(percentEncoded: false)))
        #expect(winner.assets.contains(where: { $0.fileName == "loser.mobi" }))
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
        try library.context.save()
        let service = EditionService(modelContext: library.context)
        _ = try #require(service.groupIntoWork([epub, mobi]))

        let survivor = try #require(service.mergeEditions([epub, mobi]))
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
        let service = EditionService(modelContext: library.context)
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
        let service = EditionService(modelContext: library.context, defaults: defaults)

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
        let service = EditionService(modelContext: library.context)
        await service.scanLibrary()
        let stale = try #require(service.pendingProposals.first(where: { $0.verdict == .duplicateFile }))

        second.assets.first?.contentHash = "replacement"
        try library.context.save()

        #expect(!service.approve(stale))
        #expect(try library.context.fetchCount(FetchDescriptor<Book>()) == 2)
        #expect(!service.pendingProposals.contains(where: {
            $0.pairKey == stale.pairKey && $0.verdict == .duplicateFile
        }))
    }

    @Test func absorbPreservesTheStrongerReadingHistory() async throws {
        let library = try await TestLibrary()
        let winner = insertBook(library, name: "winner", format: "mobi")
        let loser = insertBook(library, name: "loser")
        let started = Date(timeIntervalSince1970: 100)
        let finished = Date(timeIntervalSince1970: 200)
        loser.readingStatus = .finished
        loser.dateStarted = started
        loser.dateFinished = finished
        try library.context.save()

        let service = EditionService(modelContext: library.context)
        #expect(service.absorb(loser, into: winner))

        #expect(winner.readingStatus == .finished)
        #expect(winner.dateStarted == started)
        #expect(winner.dateFinished == finished)
    }

    @Test func absorbingOneBookRemovesEveryProposalThatReferencesIt() async throws {
        let library = try await TestLibrary()
        let books = [
            insertBook(library, name: "one"),
            insertBook(library, name: "two"),
            insertBook(library, name: "three")
        ]
        for book in books { book.assets.first?.contentHash = "same-content" }
        try library.context.save()
        let service = EditionService(modelContext: library.context)
        await service.scanLibrary()
        let proposal = try #require(service.pendingProposals.first)

        #expect(service.approve(proposal))

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
        let service = EditionService(modelContext: library.context)

        let undo = service.evaluate(newBook)

        #expect(undo == nil)
        #expect(newBook.work?.uuid == originalWorkUUID)
        #expect(service.pendingProposals.contains(where: {
            $0.verdict == .duplicateFile && $0.memberUUIDs.contains(newBook.uuid)
        }))
    }
}
