import Foundation
import SwiftData
import Testing
@testable import Winston

@Suite("Physical books", .serialized)
@MainActor
struct PhysicalBookTests {
    @Test func physicalOnlyBookHasNoManagedDigitalFile() {
        let first = Book(fileName: "", originalFileName: "Dune")
        let second = Book(fileName: "", originalFileName: "Dune Messiah")
        first.hasPhysicalCopy = true
        second.hasPhysicalCopy = true

        #expect(first.hasPhysicalCopy)
        #expect(!first.hasDigitalFile)
        #expect(first.primaryFileURL == nil)
        #expect(first.format == "PRINT")
        #expect(first.deviceMatchKey != second.deviceMatchKey)
        #expect(first.coverCacheURL != second.coverCacheURL)
    }

    @Test func shelfLocationParticipatesInLibrarySearch() {
        let book = Book(fileName: "", originalFileName: "Dune")
        book.hasPhysicalCopy = true
        book.shelfLocation = "Obývák B-12"

        let result = LibraryQuery.apply(
            to: [book],
            filter: .all,
            searchText: "b-12",
            sort: []
        )

        #expect(result.map(\.uuid) == [book.uuid])
    }

    @Test func viewModelCreatesPersistentPhysicalBookWithoutAsset() async throws {
        let library = try await TestLibrary()
        let toasts = ToastCenter()
        let viewModel = LibraryViewModel(
            modelContext: library.context,
            settings: AppSettings(),
            toasts: toasts
        )
        let draft = PhysicalBookDraft(
            title: "  The Left Hand of Darkness  ",
            author: "Ursula K. Le Guin",
            publisher: "Ace",
            year: "1969",
            isbn: "9780441478125",
            shelfLocation: "B-12",
            notes: "Signed copy",
            readingStatus: .reading
        )

        let book = try #require(viewModel.addPhysicalBook(draft))
        let stored = try #require(library.context.fetch(FetchDescriptor<Book>()).first)

        #expect(stored.uuid == book.uuid)
        #expect(stored.title == "The Left Hand of Darkness")
        #expect(stored.author == "Ursula K. Le Guin")
        #expect(stored.hasPhysicalCopy)
        #expect(!stored.hasDigitalFile)
        #expect(stored.shelfLocation == "B-12")
        #expect(stored.notes == "Signed copy")
        #expect(stored.readingStatus == .reading)
        #expect(stored.assets.isEmpty)
        #expect(stored.work?.preferredEditionUUID == stored.uuid)
        #expect(EditionsBackfill.run(context: library.context) == 0)
        #expect(await viewModel.scanForMissingFiles() == 0)
        #expect(!viewModel.isMissing(stored))
        #expect(toasts.messages.last?.style == .success)
    }

    @Test func attachingFirstFileKeepsPhysicalOwnershipAndCreatesPrimaryAsset() async throws {
        let library = try await TestLibrary()
        let viewModel = LibraryViewModel(
            modelContext: library.context,
            settings: AppSettings(),
            toasts: ToastCenter()
        )
        let book = try #require(viewModel.addPhysicalBook(PhysicalBookDraft(
            title: "Dune",
            author: "Frank Herbert",
            publisher: "",
            year: "",
            isbn: "",
            shelfLocation: "A-1",
            notes: "",
            readingStatus: .unread
        )))
        let source = library.root.appending(path: "Dune.epub")
        try Data("ebook".utf8).write(to: source)

        let asset = try #require(await viewModel.addFile(to: book, from: source))

        #expect(book.hasPhysicalCopy)
        #expect(book.hasDigitalFile)
        #expect(book.fileName == asset.fileName)
        #expect(book.fileSizeBytes == 5)
        #expect(book.assets.count == 1)
        #expect(book.format == "EPUB")
    }

    @Test func exportIncludesMetadataOnlyPhysicalRows() async throws {
        let library = try await TestLibrary()
        let book = Book(fileName: "", originalFileName: "Parable of the Sower")
        book.title = "Parable of the Sower"
        book.author = "Octavia E. Butler"
        book.hasPhysicalCopy = true
        book.shelfLocation = "C-4"
        let row = try #require(ExportService.rows(for: [book]).first)
        let output = library.root.appending(path: "export", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let result = LibraryExporter.export([row], to: output)
        let data = try Data(contentsOf: output.appending(path: "metadata.json"))
        let objects = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let exported = try #require(objects.first)

        #expect(result.copied == 0)
        #expect(result.failed == 0)
        #expect(exported["physicalCopy"] as? Bool == true)
        #expect(exported["shelf"] as? String == "C-4")
        #expect(exported["file"] as? String == "")
    }

    @Test func mergingPhysicalAndDigitalRecordsKeepsBothKindsOfOwnership() async throws {
        let library = try await TestLibrary()
        let physical = Book(fileName: "", originalFileName: "Dune")
        physical.title = "Dune"
        physical.author = "Frank Herbert"
        physical.publisher = "Ace"
        physical.year = "1965"
        physical.isbn = "9780441172719"
        physical.bookDescription = "A physical edition"
        physical.hasPhysicalCopy = true
        physical.shelfLocation = "A-1"
        let digital = Book(fileName: "dune.cbz", originalFileName: "Dune.cbz")
        digital.title = "Dune"
        digital.author = "Frank Herbert"
        digital.isbn = physical.isbn
        digital.assets = [BookAsset(fileName: digital.fileName, book: digital)]
        library.context.insert(physical)
        library.context.insert(digital)
        try library.context.save()
        let service = CatalogReconciliationService(modelContext: library.context)

        let merged = try #require(await service.mergeEditions([physical, digital]))

        #expect(merged.hasPhysicalCopy)
        #expect(merged.hasDigitalFile)
        #expect(merged.fileName == "dune.cbz")
        #expect(merged.shelfLocation == "A-1")
        #expect(merged.assets.count == 1)
    }
}
