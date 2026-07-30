import Foundation
import OSLog
import SwiftData

enum EditionsBackfill {
    private struct AssetSeed {
        let id: UUID
        let fileName: String
        let sizeBytes: Int64
        let drmProtected: Bool?
        let dateAdded: Date
    }

    private struct BookPlan {
        let bookID: UUID
        let existingWorkID: UUID?
        let newWorkID: UUID?
        let asset: AssetSeed?
        let affectedAssetIDs: Set<UUID>
        let requiresInvariantRepair: Bool
    }

    @discardableResult
    static func run(
        context: ModelContext,
        mutations: CatalogMutationService? = nil,
        batchSize: Int = 100
    ) throws -> Int {
        context.processPendingChanges()
        guard !context.hasChanges else {
            Log.persistence.error("Editions backfill refused a dirty catalog context")
            throw CatalogMutationError.invalidRequest
        }

        let writer = mutations ?? CatalogMutationService(modelContext: context)
        var descriptor = FetchDescriptor<Book>()
        descriptor.relationshipKeyPathsForPrefetching = [\.assets, \.work]
        let books = try context.fetch(descriptor)
        let plans = books.compactMap { book -> BookPlan? in
            let asset: AssetSeed?
            if book.assets.isEmpty, book.hasDigitalFile {
                let size = book.fileSizeBytes > 0
                    ? book.fileSizeBytes
                    : BookFileStore.size(of: book.fileName)
                asset = AssetSeed(
                    id: book.uuid,
                    fileName: book.fileName,
                    sizeBytes: size,
                    drmProtected: book.drmProtected,
                    dateAdded: book.dateAdded
                )
            } else {
                asset = nil
            }
            let newWorkID = book.work == nil ? UUID() : nil
            let requiresInvariantRepair =
                !CatalogModelInvariantService.violations(in: book).isEmpty
            guard asset != nil || newWorkID != nil || requiresInvariantRepair else {
                return nil
            }
            return BookPlan(
                bookID: book.uuid,
                existingWorkID: book.work?.uuid,
                newWorkID: newWorkID,
                asset: asset,
                affectedAssetIDs: Set(book.assets.map(\.uuid))
                    .union(asset.map { [$0.id] } ?? []),
                requiresInvariantRepair: requiresInvariantRepair
            )
        }

        var committed = 0
        let chunkSize = max(1, batchSize)
        for start in stride(from: 0, to: plans.count, by: chunkSize) {
            let chunk = Array(plans[start ..< min(start + chunkSize, plans.count)])
            let bookIDs = Set(chunk.map(\.bookID))
            let workIDs = Set(chunk.compactMap(\.existingWorkID))
                .union(chunk.compactMap(\.newWorkID))
            let assetIDs = chunk.reduce(into: Set<UUID>()) {
                $0.formUnion($1.affectedAssetIDs)
            }
            var staged = 0
            do {
                try writer.commitPrepared(
                    .legacyMigration(bookIDs: Array(bookIDs)),
                    affectedBookIDs: bookIDs,
                    affectedWorkIDs: workIDs,
                    affectedAssetIDs: assetIDs
                ) { writeContext in
                    for plan in chunk {
                        let bookID = plan.bookID
                        let matches = try writeContext.fetch(FetchDescriptor<Book>(
                            predicate: #Predicate { $0.uuid == bookID }
                        ))
                        guard let book = matches.first else {
                            throw CatalogMutationError.modelNotFound
                        }

                        if let seed = plan.asset,
                           book.assets.isEmpty,
                           book.hasDigitalFile {
                            if book.fileSizeBytes == 0, seed.sizeBytes > 0 {
                                book.fileSizeBytes = seed.sizeBytes
                            }
                            let asset = BookAsset(
                                uuid: seed.id,
                                fileName: seed.fileName,
                                origin: .original,
                                sourceProvenance: .legacyMigration,
                                sizeBytes: seed.sizeBytes,
                                drmProtected: seed.drmProtected,
                                dateAdded: seed.dateAdded,
                                book: book
                            )
                            writeContext.insert(asset)
                            book.primaryAssetUUID = asset.uuid
                            staged += 1
                        }

                        if let workID = plan.newWorkID, book.work == nil {
                            let work = Work(
                                uuid: workID,
                                title: book.displayTitle,
                                author: book.author,
                                dateCreated: book.dateAdded
                            )
                            writeContext.insert(work)
                            book.work = work
                            work.preferredEditionUUID = book.uuid
                            staged += 1
                        }

                        if CatalogModelInvariantService.repair(book: book) {
                            staged += 1
                        }
                    }
                }
            } catch {
                throw error
            }
            committed += staged
        }
        return committed
    }

    @discardableResult
    static func pruneOrphanWorks(
        context: ModelContext,
        mutations: CatalogMutationService? = nil
    ) throws -> Int {
        var descriptor = FetchDescriptor<Work>()
        descriptor.relationshipKeyPathsForPrefetching = [\.editions]
        let works = try context.fetch(descriptor)
        let workIDs = Set(works.lazy.filter(\.editions.isEmpty).map(\.uuid))
        var deleted = 0
        if !workIDs.isEmpty {
            let writer = mutations ?? CatalogMutationService(modelContext: context)
            do {
                try writer.commitPrepared(
                    .maintenanceCleanup(workIDs: Array(workIDs)),
                    affectedWorkIDs: workIDs
                ) { writeContext in
                    for workID in workIDs {
                        let matches = try writeContext.fetch(FetchDescriptor<Work>(
                            predicate: #Predicate { $0.uuid == workID }
                        ))
                        guard let work = matches.first, work.editions.isEmpty else {
                            continue
                        }
                        writeContext.delete(work)
                        deleted += 1
                    }
                }
            } catch {
                throw error
            }
        }
        return deleted
    }
}
