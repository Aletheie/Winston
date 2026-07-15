import Foundation
import SwiftData

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
        format = (book.fileName as NSString).pathExtension.lowercased()
        fileSizeBytes = book.fileSizeBytes
        dateAdded = book.dateAdded
        workUUID = book.work?.uuid.uuidString
        workTitle = book.work?.title
        editionCount = max(book.work?.editions.count ?? 1, 1)
        formats = book.assetFormats.map { $0.lowercased() }
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

@MainActor
final class PluginHostAPI {
    private let modelContext: ModelContext
    private let settings: AppSettings
    private let toasts: ToastCenter
    private let online: any OnlineMetadataFetching

    init(modelContext: ModelContext, settings: AppSettings, toasts: ToastCenter,
         online: any OnlineMetadataFetching = OnlineMetadataService()) {
        self.modelContext = modelContext
        self.settings = settings
        self.toasts = toasts
        self.online = online
    }

    func makeHandler(for manifest: PluginManifest, granted: Set<PluginPermission>) -> PluginHostHandler {
        { [weak self] call in
            guard let self else { return .failure(.unavailable("Winston is shutting down")) }
            return await self.handle(call, manifest: manifest, granted: granted)
        }
    }

    private func handle(_ call: PluginAPICall, manifest: PluginManifest,
                        granted: Set<PluginPermission>) async -> Result<Data?, PluginError> {
        func require(_ permission: PluginPermission) -> PluginError? {
            granted.contains(permission) ? nil : .permissionDenied("\(permission.rawValue) is not granted")
        }

        switch call {
        case .libraryList(let searchText):
            if let denied = require(.libraryRead) { return .failure(denied) }
            return encode(listBooks(matching: searchText))

        case .libraryGet(let uuid):
            if let denied = require(.libraryRead) { return .failure(denied) }
            return encode(book(with: uuid).map(PluginBookDTO.init))

        case .libraryUpdate(let uuid, let patch):
            if let denied = require(.libraryWrite) { return .failure(denied) }
            guard let book = book(with: uuid) else {
                return .failure(.invalidArgument("no book with uuid \(uuid.uuidString)"))
            }
            return encode(apply(patch, to: book))

        case .metadataFetch(let isbn, let title, let author):
            if let denied = require(.libraryRead) { return .failure(denied) }
            guard settings.onlineMetadataEnabled else {
                return .failure(.unavailable("online metadata is disabled in Settings"))
            }
            let language: MetadataLanguage =
                Locale.current.language.languageCode?.identifier == "cs" ? .czech : .english
            let token = settings.hardcoverToken
            let outcome = await online.fetch(isbn: isbn, title: title ?? "", author: author,
                                             language: language,
                                             hardcoverToken: token.isEmpty ? nil : token)
            return encode(outcome.metadata.map(PluginFetchedMetadataDTO.init))

        case .storageGet(let key):
            do {
                let store = try loadStorage(for: manifest)
                return .success(store[key].map { Data($0.utf8) })
            } catch let error as PluginError {
                return .failure(error)
            } catch {
                return .failure(.unavailable("could not read plugin storage"))
            }

        case .storageSet(let key, let valueJSON):
            do {
                var store = try loadStorage(for: manifest)
                store[key] = valueJSON
                return saveStorage(store, for: manifest)
            } catch let error as PluginError {
                return .failure(error)
            } catch {
                return .failure(.unavailable("could not read plugin storage"))
            }

        case .storageRemove(let key):
            do {
                var store = try loadStorage(for: manifest)
                store.removeValue(forKey: key)
                return saveStorage(store, for: manifest)
            } catch let error as PluginError {
                return .failure(error)
            } catch {
                return .failure(.unavailable("could not read plugin storage"))
            }

        case .toast(let message, let style):
            if let denied = require(.uiToast) { return .failure(denied) }
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

    private func listBooks(matching searchText: String?) -> [PluginBookDTO] {
        let books = (try? modelContext.fetch(FetchDescriptor<Book>())) ?? []
        let needle = searchText?.lowercased() ?? ""
        return books
            .filter {
                needle.isEmpty
                    || $0.displayTitle.lowercased().contains(needle)
                    || ($0.displayAuthor?.lowercased().contains(needle) ?? false)
            }
            .sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
            .map(PluginBookDTO.init)
    }

    private func book(with uuid: UUID) -> Book? {
        var descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.uuid == uuid })
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    private func apply(_ patch: PluginMetadataPatch, to book: Book) -> PluginApplyResultDTO {
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
        if !applied.isEmpty { modelContext.saveQuietly() }
        return PluginApplyResultDTO(applied: applied)
    }

    // MARK: - Storage (per-plugin key → JSON-fragment string)

    private func storageURL(for manifest: PluginManifest) -> URL {
        AppPaths.pluginDataDirectory(for: manifest.id).appending(path: "storage.json")
    }

    private func loadStorage(for manifest: PluginManifest) throws -> [String: String] {
        let url = storageURL(for: manifest)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return [:] }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= PluginStorageLimits.maxFileBytes else {
            throw PluginError.unavailable("plugin storage exceeds its 2 MB quota")
        }
        guard let store = try? JSONDecoder().decode([String: String].self, from: data) else {
            throw PluginError.unavailable("plugin storage is unreadable")
        }
        return store
    }

    private func saveStorage(_ store: [String: String], for manifest: PluginManifest) -> Result<Data?, PluginError> {
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

    // MARK: - Encoding

    private func encode<T: Encodable>(_ value: T?) -> Result<Data?, PluginError> {
        guard let value else { return .success(nil) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do { return .success(try encoder.encode(value)) }
        catch { return .failure(.unavailable("could not encode the result")) }
    }
}
