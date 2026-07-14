import Foundation
import Observation

// MARK: - Sendable snapshots and results

nonisolated struct SeriesLocalBookSnapshot: Sendable, Equatable, Hashable {
    let id: UUID
    let title: String
    let author: String?
    let position: Double?
}

nonisolated struct SeriesLookup: Sendable, Equatable, Hashable, Identifiable {
    let id: String
    let name: String
    let authors: [String]
    let books: [SeriesLocalBookSnapshot]

    init(name: String, authors: [String], books: [SeriesLocalBookSnapshot]) {
        self.id = name.normalizedMatchKey
        self.name = name
        self.authors = authors
        self.books = books
    }

    fileprivate var cacheKey: String {
        let authorPart = authors.map(\.normalizedMatchKey).sorted().joined(separator: ",")
        let bookPart = books
            .map { "\($0.title.normalizedMatchKey):\($0.position.map { String($0) } ?? "-")" }
            .sorted()
            .joined(separator: ",")
        return "\(id)|\(authorPart)|\(bookPart)"
    }
}

nonisolated struct HardcoverSeriesBook: Sendable, Equatable, Identifiable {
    let id: Int
    let title: String
    let position: Double?
    let positionText: String?
    let authors: [String]
    let hardcoverURL: URL
    fileprivate let popularity: Int
}

nonisolated struct HardcoverSeriesCatalog: Sendable, Equatable, Identifiable {
    let id: Int
    let name: String
    let author: String?
    let totalBookCount: Int
    let hardcoverURL: URL
    let books: [HardcoverSeriesBook]
}

nonisolated struct SeriesCompletion: Sendable, Equatable {
    let catalog: HardcoverSeriesCatalog
    let ownedCount: Int
    let missingCount: Int
    let missingBooks: [HardcoverSeriesBook]
    let unidentifiedMissingCount: Int
}

nonisolated protocol SeriesCatalogFetching: Sendable {
    func catalogs(
        matching lookups: [SeriesLookup],
        token: String
    ) async throws -> [String: HardcoverSeriesCatalog]
}

nonisolated enum SeriesCatalogError: Error, Equatable {
    case invalidResponse
    case requestFailed
}

nonisolated enum SeriesCatalogCacheStatus: Sendable {
    case catalog(HardcoverSeriesCatalog)
    case noMatch
    case notCached
}

// MARK: - Hardcover API

