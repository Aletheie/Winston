import Foundation
import SwiftData
import AppKit
import CryptoKit

nonisolated struct OnlineEnrichmentProposal: Sendable {
    let outcome: OnlineMetadataFetchResult
    let coverJPEGData: Data?
    let lookupConfiguration: String
    let completedAt: Date
}

@MainActor
@Observable
final class MetadataService {
    private let modelContext: ModelContext
    private let settings: AppSettings
    private let online: any OnlineMetadataFetching
    private let covers: CoverRepository
    private let mutations: CatalogMutationService
    let analysisCoordinator: CatalogAnalysisCoordinator
    private let estimatePageCount: @Sendable (URL, String) async -> Int?

    private(set) var enrichingUUIDs: Set<UUID> = []
    private(set) var metadataFetchSummary: String?
    private var enrichmentRuns: [UUID: UUID] = [:]
    private var manualFetchTask: Task<Void, Never>?
    private var manualFetchGeneration = 0

    init(
        modelContext: ModelContext,
        settings: AppSettings,
        online: any OnlineMetadataFetching = OnlineMetadataService(),
        covers: CoverRepository = .shared,
        mutations: CatalogMutationService? = nil,
        analysisCoordinator: CatalogAnalysisCoordinator? = nil,
        estimatePageCount: @escaping @Sendable (URL, String) async -> Int? = {
            await PageCountEstimator.pageCount(at: $0, format: $1)
        }
    ) {
        let coordinator = mutations?.analysisCoordinator
            ?? analysisCoordinator
            ?? CatalogAnalysisCoordinator()
        let resolvedMutations = mutations ?? CatalogMutationService(
            modelContext: modelContext,
            analysisCoordinator: coordinator
        )
        self.modelContext = modelContext
        self.settings = settings
        self.online = online
        self.covers = covers
        self.mutations = resolvedMutations
        self.analysisCoordinator = resolvedMutations.analysisCoordinator
        self.estimatePageCount = estimatePageCount
    }

    var isFetchingOnline: Bool { !enrichingUUIDs.isEmpty }

    // MARK: - Manual edits

