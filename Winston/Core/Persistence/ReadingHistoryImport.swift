import Foundation
import SwiftData

nonisolated enum ReadingHistoryImportSource: String, CaseIterable, Identifiable, Sendable {
    case goodreads
    case storyGraph
    case hardcover

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .goodreads: "Goodreads"
        case .storyGraph: "StoryGraph"
        case .hardcover: "Hardcover"
        }
    }
}

nonisolated enum ReadingHistoryImportError: LocalizedError, Equatable, Sendable {
    case unreadableFile
    case fileTooLarge
    case invalidCSV
    case unknownSource
    case missingTitleColumn
    case noBooks

    var errorDescription: String? {
        switch self {
        case .unreadableFile:
            String(localized: "Winston couldn’t read that export file.")
        case .fileTooLarge:
            String(localized: "That export is too large to import safely.")
        case .invalidCSV:
            String(localized: "That file isn’t a valid CSV export.")
        case .unknownSource:
            String(localized: "Winston couldn’t recognize this Goodreads, StoryGraph, or Hardcover export.")
        case .missingTitleColumn:
            String(localized: "The export is missing its book title column.")
        case .noBooks:
            String(localized: "No books were found in that export.")
        }
    }
}

nonisolated struct ReadingHistoryImportCycle: Equatable, Hashable, Identifiable, Sendable {
    let startedAt: Date?
    let endedAt: Date?
    let status: ReadingSessionStatus
    let progress: Double

    var id: String {
        "\(status.rawValue)-\(startedAt?.timeIntervalSinceReferenceDate ?? -1)-\(endedAt?.timeIntervalSinceReferenceDate ?? -1)-\(progress)"
    }
}

nonisolated struct ReadingHistoryImportRecord: Equatable, Identifiable, Sendable {
    let id: String
    let source: ReadingHistoryImportSource
    let rowNumber: Int
    let title: String
    let author: String?
    let isbn: String?
    let status: ReadingStatus?
    let rating: Double?
    let startedAt: Date?
    let finishedAt: Date?
    let readCount: Int?
    let cycles: [ReadingHistoryImportCycle]

    var winstonRating: Int? {
        guard let rating, rating > 0 else { return nil }
        return min(max(Int(rating.rounded()), 1), 5)
    }

    var knownReadingDate: Date? {
        finishedAt ?? startedAt ?? cycles.compactMap { $0.endedAt ?? $0.startedAt }.max()
    }
}

nonisolated struct ReadingHistoryImportDocument: Equatable, Sendable {
    let source: ReadingHistoryImportSource
    let fileName: String
    let records: [ReadingHistoryImportRecord]
}

