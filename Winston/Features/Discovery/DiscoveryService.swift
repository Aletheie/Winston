import Foundation

nonisolated protocol DiscoveryFetching: Sendable {
    func books(matching queryTerm: String, token: String) async -> DiscoveryResult
    func refreshBooks(matching queryTerm: String, token: String) async -> DiscoveryResult
}

extension DiscoveryFetching {
    func refreshBooks(matching queryTerm: String, token: String) async -> DiscoveryResult {
        await books(matching: queryTerm, token: token)
    }
}

actor DiscoveryService: DiscoveryFetching {
    nonisolated enum HTTPDisposition: Equatable {
        case success
        case unauthorized
        case failure
    }

    private nonisolated enum PostResult: Sendable {
        case success(Data)
        case unauthorized
        case failed
    }

    private nonisolated enum GenreResult: Sendable {
        case books([DiscoveryBook])
        case unauthorized
        case failed
    }

    nonisolated static let catalogLimit = 200
    nonisolated static let genreQuery = """
    query NewReleases($genre: String!, $today: date!) {
      books(
        where: {
          taggings: { tag: { tag: { _eq: $genre } } },
          release_date: { _lte: $today },
          image_id: { _is_null: false }
        },
        order_by: [{ release_date: desc_nulls_last }, { id: desc }],
        limit: 200
      ) {
        id title slug rating release_date release_year
        image { url }
        contributions(limit: 3) { author { name } }
      }
    }
    """

    private static let endpoint = URL(string: "https://api.hardcover.app/v1/graphql")!
    private static let cacheVersion = 3
    private static let maximumCacheBytes = 4 * 1024 * 1024
    private static let maximumCacheEntries = 32
    private static let minimumRequestInterval: TimeInterval = 0.34

    private let session: URLSession
    private let cacheURL: URL
    private let cacheLifetime: TimeInterval
    private var cachedEntries: [String: DiscoveryCacheEntry]?
    private var inFlight: [String: Task<GenreResult, Never>] = [:]
    private var nextRequestAt = Date.distantPast

    init(
        session: URLSession? = nil,
        cacheURL: URL? = nil,
        cacheLifetime: TimeInterval = 24 * 60 * 60
    ) {
        self.session = session ?? Self.makeSession()
        self.cacheURL = cacheURL ?? AppPaths.appSupportDirectory
            .appending(path: "DiscoveryCache.json")
        self.cacheLifetime = cacheLifetime
    }

    func books(matching queryTerm: String, token: String) async -> DiscoveryResult {
        await catalog(matching: queryTerm, token: token, forceRefresh: false)
    }

    func refreshBooks(matching queryTerm: String, token: String) async -> DiscoveryResult {
        await catalog(matching: queryTerm, token: token, forceRefresh: true)
    }

    private func catalog(
        matching queryTerm: String,
        token rawToken: String,
        forceRefresh: Bool
    ) async -> DiscoveryResult {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return .needsToken }

        loadCacheIfNeeded()
        let key = Self.cacheKey(for: queryTerm)
        let cached = cachedEntries?[key]
        if !forceRefresh, let cached, isFresh(cached.fetchedAt) {
            return .books(cached.books)
        }

        let requestKey = "\(key)|\(token.hashValue)"
        let result = await requestBooks(
            matching: queryTerm,
            token: token,
            requestKey: requestKey
        )

        switch result {
        case .books(let books):
            let ranked = Self.rankedReleasedBooks(books)
            store(ranked, for: key)
            return .books(ranked)
        case .unauthorized:
            return .needsToken
        case .failed:
            if !forceRefresh, let cached { return .books(cached.books) }
            return .failed
        }
    }

    private func requestBooks(
        matching queryTerm: String,
        token: String,
        requestKey: String
    ) async -> GenreResult {
        if let request = inFlight[requestKey] { return await request.value }

        let request = Task { [self] in
            await genreBooks(queryTerm, token: token)
        }
        inFlight[requestKey] = request
        let result = await request.value
        inFlight[requestKey] = nil
        return result
    }

    nonisolated static func rankedReleasedBooks(
        _ books: [DiscoveryBook],
        now: Date = .now
    ) -> [DiscoveryBook] {
        let calendar = Calendar.autoupdatingCurrent
        guard let today = DiscoveryReleaseDate(date: now, calendar: calendar) else { return [] }

        var unique: [String: DiscoveryBook] = [:]
        for book in books where book.coverURL?.isHTTPURL == true {
            guard let releaseDate = book.releaseDate, releaseDate <= today else { continue }
            unique[book.id] = book
        }

        return unique.values.sorted { lhs, rhs in
            guard let leftDate = lhs.releaseDate, let rightDate = rhs.releaseDate else {
                return lhs.id > rhs.id
            }
            if leftDate != rightDate {
                return leftDate > rightDate
            }
            if let leftID = Int(lhs.id), let rightID = Int(rhs.id), leftID != rightID {
                return leftID > rightID
            }
            return lhs.id > rhs.id
        }
    }

    nonisolated static func disposition(for statusCode: Int) -> HTTPDisposition {
        switch statusCode {
        case 200: .success
        case 401, 403: .unauthorized
        default: .failure
        }
    }

    nonisolated static func parseBooks(_ data: Data) -> [DiscoveryBook]? {
        guard let decoded = try? JSONDecoder().decode(BooksResponse.self, from: data),
              let rows = decoded.data?.books else { return nil }
        return rows.compactMap(\.discoveryBook)
    }

    // MARK: - Network

    private func genreBooks(_ genre: String, token: String) async -> GenreResult {
        guard let today = DiscoveryReleaseDate(date: .now, calendar: .autoupdatingCurrent) else {
            return .failed
        }
        switch await post(
            Self.genreQuery,
            variables: ["genre": genre, "today": today.iso8601],
            token: token
        ) {
        case .success(let data):
            guard let books = Self.parseBooks(data) else { return .failed }
            return .books(books)
        case .unauthorized:
            return .unauthorized
        case .failed:
            return .failed
        }
    }

    private func post(_ query: String, variables: [String: String], token: String) async -> PostResult {
        guard let payload = try? JSONSerialization.data(
            withJSONObject: ["query": query, "variables": variables]
        ) else { return .failed }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            token.hasPrefix("Bearer ") ? token : "Bearer \(token)",
            forHTTPHeaderField: "Authorization"
        )
        request.httpBody = payload

        guard await throttle() else { return .failed }
        guard let (data, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return .failed }
        switch Self.disposition(for: status) {
        case .success: return .success(data)
        case .unauthorized: return .unauthorized
        case .failure: return .failed
        }
    }

    private func throttle() async -> Bool {
        let now = Date.now
        let slot = max(now, nextRequestAt)
        nextRequestAt = slot.addingTimeInterval(Self.minimumRequestInterval)
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

    nonisolated private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Winston/1.0 (macOS eBook manager)"
        ]
        return URLSession(configuration: configuration)
    }

    // MARK: - Daily disk cache

    private func loadCacheIfNeeded() {
        guard cachedEntries == nil else { return }
        cachedEntries = readCache()
    }

    private func readCache() -> [String: DiscoveryCacheEntry] {
        guard let data = try? Data(contentsOf: cacheURL, options: .mappedIfSafe),
              data.count <= Self.maximumCacheBytes,
              let envelope = try? JSONDecoder().decode(DiscoveryCacheEnvelope.self, from: data),
              envelope.version == Self.cacheVersion else { return [:] }

        var entries: [String: DiscoveryCacheEntry] = [:]
        for (key, entry) in envelope.entries.prefix(Self.maximumCacheEntries)
        where entry.books.count <= Self.catalogLimit {
            entries[key] = entry
        }
        return entries
    }

    private func store(_ books: [DiscoveryBook], for key: String) {
        loadCacheIfNeeded()
        cachedEntries?[key] = DiscoveryCacheEntry(fetchedAt: .now, books: books)
        guard var entries = cachedEntries else { return }

        if entries.count > Self.maximumCacheEntries {
            let keep = entries.sorted { $0.value.fetchedAt > $1.value.fetchedAt }
                .prefix(Self.maximumCacheEntries)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            cachedEntries = entries
        }

        let envelope = DiscoveryCacheEnvelope(version: Self.cacheVersion, entries: entries)
        guard let data = try? JSONEncoder.discovery.encode(envelope),
              data.count <= Self.maximumCacheBytes else { return }
        do {
            try AppPaths.ensureDirectory(cacheURL.deletingLastPathComponent())
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            // Cache failures must never hide fresh API results.
        }
    }

    private func isFresh(_ fetchedAt: Date, now: Date = .now) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        return age >= 0 && age < cacheLifetime
    }

    nonisolated private static func cacheKey(for queryTerm: String) -> String {
        queryTerm.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - Cache format

private nonisolated struct DiscoveryCacheEnvelope: Codable, Sendable {
    let version: Int
    let entries: [String: DiscoveryCacheEntry]
}

private nonisolated struct DiscoveryCacheEntry: Codable, Sendable {
    let fetchedAt: Date
    let books: [DiscoveryBook]
}

private extension JSONEncoder {
    nonisolated static var discovery: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

// MARK: - Wire format

private nonisolated struct BooksResponse: Decodable {
    let data: DataField?

    struct DataField: Decodable {
        let books: [Row]?
    }

    struct Row: Decodable {
        let id: Int?
        let title: String?
        let slug: String?
        let rating: Double?
        let release_date: HardcoverReleaseDate?
        let release_year: Int?
        let image: ImageField?
        let contributions: [Contribution]?

        struct ImageField: Decodable {
            let url: String?
        }

        struct Contribution: Decodable {
            let author: Author?

            struct Author: Decodable {
                let name: String?
            }
        }

        var discoveryBook: DiscoveryBook? {
            guard let id, let slug, let title, !title.isEmpty,
                  let hardcoverURL = URL(string: "https://hardcover.app/books/\(slug)") else {
                return nil
            }
            return DiscoveryBook(
                id: String(id),
                title: title,
                author: contributions?.compactMap { $0.author?.name }.first,
                coverURL: image?.url.flatMap { URL(string: $0) },
                hardcoverURL: hardcoverURL,
                rating: (rating ?? 0) > 0 ? rating : nil,
                releaseYear: release_year,
                releaseDate: release_date?.value
            )
        }
    }
}

private nonisolated struct HardcoverReleaseDate: Decodable {
    let value: DiscoveryReleaseDate?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let string = try? container.decode(String.self) {
            value = Self.parse(string)
        } else if let number = try? container.decode(Double.self) {
            value = Self.parse(number)
        } else {
            value = nil
        }
    }

    private static func parse(_ string: String) -> DiscoveryReleaseDate? {
        DiscoveryReleaseDate(iso8601: string) ?? Double(string).flatMap(parse)
    }

    private static func parse(_ number: Double) -> DiscoveryReleaseDate? {
        guard number.isFinite else { return nil }
        if number.rounded() == number, number >= 1_000, number <= 9_999 {
            return nil
        }
        if number.rounded() == number, number >= 10_000_000, number <= 99_991_231 {
            let integer = Int(number)
            if let date = DiscoveryReleaseDate(
                year: integer / 10_000,
                month: integer / 100 % 100,
                day: integer % 100
            ) {
                return date
            }
        }

        let seconds = number > 10_000_000_000 ? number / 1_000 : number
        guard seconds >= -62_135_596_800, seconds <= 253_402_300_799 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return DiscoveryReleaseDate(
            date: Date(timeIntervalSince1970: seconds),
            calendar: calendar
        )
    }
}

private extension URL {
    nonisolated var isHTTPURL: Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
