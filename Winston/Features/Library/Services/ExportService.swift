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
        let rows = modelContext.allBooks().map { book -> ExportRow in
            ExportRow(
                title: book.displayTitle,
                author: book.displayAuthor ?? "",
                series: book.series ?? "",
                seriesIndex: book.seriesIndex ?? "",
                year: book.year ?? "",
                publisher: book.publisher ?? "",
                format: book.format,
                tags: book.tags.joined(separator: "; "),
                rating: book.rating ?? 0,
                status: book.readingStatus.label,
                sourcePath: book.fileURL.path(percentEncoded: false),
                readableName: Self.readableFileName(for: book)
            )
        }
        guard !rows.isEmpty else { return }
        isExporting = true
        Task {
            _ = await Task.detached(priority: .utility) { LibraryExporter.export(rows, to: folder) }.value
            isExporting = false
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }

    private static func readableFileName(for book: Book) -> String {
        let ext = (book.fileName as NSString).pathExtension
        let author = book.displayAuthor.map { "\(FileNaming.sanitized($0)) - " } ?? ""
        let stem = "\(author)\(FileNaming.sanitized(book.displayTitle))"
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }
}
