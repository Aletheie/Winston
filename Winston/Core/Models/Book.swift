import Foundation
import SwiftData

nonisolated struct BookMetadata: Codable, Sendable, Hashable {
    var title: String?
    var author: String?
    var publisher: String?
    var year: String?
    var language: String?
    var translator: String?
    var isbn: String?
    var series: String?
    var seriesIndex: String?
    var tags: [String] = []
    var description: String?
    var pageCount: Int?
}

@Model
final class Book {
    @Attribute(.unique) var uuid: UUID
    var fileName: String
    var originalFileName: String

    var title: String?
    var author: String?
    var publisher: String?
    var year: String?
    var language: String?
    var translator: String?
    var isbn: String?
    var series: String?
    var seriesIndex: String?
    var tags: [String]
    var bookDescription: String?

    var rating: Int?
    var communityRating: Double?
    var communityRatingCount: Int?
    var communityRatingSource: String?
    var onlineLookupAt: Date?
    var onlineLookupConfiguration: String?
    var dateAdded: Date
    // Raw string on purpose — a Codable enum column traps on NULL rows after additive migrations.
    var readingStatusRaw: String?
    var collections: [BookCollection] = []
    @Relationship(deleteRule: .cascade, inverse: \Highlight.book)
    var highlights: [Highlight] = []
    var notes: String?
    // Compatibility summary for the current/latest cycle. Full history lives in readingSessions.
    var dateFinished: Date?
    var dateStarted: Date?
    @Relationship(deleteRule: .cascade, inverse: \ReadingSession.book)
    var readingSessions: [ReadingSession] = []
    var drmProtected: Bool?
    var fileSizeBytes: Int64 = 0
    var coverVersion: Int = 0
    var pageCount: Int?
    var sampleNoticeDismissed: Bool?
    var editionStatement: String?
    var editionTypeRaw: String?
    var work: Work?
    @Relationship(deleteRule: .cascade, inverse: \BookAsset.book)
    var assets: [BookAsset] = []

    init(uuid: UUID = UUID(), fileName: String, originalFileName: String, dateAdded: Date = Date()) {
        self.uuid = uuid
        self.fileName = fileName
        self.originalFileName = originalFileName
        self.tags = []
        self.dateAdded = dateAdded
    }

    // MARK: - Derived

    var fileURL: URL {
        BookFileStore.url(for: fileName)
    }

