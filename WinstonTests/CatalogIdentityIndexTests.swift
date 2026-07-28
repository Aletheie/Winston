import SwiftData
import Testing
@testable import Winston

@Suite("Catalog identity index", .serialized)
@MainActor
struct CatalogIdentityIndexTests {
    @Test func semanticChangeSetUpdatesOneBookWithoutAnotherFullScan() async throws {
        let library = try await TestLibrary()
        let mutationLog = LibraryMutationLog()
        var targetBook: Book?
        var targetAsset: BookAsset?

        for index in 0..<128 {
            let book = Book(
                fileName: "indexed-\(index).epub",
                originalFileName: "indexed-\(index).epub"
            )
            book.title = "Indexed \(index)"
            book.author = "Author \(index)"
            let asset = BookAsset(
                fileName: book.fileName,
                contentHash: "hash-\(index)",
                book: book
            )
            library.context.insert(book)
            library.context.insert(asset)
            if index == 42 {
                targetBook = book
                targetAsset = asset
            }
        }
        try library.context.save()

        let book = try #require(targetBook)
        let asset = try #require(targetAsset)
        let index = CatalogIdentityIndex(
            modelContext: library.context,
            mutationLog: mutationLog
        )

        let initial = try index.reconciler()
        #expect(initial.contains(contentHash: "hash-42"))
        #expect(index.fullRebuildCount == 1)
        #expect(index.lastSynchronizationQueryCount == 1)
        #expect(index.lastSynchronizationFetchCount == 128)

        asset.contentHash = "updated-hash"
        try library.context.save()
        mutationLog.bump(
            affectedBookIDs: [book.uuid],
            affectedAssetIDs: [asset.uuid],
            affectedCollectionIDs: [],
            fields: [.assetAvailability]
        )

        let updated = try index.reconciler()
        #expect(!updated.contains(contentHash: "hash-42"))
        #expect(updated.contains(contentHash: "updated-hash"))
        #expect(index.fullRebuildCount == 1)
        #expect(index.lastSynchronizationQueryCount == 2)
        #expect(index.lastSynchronizationFetchCount == 2)

        library.context.delete(book)
        try library.context.save()
        mutationLog.bump(
            affectedBookIDs: [book.uuid],
            affectedCollectionIDs: [],
            fields: .all,
            changesBookMembership: true
        )

        let afterDeletion = try index.reconciler()
        #expect(!afterDeletion.contains(contentHash: "updated-hash"))
        #expect(index.fullRebuildCount == 1)
        #expect(index.lastSynchronizationQueryCount == 1)
        #expect(index.lastSynchronizationFetchCount == 0)
    }
}
