import Foundation
import SwiftData
import AppKit

@MainActor
@Observable
final class ExportService {
    private let modelContext: ModelContext

    private(set) var isExporting = false

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func exportLibrary(to folder: URL) {
        guard !isExporting else { return }
        let rows = Self.rows(for: modelContext.allBooks())
        guard !rows.isEmpty else { return }
        isExporting = true
        Task {
            _ = await Task.detached(priority: .utility) { LibraryExporter.export(rows, to: folder) }.value
            isExporting = false
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }

    static func rows(for books: [Book]) -> [ExportRow] {
        books.flatMap { book -> [ExportRow] in
            guard !book.assets.isEmpty else {
                return [row(
                    for: book,
                    fileName: book.fileName,
                    format: book.format,
                    sourceURL: book.fileURL
                )]
            }
            return book.assets.map { asset in
                row(
                    for: book,
                    fileName: asset.fileName,
                    format: asset.format,
                    sourceURL: asset.fileURL
                )
            }
        }
    }

    private static func row(
        for book: Book,
        fileName: String,
        format: String,
        sourceURL: URL
    ) -> ExportRow {
        ExportRow(
            title: book.displayTitle,
            author: book.displayAuthor ?? "",
            translator: book.translator ?? "",
            series: book.series ?? "",
            seriesIndex: book.seriesIndex ?? "",
            year: book.year ?? "",
            publisher: book.publisher ?? "",
            format: format,
            tags: book.tags.joined(separator: "; "),
            rating: book.rating ?? 0,
            status: book.readingStatus.label,
            sourcePath: sourceURL.path(percentEncoded: false),
            readableName: Self.readableFileName(for: book, fileName: fileName),
            workUUID: book.work?.uuid.uuidString ?? "",
            workTitle: book.work?.displayTitle ?? "",
            editionUUID: book.uuid.uuidString,
            editionStatement: book.editionStatement ?? ""
        )
    }

    private static func readableFileName(for book: Book, fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension
        let author = book.displayAuthor.map { "\(FileNaming.sanitized($0)) - " } ?? ""
        let stem = "\(author)\(FileNaming.sanitized(book.displayTitle))"
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }
}
