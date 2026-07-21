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
        isExporting = true
        Task {
            let rows = await Self.rowsYielding(for: modelContext.allBooks())
            guard !rows.isEmpty else {
                isExporting = false
                return
            }
            _ = await Task.detached(priority: .utility) { LibraryExporter.export(rows, to: folder) }.value
            isExporting = false
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }

    static func rows(for books: [Book]) -> [ExportRow] {
        books.flatMap { book -> [ExportRow] in
            rows(for: book)
        }
    }

    private static func rowsYielding(for books: [Book]) async -> [ExportRow] {
        var result: [ExportRow] = []
        result.reserveCapacity(books.count)
        for (index, book) in books.enumerated() {
            result.append(contentsOf: rows(for: book))
            if (index + 1).isMultiple(of: 128) { await Task.yield() }
        }
        return result
    }

    private static func rows(for book: Book) -> [ExportRow] {
        guard !book.assets.isEmpty else {
            return [row(
                for: book,
                fileName: book.fileName,
                format: book.format,
                sourceURL: book.primaryFileURL
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

    private static func row(
        for book: Book,
        fileName: String,
        format: String,
        sourceURL: URL?
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
            sourcePath: sourceURL?.path(percentEncoded: false) ?? "",
            readableName: sourceURL == nil ? "" : Self.readableFileName(for: book, fileName: fileName),
            workUUID: book.work?.uuid.uuidString ?? "",
            workTitle: book.work?.displayTitle ?? "",
            editionUUID: book.uuid.uuidString,
            editionStatement: book.editionStatement ?? "",
            isPhysicalCopy: book.hasPhysicalCopy,
            shelfLocation: book.shelfLocation ?? ""
        )
    }

    private static func readableFileName(for book: Book, fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension
        let author = book.displayAuthor.map { "\(FileNaming.sanitized($0)) - " } ?? ""
        let stem = "\(author)\(FileNaming.sanitized(book.displayTitle))"
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }
}
