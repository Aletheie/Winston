import Testing
import Foundation
import SwiftData
import AppKit
@testable import Winston

@MainActor
@Suite(.serialized)
struct MetadataServiceTests {

    private func makeService(in lib: TestLibrary, online: any OnlineMetadataFetching) -> MetadataService {
        MetadataService(modelContext: lib.context, settings: AppSettings(), online: online)
    }

    @Test func enrichFillsOnlyEmptyFieldsAndMarksLookup() async throws {
        let lib = try await TestLibrary()
        let book = Book(fileName: "a.epub", originalFileName: "Some Novel.epub")
        book.title = "User Title"
        lib.context.insert(book)
        try lib.context.save()

        var fetched = FetchedMetadata()
        fetched.title = "Online Title"
        fetched.authors = ["Jane Doe"]
        fetched.bookDescription = "An online description."
        fetched.ratingsAverage = 4.2
        fetched.ratingsCount = 12
        fetched.ratingsSource = "Google Books"

        let service = makeService(in: lib, online: FakeOnlineClient(result: fetched))
        let matched = await service.performEnrich(book, replaceCover: false)

        #expect(matched)
        #expect(book.title == "User Title")
        #expect(book.author == "Jane Doe")
        #expect(book.bookDescription == "An online description.")
        #expect(book.communityRating == 4.2)
        #expect(book.communityRatingSource == "Google Books")
        #expect(book.onlineLookupAt != nil)
        #expect(book.onlineLookupConfiguration != nil)
    }

    @Test func noMatchOverNetworkMarksLookupSoBackfillStopsRetrying() async throws {
        let lib = try await TestLibrary()
        let book = Book(fileName: "a.epub", originalFileName: "Obscure.epub")
        lib.context.insert(book)
        try lib.context.save()

        let service = makeService(in: lib, online: FakeOnlineClient(result: nil, reachedNetwork: true))
        let matched = await service.performEnrich(book, replaceCover: false)

        #expect(!matched)
        #expect(book.onlineLookupAt != nil)
        #expect(book.onlineLookupConfiguration != nil)
    }

    @Test func enrichFillsWorkCatalogIdentifiersWithoutOverwriting() async throws {
        let lib = try await TestLibrary()
        let book = Book(fileName: "a.epub", originalFileName: "Book.epub")
        let work = Work(title: "Book")
        lib.context.insert(book)
        lib.context.insert(work)
        book.work = work
        try lib.context.save()
        var fetched = FetchedMetadata()
        fetched.title = "Book"
        fetched.openLibraryWorkKey = "/works/OL1W"
        fetched.hardcoverBookID = "12345"
        let service = makeService(in: lib, online: FakeOnlineClient(result: fetched))

        #expect(await service.performEnrich(book, replaceCover: false))
        #expect(work.openLibraryWorkKey == "/works/OL1W")
        #expect(work.hardcoverBookID == "12345")

        work.openLibraryWorkKey = "/works/KEEP"
        fetched.openLibraryWorkKey = "/works/REPLACE"
        _ = await makeService(in: lib, online: FakeOnlineClient(result: fetched))
            .performEnrich(book, replaceCover: false)
        #expect(work.openLibraryWorkKey == "/works/KEEP")
    }

    @Test func offlineLookupLeavesBookUnmarkedForRetry() async throws {
        let lib = try await TestLibrary()
        let book = Book(fileName: "a.epub", originalFileName: "Obscure.epub")
        lib.context.insert(book)
        try lib.context.save()

        let service = makeService(in: lib, online: FakeOnlineClient(result: nil, reachedNetwork: false))
        let matched = await service.performEnrich(book, replaceCover: false)

        #expect(!matched)
        #expect(book.onlineLookupAt == nil)
        #expect(book.onlineLookupConfiguration == nil)
    }

    @Test func enrichDownloadsCoverWhenMissing() async throws {
        let lib = try await TestLibrary()
        let book = Book(fileName: "a.epub", originalFileName: "Covered.epub")
        lib.context.insert(book)
        try lib.context.save()

        var fetched = FetchedMetadata()
        fetched.title = "Covered"
        fetched.coverURL = URL(string: "https://example.invalid/cover.jpg")
        let online = FakeOnlineClient(result: fetched, coverData: EPUBFixture.jpegData())

        let service = makeService(in: lib, online: online)
        let matched = await service.performEnrich(book, replaceCover: false)

        #expect(matched)
        #expect(CoverStore.load(for: book.uuid) != nil)
        #expect(book.coverVersion == 1)
    }

    @Test func backgroundEnrichmentPreservesAnExplicitWorkCover() async throws {
        let lib = try await TestLibrary()
        let work = Work(title: "Covered work")
        let book = Book(fileName: "work-cover.epub", originalFileName: "Covered Work.epub")
        lib.context.insert(work)
        lib.context.insert(book)
        book.work = work
        work.coverVersion = 3
        #expect(book.selectCoverOwner(.work(work.uuid)))
        #expect(CoverStore.restore(EPUBFixture.jpegData(), for: .work(work.uuid)))
        try lib.context.save()
        let expectedCover = try #require(CoverStore.loadData(for: .work(work.uuid)))

        var fetched = FetchedMetadata()
        fetched.title = "Covered work"
        fetched.bookDescription = "Metadata should still be applied."
        fetched.coverURL = URL(string: "https://example.invalid/edition-cover.jpg")
        let online = FakeOnlineClient(result: fetched, coverData: EPUBFixture.jpegData())
        let service = makeService(in: lib, online: online)

        #expect(await service.performEnrich(book, replaceCover: false))
        #expect(book.bookDescription == "Metadata should still be applied.")
        #expect(book.coverReference == CoverReference(owner: .work(work.uuid), version: 3))
        #expect(CoverStore.loadData(for: .work(work.uuid)) == expectedCover)
        #expect(!CoverStore.exists(for: .edition(book.uuid)))
        #expect(await online.coverDownloadCalls == 0)
    }

