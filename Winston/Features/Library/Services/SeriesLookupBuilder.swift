import Foundation

nonisolated struct SeriesLookupSource: Sendable {
    let id: UUID
    let series: String?
    let title: String
    let author: String?
    let position: Double?
}

nonisolated struct SeriesLookupGroupSnapshot: Sendable {
    let id: String
    let name: String
    let bookIDs: [UUID]
    let lookup: SeriesLookup
}

enum SeriesLookupBuilder {
    @MainActor
    static func sources(from books: [Book]) async -> [SeriesLookupSource] {
        var sources: [SeriesLookupSource] = []
        sources.reserveCapacity(books.count)
        for (index, book) in books.enumerated() {
            guard !Task.isCancelled else { return [] }
            sources.append(SeriesLookupSource(
                id: book.uuid,
                series: book.series,
                title: book.displayTitle,
                author: book.displayAuthor,
                position: book.seriesIndex.flatMap(Double.init)
            ))
            if index > 0, index.isMultiple(of: 128) { await Task.yield() }
        }
        return sources
    }

    @concurrent
    static func groups(from sources: [SeriesLookupSource]) async -> [SeriesLookupGroupSnapshot] {
        let withSeries = sources.filter { !($0.series ?? "").isEmpty }
        return Dictionary(grouping: withSeries, by: { $0.series ?? "" })
            .map { name, groupSources in
                let sortedSources = groupSources.sorted { lhs, rhs in
                    let left = lhs.position ?? .greatestFiniteMagnitude
                    let right = rhs.position ?? .greatestFiniteMagnitude
                    if left != right { return left < right }
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                let authors = Array(Set(sortedSources.compactMap(\.author))).sorted()
                let snapshots = sortedSources.map {
                    SeriesLocalBookSnapshot(
                        id: $0.id,
                        title: $0.title,
                        author: $0.author,
                        position: $0.position
                    )
                }
                return SeriesLookupGroupSnapshot(
                    id: name,
                    name: name,
                    bookIDs: sortedSources.map(\.id),
                    lookup: SeriesLookup(name: name, authors: authors, books: snapshots)
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
