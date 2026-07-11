import Foundation

nonisolated struct DeviceBookRow: Identifiable, Sendable, Hashable {
    let book: DeviceBook
    let author: String?
    let title: String

    init(book: DeviceBook, author: String?) {
        self.book = book
        self.author = author
        self.title = book.displayName
    }

    var id: DeviceBook.ID { book.id }

    var sortAuthor: String { author ?? "" }
    var format: String { book.format }
    var sizeBytes: UInt64 { book.sizeBytes }
    var sortDate: Date { book.modifiedDate ?? .distantPast }
}

nonisolated enum DeviceTableQuery {

    static var recentFirst: [KeyPathComparator<DeviceBookRow>] {
        [KeyPathComparator(\.sortDate, order: .reverse)]
    }

    static func rows(books: [DeviceBook], authorByMatchKey: [String: String]) -> [DeviceBookRow] {
        books.map { DeviceBookRow(book: $0, author: authorByMatchKey[$0.matchKey]) }
    }

    static func authors(in rows: [DeviceBookRow]) -> [String] {
        Set(rows.compactMap(\.author))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func apply(
        to rows: [DeviceBookRow],
        searchText: String,
        author: String?,
        sort: [KeyPathComparator<DeviceBookRow>]
    ) -> [DeviceBookRow] {
        var result = rows
        if let author {
            result = result.filter { $0.author == author }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            result = result.filter { row in
                row.title.localizedStandardContains(query)
                    || row.author?.localizedStandardContains(query) == true
                    || row.book.fileName.localizedStandardContains(query)
            }
        }
        return result.sorted(using: sort)
    }
}
