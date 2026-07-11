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
}

actor OnlineMetadataService: OnlineMetadataFetching {
    private struct CacheKey: Hashable {
        var lookup: String
        var language: MetadataLanguage
        var hardcoverToken: String?
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.httpAdditionalHeaders = ["User-Agent": "Winston/1.0 (macOS eBook manager)"]
        return URLSession(configuration: config)
    }()

    private var nextRequestAt: Date = .distantPast
    private let minInterval: TimeInterval = 0.34

    private var cache: [CacheKey: FetchedMetadata] = [:]

    func fetch(isbn: String?, title: String, author: String?, language: MetadataLanguage = .english,
               hardcoverToken: String? = nil) async -> OnlineMetadataFetchResult {
        let lookup: String
        if let isbn, !isbn.isEmpty {
            lookup = "isbn:\(isbn)"
        } else {
            lookup = "t:\(title.lowercased())|a:\(author?.lowercased() ?? "")"
        }
        let token = hardcoverToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredToken = token?.isEmpty == false ? token : nil
        let key = CacheKey(lookup: lookup, language: language, hardcoverToken: configuredToken)
        if let cached = cache[key] {
            return OnlineMetadataFetchResult(metadata: cached, reachedNetwork: false)
        }

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

        if let configuredToken {
            let hardcover = await hardcoverRating(
                title: result.title ?? title,
                author: result.authors.first ?? author,
                token: configuredToken
            )
            reachedNetwork = reachedNetwork || hardcover.reachedNetwork
            if let rating = hardcover.value {
                result.ratingsAverage = rating.average
                result.ratingsCount = rating.count
                result.ratingsSource = "Hardcover"
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

        cache[key] = result
        return OnlineMetadataFetchResult(metadata: result, reachedNetwork: reachedNetwork)
    }

    func downloadCover(_ url: URL) async -> Data? {
        guard await throttle() else { return nil }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count > 1_000 else { return nil }
        return data
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
                     URLQueryItem(name: "fields", value: "title,author_name,first_publish_year,publisher,cover_i,subject,ratings_average,ratings_count")]
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
            value: HardcoverRating(average: rating, count: doc.ratings_count),
            reachedNetwork: true
        )
    }

}

// MARK: - Wire formats

private nonisolated struct OpenLibrarySearch: Decodable, Sendable {
    let docs: [Doc]
    struct Doc: Decodable, Sendable {
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
        let title: String?
        let rating: Double?
        let ratings_count: Int?
    }
}
