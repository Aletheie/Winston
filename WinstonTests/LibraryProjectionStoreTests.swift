import Foundation
import SwiftData
import Testing
@testable import Winston

@Suite("Library projection store", .serialized)
@MainActor
struct LibraryProjectionStoreTests {
    @Test func semanticChangesFetchOnlyAffectedBooksAfterBootstrap() async throws {
        let library = try await TestLibrary()
        var target: Book?
        for index in 0..<128 {
            let book = Book(
                fileName: "projection-\(index).epub",
                originalFileName: "projection-\(index).epub",
                dateAdded: Date(timeIntervalSince1970: TimeInterval(index))
            )
            book.title = "Projection \(index)"
            library.context.insert(book)
            if index == 42 { target = book }
        }
        try library.context.save()

        let projected = LibraryProjectionStore()
        try projected.synchronize(
            context: library.context,
            delta: fullDelta(from: -1, to: 0)
        )
        #expect(projected.books.count == 128)
        #expect(projected.fullRebuildCount == 1)
        #expect(projected.lastBookFetchCount == 128)
        #expect(projected.lastQueryCount == 2)

        let targetBook = try #require(target)
        targetBook.title = "Changed projection"
        try library.context.save()
        try projected.synchronize(
            context: library.context,
            delta: LibraryCatalogDelta(
                fromRevision: 0,
                toRevision: 1,
                affectedBookIDs: [targetBook.uuid],
                affectedCollectionIDs: [],
                fields: [.identity, .displayMetadata],
                requiresFullRebuild: false,
                changesBookMembership: false
            )
        )

        #expect(projected.fullRebuildCount == 1)
        #expect(projected.lastQueryCount == 1)
        #expect(projected.lastBookFetchCount == 1)
        #expect(projected.books.first(where: { $0.uuid == targetBook.uuid })?.title
            == "Changed projection")

        let targetID = targetBook.uuid
        library.context.delete(targetBook)
        try library.context.save()
        try projected.synchronize(
            context: library.context,
            delta: LibraryCatalogDelta(
                fromRevision: 1,
                toRevision: 2,
                affectedBookIDs: [targetID],
                affectedCollectionIDs: [],
                fields: .all,
                requiresFullRebuild: false,
                changesBookMembership: true
            )
        )

        #expect(projected.books.count == 127)
        #expect(projected.fullRebuildCount == 1)
        #expect(projected.lastQueryCount == 1)
        #expect(projected.lastBookFetchCount == 0)
    }

    private func fullDelta(from: Int, to: Int) -> LibraryCatalogDelta {
        LibraryCatalogDelta(
            fromRevision: from,
            toRevision: to,
            affectedBookIDs: [],
            affectedCollectionIDs: [],
            fields: .all,
            requiresFullRebuild: true,
            changesBookMembership: true
        )
    }
}