nonisolated enum ReadingHistoryExportParser {
    private static let maximumFileSize = 100 * 1_024 * 1_024

    static func parse(url: URL) throws -> ReadingHistoryImportDocument {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize else {
            throw ReadingHistoryImportError.unreadableFile
        }
        guard fileSize <= maximumFileSize else {
            throw ReadingHistoryImportError.fileTooLarge
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw ReadingHistoryImportError.unreadableFile
        }
        guard data.count <= maximumFileSize else {
            throw ReadingHistoryImportError.fileTooLarge
        }
        return try parse(data: data, fileName: url.lastPathComponent)
    }

    static func parse(data: Data, fileName: String) throws -> ReadingHistoryImportDocument {
        guard let text = decode(data) else {
            throw ReadingHistoryImportError.unreadableFile
        }
        let table = try CSVTable(text: text)
        let source = try detectSource(headers: table.normalizedHeaders, fileName: fileName)
        guard table.normalizedHeaders.contains(where: titleHeaders.contains) else {
            throw ReadingHistoryImportError.missingTitleColumn
        }

        let records = table.rows.enumerated().compactMap { offset, row in
            makeRecord(row: row, rowNumber: offset + 2, source: source)
        }
        guard !records.isEmpty else { throw ReadingHistoryImportError.noBooks }
        return ReadingHistoryImportDocument(source: source, fileName: fileName, records: records)
    }

    private static let titleHeaders = ["title", "booktitle", "bookname"]

    private static func decode(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xFF, 0xFE]) {
            return String(data: data, encoding: .utf16LittleEndian)
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16BigEndian)
        }
        if let value = String(data: data, encoding: .utf8) {
            return value
        }

        let sample = data.prefix(4_096)
        if !sample.isEmpty, sample.count(where: { $0 == 0 }) > sample.count / 8 {
            for encoding in [String.Encoding.utf16, .utf16LittleEndian, .utf16BigEndian] {
                if let value = String(data: data, encoding: encoding) {
                    return value
                }
            }
        }

        for encoding in [String.Encoding.windowsCP1252, .macOSRoman, .isoLatin1] {
            if let value = String(data: data, encoding: encoding) {
                return value
            }
        }
        return nil
    }

    private static func detectSource(
        headers: Set<String>,
        fileName: String
    ) throws -> ReadingHistoryImportSource {
        if headers.contains("exclusiveshelf")
            || headers.contains("bookid")
            || (headers.contains("myrating") && headers.contains("dateread")) {
            return .goodreads
        }
        if headers.contains("readstatus")
            || headers.contains("starrating")
            || headers.contains("datesread")
            || headers.contains("isbnuid") {
            return .storyGraph
        }
        let normalizedName = fileName.normalizedMatchKey
        if normalizedName.contains("hardcover")
            || headers.contains("userbookid")
            || headers.contains("editionid")
            || headers.contains("datefinished")
            || headers.contains("finishedreading") {
            return .hardcover
        }
        throw ReadingHistoryImportError.unknownSource
    }

    private static func makeRecord(
        row: CSVRow,
        rowNumber: Int,
        source: ReadingHistoryImportSource
    ) -> ReadingHistoryImportRecord? {
        guard let title = row.value(for: titleHeaders)?.trimmedNonEmpty else { return nil }
        let author = row.value(for: ["author", "authors", "primaryauthor", "authorname"])?.trimmedNonEmpty
        let isbn = normalizeISBN(row.value(for: ["isbn13", "isbn", "isbnuid", "editionisbn"]))

        let rawStatus = row.value(for: ["exclusiveshelf", "readstatus", "readingstatus", "status", "bookstatus"])
            ?? row.value(for: ["bookshelves", "shelves", "tags"])
        let status = parseStatus(rawStatus)
        let rating = parseRating(row.value(for: ["myrating", "starrating", "userrating", "rating"]))
        let startedAt = parseDate(
            row.value(for: ["datestarted", "startedat", "startdate", "startedreading", "datestartedreading"]),
            source: source
        )
        let finishedAt = parseDate(
            row.value(for: ["dateread", "lastdateread", "datefinished", "finishedat", "finishdate", "finishedreading"]),
            source: source
        )
        let readDates = parseDateList(
            row.value(for: ["datesread", "readdates"]),
            source: source
        )
        let readCount = parseInteger(row.value(for: ["readcount", "timesread"]))
        let progress = parseProgress(row.value(for: ["progress", "percentread", "readingprogress"]))
        let cycles = makeCycles(
            status: status,
            startedAt: startedAt,
            finishedAt: finishedAt,
            readDates: readDates,
            progress: progress
        )

        return ReadingHistoryImportRecord(
            id: "\(source.rawValue)-\(rowNumber)",
            source: source,
            rowNumber: rowNumber,
            title: title,
            author: author,
            isbn: isbn,
            status: status,
            rating: rating,
            startedAt: startedAt,
            finishedAt: finishedAt,
            readCount: readCount,
            cycles: cycles
        )
    }

    private static func makeCycles(
        status: ReadingStatus?,
        startedAt: Date?,
        finishedAt: Date?,
        readDates: [Date],
        progress: Double?
    ) -> [ReadingHistoryImportCycle] {
        guard let status, status != .unread else { return [] }
        let sessionStatus = switch status {
        case .unread: ReadingSessionStatus.reading
        case .reading: ReadingSessionStatus.reading
        case .paused: ReadingSessionStatus.paused
        case .finished: ReadingSessionStatus.finished
        case .didNotFinish: ReadingSessionStatus.didNotFinish
        }
        let sessionProgress = status == .finished ? 1 : (progress ?? 0)

        var cycles: [ReadingHistoryImportCycle] = []
        if readDates.isEmpty {
            if startedAt != nil || finishedAt != nil {
                cycles.append(ReadingHistoryImportCycle(
                    startedAt: startedAt,
                    endedAt: sessionStatus.isActive ? nil : finishedAt,
                    status: sessionStatus,
                    progress: sessionProgress
                ))
            }
        } else if readDates.count == 1, let startedAt {
            cycles.append(ReadingHistoryImportCycle(
                startedAt: startedAt,
                endedAt: readDates[0],
                status: .finished,
                progress: 1
            ))
        } else {
            for date in readDates {
                cycles.append(ReadingHistoryImportCycle(
                    startedAt: nil,
                    endedAt: date,
                    status: .finished,
                    progress: 1
                ))
            }
        }

        if let finishedAt,
           !cycles.contains(where: { sameDay($0.endedAt, finishedAt) }) {
            cycles.append(ReadingHistoryImportCycle(
                startedAt: startedAt,
                endedAt: finishedAt,
                status: sessionStatus.isActive ? .finished : sessionStatus,
                progress: sessionStatus == .didNotFinish ? sessionProgress : 1
            ))
        }
        if cycles.isEmpty, sessionStatus.isActive, let startedAt {
            cycles.append(ReadingHistoryImportCycle(
                startedAt: startedAt,
                endedAt: nil,
                status: sessionStatus,
                progress: sessionProgress
            ))
        }
        return cycles.sorted {
            ($0.endedAt ?? $0.startedAt ?? .distantPast) < ($1.endedAt ?? $1.startedAt ?? .distantPast)
        }
    }

    private static func parseStatus(_ raw: String?) -> ReadingStatus? {
        guard let raw else { return nil }
        let values = raw
            .components(separatedBy: CharacterSet(charactersIn: ",;|"))
            .map(\.normalizedMatchKey)
        for value in values {
            switch value {
            case "toread", "wanttoread", "unread", "planned", "planstoread": return .unread
            case "currentlyreading", "reading", "inprogress": return .reading
            case "paused", "onhold": return .paused
            case "read", "finished", "complete", "completed": return .finished
            case "didnotfinish", "didnotfinished", "dnf", "abandoned": return .didNotFinish
            default: continue
            }
        }
        return nil
    }

    private static func parseRating(_ raw: String?) -> Double? {
        guard var raw = raw?.trimmedNonEmpty else { return nil }
        if raw.contains(","), !raw.contains(".") { raw = raw.replacingOccurrences(of: ",", with: ".") }
        guard let rating = Double(raw), rating > 0 else { return nil }
        return min(max(rating, 0), 5)
    }

    private static func parseInteger(_ raw: String?) -> Int? {
        guard let value = raw?.trimmedNonEmpty.flatMap(Int.init), value >= 0 else { return nil }
        return value
    }

    private static func parseProgress(_ raw: String?) -> Double? {
        guard var raw = raw?.trimmedNonEmpty else { return nil }
        let isPercentage = raw.contains("%")
        raw = raw.replacingOccurrences(of: "%", with: "")
        guard var value = Double(raw) else { return nil }
        if isPercentage || value > 1 { value /= 100 }
        return min(max(value, 0), 1)
    }

    private static func normalizeISBN(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.uppercased().filter { $0.isNumber || $0 == "X" }
        return value.count == 10 || value.count == 13 ? value : nil
    }

    private static func parseDateList(
        _ raw: String?,
        source: ReadingHistoryImportSource
    ) -> [Date] {
        guard let raw = raw?.trimmedNonEmpty else { return [] }
        let pattern = #"\d{4}[-/.]\d{1,2}[-/.]\d{1,2}"#
        if let expression = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(raw.startIndex..., in: raw)
            let matches = expression.matches(in: raw, range: range).compactMap { match -> Date? in
                guard let range = Range(match.range, in: raw) else { return nil }
                return parseDate(String(raw[range]), source: source)
            }
            if !matches.isEmpty { return uniqueDates(matches) }
        }
        let dates = raw.components(separatedBy: CharacterSet(charactersIn: ",;|"))
            .compactMap { parseDate($0, source: source) }
        return uniqueDates(dates)
    }

    private static func uniqueDates(_ dates: [Date]) -> [Date] {
        var seen: Set<Date> = []
        return dates.sorted().filter { seen.insert($0).inserted }
    }

    private static func parseDate(
        _ raw: String?,
        source: ReadingHistoryImportSource
    ) -> Date? {
        guard let raw = raw?.trimmedNonEmpty else { return nil }
        let datePart = String(raw.prefix { $0 != "T" && $0 != " " })
        let components = datePart.split(whereSeparator: { "-/.".contains($0) }).map(String.init)
        guard components.count == 3, let first = Int(components[0]),
              let second = Int(components[1]), let third = Int(components[2]) else { return nil }

        let year: Int
        let month: Int
        let day: Int
        if components[0].count == 4 {
            year = first
            month = second
            day = third
        } else if components[2].count == 4 {
            year = third
            if first > 12 {
                day = first
                month = second
            } else if second > 12 {
                month = first
                day = second
            } else if source == .storyGraph {
                day = first
                month = second
            } else {
                month = first
                day = second
            }
        } else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let requested = DateComponents(timeZone: calendar.timeZone, year: year, month: month, day: day)
        guard let date = calendar.date(from: requested) else { return nil }
        let verified = calendar.dateComponents([.year, .month, .day], from: date)
        guard verified.year == year, verified.month == month, verified.day == day else { return nil }
        return date
    }

    private static func sameDay(_ lhs: Date?, _ rhs: Date?) -> Bool {
        guard let lhs, let rhs else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.isDate(lhs, inSameDayAs: rhs)
    }
}

