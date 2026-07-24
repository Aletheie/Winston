import Foundation
import OSLog
import SQLite3

nonisolated struct CalibreBook: Codable, Sendable, Equatable {
    var calibreID: Int64
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
    var sourceFile: CalibreSourceFile
    var additionalSourceFiles: [CalibreSourceFile]
    var coverSourceFile: CalibreSourceFile?

    var fileURL: URL { sourceFile.url }
    var additionalFileURLs: [URL] { additionalSourceFiles.map(\.url) }
    var coverURL: URL? { coverSourceFile?.url }
}

nonisolated struct CalibreSourceRevalidationResult: Sendable, Equatable {
    let primaryURL: URL?
    let additionalURLs: [URL]
    let coverURL: URL?
    let rejectedSources: [CalibreRejectedSource]
}

nonisolated enum CalibreSourceRole: Sendable, Equatable {
    case bookFormat(String)
    case cover
}

nonisolated struct CalibreRejectedSource: Sendable, Equatable {
    let bookID: Int64
    let role: CalibreSourceRole
    let reason: CalibrePathError
}

nonisolated struct CalibreLibraryReadResult: Sendable, Equatable {
    let books: [CalibreBook]
    let rejectedSources: [CalibreRejectedSource]

    var unsafeRejectionCount: Int {
        rejectedSources.count(where: { $0.reason.isSecurityViolation })
    }
}

nonisolated enum CalibreImportError: Error, Equatable {
    case noLibrary
    case cannotOpen
    case unsafeLibraryPath(CalibrePathError)
    case missingSchema(String)
    case prepareFailed(code: Int32, message: String)
    case stepFailed(code: Int32, message: String)
}

