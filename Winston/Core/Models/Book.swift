import Foundation
import SwiftData

nonisolated struct BookMetadata: Codable, Sendable, Hashable {
    var title: String?
    var author: String?
    var publisher: String?
    var year: String?
    var language: String?
    var isbn: String?
    var series: String?
    var seriesIndex: String?
    var tags: [String] = []
    var description: String?
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
    var dateFinished: Date?
    var dateStarted: Date?
    var drmProtected: Bool?
    var fileSizeBytes: Int64 = 0
    var coverVersion: Int = 0

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

    var format: String {
        (fileName as NSString).pathExtension.uppercased()
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

    var deviceMatchKey: String {
        (originalFileName as NSString).deletingPathExtension.lowercased()
    }

    var fileSizeDisplay: String {
        guard fileSizeBytes > 0 else { return "\u{2014}" }
        return ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }

    var readingStatus: ReadingStatus {
        get { readingStatusRaw.flatMap(ReadingStatus.init(rawValue:)) ?? .unread }
        set { readingStatusRaw = newValue.rawValue }
    }

    func setStatus(_ status: ReadingStatus) {
        readingStatus = status
        switch status {
        case .unread:
            dateStarted = nil
            dateFinished = nil
        case .reading:
            if dateStarted == nil { dateStarted = Date() }
            dateFinished = nil
        case .finished:
            if dateFinished == nil { dateFinished = Date() }
        }
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
        isbn = fill(isbn, metadata.isbn)
        series = fill(series, metadata.series)
        seriesIndex = fill(seriesIndex, metadata.seriesIndex)
        if tags.isEmpty, !metadata.tags.isEmpty { tags = metadata.tags }
        bookDescription = fill(bookDescription, metadata.description)
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
