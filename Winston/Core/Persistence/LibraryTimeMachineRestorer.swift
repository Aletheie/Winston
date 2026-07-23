import AppKit
import Foundation
import SwiftData

nonisolated enum LibraryTimeMachineRestoreScope: String, Sendable, Identifiable {
    case metadata
    case cover
    case book

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .metadata: "Restore Metadata"
        case .cover: "Restore Cover"
        case .book: "Restore Book"
        }
    }

    var confirmationTitle: LocalizedStringResource {
        switch self {
        case .metadata: "Restore this book’s metadata?"
        case .cover: "Restore this book’s cover?"
        case .book: "Restore this book from the backup?"
        }
    }

    var confirmationMessage: LocalizedStringResource {
        switch self {
        case .metadata:
            "Current bibliographic metadata, ratings, and notes will be replaced. Reading history, highlights, collections, and book files stay untouched."
        case .cover:
            "The current saved cover will be replaced. Metadata, reading data, and book files stay untouched."
        case .book:
            "Metadata, reading history, highlights, collection memberships, and the saved cover will return to this backup’s state. Book files stay untouched."
        }
    }
}

nonisolated struct LibraryTimeMachineRestoreResult: Equatable, Sendable {
    let bookID: UUID
    let scope: LibraryTimeMachineRestoreScope
    let createdBook: Bool
    let bookFileMissing: Bool
    let skippedCollectionCount: Int
    let safetyBackupURL: URL
}

enum LibraryTimeMachineRestoreError: LocalizedError {
    case bookUnavailable
    case backupCoverUnavailable
    case backupCoverUnreadable
    case safetyBackupFailed(String)
    case coverWriteFailed
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .bookUnavailable:
            String(localized: "This book is no longer available for that restore action.")
        case .backupCoverUnavailable:
            String(localized: "This backup does not contain a saved cover for the book.")
        case .backupCoverUnreadable:
            String(localized: "The saved cover in this backup could not be read.")
        case .safetyBackupFailed(let reason):
            String(
                localized: "A safety backup could not be created: \(reason)",
                comment: "Restore error. The interpolated value describes the underlying failure."
            )
        case .coverWriteFailed:
            String(localized: "The restored cover could not be saved.")
        case .saveFailed(let reason):
            String(
                localized: "The restored book could not be saved: \(reason)",
                comment: "Restore error. The interpolated value describes the underlying failure."
            )
        }
    }
}

@MainActor
struct LibraryTimeMachineRestorer {
    typealias SafetyBackupAction = @Sendable (URL) async throws -> URL

    private let modelContext: ModelContext
    private let coversDirectory: URL
    private let createSafetyBackup: SafetyBackupAction
    private let covers: CoverRepository

    init(
        modelContext: ModelContext,
        liveStoreURL: URL = PersistenceController.storeURL,
        coversDirectory: URL = AppPaths.coversDirectory,
        createSafetyBackup: SafetyBackupAction? = nil,
        coverRepository: CoverRepository? = nil
    ) {
        self.modelContext = modelContext
        self.coversDirectory = coversDirectory
        if let coverRepository {
            covers = coverRepository
        } else if coversDirectory.standardizedFileURL == AppPaths.coversDirectory.standardizedFileURL {
            covers = .shared
        } else {
            covers = CoverRepository(coversDirectory: coversDirectory)
        }
        if let createSafetyBackup {
            self.createSafetyBackup = createSafetyBackup
        } else {
            let backupCoordinator: ManagedFileCoordinator
            if coversDirectory.standardizedFileURL == AppPaths.coversDirectory.standardizedFileURL {
                backupCoordinator = .shared
            } else {
                let root = coversDirectory.deletingLastPathComponent()
                backupCoordinator = ManagedFileCoordinator(
                    booksDirectory: root.appending(path: "Books", directoryHint: .isDirectory),
                    coversDirectory: coversDirectory,
                    stateDirectory: root.appending(path: "ManagedFiles", directoryHint: .isDirectory)
                )
            }
            self.createSafetyBackup = { sourceBackup in
                do {
                    return try await backupCoordinator.createBackup(
                        storeURL: liveStoreURL,
                        to: sourceBackup.deletingLastPathComponent(),
                        keepLast: Int.max
                    )
                } catch {
                    throw LibraryTimeMachineRestoreError.safetyBackupFailed(
                        error.localizedDescription
                    )
                }
            }
        }
    }