    @Test func lateOnlineCoverDoesNotOverwriteANewerUserCover() async throws {
        let lib = try await TestLibrary()
        let book = Book(fileName: "cover.epub", originalFileName: "Cover.epub")
        lib.context.insert(book)
        try lib.context.save()

        var fetched = FetchedMetadata()
        fetched.title = "Covered"
        fetched.coverURL = URL(string: "https://example.invalid/cover.jpg")
        let online = CoverGateOnlineClient(result: fetched, data: EPUBFixture.jpegData())
        let service = makeService(in: lib, online: online)
        let task = Task { @MainActor in
            await service.performEnrich(book, replaceCover: true)
        }

        await online.waitUntilDownloadStarted()
        let custom = NSImage(size: NSSize(width: 17, height: 23))
        custom.lockFocus()
        NSColor.systemPink.setFill()
        NSRect(origin: .zero, size: custom.size).fill()
        custom.unlockFocus()
        CoverStore.save(custom, for: book.uuid)
        book.coverVersion += 1
        try lib.context.save()
        let expected = try #require(CoverStore.loadData(for: book.uuid))

        await online.resumeDownload()
        #expect(await task.value)
        #expect(CoverStore.loadData(for: book.uuid) == expected)
    }

    @Test func changingLookupIdentityCancelsAndDiscardsTheOnlineProposal() async throws {
        let lib = try await TestLibrary()
        let book = Book(fileName: "identity.epub", originalFileName: "Identity.epub")
        book.title = "Original Title"
        book.author = "Original Author"
        book.isbn = "9780000000001"
        let work = Work(title: "Original Title", author: "Original Author")
        lib.context.insert(work)
        lib.context.insert(book)
        book.work = work
        try lib.context.save()

        var fetched = FetchedMetadata()
        fetched.title = "Stale Online Title"
        fetched.authors = ["Stale Online Author"]
        fetched.ratingsAverage = 4.9
        fetched.openLibraryWorkKey = "/works/STALE"
        let online = FetchGateOnlineClient(result: fetched)
        let service = makeService(in: lib, online: online)
        let task = Task { @MainActor in
            await service.performEnrich(book, replaceCover: false)
        }

        await online.waitUntilStarted()
        #expect(service.updateMetadata(
            for: book,
            title: "Manual Replacement",
            author: "Manual Author",
            publisher: nil,
            year: nil,
            series: nil,
            seriesIndex: nil,
            language: nil,
            translator: nil,
            isbn: "9780000000002",
            description: nil,
            tags: [],
            shelfLocation: nil
        ))
        await online.resume()

        #expect(await task.value == false)
        #expect(book.title == "Manual Replacement")
        #expect(book.author == "Manual Author")
        #expect(book.isbn == "9780000000002")
        #expect(book.communityRating == nil)
        #expect(work.openLibraryWorkKey == nil)
    }

    @Test func movingABookToAnotherWorkDiscardsTheOnlineProposal() async throws {
        let lib = try await TestLibrary()
        let book = Book(fileName: "move.epub", originalFileName: "Move.epub")
        book.title = "Stable Title"
        let originalWork = Work(title: "Original Work")
        let replacementWork = Work(title: "Replacement Work")
        lib.context.insert(originalWork)
        lib.context.insert(replacementWork)
        lib.context.insert(book)
        book.work = originalWork
        try lib.context.save()

        var fetched = FetchedMetadata()
        fetched.bookDescription = "Description from the old work lookup"
        fetched.hardcoverBookID = "stale-work-id"
        let online = FetchGateOnlineClient(result: fetched)
        let service = makeService(in: lib, online: online)
        let task = Task { @MainActor in
            await service.performEnrich(book, replaceCover: false)
        }

        await online.waitUntilStarted()
        book.work = replacementWork
        try lib.context.save()
        await online.resume()

        #expect(await task.value == false)
        #expect(book.work?.uuid == replacementWork.uuid)
        #expect(book.bookDescription == nil)
        #expect(replacementWork.hardcoverBookID == nil)
        #expect(originalWork.hardcoverBookID == nil)
    }

    @Test func identityMutationCooperativelyCancelsUnneededNetworkWork() async throws {
        let lib = try await TestLibrary()
        let book = Book(fileName: "cancel.epub", originalFileName: "Cancel.epub")
        book.title = "Before"
        lib.context.insert(book)
        try lib.context.save()

        let online = CancellationAwareOnlineClient()
        let service = makeService(in: lib, online: online)
        let task = Task { @MainActor in
            await service.performEnrich(book, replaceCover: false)
        }
        await online.waitUntilStarted()

        #expect(service.updateMetadata(
            for: book,
            title: "After",
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
        ))

        #expect(await task.value == false)
        #expect(await online.wasCancelled)
        #expect(service.enrichingUUIDs.isEmpty)
        #expect(service.analysisCoordinator.activeJobCount == 0)
    }

    @Test func readingProgressDoesNotInvalidateAnOtherwiseCurrentLookup() async throws {
        let lib = try await TestLibrary()
        let book = Book(fileName: "progress.epub", originalFileName: "Progress.epub")
        lib.context.insert(book)
        try lib.context.save()

        var fetched = FetchedMetadata()
        fetched.title = "Still Current"
        let online = FetchGateOnlineClient(result: fetched)
        let mutations = CatalogMutationService(modelContext: lib.context)
        let service = MetadataService(
            modelContext: lib.context,
            settings: AppSettings(),
            online: online,
            mutations: mutations
        )
        let task = Task { @MainActor in
            await service.performEnrich(book, replaceCover: false)
        }
        await online.waitUntilStarted()

        try mutations.commit(
            .setReadingStatus(bookIDs: [book.uuid], status: .reading),
            affectedBookIDs: [book.uuid]
        ) {
            try mutations.book(id: book.uuid).setStatus(.reading)
        }
        #expect(service.analysisCoordinator.activeJobCount == 1)
        await online.resume()

        #expect(await task.value)
        #expect(book.title == "Still Current")
        #expect(book.readingStatus == .reading)
    }

    @Test func replacingThePrimaryAssetDiscardsALatePageCount() async throws {
        let lib = try await TestLibrary()
        let source = lib.root.appending(path: "page-source.epub")
        try Data("page source".utf8).write(to: source)
        let uuid = UUID()
        let fileName = try BookFileStore.importCopy(of: source, uuid: uuid)
        let book = Book(uuid: uuid, fileName: fileName, originalFileName: "Pages.epub")
        let asset = BookAsset(
            uuid: uuid,
            fileName: fileName,
            contentHash: "original-content",
            book: book
        )
        lib.context.insert(book)
        lib.context.insert(asset)
        try lib.context.save()

        let gate = PageCountGate()
        let service = MetadataService(
            modelContext: lib.context,
            settings: AppSettings(),
            online: FakeOnlineClient(),
            estimatePageCount: { url, format in await gate.estimate(url: url, format: format) }
        )
        let task = Task { @MainActor in await service.backfillPageCount(for: book) }
        await gate.waitUntilStarted()

        asset.contentHash = "replacement-content"
        asset.dateAdded = asset.dateAdded.addingTimeInterval(1)
        try lib.context.save()
        await gate.resume(with: 321)
        await task.value

        #expect(book.pageCount == nil)
    }

    @Test func onlineProposalSaveFailureRestoresEveryChangedField() async throws {
        struct InjectedFailure: Error {}

        let lib = try await TestLibrary()
        let book = Book(fileName: "failure.epub", originalFileName: "Failure.epub")
        let work = Work(title: "Existing Work")
        lib.context.insert(work)
        lib.context.insert(book)
        book.work = work
        try lib.context.save()

        var fetched = FetchedMetadata()
        fetched.title = "Must Roll Back"
        fetched.authors = ["Must Roll Back"]
        fetched.ratingsAverage = 4.8
        fetched.openLibraryWorkKey = "/works/ROLLBACK"
        let mutations = CatalogMutationService(
            modelContext: lib.context,
            saveAdapter: CatalogSaveAdapter { _ in throw InjectedFailure() }
        )
        let service = MetadataService(
            modelContext: lib.context,
            settings: AppSettings(),
            online: FakeOnlineClient(result: fetched),
            mutations: mutations
        )

        #expect(await service.performEnrich(book, replaceCover: false) == false)
        #expect(book.title == nil)
        #expect(book.author == nil)
        #expect(book.communityRating == nil)
        #expect(book.onlineLookupAt == nil)
        #expect(work.openLibraryWorkKey == nil)
        #expect(!lib.context.hasChanges)
    }

    @Test func renameTagRewritesEveryBookAndDeduplicates() async throws {
        let lib = try await TestLibrary()
        let a = Book(fileName: "a.epub", originalFileName: "A.epub")
        a.tags = ["scifi", "space"]
        let b = Book(fileName: "b.epub", originalFileName: "B.epub")
        b.tags = ["scifi", "sci-fi"]
        let c = Book(fileName: "c.epub", originalFileName: "C.epub")
        c.tags = ["romance"]
        for book in [a, b, c] { lib.context.insert(book) }
        try lib.context.save()

        let service = makeService(in: lib, online: FakeOnlineClient())
        service.renameTag("scifi", to: "sci-fi")

        #expect(a.tags.sorted() == ["sci-fi", "space"])
        #expect(b.tags == ["sci-fi"])
        #expect(c.tags == ["romance"])
    }

    @Test func identityScopeKeepsEditionAndWorkIdentityConsistent() async throws {
        let lib = try await TestLibrary()
        let work = Work(title: "Old Work", author: "Old Author")
        let selected = Book(fileName: "selected.epub", originalFileName: "Selected.epub")
        selected.title = "Old Edition"
        selected.author = "Old Author"
        let sibling = Book(fileName: "sibling.epub", originalFileName: "Sibling.epub")
        sibling.title = "Translated Edition"
        sibling.author = "Old Author"
        for model in [selected, sibling] { lib.context.insert(model) }
        lib.context.insert(work)
        selected.work = work
        sibling.work = work
        try lib.context.save()
        let service = makeService(in: lib, online: FakeOnlineClient())

        #expect(service.updateMetadata(
            for: selected,
            title: "Correct Work",
            author: "Correct Author",
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
            identityScope: .workIdentity
        ))
        #expect(selected.title == "Correct Work")
        #expect(selected.author == "Correct Author")
        #expect(work.title == "Correct Work")
        #expect(work.author == "Correct Author")
        #expect(sibling.title == "Translated Edition")
        #expect(sibling.author == "Old Author")
        #expect(work.matchKey == BookMatchKey(
            title: "Correct Work",
            author: "Correct Author"
        ).storageValue)

        #expect(service.updateMetadata(
            for: selected,
            title: "Shared Title",
            author: "Shared Author",
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
        ))
        #expect(selected.title == "Shared Title")
        #expect(sibling.title == "Shared Title")
        #expect(selected.author == "Shared Author")
        #expect(sibling.author == "Shared Author")
        #expect(work.title == "Shared Title")
        #expect(work.author == "Shared Author")
    }

    @Test func renameSeriesAndAuthorTouchOnlyMatchingBooks() async throws {
        let lib = try await TestLibrary()
        let work = Work(title: "A", author: "Old Author")
        let a = Book(fileName: "a.epub", originalFileName: "A.epub")
        a.series = "Old Series"
        a.author = "Old Author"
        let b = Book(fileName: "b.epub", originalFileName: "B.epub")
        b.series = "Other Series"
        b.author = "Other Author"
        lib.context.insert(work)
        for book in [a, b] { lib.context.insert(book) }
        a.work = work
        try lib.context.save()

        let service = makeService(in: lib, online: FakeOnlineClient())
        service.renameSeries("Old Series", to: "New Series")
        service.renameAuthor("Old Author", to: "New Author")

        #expect(a.series == "New Series")
        #expect(a.author == "New Author")
        #expect(work.author == "New Author")
        #expect(work.matchKey == BookMatchKey(title: "A", author: "New Author").storageValue)
        #expect(b.series == "Other Series")
        #expect(b.author == "Other Author")
    }

    @Test func `Applying metadata fixes batches every rename into one save`() async throws {
        let lib = try await TestLibrary()
        let a = Book(fileName: "a.epub", originalFileName: "A.epub")
        a.author = "Herbert, Frank"
        a.series = "Zaklinac"
        let b = Book(fileName: "b.epub", originalFileName: "B.epub")
        b.author = "Herbert, Frank"
        b.series = "Zaklínač"
        let c = Book(fileName: "c.epub", originalFileName: "Orel a lev 02 - Dvoji trun.epub")
        c.title = "Dvojí trůn"
        for book in [a, b, c] { lib.context.insert(book) }
        try lib.context.save()

        let service = makeService(in: lib, online: FakeOnlineClient())
        let revision = LibraryMutationLog.shared.revision
        service.applyMetadataFixes([
            MetadataFix(
                kind: .author,
                original: "Herbert, Frank",
                suggestion: "Frank Herbert",
                bookCount: 2
            ),
            MetadataFix(
                kind: .series,
                original: "Zaklinac",
                suggestion: "Zaklínač",
                bookCount: 1
            ),
            MetadataFix(
                kind: .seriesAssignment,
                original: "Dvojí trůn",
                suggestion: "Orel a lev",
                bookCount: 1,
                bookID: c.uuid,
                seriesIndex: "2"
            ),
        ])

        #expect(LibraryMutationLog.shared.revision == revision + 1)
        #expect(a.author == "Frank Herbert")
        #expect(b.author == "Frank Herbert")
        #expect(a.series == "Zaklínač")
        #expect(b.series == "Zaklínač")
        #expect(c.series == "Orel a lev")
        #expect(c.seriesIndex == "2")
    }

    @Test func deleteTagRemovesItEverywhere() async throws {
        let lib = try await TestLibrary()
        let a = Book(fileName: "a.epub", originalFileName: "A.epub")
        a.tags = ["drop", "keep"]
        lib.context.insert(a)
        try lib.context.save()

        let service = makeService(in: lib, online: FakeOnlineClient())
        service.deleteTag("drop")

        #expect(a.tags == ["keep"])
    }

    @Test func concurrentLookupsKeepNetworkReachabilityWithTheirOwnRequest() async throws {
        let lib = try await TestLibrary()
        let offline = Book(fileName: "offline.epub", originalFileName: "Offline.epub")
        let online = Book(fileName: "online.epub", originalFileName: "Online.epub")
        lib.context.insert(offline)
        lib.context.insert(online)
        try lib.context.save()

        let service = makeService(in: lib, online: ReentrantOnlineClient())
        let offlineTask = Task { @MainActor in
            await service.performEnrich(offline, replaceCover: false)
        }
        let onlineTask = Task { @MainActor in
            await service.performEnrich(online, replaceCover: false)
        }
        _ = await (offlineTask.value, onlineTask.value)

        #expect(offline.onlineLookupAt == nil)
        #expect(online.onlineLookupAt != nil)
    }

    @Test func addingHardcoverTokenBackfillsPreviouslyQueriedMissingRatingOnce() async throws {
        let lib = try await TestLibrary()
        let settings = AppSettings()
        let oldEnabled = settings.onlineMetadataEnabled
        let oldToken = settings.hardcoverToken
        defer {
            settings.onlineMetadataEnabled = oldEnabled
            settings.hardcoverToken = oldToken
        }
        settings.onlineMetadataEnabled = true
        settings.hardcoverToken = "test-token"

        let book = Book(fileName: "rated.epub", originalFileName: "Rated.epub")
        book.bookDescription = "Already present"
        book.onlineLookupAt = .distantPast
        lib.context.insert(book)
        try lib.context.save()

        var fetched = FetchedMetadata()
        fetched.ratingsAverage = 4.7
        fetched.ratingsCount = 42
        fetched.ratingsSource = "Hardcover"
        let online = FakeOnlineClient(result: fetched)
        let service = MetadataService(modelContext: lib.context, settings: settings, online: online)

        await service.backfillMissingOnlineMetadata()

        #expect(book.communityRating == 4.7)
        #expect(book.onlineLookupConfiguration?.contains("hardcover:none") == false)
        let callsAfterFirstBackfill = await online.fetchCalls
        await service.backfillMissingOnlineMetadata()
        #expect(await online.fetchCalls == callsAfterFirstBackfill)
    }

    @Test func deletingBookDuringMetadataFetchDiscardsLateResult() async throws {
        let lib = try await TestLibrary()
        let book = Book(fileName: "late.epub", originalFileName: "Late.epub")
        lib.context.insert(book)
        try lib.context.save()

        var fetched = FetchedMetadata()
        fetched.title = "Should Not Be Applied"
        let online = FetchGateOnlineClient(result: fetched)
        let service = makeService(in: lib, online: online)
        let task = Task { @MainActor in
            await service.performEnrich(book, replaceCover: false)
        }

        await online.waitUntilStarted()
        lib.context.delete(book)
        lib.context.saveQuietly()
        await online.resume()

        #expect(await task.value == false)
        #expect(lib.context.allBooks().isEmpty)
        #expect(service.enrichingUUIDs.isEmpty)
    }

    @Test func deletingBookDuringCoverDownloadLeavesNoLateCover() async throws {
        let lib = try await TestLibrary()
        let book = Book(fileName: "cover.epub", originalFileName: "Cover.epub")
        let uuid = book.uuid
        lib.context.insert(book)
        try lib.context.save()

        var fetched = FetchedMetadata()
        fetched.title = "Covered"
        fetched.coverURL = URL(string: "https://example.invalid/cover.jpg")
        let online = CoverGateOnlineClient(result: fetched, data: EPUBFixture.jpegData())
        let service = makeService(in: lib, online: online)
        let task = Task { @MainActor in
            await service.performEnrich(book, replaceCover: true)
        }

        await online.waitUntilDownloadStarted()
        lib.context.delete(book)
        lib.context.saveQuietly()
        await online.resumeDownload()

        #expect(await task.value == false)
        #expect(!CoverStore.exists(for: uuid))
        #expect(service.enrichingUUIDs.isEmpty)
    }

    @Test func cancellingImportAnalysisLeavesNoLiveModelOrManagedFile() async throws {
        let lib = try await TestLibrary()
        let settings = AppSettings()
        let oldOnline = settings.onlineMetadataEnabled
        settings.onlineMetadataEnabled = false
        defer { settings.onlineMetadataEnabled = oldOnline }

        let source = lib.root.appending(path: "incoming.epub")
        try Data("partial fixture".utf8).write(to: source)
        let metadata = MetadataService(modelContext: lib.context, settings: settings,
                                       online: FakeOnlineClient())
        let wishlist = WishlistService(modelContext: lib.context, toasts: ToastCenter())
        let gate = ImportAnalysisGate()
        let importer = ImportService(
            modelContext: lib.context,
            settings: settings,
            metadata: metadata,
            wishlist: wishlist,
            toasts: ToastCenter(),
            analyzeBook: { url in await gate.analyze(url) }
        )

        importer.addBooks(from: [source])
        await gate.waitUntilStarted()
        #expect(lib.context.allBooks().isEmpty)
        let uuid = try #require(importer.pendingMetadataUUIDs.first)
        importer.cancelPending(uuid)
        await gate.resume()

        let deadline = Date.now.addingTimeInterval(1)
        while importer.isExtracting, Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(lib.context.allBooks().isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: BookFileStore.url(for: "\(uuid.uuidString).epub").path(percentEncoded: false)
        ))
        #expect(!importer.pendingMetadataUUIDs.contains(uuid))
    }

    @Test func replacingSourceDuringImportAnalysisDoesNotChangeStagedGeneration() async throws {
        let lib = try await TestLibrary()
        let settings = AppSettings()
        let oldOnline = settings.onlineMetadataEnabled
        settings.onlineMetadataEnabled = false
        defer { settings.onlineMetadataEnabled = oldOnline }

        let source = lib.root.appending(path: "replace-during-analysis.epub")
        let originalData = Data("original fixture".utf8)
        try originalData.write(to: source)
        let originalHash = try ContentHasher.sha256(of: source)
        let metadata = MetadataService(
            modelContext: lib.context,
            settings: settings,
            online: FakeOnlineClient()
        )
        let gate = ImportAnalysisGate()
        let importer = ImportService(
            modelContext: lib.context,
            settings: settings,
            metadata: metadata,
            wishlist: WishlistService(modelContext: lib.context, toasts: ToastCenter()),
            toasts: ToastCenter(),
            analyzeBook: { url in await gate.analyze(url) }
        )

        importer.addBooks(from: [source])
        await gate.waitUntilStarted()
        #expect(lib.context.allBooks().isEmpty)
        try Data("replacement content".utf8).write(to: source)

        var inspectedMetadata = BookMetadata()
        inspectedMetadata.title = "Metadata From Staged Bytes"
        await gate.resume(with: ImportBookAnalysis(
            metadata: inspectedMetadata,
            drmProtected: false,
            validation: .ok
        ))

        let deadline = Date.now.addingTimeInterval(1)
        while (lib.context.allBooks().isEmpty || importer.isExtracting), Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let book = try #require(lib.context.allBooks().first)
        let asset = try #require(book.assets.first)
        #expect(book.title == "Metadata From Staged Bytes")
        #expect(try Data(contentsOf: book.fileURL) == originalData)
        #expect(asset.contentHash == originalHash)
        #expect(asset.validationStatus == .ok)
    }

    @Test func standardImportUsesUnifiedDuplicateAndFormatReconciliation() async throws {
        let lib = try await TestLibrary()
        let settings = AppSettings()
        let oldOnline = settings.onlineMetadataEnabled
        settings.onlineMetadataEnabled = false
        defer { settings.onlineMetadataEnabled = oldOnline }

        let epub = lib.root.appending(path: "unified.epub")
        let exactCopy = lib.root.appending(path: "unified-copy.epub")
        let pdf = lib.root.appending(path: "unified.pdf")
        try Data("same-edition-epub".utf8).write(to: epub)
        try Data("same-edition-epub".utf8).write(to: exactCopy)
        try Data("same-edition-pdf".utf8).write(to: pdf)

        let inspected: BookMetadata = {
            var value = BookMetadata()
            value.title = "Unified Pipeline"
            value.author = "Ada Author"
            value.isbn = "9781234567890"
            value.language = "eng"
            return value
        }()
        let coverData = EPUBFixture.jpegData()
        let toasts = ToastCenter()
        let importer = ImportService(
            modelContext: lib.context,
            settings: settings,
            metadata: MetadataService(
                modelContext: lib.context,
                settings: settings,
                online: FakeOnlineClient()
            ),
            wishlist: WishlistService(modelContext: lib.context, toasts: toasts),
            toasts: toasts,
            analyzeBook: { _ in
                ImportBookAnalysis(
                    metadata: inspected,
                    drmProtected: false,
                    validation: .ok,
                    coverJPEGData: coverData
                )
            }
        )

        func importFiles(_ urls: [URL]) async -> [UUID] {
            await withCheckedContinuation { continuation in
                importer.addBooks(from: urls) {
                    continuation.resume(returning: $0.map(\.uuid))
                }
            }
        }

        let first = await importFiles([epub, pdf])
        #expect(first.count == 1)
        let originalBookID = try #require(first.first)
        let book = try #require(lib.context.allBooks().first)
        #expect(book.uuid == originalBookID)
        #expect(book.assets.count == 2)
        #expect(Set(book.assets.map { $0.format.lowercased() }) == ["epub", "pdf"])
        #expect(book.coverVersion == 1)
        #expect(CoverStore.exists(for: book.uuid))
        #expect(try lib.context.fetch(FetchDescriptor<Work>()).count == 1)

        let duplicate = await importFiles([exactCopy])
        #expect(duplicate.isEmpty)
        #expect(lib.context.allBooks().count == 1)
        #expect(book.assets.count == 2)
        #expect(!lib.context.hasChanges)
    }

    @Test func standardImportRejectsASymbolicLinkDuringSourceDiscovery() async throws {
        let lib = try await TestLibrary()
        let target = lib.root.appending(path: "real.epub")
        let link = lib.root.appending(path: "linked.epub")
        try Data("book".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let settings = AppSettings()
        let oldOnline = settings.onlineMetadataEnabled
        settings.onlineMetadataEnabled = false
        defer { settings.onlineMetadataEnabled = oldOnline }
        let toasts = ToastCenter()
        let importer = ImportService(
            modelContext: lib.context,
            settings: settings,
            metadata: MetadataService(modelContext: lib.context, settings: settings),
            wishlist: WishlistService(modelContext: lib.context, toasts: toasts),
            toasts: toasts
        )

        let importedCount: Int = await withCheckedContinuation { continuation in
            importer.addBooks(from: [link]) { books in
                continuation.resume(returning: books.count)
            }
        }

        #expect(importedCount == 0)
        #expect(lib.context.allBooks().isEmpty)
        #expect(try lib.context.fetch(FetchDescriptor<BookAsset>()).isEmpty)
        #expect(!lib.context.hasChanges)
    }

    @Test func importRefreshesWorkIdentityAfterOnlineEnrichment() async throws {
        let lib = try await TestLibrary()
        let settings = AppSettings()
        let oldOnline = settings.onlineMetadataEnabled
        settings.onlineMetadataEnabled = true
        defer { settings.onlineMetadataEnabled = oldOnline }
        let source = lib.root.appending(path: "metadata-less.pdf")
        try Data("pdf placeholder".utf8).write(to: source)
        var fetched = FetchedMetadata()
        fetched.title = "Online Canonical Title"
        fetched.authors = ["Online Author"]
        let metadata = MetadataService(
            modelContext: lib.context,
            settings: settings,
            online: FakeOnlineClient(result: fetched)
        )
        let importer = ImportService(
            modelContext: lib.context,
            settings: settings,
            metadata: metadata,
            wishlist: WishlistService(modelContext: lib.context, toasts: ToastCenter()),
            toasts: ToastCenter(),
            analyzeBook: { _ in ImportBookAnalysis(metadata: BookMetadata(), drmProtected: false) }
        )

        importer.addBooks(from: [source])
        let deadline = Date.now.addingTimeInterval(2)
        while (lib.context.allBooks().isEmpty || importer.isExtracting), Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let book = try #require(lib.context.allBooks().first)

        #expect(book.title == "Online Canonical Title")
        #expect(book.work?.title == "Online Canonical Title")
        #expect(book.work?.author == "Online Author")
    }
}

