import Foundation
import SwiftData
import Synchronization

nonisolated struct PluginBookDTO: Codable, Sendable {
    let uuid: String
    let title: String?
    let author: String?
    let displayTitle: String
    let displayAuthor: String?
    let publisher: String?
    let year: String?
    let language: String?
    let translator: String?
    let isbn: String?
    let series: String?
    let seriesIndex: String?
    let tags: [String]
    let description: String?
    let rating: Int?
    let communityRating: Double?
    let readingStatus: String?
    let format: String
    let fileSizeBytes: Int64
    let dateAdded: Date
    let workUUID: String?
    let workTitle: String?
    let editionCount: Int
    let formats: [String]
    let physicalCopy: Bool
    let shelfLocation: String?

    @MainActor init(_ book: Book) {
        uuid = book.uuid.uuidString
        title = book.title
        author = book.author
        displayTitle = book.displayTitle
        displayAuthor = book.displayAuthor
        publisher = book.publisher
        year = book.year
        language = book.language
        translator = book.translator
        isbn = book.isbn
        series = book.series
        seriesIndex = book.seriesIndex
        tags = book.tags
        description = book.bookDescription
        rating = book.rating
        communityRating = book.communityRating
        readingStatus = book.readingStatusRaw
        format = book.format.lowercased()
        fileSizeBytes = book.fileSizeBytes
        dateAdded = book.dateAdded
        workUUID = book.work?.uuid.uuidString
        workTitle = book.work?.title
        editionCount = max(book.work?.editions.count ?? 1, 1)
        formats = book.assetFormats.map { $0.lowercased() }
        physicalCopy = book.hasPhysicalCopy
        shelfLocation = book.shelfLocation
    }
}

nonisolated struct PluginFetchedMetadataDTO: Codable, Sendable {
    let title: String?
    let authors: [String]
    let publisher: String?
    let year: String?
    let description: String?
    let subjects: [String]
    let ratingsAverage: Double?
    let ratingsCount: Int?
    let ratingsSource: String?

    init(_ fetched: FetchedMetadata) {
        title = fetched.title
        authors = fetched.authors
        publisher = fetched.publisher
        year = fetched.year
        description = fetched.bookDescription
        subjects = fetched.subjects
        ratingsAverage = fetched.ratingsAverage
        ratingsCount = fetched.ratingsCount
        ratingsSource = fetched.ratingsSource
    }
}

nonisolated struct PluginApplyResultDTO: Codable, Sendable {
    let applied: [String]
}

nonisolated struct PluginBookPageDTO: Codable, Sendable {
    let items: [PluginBookDTO]
    let nextCursor: String?
}

nonisolated enum PluginLibraryLimits {
    static let defaultPageSize = 50
    static let maximumPageSize = 100
    static let maximumScannedBooksPerPage = 500
    static let maximumCursorOffset = 100_000
    static let maximumSearchBytes = 256
}

nonisolated struct PluginSessionLease: Hashable, Sendable {
    let id: UUID
    let pluginID: String
    let contentDigest: String
}

private nonisolated final class PluginSessionRegistry: Sendable {
    private let active = Mutex(Set<PluginSessionLease>())

    func issue(pluginID: String, contentDigest: String) -> PluginSessionLease {
        let lease = PluginSessionLease(
            id: UUID(),
            pluginID: pluginID,
            contentDigest: contentDigest
        )
        active.withLock { $0.insert(lease) }
        return lease
    }

    func invalidate(_ lease: PluginSessionLease) {
        active.withLock { $0.remove(lease) }
    }

    func contains(_ lease: PluginSessionLease) -> Bool {
        active.withLock { $0.contains(lease) }
    }
}

