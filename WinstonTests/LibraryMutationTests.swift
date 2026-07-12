import Testing
import Foundation
import SwiftData
@testable import Winston

@MainActor
@Suite(.serialized)
struct LibraryMutationTests {

    @Test func saveQuietlyBumpsTheRevision() async throws {
        let lib = try await TestLibrary()
        let before = LibraryMutationLog.shared.revision
        lib.context.insert(Book(fileName: "a.epub", originalFileName: "A.epub"))
        lib.context.saveQuietly()
        #expect(LibraryMutationLog.shared.revision == before + 1)
    }

    @Test func facadeWritesBumpTheRevision() async throws {
        let lib = try await TestLibrary()
        let viewModel = LibraryViewModel(modelContext: lib.context, settings: AppSettings(), toasts: ToastCenter())
        let book = Book(fileName: "a.epub", originalFileName: "A.epub")
        lib.context.insert(book)
        try lib.context.save()

        var last = LibraryMutationLog.shared.revision
        func expectBump(_ label: String, _ operation: () -> Void) {
            operation()
            #expect(LibraryMutationLog.shared.revision > last, "\(label) did not bump the revision")
            last = LibraryMutationLog.shared.revision
        }

        expectBump("updateRating") { viewModel.updateRating(for: book, rating: 4) }
        expectBump("setReadingStatus") { viewModel.setReadingStatus(.reading, for: [book]) }
        expectBump("renameTag") {
            book.tags = ["scifi"]
            viewModel.renameTag("scifi", to: "sci-fi")
        }
        expectBump("createCollection") { _ = viewModel.createCollection(named: "Shelf") }
        expectBump("removeBooks") { viewModel.removeBooks([book]) }
    }

    @Test func duplicateScanGroupsReorderedAuthorsOffMain() async throws {
        let lib = try await TestLibrary()
        let a = Book(fileName: "a.epub", originalFileName: "A.epub")
        a.title = "Dune"
        a.author = "Frank Herbert"
        let b = Book(fileName: "b.epub", originalFileName: "B.epub")
        b.title = "Dune"
        b.author = "Herbert, Frank"
        let c = Book(fileName: "c.epub", originalFileName: "C.epub")
        c.title = "Different Book"
        c.author = "Frank Herbert"
        for book in [a, b, c] { lib.context.insert(book) }
        try lib.context.save()

        let health = LibraryHealthService(modelContext: lib.context)
        let groups = await health.duplicateGroups()

        #expect(groups.count == 1)
        #expect(Set(groups.first?.books.map(\.uuid) ?? []) == [a.uuid, b.uuid])
    }

    @Test func duplicateRecommendationBalancesFormatMetadataAndSize() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        func candidate(_ format: String, metadata: Int, size: Int64) -> LibraryHealthService.DuplicateQualityCandidate {
            LibraryHealthService.DuplicateQualityCandidate(
                uuid: UUID(), format: format, fileSizeBytes: size,
                metadataRichness: metadata, drmProtected: false,
                isMissing: false, dateAdded: date
            )
        }

        let kindle = candidate("azw3", metadata: 4, size: 2_000)
        let sameMetadataEPUB = candidate("epub", metadata: 4, size: 2_000)
        let formatWinner = try #require(LibraryHealthService.recommend([kindle, sameMetadataEPUB]))
        #expect(formatWinner.bookUUID == kindle.uuid)
        #expect(formatWinner.reasons.contains(.preferredKindleFormat("AZW3")))

        let richEPUB = candidate("epub", metadata: 11, size: 2_000)
        let metadataWinner = try #require(LibraryHealthService.recommend([kindle, richEPUB]))
        #expect(metadataWinner.bookUUID == richEPUB.uuid)
        #expect(metadataWinner.reasons.contains(.richestMetadata))

        let small = candidate("mobi", metadata: 5, size: 1_000)
        let large = candidate("mobi", metadata: 5, size: 4_000)
        let sizeWinner = try #require(LibraryHealthService.recommend([small, large]))
        #expect(sizeWinner.bookUUID == large.uuid)
        #expect(sizeWinner.reasons.contains(.largestFile))

        let tiedA = candidate("mobi", metadata: 5, size: 1_000)
        let tiedB = candidate("mobi", metadata: 5, size: 1_000)
        let tiedWinner = try #require(LibraryHealthService.recommend([tiedA, tiedB]))
        #expect(tiedWinner.reasons == [.bestOverall])
    }

    @Test func duplicateRecommendationAvoidsMissingAndDRMCopies() throws {
        let date = Date(timeIntervalSince1970: 2_000)
        let safe = LibraryHealthService.DuplicateQualityCandidate(
            uuid: UUID(), format: "epub", fileSizeBytes: 1_000,
            metadataRichness: 2, drmProtected: false, isMissing: false, dateAdded: date
        )
        let unusable = LibraryHealthService.DuplicateQualityCandidate(
            uuid: UUID(), format: "azw3", fileSizeBytes: 10_000,
            metadataRichness: 12, drmProtected: true, isMissing: true, dateAdded: date
        )

        let result = try #require(LibraryHealthService.recommend([safe, unusable]))
        #expect(result.bookUUID == safe.uuid)
        #expect(result.reasons.contains(.availableFile))
        #expect(result.reasons.contains(.drmFree))
    }
}
