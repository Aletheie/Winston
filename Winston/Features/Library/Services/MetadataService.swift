import Foundation
import SwiftData
import AppKit
import CryptoKit

@MainActor
@Observable
final class MetadataService {
    private let modelContext: ModelContext
    private let settings: AppSettings
    private let online: any OnlineMetadataFetching
    private let covers: CoverRepository
    private let mutations: CatalogMutationService

    private(set) var enrichingUUIDs: Set<UUID> = []
    private(set) var metadataFetchSummary: String?

    init(
        modelContext: ModelContext,
        settings: AppSettings,
        online: any OnlineMetadataFetching = OnlineMetadataService(),
        covers: CoverRepository = .shared,
        mutations: CatalogMutationService? = nil
    ) {
        self.modelContext = modelContext
        self.settings = settings
        self.online = online
        self.covers = covers
        self.mutations = mutations ?? CatalogMutationService(modelContext: modelContext)
    }

    var isFetchingOnline: Bool { !enrichingUUIDs.isEmpty }

    // MARK: - Manual edits

    @discardableResult
    func updateMetadata(
        for book: Book,
        title: String?, author: String?, publisher: String?, year: String?,
        series: String?, seriesIndex: String?, language: String?, translator: String?, isbn: String?,
        description: String?, tags: [String], shelfLocation: String?
    ) -> Bool {
        let bookID = book.uuid
        let fields: Set<String> = [
            "title", "author", "publisher", "year", "series", "seriesIndex",
            "language", "translator", "isbn", "description", "tags", "shelfLocation",
        ]
        return commit(.updateMetadata(bookID: bookID, fields: fields), bookIDs: [bookID]) {
            let book = try mutations.book(id: bookID)
            book.title = title
            book.author = author
            book.publisher = publisher
            book.year = year
            book.series = series
            book.seriesIndex = seriesIndex
            book.language = language
            book.translator = translator
            book.isbn = isbn
            book.bookDescription = description
            book.tags = tags
            book.shelfLocation = shelfLocation
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
        guard book.pageCount == nil, book.modelContext != nil,
              let url = book.primaryFileURL else { return }
        let format = book.format
        guard let pages = await PageCountEstimator.pageCount(at: url, format: format) else { return }
        guard book.modelContext != nil, book.pageCount == nil else { return }
        book.pageCount = pages
        modelContext.saveQuietly()
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
        let ids = Set(books.map(\.uuid))
        return commit(.updateMetadataBatch(bookIDs: Array(ids), operation: "bulkEdit"), bookIDs: ids) {
            for book in try mutations.books(ids: ids) {
                if let author = edit.author       { book.author = author.isEmpty ? nil : author }
                if let publisher = edit.publisher { book.publisher = publisher.isEmpty ? nil : publisher }
                if let year = edit.year           { book.year = year.isEmpty ? nil : year }
                if let series = edit.series       { book.series = series.isEmpty ? nil : series }
                if let language = edit.language   { book.language = language.isEmpty ? nil : language }
                if let translator = edit.translator { book.translator = translator.isEmpty ? nil : translator }
                if let status = edit.status       { book.setStatus(status) }
                if let tags = edit.tags {
                    switch edit.tagMode {
                    case .replace: book.tags = tags
                    case .add:     book.tags = (book.tags + tags).uniquedSorted()
                    }
                }
            }
        }
    }

    // MARK: - Tag / series / author management

    @discardableResult
    func renameTag(_ old: String, to new: String) -> Bool {
        let name = new.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != old else { return true }
        let ids = Set(modelContext.allBooks().filter { $0.tags.contains(old) }.map(\.uuid))
        guard !ids.isEmpty else { return true }
        return commit(.updateMetadataBatch(bookIDs: Array(ids), operation: "renameTag"), bookIDs: ids) {
            for book in try mutations.books(ids: ids) {
                book.tags = (book.tags.filter { $0 != old } + [name]).uniquedSorted()
            }
        }
    }

    @discardableResult
    func deleteTag(_ tag: String) -> Bool {
        let ids = Set(modelContext.allBooks().filter { $0.tags.contains(tag) }.map(\.uuid))
        guard !ids.isEmpty else { return true }
        return commit(.updateMetadataBatch(bookIDs: Array(ids), operation: "deleteTag"), bookIDs: ids) {
            for book in try mutations.books(ids: ids) {
                book.tags.removeAll { $0 == tag }
            }
        }
    }

    @discardableResult
    func renameSeries(_ old: String, to new: String) -> Bool {
        let ids = Set(modelContext.allBooks().filter { $0.series == old }.map(\.uuid))
        guard !ids.isEmpty else { return true }
        return commit(.updateMetadataBatch(bookIDs: Array(ids), operation: "renameSeries"), bookIDs: ids) {
            applySeriesRename(old, to: new)
        }
    }

    @discardableResult
    func renameAuthor(_ old: String, to new: String) -> Bool {
        let ids = Set(modelContext.allBooks().filter { $0.displayAuthor == old }.map(\.uuid))
        guard !ids.isEmpty else { return true }
        return commit(.updateMetadataBatch(bookIDs: Array(ids), operation: "renameAuthor"), bookIDs: ids) {
            applyAuthorRename(old, to: new)
        }
    }

    @discardableResult
    func applyMetadataFix(_ fix: MetadataFix) -> Bool {
        applyMetadataFixes([fix])
    }

    @discardableResult
    func applyMetadataFixes(_ fixes: [MetadataFix]) -> Bool {
        guard !fixes.isEmpty else { return true }
        let ids = Set(modelContext.allBooks().map(\.uuid))
        return commit(.updateMetadataBatch(bookIDs: Array(ids), operation: "metadataFixes"), bookIDs: ids) {
            for fix in fixes { applyMetadataFixCore(fix) }
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

    private func applyMetadataFixCore(_ fix: MetadataFix) {
        switch fix.kind {
        case .author:
            applyAuthorRename(fix.original, to: fix.suggestion)
        case .series:
            applySeriesRename(fix.original, to: fix.suggestion)
        case .seriesAssignment:
            applySeriesAssignment(fix)
        }
    }

    private func applySeriesRename(_ old: String, to new: String) {
        let name = new.trimmingCharacters(in: .whitespaces)
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.series == old })
        for book in (try? modelContext.fetch(descriptor)) ?? [] {
            book.series = name.isEmpty ? nil : name
        }
    }

    private func applyAuthorRename(_ old: String, to new: String) {
        let name = new.trimmingCharacters(in: .whitespaces)
        for book in modelContext.allBooks() where book.displayAuthor == old {
            book.author = name.isEmpty ? nil : name
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
        metadataFetchSummary = nil
        Task {
            var matched = 0
            for book in books where await performEnrich(book, replaceCover: true) { matched += 1 }
            metadataFetchSummary = matched > 0
                ? String(localized: "Updated \(matched) of \(books.count) from online catalogs.")
                : String(localized: "No matching records found online.")
            try? await Task.sleep(for: .seconds(6))
            if !isFetchingOnline { metadataFetchSummary = nil }
        }
    }

    func backfillMissingOnlineMetadata() {
        guard settings.onlineMetadataEnabled else { return }
        let language = preferredLanguage
        let token = normalizedHardcoverToken
        let candidates = modelContext.allBooks()
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
        guard !books.isEmpty else { return }
        Task {
            var processed = 0
            for book in books {
                await performEnrich(book, replaceCover: false, save: false)
                processed += 1
                if processed % 20 == 0 { modelContext.saveQuietly() }
            }
            modelContext.saveQuietly()
        }
    }

    @discardableResult
    func performEnrich(_ book: Book, replaceCover: Bool, save: Bool = true) async -> Bool {
        guard book.modelContext != nil else { return false }
        let uuid = book.uuid
        guard !enrichingUUIDs.contains(uuid) else { return false }
        let isbn = book.isbn
        let title = book.displayTitle
        let author = book.displayAuthor
        let hasCover = CoverStore.exists(for: uuid)
        let coverVersion = book.coverVersion
        let coverToken = replaceCover
            ? await covers.beginUserMutation(for: uuid)
            : await covers.beginBackgroundMutation(for: uuid)

        enrichingUUIDs.insert(uuid)
        defer { enrichingUUIDs.remove(uuid) }

        let language = preferredLanguage
        let token = normalizedHardcoverToken
        let configuration = lookupConfiguration(language: language, hardcoverToken: token)
        let outcome = await online.fetch(
            isbn: isbn,
            title: title,
            author: author,
            language: language,
            hardcoverToken: token
        )
        guard let fetched = outcome.metadata else {
            if outcome.reachedNetwork, book.modelContext != nil {
                book.onlineLookupAt = .now
                book.onlineLookupConfiguration = configuration
                if save { modelContext.saveQuietly() }
            }
            return false
        }

        var downloadedCover: NSImage?
        if (replaceCover || !hasCover), let coverURL = fetched.coverURL,
           let data = await online.downloadCover(coverURL) {
            downloadedCover = await Task.detached(priority: .utility) { NSImage(data: data) }.value
        }

        guard book.modelContext != nil else { return false }

        if downloadedCover != nil,
           book.coverVersion != coverVersion || (!replaceCover && CoverStore.exists(for: uuid)) {
            downloadedCover = nil
        }

        var installedCoverVersion: Int?
        var coverRollback: CoverRollbackTicket?
        var installedCoverURL: URL?
        if let image = downloadedCover {
            let fileURL = book.coverCacheURL
            let data = await Task.detached(priority: .utility) {
                ImageTranscoder.jpegData(from: image)
            }.value
            if let data,
               let rollback = await covers.install(
                   data,
                   using: coverToken,
                   onlyIfMissing: !replaceCover
               ),
               await covers.isCurrent(coverToken) {
                coverRollback = rollback
                book.coverVersion += 1
                installedCoverVersion = book.coverVersion
                installedCoverURL = fileURL
                await CoverCache.shared.replace(image, for: fileURL)
                guard book.modelContext != nil else {
                    _ = await covers.rollback(rollback)
                    await CoverCache.shared.replace(
                        rollback.previousData.flatMap(NSImage.init(data:)),
                        for: fileURL
                    )
                    return false
                }
            } else {
                downloadedCover = nil
            }
        }

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
        }
        book.onlineLookupAt = .now
        book.onlineLookupConfiguration = configuration
        if save {
            let coverStillOurs = installedCoverVersion.map { $0 == book.coverVersion } ?? false
            guard modelContext.saveQuietly(rollbackOnFailure: true) else {
                if coverStillOurs,
                   let installedCoverURL,
                   let coverRollback,
                   await covers.rollback(coverRollback) {
                    await CoverCache.shared.replace(
                        coverRollback.previousData.flatMap(NSImage.init(data:)),
                        for: installedCoverURL
                    )
                }
                return false
            }
        }
        return true
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
