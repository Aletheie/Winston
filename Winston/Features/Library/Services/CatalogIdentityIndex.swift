import Foundation
import OSLog
import SwiftData

/// Store-scoped, rebuildable value index for import identity and file hashes.
///
/// A complete scan is allowed only for the initial build or when the mutation
/// log explicitly reports that its bounded history was lost. Normal catalog
/// writes are synchronized from semantic change sets with targeted fetches.
@MainActor
final class CatalogIdentityIndex {
    private let modelContext: ModelContext
    private let mutationLog: LibraryMutationLog
    private var indexedRevision = -1
    private var index = ImportReconciler(records: [])

    private(set) var fullRebuildCount = 0
    private(set) var lastSynchronizationQueryCount = 0
    private(set) var lastSynchronizationFetchCount = 0

    init(
        modelContext: ModelContext,
        mutationLog: LibraryMutationLog = .shared
    ) {
        self.modelContext = modelContext
        self.mutationLog = mutationLog
    }

    func reconciler() throws -> ImportReconciler {
        try synchronize()
        return index
    }

    private func synchronize() throws {
        lastSynchronizationQueryCount = 0
        lastSynchronizationFetchCount = 0
        guard indexedRevision >= 0 else {
            try rebuild()
            return
        }

        let delta = mutationLog.catalogDelta(since: indexedRevision)
        guard delta.toRevision != indexedRevision else { return }
        guard !delta.requiresFullRebuild else {
            try rebuild()
            return
        }

        let relevantFields: CatalogChangeFields = [
            .identity,
            .assetAvailability,
            .fullTextSource,
            .workMembership,
        ]
        guard delta.changesBookMembership
                || !delta.fields.intersection(relevantFields).isEmpty else {
            indexedRevision = delta.toRevision
            return
        }

        var affectedBookIDs = delta.affectedBookIDs
        if !delta.affectedAssetIDs.isEmpty {
            let requestedAssetIDs = Array(delta.affectedAssetIDs)
            let assets = try modelContext.fetch(FetchDescriptor<BookAsset>(
                predicate: #Predicate {
                    requestedAssetIDs.contains($0.uuid)
                }
            ))
            lastSynchronizationQueryCount += 1
            lastSynchronizationFetchCount += assets.count
            affectedBookIDs.formUnion(assets.compactMap { $0.book?.uuid })
        }
        if !delta.affectedWorkIDs.isEmpty,
           delta.fields.contains(.workMembership) {
            let requestedWorkIDs = Array(delta.affectedWorkIDs)
            let works = try modelContext.fetch(FetchDescriptor<Work>(
                predicate: #Predicate {
                    requestedWorkIDs.contains($0.uuid)
                }
            ))
            lastSynchronizationQueryCount += 1
            lastSynchronizationFetchCount += works.count
            affectedBookIDs.formUnion(works.flatMap(\.editions).map(\.uuid))
        }

        let changedBooks: [Book]
        if affectedBookIDs.isEmpty {
            changedBooks = []
        } else {
            let requestedBookIDs = Array(affectedBookIDs)
            changedBooks = try modelContext.fetch(FetchDescriptor<Book>(
                predicate: #Predicate {
                    requestedBookIDs.contains($0.uuid)
                }
            ))
            lastSynchronizationQueryCount += 1
            lastSynchronizationFetchCount += changedBooks.count
        }
        index.synchronize(
            records: changedBooks.map(Self.record),
            removingBookIDs: affectedBookIDs
        )
        indexedRevision = delta.toRevision
        Log.persistence.debug(
            "Catalog identity index synchronized revision \(self.indexedRevision) with \(self.lastSynchronizationQueryCount) targeted queries and \(self.lastSynchronizationFetchCount) fetched models"
        )
    }

    private func rebuild() throws {
        let signposter = Log.librarySignposter
        let interval = signposter.beginInterval(
            "CatalogIdentityIndexRebuild",
            id: signposter.makeSignpostID()
        )
        LibraryPerformanceDiagnostics.beginSQLScope("catalog_identity_index_rebuild")
        defer {
            LibraryPerformanceDiagnostics.endSQLScope("catalog_identity_index_rebuild")
            signposter.endInterval("CatalogIdentityIndexRebuild", interval)
        }

        let books = try modelContext.fetchAllBooksForGlobalAnalysis()
        index = ImportReconciler(records: books.map(Self.record))
        indexedRevision = mutationLog.catalogRevision
        fullRebuildCount += 1
        lastSynchronizationQueryCount = 1
        lastSynchronizationFetchCount = books.count
    }

    private static func record(_ book: Book) -> ImportCatalogRecord {
        ImportCatalogRecord(
            bookID: book.uuid,
            workID: book.work?.uuid,
            fingerprint: ImportFingerprint(
                contentHashes: Set(book.assets.compactMap(\.contentHash)),
                formats: Set(book.assets.map(\.format) + [book.format])
            ),
            identity: ImportIdentityRecord(
                title: book.displayTitle,
                author: book.displayAuthor,
                isbn: book.isbn,
                language: book.language,
                publisher: book.publisher,
                year: book.year
            )
        )
    }
}

@MainActor
private final class CatalogIdentityIndexRegistryEntry {
    weak var container: ModelContainer?
    weak var index: CatalogIdentityIndex?

    init(container: ModelContainer, index: CatalogIdentityIndex) {
        self.container = container
        self.index = index
    }
}

@MainActor
enum CatalogIdentityIndexRegistry {
    private static var entries: [
        ObjectIdentifier: CatalogIdentityIndexRegistryEntry
    ] = [:]

    static func resolve(modelContext: ModelContext) -> CatalogIdentityIndex {
        let container = modelContext.container
        let key = ObjectIdentifier(container)
        if let entry = entries[key],
           entry.container === container,
           let index = entry.index {
            return index
        }
        entries = entries.filter {
            $0.value.container != nil && $0.value.index != nil
        }
        let index = CatalogIdentityIndex(modelContext: modelContext)
        entries[key] = CatalogIdentityIndexRegistryEntry(
            container: container,
            index: index
        )
        return index
    }
}