private actor FakeOnlineClient: OnlineMetadataFetching {
    private let result: FetchedMetadata?
    private let reachedNetwork: Bool
    private let coverData: Data?
    private(set) var fetchCalls = 0
    private(set) var coverDownloadCalls = 0

    init(result: FetchedMetadata? = nil, reachedNetwork: Bool = true, coverData: Data? = nil) {
        self.result = result
        self.reachedNetwork = reachedNetwork
        self.coverData = coverData
    }

    func fetch(isbn: String?, title: String, author: String?, language: MetadataLanguage,
               hardcoverToken: String?) async -> OnlineMetadataFetchResult {
        fetchCalls += 1
        return OnlineMetadataFetchResult(metadata: result, reachedNetwork: reachedNetwork)
    }

    func downloadCover(_ url: URL) async -> Data? {
        coverDownloadCalls += 1
        return coverData
    }
}

private actor ReentrantOnlineClient: OnlineMetadataFetching {
    func fetch(isbn: String?, title: String, author: String?, language: MetadataLanguage,
               hardcoverToken: String?) async -> OnlineMetadataFetchResult {
        if title == "Offline" {
            try? await Task.sleep(for: .milliseconds(80))
            return OnlineMetadataFetchResult(metadata: nil, reachedNetwork: false)
        }
        try? await Task.sleep(for: .milliseconds(10))
        return OnlineMetadataFetchResult(metadata: nil, reachedNetwork: true)
    }

    func downloadCover(_ url: URL) async -> Data? { nil }
}