nonisolated private struct CSVTable {
    let normalizedHeaders: Set<String>
    let rows: [CSVRow]

    init(text: String) throws {
        let delimiter = Self.detectDelimiter(in: text)
        let matrix = try Self.parse(text, delimiter: delimiter)
            .filter { row in row.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
        guard let rawHeaders = matrix.first, rawHeaders.count > 1 else {
            throw ReadingHistoryImportError.invalidCSV
        }
        let headers = rawHeaders.map {
            $0.replacingOccurrences(of: "\u{FEFF}", with: "").normalizedHeader
        }
        guard Set(headers).count == headers.count else {
            throw ReadingHistoryImportError.invalidCSV
        }
        normalizedHeaders = Set(headers)
        rows = matrix.dropFirst().map { values in
            var fields: [String: String] = [:]
            for (index, header) in headers.enumerated() where index < values.count {
                fields[header] = values[index]
            }
            return CSVRow(fields: fields)
        }
    }

    private static func detectDelimiter(in text: String) -> Character {
        let candidates: [Character] = [",", "\t", ";"]
        return candidates.max { lhs, rhs in
            delimiterCount(lhs, in: text) < delimiterCount(rhs, in: text)
        } ?? ","
    }

    private static func delimiterCount(_ delimiter: Character, in text: String) -> Int {
        var count = 0
        var quoted = false
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            if character == "\"" { quoted.toggle() }
            else if !quoted, character == delimiter { count += 1 }
            else if !quoted, character == "\n" || character == "\r" { break }
        }
        return count
    }

    private static func parse(_ text: String, delimiter: Character) throws -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var index = text.startIndex

        func finishField() {
            row.append(field)
            field.removeAll(keepingCapacity: true)
        }
        func finishRow() {
            finishField()
            rows.append(row)
            row.removeAll(keepingCapacity: true)
        }

        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == "\"" {
                if quoted, next < text.endIndex, text[next] == "\"" {
                    field.append("\"")
                    index = text.index(after: next)
                    continue
                }
                quoted.toggle()
            } else if character == delimiter, !quoted {
                finishField()
            } else if (character == "\n" || character == "\r"), !quoted {
                finishRow()
                if character == "\r", next < text.endIndex, text[next] == "\n" {
                    index = text.index(after: next)
                    continue
                }
            } else {
                field.append(character)
            }
            index = next
        }
        guard !quoted else { throw ReadingHistoryImportError.invalidCSV }
        if !field.isEmpty || !row.isEmpty { finishRow() }
        return rows
    }
}