    func restore(
        _ snapshot: LibraryTimeMachineBookSnapshot,
        scope: LibraryTimeMachineRestoreScope,
        from sourceBackup: URL
    ) async throws -> LibraryTimeMachineRestoreResult {
        let existing = modelContext.allBooks().first { $0.uuid == snapshot.id }
        if scope != .book, existing == nil {
            throw LibraryTimeMachineRestoreError.bookUnavailable
        }

        let restoredCoverData = try await coverData(for: snapshot, scope: scope)
        do {
            if modelContext.hasChanges {
                try modelContext.saveAndPublish(fullTextAffectedBookIDs: nil)
            }
        } catch {
            modelContext.rollback()
            throw LibraryTimeMachineRestoreError.saveFailed(error.localizedDescription)
        }

        let safetyBackup: URL
        do {
            safetyBackup = try await createSafetyBackup(sourceBackup)
        } catch let error as LibraryTimeMachineRestoreError {
            throw error
        } catch {
            throw LibraryTimeMachineRestoreError.safetyBackupFailed(error.localizedDescription)
        }

        let coverIsIncluded = scope == .cover || scope == .book
        let coverToken = coverIsIncluded
            ? await covers.beginUserMutation(for: snapshot.id)
            : nil
        var coverRollback: CoverRollbackTicket?
        var restoredBook: Book?
        var createdBook = false
        var skippedCollections = 0

        do {
            switch scope {
            case .metadata:
                guard let existing else { throw LibraryTimeMachineRestoreError.bookUnavailable }
                applyMetadata(snapshot.metadata, to: existing)
                restoredBook = existing

            case .cover:
                guard let existing else { throw LibraryTimeMachineRestoreError.bookUnavailable }
                restoredBook = existing

            case .book:
                let book: Book
                if let existing {
                    book = existing
                } else {
                    book = makeBook(from: snapshot)
                    modelContext.insert(book)
                    createdBook = true
                }
                applyMetadata(snapshot.metadata, to: book)
                book.readingStatusRaw = snapshot.reading.statusRaw
                book.dateStarted = snapshot.reading.dateStarted
                book.dateFinished = snapshot.reading.dateFinished
                replaceReadingSessions(on: book, with: snapshot.reading.sessions)
                replaceHighlights(on: book, with: snapshot.highlights)
                skippedCollections = try restoreCollectionMemberships(
                    on: book,
                    from: snapshot.collections
                )
                if createdBook {
                    restoreAssets(on: book, from: snapshot.assets)
                    try restoreWork(on: book, from: snapshot.work)
                }
                restoredBook = book
            }

            if let coverToken {
                coverRollback = if let restoredCoverData {
                    await covers.install(restoredCoverData, using: coverToken)
                } else {
                    await covers.remove(using: coverToken)
                }
                guard coverRollback != nil else {
                    throw LibraryTimeMachineRestoreError.coverWriteFailed
                }
                restoredBook?.coverVersion = max(
                    (restoredBook?.coverVersion ?? 0) + 1,
                    snapshot.coverVersion + 1
                )
            }

            do {
                try modelContext.saveAndPublish(
                    affectedBookIDs: [snapshot.id],
                    changesBookMembership: createdBook,
                    fullTextAffectedBookIDs: scope == .cover ? [] : [snapshot.id]
                )
            } catch {
                throw LibraryTimeMachineRestoreError.saveFailed(error.localizedDescription)
            }
        } catch {
            modelContext.rollback()
            if let coverRollback {
                _ = await covers.rollback(coverRollback)
            }
            throw error
        }

        if coverIsIncluded, let restoredBook {
            let image = restoredCoverData.flatMap(NSImage.init(data:))
            await CoverCache.shared.replace(image, for: restoredBook.coverCacheURL)
        }

        return LibraryTimeMachineRestoreResult(
            bookID: snapshot.id,
            scope: scope,
            createdBook: createdBook,
            bookFileMissing: restoredBook.map { book in
                guard let url = book.primaryFileURL else { return false }
                return !FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
            } ?? true,
            skippedCollectionCount: skippedCollections,
            safetyBackupURL: safetyBackup
        )
    }

