import Foundation
import OSLog
import PDFKit
import SQLite3

nonisolated struct FullTextBookSnapshot: Sendable, Equatable, Identifiable {
    struct AssetGeneration: Sendable, Equatable {
        let assetID: UUID
        let fileName: String
        let contentHash: String?
        let sizeBytes: Int64
        let dateAdded: Date

        var storageKey: String {
            let normalizedHash = contentHash?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            return [
                assetID.uuidString.lowercased(),
                String(dateAdded.timeIntervalSinceReferenceDate.bitPattern),
                String(sizeBytes),
                "\(fileName.utf8.count):\(fileName)",
                "\(normalizedHash.utf8.count):\(normalizedHash)",
            ].joined(separator: "|")
        }
    }

    struct Source: Sendable, Equatable {
        let fileURL: URL
        let generation: AssetGeneration

        var format: String { fileURL.pathExtension.lowercased() }
        var assetID: UUID { generation.assetID }
        var contentHash: String? { generation.contentHash }
    }

    let bookID: UUID
    let title: String
    let author: String?
    let source: Source?

    var id: UUID { bookID }
}

nonisolated struct FullTextIndexSummary: Sendable, Equatable {
    let searchableBooks: Int
    let indexedBooks: Int
    let reusedBooks: Int
    let failedBooks: Int
    let unsupportedBooks: Int
}

nonisolated struct FullTextBookResult: Sendable, Equatable, Identifiable {
    let bookID: UUID
    let title: String
    let author: String?
    let format: String
    let chapters: [FullTextChapterResult]

    var id: UUID { bookID }
    var matchCount: Int { chapters.reduce(0) { $0 + $1.excerpts.count } }
}

nonisolated struct FullTextChapterResult: Sendable, Equatable, Identifiable {
    let id: String
    let title: String?
    let kind: FullTextSectionKind
    let ordinal: Int
    let excerpts: [FullTextExcerpt]
}

nonisolated struct FullTextExcerpt: Sendable, Equatable, Identifiable {
    let id: String
    let text: String
}

nonisolated struct FullTextSearchPage: Sendable, Equatable {
    let results: [FullTextBookResult]
    let offset: Int
    let limit: Int
    let nextOffset: Int?
}

nonisolated enum FullTextSectionKind: String, Codable, Sendable, Equatable {
    case chapter
    case page
    case document
}

nonisolated struct StoredFullTextSection: Codable, Sendable {
    let id: String
    let title: String?
    let kind: FullTextSectionKind
    let ordinal: Int
    let text: String
}

private nonisolated struct IndexedFullTextDocument: Sendable {
    let assetID: UUID
    let assetGeneration: String
    let title: String
    let author: String?
    let format: String
    let sourcePath: String
    let sourceHash: String
    let sourceFileGeneration: CatalogFileGeneration
}

private nonisolated struct FullTextSQLiteError: Error, LocalizedError, Sendable {
    let code: Int32
    let operation: String
    let message: String

    var errorDescription: String? {
        "\(operation) failed (\(code)): \(message)"
    }

    var isCorruption: Bool {
        let primaryCode = code & 0xFF
        return primaryCode == SQLITE_CORRUPT || primaryCode == SQLITE_NOTADB
    }
}

private nonisolated enum FullTextIndexError: Error, LocalizedError, Sendable {
    case sourceUnavailable
    case sourceChanged
    case rebuildRequired

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            "The indexed source file is unavailable"
        case .sourceChanged:
            "The indexed source changed while it was being read"
        case .rebuildRequired:
            "The local full-text database was corrupt and has been reset"
        }
    }
}

private nonisolated struct FullTextResultRow: Sendable {
    let bookID: UUID
    let title: String
    let author: String?
    let format: String
    let sectionID: String
    let sectionTitle: String?
    let sectionKind: FullTextSectionKind
    let sectionOrdinal: Int
    let snippet: String
}

private nonisolated struct FullTextBookResultBuilder: Sendable {
    let bookID: UUID
    let title: String
    let author: String?
    let format: String
    var chapters: [FullTextChapterResult] = []

    mutating func append(_ row: FullTextResultRow) {
        chapters.append(FullTextChapterResult(
            id: row.sectionID,
            title: row.sectionTitle,
            kind: row.sectionKind,
            ordinal: row.sectionOrdinal,
            excerpts: [
                FullTextExcerpt(
                    id: "\(row.sectionID):fts",
                    text: row.snippet
                ),
            ]
        ))
    }

    func result() -> FullTextBookResult {
        FullTextBookResult(
            bookID: bookID,
            title: title,
            author: author,
            format: format.uppercased(),
            chapters: chapters.sorted {
                if $0.ordinal != $1.ordinal { return $0.ordinal < $1.ordinal }
                return $0.id < $1.id
            }
        )
    }
}