    nonisolated(unsafe) private static let formats: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 16_384
        return cache
    }()

    var format: String {
        let key = fileName as NSString
        if let cached = Self.formats.object(forKey: key) { return cached as String }
        let value = key.pathExtension.uppercased()
        Self.formats.setObject(value as NSString, forKey: key)
        return value
    }

    var assetFormats: [String] {
        Array(Set(assets.isEmpty ? [format] : assets.map(\.format))).sorted()
    }

    var displayTitle: String {
        Self.displayTitle(storedTitle: title, originalFileName: originalFileName)
    }

    nonisolated static func displayTitle(storedTitle: String?, originalFileName: String) -> String {
        if let title = storedTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        return cleanFilename((originalFileName as NSString).deletingPathExtension)
    }

    var displayAuthor: String? {
        guard let author = author?.trimmingCharacters(in: .whitespacesAndNewlines),
              !author.isEmpty else { return nil }
        return author
    }

    var sortAuthor: String { displayAuthor ?? "" }
    var sortRating: Int { rating ?? 0 }

    nonisolated(unsafe) private static let deviceMatchKeys: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 16_384
        return cache
    }()

    var deviceMatchKey: String {
        let key = originalFileName as NSString
        if let cached = Self.deviceMatchKeys.object(forKey: key) { return cached as String }
        let value = key.deletingPathExtension.lowercased()
        Self.deviceMatchKeys.setObject(value as NSString, forKey: key)
        return value
    }

    nonisolated(unsafe) private static let fileSizes: NSCache<NSNumber, NSString> = {
        let cache = NSCache<NSNumber, NSString>()
        cache.countLimit = 8_192
        return cache
    }()

    var fileSizeDisplay: String {
        guard fileSizeBytes > 0 else { return "\u{2014}" }
        let key = NSNumber(value: fileSizeBytes)
        if let cached = Self.fileSizes.object(forKey: key) { return cached as String }
        let value = ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
        Self.fileSizes.setObject(value as NSString, forKey: key)
        return value
    }

    var readingStatus: ReadingStatus {
        get { readingStatusRaw.flatMap(ReadingStatus.init(rawValue:)) ?? .unread }
        set { readingStatusRaw = newValue.rawValue }
    }

    var editionType: EditionType {
        get { editionTypeRaw.flatMap(EditionType.init(rawValue:)) ?? .standard }
        set { editionTypeRaw = newValue.rawValue }
    }

    var readingSessionsChronological: [ReadingSession] {
        readingSessions.sorted {
            if $0.startedAt == $1.startedAt {
                return $0.uuid.uuidString < $1.uuid.uuidString
            }
            return $0.startedAt < $1.startedAt
        }
    }

    var activeReadingSession: ReadingSession? {
        readingSessions.lazy
            .filter { $0.endedAt == nil && $0.status.isActive }
            .max { lhs, rhs in
                if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
                return lhs.uuid.uuidString < rhs.uuid.uuidString
            }
    }

    var finishedReadingCount: Int {
        readingSessions.count { $0.status == .finished }
    }

    @discardableResult
    func setStatus(_ status: ReadingStatus, at date: Date = .now) -> ReadingSession? {
        switch status {
        case .unread:
            closeActiveSessions(as: .didNotFinish, at: date)
            readingStatus = .unread
            dateStarted = nil
            dateFinished = nil

        case .reading:
            if let active = activeReadingSession {
                active.status = .reading
                active.endedAt = nil
                applySummary(status: .reading, session: active)
                return active
            }
            let session = makeReadingSession(startedAt: date, status: .reading)
            applySummary(status: .reading, session: session)
            return session

        case .paused:
            let session: ReadingSession
            if let active = activeReadingSession {
                session = active
                session.status = .paused
            } else {
                session = makeReadingSession(startedAt: date, status: .paused)
            }
            session.endedAt = nil
            applySummary(status: .paused, session: session)
            return session

        case .finished:
            let legacyFinishedAt = dateFinished
            if readingStatus == .finished,
               let latest = readingSessionsChronological.last,
               latest.status == .finished {
                applySummary(status: .finished, session: latest)
                return latest
            }
            let session: ReadingSession
            if let active = activeReadingSession {
                session = active
            } else if readingStatus == .didNotFinish,
                      let latest = readingSessionsChronological.last,
                      latest.status == .didNotFinish {
                session = latest
            } else {
                session = makeReadingSession(
                    startedAt: dateStarted ?? legacyFinishedAt ?? date,
                    status: .reading
                )
            }
            session.status = .finished
            session.endedAt = session.endedAt ?? legacyFinishedAt ?? date
            session.setProgress(1)
            applySummary(status: .finished, session: session)
            return session

        case .didNotFinish:
            if readingStatus == .didNotFinish,
               let latest = readingSessionsChronological.last,
               latest.status == .didNotFinish {
                applySummary(status: .didNotFinish, session: latest)
                return latest
            }
            let session: ReadingSession
            if let active = activeReadingSession {
                session = active
            } else if readingStatus == .finished,
                      let latest = readingSessionsChronological.last,
                      latest.status == .finished {
                session = latest
            } else {
                session = makeReadingSession(startedAt: dateStarted ?? date, status: .reading)
            }
            session.status = .didNotFinish
            session.endedAt = session.endedAt ?? date
            applySummary(status: .didNotFinish, session: session)
            return session
        }
        return nil
    }

    @discardableResult
    func updateReadingProgress(_ value: Double) -> Bool {
        guard let session = activeReadingSession else { return false }
        session.setProgress(value)
        applySummary(status: session.status.readingStatus, session: session)
        return true
    }

    @discardableResult
    func refreshReadingSummaryFromHistory() -> Bool {
        if let active = activeReadingSession {
            applySummary(status: active.status.readingStatus, session: active)
            return true
        }
        guard let latest = readingSessionsChronological.last else { return false }
        applySummary(status: latest.status.readingStatus, session: latest)
        return true
    }

    private func makeReadingSession(
        startedAt: Date,
        status: ReadingSessionStatus
    ) -> ReadingSession {
        let session = ReadingSession(startedAt: startedAt, status: status, book: self)
        if !readingSessions.contains(where: { $0.uuid == session.uuid }) {
            readingSessions.append(session)
        }
        return session
    }

    private func closeActiveSessions(as status: ReadingSessionStatus, at date: Date) {
        for session in readingSessions where session.endedAt == nil && session.status.isActive {
            session.status = status
            session.endedAt = date
        }
    }

    private func applySummary(status: ReadingStatus, session: ReadingSession) {
        readingStatus = status
        dateStarted = session.startedAt
        dateFinished = status == .finished ? session.endedAt : nil
    }

    // MARK: - Metadata

    // Fills only empty fields so a re-scan never clobbers user edits.
    func apply(_ metadata: BookMetadata) {
        func fill(_ current: String?, _ new: String?) -> String? {
            if let current, !current.isEmpty { return current }
            guard let new = new?.trimmingCharacters(in: .whitespacesAndNewlines), !new.isEmpty else { return current }
            return new
        }
        title = fill(title, metadata.title)
        author = fill(author, metadata.author)
        publisher = fill(publisher, metadata.publisher)
        year = fill(year, metadata.year)
        language = fill(language, metadata.language)
        translator = fill(translator, metadata.translator)
        isbn = fill(isbn, metadata.isbn)
        series = fill(series, metadata.series)
        seriesIndex = fill(seriesIndex, metadata.seriesIndex)
        if tags.isEmpty, !metadata.tags.isEmpty { tags = metadata.tags }
        bookDescription = fill(bookDescription, metadata.description)
        if pageCount == nil, let pages = metadata.pageCount, pages > 0 { pageCount = pages }
    }

    static let sampleMaxPages = 30

    var probablySample: Bool {
        guard sampleNoticeDismissed != true, let pageCount else { return false }
        return pageCount <= Self.sampleMaxPages
    }

    func applyOnline(_ fetched: FetchedMetadata) {
        func fill(_ current: String?, _ new: String?) -> String? {
            if let current, !current.isEmpty { return current }
            guard let new = new?.trimmingCharacters(in: .whitespacesAndNewlines), !new.isEmpty else { return current }
            return new
        }
        title = fill(title, fetched.title)
        if author == nil || author?.isEmpty == true, !fetched.authors.isEmpty {
            author = fetched.authors.joined(separator: ", ")
        }
        publisher = fill(publisher, fetched.publisher)
        year = fill(year, fetched.year)
        bookDescription = fill(bookDescription, fetched.bookDescription)
        if tags.isEmpty, !fetched.subjects.isEmpty { tags = fetched.subjects }
        if let avg = fetched.ratingsAverage {
            communityRating = avg
            communityRatingCount = fetched.ratingsCount
            communityRatingSource = fetched.ratingsSource
        }
    }

    nonisolated private static let cleaningPatterns: [NSRegularExpression] = {
        let patterns = [
            "anna's archive|annas archive|amazonencore|z library|libgen|z lib",
            "\\b[0-9a-fA-F]{16,}\\b",
            "\\b(19|20)\\d{2}\\b",
            "\\s{2,}",
        ]
        return patterns.map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }()

    // Memoized — this runs per render for filename-titled rows.
    nonisolated(unsafe) private static let cleanedNames: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 4096
        return cache
    }()

    nonisolated static func cleanFilename(_ name: String) -> String {
        if let cached = cleanedNames.object(forKey: name as NSString) {
            return cached as String
        }
        var result = name
        result = result.replacingOccurrences(of: "_", with: " ")
        result = result.replacingOccurrences(of: "-", with: " ")
        for regex in cleaningPatterns {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: " "
            )
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if !result.isEmpty && (result == result.lowercased() || result == result.uppercased()) {
            result = result.capitalized
        }
        let cleaned = result.isEmpty ? "Unknown" : result
        cleanedNames.setObject(cleaned as NSString, forKey: name as NSString)
        return cleaned
    }
}