    private func coverData(
        for snapshot: LibraryTimeMachineBookSnapshot,
        scope: LibraryTimeMachineRestoreScope
    ) async throws -> Data? {
        guard scope == .cover || scope == .book else { return nil }
        if scope == .cover, snapshot.coverURL == nil {
            throw LibraryTimeMachineRestoreError.backupCoverUnavailable
        }
        guard let coverURL = snapshot.coverURL else { return nil }
        let data = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: coverURL)
        }.value
        guard let data else { throw LibraryTimeMachineRestoreError.backupCoverUnreadable }
        return data
    }

    private func applyMetadata(
        _ metadata: LibraryTimeMachineMetadataSnapshot,
        to book: Book
    ) {
        book.title = metadata.title
        book.author = metadata.author
        book.publisher = metadata.publisher
        book.year = metadata.year
        book.language = metadata.language
        book.translator = metadata.translator
        book.isbn = metadata.isbn
        book.series = metadata.series
        book.seriesIndex = metadata.seriesIndex
        book.tags = metadata.tags
        book.bookDescription = metadata.bookDescription
        book.rating = metadata.rating
        book.communityRating = metadata.communityRating
        book.communityRatingCount = metadata.communityRatingCount
        book.communityRatingSource = metadata.communityRatingSource
        book.notes = metadata.notes
        book.drmProtected = metadata.drmProtected
        book.pageCount = metadata.pageCount
        book.editionStatement = metadata.editionStatement
        book.editionTypeRaw = metadata.editionTypeRaw
        book.hasPhysicalCopyRaw = metadata.hasPhysicalCopyRaw
        book.shelfLocation = metadata.shelfLocation
    }

    private func makeBook(from snapshot: LibraryTimeMachineBookSnapshot) -> Book {
        let book = Book(
            uuid: snapshot.id,
            fileName: snapshot.fileName,
            originalFileName: snapshot.originalFileName,
            dateAdded: snapshot.dateAdded
        )
        book.fileSizeBytes = snapshot.fileSizeBytes
        book.coverVersion = snapshot.coverVersion
        return book
    }

    private func replaceReadingSessions(
        on book: Book,
        with snapshots: [LibraryTimeMachineReadingSessionSnapshot]
    ) {
        let existing = book.readingSessions
        book.readingSessions.removeAll()
        existing.forEach(modelContext.delete)
        for snapshot in snapshots {
            let session = ReadingSession(
                uuid: snapshot.id,
                startedAt: snapshot.startedAt,
                endedAt: snapshot.endedAt,
                status: ReadingSessionStatus(rawValue: snapshot.statusRaw) ?? .reading,
                progress: snapshot.progress,
                book: book
            )
            session.statusRaw = snapshot.statusRaw
            modelContext.insert(session)
        }
    }

    private func replaceHighlights(
        on book: Book,
        with snapshots: [LibraryTimeMachineHighlightSnapshot]
    ) {
        let existing = book.highlights
        book.highlights.removeAll()
        existing.forEach(modelContext.delete)
        for snapshot in snapshots {
            let highlight = Highlight(
                text: snapshot.text,
                isNote: snapshot.kindRaw == "note",
                location: snapshot.location,
                addedDate: snapshot.addedDate
            )
            highlight.kindRaw = snapshot.kindRaw
            highlight.dateImported = snapshot.dateImported
            highlight.book = book
            modelContext.insert(highlight)
        }
    }

    private func restoreCollectionMemberships(
        on book: Book,
        from snapshots: [LibraryTimeMachineCollectionSnapshot]
    ) throws -> Int {
        let collections = try modelContext.fetch(FetchDescriptor<BookCollection>())
        let byID = Dictionary(collections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byName = Dictionary(
            collections.map { ($0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var restored: [BookCollection] = []
        var skipped = 0
        for snapshot in snapshots {
            let nameKey = snapshot.name.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            if let collection = byID[snapshot.id] ?? byName[nameKey] {
                restored.append(collection)
            } else {
                skipped += 1
            }
        }
        book.collections = restored
        return skipped
    }

    private func restoreAssets(
        on book: Book,
        from snapshots: [LibraryTimeMachineAssetSnapshot]
    ) {
        for snapshot in snapshots {
            let asset = BookAsset(
                uuid: snapshot.id,
                fileName: snapshot.fileName,
                origin: snapshot.originRaw.flatMap(AssetOrigin.init(rawValue:)) ?? .original,
                contentHash: snapshot.contentHash,
                generatedFromContentHash: snapshot.generatedFromContentHash,
                sizeBytes: snapshot.sizeBytes,
                dateAdded: snapshot.dateAdded,
                validationStatus: snapshot.validationStatusRaw.flatMap(AssetValidation.init(rawValue:)),
                book: book
            )
            asset.originRaw = snapshot.originRaw
            asset.validationStatusRaw = snapshot.validationStatusRaw
            modelContext.insert(asset)
        }
    }

    private func restoreWork(
        on book: Book,
        from snapshot: LibraryTimeMachineWorkSnapshot?
    ) throws {
        guard let snapshot else { return }
        let works = try modelContext.fetch(FetchDescriptor<Work>())
        if let existing = works.first(where: { $0.uuid == snapshot.id }) {
            book.work = existing
            return
        }
        let work = Work(
            uuid: snapshot.id,
            title: snapshot.title,
            author: snapshot.author,
            dateCreated: snapshot.dateCreated
        )
        work.originalTitle = snapshot.originalTitle
        work.originalLanguage = snapshot.originalLanguage
        work.openLibraryWorkKey = snapshot.openLibraryWorkKey
        work.hardcoverBookID = snapshot.hardcoverBookID
        work.preferredEditionUUID = snapshot.preferredEditionUUID
        work.notes = snapshot.notes
        modelContext.insert(work)
        book.work = work
    }

}
