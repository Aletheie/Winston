import Testing
import Foundation
import SwiftData
@testable import Winston

@MainActor
struct ModelRoundTripTests {

    private func makeContext() -> (ModelContainer, ModelContext) {
        let container = PersistenceController.inMemory()
        return (container, container.mainContext)
    }

    private func fetchBook(uuid: UUID, in context: ModelContext) throws -> Book? {
        try context.fetch(FetchDescriptor<Book>(predicate: #Predicate { $0.uuid == uuid })).first
    }

    @Test func collectionMembershipRoundTripsBothDirections() throws {
        let (container, context) = makeContext()
        _ = container

        let book = Book(fileName: "a.epub", originalFileName: "A.epub")
        let shelf = BookCollection(name: "Shelf")
        context.insert(book)
        context.insert(shelf)
        shelf.books.append(book)
        try context.save()

        let fetchedShelf = try #require(try context.fetch(FetchDescriptor<BookCollection>()).first)
        #expect(fetchedShelf.books.map(\.uuid) == [book.uuid])

        let fetchedBook = try #require(try fetchBook(uuid: book.uuid, in: context))
        #expect(fetchedBook.collections.map(\.name) == ["Shelf"])
    }

    @Test func deletingCollectionNullifiesButKeepsBooks() throws {
        let (container, context) = makeContext()
        _ = container

        let book = Book(fileName: "a.epub", originalFileName: "A.epub")
        let shelf = BookCollection(name: "Shelf")
        context.insert(book)
        context.insert(shelf)
        shelf.books.append(book)
        try context.save()

        context.delete(shelf)
        try context.save()

        let fetchedBook = try #require(try fetchBook(uuid: book.uuid, in: context))
        #expect(fetchedBook.collections.isEmpty)
        #expect(try context.fetchCount(FetchDescriptor<Book>()) == 1)
    }

    @Test func deletingBookCascadesItsHighlights() throws {
        let (container, context) = makeContext()
        _ = container

        let book = Book(fileName: "a.epub", originalFileName: "A.epub")
        context.insert(book)
        let highlight = Highlight(text: "Marked passage", isNote: false, location: "Location 12", addedDate: nil)
        book.highlights.append(highlight)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Highlight>()) == 1)

        context.delete(book)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Highlight>()) == 0)
    }

    @Test func duplicateUUIDUpsertsToASingleRow() throws {
        let (container, context) = makeContext()
        _ = container

        let uuid = UUID()
        context.insert(Book(uuid: uuid, fileName: "a.epub", originalFileName: "A.epub"))
        context.insert(Book(uuid: uuid, fileName: "b.epub", originalFileName: "B.epub"))
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<Book>()) == 1)
    }

    @Test func readingStatusSurvivesPersistenceAndNilRawDecodesUnread() throws {
        let (container, context) = makeContext()
        _ = container

        let book = Book(fileName: "a.epub", originalFileName: "A.epub")
        context.insert(book)
        book.setStatus(.reading)
        try context.save()

        let fetched = try #require(try fetchBook(uuid: book.uuid, in: context))
        #expect(fetched.readingStatus == .reading)
        #expect(fetched.dateStarted != nil)
        #expect(fetched.dateFinished == nil)

        fetched.readingStatusRaw = nil
        #expect(fetched.readingStatus == .unread)
    }

    @Test func applyFillsOnlyEmptyFieldsOnRefetchedBook() throws {
        let (container, context) = makeContext()
        _ = container

        let book = Book(fileName: "a.epub", originalFileName: "A.epub")
        book.title = "User Title"
        context.insert(book)
        try context.save()

        let fetched = try #require(try fetchBook(uuid: book.uuid, in: context))
        var metadata = BookMetadata()
        metadata.title = "Extracted Title"
        metadata.publisher = "Extracted Publisher"
        fetched.apply(metadata)
        try context.save()

        let refetched = try #require(try fetchBook(uuid: book.uuid, in: context))
        #expect(refetched.title == "User Title")
        #expect(refetched.publisher == "Extracted Publisher")
    }

    @Test func workAndAssetsRoundTripAndCascadeCorrectly() throws {
        let (container, context) = makeContext()
        _ = container

        let work = Work(title: "Dune", author: "Frank Herbert")
        let book = Book(fileName: "a.epub", originalFileName: "Dune.epub")
        let asset = BookAsset(fileName: "a.epub", origin: .original, sizeBytes: 42, book: book)
        context.insert(work)
        context.insert(book)
        context.insert(asset)
        book.work = work
        try context.save()

        let fetched = try #require(try fetchBook(uuid: book.uuid, in: context))
        #expect(fetched.work?.uuid == work.uuid)
        #expect(fetched.assets.map(\.uuid) == [asset.uuid])
        #expect(work.editions.map(\.uuid) == [book.uuid])

        context.delete(work)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Book>()) == 1)
        #expect(fetched.work == nil)

        context.delete(fetched)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<BookAsset>()) == 0)
    }

    @Test func nilRawEditionAndAssetValuesUseSafeDefaults() {
        let book = Book(fileName: "a.epub", originalFileName: "A.epub")
        book.editionTypeRaw = nil
        let asset = BookAsset(fileName: "a.epub")
        asset.originRaw = nil
        asset.validationStatusRaw = nil

        #expect(book.editionType == .standard)
        #expect(asset.origin == .original)
        #expect(asset.validationStatus == nil)
        #expect(asset.generatedFromContentHash == nil)
    }

    @Test func pluginSnapshotIncludesEditionGroupingAndFormats() throws {
        let (container, context) = makeContext()
        _ = container
        let work = Work(title: "Dune", author: "Frank Herbert")
        let book = Book(fileName: "dune.epub", originalFileName: "Dune.epub")
        book.translator = "Jan Novák"
        let epub = BookAsset(uuid: book.uuid, fileName: "dune.epub", book: book)
        let mobi = BookAsset(fileName: "dune.mobi", origin: .generated, book: book)
        context.insert(work)
        context.insert(book)
        context.insert(epub)
        context.insert(mobi)
        book.work = work
        try context.save()

        let dto = PluginBookDTO(book)
        #expect(dto.translator == "Jan Novák")
        #expect(dto.workUUID == work.uuid.uuidString)
        #expect(dto.workTitle == "Dune")
        #expect(dto.editionCount == 1)
        #expect(dto.formats == ["epub", "mobi"])
    }
}
