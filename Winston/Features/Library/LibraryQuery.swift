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
        return books.filter { matches($0, query) }
    }

    private static func matches(_ book: Book, _ query: SearchQuery) -> Bool {
        if !query.freeText.isEmpty {
            let q = query.freeText.lowercased()
            let hit = book.displayTitle.lowercased().contains(q)
                || (book.displayAuthor?.lowercased().contains(q) ?? false)
                || book.tags.contains { $0.lowercased().contains(q) }
                || (book.series?.lowercased().contains(q) ?? false)
                || (book.notes?.lowercased().contains(q) ?? false)
                || (book.translator?.lowercased().contains(q) ?? false)
                || (book.language?.lowercased().contains(q) ?? false)
            if !hit { return false }
        }
        for author in query.authors where !(book.displayAuthor?.lowercased().contains(author.lowercased()) ?? false) {
            return false
        }
        for tag in query.tags where !book.tags.contains(where: { $0.lowercased().contains(tag.lowercased()) }) {
            return false
        }
        for series in query.series where !(book.series?.lowercased().contains(series.lowercased()) ?? false) {
            return false
        }
        for title in query.titles where !book.displayTitle.lowercased().contains(title.lowercased()) {
            return false
        }
        for format in query.formats where book.format.lowercased() != format {
            return false
        }
        for language in query.languages where book.language?.lowercased() != language {
            return false
        }
        for translator in query.translators
        where !(book.translator?.lowercased().contains(translator.lowercased()) ?? false) {
            return false
        }
        if let constraint = query.year {
            guard let bookYear = book.year.flatMap({ Int($0.prefix(4)) }) else { return false }
            switch constraint.op {
            case .greaterThan: if !(bookYear > constraint.value) { return false }
            case .lessThan:    if !(bookYear < constraint.value) { return false }
            case .equal:       if bookYear != constraint.value { return false }
            }
        }
        return true
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