nonisolated final class PluginStorageRepository: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cz.annajung.Winston.plugin-storage")

    func get(
        _ key: String,
        for manifest: PluginManifest,
        sessionIsValid: @escaping @Sendable () -> Bool
    ) async -> Result<Data?, PluginError> {
        await perform {
            guard sessionIsValid() else { return .failure(Self.inactiveSessionError) }
            do {
                return .success(try Self.load(for: manifest)[key].map { Data($0.utf8) })
            } catch let error as PluginError {
                return .failure(error)
            } catch {
                return .failure(.unavailable("could not read plugin storage"))
            }
        }
    }

    func set(
        _ valueJSON: String,
        for key: String,
        manifest: PluginManifest,
        sessionIsValid: @escaping @Sendable () -> Bool
    ) async -> Result<Data?, PluginError> {
        await perform {
            guard sessionIsValid() else { return .failure(Self.inactiveSessionError) }
            do {
                var store = try Self.load(for: manifest)
                store[key] = valueJSON
                guard sessionIsValid() else { return .failure(Self.inactiveSessionError) }
                return Self.save(store, for: manifest)
            } catch let error as PluginError {
                return .failure(error)
            } catch {
                return .failure(.unavailable("could not read plugin storage"))
            }
        }
    }

    func remove(
        _ key: String,
        for manifest: PluginManifest,
        sessionIsValid: @escaping @Sendable () -> Bool
    ) async -> Result<Data?, PluginError> {
        await perform {
            guard sessionIsValid() else { return .failure(Self.inactiveSessionError) }
            do {
                var store = try Self.load(for: manifest)
                store.removeValue(forKey: key)
                guard sessionIsValid() else { return .failure(Self.inactiveSessionError) }
                return Self.save(store, for: manifest)
            } catch let error as PluginError {
                return .failure(error)
            } catch {
                return .failure(.unavailable("could not read plugin storage"))
            }
        }
    }

    private func perform(
        _ operation: @escaping @Sendable () -> Result<Data?, PluginError>
    ) async -> Result<Data?, PluginError> {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: operation())
            }
        }
    }

    private static func storageURL(for manifest: PluginManifest) -> URL {
        AppPaths.pluginDataDirectory(for: manifest.id).appending(path: "storage.json")
    }

    private static let inactiveSessionError = PluginError.unavailable(
        "plugin session is no longer active"
    )

    private static func load(for manifest: PluginManifest) throws -> [String: String] {
        let url = storageURL(for: manifest)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return [:] }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= PluginStorageLimits.maxFileBytes else {
            throw PluginError.unavailable("plugin storage exceeds its 2 MB quota")
        }
        guard let store = try? JSONDecoder().decode([String: String].self, from: data) else {
            throw PluginError.unavailable("plugin storage is unreadable")
        }
        guard store.count <= PluginStorageLimits.maxEntries,
              store.allSatisfy({
                  PluginStorageLimits.accepts(key: $0.key)
                      && $0.value.utf8.count <= PluginStorageLimits.maxValueBytes
              }) else {
            throw PluginError.unavailable("plugin storage exceeds its entry or value limit")
        }
        return store
    }

    private static func save(
        _ store: [String: String],
        for manifest: PluginManifest
    ) -> Result<Data?, PluginError> {
        do {
            try AppPaths.ensurePluginDataDirectory(for: manifest.id)
            guard store.count <= PluginStorageLimits.maxEntries,
                  store.allSatisfy({
                      PluginStorageLimits.accepts(key: $0.key)
                          && $0.value.utf8.count <= PluginStorageLimits.maxValueBytes
                  }) else {
                return .failure(.invalidArgument("plugin storage exceeds its entry or value limit"))
            }
            let data = try JSONEncoder().encode(store)
            guard data.count <= PluginStorageLimits.maxFileBytes else {
                return .failure(.invalidArgument("plugin storage exceeds its 2 MB quota"))
            }
            try data.write(to: storageURL(for: manifest), options: .atomic)
            return .success(nil)
        } catch {
            return .failure(.unavailable("could not persist plugin storage: \(error.localizedDescription)"))
        }
    }
}

@MainActor
final class PluginHostAPI {
    private let modelContext: ModelContext
    private let settings: AppSettings
    private let toasts: ToastCenter
    private let online: any OnlineMetadataFetching
    private let mutations: CatalogMutationService
    private let storage = PluginStorageRepository()
    private let sessions = PluginSessionRegistry()

    init(modelContext: ModelContext, settings: AppSettings, toasts: ToastCenter,
         online: any OnlineMetadataFetching = OnlineMetadataService(),
         mutations: CatalogMutationService? = nil) {
        self.modelContext = modelContext
        self.settings = settings
        self.toasts = toasts
        self.online = online
        self.mutations = mutations ?? CatalogMutationService(modelContext: modelContext)
    }

    func openSession(for manifest: PluginManifest, contentDigest: String) -> PluginSessionLease {
        sessions.issue(pluginID: manifest.id, contentDigest: contentDigest)
    }

    func invalidate(_ session: PluginSessionLease) {
        sessions.invalidate(session)
    }

    func isActive(_ session: PluginSessionLease) -> Bool {
        sessions.contains(session)
    }

    func makeHandler(
        for manifest: PluginManifest,
        granted: Set<PluginPermission>,
        session: PluginSessionLease
    ) -> PluginHostHandler {
        { [weak self] call in
            guard let self else { return .failure(.unavailable("Winston is shutting down")) }
            return await self.handle(
                call,
                manifest: manifest,
                granted: granted,
                session: session
            )
        }
    }

