import Foundation
import PDFKit
import AppKit

nonisolated enum PDFReader {
    enum ReadError: Error, LocalizedError {
        case unreadable
        case noText

        var errorDescription: String? {
            switch self {
            case .unreadable: "Couldn’t open the PDF"
            case .noText:     "The PDF has no extractable text (it may be scanned images)"
            }
        }
    }

    static func read(_ url: URL) throws -> SourceDocument {
        guard let pdf = PDFDocument(url: url) else { throw ReadError.unreadable }

        var sections: [String] = []
        for index in 0 ..< pdf.pageCount {
            guard let page = pdf.page(at: index), let text = page.string else { continue }
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
