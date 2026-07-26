import Foundation
import SwiftData
import Testing
@testable import Winston

@Suite("Catalog mutation failures", .serialized)
@MainActor
struct CatalogMutationFailureTests {
    private struct InjectedSaveFailure: Error {}
    private struct InjectedCheckpointFailure: Error {}

    private var failingSaveAdapter: CatalogSaveAdapter {
        CatalogSaveAdapter { _ in throw InjectedSaveFailure() }
    }

    @Test func beforeMutationFailpointLeavesTheContextClean() async throws {
        try await assertCheckpointFailure(at: .beforeMutation)
    }

    @Test func afterMutationFailpointRestoresThePreimageAndDoesNotPublish() async throws {
        try await assertCheckpointFailure(at: .afterMutation)
    }

    @Test func staleGenerationRejectsTheCommandWithoutLeakingChanges() async throws {
        let library = try await TestLibrary()
        let book = try seedBook(in: library, title: "Original")
        let revision = LibraryMutationLog.shared.catalogRevision
        let mutations = CatalogMutationService(modelContext: library.context)
        let request = CatalogMutationRequest.updateBook(
            CatalogBookUpdate(
                bookID: book.uuid,
                patch: CatalogBookPatch(fields: [.title], title: "Changed")
            ),
            source: .manual
        )

        let result = mutations.execute(request, validatingGeneration: { false })

        guard case .failure(.staleGeneration) = result else {
            Issue.record("Expected a stale generation failure")
            return
        }
        #expect(book.title == "Original")
        #expect(!library.context.hasChanges)
        #expect(LibraryMutationLog.shared.catalogRevision == revision)
    }

    @Test func typedCommandReturnsOnlyAChangeSetAfterDurableSave() async throws {
        let library = try await TestLibrary()
        let book = try seedBook(in: library, title: "Original")
        let mutations = CatalogMutationService(modelContext: library.context)

        let result = mutations.execute(.updateBook(
            CatalogBookUpdate(
                bookID: book.uuid,
                patch: CatalogBookPatch(fields: [.title], title: "Changed")
            ),
            source: .manual
        ))

        let changeSet: CatalogChangeSet
        switch result {
        case .success(let committed):
            changeSet = committed
        case .failure(let error):
            Issue.record("Expected a successful typed mutation, got \(error)")
            return
        }
        #expect(changeSet.affectedBookIDs == [book.uuid])
        #expect(changeSet.fields.contains(.identity))
        #expect(changeSet.fields.contains(.displayMetadata))
        #expect(changeSet.fields.contains(.fullTextSource))
        #expect(book.title == "Changed")
        #expect(!library.context.hasChanges)
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

    @Test func failedPhysicalBookCreationLeavesNoBookOrWork() async throws {
        let library = try await TestLibrary()
        let toasts = ToastCenter()
        let viewModel = LibraryViewModel(
            modelContext: library.context,
            settings: AppSettings(),
            toasts: toasts,
            saveAdapter: failingSaveAdapter
        )

        let result = viewModel.addPhysicalBook(PhysicalBookDraft(
            title: "Failed Book",
            author: "Author",
            publisher: "",
            year: "",
            isbn: "",
            shelfLocation: "",
            notes: "",
            readingStatus: .unread
        ))

        #expect(result == nil)
        #expect(try library.context.fetchCount(FetchDescriptor<Book>()) == 0)
        #expect(try library.context.fetchCount(FetchDescriptor<Work>()) == 0)
        #expect(!library.context.hasChanges)
        #expect(toasts.messages.allSatisfy { $0.style != .success })
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

    @Test func failedHighlightImportLeavesNoPendingRelationshipInsert() async throws {
        let library = try await TestLibrary()
        let book = try seedBook(in: library, title: "Original")
        let mutations = CatalogMutationService(
            modelContext: library.context,
            saveAdapter: failingSaveAdapter
        )

        let result = mutations.execute(.importHighlights([
            CatalogHighlightInsertion(
                bookID: book.uuid,
                text: "A quote",
                isNote: false,
                location: "12",
                addedDate: .now
            ),
        ]))

        guard case .failure(.saveFailed) = result else {
            Issue.record("Expected highlight import persistence to fail")
            return
        }
        #expect(book.highlights.isEmpty)
        #expect(!library.context.hasChanges)

        book.notes = "unrelated"
        try library.context.save()
        let stored = try #require(try fetchBook(book.uuid, from: library.container))
        #expect(stored.highlights.isEmpty)
        #expect(stored.notes == "unrelated")
    }

    @Test func failedWorkIdentityEditRestoresEveryEditionAndMatchKey() async throws {
        let library = try await TestLibrary()
        let work = Work(title: "Original Work", author: "Original Author")
        let first = Book(fileName: "first.epub", originalFileName: "First.epub")
        first.title = "First"
        first.author = "Original Author"
        let second = Book(fileName: "second.epub", originalFileName: "Second.epub")
        second.title = "Second"
        second.author = "Original Author"
        library.context.insert(work)
        library.context.insert(first)
        library.context.insert(second)
        first.work = work
        second.work = work
        try library.context.save()
        let originalMatchKey = work.matchKey
        let viewModel = LibraryViewModel(
            modelContext: library.context,
            settings: AppSettings(),
            toasts: ToastCenter(),
            saveAdapter: failingSaveAdapter
        )

        let succeeded = viewModel.updateMetadata(
            for: first,
            title: "Changed",
            author: "Changed Author",
            publisher: nil,
            year: nil,
            series: nil,
            seriesIndex: nil,
            language: nil,
            translator: nil,
            isbn: nil,
            description: nil,
            tags: [],
            shelfLocation: nil,
            identityScope: .allEditions
        )

        #expect(!succeeded)
        #expect(first.title == "First")
        #expect(second.title == "Second")
        #expect(first.author == "Original Author")
        #expect(second.author == "Original Author")
        #expect(work.title == "Original Work")
        #expect(work.author == "Original Author")
        #expect(work.matchKey == originalMatchKey)
        #expect(!library.context.hasChanges)
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

    private func assertCheckpointFailure(
        at checkpoint: CatalogMutationCheckpoint
    ) async throws {
        let library = try await TestLibrary()
        let book = try seedBook(in: library, title: "Original")
        let revision = LibraryMutationLog.shared.catalogRevision
        let mutations = CatalogMutationService(
            modelContext: library.context,
            hooks: CatalogMutationHooks { reached in
                if reached == checkpoint { throw InjectedCheckpointFailure() }
            }
        )

        let result = mutations.execute(.updateBook(
            CatalogBookUpdate(
                bookID: book.uuid,
                patch: CatalogBookPatch(fields: [.title], title: "Changed")
            ),
            source: .manual
        ))

        guard case .failure(.checkpointFailed) = result else {
            Issue.record("Expected the injected checkpoint to fail the command")
            return
        }
        #expect(book.title == "Original")
        #expect(!library.context.hasChanges)
        #expect(LibraryMutationLog.shared.catalogRevision == revision)

        book.notes = "unrelated"
        try library.context.save()
        let stored = try #require(try fetchBook(book.uuid, from: library.container))
        #expect(stored.title == "Original")
        #expect(stored.notes == "unrelated")
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