    @discardableResult
    func updateMetadata(
        for book: Book,
        title: String?, author: String?, publisher: String?, year: String?,
        series: String?, seriesIndex: String?, language: String?, translator: String?, isbn: String?,
        description: String?, tags: [String], shelfLocation: String?,
        identityScope: EditionIdentityScope = .editionOnly
    ) -> Bool {
        let bookID = book.uuid
        let fields: Set<String> = [
            "title", "author", "publisher", "year", "series", "seriesIndex",
            "language", "translator", "isbn", "description", "tags", "shelfLocation",
        ]
        let affected = mutations.editionIdentity.affectedModels(
            for: book,
            scope: identityScope
        )
        let bookPreimages = ((try? mutations.books(ids: affected.affectedBookIDs)) ?? [])
            .map(CatalogBookMetadataPreimage.init)
        let workPreimages = ((try? mutations.works(ids: affected.affectedWorkIDs)) ?? [])
            .map(CatalogWorkPreimage.init)
        do {
            try mutations.commit(
                .updateMetadata(bookID: bookID, fields: fields),
                affectedBookIDs: affected.affectedBookIDs,
                affectedWorkIDs: affected.affectedWorkIDs,
                revertingOnFailure: {
                    bookPreimages.forEach { $0.restore() }
                    workPreimages.forEach { $0.restore() }
                }
            ) {
                let book = try mutations.book(id: bookID)
                mutations.editionIdentity.apply(
                    EditionIdentityPatch(
                        fields: [.title, .author, .isbn],
                        title: title,
                        author: author,
                        isbn: isbn
                    ),
                    to: book,
                    scope: identityScope
                )
                book.publisher = publisher
                book.year = year
                book.series = series
                book.seriesIndex = seriesIndex
                book.language = language
                book.translator = translator
                book.bookDescription = description
                book.tags = tags
                book.shelfLocation = shelfLocation
            }
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func updateRating(for book: Book, rating: Int?) -> Bool {
        let bookID = book.uuid
        return commit(.updateMetadata(bookID: bookID, fields: ["rating"]), bookIDs: [bookID]) {
            let storedBook = try mutations.book(id: bookID)
            storedBook.rating = rating
        }
    }

    @discardableResult
    func updateNotes(_ notes: String, for book: Book) -> Bool {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookID = book.uuid
        return commit(.updateMetadata(bookID: bookID, fields: ["notes"]), bookIDs: [bookID]) {
            let storedBook = try mutations.book(id: bookID)
            storedBook.notes = trimmed.isEmpty ? nil : notes
        }
    }

    // MARK: - Page count

    /// Books imported before page counts existed get theirs the first time the panel shows them.
    func backfillPageCount(for book: Book) async {
        guard book.pageCount == nil,
              let snapshot = BookAnalysisSnapshot(book: book),
              snapshot.fileURL != nil else { return }
        let estimator = estimatePageCount
        let format = (snapshot.fileName as NSString).pathExtension
        let job = analysisCoordinator.start(snapshot: snapshot, kind: .pageCount) { snapshot in
            await CatalogAnalysisWorker.inspect(snapshot: snapshot) { url in
                await estimator(url, format)
            }
        }
        defer { analysisCoordinator.finish(job.ticket) }

        guard let proposal = await analysisCoordinator.value(for: job),
              proposal.value > 0,
              proposal.sourceIsCurrent(for: snapshot),
              analysisCoordinator.isCurrent(job.ticket),
              let liveBook = try? mutations.book(id: snapshot.bookID),
              snapshot.matches(liveBook),
              liveBook.pageCount == nil else { return }

        let preimage = CatalogBookMetadataPreimage(liveBook)
        do {
            try mutations.commit(
                .applyAnalysis(bookID: snapshot.bookID, kind: .pageCount),
                affectedBookIDs: [snapshot.bookID],
                revertingOnFailure: preimage.restore
            ) {
                let storedBook = try mutations.book(id: snapshot.bookID)
                guard analysisCoordinator.isCurrent(job.ticket),
                      snapshot.matches(storedBook),
                      proposal.sourceIsCurrent(for: snapshot),
                      storedBook.pageCount == nil else {
                    throw CatalogMutationError.staleAnalysis
                }
                storedBook.pageCount = proposal.value
            }
        } catch {
            return
        }
    }

    @discardableResult
    func markNotSample(_ book: Book) -> Bool {
        let bookID = book.uuid
        return commit(.updateMetadata(bookID: bookID, fields: ["sampleNoticeDismissed"]), bookIDs: [bookID]) {
            let storedBook = try mutations.book(id: bookID)
            storedBook.sampleNoticeDismissed = true
        }
    }

    @discardableResult
    func bulkUpdate(_ books: [Book], _ edit: BulkEdit) -> Bool {
        let selectedIDs = Set(books.map(\.uuid))
        var affectedBookIDs = selectedIDs
        var affectedWorkIDs: Set<UUID> = []
        if edit.author != nil {
            for book in books {
                let affected = mutations.editionIdentity.affectedModels(
                    for: book,
                    scope: edit.authorIdentityScope
                )
                affectedBookIDs.formUnion(affected.affectedBookIDs)
                affectedWorkIDs.formUnion(affected.affectedWorkIDs)
            }
        }
        var fields: Set<String> = []
        if edit.author != nil { fields.insert("author") }
        if edit.publisher != nil { fields.insert("publisher") }
        if edit.year != nil { fields.insert("year") }
        if edit.series != nil { fields.insert("series") }
        if edit.language != nil { fields.insert("language") }
        if edit.translator != nil { fields.insert("translator") }
        if edit.status != nil { fields.insert("readingStatus") }
        if edit.tags != nil { fields.insert("tags") }
        let bookPreimages = ((try? mutations.books(ids: affectedBookIDs)) ?? [])
            .map(CatalogBookMetadataPreimage.init)
        let workPreimages = ((try? mutations.works(ids: affectedWorkIDs)) ?? [])
            .map(CatalogWorkPreimage.init)
        do {
            try mutations.commit(
                .updateMetadataBatch(
                    bookIDs: Array(affectedBookIDs),
                    operation: "bulkEdit",
                    fields: fields
                ),
                affectedBookIDs: affectedBookIDs,
                affectedWorkIDs: affectedWorkIDs,
                revertingOnFailure: {
                    bookPreimages.forEach { $0.restore() }
                    workPreimages.forEach { $0.restore() }
                }
            ) {
                let selectedBooks = try mutations.books(ids: selectedIDs)
                for book in selectedBooks {
                    if let author = edit.author {
                        mutations.editionIdentity.apply(
                            EditionIdentityPatch(
                                fields: [.author],
                                author: author.isEmpty ? nil : author
                            ),
                            to: book,
                            scope: edit.authorIdentityScope
                        )
                    }
                    if let publisher = edit.publisher {
                        book.publisher = publisher.isEmpty ? nil : publisher
                    }
                    if let year = edit.year { book.year = year.isEmpty ? nil : year }
                    if let series = edit.series { book.series = series.isEmpty ? nil : series }
                    if let language = edit.language {
                        book.language = language.isEmpty ? nil : language
                    }
                    if let translator = edit.translator {
                        book.translator = translator.isEmpty ? nil : translator
                    }
                    if let status = edit.status { book.setStatus(status) }
                    if let tags = edit.tags {
                        switch edit.tagMode {
                        case .replace: book.tags = tags
                        case .add: book.tags = (book.tags + tags).uniquedSorted()
                        }
                    }
                }
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Tag / series / author management

    @discardableResult
    func renameTag(_ old: String, to new: String) -> Bool {
        let name = new.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != old else { return true }
        let ids = Set(((try? modelContext.fetchAllBooksForGlobalAnalysis()) ?? [])
            .filter { $0.tags.contains(old) }.map(\.uuid))
        guard !ids.isEmpty else { return true }
        return commit(
            .updateMetadataBatch(bookIDs: Array(ids), operation: "renameTag", fields: ["tags"]),
            bookIDs: ids
        ) {
            for book in try mutations.books(ids: ids) {
                book.tags = (book.tags.filter { $0 != old } + [name]).uniquedSorted()
            }
        }
    }

    @discardableResult
    func deleteTag(_ tag: String) -> Bool {
        let ids = Set(((try? modelContext.fetchAllBooksForGlobalAnalysis()) ?? [])
            .filter { $0.tags.contains(tag) }.map(\.uuid))
        guard !ids.isEmpty else { return true }
        return commit(
            .updateMetadataBatch(bookIDs: Array(ids), operation: "deleteTag", fields: ["tags"]),
            bookIDs: ids
        ) {
            for book in try mutations.books(ids: ids) {
                book.tags.removeAll { $0 == tag }
            }
        }
    }

    @discardableResult
    func renameSeries(_ old: String, to new: String) -> Bool {
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.series == old })
        let ids = Set(((try? modelContext.fetch(descriptor)) ?? []).map(\.uuid))
        guard !ids.isEmpty else { return true }
        return commit(
            .updateMetadataBatch(bookIDs: Array(ids), operation: "renameSeries", fields: ["series"]),
            bookIDs: ids
        ) {
            applySeriesRename(old, to: new)
        }
    }

    @discardableResult
    func renameAuthor(_ old: String, to new: String) -> Bool {
        let ids = Set(((try? modelContext.fetchAllBooksForGlobalAnalysis()) ?? [])
            .filter { $0.displayAuthor == old }.map(\.uuid))
        guard !ids.isEmpty else { return true }
        let books = (try? mutations.books(ids: ids)) ?? []
        var affectedBookIDs = ids
        var affectedWorkIDs: Set<UUID> = []
        for book in books {
            let affected = mutations.editionIdentity.affectedModels(
                for: book,
                scope: .workIdentity
            )
            affectedBookIDs.formUnion(affected.affectedBookIDs)
            affectedWorkIDs.formUnion(affected.affectedWorkIDs)
        }
        let bookPreimages = ((try? mutations.books(ids: affectedBookIDs)) ?? [])
            .map(CatalogBookMetadataPreimage.init)
        let workPreimages = ((try? mutations.works(ids: affectedWorkIDs)) ?? [])
            .map(CatalogWorkPreimage.init)
        do {
            try mutations.commit(
                .updateMetadataBatch(
                    bookIDs: Array(affectedBookIDs),
                    operation: "renameAuthor",
                    fields: ["author"]
                ),
                affectedBookIDs: affectedBookIDs,
                affectedWorkIDs: affectedWorkIDs,
                revertingOnFailure: {
                    bookPreimages.forEach { $0.restore() }
                    workPreimages.forEach { $0.restore() }
                }
            ) {
                let name = new.trimmingCharacters(in: .whitespaces)
                for book in try mutations.books(ids: ids) {
                    mutations.editionIdentity.apply(
                        EditionIdentityPatch(
                            fields: [.author],
                            author: name.isEmpty ? nil : name
                        ),
                        to: book,
                        scope: .workIdentity
                    )
                }
            }
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func applyMetadataFix(_ fix: MetadataFix) -> Bool {
        applyMetadataFixes([fix])
    }

    @discardableResult
    func applyMetadataFixes(_ fixes: [MetadataFix]) -> Bool {
        guard !fixes.isEmpty else { return true }
        let catalogBooks = (try? modelContext.fetchAllBooksForGlobalAnalysis()) ?? []
        var targetIDsByFixIndex: [Int: Set<UUID>] = [:]
        var affectedBookIDs: Set<UUID> = []
        var affectedWorkIDs: Set<UUID> = []
        for (index, fix) in fixes.enumerated() {
            let targetIDs: Set<UUID>
            switch fix.kind {
            case .author:
                let matching = catalogBooks.filter { $0.displayAuthor == fix.original }
                targetIDs = Set(matching.map(\.uuid))
                for book in matching {
                    let affected = mutations.editionIdentity.affectedModels(
                        for: book,
                        scope: .workIdentity
                    )
                    affectedBookIDs.formUnion(affected.affectedBookIDs)
                    affectedWorkIDs.formUnion(affected.affectedWorkIDs)
                }
            case .series:
                targetIDs = Set(catalogBooks.filter {
                    $0.series == fix.original
                }.map(\.uuid))
                affectedBookIDs.formUnion(targetIDs)
            case .seriesAssignment:
                targetIDs = Set([fix.bookID].compactMap { $0 })
                affectedBookIDs.formUnion(targetIDs)
            }
            targetIDsByFixIndex[index] = targetIDs
        }
        guard !affectedBookIDs.isEmpty else { return true }
        let fields = Set(fixes.flatMap { fix -> [String] in
            switch fix.kind {
            case .author: ["author"]
            case .series: ["series"]
            case .seriesAssignment: ["series", "seriesIndex"]
            }
        })
        let bookPreimages = ((try? mutations.books(ids: affectedBookIDs)) ?? [])
            .map(CatalogBookMetadataPreimage.init)
        let workPreimages = ((try? mutations.works(ids: affectedWorkIDs)) ?? [])
            .map(CatalogWorkPreimage.init)
        do {
            try mutations.commit(
                .updateMetadataBatch(
                    bookIDs: Array(affectedBookIDs),
                    operation: "metadataFixes",
                    fields: fields
                ),
                affectedBookIDs: affectedBookIDs,
                affectedWorkIDs: affectedWorkIDs,
                revertingOnFailure: {
                    bookPreimages.forEach { $0.restore() }
                    workPreimages.forEach { $0.restore() }
                }
            ) {
                for (index, fix) in fixes.enumerated() {
                    let targetIDs = targetIDsByFixIndex[index] ?? []
                    switch fix.kind {
                    case .author:
                        let name = fix.suggestion.trimmingCharacters(in: .whitespaces)
                        for book in try mutations.books(ids: targetIDs) {
                            mutations.editionIdentity.apply(
                                EditionIdentityPatch(
                                    fields: [.author],
                                    author: name.isEmpty ? nil : name
                                ),
                                to: book,
                                scope: .workIdentity
                            )
                        }
                    case .series:
                        let name = fix.suggestion.trimmingCharacters(in: .whitespaces)
                        for book in try mutations.books(ids: targetIDs) {
                            book.series = name.isEmpty ? nil : name
                        }
                    case .seriesAssignment:
                        applySeriesAssignment(fix)
                    }
                }
            }
            return true
        } catch {
            return false
        }
    }

    private func commit(
        _ command: CatalogMutationCommand,
        bookIDs: Set<UUID>,
        applying mutation: () throws -> Void
    ) -> Bool {
        let preimages = ((try? mutations.books(ids: bookIDs)) ?? [])
            .map(CatalogBookMetadataPreimage.init)
        do {
            try mutations.commit(
                command,
                affectedBookIDs: bookIDs,
                revertingOnFailure: { preimages.forEach { $0.restore() } },
                applying: mutation
            )
            return true
        } catch {
            return false
        }
    }

    private func applySeriesRename(_ old: String, to new: String) {
        let name = new.trimmingCharacters(in: .whitespaces)
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.series == old })
        for book in (try? modelContext.fetch(descriptor)) ?? [] {
            book.series = name.isEmpty ? nil : name
        }
    }

    private func applySeriesAssignment(_ fix: MetadataFix) {
        guard let bookID = fix.bookID else { return }
        var descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.uuid == bookID })
        descriptor.fetchLimit = 1
        guard let book = ((try? modelContext.fetch(descriptor)) ?? []).first,
              book.series?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else { return }

        let series = fix.suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !series.isEmpty else { return }
        book.series = series
        if book.seriesIndex?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            book.seriesIndex = fix.seriesIndex
        }
    }

