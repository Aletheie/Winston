import Testing
import Foundation
import SwiftData
@testable import Winston

@MainActor
@Suite(.serialized)
struct LibraryMutationTests {

    @Test func commandContextPublishesStableAvailabilityAndRepeatedCommands() {
        let context = LibraryCommandContext()
        let availability = LibraryCommandAvailability(
            hasSelection: true,
            canConvert: true,
            canFetchMetadata: false,
            canSaveSearch: true
        )

        context.updateAvailability(availability)
        context.perform(.reviewEditions)
        let firstGeneration = context.requestGeneration
        context.perform(.reviewEditions)

        #expect(context.availability == availability)
        #expect(context.request == .reviewEditions)
        #expect(context.requestGeneration == firstGeneration + 1)
    }

    @Test func saveQuietlyBumpsTheRevision() async throws {
        let lib = try await TestLibrary()
        let before = LibraryMutationLog.shared.revision
        let catalogBefore = LibraryMutationLog.shared.catalogRevision
        lib.context.insert(Book(fileName: "a.epub", originalFileName: "A.epub"))
        lib.context.saveQuietly()
        #expect(LibraryMutationLog.shared.revision == before + 1)
        #expect(LibraryMutationLog.shared.catalogRevision == catalogBefore + 1)
    }

    @Test func throwingSavePublishesTheMutation() async throws {
        let lib = try await TestLibrary()
        let before = LibraryMutationLog.shared.revision
        let catalogBefore = LibraryMutationLog.shared.catalogRevision
        lib.context.insert(Book(fileName: "throwing.epub", originalFileName: "Throwing.epub"))

        try lib.context.saveAndPublish()

        #expect(LibraryMutationLog.shared.revision == before + 1)
        #expect(LibraryMutationLog.shared.catalogRevision == catalogBefore + 1)
    }

    @Test func legacyHardcoverTokenMigratesOutOfDefaults() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "hardcoverToken")
        defer {
            if let previous {
                defaults.set(previous, forKey: "hardcoverToken")
            } else {
                defaults.removeObject(forKey: "hardcoverToken")
            }
        }
        defaults.set("legacy-token", forKey: "hardcoverToken")
        let secrets = TestSecretStore()

        let settings = AppSettings(secretStore: secrets)

        #expect(settings.hardcoverToken == "legacy-token")
        #expect(secrets.string(for: AppSettings.hardcoverTokenAccount) == "legacy-token")
        #expect(defaults.string(forKey: "hardcoverToken") == nil)

        settings.hardcoverToken = "replacement"
        #expect(secrets.string(for: AppSettings.hardcoverTokenAccount) == "replacement")
        settings.hardcoverToken = ""
        #expect(secrets.string(for: AppSettings.hardcoverTokenAccount) == nil)
    }

    @Test func nonCatalogSaveDoesNotInvalidateTheLibraryUI() async throws {
        let lib = try await TestLibrary()
        let before = LibraryMutationLog.shared.revision
        let catalogBefore = LibraryMutationLog.shared.catalogRevision
        lib.context.insert(LibraryNotice(
            dedupeKey: "performance-test",
            kind: .ratingPrompt,
            bookTitle: "Test"
        ))

        lib.context.saveQuietly(catalogChanged: false)

        #expect(LibraryMutationLog.shared.revision == before + 1)
        #expect(LibraryMutationLog.shared.catalogRevision == catalogBefore)
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

    @Test func removingEditionDeletesEveryAssetAndPrunesItsWork() async throws {
        let lib = try await TestLibrary()
        let source = lib.root.appending(path: "source.epub")
        try Data("edition".utf8).write(to: source)
        let book = Book(fileName: "primary.epub", originalFileName: "Edition.epub")
        let work = Work(title: "Work")
        let primary = BookAsset(uuid: book.uuid, fileName: book.fileName, book: book)
        let sibling = BookAsset(fileName: "sibling.mobi", origin: .generated, book: book)
        try lib.installBookFile(from: source, fileName: primary.fileName)
        try lib.installBookFile(from: source, fileName: sibling.fileName)
        lib.context.insert(work)
        lib.context.insert(book)
        lib.context.insert(primary)
        lib.context.insert(sibling)
        book.work = work
        try lib.context.save()

        let viewModel = LibraryViewModel(
            modelContext: lib.context,
            settings: AppSettings(),
            toasts: ToastCenter()
        )
        viewModel.remove(book)

        #expect(!FileManager.default.fileExists(atPath: primary.fileURL.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: sibling.fileURL.path(percentEncoded: false)))
        #expect(try lib.context.fetch(FetchDescriptor<Book>()).isEmpty)
        #expect(try lib.context.fetch(FetchDescriptor<Work>()).isEmpty)
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

    @Test func duplicateRecommendationRanksAllRetainedSiblingAssets() async throws {
        let lib = try await TestLibrary()
        let richer = Book(fileName: "rich.epub", originalFileName: "Dune.epub")
        richer.title = "Dune"
        richer.author = "Frank Herbert"
        richer.fileSizeBytes = 100
        let richPrimary = BookAsset(
            uuid: richer.uuid, fileName: richer.fileName, sizeBytes: 100,
            validationStatus: .ok, book: richer
        )
        let azw3 = BookAsset(
            fileName: "rich.azw3", origin: .imported, sizeBytes: 200,
            validationStatus: .ok, book: richer
        )
        let mobiOnly = Book(fileName: "plain.mobi", originalFileName: "Dune.mobi")
        mobiOnly.title = "Dune"
        mobiOnly.author = "Frank Herbert"
        mobiOnly.fileSizeBytes = 100
        let mobi = BookAsset(
            uuid: mobiOnly.uuid, fileName: mobiOnly.fileName, sizeBytes: 100,
            validationStatus: .ok, book: mobiOnly
        )
        for model in [richer, mobiOnly] { lib.context.insert(model) }
        for asset in [richPrimary, azw3, mobi] { lib.context.insert(asset) }
        try lib.context.save()

        let groups = await LibraryHealthService(modelContext: lib.context).duplicateGroups()

        #expect(groups.first?.recommendation.bookUUID == richer.uuid)
        #expect(groups.first?.recommendation.reasons.contains(.preferredKindleFormat("AZW3")) == true)
    }
}

private final class TestSecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func string(for account: String) -> String? {
        lock.withLock { values[account] }
    }

    @discardableResult
    func set(_ value: String?, for account: String) -> Bool {
        lock.withLock { values[account] = value }
        return true
    }
}
