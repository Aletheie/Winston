import Foundation

nonisolated enum OPDSCatalogSearchState: Equatable, Sendable {
    case loading
    case success([OPDSPublication])
    case empty
    case failed(OPDSServiceError)
    case unsupportedSearch
    case disabled
    case cancelled

    var isComplete: Bool {
        switch self {
        case .loading:
            false
        case .success, .empty, .failed, .unsupportedSearch, .disabled,
             .cancelled:
            true
        }
    }
}

nonisolated struct OPDSCatalogSearchUpdate: Equatable, Sendable {
    let catalogID: String
    let state: OPDSCatalogSearchState
}

nonisolated struct OPDSSearchVariant: Identifiable, Equatable, Sendable {
    let catalogID: String
    let catalogName: String
    let publication: OPDSPublication

    var id: String {
        "\(catalogID)|\(publication.id)"
    }
}

nonisolated struct OPDSSearchResultGroup:
    Identifiable,
    Equatable,
    Sendable
{
    enum GroupingBasis: Equatable, Sendable {
        case canonicalISBN(String)
        case normalizedName(BookMatchKey)
        case sourceOnly
    }

    let id: String
    let basis: GroupingBasis
    let title: String
    let author: String?
    let coverURL: URL?
    let variants: [OPDSSearchVariant]
    let isOwned: Bool
    let appearsToBeAnotherEdition: Bool

    var languages: [String] {
        unique(variants.compactMap(\.publication.language))
    }

    var formats: [String] {
        unique(
            variants.flatMap(\.publication.acquisitions)
                .map(\.formatLabel)
        )
    }

    var acquisitionRelations: [OPDSAcquisitionRelation] {
        var seen: Set<OPDSAcquisitionRelation> = []
        return variants.flatMap(\.publication.acquisitions)
            .map(\.relation)
            .filter { seen.insert($0).inserted }
    }

    var sourceCount: Int {
        Set(variants.map(\.catalogID)).count
    }

    private func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}

nonisolated struct OPDSLocalOwnershipIndex: Sendable {
    private let isbn13s: Set<String>
    private let nameKeys: Set<BookMatchKey>

    init(records: [LibraryBookRecord]) {
        isbn13s = Set(records.compactMap(\.canonicalISBN13))
        nameKeys = Set(records.compactMap { record in
            let key = BookMatchKey(
                title: record.displayTitle,
                author: record.displayAuthor
            )
            return key.isComplete ? key : nil
        })
    }

    func match(
        publication: OPDSPublication
    ) -> (owned: Bool, anotherEdition: Bool) {
        let remoteISBNs = publication.canonicalISBNs
        let hasISBNMatch = !isbn13s.isDisjoint(with: remoteISBNs)
        let nameKey = BookMatchKey(
            title: publication.title,
            author: publication.authors.first
        )
        let hasNameMatch = nameKey.isComplete && nameKeys.contains(nameKey)
        return (
            hasISBNMatch || hasNameMatch,
            hasNameMatch && !hasISBNMatch && !remoteISBNs.isEmpty
        )
    }
}

nonisolated enum OPDSSearchAggregator {
    static func aggregate(
        states: [String: OPDSCatalogSearchState],
        catalogNames: [String: String],
        ownership: OPDSLocalOwnershipIndex
    ) -> [OPDSSearchResultGroup] {
        var buckets: [String: [OPDSSearchVariant]] = [:]
        var bases: [String: OPDSSearchResultGroup.GroupingBasis] = [:]

        for catalogID in states.keys.sorted() {
            guard case .success(let publications) = states[catalogID] else {
                continue
            }
            for publication in publications {
                let grouping = groupingKey(
                    publication: publication,
                    catalogID: catalogID
                )
                buckets[grouping.key, default: []].append(
                    OPDSSearchVariant(
                        catalogID: catalogID,
                        catalogName: catalogNames[catalogID]
                            ?? String(localized: "Catalog"),
                        publication: publication
                    )
                )
                bases[grouping.key] = grouping.basis
            }
        }

        return buckets.map { key, variants in
            let ordered = variants.sorted {
                if $0.catalogName != $1.catalogName {
                    return $0.catalogName.localizedStandardCompare(
                        $1.catalogName
                    ) == .orderedAscending
                }
                return $0.publication.id < $1.publication.id
            }
            let representative = ordered[0].publication
            let matches = ordered.map {
                ownership.match(publication: $0.publication)
            }
            return OPDSSearchResultGroup(
                id: key,
                basis: bases[key] ?? .sourceOnly,
                title: representative.title,
                author: representative.authorLine,
                coverURL: ordered.compactMap(
                    \.publication.coverURL
                ).first,
                variants: ordered,
                isOwned: matches.contains(where: \.owned),
                appearsToBeAnotherEdition: matches.contains(
                    where: \.anotherEdition
                )
            )
        }.sorted {
            let titleOrder = $0.title.localizedStandardCompare($1.title)
            if titleOrder != .orderedSame {
                return titleOrder == .orderedAscending
            }
            return ($0.author ?? "").localizedStandardCompare(
                $1.author ?? ""
            ) == .orderedAscending
        }
    }

    private static func groupingKey(
        publication: OPDSPublication,
        catalogID: String
    ) -> (
        key: String,
        basis: OPDSSearchResultGroup.GroupingBasis
    ) {
        let isbns = publication.canonicalISBNs.sorted()
        if isbns.count == 1, let isbn = isbns.first {
            return ("isbn:\(isbn)", .canonicalISBN(isbn))
        }
        let nameKey = BookMatchKey(
            title: publication.title,
            author: publication.authors.first
        )
        if isbns.isEmpty, nameKey.isComplete {
            return (
                "name:\(nameKey.storageValue)",
                .normalizedName(nameKey)
            )
        }
        return (
            "source:\(catalogID)|\(publication.id)",
            .sourceOnly
        )
    }
}

