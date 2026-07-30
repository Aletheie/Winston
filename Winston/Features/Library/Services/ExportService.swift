import Foundation
import SwiftData
import AppKit
import OSLog

@MainActor
@Observable
final class ExportService {
    typealias RevealHandler = @MainActor (URL) -> Void

    private let modelContext: ModelContext
    private let toasts: ToastCenter?
    @ObservationIgnored private let revealExport: RevealHandler

    private(set) var isExporting = false
    private(set) var lastError: String?
    private(set) var lastResult: LibraryExporter.Result?

    init(
        modelContext: ModelContext,
        toasts: ToastCenter? = nil,
        revealExport: @escaping RevealHandler = {
            NSWorkspace.shared.activateFileViewerSelecting([$0])
        }
    ) {
        self.modelContext = modelContext
        self.toasts = toasts
        self.revealExport = revealExport
    }

    func exportLibrary(to parentFolder: URL) {
        guard !isExporting else { return }
        isExporting = true
        lastError = nil
        lastResult = nil
        Task {
            defer { isExporting = false }
            let books: [Book]
            do {
                books = try modelContext.fetchAllBooksForGlobalAnalysis()
            } catch {
                lastError = error.localizedDescription
                Log.persistence.error(
                    "Library export catalog fetch failed: \(error.localizedDescription, privacy: .public)"
                )
                toasts?.error(String(localized: "Couldn’t read the library for export."))
                return
            }
            let rows = await Self.rowsYielding(for: books)
            let result = await Task.detached(priority: .utility) {
                LibraryExporter.export(rows, to: parentFolder)
            }.value
            lastResult = result
            guard let finalURL = result.finalURL else {
                let details = Self.failureDetails(result.failures)
                lastError = details
                toasts?.error(String(
                    localized: "The library export couldn’t be completed. \(details)"
                ))
                return
            }

            if result.failures.isEmpty {
                toasts?.success(String(
                    localized: "Exported \(result.copied) files and \(result.skipped) metadata-only entries."
                ))
            } else {
                let details = Self.failureDetails(result.failures)
                lastError = details
                toasts?.error(String(
                    localized: "Exported \(result.copied) files; \(result.failed) items failed. \(details)"
                ))
            }
            revealExport(finalURL)
        }
    }

    private static func failureDetails(
        _ failures: [LibraryExporter.Failure]
    ) -> String {
        let names = failures.compactMap(\.itemName)
        if !names.isEmpty {
            return Array(names.prefix(3)).formatted()
        }
        return failures.first?.detail
            ?? String(localized: "No additional error details are available.")
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
