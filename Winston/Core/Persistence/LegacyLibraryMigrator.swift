import Foundation
import SwiftData
import OSLog

enum LegacyLibraryMigrator {
    enum MigrationResult: Equatable {
        case completed
        case cancelled
        case failed
    }

    private static let progressKey = "maintenance.legacy-library.v2.offset"

    static func resetCheckpoint(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: progressKey)
    }

    private nonisolated struct LegacyMetadata: Decodable, Sendable {
        var title: String?
        var author: String?
        var publisher: String?
        var year: String?
        var language: String?
        var isbn: String?
        var series: String?
        var seriesIndex: String?
        var tags: [String]?
        var description: String?
    }

    private nonisolated struct LegacyBook: Decodable, Sendable {
        let id: UUID
        var fileURL: URL
        var bookmarkData: Data?
        var metadata: LegacyMetadata
        var rating: Int?
        let dateAdded: Date
    }

    @MainActor
    static func migrateIfNeeded(
        context: ModelContext,
        mutations: CatalogMutationService,
        managedFiles: ManagedFileCoordinator
    ) async -> Bool {
        await migrateIncrementally(
            context: context,
            mutations: mutations,
            managedFiles: managedFiles
        ) == .completed
    }

    @MainActor
    static func migrateIncrementally(
        context: ModelContext,
        mutations: CatalogMutationService,
        managedFiles: ManagedFileCoordinator,
        defaults: UserDefaults = .standard,
        batchSize: Int = 16,
        onProgress: (Int, Int) -> Void = { _, _ in }
    ) async -> MigrationResult {
        let legacyFile = AppPaths.appSupportDirectory.appending(path: "library.json")
        guard FileManager.default.fileExists(atPath: legacyFile.path(percentEncoded: false)) else {
            defaults.removeObject(forKey: progressKey)
            return .completed
        }

        let legacyBooks: [LegacyBook]
        do {
            legacyBooks = try await Task.detached(priority: .utility) {
                let data = try Data(contentsOf: legacyFile)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode([LegacyBook].self, from: data)
            }.value
        } catch {
            Log.persistence.error("Legacy migration could not read the old catalog: \(error.localizedDescription, privacy: .public)")
            return .failed
        }

        let startIndex = min(
            max(defaults.integer(forKey: progressKey), 0),
            legacyBooks.count
        )
        onProgress(startIndex, legacyBooks.count)

        for index in startIndex ..< legacyBooks.count {
            guard !Task.isCancelled else { return .cancelled }
            let legacy = legacyBooks[index]
            let legacyID = legacy.id
            var descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.uuid == legacyID })
            descriptor.fetchLimit = 1
            if (try? context.fetch(descriptor).first) == nil {
                let sourceURL = resolveURL(for: legacy)
                let accessing = sourceURL.startAccessingSecurityScopedResource()
                let result = await migrate(
                    legacy,
                    sourceURL: sourceURL,
                    context: context,
                    mutations: mutations,
                    managedFiles: managedFiles
                )
                if accessing { sourceURL.stopAccessingSecurityScopedResource() }
                guard result else { return .failed }
            }

            defaults.set(index + 1, forKey: progressKey)
            onProgress(index + 1, legacyBooks.count)
            if (index + 1).isMultiple(of: max(1, batchSize)) {
                await Task.yield()
            }
        }

        guard !Task.isCancelled else { return .cancelled }
        let backup = AppPaths.appSupportDirectory.appending(path: "library.v1.bak")
        do {
            try await Task.detached(priority: .utility) {
                let fileManager = FileManager.default
                if fileManager.fileExists(atPath: backup.path(percentEncoded: false)) {
                    try fileManager.removeItem(at: backup)
                }
                try fileManager.moveItem(at: legacyFile, to: backup)
            }.value
            defaults.removeObject(forKey: progressKey)
            return .completed
        } catch {
            Log.persistence.error("Legacy migration checkpoint failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    @MainActor
    private static func migrate(
        _ legacy: LegacyBook,
        sourceURL: URL,
        context: ModelContext,
        mutations: CatalogMutationService,
        managedFiles: ManagedFileCoordinator
    ) async -> Bool {
        guard FileManager.default.fileExists(atPath: sourceURL.path(percentEncoded: false)) else {
            Log.persistence.error("Legacy migration source is unavailable: \(sourceURL.lastPathComponent, privacy: .private)")
            return false
        }

        let source: ManagedFileSource
        do {
            source = try .book(sourceURL: sourceURL, fileID: legacy.id)
        } catch {
            return false
        }
        let fileName = source.finalRelativeName
        let transaction: ManagedFileTransaction
        do {
            transaction = try await managedFiles.stage(
                intent: .legacyMigration,
                sources: [source],
                requirement: ManagedFileRequirement(
                    presentBookIDs: [legacy.id],
                    referencedBookFileNames: [fileName]
                )
            )
        } catch {
            Log.persistence.error("Legacy file staging failed: \(error.localizedDescription, privacy: .public)")
            return false
        }

        guard let staged = transaction.files.first else {
            await managedFiles.abort(transaction)
            return false
        }
        let book = Book(
            uuid: legacy.id,
            fileName: fileName,
            originalFileName: legacy.fileURL.lastPathComponent,
            dateAdded: legacy.dateAdded
        )
        book.fileSizeBytes = staged.byteCount
        book.title = legacy.metadata.title
        book.author = legacy.metadata.author
        book.publisher = legacy.metadata.publisher
        book.year = legacy.metadata.year
        book.language = legacy.metadata.language
        book.isbn = legacy.metadata.isbn
        book.series = legacy.metadata.series
        book.seriesIndex = legacy.metadata.seriesIndex
        book.tags = legacy.metadata.tags ?? []
        book.bookDescription = legacy.metadata.description
        book.rating = legacy.rating
        let asset = BookAsset(
            uuid: legacy.id,
            fileName: fileName,
            origin: .original,
            contentHash: staged.sha256,
            sizeBytes: staged.byteCount,
            dateAdded: legacy.dateAdded,
            validationStatus: .ok,
            book: book
        )
        context.insert(book)
        context.insert(asset)

        do {
            let result = try await mutations.commitStagedFiles(
                .legacyMigration(bookIDs: [legacy.id]),
                transactions: [transaction],
                affectedBookIDs: [legacy.id]
            )
            return result.isFullyPublished
        } catch {
            Log.persistence.error("Legacy migration save failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func resolveURL(for legacy: LegacyBook) -> URL {
        guard let bookmarkData = legacy.bookmarkData else { return legacy.fileURL }
        var isStale = false
        if let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return url
        }
        return legacy.fileURL
    }
}
