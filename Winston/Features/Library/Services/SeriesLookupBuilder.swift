import Foundation

@MainActor
enum SeriesLookupBuilder {
    struct Group: Identifiable {
        let id: String
        let name: String
        let books: [Book]
        let lookup: SeriesLookup
    }

    static func groups(from books: [Book]) -> [Group] {
        let withSeries = books.filter { !($0.series ?? "").isEmpty }
        return Dictionary(grouping: withSeries, by: { $0.series ?? "" })
            .map { name, groupBooks in
                let sortedBooks = groupBooks.sorted { lhs, rhs in
                    let left = position(of: lhs)
                    let right = position(of: rhs)
                    if left != right { return left < right }
                    return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
                }
                let authors = Array(Set(sortedBooks.compactMap(\.displayAuthor))).sorted()
                let snapshots = sortedBooks.map {
                    SeriesLocalBookSnapshot(
                        id: $0.uuid,
                        title: $0.displayTitle,
                        author: $0.displayAuthor,
                        position: $0.seriesIndex.flatMap(Double.init)
                    )
                }
                return Group(
                    id: name,
                    name: name,
                    books: sortedBooks,
                    lookup: SeriesLookup(name: name, authors: authors, books: snapshots)
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func position(of book: Book) -> Double {
        book.seriesIndex.flatMap(Double.init) ?? .greatestFiniteMagnitude
    }
}