nonisolated private struct CSVRow {
    let fields: [String: String]

    func value(for aliases: [String]) -> String? {
        for alias in aliases {
            if let value = fields[alias], !value.isEmpty { return value }
        }
        return nil
    }
}

nonisolated private extension String {
    var normalizedHeader: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

nonisolated enum ReadingHistoryImportMatchKind: String, Sendable {
    case isbn
    case titleAndAuthor
    case titleOnly
    case ambiguous
    case unmatched
    case manual

    var title: LocalizedStringResource {
        switch self {
        case .isbn: "ISBN Match"
        case .titleAndAuthor: "Title & Author Match"
        case .titleOnly: "Title Match — Review"
        case .ambiguous: "Multiple Matches"
        case .unmatched: "No Match"
        case .manual: "Selected Match"
        }
    }

    var needsReview: Bool {
        self == .titleOnly || self == .ambiguous || self == .unmatched
    }
}

nonisolated struct ReadingHistoryBookOption: Equatable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let author: String?
    let isbn: String?
}

nonisolated struct ReadingHistoryImportImpact: Equatable, Sendable {
    let newCycleCount: Int
    let changesStatus: Bool
    let changesRating: Bool

    var hasChanges: Bool { newCycleCount > 0 || changesStatus || changesRating }
}