    private func handle(
        _ call: PluginAPICall,
        manifest: PluginManifest,
        granted: Set<PluginPermission>,
        session: PluginSessionLease
    ) async -> Result<Data?, PluginError> {
        guard session.pluginID == manifest.id, sessions.contains(session) else {
            return .failure(Self.inactiveSessionError)
        }
        func require(_ permission: PluginPermission) -> PluginError? {
            granted.contains(permission) ? nil : .permissionDenied("\(permission.rawValue) is not granted")
        }
        let sessionIsValid: @Sendable () -> Bool = { [sessions] in
            sessions.contains(session)
        }

        switch call {
        case .libraryList(let searchText, let cursor, let limit):
            if let denied = require(.libraryRead) { return .failure(denied) }
            switch listBooks(matching: searchText, cursor: cursor, limit: limit) {
            case .success(let page): return encode(page)
            case .failure(let error): return .failure(error)
            }

        case .libraryGet(let uuid):
            if let denied = require(.libraryRead) { return .failure(denied) }
            return encode(book(with: uuid).map(PluginBookDTO.init))

        case .libraryUpdate(let uuid, let patch):
            if let denied = require(.libraryWrite) { return .failure(denied) }
            guard let book = book(with: uuid) else {
                return .failure(.invalidArgument("no book with uuid \(uuid.uuidString)"))
            }
            switch apply(patch, to: book, session: session) {
            case .success(let result): return encode(result)
            case .failure(let error): return .failure(error)
            }

        case .metadataFetch(let isbn, let title, let author):
            if let denied = require(.metadataFetch) { return .failure(denied) }
            guard settings.onlineMetadataEnabled else {
                return .failure(.unavailable("online metadata is disabled in Settings"))
            }
            let language: MetadataLanguage =
                Locale.current.language.languageCode?.identifier == "cs" ? .czech : .english
            let token = settings.hardcoverToken
            let outcome = await online.fetch(isbn: isbn, title: title ?? "", author: author,
                                             language: language,
                                             hardcoverToken: token.isEmpty ? nil : token)
            guard sessions.contains(session), !Task.isCancelled else {
                return .failure(Self.inactiveSessionError)
            }
            return encode(outcome.metadata.map(PluginFetchedMetadataDTO.init))

        case .storageGet(let key):
            return await storage.get(key, for: manifest, sessionIsValid: sessionIsValid)

        case .storageSet(let key, let valueJSON):
            return await storage.set(
                valueJSON,
                for: key,
                manifest: manifest,
                sessionIsValid: sessionIsValid
            )

        case .storageRemove(let key):
            return await storage.remove(key, for: manifest, sessionIsValid: sessionIsValid)

        case .toast(let message, let style):
            if let denied = require(.uiToast) { return .failure(denied) }
            guard sessions.contains(session) else { return .failure(Self.inactiveSessionError) }
            let text = "\(manifest.name): \(message)"
            switch style {
            case .info: toasts.info(text)
            case .success: toasts.success(text)
            case .error: toasts.error(text)
            }
            return .success(nil)
        }
    }

    // MARK: - Library

    private func listBooks(
        matching searchText: String?,
        cursor: String?,
        limit: Int
    ) -> Result<PluginBookPageDTO, PluginError> {
        guard (1 ... PluginLibraryLimits.maximumPageSize).contains(limit) else {
            return .failure(.invalidArgument(
                "library.list limit must be between 1 and \(PluginLibraryLimits.maximumPageSize)"
            ))
        }
        let needle = searchText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard needle.utf8.count <= PluginLibraryLimits.maximumSearchBytes else {
            return .failure(.invalidArgument("library.list search text is too long"))
        }
        guard let offset = Self.cursorOffset(cursor) else {
            return .failure(.invalidArgument("library.list cursor is invalid"))
        }

        let scanLimit = needle.isEmpty
            ? limit
            : min(PluginLibraryLimits.maximumScannedBooksPerPage, max(limit * 5, limit))
        var descriptor = FetchDescriptor<Book>(sortBy: [
            SortDescriptor(\Book.title),
            SortDescriptor(\Book.uuid),
        ])
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = scanLimit + 1
        let fetched: [Book]
        do {
            fetched = try modelContext.fetch(descriptor)
        } catch {
            return .failure(.unavailable("could not read the library"))
        }

        var items: [PluginBookDTO] = []
        var consumed = 0
        for book in fetched.prefix(scanLimit) {
            consumed += 1
            if needle.isEmpty
                || book.displayTitle.localizedCaseInsensitiveContains(needle)
                || book.displayAuthor?.localizedCaseInsensitiveContains(needle) == true {
                items.append(PluginBookDTO(book))
                if items.count == limit { break }
            }
        }
        let nextOffset = offset + consumed
        let hasMore = consumed < fetched.count
            && nextOffset <= PluginLibraryLimits.maximumCursorOffset
        return .success(PluginBookPageDTO(
            items: items,
            nextCursor: hasMore ? "v1:\(nextOffset)" : nil
        ))
    }

