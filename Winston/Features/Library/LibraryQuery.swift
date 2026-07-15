import Foundation

enum LibraryQuery {
    static func apply(to books: [Book],
                      filter: LibraryFilter,
                      searchText: String,
                      sort: [KeyPathComparator<Book>]) -> [Book] {
        let result = searched(filtered(books, by: filter), query: SearchQuery.parse(searchText))

        if case .series = filter {
            return result.sorted { seriesIndex($0) < seriesIndex($1) }
        }
        return sorted(result, by: sort)
    }

    // MARK: - Filter

    private static func filtered(_ books: [Book], by filter: LibraryFilter) -> [Book] {
        switch filter {
        case .all:
            return books
        case .recentlyAdded:
            let cutoff = Date.now.addingTimeInterval(-14 * 24 * 3600)
            return books.filter { $0.dateAdded > cutoff }
        case .status(let status):
            return books.filter { $0.readingStatus == status }
        case .collection(let id):
            return books.filter { book in book.collections.contains { $0.id == id } }
        case .format(let format):
            return books.filter { $0.format == format }
        case .author(let author):
            return books.filter { $0.displayAuthor == author }
        case .series(let series):
            return books.filter { $0.series == series }
        case .tag(let tag):
            return books.filter { $0.tags.contains(tag) }
        case .rated:
            return books.filter { ($0.rating ?? 0) > 0 }
        }
    }

    // MARK: - Search

    private static func searched(_ books: [Book], query: SearchQuery) -> [Book] {
        guard !query.isEmpty else { return books }
        let query = NormalizedQuery(query)
        return books.filter { SearchableBook($0).matches(query) }
    }

    static func smartCounts(for books: [Book], searches: [(UUID, String)]) -> [UUID: Int] {
        let queries = searches.map { ($0.0, NormalizedQuery(SearchQuery.parse($0.1))) }
        var counts: [UUID: Int] = [:]
        for book in books {
            let searchable = SearchableBook(book)
            for (id, query) in queries where searchable.matches(query) {
                counts[id, default: 0] += 1
            }
        }
        return counts
    }

    private struct NormalizedQuery {
        let freeText: String
        let authors: [String]
        let tags: [String]
        let series: [String]
        let titles: [String]
        let formats: [String]
        let languages: [String]
        let translators: [String]
        let year: SearchQuery.YearConstraint?

        init(_ query: SearchQuery) {
            freeText = query.freeText.lowercased()
            authors = query.authors.map { $0.lowercased() }
            tags = query.tags.map { $0.lowercased() }
            series = query.series.map { $0.lowercased() }
            titles = query.titles.map { $0.lowercased() }
            formats = query.formats
            languages = query.languages
            translators = query.translators.map { $0.lowercased() }
            year = query.year
        }
    }

    private struct SearchableBook {
        let title: String
        let author: String
        let tags: [String]
        let series: String
        let notes: String
        let translator: String
        let language: String
        let format: String
        let year: Int?

        init(_ book: Book) {
            title = book.displayTitle.lowercased()
            author = book.displayAuthor?.lowercased() ?? ""
            tags = book.tags.map { $0.lowercased() }
            series = book.series?.lowercased() ?? ""
            notes = book.notes?.lowercased() ?? ""
            translator = book.translator?.lowercased() ?? ""
            language = book.language?.lowercased() ?? ""
            format = book.format.lowercased()
            year = book.year.flatMap { Int($0.prefix(4)) }
        }

        func matches(_ query: NormalizedQuery) -> Bool {
        if !query.freeText.isEmpty {
            let q = query.freeText
            let hit = title.contains(q) || author.contains(q) || tags.contains { $0.contains(q) }
                || series.contains(q) || notes.contains(q) || translator.contains(q) || language.contains(q)
            if !hit { return false }
        }
        for value in query.authors where !author.contains(value) { return false }
        for tag in query.tags where !tags.contains(where: { $0.contains(tag) }) {
            return false
        }
        for value in query.series where !series.contains(value) { return false }
        for value in query.titles where !title.contains(value) { return false }
        for value in query.formats where format != value { return false }
        for value in query.languages where language != value { return false }
        for value in query.translators where !translator.contains(value) { return false }
        if let constraint = query.year {
            guard let year else { return false }
            switch constraint.op {
            case .greaterThan: if !(year > constraint.value) { return false }
            case .lessThan:    if !(year < constraint.value) { return false }
            case .equal:       if year != constraint.value { return false }
            }
        }
        return true
        }
    }

    // MARK: - Sort

    private static func seriesIndex(_ book: Book) -> Double {
        book.seriesIndex.flatMap(Double.init) ?? .greatestFiniteMagnitude
    }

    private static func sorted(_ books: [Book], by comparators: [KeyPathComparator<Book>]) -> [Book] {
        guard let first = comparators.first else { return books }
        let ascending = first.order == .forward
        if first == BookSort.title.comparator(ascending: ascending) {
            return decorated(books, key: { $0.displayTitle }, ascending: ascending)
        }
        if first == BookSort.author.comparator(ascending: ascending) {
            return decorated(books, key: { $0.sortAuthor }, ascending: ascending)
        }
        return books.sorted(using: comparators)
    }

    private static func decorated(_ books: [Book], key: (Book) -> String, ascending: Bool) -> [Book] {
        books.map { (key: key($0), book: $0) }
            .sorted { ascending ? $0.key < $1.key : $0.key > $1.key }
            .map(\.book)
    }
}
