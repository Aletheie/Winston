import Foundation
import SwiftData
import Testing
@testable import Winston

@Suite("Editions backfill", .serialized)
@MainActor
struct EditionsBackfillTests {
    @Test func createsSingletonWorkAndPrimaryAssetAndIsIdempotent() async throws {
        let library = try await TestLibrary()
        let book = Book(fileName: "book.epub", originalFileName: "Book.epub")
        book.title = "Book"
        book.author = "Author"
        book.fileSizeBytes = 123
        library.context.insert(book)
        try library.context.save()

        #expect(EditionsBackfill.run(context: library.context) == 2)
        #expect(book.work?.title == "Book")
        #expect(book.work?.preferredEditionUUID == book.uuid)
        #expect(book.assets.count == 1)
        #expect(book.assets.first?.uuid == book.uuid)
        #expect(book.assets.first?.fileName == book.fileName)
        #expect(book.assets.first?.sizeBytes == 123)

        #expect(EditionsBackfill.run(context: library.context) == 0)
        #expect(try library.context.fetchCount(FetchDescriptor<Work>()) == 1)
        #expect(try library.context.fetchCount(FetchDescriptor<BookAsset>()) == 1)
    }

    @Test func healsPartiallyRestoredRows() async throws {
        let library = try await TestLibrary()
        let book = Book(fileName: "restored.pdf", originalFileName: "Restored.pdf")
        let existingWork = Work(title: "Restored")
        library.context.insert(book)
        library.context.insert(existingWork)
        book.work = existingWork
        try library.context.save()

        #expect(EditionsBackfill.run(context: library.context) == 1)
        #expect(book.work?.uuid == existingWork.uuid)
        #expect(book.assets.count == 1)
    }

    @Test func prunesOnlyOrphanWorks() async throws {
        let library = try await TestLibrary()
        let orphan = Work(title: "Orphan")
        let retained = Work(title: "Retained")
        let book = Book(fileName: "book.epub", originalFileName: "Book.epub")
        library.context.insert(orphan)
        library.context.insert(retained)
        library.context.insert(book)
        book.work = retained
        try library.context.save()

        #expect(EditionsBackfill.pruneOrphanWorks(context: library.context) == 1)
        let works = try library.context.fetch(FetchDescriptor<Work>())
        #expect(works.map(\.uuid) == [retained.uuid])
    }

    @Test func recoversLegacyPrimarySizeIntoBothBookAndAsset() async throws {
        let library = try await TestLibrary()
        let source = library.root.appending(path: "legacy-source.epub")
        let bytes = Data("legacy bytes".utf8)
        try bytes.write(to: source)
        let book = Book(fileName: "legacy.epub", originalFileName: "Legacy.epub")
        book.fileSizeBytes = 0
        try library.installBookFile(from: source, fileName: book.fileName)
        library.context.insert(book)
        try library.context.save()

        _ = EditionsBackfill.run(context: library.context)

        #expect(book.fileSizeBytes == Int64(bytes.count))
        #expect(book.assets.first?.sizeBytes == Int64(bytes.count))
    }
}