    private static func cursorOffset(_ cursor: String?) -> Int? {
        guard let cursor else { return 0 }
        guard cursor.hasPrefix("v1:"),
              let offset = Int(cursor.dropFirst(3)),
              (0 ... PluginLibraryLimits.maximumCursorOffset).contains(offset) else {
            return nil
        }
        return offset
    }

    private func book(with uuid: UUID) -> Book? {
        var descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.uuid == uuid })
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    private func apply(
        _ patch: PluginMetadataPatch,
        to book: Book,
        session: PluginSessionLease
    ) -> Result<PluginApplyResultDTO, PluginError> {
        let bookID = book.uuid
        let expectedFields = applicableFields(in: patch, to: book)
        guard !expectedFields.isEmpty else {
            return .success(PluginApplyResultDTO(applied: []))
        }
        var applied: [String] = []
        let preimage = CatalogBookMetadataPreimage(book)
        do {
            try mutations.commit(
                .pluginUpdate(bookID: bookID, fields: Set(expectedFields)),
                affectedBookIDs: [bookID],
                revertingOnFailure: preimage.restore
            ) {
                guard sessions.contains(session) else { throw Self.inactiveSessionError }
                applied = applyFields(in: patch, to: try mutations.book(id: bookID))
            }
            return .success(PluginApplyResultDTO(applied: applied))
        } catch {
            return .failure(.unavailable("could not persist library changes"))
        }
    }

    private func applicableFields(in patch: PluginMetadataPatch, to book: Book) -> [String] {
        var fields: [String] = []
        func check(_ keyPath: KeyPath<Book, String?>, _ value: String?, _ name: String) {
            guard let value, !value.isEmpty, (book[keyPath: keyPath] ?? "").isEmpty else { return }
            fields.append(name)
        }
        check(\.title, patch.title, "title")
        check(\.author, patch.author, "author")
        check(\.publisher, patch.publisher, "publisher")
        check(\.year, patch.year, "year")
        check(\.language, patch.language, "language")
        check(\.translator, patch.translator, "translator")
        check(\.isbn, patch.isbn, "isbn")
        check(\.series, patch.series, "series")
        check(\.seriesIndex, patch.seriesIndex, "seriesIndex")
        check(\.bookDescription, patch.description, "description")
        if let tags = patch.tags, !tags.isEmpty, book.tags.isEmpty { fields.append("tags") }
        return fields
    }

    private func applyFields(in patch: PluginMetadataPatch, to book: Book) -> [String] {
        var applied: [String] = []
        func fill(_ keyPath: ReferenceWritableKeyPath<Book, String?>, _ value: String?, _ name: String) {
            guard let value, !value.isEmpty, (book[keyPath: keyPath] ?? "").isEmpty else { return }
            book[keyPath: keyPath] = value
            applied.append(name)
        }
        fill(\.title, patch.title, "title")
        fill(\.author, patch.author, "author")
        fill(\.publisher, patch.publisher, "publisher")
        fill(\.year, patch.year, "year")
        fill(\.language, patch.language, "language")
        fill(\.translator, patch.translator, "translator")
        fill(\.isbn, patch.isbn, "isbn")
        fill(\.series, patch.series, "series")
        fill(\.seriesIndex, patch.seriesIndex, "seriesIndex")
        fill(\.bookDescription, patch.description, "description")
        if let tags = patch.tags, !tags.isEmpty, book.tags.isEmpty {
            book.tags = tags
            applied.append("tags")
        }
        return applied
    }

    // MARK: - Encoding

    private func encode<T: Encodable>(_ value: T?) -> Result<Data?, PluginError> {
        guard let value else { return .success(nil) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do { return .success(try encoder.encode(value)) }
        catch { return .failure(.unavailable("could not encode the result")) }
    }

    private static let inactiveSessionError = PluginError.unavailable(
        "plugin session is no longer active"
    )
}