actor FullTextSearchIndex {
    nonisolated static let shared = FullTextSearchIndex()
    nonisolated static let supportedFormats: Set<String> = ["epub", "pdf", "txt", "html", "htm"]

    private static let schemaVersion: Int32 = 1
    private static let maximumBookResults = 80
    private static let maximumExcerpts = 240

    private let executor = DispatchQueueSerialExecutor(label: "cz.annajung.Winston.full-text")
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    private let indexDirectory: URL
    private let databaseURL: URL
    private var database: OpaquePointer?

    init(indexDirectory: URL = AppPaths.fullTextIndexDirectory) {
        self.indexDirectory = indexDirectory
        databaseURL = indexDirectory.appending(path: "fulltext.sqlite3")
    }

    deinit {
        if let database {
            sqlite3_close_v2(database)
        }
    }

    func synchronize(
        _ snapshots: [FullTextBookSnapshot],
        forceReindex: Bool = false
    ) throws -> FullTextIndexSummary {
        do {
            return try synchronizeAll(snapshots, forceReindex: forceReindex)
        } catch let error as FullTextSQLiteError where error.isCorruption {
            Log.search.error(
                "Full-text database corruption detected during synchronization: \(error.localizedDescription, privacy: .public)"
            )
            try resetDatabase()
            return try synchronizeAll(snapshots, forceReindex: true)
        }
    }

    func applyChanges(
        _ snapshots: [FullTextBookSnapshot],
        removing removedBookIDs: Set<UUID>
    ) throws -> FullTextIndexSummary {
        do {
            return try synchronizeChanges(snapshots, removing: removedBookIDs)
        } catch let error as FullTextSQLiteError where error.isCorruption {
            Log.search.error(
                "Full-text database corruption detected during an incremental update: \(error.localizedDescription, privacy: .public)"
            )
            try resetDatabase()
            throw FullTextIndexError.rebuildRequired
        }
    }

    func search(_ rawQuery: String) throws -> [FullTextBookResult] {
        try searchPage(rawQuery).results
    }

    func searchPage(
        _ rawQuery: String,
        limit proposedLimit: Int = maximumBookResults,
        offset proposedOffset: Int = 0
    ) throws -> FullTextSearchPage {
        do {
            return try queryDatabase(
                rawQuery,
                limit: min(max(proposedLimit, 1), Self.maximumBookResults),
                offset: max(proposedOffset, 0)
            )
        } catch let error as FullTextSQLiteError where error.isCorruption {
            Log.search.error(
                "Full-text database corruption detected during search: \(error.localizedDescription, privacy: .public)"
            )
            try resetDatabase()
            throw FullTextIndexError.rebuildRequired
        }
    }

    private func synchronizeAll(
        _ snapshots: [FullTextBookSnapshot],
        forceReindex: Bool
    ) throws -> FullTextIndexSummary {
        let signposter = Log.searchSignposter
        let interval = signposter.beginInterval(
            "SynchronizeFullTextIndex",
            id: signposter.makeSignpostID(),
            "\(snapshots.count) books"
        )
        defer { signposter.endInterval("SynchronizeFullTextIndex", interval) }
        try Task.checkCancellation()
        let database = try openDatabase()
        if forceReindex {
            try clearIndex(database)
        } else {
            try removeBooksMissingFromLibrary(Set(snapshots.map(\.bookID)), database: database)
        }
        let summary = try synchronizeSnapshots(snapshots, database: database)
        removeLegacyJSONIndexes()
        return summary
    }

    private func synchronizeChanges(
        _ snapshots: [FullTextBookSnapshot],
        removing removedBookIDs: Set<UUID>
    ) throws -> FullTextIndexSummary {
        let signposter = Log.searchSignposter
        let interval = signposter.beginInterval(
            "UpdateFullTextIndex",
            id: signposter.makeSignpostID(),
            "\(snapshots.count) changed books"
        )
        defer { signposter.endInterval("UpdateFullTextIndex", interval) }
        try Task.checkCancellation()
        let database = try openDatabase()
        for bookID in removedBookIDs {
            try Task.checkCancellation()
            try removeBook(bookID, database: database)
        }
        return try synchronizeSnapshots(snapshots, database: database)
    }

    private func synchronizeSnapshots(
        _ snapshots: [FullTextBookSnapshot],
        database: OpaquePointer
    ) throws -> FullTextIndexSummary {
        var indexedBooks = 0
        var reusedBooks = 0
        var failedBooks = 0
        var unsupportedBooks = 0

        for snapshot in snapshots {
            try Task.checkCancellation()
            guard let source = snapshot.source,
                  Self.supportedFormats.contains(source.format) else {
                unsupportedBooks += 1
                try removeBook(snapshot.bookID, database: database)
                continue
            }

            do {
                switch try synchronize(snapshot, source: source, database: database) {
                case .indexed:
                    indexedBooks += 1
                case .reused:
                    reusedBooks += 1
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as FullTextSQLiteError {
                throw error
            } catch {
                failedBooks += 1
                try removeBook(snapshot.bookID, database: database)
                Log.search.error(
                    "Indexing \(source.fileURL.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        try Task.checkCancellation()
        return FullTextIndexSummary(
            searchableBooks: try searchableBookCount(database),
            indexedBooks: indexedBooks,
            reusedBooks: reusedBooks,
            failedBooks: failedBooks,
            unsupportedBooks: unsupportedBooks
        )
    }

    private enum SynchronizationOutcome {
        case indexed
        case reused
    }

    private func synchronize(
        _ snapshot: FullTextBookSnapshot,
        source: FullTextBookSnapshot.Source,
        database: OpaquePointer
    ) throws -> SynchronizationOutcome {
        guard let initialFileGeneration = CatalogFileGeneration.capture(at: source.fileURL) else {
            throw FullTextIndexError.sourceUnavailable
        }
        let path = sourcePath(for: source.fileURL)
        let assetGeneration = source.generation.storageKey
        let cached = try indexedDocument(for: snapshot.bookID, database: database)

        if let cached,
           cached.assetID == source.assetID,
           cached.assetGeneration == assetGeneration,
           cached.format == source.format,
           cached.sourcePath == path,
           cached.sourceFileGeneration == initialFileGeneration {
            try upsertDocument(
                snapshot,
                source: source,
                sourcePath: path,
                sourceHash: cached.sourceHash,
                sourceFileGeneration: initialFileGeneration,
                database: database
            )
            return .reused
        }

        let contentHash = try resolvedHash(for: source)
        try Task.checkCancellation()
        guard CatalogFileGeneration.capture(at: source.fileURL) == initialFileGeneration else {
            throw FullTextIndexError.sourceChanged
        }

        if let cached,
           cached.sourceHash.caseInsensitiveCompare(contentHash) == .orderedSame,
           cached.format == source.format {
            try updateReusedDocument(
                snapshot,
                source: source,
                sourcePath: path,
                sourceHash: contentHash,
                sourceFileGeneration: initialFileGeneration,
                database: database
            )
            return .reused
        }

        let sections = try FullTextDocumentExtractor.extract(
            source.fileURL,
            format: source.format
        )
        try Task.checkCancellation()
        guard CatalogFileGeneration.capture(at: source.fileURL) == initialFileGeneration else {
            throw FullTextIndexError.sourceChanged
        }
        try replaceDocument(
            snapshot,
            source: source,
            sourcePath: path,
            sourceHash: contentHash,
            sourceFileGeneration: initialFileGeneration,
            sections: sections,
            database: database
        )
        return .indexed
    }

    private func queryDatabase(
        _ rawQuery: String,
        limit: Int,
        offset: Int
    ) throws -> FullTextSearchPage {
        let query = Self.collapsedWhitespace(rawQuery)
        guard query.count >= 2 else {
            return FullTextSearchPage(results: [], offset: offset, limit: limit, nextOffset: nil)
        }
        try Task.checkCancellation()
        let database = try openDatabase()

        let signposter = Log.searchSignposter
        let interval = signposter.beginInterval(
            "SearchFullTextIndex",
            id: signposter.makeSignpostID(),
            "\(query.count) query characters"
        )
        defer { signposter.endInterval("SearchFullTextIndex", interval) }

        let sql = """
        SELECT d.book_id, d.title, d.author, d.format,
               sections.section_id, sections.section_title, sections.section_kind,
               sections.section_ordinal,
               snippet(sections, 7, '', '', '…', 40)
        FROM sections
        JOIN documents AS d ON d.book_id = sections.book_id
        WHERE sections MATCH ?
        ORDER BY bm25(sections), d.title COLLATE NOCASE, sections.section_ordinal
        """
        let statement = try prepare(sql, database: database)
        defer { sqlite3_finalize(statement) }
        try bind(Self.matchExpression(for: query), at: 1, statement: statement, database: database)

        sqlite3_progress_handler(database, 500, { _ in
            Task<Never, Never>.isCancelled ? 1 : 0
        }, nil)
        defer { sqlite3_progress_handler(database, 0, nil, nil) }

        var discoveredBookIDs: Set<UUID> = []
        var includedBookIDs: Set<UUID> = []
        var order: [UUID] = []
        var builders: [UUID: FullTextBookResultBuilder] = [:]
        var excerptCount = 0
        var hasMore = false

        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            if code == SQLITE_INTERRUPT, Task.isCancelled {
                throw CancellationError()
            }
            guard code == SQLITE_ROW else {
                throw sqliteError(code, operation: "Search query", database: database)
            }
            try Task.checkCancellation()
            guard let row = resultRow(statement) else { continue }

            if discoveredBookIDs.insert(row.bookID).inserted {
                let discoveredIndex = discoveredBookIDs.count - 1
                if discoveredIndex < offset {
                    continue
                }
                guard order.count < limit, excerptCount < Self.maximumExcerpts else {
                    hasMore = true
                    break
                }
                includedBookIDs.insert(row.bookID)
                order.append(row.bookID)
                builders[row.bookID] = FullTextBookResultBuilder(
                    bookID: row.bookID,
                    title: row.title,
                    author: row.author,
                    format: row.format
                )
            }

            guard includedBookIDs.contains(row.bookID),
                  excerptCount < Self.maximumExcerpts else { continue }
            builders[row.bookID]?.append(row)
            excerptCount += 1
        }

        let results = order.compactMap { builders[$0]?.result() }
        return FullTextSearchPage(
            results: results,
            offset: offset,
            limit: limit,
            nextOffset: hasMore ? offset + results.count : nil
        )
    }

    private func resultRow(_ statement: OpaquePointer) -> FullTextResultRow? {
        guard let bookIDString = columnText(statement, at: 0),
              let bookID = UUID(uuidString: bookIDString),
              let title = columnText(statement, at: 1),
              let format = columnText(statement, at: 3),
              let sectionID = columnText(statement, at: 4),
              let kindRaw = columnText(statement, at: 6),
              let kind = FullTextSectionKind(rawValue: kindRaw),
              let snippet = columnText(statement, at: 8) else {
            return nil
        }
        return FullTextResultRow(
            bookID: bookID,
            title: title,
            author: columnText(statement, at: 2),
            format: format,
            sectionID: sectionID,
            sectionTitle: columnText(statement, at: 5),
            sectionKind: kind,
            sectionOrdinal: Int(sqlite3_column_int64(statement, 7)),
            snippet: snippet
        )
    }

    private func indexedDocument(
        for bookID: UUID,
        database: OpaquePointer
    ) throws -> IndexedFullTextDocument? {
        let statement = try prepare(
            """
            SELECT asset_id, asset_generation, title, author, format, source_path,
                   source_hash, source_resource_id, source_modified, source_size
            FROM documents WHERE book_id = ?
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(bookID.uuidString.lowercased(), at: 1, statement: statement, database: database)
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW else {
            throw sqliteError(code, operation: "Load indexed document", database: database)
        }
        guard let assetIDString = columnText(statement, at: 0),
              let assetID = UUID(uuidString: assetIDString),
              let assetGeneration = columnText(statement, at: 1),
              let title = columnText(statement, at: 2),
              let format = columnText(statement, at: 4),
              let sourcePath = columnText(statement, at: 5),
              let sourceHash = columnText(statement, at: 6) else {
            throw sqliteError(SQLITE_CORRUPT, operation: "Decode indexed document", database: database)
        }
        let modificationDate = sqlite3_column_type(statement, 8) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 8))
        return IndexedFullTextDocument(
            assetID: assetID,
            assetGeneration: assetGeneration,
            title: title,
            author: columnText(statement, at: 3),
            format: format,
            sourcePath: sourcePath,
            sourceHash: sourceHash,
            sourceFileGeneration: CatalogFileGeneration(
                resourceIdentifier: columnText(statement, at: 7),
                modificationDate: modificationDate,
                fileSize: sqlite3_column_int64(statement, 9)
            )
        )
    }

    private func replaceDocument(
        _ snapshot: FullTextBookSnapshot,
        source: FullTextBookSnapshot.Source,
        sourcePath: String,
        sourceHash: String,
        sourceFileGeneration: CatalogFileGeneration,
        sections: [StoredFullTextSection],
        database: OpaquePointer
    ) throws {
        try transaction(database) {
            try deleteSections(for: snapshot.bookID, database: database)
            let statement = try prepare(
                """
                INSERT INTO sections(
                    book_id, asset_id, asset_generation, section_id, section_title,
                    section_kind, section_ordinal, body
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                database: database
            )
            defer { sqlite3_finalize(statement) }

            for section in sections {
                try Task.checkCancellation()
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bind(snapshot.bookID.uuidString.lowercased(), at: 1, statement: statement, database: database)
                try bind(source.assetID.uuidString.lowercased(), at: 2, statement: statement, database: database)
                try bind(source.generation.storageKey, at: 3, statement: statement, database: database)
                try bind(section.id, at: 4, statement: statement, database: database)
                try bind(section.title, at: 5, statement: statement, database: database)
                try bind(section.kind.rawValue, at: 6, statement: statement, database: database)
                guard sqlite3_bind_int64(statement, 7, Int64(section.ordinal)) == SQLITE_OK else {
                    throw sqliteError(
                        sqlite3_errcode(database),
                        operation: "Bind section ordinal",
                        database: database
                    )
                }
                try bind(section.text, at: 8, statement: statement, database: database)
                try stepToCompletion(statement, operation: "Insert full-text section", database: database)
            }
            try upsertDocument(
                snapshot,
                source: source,
                sourcePath: sourcePath,
                sourceHash: sourceHash,
                sourceFileGeneration: sourceFileGeneration,
                database: database
            )
        }
    }

    private func updateReusedDocument(
        _ snapshot: FullTextBookSnapshot,
        source: FullTextBookSnapshot.Source,
        sourcePath: String,
        sourceHash: String,
        sourceFileGeneration: CatalogFileGeneration,
        database: OpaquePointer
    ) throws {
        try transaction(database) {
            let statement = try prepare(
                "UPDATE sections SET asset_id = ?, asset_generation = ? WHERE book_id = ?",
                database: database
            )
            defer { sqlite3_finalize(statement) }
            try bind(source.assetID.uuidString.lowercased(), at: 1, statement: statement, database: database)
            try bind(source.generation.storageKey, at: 2, statement: statement, database: database)
            try bind(snapshot.bookID.uuidString.lowercased(), at: 3, statement: statement, database: database)
            try stepToCompletion(statement, operation: "Update indexed asset generation", database: database)
            try upsertDocument(
                snapshot,
                source: source,
                sourcePath: sourcePath,
                sourceHash: sourceHash,
                sourceFileGeneration: sourceFileGeneration,
                database: database
            )
        }
    }

    private func upsertDocument(
        _ snapshot: FullTextBookSnapshot,
        source: FullTextBookSnapshot.Source,
        sourcePath: String,
        sourceHash: String,
        sourceFileGeneration: CatalogFileGeneration,
        database: OpaquePointer
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO documents(
                book_id, asset_id, asset_generation, title, author, format,
                source_path, source_hash, source_resource_id, source_modified, source_size
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(book_id) DO UPDATE SET
                asset_id = excluded.asset_id,
                asset_generation = excluded.asset_generation,
                title = excluded.title,
                author = excluded.author,
                format = excluded.format,
                source_path = excluded.source_path,
                source_hash = excluded.source_hash,
                source_resource_id = excluded.source_resource_id,
                source_modified = excluded.source_modified,
                source_size = excluded.source_size
            """,
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(snapshot.bookID.uuidString.lowercased(), at: 1, statement: statement, database: database)
        try bind(source.assetID.uuidString.lowercased(), at: 2, statement: statement, database: database)
        try bind(source.generation.storageKey, at: 3, statement: statement, database: database)
        try bind(snapshot.title, at: 4, statement: statement, database: database)
        try bind(snapshot.author, at: 5, statement: statement, database: database)
        try bind(source.format, at: 6, statement: statement, database: database)
        try bind(sourcePath, at: 7, statement: statement, database: database)
        try bind(sourceHash, at: 8, statement: statement, database: database)
        try bind(sourceFileGeneration.resourceIdentifier, at: 9, statement: statement, database: database)
        if let modificationDate = sourceFileGeneration.modificationDate {
            guard sqlite3_bind_double(
                statement,
                10,
                modificationDate.timeIntervalSinceReferenceDate
            ) == SQLITE_OK else {
                throw sqliteError(
                    sqlite3_errcode(database),
                    operation: "Bind source modification date",
                    database: database
                )
            }
        } else {
            sqlite3_bind_null(statement, 10)
        }
        guard sqlite3_bind_int64(statement, 11, sourceFileGeneration.fileSize) == SQLITE_OK else {
            throw sqliteError(
                sqlite3_errcode(database),
                operation: "Bind source size",
                database: database
            )
        }
        try stepToCompletion(statement, operation: "Upsert indexed document", database: database)
    }

    private func removeBooksMissingFromLibrary(
        _ libraryBookIDs: Set<UUID>,
        database: OpaquePointer
    ) throws {
        let statement = try prepare("SELECT book_id FROM documents", database: database)
        defer { sqlite3_finalize(statement) }
        var staleIDs: [UUID] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else {
                throw sqliteError(code, operation: "List indexed documents", database: database)
            }
            if let raw = columnText(statement, at: 0),
               let id = UUID(uuidString: raw),
               !libraryBookIDs.contains(id) {
                staleIDs.append(id)
            }
        }
        for id in staleIDs {
            try removeBook(id, database: database)
        }
    }

    private func removeBook(_ bookID: UUID, database: OpaquePointer) throws {
        try transaction(database) {
            try deleteSections(for: bookID, database: database)
            let statement = try prepare(
                "DELETE FROM documents WHERE book_id = ?",
                database: database
            )
            defer { sqlite3_finalize(statement) }
            try bind(bookID.uuidString.lowercased(), at: 1, statement: statement, database: database)
            try stepToCompletion(statement, operation: "Delete indexed document", database: database)
        }
    }

    private func deleteSections(for bookID: UUID, database: OpaquePointer) throws {
        let statement = try prepare(
            "DELETE FROM sections WHERE book_id = ?",
            database: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(bookID.uuidString.lowercased(), at: 1, statement: statement, database: database)
        try stepToCompletion(statement, operation: "Delete indexed sections", database: database)
    }

    private func searchableBookCount(_ database: OpaquePointer) throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM documents", database: database)
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_ROW else {
            throw sqliteError(code, operation: "Count indexed documents", database: database)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func resolvedHash(for source: FullTextBookSnapshot.Source) throws -> String {
        let actual = try ContentHasher.sha256(of: source.fileURL)
        if let catalog = source.contentHash?.trimmingCharacters(in: .whitespacesAndNewlines),
           !catalog.isEmpty,
           catalog.caseInsensitiveCompare(actual) != .orderedSame {
            Log.search.notice(
                "The catalog hash for \(source.fileURL.lastPathComponent, privacy: .public) was stale; rebuilding its full-text index"
            )
        }
        return actual
    }

    private func sourcePath(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
    }

    private func openDatabase() throws -> OpaquePointer {
        if let database { return database }
        try AppPaths.ensureDirectory(indexDirectory)
        var opened: OpaquePointer?
        let code = sqlite3_open_v2(
            databaseURL.path(percentEncoded: false),
            &opened,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard code == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) }
                ?? "SQLite could not open the full-text database."
            if let opened { sqlite3_close_v2(opened) }
            throw FullTextSQLiteError(code: code, operation: "Open full-text database", message: message)
        }

        database = opened
        sqlite3_extended_result_codes(opened, 1)
        sqlite3_busy_timeout(opened, 5_000)
        do {
            try execute(
                """
                PRAGMA journal_mode = WAL;
                PRAGMA synchronous = NORMAL;
                PRAGMA temp_store = MEMORY;
                """,
                database: opened
            )
            let version = try userVersion(opened)
            if version != Self.schemaVersion {
                try rebuildSchema(opened)
            }
            return opened
        } catch {
            sqlite3_close_v2(opened)
            database = nil
            throw error
        }
    }

    private func rebuildSchema(_ database: OpaquePointer) throws {
        try execute(
            """
            BEGIN IMMEDIATE;
            DROP TABLE IF EXISTS sections;
            DROP TABLE IF EXISTS documents;
            CREATE TABLE documents(
                book_id TEXT PRIMARY KEY NOT NULL,
                asset_id TEXT NOT NULL,
                asset_generation TEXT NOT NULL,
                title TEXT NOT NULL,
                author TEXT,
                format TEXT NOT NULL,
                source_path TEXT NOT NULL,
                source_hash TEXT NOT NULL,
                source_resource_id TEXT,
                source_modified REAL,
                source_size INTEGER NOT NULL
            );
            CREATE VIRTUAL TABLE sections USING fts5(
                book_id UNINDEXED,
                asset_id UNINDEXED,
                asset_generation UNINDEXED,
                section_id UNINDEXED,
                section_title,
                section_kind UNINDEXED,
                section_ordinal UNINDEXED,
                body,
                tokenize = 'unicode61 remove_diacritics 2'
            );
            PRAGMA user_version = \(Self.schemaVersion);
            COMMIT;
            """,
            database: database
        )
    }

    private func clearIndex(_ database: OpaquePointer) throws {
        try transaction(database) {
            try execute("DELETE FROM sections; DELETE FROM documents;", database: database)
        }
    }

    private func resetDatabase() throws {
        if let database {
            sqlite3_close_v2(database)
            self.database = nil
        }
        let fileManager = FileManager.default
        for url in [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path(percentEncoded: false) + "-wal"),
            URL(fileURLWithPath: databaseURL.path(percentEncoded: false) + "-shm"),
        ] where fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
            try fileManager.removeItem(at: url)
        }
        _ = try openDatabase()
    }

    private func removeLegacyJSONIndexes() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: indexDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for url in urls where url.pathExtension.lowercased() == "json" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func userVersion(_ database: OpaquePointer) throws -> Int32 {
        let statement = try prepare("PRAGMA user_version", database: database)
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_ROW else {
            throw sqliteError(code, operation: "Read full-text schema version", database: database)
        }
        return sqlite3_column_int(statement, 0)
    }

    private func transaction(
        _ database: OpaquePointer,
        _ body: () throws -> Void
    ) throws {
        try execute("BEGIN IMMEDIATE", database: database)
        do {
            try body()
            try execute("COMMIT", database: database)
        } catch {
            try? execute("ROLLBACK", database: database)
            throw error
        }
    }

    private func execute(_ sql: String, database: OpaquePointer) throws {
        let code = sqlite3_exec(database, sql, nil, nil, nil)
        guard code == SQLITE_OK else {
            throw sqliteError(code, operation: "Execute full-text SQL", database: database)
        }
    }

    private func prepare(_ sql: String, database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            throw sqliteError(code, operation: "Prepare full-text SQL", database: database)
        }
        return statement
    }

    private func bind(
        _ value: String?,
        at index: Int32,
        statement: OpaquePointer,
        database: OpaquePointer
    ) throws {
        let code: Int32
        if let value {
            code = sqlite3_bind_text(
                statement,
                index,
                value,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        } else {
            code = sqlite3_bind_null(statement, index)
        }
        guard code == SQLITE_OK else {
            throw sqliteError(code, operation: "Bind full-text SQL value", database: database)
        }
    }

    private func stepToCompletion(
        _ statement: OpaquePointer,
        operation: String,
        database: OpaquePointer
    ) throws {
        let code = sqlite3_step(statement)
        if code == SQLITE_INTERRUPT, Task.isCancelled {
            throw CancellationError()
        }
        guard code == SQLITE_DONE else {
            throw sqliteError(code, operation: operation, database: database)
        }
    }

    private func columnText(_ statement: OpaquePointer, at index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private func sqliteError(
        _ code: Int32,
        operation: String,
        database: OpaquePointer
    ) -> FullTextSQLiteError {
        FullTextSQLiteError(
            code: code,
            operation: operation,
            message: String(cString: sqlite3_errmsg(database))
        )
    }

    private static func matchExpression(for query: String) -> String {
        "\"\(query.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func collapsedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

typealias FullTextIndexService = FullTextSearchIndex

private nonisolated enum FullTextDocumentExtractor {
    enum ExtractionError: Error, LocalizedError {
        case noText
        case tooLarge
        case unsupported

        var errorDescription: String? {
            switch self {
            case .noText: "The document has no searchable text"
            case .tooLarge: "The document contains too much text to index safely"
            case .unsupported: "The document format is not supported for full-text search"
            }
        }
    }

    private static let maximumTextBytes = 32 * 1_024 * 1_024
    private static let maximumPDFBytes = 512 * 1_024 * 1_024
    private static let maximumPDFPages = 20_000
    private static let headingRegex = try! NSRegularExpression(
        pattern: "<h([1-6])\\b[^>]*>([\\s\\S]*?)</h\\1>",
        options: [.caseInsensitive]
    )
    private static let titleRegex = try! NSRegularExpression(
        pattern: "<title\\b[^>]*>([\\s\\S]*?)</title>",
        options: [.caseInsensitive]
    )

    static func extract(_ url: URL, format: String) throws -> [StoredFullTextSection] {
        let sections: [StoredFullTextSection]
        switch format {
        case "epub":
            sections = try extractEPUB(url)
        case "pdf":
            sections = try extractPDF(url)
        case "txt":
            sections = try extractDocument(TextReader.read(url))
        case "html", "htm":
            sections = try extractDocument(HTMLReader.read(url))
        default:
            throw ExtractionError.unsupported
        }
        guard !sections.isEmpty else { throw ExtractionError.noText }
        return sections
    }

    private static func extractEPUB(_ url: URL) throws -> [StoredFullTextSection] {
        let archive = try EPUBArchive(url: url)
        let epub = try EPUBReader.read(url, archive: archive)
        var sections: [StoredFullTextSection] = []
        var totalBytes = 0

        for item in epub.spine where isHTML(item) {
            try Task.checkCancellation()
            guard let data = archive.entry(item.href),
                  let xhtml = decode(data) else { continue }
            let body = MOBIHTMLBuilder.bodyInner(of: xhtml)
            let fallbackTitle = firstCapture(titleRegex, group: 1, in: xhtml)
                .map(cleanText)
                .flatMap(\.nonEmpty)
            let parts = splitHTML(body, baseID: item.href, fallbackTitle: fallbackTitle)
            for part in parts {
                try append(part, to: &sections, totalBytes: &totalBytes)
            }
        }
        return sections
    }

    private static func extractPDF(_ url: URL) throws -> [StoredFullTextSection] {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > maximumPDFBytes {
            throw ExtractionError.tooLarge
        }
        guard let pdf = PDFDocument(url: url) else { throw ExtractionError.noText }
        guard pdf.pageCount <= maximumPDFPages else { throw ExtractionError.tooLarge }

        var sections: [StoredFullTextSection] = []
        var totalBytes = 0
        for index in 0 ..< pdf.pageCount {
            try Task.checkCancellation()
            guard let page = pdf.page(at: index),
                  let pageText = page.string.map(cleanText),
                  !pageText.isEmpty else { continue }
            let label = page.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            let numericLabel = String(index + 1)
            let section = StoredFullTextSection(
                id: "page-\(index + 1)",
                title: label == numericLabel ? nil : label?.nonEmpty,
                kind: .page,
                ordinal: index + 1,
                text: pageText
            )
            try append(section, to: &sections, totalBytes: &totalBytes)
        }
        return sections
    }

    private static func extractDocument(_ document: SourceDocument) throws -> [StoredFullTextSection] {
        var sections: [StoredFullTextSection] = []
        var totalBytes = 0
        for (index, html) in document.sections.enumerated() {
            try Task.checkCancellation()
            let parts = splitHTML(
                html,
                baseID: "section-\(index + 1)",
                fallbackTitle: document.sections.count == 1 ? nil : document.title
            )
            for part in parts {
                try append(part, to: &sections, totalBytes: &totalBytes)
            }
        }
        return sections
    }

    private static func splitHTML(
        _ html: String,
        baseID: String,
        fallbackTitle: String?
    ) -> [StoredFullTextSection] {
        let ns = html as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let headings = headingRegex.matches(in: html, range: fullRange)

        guard !headings.isEmpty else {
            let text = cleanText(html.removingHTMLNonContent.strippedHTML)
            guard !text.isEmpty else { return [] }
            return [StoredFullTextSection(
                id: baseID,
                title: fallbackTitle,
                kind: .document,
                ordinal: 1,
                text: text
            )]
        }

        var result: [StoredFullTextSection] = []
        let prefaceRange = NSRange(location: 0, length: headings[0].range.location)
        let preface = cleanText(ns.substring(with: prefaceRange).removingHTMLNonContent.strippedHTML)
        if !preface.isEmpty {
            result.append(StoredFullTextSection(
                id: "\(baseID)#preface",
                title: fallbackTitle,
                kind: .document,
                ordinal: 1,
                text: preface
            ))
        }

        for (index, heading) in headings.enumerated() {
            let contentStart = heading.range.location + heading.range.length
            let contentEnd = index + 1 < headings.count ? headings[index + 1].range.location : ns.length
            guard contentEnd >= contentStart else { continue }
            let title = heading.range(at: 2).location == NSNotFound
                ? nil
                : cleanText(ns.substring(with: heading.range(at: 2)).strippedHTML).nonEmpty
            let body = cleanText(ns.substring(with: NSRange(
                location: contentStart,
                length: contentEnd - contentStart
            )).removingHTMLNonContent.strippedHTML)
            let searchableText = cleanText([title, body].compactMap { $0 }.joined(separator: " "))
            guard !searchableText.isEmpty else { continue }
            result.append(StoredFullTextSection(
                id: "\(baseID)#heading-\(index + 1)",
                title: title ?? fallbackTitle,
                kind: .chapter,
                ordinal: result.count + 1,
                text: searchableText
            ))
        }
        return result
    }

    private static func append(
        _ section: StoredFullTextSection,
        to sections: inout [StoredFullTextSection],
        totalBytes: inout Int
    ) throws {
        let bytes = section.text.utf8.count
        guard bytes <= maximumTextBytes - totalBytes else { throw ExtractionError.tooLarge }
        totalBytes += bytes
        let normalized = StoredFullTextSection(
            id: section.id,
            title: section.title,
            kind: section.kind,
            ordinal: sections.count + 1,
            text: section.text
        )
        sections.append(normalized)
    }

    private static func isHTML(_ item: ParsedEPUB.Item) -> Bool {
        let mediaType = item.mediaType.lowercased()
        if mediaType.contains("html") || mediaType.contains("xml") { return true }
        return ["xhtml", "html", "htm"].contains((item.href as NSString).pathExtension.lowercased())
    }

    private static func decode(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1250)
            ?? String(data: data, encoding: .isoLatin1)
    }

    private static func cleanText(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func firstCapture(
        _ regex: NSRegularExpression,
        group: Int,
        in text: String
    ) -> String? {
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard let match = regex.firstMatch(in: text, range: range),
              match.range(at: group).location != NSNotFound else { return nil }
        return (text as NSString).substring(with: match.range(at: group))
    }
}
