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

    @Test func smartShelfRulesRoundTripThroughPersistence() throws {
        let (container, context) = makeContext()
        _ = container
        let definition = SmartShelfDefinition(rules: [
            SmartShelfRule(field: .language, comparison: .isEqual, value: "cs"),
            SmartShelfRule(field: .pageCount, comparison: .lessThan, value: "300"),
        ])
        let shelf = BookCollection(name: "Short Czech Books")
        shelf.smartShelfDefinition = definition
        context.insert(shelf)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<BookCollection>()).first)
        #expect(fetched.smartShelfDefinition == definition)
        #expect(fetched.isSmart)
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

    @Test func deletingBookCascadesItsReadingHistory() throws {
        let (container, context) = makeContext()
        _ = container

        let book = Book(fileName: "a.epub", originalFileName: "A.epub")
        context.insert(book)
        book.setStatus(.reading)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<ReadingSession>()) == 1)

        context.delete(book)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<ReadingSession>()) == 0)
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

    @Test func explicitPrimaryAssetIsAuthoritativeAndRepairsCompatibilityMirror() throws {
        let (container, context) = makeContext()
        _ = container
        let book = Book(fileName: "stale.epub", originalFileName: "Book.epub")
        let first = BookAsset(fileName: "first.epub", sizeBytes: 10, book: book)
        let selected = BookAsset(fileName: "selected.pdf", sizeBytes: 42, book: book)
        context.insert(book)
        context.insert(first)
        context.insert(selected)
        book.primaryAssetUUID = selected.uuid

        #expect(book.primaryAsset?.uuid == selected.uuid)
        #expect(book.repairPrimaryAssetInvariant())
        #expect(book.fileName == "selected.pdf")
        #expect(book.fileSizeBytes == 42)
        #expect(book.format == "PDF")
    }

    @Test func assetFileFactsAreAuthoritativeAndLegacyMirrorsConverge() {
        let book = Book(fileName: "legacy.epub", originalFileName: "Book.epub")
        let asset = BookAsset(
            fileName: "authoritative.pdf",
            sizeBytes: 42,
            drmProtected: true,
            validationStatus: .ok,
            book: book
        )
        asset.formatRaw = "EPUB"
        asset.sourceProvenanceRaw = nil
        asset.availabilityRaw = nil
        book.primaryAssetUUID = asset.uuid
        book.fileSizeBytes = 7
        book.drmProtected = false
        book.coverScopeRaw = nil

        #expect(!CatalogModelInvariantService.violations(in: book).isEmpty)
        #expect(CatalogModelInvariantService.repair(book: book))

        #expect(book.explicitPrimaryAsset?.uuid == asset.uuid)
        #expect(book.fileName == asset.fileName)
        #expect(book.fileSizeBytes == 42)
        #expect(book.drmProtected == true)
        #expect(book.primaryDRMProtected == true)
        #expect(asset.format == "PDF")
        #expect(asset.sourceProvenance == .unknown)
        #expect(asset.availability == .available)
        #expect(book.coverReference.owner == .edition(book.uuid))
        #expect(CatalogModelInvariantService.violations(in: book).isEmpty)
        #expect(!CatalogModelInvariantService.repair(book: book))
    }

    @Test func switchingPrimaryAssetSwitchesPerFileDRMAndSize() {
        let book = Book(fileName: "open.epub", originalFileName: "Book.epub")
        let open = BookAsset(
            fileName: "open.epub",
            sizeBytes: 10,
            drmProtected: false,
            book: book
        )
        let locked = BookAsset(
            fileName: "locked.azw3",
            sizeBytes: 20,
            drmProtected: true,
            book: book
        )

        book.primaryAssetUUID = open.uuid
        _ = CatalogModelInvariantService.repair(book: book)
        #expect(book.primaryDRMProtected == false)
        #expect(book.fileSizeBytes == 10)

        book.primaryAssetUUID = locked.uuid
        _ = CatalogModelInvariantService.repair(book: book)
        #expect(book.primaryDRMProtected == true)
        #expect(book.drmProtected == true)
        #expect(book.fileSizeBytes == 20)
        #expect(book.fileName == "locked.azw3")
    }

    @Test func coverSelectionHasAnExplicitValidOwner() {
        let work = Work(title: "Dune")
        work.coverVersion = 3
        let book = Book(fileName: "dune.epub", originalFileName: "Dune.epub")
        let asset = BookAsset(fileName: "dune.epub", coverVersion: 4, book: book)
        book.work = work
        let editionCacheURL = book.coverCacheURL

        #expect(book.selectCoverOwner(.work(work.uuid)))
        #expect(book.coverReference == CoverReference(
            owner: .work(work.uuid),
            version: 3
        ))
        #expect(book.coverCacheURL != editionCacheURL)
        #expect(book.coverCacheURL == CoverStore.url(for: .work(work.uuid)))
        book.coverAssetUUID = asset.uuid
        #expect(CatalogModelInvariantService.violations(in: book).contains(.invalidCoverOwner))
        #expect(CatalogModelInvariantService.repair(book: book))
        #expect(book.coverAssetUUID == nil)
        #expect(book.coverReference.owner == .work(work.uuid))

        #expect(book.selectCoverOwner(.generatedAsset(asset.uuid)))
        #expect(book.coverReference == CoverReference(
            owner: .generatedAsset(asset.uuid),
            version: 4
        ))
        #expect(book.coverCacheURL == CoverStore.url(for: .generatedAsset(asset.uuid)))
        #expect(!book.selectCoverOwner(.generatedAsset(UUID())))

        book.coverAssetUUID = UUID()
        #expect(CatalogModelInvariantService.repair(book: book))
        #expect(book.coverReference.owner == .edition(book.uuid))
        #expect(book.coverCacheURL == editionCacheURL)
    }

    @Test func invalidPrimaryReferenceDoesNotHideAssetInvariantDrift() {
        let book = Book(fileName: "ghost.epub", originalFileName: "Ghost.epub")
        let asset = BookAsset(fileName: "real.epub", validationStatus: .ok, book: book)
        book.primaryAssetUUID = UUID()

        #expect(book.primaryAsset == nil)
        #expect(!book.hasCatalogDigitalFile)
        #expect(book.repairPrimaryAssetInvariant())
        #expect(book.primaryAssetUUID == asset.uuid)
        #expect(book.fileName == asset.fileName)
        #expect(book.hasCatalogDigitalFile)
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
        #expect(asset.format == "EPUB")
        #expect(asset.sourceProvenance == .unknown)
        #expect(asset.availability == .available)
    }

    @Test func libraryNoticeKindRoundTripsAndUnknownRawValueIsSafe() throws {
        let (container, context) = makeContext()
        _ = container

        let notice = LibraryNotice(
            dedupeKey: "release:42",
            kind: .newRelease,
            bookTitle: "A New Book"
        )
        context.insert(notice)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<LibraryNotice>()).first)
        #expect(fetched.kind == .newRelease)
        #expect(fetched.isUnread)

        fetched.kindRaw = "future-kind"
        #expect(fetched.kind == nil)
    }

    @Test func seriesCatalogSnapshotEncodesStableSortedSets() throws {
        let (container, context) = makeContext()
        _ = container

        let snapshot = SeriesCatalogSnapshot(seriesKey: "series", knownBookIDs: [9, 2, 5])
        context.insert(snapshot)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<SeriesCatalogSnapshot>()).first)
        #expect(fetched.knownBookIDsRaw == "2,5,9")
        #expect(fetched.knownBookIDs == [2, 5, 9])

        fetched.knownBookIDs = []
        #expect(fetched.knownBookIDsRaw.isEmpty)
        #expect(fetched.knownBookIDs.isEmpty)
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
