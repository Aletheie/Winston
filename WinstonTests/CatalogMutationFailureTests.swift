import Foundation
import SwiftData
import Testing
@testable import Winston

@Suite("Catalog mutation failures", .serialized)
@MainActor
struct CatalogMutationFailureTests {
    private struct InjectedSaveFailure: Error {}

    private var failingSaveAdapter: CatalogSaveAdapter {
        CatalogSaveAdapter { _ in throw InjectedSaveFailure() }
    }

    @Test func failedReadingStatusRollsBackAndDoesNotPublishSuccess() async throws {
        let library = try await TestLibrary()
        let book = try seedBook(in: library, title: "Original")
        let toasts = ToastCenter()
        let viewModel = LibraryViewModel(
            modelContext: library.context,
            settings: AppSettings(),
            toasts: toasts,
            saveAdapter: failingSaveAdapter
        )

        let succeeded = viewModel.setReadingStatus(.finished, for: [book])

        #expect(!succeeded)
        #expect(book.readingStatus == .unread)
        #expect(!library.context.hasChanges)
        #expect(viewModel.notices.notices.isEmpty)
        #expect(toasts.messages.allSatisfy { $0.style != .success })

        book.notes = "unrelated"
        try library.context.save()
        let stored = try #require(try fetchBook(book.uuid, from: library.container))
        #expect(stored.readingStatus == .unread)
        #expect(stored.notes == "unrelated")
    }

    @Test func failedCollectionCreationReturnsNilAndLeavesNoPendingInsert() async throws {
        let library = try await TestLibrary()
        let book = try seedBook(in: library, title: "Original")
        let viewModel = LibraryViewModel(
            modelContext: library.context,
            settings: AppSettings(),
            toasts: ToastCenter(),
            saveAdapter: failingSaveAdapter
        )

        let collection = viewModel.createCollection(named: "Failed Shelf", adding: [book])

        #expect(collection == nil)
        #expect(!library.context.hasChanges)

        book.notes = "unrelated"
        try library.context.save()
        let verification = ModelContext(library.container)
        let storedCollections = try verification.fetch(FetchDescriptor<BookCollection>())
        #expect(!storedCollections.contains { $0.name == "Failed Shelf" })
    }

    @Test func failedMetadataEditRestoresThePreimage() async throws {
        let library = try await TestLibrary()
        let book = try seedBook(in: library, title: "Original")
        let viewModel = LibraryViewModel(
            modelContext: library.context,
            settings: AppSettings(),
            toasts: ToastCenter(),
            saveAdapter: failingSaveAdapter
        )

        let succeeded = viewModel.updateMetadata(
            for: book,
            title: "Changed",
            author: nil,
            publisher: nil,
            year: nil,
            series: nil,
            seriesIndex: nil,
            language: nil,
            translator: nil,
            isbn: nil,
            description: nil,
            tags: [],
            shelfLocation: nil
        )

        #expect(!succeeded)
        #expect(book.title == "Original")
        #expect(!library.context.hasChanges)

        book.notes = "unrelated"
        try library.context.save()
        let stored = try #require(try fetchBook(book.uuid, from: library.container))
        #expect(stored.title == "Original")
        #expect(stored.notes == "unrelated")
    }

    @Test func failedEditionAssignmentRestoresTheOriginalWork() async throws {
        let library = try await TestLibrary()
        let first = seedEdition(in: library, title: "First")
        let second = seedEdition(in: library, title: "Second")
        try library.context.save()
        let originalWorkID = try #require(first.work?.uuid)
        let targetWork = try #require(second.work)
        let mutations = CatalogMutationService(
            modelContext: library.context,
            saveAdapter: failingSaveAdapter
        )
        let service = CatalogReconciliationService(modelContext: library.context, mutations: mutations)

        let assigned = service.assign(first, to: targetWork)

        #expect(assigned == nil)
        #expect(first.work?.uuid == originalWorkID)
        #expect(!library.context.hasChanges)

        first.notes = "unrelated"
        try library.context.save()
        let stored = try #require(try fetchBook(first.uuid, from: library.container))
        #expect(stored.work?.uuid == originalWorkID)
        #expect(stored.notes == "unrelated")
    }

    @Test func failedPluginUpdateReturnsAnErrorAndCannotLeakIntoALaterSave() async throws {
        let library = try await TestLibrary()
        let book = try seedBook(in: library, title: "Original")
        let mutations = CatalogMutationService(
            modelContext: library.context,
            saveAdapter: failingSaveAdapter
        )
        let host = PluginHostAPI(
            modelContext: library.context,
            settings: AppSettings(),
            toasts: ToastCenter(),
            mutations: mutations
        )
        let manifest = PluginManifest(
            id: "cz.test.failure",
            name: "Failure Test",
            version: "1.0.0",
            api: "1",
            entry: "index.js",
            permissions: [.libraryWrite],
            description: nil,
            author: nil
        )
        let session = host.openSession(for: manifest, contentDigest: "test-digest")
        let handler = host.makeHandler(
            for: manifest,
            granted: [.libraryWrite],
            session: session
        )
        let patch = PluginMetadataPatch(
            title: nil,
            author: nil,
            publisher: "Argo",
            year: nil,
            language: nil,
            translator: nil,
            isbn: nil,
            series: nil,
            seriesIndex: nil,
            description: nil,
            tags: nil
        )

        let result = await handler(.libraryUpdate(uuid: book.uuid, patch: patch))

        if case .failure(.unavailable(let message)) = result {
            #expect(message == "could not persist library changes")
        } else {
            Issue.record("Expected the plugin update to report a persistence failure")
        }
        #expect(book.publisher == nil)
        #expect(!library.context.hasChanges)

        book.notes = "unrelated"
        try library.context.save()
        let stored = try #require(try fetchBook(book.uuid, from: library.container))
        #expect(stored.publisher == nil)
        #expect(stored.notes == "unrelated")
    }

    private func seedBook(in library: TestLibrary, title: String) throws -> Book {
        let book = Book(fileName: "\(UUID().uuidString).epub", originalFileName: "\(title).epub")
        book.title = title
        library.context.insert(book)
        try library.context.save()
        return book
    }

    private func seedEdition(in library: TestLibrary, title: String) -> Book {
        let book = Book(fileName: "\(UUID().uuidString).epub", originalFileName: "\(title).epub")
        book.title = title
        let work = Work(title: title)
        work.preferredEditionUUID = book.uuid
        library.context.insert(work)
        library.context.insert(book)
        book.work = work
        return book
    }

    private func fetchBook(_ id: UUID, from container: ModelContainer) throws -> Book? {
        let context = ModelContext(container)
        return try context.fetch(
            FetchDescriptor<Book>(predicate: #Predicate { $0.uuid == id })
        ).first
    }
}
