import CryptoKit
import Foundation

nonisolated struct FetchedMetadata: Sendable, Equatable {
    var title: String?
    var authors: [String] = []
    var publisher: String?
    var year: String?
    var bookDescription: String?
    var subjects: [String] = []
    var coverURL: URL?
    var ratingsAverage: Double?
    var ratingsCount: Int?
    var ratingsSource: String?
    var openLibraryWorkKey: String?
    var hardcoverBookID: String?
}

nonisolated enum MetadataLanguage: String, Sendable, Hashable { case english, czech }

nonisolated struct OnlineMetadataFetchResult: Sendable, Equatable {
    var metadata: FetchedMetadata?
    var reachedNetwork: Bool
}

nonisolated protocol OnlineMetadataFetching: Sendable {
    func fetch(isbn: String?, title: String, author: String?, language: MetadataLanguage,
               hardcoverToken: String?) async -> OnlineMetadataFetchResult
    func downloadCover(_ url: URL) async -> Data?
}

private nonisolated struct NetworkResult<Value: Sendable>: Sendable {
    var value: Value?
    var reachedNetwork: Bool
}

private nonisolated struct HardcoverRating: Sendable {
    var average: Double
    var count: Int?
    var bookID: String?
}

nonisolated struct OnlineMetadataCacheDiagnostics: Sendable, Equatable {
    var cacheEntryCount = 0
    var metadataRequestCount = 0
    var coverDownloadCount = 0
    var cacheHitCount = 0
    var cacheMissCount = 0
    var coalescedMetadataRequestCount = 0
    var coalescedCoverDownloadCount = 0
    var evictionCount = 0
    var expirationCount = 0
    var metadataInFlightCount = 0
    var coverInFlightCount = 0
}

