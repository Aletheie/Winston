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

    @Test func catalogJournalPreservesAffectedBookIDs() {
        let log = LibraryMutationLog()
        let before = log.catalogRevision
        let first = UUID()
        let second = UUID()

        log.bump(affectedBookIDs: [first])
        log.bump(affectedBookIDs: [second])

        let delta = log.catalogDelta(since: before)
        #expect(delta.toRevision == before + 2)
        #expect(delta.affectedBookIDs == [first, second])
        #expect(!delta.requiresFullRebuild)
        #expect(!delta.changesBookMembership)
    }

    @Test func fullTextJournalIgnoresUnrelatedCatalogChangesAndPreservesAssetIDs() {
        let log = LibraryMutationLog()
        let before = log.fullTextRevision
        let assetBookID = UUID()

        log.bump(affectedBookIDs: [UUID()])
        #expect(log.fullTextRevision == before)

        log.bump(
            affectedBookIDs: [assetBookID],
            fullTextAffectedBookIDs: [assetBookID]
        )
        let delta = log.fullTextDelta(since: before)
        #expect(delta.toRevision == before + 1)
        #expect(delta.affectedBookIDs == [assetBookID])
        #expect(!delta.requiresFullRebuild)
    }

    @Test func mutationCommandsOnlyInvalidateFullTextWhenIndexedContentCanChange() {
        #expect(!CatalogMutationCommand.setReadingStatus(
            bookIDs: [UUID()],
            status: .finished
        ).changesFullTextIndex)
        #expect(!CatalogMutationCommand.updateMetadata(
            bookID: UUID(),
            fields: ["rating", "notes"]
        ).changesFullTextIndex)
        #expect(CatalogMutationCommand.updateMetadata(
            bookID: UUID(),
            fields: ["title"]
        ).changesFullTextIndex)
        #expect(!CatalogMutationCommand.updateWork(
            workID: UUID(),
            fields: ["preferredEditionUUID"]
        ).changesFullTextIndex)
        #expect(CatalogMutationCommand.updateWork(
            workID: UUID(),
            fields: ["author"]
        ).changesFullTextIndex)
        #expect(CatalogMutationCommand.replaceFile(
            bookID: UUID(),
            assetID: UUID()
        ).changesFullTextIndex)
    }

    @Test func workIdentityChangeInvalidatesEveryEditionForFullTextMetadata() async throws {
        let lib = try await TestLibrary()
        let work = Work(title: "Original")
        let first = Book(fileName: "first.epub", originalFileName: "First.epub")
        let second = Book(fileName: "second.epub", originalFileName: "Second.epub")
        lib.context.insert(work)
        lib.context.insert(first)
        lib.context.insert(second)
        first.work = work
        second.work = work
        try lib.context.save()
        let mutations = CatalogMutationService(modelContext: lib.context)
        let before = LibraryMutationLog.shared.fullTextRevision

        try mutations.commit(
            .updateWork(workID: work.uuid, fields: ["title"]),
            affectedWorkIDs: [work.uuid]
        ) {
            work.title = "Updated"
        }

        let delta = LibraryMutationLog.shared.fullTextDelta(since: before)
        #expect(delta.affectedBookIDs == [first.uuid, second.uuid])
        #expect(!delta.requiresFullRebuild)
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
        book.tags = ["scifi"]
        try lib.context.save()
        expectBump("renameTag") {
            viewModel.renameTag("scifi", to: "sci-fi")
        }
        expectBump("createCollection") { _ = viewModel.createCollection(named: "Shelf") }
        await viewModel.removeBooks([book])
        #expect(LibraryMutationLog.shared.revision > last, "removeBooks did not bump the revision")
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
        await viewModel.remove(book)

        #expect(!FileManager.default.fileExists(atPath: primary.fileURL.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: sibling.fileURL.path(percentEncoded: false)))
        #expect(try lib.context.fetch(FetchDescriptor<Book>()).isEmpty)
        #expect(try lib.context.fetch(FetchDescriptor<Work>()).isEmpty)
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
