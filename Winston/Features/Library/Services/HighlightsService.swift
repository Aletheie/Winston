import Foundation
import OSLog
import SwiftData

@MainActor
@Observable
final class HighlightsService {
    nonisolated struct Signature: Hashable, Sendable {
        let text: String
        let location: String?
    }

    nonisolated struct BookSnapshot: Sendable {
        let uuid: UUID
        let title: String
        let existing: Set<Signature>
    }

    nonisolated struct Match: Sendable, Equatable {
        let bookUUID: UUID
        let text: String
        let isNote: Bool
        let location: String?
        let addedDate: Date?
    }

    private let modelContext: ModelContext
    private let mutations: CatalogMutationService

    private(set) var isImportingHighlights = false
    private(set) var highlightImportSummary: String?

    init(
        modelContext: ModelContext,
        mutations: CatalogMutationService? = nil
    ) {
        self.modelContext = modelContext
        self.mutations = mutations ?? CatalogMutationService(modelContext: modelContext)
    }

    func importHighlights(via monitor: DeviceMonitor) async {
        guard let connection = monitor.connection, !isImportingHighlights else { return }
        isImportingHighlights = true
        highlightImportSummary = nil
        defer { isImportingHighlights = false }
        let text: String?
        do {
            text = try await connection.readClippingsText()
        } catch {
            highlightImportSummary = String(
                localized: "Couldn’t read clippings from the device."
            )
            return
        }
        guard let text, !text.isEmpty else {
            highlightImportSummary = String(localized: "No clippings file found on the device.")
            return
        }
        let clippings = await Task.detached(priority: .userInitiated) {
            KindleClippings.parse(text)
        }.value
        let libraryBooks: [Book]
        do {
            libraryBooks = try modelContext.fetchAllBooksForGlobalAnalysis()
        } catch {
            Log.persistence.error(
                "Highlight import catalog fetch failed: \(error.localizedDescription, privacy: .public)"
            )
            highlightImportSummary = String(
                localized: "Couldn’t read the library for highlight matching."
            )
            return
        }
        let snapshots = libraryBooks.map { book in
            BookSnapshot(
                uuid: book.uuid,
                title: book.displayTitle,
                existing: Set(book.highlights.map {
                    Signature(text: $0.text, location: $0.location)
                })
            )
        }
        let matches = await Self.match(clippings: clippings, books: snapshots)
        let insertions = matches.map {
            CatalogHighlightInsertion(
                bookID: $0.bookUUID,
                text: $0.text,
                isNote: $0.isNote,
                location: $0.location,
                addedDate: $0.addedDate
            )
        }
        if insertions.isEmpty {
            highlightImportSummary = String(localized: "No new highlights found.")
            return
        } else if case .success = mutations.execute(.importHighlights(insertions)) {
            highlightImportSummary = String(
                localized: "Imported \(insertions.count) highlight(s)."
            )
        } else {
            highlightImportSummary = String(
                localized: "Couldn’t save imported highlights."
            )
        }
    }

    @concurrent
    static func match(clippings: [KindleClippings.Clipping], books: [BookSnapshot]) async -> [Match] {
        struct KeyedBook {
            let uuid: UUID
            let key: String
        }

        let keyedBooks = books.compactMap { book -> KeyedBook? in
            let key = book.title.normalizedMatchKey
            return key.isEmpty ? nil : KeyedBook(uuid: book.uuid, key: key)
        }
        var exact: [String: UUID] = [:]
        for book in keyedBooks where exact[book.key] == nil { exact[book.key] = book.uuid }
        var seen = Dictionary(uniqueKeysWithValues: books.map { ($0.uuid, $0.existing) })
        var matches: [Match] = []

        for clipping in clippings where !clipping.isBookmark && !clipping.text.isEmpty {
            let key = clipping.title.normalizedMatchKey
            guard !key.isEmpty else { continue }
            let bookUUID = exact[key] ?? keyedBooks.first(where: {
                $0.key.contains(key) || key.contains($0.key)
            })?.uuid
            guard let bookUUID else { continue }

            let signature = Signature(text: clipping.text, location: clipping.location)
            guard seen[bookUUID, default: []].insert(signature).inserted else { continue }
            matches.append(Match(
                bookUUID: bookUUID,
                text: clipping.text,
                isNote: clipping.isNote,
                location: clipping.location,
                addedDate: clipping.addedDate
            ))
        }
        return matches
    }
}