actor OnlineMetadataService: OnlineMetadataFetching {
    private struct CacheKey: Hashable, Sendable {
        var lookup: String
        var language: MetadataLanguage
        var providerConfiguration: String
    }

    private struct CacheEntry: Sendable {
        var metadata: FetchedMetadata
        var expiresAt: Date
        var lastAccess: UInt64
    }

    private struct InFlight<Value: Sendable>: Sendable {
        let id: UUID
        let task: Task<Value, Never>
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.httpAdditionalHeaders = ["User-Agent": "Winston/1.0 (macOS eBook manager)"]
        return URLSession(configuration: config)
    }

    private let session: URLSession
    private let cacheCapacity: Int
    private let cacheTTL: TimeInterval
    private let providerConfigurationGeneration: Int
    private let now: @Sendable () -> Date
    private var nextRequestAt: Date = .distantPast
    private let minInterval: TimeInterval

    private var cache: [CacheKey: CacheEntry] = [:]
    private var inFlightMetadata: [CacheKey: InFlight<OnlineMetadataFetchResult>] = [:]
    private var inFlightCoverDownloads: [String: InFlight<Data?>] = [:]
    private var accessGeneration: UInt64 = 0
    private var diagnosticsState = OnlineMetadataCacheDiagnostics()

    init(
        session: URLSession? = nil,
        cacheCapacity: Int = 256,
        cacheTTL: TimeInterval = 30 * 60,
        minInterval: TimeInterval = 0.34,
        providerConfigurationGeneration: Int = 1,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.session = session ?? Self.makeSession()
        self.cacheCapacity = max(1, cacheCapacity)
        self.cacheTTL = max(0, cacheTTL)
        self.minInterval = max(0, minInterval)
        self.providerConfigurationGeneration = providerConfigurationGeneration
        self.now = now
    }

    func fetch(isbn: String?, title: String, author: String?, language: MetadataLanguage = .english,
               hardcoverToken: String? = nil) async -> OnlineMetadataFetchResult {
        let token = hardcoverToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredToken = token?.isEmpty == false ? token : nil
        let key = cacheKey(
            isbn: isbn,
            title: title,
            author: author,
            language: language,
            hardcoverToken: configuredToken
        )
        if let cached = cachedMetadata(for: key) {
            return OnlineMetadataFetchResult(metadata: cached, reachedNetwork: false)
        }
        diagnosticsState.cacheMissCount += 1

        let request: InFlight<OnlineMetadataFetchResult>
        if let existing = inFlightMetadata[key] {
            diagnosticsState.coalescedMetadataRequestCount += 1
            request = existing
        } else {
            let id = UUID()
            let task = Task {
                await self.performFetch(
                    isbn: isbn,
                    title: title,
                    author: author,
                    language: language,
                    hardcoverToken: configuredToken
                )
            }
            request = InFlight(id: id, task: task)
            inFlightMetadata[key] = request
            diagnosticsState.metadataRequestCount += 1
        }

        let outcome = await request.task.value
        if inFlightMetadata[key]?.id == request.id {
            inFlightMetadata.removeValue(forKey: key)
            if let metadata = outcome.metadata {
                insert(metadata, for: key)
            }
        }
        return outcome
    }

    private func performFetch(
        isbn: String?,
        title: String,
        author: String?,
        language: MetadataLanguage,
        hardcoverToken: String?
    ) async -> OnlineMetadataFetchResult {
        var reachedNetwork = false
        let openLibraryResult = await openLibrary(isbn: isbn, title: title, author: author)
        reachedNetwork = reachedNetwork || openLibraryResult.reachedNetwork
        var resolved = openLibraryResult.value
        if resolved == nil {
            let googleResult = await googleBooks(isbn: isbn, title: title, author: author)
            reachedNetwork = reachedNetwork || googleResult.reachedNetwork
            resolved = googleResult.value
        }
        guard var result = resolved else {
            return OnlineMetadataFetchResult(metadata: nil, reachedNetwork: reachedNetwork)
        }

        if let hardcoverToken {
            let hardcover = await hardcoverRating(
                title: result.title ?? title,
                author: result.authors.first ?? author,
                token: hardcoverToken
            )
            reachedNetwork = reachedNetwork || hardcover.reachedNetwork
            if let rating = hardcover.value {
                result.ratingsAverage = rating.average
                result.ratingsCount = rating.count
                result.ratingsSource = "Hardcover"
                result.hardcoverBookID = rating.bookID
            }
        }

        if result.bookDescription == nil || result.ratingsAverage == nil {
            let resolvedTitle = result.title ?? title
            let resolvedAuthor = result.authors.first ?? author

            func absorb(_ volume: GoogleBooksResponse.VolumeInfo?) {
                guard let volume else { return }
                if result.bookDescription == nil, let desc = volume.description, !desc.isEmpty {
                    result.bookDescription = desc
                }
                if result.ratingsAverage == nil, let average = volume.averageRating {
                    result.ratingsAverage = average
                    result.ratingsCount = volume.ratingsCount
                    result.ratingsSource = "Google Books"
                }
            }

            if language == .czech {
                let czech = await googleVolume(
                    isbn: isbn, title: resolvedTitle, author: resolvedAuthor, language: .czech
                )
                reachedNetwork = reachedNetwork || czech.reachedNetwork
                absorb(czech.value)
            }
            if result.bookDescription == nil || result.ratingsAverage == nil {
                let english = await googleVolume(
                    isbn: isbn, title: resolvedTitle, author: resolvedAuthor, language: .english
                )
                reachedNetwork = reachedNetwork || english.reachedNetwork
                absorb(english.value)
            }
        }

        return OnlineMetadataFetchResult(metadata: result, reachedNetwork: reachedNetwork)
    }

    func downloadCover(_ url: URL) async -> Data? {
        let key = url.absoluteString
        let request: InFlight<Data?>
        if let existing = inFlightCoverDownloads[key] {
            diagnosticsState.coalescedCoverDownloadCount += 1
            request = existing
        } else {
            let id = UUID()
            let task = Task { await self.performCoverDownload(url) }
            request = InFlight(id: id, task: task)
            inFlightCoverDownloads[key] = request
            diagnosticsState.coverDownloadCount += 1
        }

        let data = await request.task.value
        if inFlightCoverDownloads[key]?.id == request.id {
            inFlightCoverDownloads.removeValue(forKey: key)
        }
        return data
    }

    private func performCoverDownload(_ url: URL) async -> Data? {
        guard await throttle() else { return nil }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count > 1_000 else { return nil }
        return data
    }

    func cacheDiagnostics() -> OnlineMetadataCacheDiagnostics {
        var result = diagnosticsState
        result.cacheEntryCount = cache.count
        result.metadataInFlightCount = inFlightMetadata.count
        result.coverInFlightCount = inFlightCoverDownloads.count
        return result
    }

    func resetCache(cancelInFlight: Bool = true) {
        cache.removeAll(keepingCapacity: true)
        accessGeneration = 0
        if cancelInFlight {
            for request in inFlightMetadata.values { request.task.cancel() }
            for request in inFlightCoverDownloads.values { request.task.cancel() }
            inFlightMetadata.removeAll()
            inFlightCoverDownloads.removeAll()
        }
    }

    private func cacheKey(
        isbn: String?,
        title: String,
        author: String?,
        language: MetadataLanguage,
        hardcoverToken: String?
    ) -> CacheKey {
        let normalizedISBN = (isbn ?? "")
            .uppercased()
            .filter { $0.isNumber || $0 == "X" }
        let lookup = normalizedISBN.isEmpty
            ? "t:\(title.normalizedMatchKey)|a:\((author ?? "").normalizedMatchKey)"
            : "isbn:\(normalizedISBN)"
        let tokenConfiguration = hardcoverToken.map(Self.tokenDigest) ?? "none"
        return CacheKey(
            lookup: lookup,
            language: language,
            providerConfiguration: "v\(providerConfigurationGeneration)|hardcover:\(tokenConfiguration)"
        )
    }

    private static func tokenDigest(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func cachedMetadata(for key: CacheKey) -> FetchedMetadata? {
        guard var entry = cache[key] else { return nil }
        guard entry.expiresAt > now() else {
            cache.removeValue(forKey: key)
            diagnosticsState.expirationCount += 1
            return nil
        }
        accessGeneration &+= 1
        entry.lastAccess = accessGeneration
        cache[key] = entry
        diagnosticsState.cacheHitCount += 1
        return entry.metadata
    }

    private func insert(_ metadata: FetchedMetadata, for key: CacheKey) {
        let currentTime = now()
        let expiredKeys = cache.compactMap { cacheKey, entry in
            entry.expiresAt <= currentTime ? cacheKey : nil
        }
        for expiredKey in expiredKeys {
            cache.removeValue(forKey: expiredKey)
            diagnosticsState.expirationCount += 1
        }

        accessGeneration &+= 1
        cache[key] = CacheEntry(
            metadata: metadata,
            expiresAt: currentTime.addingTimeInterval(cacheTTL),
            lastAccess: accessGeneration
        )
        while cache.count > cacheCapacity,
              let leastRecentlyUsed = cache.min(by: {
                  $0.value.lastAccess < $1.value.lastAccess
              })?.key {
            cache.removeValue(forKey: leastRecentlyUsed)
            diagnosticsState.evictionCount += 1
        }
    }

    // MARK: - Throttle

    private func throttle() async -> Bool {
        let now = Date.now
        let slot = max(now, nextRequestAt)
        nextRequestAt = slot.addingTimeInterval(minInterval)
        let delay = slot.timeIntervalSince(now)
        if delay > 0 {
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return false
            }
        }
        return !Task.isCancelled
    }

    private func getJSON<T: Decodable & Sendable>(_ type: T.Type, from url: URL) async -> NetworkResult<T> {
        guard await throttle() else { return NetworkResult(value: nil, reachedNetwork: false) }
        guard let (data, response) = try? await session.data(from: url) else {
            return NetworkResult(value: nil, reachedNetwork: false)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            return NetworkResult(value: nil, reachedNetwork: true)
        }
        return NetworkResult(value: try? JSONDecoder().decode(T.self, from: data), reachedNetwork: true)
    }

    // MARK: - Open Library

    private func openLibrary(isbn: String?, title: String, author: String?) async -> NetworkResult<FetchedMetadata> {
        var components = URLComponents(string: "https://openlibrary.org/search.json")!
        var items = [URLQueryItem(name: "limit", value: "5"),
                     URLQueryItem(name: "fields", value: "key,title,author_name,first_publish_year,publisher,cover_i,subject,ratings_average,ratings_count")]
        if let isbn, !isbn.isEmpty {
            items.append(URLQueryItem(name: "isbn", value: isbn))
        } else {
            items.append(URLQueryItem(name: "title", value: title))
            if let author, !author.isEmpty { items.append(URLQueryItem(name: "author", value: author)) }
        }
        components.queryItems = items
        guard let url = components.url else { return NetworkResult(value: nil, reachedNetwork: false) }
        let network = await getJSON(OpenLibrarySearch.self, from: url)
        guard let response = network.value else { return NetworkResult(value: nil, reachedNetwork: network.reachedNetwork) }

        let trusted = isbn?.isEmpty == false
        guard let doc = response.docs.first(where: { trusted || TitleMatcher.matches($0.title, title) }) else {
            return NetworkResult(value: nil, reachedNetwork: network.reachedNetwork)
        }

        var meta = FetchedMetadata()
        meta.title = doc.title
        meta.authors = doc.author_name ?? []
        meta.publisher = doc.publisher?.first
        meta.year = doc.first_publish_year.map(String.init)
        meta.subjects = Array((doc.subject ?? []).prefix(8))
        meta.openLibraryWorkKey = doc.key
        if let average = doc.ratings_average {
            meta.ratingsAverage = average
            meta.ratingsCount = doc.ratings_count
            meta.ratingsSource = "Open Library"
        }
        if let coverID = doc.cover_i {
            meta.coverURL = URL(string: "https://covers.openlibrary.org/b/id/\(coverID)-L.jpg")
        }
        return NetworkResult(value: meta, reachedNetwork: network.reachedNetwork)
    }

    private func googleVolume(isbn: String?, title: String, author: String?,
                              language: MetadataLanguage) async -> NetworkResult<GoogleBooksResponse.VolumeInfo> {
        var query = ""
        if let isbn, !isbn.isEmpty {
            query = "isbn:\(isbn)"
        } else {
            query = "intitle:\(title)"
            if let author, !author.isEmpty { query += "+inauthor:\(author)" }
        }
        var components = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")!
        var items = [URLQueryItem(name: "q", value: query),
                     URLQueryItem(name: "maxResults", value: "5")]
        if language == .czech { items.append(URLQueryItem(name: "langRestrict", value: "cs")) }
        components.queryItems = items
        guard let url = components.url else { return NetworkResult(value: nil, reachedNetwork: false) }
        let network = await getJSON(GoogleBooksResponse.self, from: url)
        guard let response = network.value else { return NetworkResult(value: nil, reachedNetwork: network.reachedNetwork) }

        let trusted = isbn?.isEmpty == false
        let volume = response.items?.compactMap(\.volumeInfo)
            .first { trusted || TitleMatcher.matches($0.title, title) }
        return NetworkResult(value: volume, reachedNetwork: network.reachedNetwork)
    }

    // MARK: - Google Books (fallback)

    private func googleBooks(isbn: String?, title: String, author: String?) async -> NetworkResult<FetchedMetadata> {
        var query = ""
        if let isbn, !isbn.isEmpty {
            query = "isbn:\(isbn)"
        } else {
            query = "intitle:\(title)"
            if let author, !author.isEmpty { query += "+inauthor:\(author)" }
        }
        var components = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")!
        components.queryItems = [URLQueryItem(name: "q", value: query),
                                 URLQueryItem(name: "maxResults", value: "5")]
        guard let url = components.url else { return NetworkResult(value: nil, reachedNetwork: false) }
        let network = await getJSON(GoogleBooksResponse.self, from: url)
        guard let response = network.value else { return NetworkResult(value: nil, reachedNetwork: network.reachedNetwork) }

        let trusted = isbn?.isEmpty == false
        guard let info = response.items?.compactMap(\.volumeInfo)
            .first(where: { trusted || TitleMatcher.matches($0.title, title) }) else {
            return NetworkResult(value: nil, reachedNetwork: network.reachedNetwork)
        }

        var meta = FetchedMetadata()
        meta.title = info.title
        meta.authors = info.authors ?? []
        meta.publisher = info.publisher
        meta.year = info.publishedDate.map { String($0.prefix(4)) }
        meta.bookDescription = info.description
        meta.subjects = Array((info.categories ?? []).prefix(8))
        if let average = info.averageRating {
            meta.ratingsAverage = average
            meta.ratingsCount = info.ratingsCount
            meta.ratingsSource = "Google Books"
        }
        if let thumb = info.imageLinks?.thumbnail {
            meta.coverURL = URL(string: thumb.replacingOccurrences(of: "http://", with: "https://"))
        }
        return NetworkResult(value: meta, reachedNetwork: network.reachedNetwork)
    }

    // MARK: - Hardcover (community ratings)

    private func hardcoverRating(title: String, author: String?,
                                 token: String) async -> NetworkResult<HardcoverRating> {
        let queryText = [title, author].compactMap { $0 }.joined(separator: " ")
        let gql = "query Ratings($q: String!) { search(query: $q, query_type: \"Book\", per_page: 5) { results } }"
        let body: [String: Any] = ["query": gql, "variables": ["q": queryText]]
        guard let url = URL(string: "https://api.hardcover.app/v1/graphql"),
              let payload = try? JSONSerialization.data(withJSONObject: body) else {
            return NetworkResult(value: nil, reachedNetwork: false)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token.hasPrefix("Bearer ") ? token : "Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = payload

        guard await throttle() else { return NetworkResult(value: nil, reachedNetwork: false) }
        guard let (data, response) = try? await session.data(for: request) else {
            return NetworkResult(value: nil, reachedNetwork: false)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(HardcoverResponse.self, from: data),
              let documents = decoded.data?.search?.results?.hits?.compactMap(\.document) else {
            return NetworkResult(value: nil, reachedNetwork: true)
        }

        let match = documents.first { TitleMatcher.matches($0.title, title) && ($0.rating ?? 0) > 0 }
            ?? documents.first { ($0.rating ?? 0) > 0 }
        guard let doc = match, let rating = doc.rating, rating > 0 else {
            return NetworkResult(value: nil, reachedNetwork: true)
        }
        return NetworkResult(
            value: HardcoverRating(average: rating, count: doc.ratings_count, bookID: doc.id),
            reachedNetwork: true
        )
    }

}

// MARK: - Wire formats

private nonisolated struct OpenLibrarySearch: Decodable, Sendable {
    let docs: [Doc]
    struct Doc: Decodable, Sendable {
        let key: String?
        let title: String?
        let author_name: [String]?
        let first_publish_year: Int?
        let publisher: [String]?
        let cover_i: Int?
        let subject: [String]?
        let ratings_average: Double?
        let ratings_count: Int?
    }
}

private nonisolated struct GoogleBooksResponse: Decodable, Sendable {
    let items: [Item]?
    struct Item: Decodable, Sendable { let volumeInfo: VolumeInfo? }
    struct VolumeInfo: Decodable, Sendable {
        let title: String?
        let authors: [String]?
        let publisher: String?
        let publishedDate: String?
        let description: String?
        let categories: [String]?
        let imageLinks: ImageLinks?
        let averageRating: Double?
        let ratingsCount: Int?
    }
    struct ImageLinks: Decodable, Sendable { let thumbnail: String? }
}

private nonisolated struct HardcoverResponse: Decodable, Sendable {
    let data: DataField?
    struct DataField: Decodable, Sendable { let search: SearchField? }
    struct SearchField: Decodable, Sendable { let results: Results? }
    struct Results: Decodable, Sendable { let hits: [Hit]? }
    struct Hit: Decodable, Sendable { let document: Document? }
    struct Document: Decodable, Sendable {
        let id: String?
        let title: String?
        let rating: Double?
        let ratings_count: Int?
    }
}
