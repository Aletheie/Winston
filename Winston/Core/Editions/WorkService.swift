import Foundation
import SwiftData

nonisolated enum CatalogWorkInvariantViolation: Equatable, Sendable {
    case staleMatchKey(expected: String?)
    case danglingPreferredEdition(UUID)
    case editionPointsToAnotherWork(UUID)
}

@MainActor
enum WorkService {
    static func preferredEdition(in work: Work) -> Book? {
        if let uuid = work.preferredEditionUUID,
           let preferred = work.editions.first(where: { $0.uuid == uuid }) {
            return preferred
        }
        return work.editions.sorted(by: editionPrecedes).first
    }

    @discardableResult
    static func repairPreferredEditionInvariant(_ work: Work) -> Bool {
        if let preferredEditionUUID = work.preferredEditionUUID,
           work.editions.contains(where: { $0.uuid == preferredEditionUUID }) {
            return false
        }
        let repaired = work.editions.sorted(by: editionPrecedes).first?.uuid
        guard work.preferredEditionUUID != repaired else { return false }
        work.preferredEditionUUID = repaired
        return true
    }

    static func violations(in work: Work) -> [CatalogWorkInvariantViolation] {
        var result: [CatalogWorkInvariantViolation] = []
        if work.matchKey != work.expectedMatchKey {
            result.append(.staleMatchKey(expected: work.expectedMatchKey))
        }
        if let preferredEditionUUID = work.preferredEditionUUID,
           !work.editions.contains(where: { $0.uuid == preferredEditionUUID }) {
            result.append(.danglingPreferredEdition(preferredEditionUUID))
        }
        result.append(contentsOf: work.editions.compactMap { edition in
            edition.work?.uuid == work.uuid
                ? nil
                : .editionPointsToAnotherWork(edition.uuid)
        })
        return result
    }

    /// Repairs only derived/inverse Work state. `Book.work` remains the
    /// authority for membership, so this never reparents an edition.
    @discardableResult
    static func repairCatalogInvariant(_ work: Work) -> Bool {
        var changed = false
        let invalidEditionIDs = Set(work.editions.compactMap { edition in
            edition.work?.uuid == work.uuid ? nil : edition.uuid
        })
        if !invalidEditionIDs.isEmpty {
            work.editions.removeAll { invalidEditionIDs.contains($0.uuid) }
            changed = true
        }
        if work.matchKey != work.expectedMatchKey {
            work.matchKey = work.expectedMatchKey
            changed = true
        }
        return repairPreferredEditionInvariant(work) || changed
    }

    static func pruneIfOrphaned(_ work: Work?, context: ModelContext) {
        guard let work, work.modelContext != nil, work.editions.isEmpty else { return }
        context.delete(work)
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
            .filter(\.isUsable)
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