private actor FetchGateOnlineClient: OnlineMetadataFetching {
    private let outcome: OnlineMetadataFetchResult
    private var continuation: CheckedContinuation<OnlineMetadataFetchResult, Never>?
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(result: FetchedMetadata?) {
        outcome = OnlineMetadataFetchResult(metadata: result, reachedNetwork: true)
    }

    func fetch(isbn: String?, title: String, author: String?, language: MetadataLanguage,
               hardcoverToken: String?) async -> OnlineMetadataFetchResult {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    func downloadCover(_ url: URL) async -> Data? { nil }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func resume() {
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}

private actor CoverGateOnlineClient: OnlineMetadataFetching {
    private let result: FetchedMetadata
    private let data: Data
    private var continuation: CheckedContinuation<Data?, Never>?
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(result: FetchedMetadata, data: Data) {
        self.result = result
        self.data = data
    }

    func fetch(isbn: String?, title: String, author: String?, language: MetadataLanguage,
               hardcoverToken: String?) async -> OnlineMetadataFetchResult {
        OnlineMetadataFetchResult(metadata: result, reachedNetwork: true)
    }

    func downloadCover(_ url: URL) async -> Data? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    func waitUntilDownloadStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func resumeDownload() {
        continuation?.resume(returning: data)
        continuation = nil
    }
}

private actor CancellationAwareOnlineClient: OnlineMetadataFetching {
    private(set) var wasCancelled = false
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fetch(isbn: String?, title: String, author: String?, language: MetadataLanguage,
               hardcoverToken: String?) async -> OnlineMetadataFetchResult {
        started = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        do {
            try await Task.sleep(for: .seconds(60))
        } catch {
            wasCancelled = true
        }
        return OnlineMetadataFetchResult(metadata: nil, reachedNetwork: false)
    }

    func downloadCover(_ url: URL) async -> Data? { nil }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor PageCountGate {
    private var continuation: CheckedContinuation<Int?, Never>?
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func estimate(url: URL, format: String) async -> Int? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func resume(with pages: Int?) {
        continuation?.resume(returning: pages)
        continuation = nil
    }
}

private actor ImportAnalysisGate {
    private var continuation: CheckedContinuation<ImportBookAnalysis, Never>?
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func analyze(_ url: URL) async -> ImportBookAnalysis {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func resume() {
        var metadata = BookMetadata()
        metadata.title = "Late Metadata"
        resume(with: ImportBookAnalysis(metadata: metadata, drmProtected: false))
    }

    func resume(with result: ImportBookAnalysis) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

@MainActor
@Suite(.serialized)
struct CatalogAnalysisCoordinatorTests {
    @Test func identicalRequestsShareOneWorkerUntilEveryLeaseFinishes() async throws {
        let library = try await TestLibrary()
        let book = Book(fileName: "coalesced.epub", originalFileName: "Coalesced.epub")
        library.context.insert(book)
        try library.context.save()
        let snapshot = try #require(BookAnalysisSnapshot(book: book))
        let gate = CatalogCoordinatorGate()
        let coordinator = CatalogAnalysisCoordinator()

        let first: CatalogAnalysisJob<Int> = coordinator.start(
            snapshot: snapshot,
            kind: .pageCount
        ) { _ in
            await gate.run(value: 42)
        }
        let second: CatalogAnalysisJob<Int> = coordinator.start(
            snapshot: snapshot,
            kind: .pageCount
        ) { _ in
            await gate.run(value: 999)
        }

        await gate.waitUntilStarted(1)
        #expect(await gate.startedCount == 1)
        #expect(coordinator.activeJobCount == 1)
        #expect(coordinator.activeLeaseCount == 2)

        await gate.resumeAll()
        #expect(await coordinator.value(for: first) == 42)
        #expect(await coordinator.value(for: second) == 42)

        coordinator.finish(first.ticket)
        #expect(coordinator.activeJobCount == 1)
        #expect(coordinator.activeLeaseCount == 1)
        coordinator.finish(second.ticket)
        #expect(coordinator.activeJobCount == 0)
        #expect(coordinator.activeLeaseCount == 0)
    }

    @Test func localWorkerConcurrencyIsBoundedAcrossBooks() async throws {
        let library = try await TestLibrary()
        var snapshots: [BookAnalysisSnapshot] = []
        for index in 0 ..< 3 {
            let book = Book(
                fileName: "bounded-\(index).epub",
                originalFileName: "Bounded \(index).epub"
            )
            library.context.insert(book)
            snapshots.append(try #require(BookAnalysisSnapshot(book: book)))
        }
        try library.context.save()

        let gate = CatalogCoordinatorGate()
        let coordinator = CatalogAnalysisCoordinator(
            maximumConcurrentLocalJobs: 2,
            maximumConcurrentNetworkJobs: 1
        )
        let jobs: [CatalogAnalysisJob<Int>] = snapshots.enumerated().map { index, snapshot in
            coordinator.start(snapshot: snapshot, kind: .metadataExtraction) { _ in
                await gate.run(value: index)
            }
        }

        await gate.waitUntilStarted(2)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await gate.startedCount == 2)
        let saturated = await coordinator.schedulerDiagnostics()
        #expect(saturated.activeLocalJobs == 2)
        #expect(saturated.peakLocalJobs == 2)

        await gate.resumeOne()
        await gate.waitUntilStarted(3)
        #expect((await coordinator.schedulerDiagnostics()).peakLocalJobs == 2)
        await gate.resumeAll()

        for job in jobs {
            _ = await coordinator.value(for: job)
            coordinator.finish(job.ticket)
        }
        #expect(coordinator.activeJobCount == 0)
    }

    @Test func changedRequestGenerationSupersedesAndCancelsTheOldWorker() async throws {
        let library = try await TestLibrary()
        let book = Book(fileName: "generation.epub", originalFileName: "Generation.epub")
        library.context.insert(book)
        try library.context.save()
        let snapshot = try #require(BookAnalysisSnapshot(book: book))
        let oldGate = CatalogCoordinatorCancellationGate()
        let coordinator = CatalogAnalysisCoordinator()

        let old: CatalogAnalysisJob<Int> = coordinator.start(
            snapshot: snapshot,
            kind: .onlineEnrichment,
            requestGeneration: "provider-config-v1"
        ) { _ in
            await oldGate.run()
        }
        await oldGate.waitUntilStarted()

        let replacement: CatalogAnalysisJob<Int> = coordinator.start(
            snapshot: snapshot,
            kind: .onlineEnrichment,
            requestGeneration: "provider-config-v2"
        ) { _ in
            2
        }

        #expect(await coordinator.value(for: old) == nil)
        #expect(await oldGate.wasCancelled)
        #expect(await coordinator.value(for: replacement) == 2)
        #expect(!coordinator.isCurrent(old.ticket))
        #expect(coordinator.isCurrent(replacement.ticket))
        coordinator.finish(replacement.ticket)
        #expect(coordinator.activeJobCount == 0)
    }
}

private actor CatalogCoordinatorGate {
    private var started = 0
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var resumeContinuations: [CheckedContinuation<Void, Never>] = []

    var startedCount: Int { started }

    func run(value: Int) async -> Int {
        started += 1
        let ready = startWaiters.filter { started >= $0.count }
        startWaiters.removeAll { started >= $0.count }
        ready.forEach { $0.continuation.resume() }
        await withCheckedContinuation { continuation in
            resumeContinuations.append(continuation)
        }
        return value
    }

    func waitUntilStarted(_ count: Int) async {
        guard started < count else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((count, continuation))
        }
    }

    func resumeOne() {
        guard !resumeContinuations.isEmpty else { return }
        resumeContinuations.removeFirst().resume()
    }

    func resumeAll() {
        let pending = resumeContinuations
        resumeContinuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor CatalogCoordinatorCancellationGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var wasCancelled = false

    func run() async -> Int? {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        do {
            try await Task.sleep(for: .seconds(30))
            return 1
        } catch {
            wasCancelled = true
            return nil
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }
}