    // MARK: - Online enrichment (gated by Settings; no network calls when off)

    func fetchOnlineMetadata(for book: Book) {
        fetchOnlineMetadata(for: [book])
    }

    func fetchOnlineMetadata(for books: [Book]) {
        guard settings.onlineMetadataEnabled else {
            metadataFetchSummary = String(localized: "Turn on “Fetch metadata online” in Settings first.")
            return
        }
        let bookIDs = books.map(\.uuid)
        metadataFetchSummary = nil
        manualFetchTask?.cancel()
        manualFetchGeneration &+= 1
        let generation = manualFetchGeneration
        manualFetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if manualFetchGeneration == generation {
                    manualFetchTask = nil
                }
            }
            var matched = 0
            for bookID in bookIDs {
                guard !Task.isCancelled,
                      manualFetchGeneration == generation,
                      let book = try? mutations.book(id: bookID) else { continue }
                if await performEnrich(book, replaceCover: true) { matched += 1 }
            }
            guard !Task.isCancelled,
                  manualFetchGeneration == generation else { return }
            metadataFetchSummary = matched > 0
                ? String(localized: "Updated \(matched) of \(bookIDs.count) from online catalogs.")
                : String(localized: "No matching records found online.")
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled,
               manualFetchGeneration == generation,
               !isFetchingOnline {
                metadataFetchSummary = nil
            }
        }
    }

    func backfillMissingOnlineMetadata() async {
        guard settings.onlineMetadataEnabled else { return }
        let language = preferredLanguage
        let token = normalizedHardcoverToken
        let candidates = (try? modelContext.fetchAllBooksForGlobalAnalysis()) ?? []
        let books: [Book]
        if let token {
            let configuration = lookupConfiguration(language: language, hardcoverToken: token)
            books = candidates.filter {
                ($0.bookDescription == nil || $0.communityRating == nil)
                    && $0.onlineLookupConfiguration != configuration
            }
        } else {
            books = candidates.filter {
                $0.onlineLookupAt == nil && ($0.bookDescription == nil || $0.communityRating == nil)
            }
        }
        let bookIDs = books.map(\.uuid)
        guard !bookIDs.isEmpty else { return }
        for bookID in bookIDs {
            guard !Task.isCancelled,
                  let book = try? mutations.book(id: bookID) else { continue }
            await performEnrich(book, replaceCover: false)
        }
    }

    func cancelOnlineMetadataJobs() {
        manualFetchGeneration &+= 1
        manualFetchTask?.cancel()
        manualFetchTask = nil
        for bookID in enrichingUUIDs {
            analysisCoordinator.cancelAll(for: bookID)
        }
        enrichmentRuns.removeAll()
        enrichingUUIDs.removeAll()
    }

    @discardableResult
    func performEnrich(_ book: Book, replaceCover: Bool) async -> Bool {
        await performEnrich(bookID: book.uuid, replaceCover: replaceCover)
    }

    /// ID-only entry point for import/background jobs. The context-bound model
    /// is released before the first suspension point.
    @discardableResult
    func performEnrich(bookID: UUID, replaceCover: Bool) async -> Bool {
        let input: (BookAnalysisSnapshot, Int)
        do {
            guard let book = try? mutations.book(id: bookID),
                  let snapshot = BookAnalysisSnapshot(book: book) else { return false }
            input = (snapshot, book.coverVersion)
        }
        return await performEnrich(
            snapshot: input.0,
            coverVersion: input.1,
            replaceCover: replaceCover
        )
    }

    private func performEnrich(
        snapshot: BookAnalysisSnapshot,
        coverVersion: Int,
        replaceCover: Bool
    ) async -> Bool {
        let uuid = snapshot.bookID
        let hasCover = CoverStore.exists(for: uuid)
        let coverToken = replaceCover
            ? await covers.beginUserMutation(for: uuid)
            : await covers.beginBackgroundMutation(for: uuid)

        let runID = UUID()
        enrichmentRuns[uuid] = runID
        enrichingUUIDs.insert(uuid)
        defer {
            if enrichmentRuns[uuid] == runID {
                enrichmentRuns.removeValue(forKey: uuid)
                enrichingUUIDs.remove(uuid)
            }
        }

        let language = preferredLanguage
        let token = normalizedHardcoverToken
        let configuration = lookupConfiguration(language: language, hardcoverToken: token)
        let online = self.online
        let shouldDownloadCover = replaceCover || !hasCover
        let job: CatalogAnalysisJob<OnlineEnrichmentProposal> = analysisCoordinator.start(
            snapshot: snapshot,
            kind: .onlineEnrichment
        ) { snapshot in
            let outcome = await online.fetch(
                isbn: snapshot.lookupISBN,
                title: snapshot.lookupTitle,
                author: snapshot.lookupAuthor,
                language: language,
                hardcoverToken: token
            )
            guard !Task.isCancelled else { return nil }

            var coverJPEGData: Data?
            if shouldDownloadCover,
               let coverURL = outcome.metadata?.coverURL,
               let downloaded = await online.downloadCover(coverURL),
               !Task.isCancelled {
                coverJPEGData = await Self.normalizedJPEGData(downloaded)
            }
            guard !Task.isCancelled else { return nil }
            return OnlineEnrichmentProposal(
                outcome: outcome,
                coverJPEGData: coverJPEGData,
                lookupConfiguration: configuration,
                completedAt: .now
            )
        }
        defer { analysisCoordinator.finish(job.ticket) }

        guard let proposal = await analysisCoordinator.value(for: job),
              proposal.lookupConfiguration == currentLookupConfiguration,
              analysisCoordinator.isCurrent(job.ticket),
              let currentBook = try? mutations.book(id: snapshot.bookID),
              snapshot.matches(currentBook) else { return false }

        var coverRollback: CoverRollbackTicket?
        var installedCoverURL: URL?
        if let data = proposal.coverJPEGData,
           currentBook.coverVersion == coverVersion,
           (replaceCover || !CoverStore.exists(for: uuid)) {
            installedCoverURL = currentBook.coverCacheURL
            coverRollback = await covers.install(
                data,
                using: coverToken,
                onlyIfMissing: !replaceCover
            )
        }

        if coverRollback != nil, !(await covers.isCurrent(coverToken)) {
            return false
        }
        guard analysisCoordinator.isCurrent(job.ticket),
              proposal.lookupConfiguration == currentLookupConfiguration,
              let liveBook = try? mutations.book(id: snapshot.bookID),
              snapshot.matches(liveBook),
              coverRollback == nil || liveBook.coverVersion == coverVersion else {
            if let coverRollback, let installedCoverURL {
                await rollbackCover(coverRollback, cacheURL: installedCoverURL)
            }
            return false
        }

        let matched = proposal.outcome.metadata != nil
        guard matched || proposal.outcome.reachedNetwork else { return false }
        let bookPreimage = CatalogBookMetadataPreimage(liveBook)
        let workPreimage = liveBook.work.map(CatalogWorkPreimage.init)
        do {
            try mutations.commit(
                .applyAnalysis(bookID: snapshot.bookID, kind: .onlineEnrichment),
                affectedBookIDs: [snapshot.bookID],
                affectedWorkIDs: Set([snapshot.identityRevision.workID].compactMap { $0 }),
                revertingOnFailure: {
                    bookPreimage.restore()
                    workPreimage?.restore()
                }
            ) {
                let storedBook = try mutations.book(id: snapshot.bookID)
                guard analysisCoordinator.isCurrent(job.ticket),
                      proposal.lookupConfiguration == currentLookupConfiguration,
                      snapshot.matches(storedBook),
                      coverRollback == nil || storedBook.coverVersion == coverVersion else {
                    throw CatalogMutationError.staleAnalysis
                }
                if let fetched = proposal.outcome.metadata {
                    applyOnlineProposal(fetched, to: storedBook)
                }
                storedBook.onlineLookupAt = proposal.completedAt
                storedBook.onlineLookupConfiguration = proposal.lookupConfiguration
                if coverRollback != nil { storedBook.coverVersion += 1 }
            }
        } catch {
            if let coverRollback, let installedCoverURL {
                await rollbackCover(coverRollback, cacheURL: installedCoverURL)
            }
            return false
        }

        if let coverRollback,
           let installedCoverURL,
           let data = proposal.coverJPEGData,
           await covers.isCurrent(coverToken) {
            _ = coverRollback
            await CoverCache.shared.replace(NSImage(data: data), for: installedCoverURL)
        }
        return matched
    }

    private var currentLookupConfiguration: String {
        lookupConfiguration(language: preferredLanguage, hardcoverToken: normalizedHardcoverToken)
    }

    private func applyOnlineProposal(_ fetched: FetchedMetadata, to book: Book) {
        book.applyOnline(fetched)
        if let work = book.work {
            if work.openLibraryWorkKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
               let key = fetched.openLibraryWorkKey?.trimmingCharacters(in: .whitespacesAndNewlines),
               !key.isEmpty {
                work.openLibraryWorkKey = key
            }
            if work.hardcoverBookID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
               let id = fetched.hardcoverBookID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !id.isEmpty {
                work.hardcoverBookID = id
            }
            if work.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                work.title = book.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? book.title
                    : book.displayTitle
            }
            if work.author?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                work.author = book.displayAuthor
            }
            work.refreshMatchKey()
        }
    }

    private func rollbackCover(_ rollback: CoverRollbackTicket, cacheURL: URL) async {
        if await covers.rollback(rollback) {
            await CoverCache.shared.replace(
                rollback.previousData.flatMap(NSImage.init(data:)),
                for: cacheURL
            )
        }
    }

    @concurrent
    private static func normalizedJPEGData(_ data: Data) async -> Data? {
        guard !Task.isCancelled, let image = NSImage(data: data) else { return nil }
        let jpeg = ImageTranscoder.jpegData(from: image)
        return Task.isCancelled ? nil : jpeg
    }

    private var preferredLanguage: MetadataLanguage {
        Locale.current.language.languageCode?.identifier == "cs" ? .czech : .english
    }

    private var normalizedHardcoverToken: String? {
        let token = settings.hardcoverToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private func lookupConfiguration(language: MetadataLanguage, hardcoverToken: String?) -> String {
        let tokenID: String
        if let hardcoverToken {
            tokenID = SHA256.hash(data: Data(hardcoverToken.utf8))
                .prefix(8)
                .map { String(format: "%02x", $0) }
                .joined()
        } else {
            tokenID = "none"
        }
        return "catalog-v2|language:\(language.rawValue)|hardcover:\(tokenID)"
    }
}
