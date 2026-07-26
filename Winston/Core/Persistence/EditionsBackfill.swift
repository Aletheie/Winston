import Foundation
import SwiftData

enum EditionsBackfill {
    @discardableResult
    static func run(
        context: ModelContext,
        mutations: CatalogMutationService? = nil,
        batchSize: Int = 100
    ) -> Int {
        let writer = mutations ?? CatalogMutationService(modelContext: context)
        var descriptor = FetchDescriptor<Book>()
        descriptor.relationshipKeyPathsForPrefetching = [\.assets, \.work]
        let books = (try? context.fetch(descriptor)) ?? []
        var committed = 0
        var staged = 0
        var changedBookIDs: Set<UUID> = []
        var changedWorkIDs: Set<UUID> = []
        var changedAssetIDs: Set<UUID> = []

        for (index, book) in books.enumerated() {
            if book.assets.isEmpty, book.hasDigitalFile {
                let size = book.fileSizeBytes > 0
                    ? book.fileSizeBytes
                    : BookFileStore.size(of: book.fileName)
                if book.fileSizeBytes == 0, size > 0 { book.fileSizeBytes = size }
                let asset = BookAsset(
                    uuid: book.uuid,
                    fileName: book.fileName,
                    origin: .original,
                    sizeBytes: size,
                    dateAdded: book.dateAdded,
                    book: book
                )
                context.insert(asset)
                book.primaryAssetUUID = asset.uuid
                staged += 1
                changedBookIDs.insert(book.uuid)
                changedAssetIDs.insert(asset.uuid)
            }

            if book.work == nil {
                let work = Work(title: book.displayTitle, author: book.author, dateCreated: book.dateAdded)
                context.insert(work)
                book.work = work
                work.preferredEditionUUID = book.uuid
                staged += 1
                changedBookIDs.insert(book.uuid)
                changedWorkIDs.insert(work.uuid)
            }

            if staged > 0, (index + 1).isMultiple(of: max(1, batchSize)) {
                guard commitStaged(
                    writer: writer,
                    staged: staged,
                    bookIDs: changedBookIDs,
                    workIDs: changedWorkIDs,
                    assetIDs: changedAssetIDs
                ) else { return committed }
                committed += staged
                staged = 0
                changedBookIDs.removeAll(keepingCapacity: true)
                changedWorkIDs.removeAll(keepingCapacity: true)
                changedAssetIDs.removeAll(keepingCapacity: true)
            }
        }

        if staged > 0 {
            guard commitStaged(
                writer: writer,
                staged: staged,
                bookIDs: changedBookIDs,
                workIDs: changedWorkIDs,
                assetIDs: changedAssetIDs
            ) else { return committed }
            committed += staged
        }
        return committed
    }

    @discardableResult
    static func pruneOrphanWorks(
        context: ModelContext,
        mutations: CatalogMutationService? = nil
    ) -> Int {
        var descriptor = FetchDescriptor<Work>()
        descriptor.relationshipKeyPathsForPrefetching = [\.editions]
        let works = (try? context.fetch(descriptor)) ?? []
        let orphaned = works.filter(\.editions.isEmpty)
        for work in orphaned { context.delete(work) }
        if !orphaned.isEmpty {
            let workIDs = Set(orphaned.map(\.uuid))
            let writer = mutations ?? CatalogMutationService(modelContext: context)
            do {
                try writer.commitStaged(
                    .maintenanceCleanup(workIDs: Array(workIDs)),
                    affectedWorkIDs: workIDs
                )
            } catch {
                return 0
            }
        }
        return orphaned.count
    }

    private static func commitStaged(
        writer: CatalogMutationService,
        staged: Int,
        bookIDs: Set<UUID>,
        workIDs: Set<UUID>,
        assetIDs: Set<UUID>
    ) -> Bool {
        guard staged > 0 else { return true }
        do {
            try writer.commitStaged(
                .legacyMigration(bookIDs: Array(bookIDs)),
                affectedBookIDs: bookIDs,
                affectedWorkIDs: workIDs,
                affectedAssetIDs: assetIDs
            )
            return true
        } catch {
            return false
        }
    }
}