actor OPDSCatalogSearchService {
    private struct CachedCapability: Sendable {
        let rootURL: URL
        let searchLink: OPDSSearchLink?
    }

    private let client: any OPDSFetching
    private let maximumConcurrentCatalogs: Int
    private var capabilityCache: [String: CachedCapability] = [:]

    init(
        client: any OPDSFetching = OPDSService(),
        maximumConcurrentCatalogs: Int = 3
    ) {
        self.client = client
        self.maximumConcurrentCatalogs = max(
            1,
            maximumConcurrentCatalogs
        )
    }

    nonisolated func updates(
        accesses: [OPDSCatalogAccess],
        query: String
    ) -> AsyncStream<OPDSCatalogSearchUpdate> {
        AsyncStream { continuation in
            let producer = Task {
                await self.runSearch(
                    accesses: accesses,
                    query: query,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in
                producer.cancel()
            }
        }
    }

    func invalidate(catalogID: String) {
        capabilityCache[catalogID] = nil
    }

    func clearCache() {
        capabilityCache.removeAll()
    }

    private func runSearch(
        accesses: [OPDSCatalogAccess],
        query: String,
        continuation: AsyncStream<OPDSCatalogSearchUpdate>.Continuation
    ) async {
        let enabled = accesses.filter(\.configuration.isEnabled)
        for access in accesses where !access.configuration.isEnabled {
            continuation.yield(OPDSCatalogSearchUpdate(
                catalogID: access.catalogID,
                state: .disabled
            ))
        }
        for access in enabled {
            continuation.yield(OPDSCatalogSearchUpdate(
                catalogID: access.catalogID,
                state: .loading
            ))
        }

        await withTaskGroup(
            of: OPDSCatalogSearchUpdate.self
        ) { group in
            var nextIndex = 0

            func addNext() {
                guard nextIndex < enabled.count else { return }
                let access = enabled[nextIndex]
                nextIndex += 1
                group.addTask {
                    await self.searchOne(
                        access: access,
                        query: query
                    )
                }
            }

            for _ in 0..<min(
                maximumConcurrentCatalogs,
                enabled.count
            ) {
                addNext()
            }

            while let update = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }
                continuation.yield(update)
                addNext()
            }
        }
        continuation.finish()
    }

    private func searchOne(
        access: OPDSCatalogAccess,
        query: String
    ) async -> OPDSCatalogSearchUpdate {
        do {
            try Task.checkCancellation()
            let capability: CachedCapability
            if let cached = capabilityCache[access.catalogID],
               cached.rootURL == access.configuration.rootURL {
                capability = cached
            } else {
                let root = try await client.feed(
                    at: access.configuration.rootURL,
                    access: access
                )
                capability = CachedCapability(
                    rootURL: access.configuration.rootURL,
                    searchLink: root.searchLink
                )
                capabilityCache[access.catalogID] = capability
            }
            guard let searchLink = capability.searchLink,
                  let template = try await client.resolvedSearchTemplate(
                    for: searchLink,
                    access: access
                  ),
                  let searchURL = OPDSService.expandedSearchURL(
                    template: template,
                    query: query
                  ) else {
                return OPDSCatalogSearchUpdate(
                    catalogID: access.catalogID,
                    state: .unsupportedSearch
                )
            }
            let feed = try await client.feed(
                at: searchURL,
                access: access
            )
            return OPDSCatalogSearchUpdate(
                catalogID: access.catalogID,
                state: feed.publications.isEmpty
                    ? .empty
                    : .success(feed.publications)
            )
        } catch is CancellationError {
            return OPDSCatalogSearchUpdate(
                catalogID: access.catalogID,
                state: .cancelled
            )
        } catch let error as OPDSServiceError {
            return OPDSCatalogSearchUpdate(
                catalogID: access.catalogID,
                state: .failed(error)
            )
        } catch {
            return OPDSCatalogSearchUpdate(
                catalogID: access.catalogID,
                state: .failed(.network)
            )
        }
    }
}
