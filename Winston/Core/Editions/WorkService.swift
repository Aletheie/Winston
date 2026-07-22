import Foundation
import SwiftData

@MainActor
enum WorkService {
    static func preferredEdition(in work: Work) -> Book? {
        if let uuid = work.preferredEditionUUID,
           let preferred = work.editions.first(where: { $0.uuid == uuid }) {
            return preferred
        }
        return work.editions.sorted(by: editionPrecedes).first
    }

    static func setPreferred(_ book: Book, in work: Work, context: ModelContext) {
        guard book.work?.uuid == work.uuid else { return }
        work.preferredEditionUUID = book.uuid
        context.saveQuietly()
    }

    static func pruneIfOrphaned(_ work: Work?, context: ModelContext, save: Bool = true) {
        guard let work, work.modelContext != nil, work.editions.isEmpty else { return }
        context.delete(work)
        if save { context.saveQuietly() }
    }

    static func editionPrecedes(_ lhs: Book, _ rhs: Book) -> Bool {
        let lhsFormat = bestAvailableFormatScore(for: lhs)
        let rhsFormat = bestAvailableFormatScore(for: rhs)
        if lhsFormat != rhsFormat { return lhsFormat > rhsFormat }
        let lhsRichness = metadataRichness(lhs)
        let rhsRichness = metadataRichness(rhs)
        if lhsRichness != rhsRichness { return lhsRichness > rhsRichness }
        if lhs.dateAdded != rhs.dateAdded { return lhs.dateAdded < rhs.dateAdded }
        return lhs.uuid.uuidString < rhs.uuid.uuidString
    }

    private static func bestAvailableFormatScore(for book: Book) -> Int {
        if book.assets.isEmpty { return formatScore(book.format) }
        return book.assets
            .filter { $0.validationStatus != .missing && $0.validationStatus != .corrupt }
            .map { formatScore($0.format) }
            .max() ?? 0
    }

    private static func formatScore(_ format: String) -> Int {
        let preference = ["azw3", "mobi", "azw", "epub", "pdf", "txt"]
        guard let index = preference.firstIndex(of: format.lowercased()) else { return 0 }
        return preference.count - index
    }

    private static func metadataRichness(_ book: Book) -> Int {
        let values = [
            book.title, book.author, book.translator, book.language, book.publisher,
            book.year, book.isbn, book.series, book.editionStatement, book.bookDescription,
        ]
        return values.reduce(0) { $0 + ($1?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? 1 : 0) }
            + (book.tags.isEmpty ? 0 : 1)
            + (book.rating == nil ? 0 : 1)
    }
}