nonisolated struct ReadingHistoryImportPreviewRow: Equatable, Identifiable, Sendable {
    let id: String
    let record: ReadingHistoryImportRecord
    var matchKind: ReadingHistoryImportMatchKind
    var matchedBookID: UUID?
    var candidates: [ReadingHistoryBookOption]
    var isIncluded: Bool
    var impact: ReadingHistoryImportImpact?
}

@MainActor
enum ReadingHistoryImportMatcher {
    static func match(
        records: [ReadingHistoryImportRecord],
        books: [Book]
    ) -> [ReadingHistoryImportPreviewRow] {
        let options = books.map(makeOption)
        let byISBN = Dictionary(grouping: options.compactMap { option -> (String, ReadingHistoryBookOption)? in
            guard let isbn = normalizedISBN(option.isbn) else { return nil }
            return (isbn, option)
        }, by: \.0).mapValues { $0.map(\.1) }
        let byTitleAuthor = Dictionary(grouping: options, by: {
            BookMatchKey(title: $0.title, author: $0.author)
        })
        let byTitle = Dictionary(grouping: options, by: { $0.title.normalizedMatchKey })
        let booksByID = Dictionary(uniqueKeysWithValues: books.map { ($0.uuid, $0) })

        return records.map { record in
            let matched: [ReadingHistoryBookOption]
            let kind: ReadingHistoryImportMatchKind
            if let isbn = normalizedISBN(record.isbn), let isbnMatches = byISBN[isbn], !isbnMatches.isEmpty {
                matched = isbnMatches
                kind = isbnMatches.count == 1 ? .isbn : .ambiguous
            } else {
                let key = BookMatchKey(title: record.title, author: record.author)
                if key.isComplete, let exact = byTitleAuthor[key], !exact.isEmpty {
                    matched = exact
                    kind = exact.count == 1 ? .titleAndAuthor : .ambiguous
                } else if let titleMatches = byTitle[key.title], !titleMatches.isEmpty {
                    matched = titleMatches
                    kind = titleMatches.count == 1 ? .titleOnly : .ambiguous
                } else {
                    matched = []
                    kind = .unmatched
                }
            }

            let bookID = matched.count == 1 ? matched[0].id : nil
            let impact = bookID.flatMap { booksByID[$0] }.map {
                ReadingHistoryImportImpactBuilder.impact(record: record, book: $0)
            }
            let include = bookID != nil && kind != .titleOnly && impact?.hasChanges == true
            return ReadingHistoryImportPreviewRow(
                id: record.id,
                record: record,
                matchKind: kind,
                matchedBookID: bookID,
                candidates: matched,
                isIncluded: include,
                impact: impact
            )
        }
    }

