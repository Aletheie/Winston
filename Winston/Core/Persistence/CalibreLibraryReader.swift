import Foundation
import SQLite3

nonisolated struct CalibreBook: Sendable, Equatable {
    var title: String
    var authors: [String]
    var series: String?
    var seriesIndex: String?
    var publisher: String?
    var year: String?
    var language: String?
    var isbn: String?
    var tags: [String]
    var bookDescription: String?
    var rating: Int?
    var dateAdded: Date?
    var fileURL: URL
    var additionalFileURLs: [URL]
    var coverURL: URL?
}

nonisolated enum CalibreImportError: Error, Equatable {
    case noLibrary
    case cannotOpen
}

nonisolated enum CalibreLibraryReader {
    static let metadataDBName = "metadata.db"

    static func read(libraryRoot: URL, formatPreference: [String]) throws -> [CalibreBook] {
        let dbURL = libraryRoot.appending(path: metadataDBName)
        guard FileManager.default.fileExists(atPath: dbURL.path(percentEncoded: false)) else {
            throw CalibreImportError.noLibrary
        }

        var handle: OpaquePointer?
        let uri = "file:\(dbURL.path(percentEncoded: false))?immutable=1"
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let db = handle else {
            sqlite3_close(handle)
            throw CalibreImportError.cannotOpen
        }
        defer { sqlite3_close(db) }

        let authors    = groupedStrings(db, "SELECT bal.book, a.name FROM books_authors_link bal JOIN authors a ON a.id = bal.author ORDER BY bal.id")
        let tags       = groupedStrings(db, "SELECT btl.book, t.name FROM books_tags_link btl JOIN tags t ON t.id = btl.tag ORDER BY t.name")
        let series     = firstString(db, "SELECT bsl.book, s.name FROM books_series_link bsl JOIN series s ON s.id = bsl.series")
        let publishers = firstString(db, "SELECT bpl.book, p.name FROM books_publishers_link bpl JOIN publishers p ON p.id = bpl.publisher")
        let comments   = firstString(db, "SELECT book, text FROM comments")
        let isbns      = firstString(db, "SELECT book, val FROM identifiers WHERE type = 'isbn'")
        let languages  = firstString(db, "SELECT bll.book, l.lang_code FROM books_languages_link bll JOIN languages l ON l.id = bll.lang_code ORDER BY bll.item_order")
        let ratings    = firstInt(db,    "SELECT brl.book, r.rating FROM books_ratings_link brl JOIN ratings r ON r.id = brl.rating")
        let formats    = groupedFormats(db, "SELECT book, format, name FROM data")

        var result: [CalibreBook] = []
        eachRow(db, "SELECT id, title, series_index, path, pubdate, timestamp FROM books") { stmt in
            let id = sqlite3_column_int64(stmt, 0)
            let path = columnText(stmt, 3) ?? ""
            guard !path.isEmpty, let formatsForBook = formats[id],
                  let chosen = pickFormat(formatsForBook, preference: formatPreference) else { return }

            let bookDir = libraryRoot.appending(path: path, directoryHint: .isDirectory)
            let fileURL = bookDir.appending(path: "\(chosen.name).\(chosen.format.lowercased())")
            guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return }
            let additionalFileURLs = formatsForBook.compactMap { item -> URL? in
                guard item.format.caseInsensitiveCompare(chosen.format) != .orderedSame,
                      formatPreference.contains(where: { $0.caseInsensitiveCompare(item.format) == .orderedSame })
                else { return nil }
                let url = bookDir.appending(path: "\(item.name).\(item.format.lowercased())")
                return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
            }

            let coverURL = bookDir.appending(path: "cover.jpg")
            let hasCover = FileManager.default.fileExists(atPath: coverURL.path(percentEncoded: false))
            let bookSeries = series[id]

            result.append(CalibreBook(
                title: columnText(stmt, 1) ?? "Untitled",
                authors: authors[id] ?? [],
                series: bookSeries,
                seriesIndex: bookSeries != nil ? formatSeriesIndex(sqlite3_column_double(stmt, 2)) : nil,
                publisher: publishers[id],
                year: year(from: columnText(stmt, 4)),
                language: languages[id],
                isbn: isbns[id],
                tags: tags[id] ?? [],
                bookDescription: comments[id],
                rating: ratings[id].flatMap(winstonRating),
                dateAdded: date(from: columnText(stmt, 5)),
                fileURL: fileURL,
                additionalFileURLs: additionalFileURLs,
                coverURL: hasCover ? coverURL : nil
            ))
        }
        return result
    }

    // MARK: - Pure mapping (unit-tested)

    static func pickFormat(_ formats: [(format: String, name: String)],
                           preference: [String]) -> (format: String, name: String)? {
        for pref in preference {
            if let match = formats.first(where: { $0.format.lowercased() == pref }) { return match }
        }
        return nil
    }

    static func winstonRating(_ raw: Int) -> Int? {
        guard raw > 0 else { return nil }
        return min(5, max(1, Int((Double(raw) / 2.0).rounded())))
    }

    static func formatSeriesIndex(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    static func year(from pubdate: String?) -> String? {
        guard let pubdate, pubdate.count >= 4 else { return nil }
        let prefix = String(pubdate.prefix(4))
        guard let y = Int(prefix), y > 0, y != 101 else { return nil }
        return prefix
    }

    static func date(from raw: String?) -> Date? {
        guard let raw, raw.count >= 19 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: String(raw.prefix(19)).replacingOccurrences(of: "T", with: " "))
    }

    // MARK: - SQLite helpers

    private static func eachRow(_ db: OpaquePointer, _ sql: String, _ body: (OpaquePointer?) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { body(stmt) }
    }

    private static func columnText(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, col) else { return nil }
        let value = String(cString: c)
        return value.isEmpty ? nil : value
    }

    private static func groupedStrings(_ db: OpaquePointer, _ sql: String) -> [Int64: [String]] {
        var map: [Int64: [String]] = [:]
        eachRow(db, sql) { stmt in
            let id = sqlite3_column_int64(stmt, 0)
            if let value = columnText(stmt, 1) { map[id, default: []].append(value) }
        }
        return map
    }

    private static func firstString(_ db: OpaquePointer, _ sql: String) -> [Int64: String] {
        var map: [Int64: String] = [:]
        eachRow(db, sql) { stmt in
            let id = sqlite3_column_int64(stmt, 0)
            if map[id] == nil, let value = columnText(stmt, 1) { map[id] = value }
        }
        return map
    }

    private static func firstInt(_ db: OpaquePointer, _ sql: String) -> [Int64: Int] {
        var map: [Int64: Int] = [:]
        eachRow(db, sql) { stmt in
            let id = sqlite3_column_int64(stmt, 0)
            if map[id] == nil { map[id] = Int(sqlite3_column_int64(stmt, 1)) }
        }
        return map
    }

    private static func groupedFormats(_ db: OpaquePointer, _ sql: String) -> [Int64: [(format: String, name: String)]] {
        var map: [Int64: [(format: String, name: String)]] = [:]
        eachRow(db, sql) { stmt in
            let id = sqlite3_column_int64(stmt, 0)
            if let format = columnText(stmt, 1), let name = columnText(stmt, 2) {
                map[id, default: []].append((format, name))
            }
        }
        return map
    }
}
