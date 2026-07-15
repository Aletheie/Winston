import Foundation
import PDFKit
import AppKit

nonisolated enum PDFReader {
    enum ReadError: Error, LocalizedError {
        case unreadable
        case noText
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .unreadable: "Couldn’t open the PDF"
            case .noText:     "The PDF has no extractable text (it may be scanned images)"
            case .tooLarge:   "The PDF is too large to convert safely"
            }
        }
    }

    private static let maxDocumentBytes = 512 * 1_024 * 1_024
    private static let maxPageCount = 20_000
    private static let maxExtractedTextBytes = 32 * 1_024 * 1_024

    static func read(_ url: URL) throws -> SourceDocument {
        guard isWithinSizeLimit(url) else { throw ReadError.tooLarge }
        guard let pdf = PDFDocument(url: url) else { throw ReadError.unreadable }
        guard pdf.pageCount <= maxPageCount else { throw ReadError.tooLarge }

        var sections: [String] = []
        var extractedTextBytes = 0
        for index in 0 ..< pdf.pageCount {
            guard let page = pdf.page(at: index), let text = page.string else { continue }
            let pageBytes = text.utf8.count
            guard pageBytes <= maxExtractedTextBytes - extractedTextBytes else {
                throw ReadError.tooLarge
            }
            extractedTextBytes += pageBytes
            let html = paragraphsHTML(from: text)
            if !html.isEmpty { sections.append(html) }
        }
        guard !sections.isEmpty else { throw ReadError.noText }

        let meta = MetadataExtractor.extractMetadata(from: url)
        let cover = CoverExtractor.extractCover(from: url).flatMap { ImageTranscoder.jpegData(from: $0) }
        let title = meta.title?.nonEmpty ?? url.deletingPathExtension().lastPathComponent
        return SourceDocument(
            title: title, metadata: meta, sections: sections, images: [], coverImage: cover
        )
    }

    static func isWithinSizeLimit(_ url: URL) -> Bool {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return true }
        return size <= maxDocumentBytes
    }

    // MARK: - Helpers

    private static func paragraphsHTML(from pageText: String) -> String {
        let normalized = pageText.replacingOccurrences(of: "\r\n", with: "\n")
                                 .replacingOccurrences(of: "\r", with: "\n")
        return normalized.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "<p>\($0.htmlEscaped.replacingOccurrences(of: "\n", with: " "))</p>" }
            .joined()
    }
}