    static func makeOption(_ book: Book) -> ReadingHistoryBookOption {
        ReadingHistoryBookOption(
            id: book.uuid,
            title: book.displayTitle,
            author: book.displayAuthor,
            isbn: book.isbn
        )
    }

    static func normalizedISBN(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.uppercased().filter { $0.isNumber || $0 == "X" }
        return value.count == 10 || value.count == 13 ? value : nil
    }
}

@MainActor
enum ReadingHistoryImportImpactBuilder {
    static func impact(record: ReadingHistoryImportRecord, book: Book) -> ReadingHistoryImportImpact {
        let newCycles = record.cycles.count { cycle in
            !ReadingHistorySessionMatcher.contains(cycle, in: book.readingSessions)
        }
        return ReadingHistoryImportImpact(
            newCycleCount: newCycles,
            changesStatus: record.status.map { $0 != book.readingStatus } ?? false,
            changesRating: record.winstonRating.map { $0 != book.rating } ?? false
        )
    }
}

nonisolated struct ReadingHistoryImportResult: Equatable, Sendable {
    let bookCount: Int
    let cycleCount: Int
    let statusCount: Int
    let ratingCount: Int
}

@MainActor
final class ReadingHistoryImporter {
    private struct BookRollbackState {
        let book: Book
        let readingStatusRaw: String?
        let dateStarted: Date?
        let dateFinished: Date?
        let rating: Int?
    }

    private let modelContext: ModelContext
    private let save: @MainActor () throws -> Void

    init(
        modelContext: ModelContext,
        save: (@MainActor () throws -> Void)? = nil
    ) {
        self.modelContext = modelContext
        self.save = save ?? { try modelContext.save() }
    }