actor HardcoverSeriesService: SeriesCatalogFetching {
    nonisolated static let shared = HardcoverSeriesService()

    private enum CacheEntry {
        case catalog(HardcoverSeriesCatalog)
        case noMatch
    }

    private struct InFlightRequest: Sendable {
        let id: UUID
        let lookups: [SeriesLookup]
        let task: Task<[String: HardcoverSeriesCatalog], any Error>
    }

    private static let endpoint = URL(string: "https://api.hardcover.app/v1/graphql")!
    private static let batchSize = 20
    private static let minimumRequestInterval: TimeInterval = 0.34

    private let session: URLSession
    private var cache: [String: CacheEntry] = [:]
    private var inFlight: [String: InFlightRequest] = [:]
    private var nextRequestAt = Date.distantPast

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 20
            configuration.httpAdditionalHeaders = [
                "User-Agent": "Winston/1.0 (macOS eBook manager)"
            ]
            self.session = URLSession(configuration: configuration)
        }
    }

    func cacheStatus(for lookup: SeriesLookup) -> SeriesCatalogCacheStatus {
        switch cache[lookup.cacheKey] {
        case .catalog(let catalog): .catalog(catalog)
        case .noMatch: .noMatch
        case nil: .notCached
        }
    }

    func catalogs(
        matching lookups: [SeriesLookup],
        token: String
    ) async throws -> [String: HardcoverSeriesCatalog] {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return [:] }

        var uncached: [SeriesLookup] = []
        var requests: [UUID: InFlightRequest] = [:]

        for lookup in lookups {
            switch cache[lookup.cacheKey] {
            case .catalog, .noMatch:
                break
            case nil:
                if let request = inFlight[lookup.cacheKey] {
                    requests[request.id] = request
                } else {
                    uncached.append(lookup)
                }
            }
        }

        for start in stride(from: 0, to: uncached.count, by: Self.batchSize) {
            let end = min(start + Self.batchSize, uncached.count)
            let batch = Array(uncached[start..<end])
            let inFlightRequest = InFlightRequest(
                id: UUID(),
                lookups: batch,
                task: Task { [self] in
                    let data = try await self.request(batch: batch, token: token)
                    return try Self.decodeCatalogs(data, matching: batch)
                }
            )
            for lookup in batch {
                inFlight[lookup.cacheKey] = inFlightRequest
            }
            requests[inFlightRequest.id] = inFlightRequest
        }

        var firstError: (any Error)?
        for request in requests.values {
            do {
                let decoded = try await request.task.value
                finish(request, decoded: decoded)
            } catch {
                clear(request)
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
        try Task.checkCancellation()

        var result: [String: HardcoverSeriesCatalog] = [:]
        for lookup in lookups {
            if case .catalog(let catalog) = cache[lookup.cacheKey] {
                result[lookup.id] = catalog
            }
        }

        return result
    }

    private func finish(
        _ request: InFlightRequest,
        decoded: [String: HardcoverSeriesCatalog]
    ) {
        for lookup in request.lookups {
            if let catalog = decoded[lookup.id] {
                cache[lookup.cacheKey] = .catalog(catalog)
            } else {
                cache[lookup.cacheKey] = .noMatch
            }
        }
        clear(request)
    }

    private func clear(_ request: InFlightRequest) {
        for lookup in request.lookups where inFlight[lookup.cacheKey]?.id == request.id {
            inFlight[lookup.cacheKey] = nil
        }
    }

    nonisolated static func decodeCatalogs(
        _ data: Data,
        matching lookups: [SeriesLookup]
    ) throws -> [String: HardcoverSeriesCatalog] {
        let response = try JSONDecoder().decode(SeriesResponse.self, from: data)
        guard let rows = response.data?.series else { throw SeriesCatalogError.invalidResponse }

        let rowsByName = Dictionary(grouping: rows, by: { $0.name.normalizedMatchKey })
        var result: [String: HardcoverSeriesCatalog] = [:]
        for lookup in lookups {
            guard let candidates = rowsByName[lookup.id],
                  let row = bestCandidate(in: candidates, for: lookup),
                  let catalog = makeCatalog(from: row, lookup: lookup) else { continue }
            result[lookup.id] = catalog
        }
        return result
    }

    private func request(batch: [SeriesLookup], token: String) async throws -> Data {
        let comparisons: [[String: Any]] = batch.map {
            ["name": ["_ilike": Self.escapedILikeLiteral($0.name)]]
        }
        let variables: [String: Any] = [
            "where": [
                "_and": [
                    ["_or": comparisons],
                    ["canonical_id": ["_is_null": true]],
                ]
            ]
        ]
        let body = try JSONSerialization.data(withJSONObject: [
            "query": Self.query,
            "variables": variables,
        ])

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            token.hasPrefix("Bearer ") ? token : "Bearer \(token)",
            forHTTPHeaderField: "Authorization"
        )
        request.httpBody = body

        try await reserveRequestSlot()
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SeriesCatalogError.requestFailed
        }
        return data
    }

    private func reserveRequestSlot() async throws {
        let now = Date.now
        let scheduled = max(now, nextRequestAt)
        nextRequestAt = scheduled.addingTimeInterval(Self.minimumRequestInterval)
        let delay = scheduled.timeIntervalSince(now)
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
    }

    private nonisolated static func escapedILikeLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private nonisolated static func bestCandidate(
        in candidates: [SeriesResponse.Row],
        for lookup: SeriesLookup
    ) -> SeriesResponse.Row? {
        guard candidates.count > 1 else { return candidates.first }

        let localAuthors = Set(lookup.authors.map(\.normalizedMatchKey).filter { !$0.isEmpty })
        let localTitles = Set(lookup.books.map { $0.title.normalizedMatchKey })
        let scored = candidates.map { row -> (row: SeriesResponse.Row, score: Int, meaningful: Bool) in
            let authorMatch = row.author.map {
                localAuthors.contains($0.name.normalizedMatchKey)
            } ?? false
            let titleMatches = Set(
                row.book_series.compactMap { $0.book?.title.normalizedMatchKey }
            ).intersection(localTitles).count
            let countDistance = abs((row.primary_books_count ?? row.book_series.count) - lookup.books.count)
            let popularity = row.book_series.compactMap { $0.book?.users_read_count }.reduce(0, +)
            let score = (authorMatch ? 1_000_000 : 0)
                + titleMatches * 10_000
                - min(countDistance, 100) * 100
                + min(popularity, 9_999)
            return (row, score, authorMatch || titleMatches > 0)
        }.sorted { $0.score > $1.score }

        guard let first = scored.first, first.meaningful else { return nil }
        if scored.count > 1, scored[1].score == first.score { return nil }
        return first.row
    }

    private nonisolated static func makeCatalog(
        from row: SeriesResponse.Row,
        lookup: SeriesLookup
    ) -> HardcoverSeriesCatalog? {
        guard let seriesURL = URL(string: "https://hardcover.app/series/\(row.slug)") else {
            return nil
        }

        let localTitles = Set(lookup.books.map { $0.title.normalizedMatchKey })
        let remoteBooks = row.book_series.compactMap { entry -> HardcoverSeriesBook? in
            guard let book = entry.book,
                  let url = URL(string: "https://hardcover.app/books/\(book.slug)") else { return nil }
            return HardcoverSeriesBook(
                id: book.id,
                title: book.title,
                position: entry.position,
                positionText: entry.details,
                authors: row.author.map { [$0.name] } ?? [],
                hardcoverURL: url,
                popularity: book.users_read_count ?? 0
            )
        }

        var byPosition: [String: HardcoverSeriesBook] = [:]
        for book in remoteBooks {
            let identity = book.position.map { "p:\(Int64(($0 * 1_000).rounded()))" }
                ?? "b:\(book.id)"
            guard let current = byPosition[identity] else {
                byPosition[identity] = book
                continue
            }
            let bookIsLocal = localTitles.contains(book.title.normalizedMatchKey)
            let currentIsLocal = localTitles.contains(current.title.normalizedMatchKey)
            if (bookIsLocal && !currentIsLocal)
                || (bookIsLocal == currentIsLocal && book.popularity > current.popularity) {
                byPosition[identity] = book
            }
        }

        var books = byPosition.values.sorted { lhs, rhs in
            switch (lhs.position, rhs.position) {
            case let (l?, r?) where l != r: return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
        let reportedTotal = max(row.primary_books_count ?? 0, 0)
        let total = reportedTotal > 0 ? reportedTotal : books.count
        if books.count > total { books = Array(books.prefix(total)) }

        return HardcoverSeriesCatalog(
            id: row.id,
            name: row.name,
            author: row.author?.name,
            totalBookCount: max(total, books.count),
            hardcoverURL: seriesURL,
            books: books
        )
    }

    private static let query = """
    query SeriesCompletion($where: series_bool_exp!) {
      series(where: $where, limit: 100) {
        id
        name
        slug
        primary_books_count
        author { name }
        book_series(
          where: {
            featured: { _eq: true }
            compilation: { _eq: false }
            book: { book_status_id: { _eq: 1 } }
          }
          order_by: [{ position: asc }, { book: { users_read_count: desc } }]
        ) {
          position
          details
          book {
            id
            title
            slug
            users_read_count
          }
        }
      }
    }
    """
}

// MARK: - Completion calculation

nonisolated enum SeriesCompletionCalculator {
    static func make(
        catalog: HardcoverSeriesCatalog,
        lookup: SeriesLookup
    ) -> SeriesCompletion {
        let total = catalog.totalBookCount
        guard total > 0 else {
            return SeriesCompletion(
                catalog: catalog,
                ownedCount: 0,
                missingCount: 0,
                missingBooks: [],
                unidentifiedMissingCount: 0
            )
        }

        var availableLocal = Set(lookup.books.indices)
        var matchedRemoteIDs = Set<Int>()

        for remote in catalog.books {
            let remoteTitle = remote.title.normalizedMatchKey
            let remoteAuthors = remote.authors.map(\.normalizedMatchKey).filter { !$0.isEmpty }

            let titleMatch = availableLocal.first { index in
                let local = lookup.books[index]
                guard local.title.normalizedMatchKey == remoteTitle else { return false }
                return authorsOverlap(local.author, remoteAuthors: remoteAuthors)
            }
            let positionMatch = titleMatch == nil ? availableLocal.first { index in
                guard let remotePosition = remote.position,
                      let localPosition = lookup.books[index].position else { return false }
                return abs(remotePosition - localPosition) < 0.001
            } : nil

            if let localIndex = titleMatch ?? positionMatch {
                availableLocal.remove(localIndex)
                matchedRemoteIDs.insert(remote.id)
            }
        }

        let remoteTitleKeys = Set(catalog.books.map { $0.title.normalizedMatchKey })
        let uniqueLocalCount = Set(lookup.books.compactMap {
            localPrimaryIdentity($0, total: total, remoteTitleKeys: remoteTitleKeys)
        }).count
        let owned = min(total, max(matchedRemoteIDs.count, uniqueLocalCount))
        let missing = max(0, total - owned)
        let identifiedMissing = catalog.books
            .filter { !matchedRemoteIDs.contains($0.id) }
            .prefix(missing)

        return SeriesCompletion(
            catalog: catalog,
            ownedCount: owned,
            missingCount: missing,
            missingBooks: Array(identifiedMissing),
            unidentifiedMissingCount: max(0, missing - identifiedMissing.count)
        )
    }

    private static func authorsOverlap(_ localAuthor: String?, remoteAuthors: [String]) -> Bool {
        guard let local = localAuthor?.normalizedMatchKey, !local.isEmpty,
              !remoteAuthors.isEmpty else { return true }
        return remoteAuthors.contains { remote in
            local == remote || (min(local.count, remote.count) >= 4
                && (local.contains(remote) || remote.contains(local)))
        }
    }

    private static func localPrimaryIdentity(
        _ book: SeriesLocalBookSnapshot,
        total: Int,
        remoteTitleKeys: Set<String>
    ) -> String? {
        let titleKey = book.title.normalizedMatchKey
        if remoteTitleKeys.contains(titleKey) {
            return "t:\(BookMatchKey(title: book.title, author: book.author).storageValue)"
        }
        if let position = book.position {
            guard position >= 1,
                  position <= Double(total) + 0.001,
                  abs(position - position.rounded()) < 0.001 else { return nil }
            return "p:\(Int64((position * 1_000).rounded()))"
        }
        return "t:\(BookMatchKey(title: book.title, author: book.author).storageValue)"
    }
}

// MARK: - View state

@MainActor
@Observable
final class SeriesCompletionViewModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    private let service: any SeriesCatalogFetching
    private var generation = 0

    private(set) var phase: Phase = .idle
    private(set) var completions: [String: SeriesCompletion] = [:]

    init(service: any SeriesCatalogFetching = HardcoverSeriesService.shared) {
        self.service = service
    }

    func reset() {
        generation += 1
        completions = [:]
        phase = .idle
    }

    func load(lookups: [SeriesLookup], token: String) async {
        generation += 1
        let currentGeneration = generation
        completions = [:]
        guard !lookups.isEmpty else {
            phase = .loaded
            return
        }
        phase = .loading

        do {
            let catalogs = try await service.catalogs(matching: lookups, token: token)
            guard currentGeneration == generation, !Task.isCancelled else { return }
            completions = Dictionary(uniqueKeysWithValues: lookups.compactMap { lookup in
                guard let catalog = catalogs[lookup.id] else { return nil }
                return (lookup.id, SeriesCompletionCalculator.make(catalog: catalog, lookup: lookup))
            })
            phase = .loaded
        } catch is CancellationError {
            return
        } catch {
            guard currentGeneration == generation else { return }
            completions = [:]
            phase = .failed
        }
    }
}

// MARK: - Wire format

private nonisolated struct SeriesResponse: Decodable {
    let data: DataField?

    struct DataField: Decodable { let series: [Row]? }

    struct Row: Decodable {
        let id: Int
        let name: String
        let slug: String
        let primary_books_count: Int?
        let author: Author?
        let book_series: [SeriesBook]

        struct Author: Decodable { let name: String }

        struct SeriesBook: Decodable {
            let position: Double?
            let details: String?
            let book: RemoteBook?
        }

        struct RemoteBook: Decodable {
            let id: Int
            let title: String
            let slug: String
            let users_read_count: Int?
        }
    }
}
