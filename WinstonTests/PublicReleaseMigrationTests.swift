import Foundation
import SwiftData
import Testing
@testable import Winston

private final class PublicReleaseFixtureBundleMarker: NSObject {}

@MainActor
@Suite("Public release migrations", .serialized)
struct PublicReleaseMigrationTests {
    @Test func `Version 0.1 catalog opens and completes the 0.2 backfill`() throws {
        let fixture = try #require(
            Bundle(for: PublicReleaseFixtureBundleMarker.self).url(
                forResource: "Winston-v0.1",
                withExtension: "store"
            )
        )
        let root = FileManager.default.temporaryDirectory.appending(
            path: "Winston-v0.1-migration-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appending(path: "Winston.store")
        try FileManager.default.copyItem(at: fixture, to: storeURL)

        let (container, recovery) = PersistenceController.makeContainer(storeURL: storeURL)
        #expect(recovery == nil)
        let context = container.mainContext
        context.autosaveEnabled = false

        #expect(try context.fetchCount(FetchDescriptor<Book>()) == 2)
        #expect(try context.fetchCount(FetchDescriptor<BookCollection>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<Highlight>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<WishlistItem>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<Work>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<BookAsset>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ReadingSession>()) == 0)

        #expect(try EditionsBackfill.run(context: context) > 0)
        #expect(try ReadingHistoryBackfill.run(context: context) == 2)

        var descriptor = FetchDescriptor<Book>(sortBy: [SortDescriptor(\Book.uuid)])
        descriptor.relationshipKeyPathsForPrefetching = [
            \Book.assets,
            \Book.collections,
            \Book.highlights,
            \Book.readingSessions,
            \Book.work,
        ]
        let books = try context.fetch(descriptor)
        let leftHand = try #require(books.first {
            $0.uuid == UUID(uuidString: "11111111-1111-4111-8111-111111111111")
        })
        #expect(leftHand.title == "The Left Hand of Darkness")
        #expect(leftHand.author == "Ursula K. Le Guin")
        #expect(leftHand.publisher == "Ace")
        #expect(leftHand.year == "1969")
        #expect(leftHand.language == "en")
        #expect(leftHand.isbn == "9780441478125")
        #expect(leftHand.series == "Hainish Cycle")
        #expect(leftHand.seriesIndex == "4")
        #expect(leftHand.tags == ["science fiction", "classic"])
        #expect(leftHand.bookDescription == "A winter journey across Gethen.")
        #expect(leftHand.rating == 5)
        #expect(leftHand.communityRating == 4.31)
        #expect(leftHand.communityRatingCount == 42_000)
        #expect(leftHand.communityRatingSource == "Hardcover")
        #expect(leftHand.readingStatus == .finished)
        #expect(leftHand.notes == "Read again in winter.")
        #expect(leftHand.fileSizeBytes == 1_234_567)
        #expect(leftHand.coverVersion == 3)
        #expect(leftHand.collections.map(\.name) == ["Favourites"])
        #expect(leftHand.highlights.map(\.text) == [
            "The only thing that makes life possible is permanent, intolerable uncertainty."
        ])
        #expect(leftHand.work?.title == leftHand.title)
        #expect(leftHand.work?.preferredEditionUUID == leftHand.uuid)
        #expect(leftHand.assets.count == 1)
        #expect(leftHand.primaryAsset?.uuid == leftHand.uuid)
        #expect(leftHand.primaryAsset?.fileName == leftHand.fileName)
        #expect(leftHand.primaryAsset?.sourceProvenance == .legacyMigration)
        #expect(leftHand.readingSessions.count == 1)
        #expect(leftHand.readingSessions.first?.status == .finished)
        #expect(leftHand.readingSessions.first?.progress == 1)

        let rur = try #require(books.first {
            $0.uuid == UUID(uuidString: "22222222-2222-4222-8222-222222222222")
        })
        #expect(rur.title == "R.U.R.")
        #expect(rur.author == "Karel Čapek")
        #expect(rur.language == "cs")
        #expect(rur.readingStatus == .reading)
        #expect(rur.readingSessions.count == 1)
        #expect(rur.readingSessions.first?.status == .reading)
        #expect(rur.readingSessions.first?.endedAt == nil)

        #expect(try context.fetchCount(FetchDescriptor<Work>()) == 2)
        #expect(try context.fetchCount(FetchDescriptor<BookAsset>()) == 2)
        #expect(try context.fetchCount(FetchDescriptor<ReadingSession>()) == 2)
        #expect(try EditionsBackfill.run(context: context) == 0)
        #expect(try ReadingHistoryBackfill.run(context: context) == 0)
    }
}
