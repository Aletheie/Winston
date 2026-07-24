import Foundation
import SwiftData

enum EditionsBackfill {
    @discardableResult
    static func run(context: ModelContext, batchSize: Int = 100) -> Int {
        var descriptor = FetchDescriptor<Book>()
        descriptor.relationshipKeyPathsForPrefetching = [\.assets, \.work]
        let books = (try? context.fetch(descriptor)) ?? []
        var inserted = 0

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
                inserted += 1
            }

            if book.work == nil {
                let work = Work(title: book.displayTitle, author: book.author, dateCreated: book.dateAdded)
                context.insert(work)
                book.work = work
                work.preferredEditionUUID = book.uuid
                inserted += 1
            }

            if inserted > 0, (index + 1).isMultiple(of: max(1, batchSize)) {
                context.saveQuietly()
            }
        }

        if inserted > 0 { context.saveQuietly() }
        return inserted
    }

    @discardableResult
    static func pruneOrphanWorks(context: ModelContext) -> Int {
        var descriptor = FetchDescriptor<Work>()
        descriptor.relationshipKeyPathsForPrefetching = [\.editions]
        let works = (try? context.fetch(descriptor)) ?? []
        let orphaned = works.filter(\.editions.isEmpty)
        for work in orphaned { context.delete(work) }
        if !orphaned.isEmpty { context.saveQuietly() }
        return orphaned.count
    }
}