    func apply(_ rows: [ReadingHistoryImportPreviewRow]) throws -> ReadingHistoryImportResult {
        let selected = rows.filter { $0.isIncluded && $0.matchedBookID != nil }
        let bookIDs = Set(selected.compactMap(\.matchedBookID))
        let booksByID = Dictionary(uniqueKeysWithValues: modelContext.allBooks()
            .filter { bookIDs.contains($0.uuid) }
            .map { ($0.uuid, $0) })
        let rollbackStates = booksByID.values.map {
            BookRollbackState(
                book: $0,
                readingStatusRaw: $0.readingStatusRaw,
                dateStarted: $0.dateStarted,
                dateFinished: $0.dateFinished,
                rating: $0.rating
            )
        }
        var insertedSessions: [ReadingSession] = []
        var touched: Set<UUID> = []
        var cyclesAdded = 0
        var statusesChanged = 0
        var ratingsChanged = 0

        for row in selected {
            guard let bookID = row.matchedBookID, let book = booksByID[bookID] else { continue }
            var changed = false
            for cycle in row.record.cycles
            where !ReadingHistorySessionMatcher.contains(cycle, in: book.readingSessions) {
                guard let startedAt = cycle.startedAt ?? cycle.endedAt else { continue }
                let endedAt = cycle.status.isActive ? nil : (cycle.endedAt ?? startedAt)
                let session = ReadingSession(
                    startedAt: startedAt,
                    endedAt: endedAt,
                    status: cycle.status,
                    progress: cycle.progress,
                    book: book
                )
                modelContext.insert(session)
                insertedSessions.append(session)
                cyclesAdded += 1
                changed = true
            }
            if let status = row.record.status, book.readingStatus != status {
                applySummaryStatus(status, record: row.record, to: book)
                statusesChanged += 1
                changed = true
            } else if changed {
                refreshSummary(for: book)
            }
            if let rating = row.record.winstonRating, book.rating != rating {
                book.rating = rating
                ratingsChanged += 1
                changed = true
            }
            if changed { touched.insert(bookID) }
        }

        do {
            try save()
            if !touched.isEmpty { LibraryMutationLog.shared.bump() }
        } catch {
            let insertedIDs = Set(insertedSessions.map(\.uuid))
            for state in rollbackStates {
                state.book.readingStatusRaw = state.readingStatusRaw
                state.book.dateStarted = state.dateStarted
                state.book.dateFinished = state.dateFinished
                state.book.rating = state.rating
                state.book.readingSessions.removeAll { insertedIDs.contains($0.uuid) }
            }
            for session in insertedSessions where session.modelContext != nil {
                modelContext.delete(session)
            }
            modelContext.rollback()
            throw error
        }
        return ReadingHistoryImportResult(
            bookCount: touched.count,
            cycleCount: cyclesAdded,
            statusCount: statusesChanged,
            ratingCount: ratingsChanged
        )
    }

    private func applySummaryStatus(
        _ status: ReadingStatus,
        record: ReadingHistoryImportRecord,
        to book: Book
    ) {
        book.readingStatus = status
        switch status {
        case .unread:
            book.dateStarted = nil
            book.dateFinished = nil
        case .reading, .paused:
            let active = book.readingSessionsChronological.last { $0.endedAt == nil && $0.status.isActive }
            book.dateStarted = active?.startedAt ?? record.startedAt
            book.dateFinished = nil
        case .finished:
            let latest = book.readingSessionsChronological.last { $0.status == .finished }
            book.dateStarted = latest?.startedAt ?? record.startedAt
            book.dateFinished = latest?.endedAt ?? record.finishedAt
        case .didNotFinish:
            let latest = book.readingSessionsChronological.last { $0.status == .didNotFinish }
            book.dateStarted = latest?.startedAt ?? record.startedAt
            book.dateFinished = nil
        }
    }

    private func refreshSummary(for book: Book) {
        guard let latest = book.readingSessionsChronological.last else { return }
        book.readingStatus = latest.status.readingStatus
        book.dateStarted = latest.startedAt
        book.dateFinished = latest.status == .finished ? latest.endedAt : nil
    }
}

@MainActor
private enum ReadingHistorySessionMatcher {
    static func contains(_ cycle: ReadingHistoryImportCycle, in sessions: [ReadingSession]) -> Bool {
        sessions.contains { session in
            guard session.status == cycle.status else { return false }
            if let endedAt = cycle.endedAt {
                return sameDay(session.endedAt, endedAt)
                    && (cycle.startedAt == nil || sameDay(session.startedAt, cycle.startedAt))
            }
            guard let startedAt = cycle.startedAt else { return false }
            return session.endedAt == nil && sameDay(session.startedAt, startedAt)
        }
    }

    private static func sameDay(_ lhs: Date?, _ rhs: Date?) -> Bool {
        guard let lhs, let rhs else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.isDate(lhs, inSameDayAs: rhs)
    }
}