nonisolated enum CalibreLibraryReader {
    static let metadataDBName = "metadata.db"
    private nonisolated static let dateFormatterLock = NSLock()
    private nonisolated static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    @concurrent
    static func read(
        libraryRoot: URL,
        formatPreference: [String]
    ) async throws -> CalibreLibraryReadResult {
        let resolver: CalibrePathResolver
        do {
            resolver = try CalibrePathResolver(
                libraryRoot: libraryRoot,
                supportedFormats: formatPreference + ["jpg", "db"]
            )
        } catch {
            throw CalibreImportError.noLibrary
        }

        let dbURL: URL
        do {
            dbURL = try resolver.resolve(
                rawRelativeBookPath: "",
                rawFileName: "metadata",
                declaredFormat: "db"
            ).url
        } catch CalibrePathError.missingFile {
            throw CalibreImportError.noLibrary
        } catch let error as CalibrePathError {
            throw CalibreImportError.unsafeLibraryPath(error)
        }

        var handle: OpaquePointer?
        let uri = dbURL.absoluteString + "?immutable=1"
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let db = handle else {
            sqlite3_close(handle)
            throw CalibreImportError.cannotOpen
        }
        defer { sqlite3_close(db) }

        let authors    = try groupedStrings(db, "SELECT bal.book, a.name FROM books_authors_link bal JOIN authors a ON a.id = bal.author ORDER BY bal.id")
        let tags       = try groupedStrings(db, "SELECT btl.book, t.name FROM books_tags_link btl JOIN tags t ON t.id = btl.tag ORDER BY t.name")
        let series     = try firstString(db, "SELECT bsl.book, s.name FROM books_series_link bsl JOIN series s ON s.id = bsl.series")
        let publishers = try firstString(db, "SELECT bpl.book, p.name FROM books_publishers_link bpl JOIN publishers p ON p.id = bpl.publisher")
        let comments   = try firstString(db, "SELECT book, text FROM comments")
        let isbns      = try firstString(db, "SELECT book, val FROM identifiers WHERE type = 'isbn'")
        let languages  = try firstString(db, "SELECT bll.book, l.lang_code FROM books_languages_link bll JOIN languages l ON l.id = bll.lang_code ORDER BY bll.item_order")
        let ratings    = try firstInt(db,    "SELECT brl.book, r.rating FROM books_ratings_link brl JOIN ratings r ON r.id = brl.rating")
        let formats    = try groupedFormats(db, "SELECT book, format, name FROM data")

        var result: [CalibreBook] = []
        var rejectedSources: [CalibreRejectedSource] = []
        try eachRow(db, "SELECT id, title, series_index, path, pubdate, timestamp FROM books") { stmt in
            let id = sqlite3_column_int64(stmt, 0)
            let path = columnText(stmt, 3) ?? ""
            guard let formatsForBook = formats[id] else { return }

            var safeSources: [CalibreSourceFile] = []
            for item in orderedFormats(formatsForBook, preference: formatPreference) {
                do {
                    safeSources.append(try resolver.resolve(
                        rawRelativeBookPath: path,
                        rawFileName: item.name,
                        declaredFormat: item.format
                    ))
                } catch let reason as CalibrePathError {
                    let rejection = CalibreRejectedSource(
                        bookID: id,
                        role: .bookFormat(item.format.lowercased()),
                        reason: reason
                    )
                    rejectedSources.append(rejection)
                    log(rejection)
                }
            }
            guard let sourceFile = safeSources.first else { return }

            let coverSourceFile: CalibreSourceFile?
            do {
                coverSourceFile = try resolver.resolve(
                    rawRelativeBookPath: path,
                    rawFileName: "cover",
                    declaredFormat: "jpg"
                )
            } catch CalibrePathError.missingFile {
                coverSourceFile = nil
            } catch let reason as CalibrePathError {
                let rejection = CalibreRejectedSource(bookID: id, role: .cover, reason: reason)
                rejectedSources.append(rejection)
                log(rejection)
                coverSourceFile = nil
            }
            let bookSeries = series[id]

            result.append(CalibreBook(
                calibreID: id,
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
                sourceFile: sourceFile,
                additionalSourceFiles: Array(safeSources.dropFirst()),
                coverSourceFile: coverSourceFile
            ))
        }
        return CalibreLibraryReadResult(books: result, rejectedSources: rejectedSources)
    }

    /// Re-checks the filesystem boundary immediately before the importer stages bytes.
    /// A rejected additional format or cover does not prevent importing a safe primary.
    @concurrent
    static func revalidateSources(
        for book: CalibreBook
    ) async -> CalibreSourceRevalidationResult {
        var rejectedSources: [CalibreRejectedSource] = []

        func revalidate(_ source: CalibreSourceFile, role: CalibreSourceRole) -> URL? {
            do {
                return try source.revalidatedURL()
            } catch let reason as CalibrePathError {
                let rejection = CalibreRejectedSource(
                    bookID: book.calibreID,
                    role: role,
                    reason: reason
                )
                rejectedSources.append(rejection)
                log(rejection)
                return nil
            } catch {
                let rejection = CalibreRejectedSource(
                    bookID: book.calibreID,
                    role: role,
                    reason: .unreadablePath
                )
                rejectedSources.append(rejection)
                log(rejection)
                return nil
            }
        }

        let primaryURL = revalidate(
            book.sourceFile,
            role: .bookFormat(book.sourceFile.declaredFormat)
        )
        let additionalURLs = book.additionalSourceFiles.compactMap {
            revalidate($0, role: .bookFormat($0.declaredFormat))
        }
        let coverURL = book.coverSourceFile.flatMap { revalidate($0, role: .cover) }
        return CalibreSourceRevalidationResult(
            primaryURL: primaryURL,
            additionalURLs: additionalURLs,
            coverURL: coverURL,
            rejectedSources: rejectedSources
        )
    }

    // MARK: - Pure mapping (unit-tested)

    static func pickFormat(_ formats: [(format: String, name: String)],
                           preference: [String]) -> (format: String, name: String)? {
        for pref in preference {
            if let match = formats.first(where: { $0.format.lowercased() == pref }) { return match }
        }
        return nil
    }

    private static func orderedFormats(
        _ formats: [(format: String, name: String)],
        preference: [String]
    ) -> [(format: String, name: String)] {
        preference.compactMap { preferred in
            formats.first { $0.format.caseInsensitiveCompare(preferred) == .orderedSame }
        }
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
        let normalized = String(raw.prefix(19)).replacingOccurrences(of: "T", with: " ")
        dateFormatterLock.lock()
        defer { dateFormatterLock.unlock() }
        return dateFormatter.date(from: normalized)
    }

    // MARK: - SQLite helpers

    static func eachRow(
        _ db: OpaquePointer,
        _ sql: String,
        _ body: (OpaquePointer?) throws -> Void
    ) throws {
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK else {
            throw databaseError(db, code: prepareResult, phase: .prepare)
        }
        defer { sqlite3_finalize(stmt) }
        while true {
            let stepResult = sqlite3_step(stmt)
            switch stepResult {
            case SQLITE_ROW:
                try body(stmt)
            case SQLITE_DONE:
                return
            default:
                throw databaseError(db, code: stepResult, phase: .step)
            }
        }
    }

    private static func columnText(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, col) else { return nil }
        let value = String(cString: c)
        return value.isEmpty ? nil : value
    }

    private static func groupedStrings(_ db: OpaquePointer, _ sql: String) throws -> [Int64: [String]] {
        var map: [Int64: [String]] = [:]
        try eachRow(db, sql) { stmt in
            let id = sqlite3_column_int64(stmt, 0)
            if let value = columnText(stmt, 1) { map[id, default: []].append(value) }
        }
        return map
    }

    private static func firstString(_ db: OpaquePointer, _ sql: String) throws -> [Int64: String] {
        var map: [Int64: String] = [:]
        try eachRow(db, sql) { stmt in
            let id = sqlite3_column_int64(stmt, 0)
            if map[id] == nil, let value = columnText(stmt, 1) { map[id] = value }
        }
        return map
    }

    private static func firstInt(_ db: OpaquePointer, _ sql: String) throws -> [Int64: Int] {
        var map: [Int64: Int] = [:]
        try eachRow(db, sql) { stmt in
            let id = sqlite3_column_int64(stmt, 0)
            if map[id] == nil { map[id] = Int(sqlite3_column_int64(stmt, 1)) }
        }
        return map
    }

    private static func groupedFormats(
        _ db: OpaquePointer,
        _ sql: String
    ) throws -> [Int64: [(format: String, name: String)]] {
        var map: [Int64: [(format: String, name: String)]] = [:]
        try eachRow(db, sql) { stmt in
            let id = sqlite3_column_int64(stmt, 0)
            if let format = columnText(stmt, 1), let name = columnText(stmt, 2) {
                map[id, default: []].append((format, name))
            }
        }
        return map
    }

    private enum DatabasePhase {
        case prepare
        case step
    }

    private static func databaseError(
        _ db: OpaquePointer,
        code: Int32,
        phase: DatabasePhase
    ) -> CalibreImportError {
        let message = String(cString: sqlite3_errmsg(db))
        if code == SQLITE_SCHEMA
            || message.localizedCaseInsensitiveContains("no such table")
            || message.localizedCaseInsensitiveContains("no such column") {
            return .missingSchema(message)
        }
        switch phase {
        case .prepare:
            return .prepareFailed(code: code, message: message)
        case .step:
            return .stepFailed(code: code, message: message)
        }
    }

    private static func log(_ rejection: CalibreRejectedSource) {
        Log.persistence.warning(
            "Rejected Calibre source for book \(rejection.bookID, privacy: .public): \(rejection.reason.rawValue, privacy: .public)"
        )
    }
}
