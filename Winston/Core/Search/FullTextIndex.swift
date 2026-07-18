import Foundation
import OSLog
import PDFKit

nonisolated struct FullTextBookSnapshot: Sendable, Equatable, Identifiable {
    struct Source: Sendable, Equatable {
        let fileURL: URL
        let contentHash: String?

        var format: String { fileURL.pathExtension.lowercased() }
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

nonisolated enum FullTextSectionKind: String, Codable, Sendable, Equatable {
    case chapter
    case page
    case document
}

private nonisolated struct StoredFullTextIndex: Codable, Sendable {
    let schemaVersion: Int
    let contentHash: String
    let format: String
    let sourceFilePath: String?
    let sourceFileSize: Int?
    let sourceModificationDate: Date?
    let sections: [StoredFullTextSection]
}

private nonisolated struct FullTextSourceMetadata: Equatable, Sendable {
    let fileSize: Int?
    let modificationDate: Date?
}

private nonisolated struct StoredFullTextSection: Codable, Sendable {
    let id: String
    let title: String?
    let kind: FullTextSectionKind
    let ordinal: Int
    let text: String
}

private nonisolated struct LoadedFullTextBook: Sendable {
    let title: String
    let author: String?
    let index: StoredFullTextIndex
}

actor FullTextIndexService {
    nonisolated static let shared = FullTextIndexService()
    nonisolated static let supportedFormats: Set<String> = ["epub", "pdf", "txt", "html", "htm"]

    private static let schemaVersion = 1
    private static let maximumBookResults = 80
    private static let maximumExcerpts = 240
    private static let maximumExcerptsPerSection = 3

    private let indexDirectory: URL
    private var documents: [UUID: LoadedFullTextBook] = [:]
    private var orderedDocuments: [(UUID, LoadedFullTextBook)] = []

    init(indexDirectory: URL = AppPaths.fullTextIndexDirectory) {
        self.indexDirectory = indexDirectory
    }

    func synchronize(_ snapshots: [FullTextBookSnapshot]) throws -> FullTextIndexSummary {
        try Task.checkCancellation()
        try AppPaths.ensureDirectory(indexDirectory)
        removeIndexesMissingFromLibrary(Set(snapshots.map(\.bookID)))

        var loaded: [UUID: LoadedFullTextBook] = [:]
        var indexedBooks = 0
        var reusedBooks = 0
        var failedBooks = 0
        var unsupportedBooks = 0

        for snapshot in snapshots {
            try Task.checkCancellation()
            guard let source = snapshot.source,
                  Self.supportedFormats.contains(source.format) else {
                unsupportedBooks += 1
                removeIndex(for: snapshot.bookID)
                continue
            }

            do {
                let metadata = sourceMetadata(for: source.fileURL)
                let cached = loadIndex(for: snapshot.bookID)
                let stored: StoredFullTextIndex
                if let cached, canReuseWithoutHashing(cached, source: source, metadata: metadata) {
                    stored = cached
                    reusedBooks += 1
                } else {
                    let contentHash = try resolvedHash(for: source)
                    if let cached,
                       cached.schemaVersion == Self.schemaVersion,
                       cached.contentHash.caseInsensitiveCompare(contentHash) == .orderedSame,
                       cached.format == source.format {
                        stored = StoredFullTextIndex(
                            schemaVersion: cached.schemaVersion,
                            contentHash: cached.contentHash,
                            format: cached.format,
                            sourceFilePath: sourcePath(for: source.fileURL),
                            sourceFileSize: metadata.fileSize,
                            sourceModificationDate: metadata.modificationDate,
                            sections: cached.sections
                        )
                        try save(stored, for: snapshot.bookID)
                        reusedBooks += 1
                    } else {
                        let sections = try FullTextDocumentExtractor.extract(
                            source.fileURL,
                            format: source.format
                        )
                        stored = StoredFullTextIndex(
                            schemaVersion: Self.schemaVersion,
                            contentHash: contentHash,
                            format: source.format,
                            sourceFilePath: sourcePath(for: source.fileURL),
                            sourceFileSize: metadata.fileSize,
                            sourceModificationDate: metadata.modificationDate,
                            sections: sections
                        )
                        try save(stored, for: snapshot.bookID)
                        indexedBooks += 1
                    }
                }
                loaded[snapshot.bookID] = LoadedFullTextBook(
                    title: snapshot.title,
                    author: snapshot.author,
                    index: stored
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failedBooks += 1
                removeIndex(for: snapshot.bookID)
                Log.search.error(
                    "Indexing \(source.fileURL.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        try Task.checkCancellation()
        documents = loaded
        orderedDocuments = loaded.sorted {
            $0.value.title.localizedCaseInsensitiveCompare($1.value.title) == .orderedAscending
        }
        return FullTextIndexSummary(
            searchableBooks: loaded.count,
            indexedBooks: indexedBooks,
            reusedBooks: reusedBooks,
            failedBooks: failedBooks,
            unsupportedBooks: unsupportedBooks
        )
    }

    func search(_ rawQuery: String) -> [FullTextBookResult] {
        let query = Self.collapsedWhitespace(rawQuery)
        guard query.count >= 2 else { return [] }

        var results: [FullTextBookResult] = []
        var excerptCount = 0

        for (bookID, document) in orderedDocuments {
            guard excerptCount < Self.maximumExcerpts else { break }
            var chapters: [FullTextChapterResult] = []

            for section in document.index.sections {
                let remaining = Self.maximumExcerpts - excerptCount
                guard remaining > 0 else { break }
                let excerpts = Self.excerpts(
                    matching: query,
                    in: section,
                    limit: min(Self.maximumExcerptsPerSection, remaining)
                )
                guard !excerpts.isEmpty else { continue }
                excerptCount += excerpts.count
                chapters.append(FullTextChapterResult(
                    id: section.id,
                    title: section.title,
                    kind: section.kind,
                    ordinal: section.ordinal,
                    excerpts: excerpts
                ))
            }

            guard !chapters.isEmpty else { continue }
            results.append(FullTextBookResult(
                bookID: bookID,
                title: document.title,
                author: document.author,
                format: document.index.format.uppercased(),
                chapters: chapters
            ))
        }

        results.sort {
            if $0.matchCount != $1.matchCount { return $0.matchCount > $1.matchCount }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        return Array(results.prefix(Self.maximumBookResults))
    }

    private func resolvedHash(for source: FullTextBookSnapshot.Source) throws -> String {
        // Hash the managed file itself on refresh. The catalog hash is a useful hint,
        // but can be stale if someone edits the file outside Winston.
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

    private func sourceMetadata(for url: URL) -> FullTextSourceMetadata {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path(percentEncoded: false)
        )
        return FullTextSourceMetadata(
            fileSize: (attributes?[.size] as? NSNumber)?.intValue,
            modificationDate: attributes?[.modificationDate] as? Date
        )
    }

    private func sourcePath(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
    }

    private func canReuseWithoutHashing(
        _ cached: StoredFullTextIndex,
        source: FullTextBookSnapshot.Source,
        metadata: FullTextSourceMetadata
    ) -> Bool {
        guard cached.schemaVersion == Self.schemaVersion,
              cached.format == source.format,
              cached.sourceFilePath == sourcePath(for: source.fileURL),
              let cachedSize = cached.sourceFileSize,
              let currentSize = metadata.fileSize,
              cachedSize == currentSize,
              let cachedDate = cached.sourceModificationDate,
              let currentDate = metadata.modificationDate,
              cachedDate == currentDate else {
            return false
        }
        return true
    }

    private func indexURL(for bookID: UUID) -> URL {
        indexDirectory.appending(path: "\(bookID.uuidString.lowercased()).json")
    }

    private func loadIndex(for bookID: UUID) -> StoredFullTextIndex? {
        guard let data = try? Data(contentsOf: indexURL(for: bookID), options: .mappedIfSafe) else {
            return nil
        }
        return try? JSONDecoder().decode(StoredFullTextIndex.self, from: data)
    }

    private func save(_ index: StoredFullTextIndex, for bookID: UUID) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(index)
        try data.write(to: indexURL(for: bookID), options: .atomic)
    }

    private func removeIndex(for bookID: UUID) {
        try? FileManager.default.removeItem(at: indexURL(for: bookID))
        documents[bookID] = nil
    }

    private func removeIndexesMissingFromLibrary(_ libraryBookIDs: Set<UUID>) {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: indexDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for url in urls where url.pathExtension.lowercased() == "json" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  !libraryBookIDs.contains(id) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func excerpts(
        matching query: String,
        in section: StoredFullTextSection,
        limit: Int
    ) -> [FullTextExcerpt] {
        let text = section.text
        var searchRange = text.startIndex ..< text.endIndex
        var excerpts: [FullTextExcerpt] = []
        var lastSnippetUpperBound = text.startIndex
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

        while excerpts.count < limit,
              let match = text.range(of: query, options: options, range: searchRange) {
            let snippetLower = text.index(match.lowerBound, offsetBy: -90, limitedBy: text.startIndex)
                ?? text.startIndex
            let snippetUpper = text.index(match.upperBound, offsetBy: 120, limitedBy: text.endIndex)
                ?? text.endIndex

            if snippetLower >= lastSnippetUpperBound || excerpts.isEmpty {
                let core = String(text[snippetLower ..< snippetUpper])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let prefix = snippetLower == text.startIndex ? "" : "…"
                let suffix = snippetUpper == text.endIndex ? "" : "…"
                let offset = text.distance(from: text.startIndex, to: match.lowerBound)
                excerpts.append(FullTextExcerpt(
                    id: "\(section.id):\(offset)",
                    text: prefix + core + suffix
                ))
                lastSnippetUpperBound = snippetUpper
            }

            guard match.upperBound < text.endIndex else { break }
            searchRange = match.upperBound ..< text.endIndex
        }
        return excerpts
    }

    private static func collapsedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

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
