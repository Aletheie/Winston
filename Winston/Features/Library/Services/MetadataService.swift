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
        let patch = CatalogBookPatch(
            fields: [
                .title, .author, .publisher, .year, .series, .seriesIndex,
                .language, .translator, .isbn, .description, .tags, .shelfLocation,
            ],
            title: title,
            author: author,
            publisher: publisher,
            year: year,
            language: language,
            translator: translator,
            isbn: isbn,
            series: series,
            seriesIndex: seriesIndex,
            bookDescription: description,
            tags: tags,
            shelfLocation: shelfLocation
        )
        return succeeded(mutations.execute(.updateBook(
            CatalogBookUpdate(
                bookID: bookID,
                patch: patch,
                identityScope: identityScope
            ),
            source: .manual
        )))
    }

    @discardableResult
    func updateRating(for book: Book, rating: Int?) -> Bool {
        let bookID = book.uuid
        return succeeded(mutations.execute(.updateBook(
            CatalogBookUpdate(
                bookID: bookID,
                patch: CatalogBookPatch(fields: [.rating], rating: rating)
            ),
            source: .manual
        )))
    }

    @discardableResult
    func updateNotes(_ notes: String, for book: Book) -> Bool {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookID = book.uuid
        return succeeded(mutations.execute(.updateBook(
            CatalogBookUpdate(
                bookID: bookID,
                patch: CatalogBookPatch(
                    fields: [.notes],
                    notes: trimmed.isEmpty ? nil : notes
                )
            ),
            source: .manual
        )))
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
        return succeeded(mutations.execute(.updateBook(
            CatalogBookUpdate(
                bookID: bookID,
                patch: CatalogBookPatch(
                    fields: [.sampleNoticeDismissed],
                    sampleNoticeDismissed: true
                )
            ),
            source: .manual
        )))
    }

    @discardableResult
    func bulkUpdate(_ books: [Book], _ edit: BulkEdit) -> Bool {
        let selectedIDs = Set(books.map(\.uuid))
        guard !selectedIDs.isEmpty else { return true }
        var fields: Set<CatalogBookMetadataField> = []
        if edit.author != nil { fields.insert(.author) }
        if edit.publisher != nil { fields.insert(.publisher) }
        if edit.year != nil { fields.insert(.year) }
        if edit.series != nil { fields.insert(.series) }
        if edit.language != nil { fields.insert(.language) }
        if edit.translator != nil { fields.insert(.translator) }
        if edit.tags != nil { fields.insert(.tags) }
        let patch = CatalogBookPatch(
            fields: fields,
            author: edit.author.flatMap(Self.nilIfEmpty),
            publisher: edit.publisher.flatMap(Self.nilIfEmpty),
            year: edit.year.flatMap(Self.nilIfEmpty),
            language: edit.language.flatMap(Self.nilIfEmpty),
            translator: edit.translator.flatMap(Self.nilIfEmpty),
            series: edit.series.flatMap(Self.nilIfEmpty),
            tags: edit.tags ?? []
        )
        let tagMode: CatalogTagUpdateMode = edit.tagMode == .replace ? .replace : .add
        let updates = selectedIDs.map {
            CatalogBookUpdate(
                bookID: $0,
                patch: patch,
                identityScope: edit.authorIdentityScope,
                tagMode: tagMode,
                readingStatus: edit.status
            )
        }
        return succeeded(mutations.execute(.updateBooks(updates, operation: "bulkEdit")))
    }

    // MARK: - Tag / series / author management

    @discardableResult
    func renameTag(_ old: String, to new: String) -> Bool {
        let name = new.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != old else { return true }
        let updates = ((try? modelContext.fetchAllBooksForGlobalAnalysis()) ?? [])
            .filter { $0.tags.contains(old) }
            .map {
                CatalogBookUpdate(
                    bookID: $0.uuid,
                    patch: CatalogBookPatch(
                        fields: [.tags],
                        tags: Array(Set($0.tags.filter { $0 != old } + [name])).sorted()
                    )
                )
            }
        guard !updates.isEmpty else { return true }
        return succeeded(mutations.execute(.updateBooks(updates, operation: "renameTag")))
    }

    @discardableResult
    func deleteTag(_ tag: String) -> Bool {
        let updates = ((try? modelContext.fetchAllBooksForGlobalAnalysis()) ?? [])
            .filter { $0.tags.contains(tag) }
            .map {
                CatalogBookUpdate(
                    bookID: $0.uuid,
                    patch: CatalogBookPatch(
                        fields: [.tags],
                        tags: $0.tags.filter { $0 != tag }
                    )
                )
            }
        guard !updates.isEmpty else { return true }
        return succeeded(mutations.execute(.updateBooks(updates, operation: "deleteTag")))
    }

    @discardableResult
    func renameSeries(_ old: String, to new: String) -> Bool {
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.series == old })
        let ids = Set(((try? modelContext.fetch(descriptor)) ?? []).map(\.uuid))
        guard !ids.isEmpty else { return true }
        let series = Self.nilIfEmpty(new)
        let updates = ids.map {
            CatalogBookUpdate(
                bookID: $0,
                patch: CatalogBookPatch(fields: [.series], series: series)
            )
        }
        return succeeded(mutations.execute(.updateBooks(updates, operation: "renameSeries")))
    }

    @discardableResult
    func renameAuthor(_ old: String, to new: String) -> Bool {
        let ids = Set(((try? modelContext.fetchAllBooksForGlobalAnalysis()) ?? [])
            .filter { $0.displayAuthor == old }.map(\.uuid))
        guard !ids.isEmpty else { return true }
        let author = Self.nilIfEmpty(new)
        let updates = ids.map {
            CatalogBookUpdate(
                bookID: $0,
                patch: CatalogBookPatch(fields: [.author], author: author),
                identityScope: .workIdentity
            )
        }
        return succeeded(mutations.execute(.updateBooks(updates, operation: "renameAuthor")))
    }

    @discardableResult
    func applyMetadataFix(_ fix: MetadataFix) -> Bool {
        applyMetadataFixes([fix])
    }

    @discardableResult
    func applyMetadataFixes(_ fixes: [MetadataFix]) -> Bool {
        guard !fixes.isEmpty else { return true }
        let catalogBooks = (try? modelContext.fetchAllBooksForGlobalAnalysis()) ?? []
        var updates: [CatalogBookUpdate] = []
        for fix in fixes {
            switch fix.kind {
            case .author:
                let author = Self.nilIfEmpty(fix.suggestion)
                updates.append(contentsOf: catalogBooks
                    .filter { $0.displayAuthor == fix.original }
                    .map {
                        CatalogBookUpdate(
                            bookID: $0.uuid,
                            patch: CatalogBookPatch(fields: [.author], author: author),
                            identityScope: .workIdentity
                        )
                    })
            case .series:
                let series = Self.nilIfEmpty(fix.suggestion)
                updates.append(contentsOf: catalogBooks
                    .filter { $0.series == fix.original }
                    .map {
                        CatalogBookUpdate(
                            bookID: $0.uuid,
                            patch: CatalogBookPatch(fields: [.series], series: series)
                        )
                    })
            case .seriesAssignment:
                guard let bookID = fix.bookID,
                      let book = catalogBooks.first(where: { $0.uuid == bookID }),
                      book.series?.trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty != false,
                      let series = Self.nilIfEmpty(fix.suggestion) else { continue }
                var fields: Set<CatalogBookMetadataField> = [.series]
                var seriesIndex: String?
                if book.seriesIndex?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty != false {
                    fields.insert(.seriesIndex)
                    seriesIndex = fix.seriesIndex
                }
                updates.append(
                    CatalogBookUpdate(
                        bookID: bookID,
                        patch: CatalogBookPatch(
                            fields: fields,
                            series: series,
                            seriesIndex: seriesIndex
                        )
                    )
                )
            }
        }
        guard !updates.isEmpty else { return true }
        return succeeded(mutations.execute(.updateBooks(updates, operation: "metadataFixes")))
    }

    private func succeeded(
        _ result: Result<CatalogChangeSet, CatalogMutationError>
    ) -> Bool {
        if case .success = result { return true }
        return false
    }

    private static func nilIfEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
            kind: .onlineEnrichment,
            requestGeneration: configuration
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
