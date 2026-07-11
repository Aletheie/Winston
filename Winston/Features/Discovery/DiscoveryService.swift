import Foundation

nonisolated protocol DiscoveryFetching: Sendable {
    func books(matching queryTerm: String, token: String) async -> DiscoveryResult
}

actor DiscoveryService: DiscoveryFetching {
    nonisolated enum HTTPDisposition: Equatable {
        case success
        case unauthorized
        case failure
    }

    private enum PostResult {
        case success(Data)
        case unauthorized
        case failed
    }

    private enum GenreResult {
        case books([DiscoveryBook])
        case unauthorized
        case failed
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.httpAdditionalHeaders = ["User-Agent": "Winston/1.0 (macOS eBook manager)"]
        return URLSession(configuration: config)
    }()

    private var nextRequestAt: Date = .distantPast
    private let minInterval: TimeInterval = 0.34

    private static let endpoint = URL(string: "https://api.hardcover.app/v1/graphql")!

    func books(matching queryTerm: String, token: String) async -> DiscoveryResult {
        guard !token.isEmpty else { return .needsToken }

        switch await genreBooks(queryTerm, token: token) {
        case .books(let genre):
            let usable = Self.released(genre.filter { $0.coverURL != nil })
            if !usable.isEmpty { return .books(usable) }
        case .unauthorized:
            return .needsToken
        case .failed:
            break
        }

        let data: Data
        switch await post(Self.searchGQL, variables: ["q": queryTerm], token: token) {
        case .success(let responseData):
            data = responseData
        case .unauthorized:
            return .needsToken
        case .failed:
            return .failed
        }
        var cleaned = Self.released(Self.cleanedSearch(data, genre: queryTerm))
        if cleaned.isEmpty {
            cleaned = Self.released(Self.parse(data).filter { $0.coverURL != nil })
        }
        return .books(cleaned)
    }

    nonisolated static func released(_ books: [DiscoveryBook], now: Date = .now) -> [DiscoveryBook] {
        let calendar = Calendar.autoupdatingCurrent
        guard let today = DiscoveryReleaseDate(date: now, calendar: calendar) else { return [] }
        return books.filter { book in
            if let releaseDate = book.releaseDate {
                return releaseDate <= today
            }
            if let releaseYear = book.releaseYear {
                return releaseYear < today.year
            }
            return false
        }
    }

    // MARK: - Requests

    private func genreBooks(_ genre: String, token: String) async -> GenreResult {
        let gql = """
        query GenreBooks($genre: String!, $today: date!) {
          books(
            where: {
              taggings: { tag: { tag: { _eq: $genre } } },
              users_count: { _gte: 50 },
              release_date: { _lte: $today }
            },
            order_by: { release_date: desc_nulls_last },
            limit: 40
          ) {
            id title slug rating users_count release_date release_year description
            image { url }
            contributions { author { name } }
          }
        }
        """
        guard let today = DiscoveryReleaseDate(date: .now, calendar: .autoupdatingCurrent) else {
            return .failed
        }
        switch await post(
            gql,
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

    private static let searchGQL =
        "query Discover($q: String!) { search(query: $q, query_type: \"Book\", per_page: 40) { results } }"

    private func post(_ query: String, variables: [String: String], token: String) async -> PostResult {
        guard let payload = try? JSONSerialization.data(
            withJSONObject: ["query": query, "variables": variables]) else { return .failed }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token.hasPrefix("Bearer ") ? token : "Bearer \(token)", forHTTPHeaderField: "Authorization")
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

    nonisolated static func disposition(for statusCode: Int) -> HTTPDisposition {
        switch statusCode {
        case 200: .success
        case 401, 403: .unauthorized
        default: .failure
        }
    }

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

    // MARK: - Decoding: `books` query (genre)

    nonisolated static func parseBooks(_ data: Data) -> [DiscoveryBook]? {
        guard let decoded = try? JSONDecoder().decode(BooksResponse.self, from: data),
              let rows = decoded.data?.books else { return nil }
        return rows.compactMap(\.discoveryBook)
    }

    // MARK: - Decoding: `search` query (fallback)

    nonisolated static func parse(_ data: Data) -> [DiscoveryBook] {
        (try? JSONDecoder().decode(HardcoverSearch.self, from: data))?
            .data?.search?.results?.hits?.compactMap { $0.document?.discoveryBook } ?? []
    }

    nonisolated static func cleanedSearch(_ data: Data, genre: String) -> [DiscoveryBook] {
        guard let hits = (try? JSONDecoder().decode(HardcoverSearch.self, from: data))?
            .data?.search?.results?.hits else { return [] }
        let g = genre.lowercased()

        func keep(_ doc: HardcoverSearch.Document, requireDescription: Bool) -> Bool {
            guard let title = doc.title, doc.image?.url != nil else { return false }
            if title.lowercased() == g { return false }
            if requireDescription, (doc.description ?? "").isEmpty { return false }
            if let genres = doc.genres, !genres.isEmpty,
               !genres.contains(where: { $0.caseInsensitiveCompare(genre) == .orderedSame }) {
                return false
            }
            return true
        }

        let docs = hits.compactMap(\.document)
        var chosen = docs.filter { keep($0, requireDescription: true) }
        if chosen.count < 8 { chosen = docs.filter { keep($0, requireDescription: false) } }

        return chosen
            .sorted { a, b in
                let (au, bu) = (a.users_count ?? 0, b.users_count ?? 0)
                if au != bu { return au > bu }
                return (a.release_year ?? 0) > (b.release_year ?? 0)
            }
            .prefix(24)
            .compactMap(\.discoveryBook)
    }
}

// MARK: - Wire formats

private nonisolated struct BooksResponse: Decodable {
    let data: DataField?
    struct DataField: Decodable { let books: [Row]? }
    struct Row: Decodable {
        let id: Int?
        let title: String?
        let slug: String?
        let rating: Double?
        let users_count: Int?
        let release_date: HardcoverReleaseDate?
        let release_year: Int?
        let description: String?
        let image: ImageField?
        let contributions: [Contribution]?

        struct ImageField: Decodable { let url: String? }
        struct Contribution: Decodable { let author: Author?; struct Author: Decodable { let name: String? } }

        var discoveryBook: DiscoveryBook? {
            guard let slug, let title, !title.isEmpty,
                  let hardcoverURL = URL(string: "https://hardcover.app/books/\(slug)") else { return nil }
            return DiscoveryBook(
                id: id.map(String.init) ?? slug,
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

private nonisolated struct HardcoverSearch: Decodable {
    let data: DataField?
    struct DataField: Decodable { let search: SearchField? }
    struct SearchField: Decodable { let results: Results? }
    struct Results: Decodable { let hits: [Hit]? }
    struct Hit: Decodable { let document: Document? }

    struct Document: Decodable {
        let id: String?
        let slug: String?
        let title: String?
        let rating: Double?
        let image: ImageField?
        let contributions: [Contribution]?
        let author_names: [String]?
        let genres: [String]?
        let users_count: Int?
        let release_date: HardcoverReleaseDate?
        let release_year: Int?
        let description: String?

        struct ImageField: Decodable { let url: String? }
        struct Contribution: Decodable { let author: Author?; struct Author: Decodable { let name: String? } }

        var discoveryBook: DiscoveryBook? {
            guard let slug, let title, !title.isEmpty,
                  let hardcoverURL = URL(string: "https://hardcover.app/books/\(slug)") else { return nil }
            let author = author_names?.first(where: { !$0.isEmpty })
                ?? contributions?.compactMap { $0.author?.name }.first
            return DiscoveryBook(
                id: id ?? slug,
                title: title,
                author: author,
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
        DiscoveryReleaseDate(iso8601: string)
            ?? Double(string).flatMap(parse)
    }

    private static func parse(_ number: Double) -> DiscoveryReleaseDate? {
        guard number.isFinite else { return nil }
        if number.rounded() == number, number >= 1_000, number <= 9_999 {
            return nil
        }
        if number.rounded() == number,
           number >= 10_000_000,
           number <= 99_991_231 {
            let integer = Int(number)
            let year = integer / 10_000
            let month = integer / 100 % 100
            let day = integer % 100
            if let date = DiscoveryReleaseDate(year: year, month: month, day: day) {
                return date
            }
        }

        let seconds = number > 10_000_000_000 ? number / 1_000 : number
        guard seconds >= -62_135_596_800,
              seconds <= 253_402_300_799 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return DiscoveryReleaseDate(
            date: Date(timeIntervalSince1970: seconds),
            calendar: calendar
        )
    }
}
