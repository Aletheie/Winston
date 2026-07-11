import Foundation
import SwiftData

@MainActor
@Observable
final class ConversionService {
    private struct Request {
        let book: Book
        let uuid: UUID
        let sourceURL: URL
        let oldFileName: String
        let title: String
        let format: EbookConverter.OutputFormat
    }

    private let modelContext: ModelContext
    private let toasts: ToastCenter

    private(set) var convertingUUIDs: Set<UUID> = []

    init(modelContext: ModelContext, toasts: ToastCenter) {
        self.modelContext = modelContext
        self.toasts = toasts
    }

    func isConverting(_ book: Book) -> Bool { convertingUUIDs.contains(book.uuid) }

    func convert(_ book: Book) {
        guard EbookConverter.needsConversion(format: book.format) else { return }
        convert(book, to: EbookConverter.kindleTarget(forFormat: book.format))
    }

    func convert(_ book: Book, to format: EbookConverter.OutputFormat) {
        guard book.format.lowercased() != format.ext, !convertingUUIDs.contains(book.uuid) else { return }
        if book.drmProtected == true {
            toasts.error(String(localized: "\u{201C}\(book.displayTitle)\u{201D} is DRM\u{2011}protected and can't be converted."))
            return
        }
        guard EbookConverter.canConvert(from: book.format, to: format) else {
            toasts.error(String(localized: "Install calibre to convert books"))
            return
        }
        let request = makeRequest(for: book, to: format)
        convertingUUIDs.insert(request.uuid)
        Task { await performConvert(request) }
    }

    func convertBooks(_ books: [Book]) {
        let candidates = books.filter {
            EbookConverter.needsConversion(format: $0.format) && !convertingUUIDs.contains($0.uuid)
        }
        let drmCount = candidates.filter { $0.drmProtected == true }.count
        if drmCount > 0 {
            toasts.error(String(localized: "Some DRM\u{2011}protected books were skipped (\(drmCount))."))
        }
        let targets = candidates.filter {
            $0.drmProtected != true && EbookConverter.canConvertForKindle($0.format)
        }
        guard !targets.isEmpty else {
            if candidates.contains(where: { $0.drmProtected != true }) {
                toasts.error(String(localized: "Install calibre to convert books"))
            }
            return
        }
        let requests = targets.map {
            makeRequest(for: $0, to: EbookConverter.kindleTarget(forFormat: $0.format))
        }
        for request in requests { convertingUUIDs.insert(request.uuid) }
        Task {
            for request in requests { await performConvert(request) }
        }
    }

    func convertBooks(_ books: [Book], to format: EbookConverter.OutputFormat) {
        let convertible = books.filter { $0.format.lowercased() != format.ext && !convertingUUIDs.contains($0.uuid) }
        let drmCount = convertible.filter { $0.drmProtected == true }.count
        if drmCount > 0 {
            toasts.error(String(localized: "Some DRM\u{2011}protected books were skipped (\(drmCount))."))
        }
        let targets = convertible.filter { $0.drmProtected != true }
        guard !targets.isEmpty else { return }
        let needsCalibre = targets.contains { !EbookConverter.canConvertNatively(from: $0.format, to: format) }
        if needsCalibre, !EbookConverter.isCalibreAvailable {
            toasts.error(String(localized: "Install calibre to convert books"))
            return
        }
        let requests = targets.map { makeRequest(for: $0, to: format) }
        for request in requests { convertingUUIDs.insert(request.uuid) }
        Task {
            for request in requests { await performConvert(request) }
        }
    }

    private func makeRequest(for book: Book, to format: EbookConverter.OutputFormat) -> Request {
        Request(
            book: book,
            uuid: book.uuid,
            sourceURL: book.fileURL,
            oldFileName: book.fileName,
            title: book.displayTitle,
            format: format
        )
    }

    private func performConvert(_ request: Request) async {
        let book = request.book
        let uuid = request.uuid
        let sourceURL = request.sourceURL
        defer { convertingUUIDs.remove(uuid) }
        guard book.modelContext != nil else { return }

        await Task.detached(priority: .utility) {
            if !CoverStore.exists(for: uuid),
               let cover = CoverExtractor.extractCover(from: sourceURL) {
                CoverStore.save(cover, for: uuid)
            }
        }.value

        guard book.modelContext != nil else {
            CoverStore.delete(for: uuid)
            return
        }

        let converted: URL? = try? await EbookConverter.convert(sourceURL, to: request.format)
        guard book.modelContext != nil else {
            if let converted { try? FileManager.default.removeItem(at: converted) }
            CoverStore.delete(for: uuid)
            return
        }
        guard let converted else {
            toasts.error(String(localized: "Couldn\u{2019}t convert \u{201C}\(request.title)\u{201D}."))
            return
        }
        defer { try? FileManager.default.removeItem(at: converted) }

        guard let newFileName = try? BookFileStore.importCopy(of: converted, uuid: uuid) else {
            toasts.error(String(localized: "Couldn\u{2019}t convert \u{201C}\(request.title)\u{201D}."))
            return
        }
        if newFileName != request.oldFileName {
            BookFileStore.delete(fileName: request.oldFileName)
        }
        book.fileName = newFileName
        book.fileSizeBytes = BookFileStore.size(of: newFileName)
        modelContext.saveQuietly()
    }
}
