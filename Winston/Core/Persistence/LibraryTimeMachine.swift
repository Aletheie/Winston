import Foundation
import SwiftData

nonisolated struct LibraryTimeMachineMetadataSnapshot: Equatable, Sendable {
    var title: String?
    var author: String?
    var publisher: String?
    var year: String?
    var language: String?
    var translator: String?
    var isbn: String?
    var series: String?
    var seriesIndex: String?
    var tags: [String]
    var bookDescription: String?
    var rating: Int?
    var communityRating: Double?
    var communityRatingCount: Int?
    var communityRatingSource: String?
    var onlineLookupAt: Date?
    var onlineLookupConfiguration: String?
    var notes: String?
    var drmProtected: Bool?
    var pageCount: Int?
    var sampleNoticeDismissed: Bool?
    var editionStatement: String?
    var editionTypeRaw: String?

    init(
        title: String? = nil,
        author: String? = nil,
        publisher: String? = nil,
        year: String? = nil,
        language: String? = nil,
        translator: String? = nil,
        isbn: String? = nil,
        series: String? = nil,
        seriesIndex: String? = nil,
        tags: [String] = [],
        bookDescription: String? = nil,
        rating: Int? = nil,
        communityRating: Double? = nil,
        communityRatingCount: Int? = nil,
        communityRatingSource: String? = nil,
        onlineLookupAt: Date? = nil,
        onlineLookupConfiguration: String? = nil,
        notes: String? = nil,
        drmProtected: Bool? = nil,
        pageCount: Int? = nil,
        sampleNoticeDismissed: Bool? = nil,
        editionStatement: String? = nil,
        editionTypeRaw: String? = nil
    ) {
        self.title = title
        self.author = author
        self.publisher = publisher
        self.year = year
        self.language = language
        self.translator = translator
        self.isbn = isbn
        self.series = series
        self.seriesIndex = seriesIndex
        self.tags = tags
        self.bookDescription = bookDescription
        self.rating = rating
        self.communityRating = communityRating
        self.communityRatingCount = communityRatingCount
        self.communityRatingSource = communityRatingSource
        self.onlineLookupAt = onlineLookupAt
        self.onlineLookupConfiguration = onlineLookupConfiguration
        self.notes = notes
        self.drmProtected = drmProtected
        self.pageCount = pageCount
        self.sampleNoticeDismissed = sampleNoticeDismissed
        self.editionStatement = editionStatement
        self.editionTypeRaw = editionTypeRaw
    }
}

nonisolated struct LibraryTimeMachineReadingSessionSnapshot: Equatable, Sendable, Identifiable {
    let id: UUID
    var startedAt: Date
    var endedAt: Date?
    var statusRaw: String
    var progress: Double
}

nonisolated struct LibraryTimeMachineReadingSnapshot: Equatable, Sendable {
    var statusRaw: String?
    var dateStarted: Date?
    var dateFinished: Date?
    var sessions: [LibraryTimeMachineReadingSessionSnapshot]

    init(
        statusRaw: String? = nil,
        dateStarted: Date? = nil,
        dateFinished: Date? = nil,
        sessions: [LibraryTimeMachineReadingSessionSnapshot] = []
    ) {
        self.statusRaw = statusRaw
        self.dateStarted = dateStarted
        self.dateFinished = dateFinished
        self.sessions = sessions
    }
}

nonisolated struct LibraryTimeMachineHighlightSnapshot: Equatable, Sendable {
    var text: String
    var kindRaw: String
    var location: String?
    var addedDate: Date?
    var dateImported: Date
}

nonisolated struct LibraryTimeMachineAssetSnapshot: Equatable, Sendable, Identifiable {
    let id: UUID
    var fileName: String
    var originRaw: String?
    var contentHash: String?
    var generatedFromContentHash: String?
    var sizeBytes: Int64
    var dateAdded: Date
    var validationStatusRaw: String?
}

nonisolated struct LibraryTimeMachineCollectionSnapshot: Equatable, Sendable, Identifiable {
    let id: UUID
    var name: String
    var dateCreated: Date
    var savedSearch: String?
    var smartShelfRulesData: Data?
    var systemKindRaw: String?
}

nonisolated struct LibraryTimeMachineWorkSnapshot: Equatable, Sendable, Identifiable {
    let id: UUID
    var title: String?
    var author: String?
    var originalTitle: String?
    var originalLanguage: String?
    var openLibraryWorkKey: String?
    var hardcoverBookID: String?
    var preferredEditionUUID: UUID?
    var dateCreated: Date
    var notes: String?
}

nonisolated struct LibraryTimeMachineBookSnapshot: Equatable, Sendable, Identifiable {
    let id: UUID
    var fileName: String
    var originalFileName: String
    var dateAdded: Date
    var fileSizeBytes: Int64
    var coverVersion: Int
    var metadata: LibraryTimeMachineMetadataSnapshot
    var reading: LibraryTimeMachineReadingSnapshot
    var highlights: [LibraryTimeMachineHighlightSnapshot]
    var collections: [LibraryTimeMachineCollectionSnapshot]
    var work: LibraryTimeMachineWorkSnapshot?
    var assets: [LibraryTimeMachineAssetSnapshot]
    var coverURL: URL?
    var bookFileExists: Bool

    init(
        id: UUID,
        fileName: String,
        originalFileName: String,
        dateAdded: Date = .now,
        fileSizeBytes: Int64 = 0,
        coverVersion: Int = 0,
        metadata: LibraryTimeMachineMetadataSnapshot = .init(),
        reading: LibraryTimeMachineReadingSnapshot = .init(),
        highlights: [LibraryTimeMachineHighlightSnapshot] = [],
        collections: [LibraryTimeMachineCollectionSnapshot] = [],
        work: LibraryTimeMachineWorkSnapshot? = nil,
        assets: [LibraryTimeMachineAssetSnapshot] = [],
        coverURL: URL? = nil,
        bookFileExists: Bool = false
    ) {
        self.id = id
        self.fileName = fileName
        self.originalFileName = originalFileName
        self.dateAdded = dateAdded
        self.fileSizeBytes = fileSizeBytes
        self.coverVersion = coverVersion
        self.metadata = metadata
        self.reading = reading
        self.highlights = highlights
        self.collections = collections
        self.work = work
        self.assets = assets
        self.coverURL = coverURL
        self.bookFileExists = bookFileExists
    }

    var displayTitle: String {
        Book.displayTitle(storedTitle: metadata.title, originalFileName: originalFileName)
    }

    var displayAuthor: String? {
        guard let value = metadata.author?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    var hasCover: Bool { coverURL != nil }
}

nonisolated struct LibraryTimeMachineSnapshot: Equatable, Sendable {
    let backupURL: URL
    let date: Date?
    let books: [LibraryTimeMachineBookSnapshot]
}

nonisolated enum LibraryTimeMachineChangeKind: Int, CaseIterable, Sendable {
    case deletedSinceBackup
    case modified
    case addedSinceBackup
    case unchanged

    var title: LocalizedStringResource {
        switch self {
        case .deletedSinceBackup: "Deleted"
        case .modified: "Modified"
        case .addedSinceBackup: "Added later"
        case .unchanged: "Unchanged"
        }
    }

    var systemImage: String {
        switch self {
        case .deletedSinceBackup: "arrow.uturn.backward.circle.fill"
        case .modified: "pencil.circle.fill"
        case .addedSinceBackup: "plus.circle.fill"
        case .unchanged: "checkmark.circle"
        }
    }
}

nonisolated enum LibraryTimeMachineChangeGroup: String, CaseIterable, Sendable, Hashable {
    case metadata
    case readingHistory
    case highlights
    case collections
    case cover
    case fileRecord

    var title: LocalizedStringResource {
        switch self {
        case .metadata: "Metadata"
        case .readingHistory: "Reading history"
        case .highlights: "Highlights"
        case .collections: "Collections"
        case .cover: "Cover"
        case .fileRecord: "File record"
        }
    }

    var systemImage: String {
        switch self {
        case .metadata: "text.badge.checkmark"
        case .readingHistory: "clock.arrow.circlepath"
        case .highlights: "highlighter"
        case .collections: "books.vertical"
        case .cover: "photo"
        case .fileRecord: "doc"
        }
    }
}

nonisolated enum LibraryTimeMachineField: String, CaseIterable, Sendable, Identifiable {
    case title
    case author
    case publisher
    case year
    case language
    case translator
    case isbn
    case series
    case seriesIndex
    case tags
    case bookDescription
    case rating
    case communityRating
    case communityRatingCount
    case communityRatingSource
    case pageCount
    case notes
    case readingStatus
    case dateStarted
    case dateFinished
    case editionStatement
    case editionType
    case drmProtected

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .title: "Title"
        case .author: "Author"
        case .publisher: "Publisher"
        case .year: "Year"
        case .language: "Language"
        case .translator: "Translator"
        case .isbn: "ISBN"
        case .series: "Series"
        case .seriesIndex: "Series position"
        case .tags: "Tags"
        case .bookDescription: "Description"
        case .rating: "My rating"
        case .communityRating: "Community rating"
        case .communityRatingCount: "Community rating count"
        case .communityRatingSource: "Community rating source"
        case .pageCount: "Pages"
        case .notes: "Notes"
        case .readingStatus: "Reading status"
        case .dateStarted: "Started"
        case .dateFinished: "Finished"
        case .editionStatement: "Edition"
        case .editionType: "Edition type"
        case .drmProtected: "DRM"
        }
    }
}

nonisolated enum LibraryTimeMachineFieldValue: Equatable, Sendable {
    case text(String?)
    case integer(Int?)
    case decimal(Double?)
    case date(Date?)
    case textList([String])
    case boolean(Bool?)
}

nonisolated struct LibraryTimeMachineFieldChange: Equatable, Sendable, Identifiable {
    let field: LibraryTimeMachineField
    let current: LibraryTimeMachineFieldValue
    let backup: LibraryTimeMachineFieldValue

    var id: LibraryTimeMachineField { field }
}

nonisolated struct LibraryTimeMachineBookDiff: Equatable, Sendable, Identifiable {
    let id: UUID
    let kind: LibraryTimeMachineChangeKind
    let backup: LibraryTimeMachineBookSnapshot?
    let current: LibraryTimeMachineBookSnapshot?
    let changeGroups: [LibraryTimeMachineChangeGroup]
    let fieldChanges: [LibraryTimeMachineFieldChange]

    var displayTitle: String {
        backup?.displayTitle ?? current?.displayTitle ?? String(localized: "Unknown")
    }

    var displayAuthor: String? {
        backup?.displayAuthor ?? current?.displayAuthor
    }

    var canRestore: Bool {
        guard backup != nil else { return false }
        if kind == .deletedSinceBackup { return true }
        let restorable: Set<LibraryTimeMachineChangeGroup> = [
            .metadata, .readingHistory, .highlights, .collections, .cover,
        ]
        return kind == .modified && !restorable.isDisjoint(with: changeGroups)
    }
}

enum LibraryTimeMachineError: LocalizedError {
    case missingCatalog
    case unreadableCatalog(String)

    var errorDescription: String? {
        switch self {
        case .missingCatalog:
            String(localized: "This backup does not contain a library catalog.")
        case .unreadableCatalog(let reason):
            String(
                localized: "The backup catalog could not be opened: \(reason)",
                comment: "Time Machine error. The interpolated value describes the catalog failure."
            )
        }
    }
}

nonisolated enum LibraryTimeMachineReader {
    static func load(_ backupURL: URL) throws -> LibraryTimeMachineSnapshot {
        guard let sourceStore = LibraryBackup.catalogURL(in: backupURL) else {
            throw LibraryTimeMachineError.missingCatalog
        }

        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory.appending(
            path: "WinstonTimeMachine-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? fileManager.removeItem(at: staging) }

        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            let stagedStore = staging.appending(path: LibraryBackup.currentStoreName)
            try fileManager.copyItem(at: sourceStore, to: stagedStore)

            let books = try readBooks(
                from: stagedStore,
                backupURL: backupURL,
                liveBooksDirectory: AppPaths.booksDirectory
            )
            return LibraryTimeMachineSnapshot(
                backupURL: backupURL,
                date: LibraryBackup.date(of: backupURL),
                books: books
            )
        } catch let error as LibraryTimeMachineError {
            throw error
        } catch {
            throw LibraryTimeMachineError.unreadableCatalog(error.localizedDescription)
        }
    }

    private static func readBooks(
        from storeURL: URL,
        backupURL: URL,
        liveBooksDirectory: URL
    ) throws -> [LibraryTimeMachineBookSnapshot] {
        let configuration = ModelConfiguration(url: storeURL, allowsSave: true)
        let container = try ModelContainer(
            for: Work.self, Book.self, ReadingSession.self, BookAsset.self,
            BookCollection.self, Highlight.self, WishlistItem.self,
            LibraryNotice.self, SeriesCatalogSnapshot.self,
            configurations: configuration
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var descriptor = FetchDescriptor<Book>()
        descriptor.relationshipKeyPathsForPrefetching = [
            \Book.readingSessions,
            \Book.highlights,
            \Book.collections,
            \Book.assets,
            \Book.work,
        ]
        let books = try context.fetch(descriptor)
        return books.map {
            LibraryTimeMachineSnapshotBuilder.makeBook(
                $0,
                coverURL: LibraryBackup.coverURL(for: $0.uuid, in: backupURL),
                booksDirectory: liveBooksDirectory
            )
        }
    }
}

enum LibraryTimeMachineDiffBuilder {
    @MainActor
    static func snapshotCurrentBooks(
        _ books: [Book],
        currentCoversDirectory: URL = AppPaths.coversDirectory,
        currentBooksDirectory: URL = AppPaths.booksDirectory
    ) async -> [LibraryTimeMachineBookSnapshot] {
        var snapshots: [LibraryTimeMachineBookSnapshot] = []
        snapshots.reserveCapacity(books.count)
        for (index, book) in books.enumerated() {
            guard !Task.isCancelled else { return [] }
            snapshots.append(LibraryTimeMachineSnapshotBuilder.makeBook(
                book,
                coverURL: nil,
                booksDirectory: currentBooksDirectory,
                bookFileExists: false
            ))
            if index > 0, index.isMultiple(of: 64) { await Task.yield() }
        }

        return await resolveAvailability(
            snapshots,
            coversDirectory: currentCoversDirectory,
            booksDirectory: currentBooksDirectory
        )
    }

    @concurrent
    private static func resolveAvailability(
        _ snapshots: [LibraryTimeMachineBookSnapshot],
        coversDirectory: URL,
        booksDirectory: URL
    ) async -> [LibraryTimeMachineBookSnapshot] {
        var resolved = snapshots
        for index in resolved.indices {
            guard !Task.isCancelled else { return [] }
            let cover = coversDirectory.appending(path: "\(resolved[index].id.uuidString).jpg")
            if FileManager.default.fileExists(atPath: cover.path(percentEncoded: false)) {
                resolved[index].coverURL = cover
            }
            let bookFile = booksDirectory.appending(path: resolved[index].fileName)
            resolved[index].bookFileExists = FileManager.default.fileExists(
                atPath: bookFile.path(percentEncoded: false)
            )
        }
        return resolved
    }

    static func compare(
        backup: LibraryTimeMachineSnapshot,
        currentBooks: [Book],
        currentCoversDirectory: URL = AppPaths.coversDirectory,
        currentBooksDirectory: URL = AppPaths.booksDirectory
    ) -> [LibraryTimeMachineBookDiff] {
        let currentSnapshots = currentBooks.map {
            let cover = currentCoversDirectory.appending(path: "\($0.uuid.uuidString).jpg")
            let coverExists = FileManager.default.fileExists(atPath: cover.path(percentEncoded: false))
            return LibraryTimeMachineSnapshotBuilder.makeBook(
                $0,
                coverURL: coverExists ? cover : nil,
                booksDirectory: currentBooksDirectory
            )
        }
        return compare(backupBooks: backup.books, currentBooks: currentSnapshots)
    }

    nonisolated static func compare(
        backupBooks: [LibraryTimeMachineBookSnapshot],
        currentBooks: [LibraryTimeMachineBookSnapshot]
    ) -> [LibraryTimeMachineBookDiff] {
        let backupByID = Dictionary(
            backupBooks.lazy.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let currentByID = Dictionary(
            currentBooks.lazy.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var diffs: [LibraryTimeMachineBookDiff] = []
        diffs.reserveCapacity(backupByID.count + currentByID.count)
        for (id, backup) in backupByID {
            diffs.append(makeDiff(id: id, backup: backup, current: currentByID[id]))
        }
        for (id, current) in currentByID where backupByID[id] == nil {
            diffs.append(makeDiff(id: id, backup: nil, current: current))
        }
        return diffs.sorted { lhs, rhs in
            if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
            let order = lhs.displayTitle.localizedStandardCompare(rhs.displayTitle)
            if order == .orderedSame { return lhs.id.uuidString < rhs.id.uuidString }
            return order == .orderedAscending
        }
    }

    private nonisolated static func makeDiff(
        id: UUID,
        backup: LibraryTimeMachineBookSnapshot?,
        current: LibraryTimeMachineBookSnapshot?
    ) -> LibraryTimeMachineBookDiff {
        guard let backup else {
            return LibraryTimeMachineBookDiff(
                id: id,
                kind: .addedSinceBackup,
                backup: nil,
                current: current,
                changeGroups: [],
                fieldChanges: []
            )
        }
        guard let current else {
            return LibraryTimeMachineBookDiff(
                id: id,
                kind: .deletedSinceBackup,
                backup: backup,
                current: nil,
                changeGroups: [],
                fieldChanges: []
            )
        }

        var groups: [LibraryTimeMachineChangeGroup] = []
        if metadataChanged(backup.metadata, current.metadata) { groups.append(.metadata) }
        if backup.reading != current.reading { groups.append(.readingHistory) }
        if backup.highlights != current.highlights { groups.append(.highlights) }
        if backup.collections.map(\.id) != current.collections.map(\.id) { groups.append(.collections) }
        if backup.hasCover != current.hasCover
            || (backup.hasCover && backup.coverVersion != current.coverVersion) {
            groups.append(.cover)
        }
        if backup.fileName != current.fileName
            || backup.originalFileName != current.originalFileName
            || backup.fileSizeBytes != current.fileSizeBytes
            || backup.assets != current.assets
            || backup.work != current.work {
            groups.append(.fileRecord)
        }

        let hasFieldChanges = groups.contains(.metadata) || groups.contains(.readingHistory)
        return LibraryTimeMachineBookDiff(
            id: id,
            kind: groups.isEmpty ? .unchanged : .modified,
            backup: backup,
            current: current,
            changeGroups: groups,
            fieldChanges: hasFieldChanges ? fieldChanges(backup: backup, current: current) : []
        )
    }

    private nonisolated static func fieldChanges(
        backup: LibraryTimeMachineBookSnapshot,
        current: LibraryTimeMachineBookSnapshot
    ) -> [LibraryTimeMachineFieldChange] {
        let pairs: [(LibraryTimeMachineField, LibraryTimeMachineFieldValue, LibraryTimeMachineFieldValue)] = [
            (.title, .text(current.metadata.title), .text(backup.metadata.title)),
            (.author, .text(current.metadata.author), .text(backup.metadata.author)),
            (.publisher, .text(current.metadata.publisher), .text(backup.metadata.publisher)),
            (.year, .text(current.metadata.year), .text(backup.metadata.year)),
            (.language, .text(current.metadata.language), .text(backup.metadata.language)),
            (.translator, .text(current.metadata.translator), .text(backup.metadata.translator)),
            (.isbn, .text(current.metadata.isbn), .text(backup.metadata.isbn)),
            (.series, .text(current.metadata.series), .text(backup.metadata.series)),
            (.seriesIndex, .text(current.metadata.seriesIndex), .text(backup.metadata.seriesIndex)),
            (.tags, .textList(current.metadata.tags), .textList(backup.metadata.tags)),
            (.bookDescription, .text(current.metadata.bookDescription), .text(backup.metadata.bookDescription)),
            (.rating, .integer(current.metadata.rating), .integer(backup.metadata.rating)),
            (.communityRating, .decimal(current.metadata.communityRating), .decimal(backup.metadata.communityRating)),
            (
                .communityRatingCount,
                .integer(current.metadata.communityRatingCount),
                .integer(backup.metadata.communityRatingCount)
            ),
            (
                .communityRatingSource,
                .text(current.metadata.communityRatingSource),
                .text(backup.metadata.communityRatingSource)
            ),
            (.pageCount, .integer(current.metadata.pageCount), .integer(backup.metadata.pageCount)),
            (.notes, .text(current.metadata.notes), .text(backup.metadata.notes)),
            (
                .readingStatus,
                .text(readingStatusLabel(current.reading.statusRaw)),
                .text(readingStatusLabel(backup.reading.statusRaw))
            ),
            (.dateStarted, .date(current.reading.dateStarted), .date(backup.reading.dateStarted)),
            (.dateFinished, .date(current.reading.dateFinished), .date(backup.reading.dateFinished)),
            (.editionStatement, .text(current.metadata.editionStatement), .text(backup.metadata.editionStatement)),
            (.editionType, .text(current.metadata.editionTypeRaw), .text(backup.metadata.editionTypeRaw)),
            (.drmProtected, .boolean(current.metadata.drmProtected), .boolean(backup.metadata.drmProtected)),
        ]
        return pairs.compactMap { field, currentValue, backupValue in
            guard currentValue != backupValue else { return nil }
            return LibraryTimeMachineFieldChange(field: field, current: currentValue, backup: backupValue)
        }
    }

    private nonisolated static func readingStatusLabel(_ rawValue: String?) -> String? {
        rawValue.flatMap(ReadingStatus.init(rawValue:))?.label
    }

    private nonisolated static func metadataChanged(
        _ lhs: LibraryTimeMachineMetadataSnapshot,
        _ rhs: LibraryTimeMachineMetadataSnapshot
    ) -> Bool {
        lhs.title != rhs.title
            || lhs.author != rhs.author
            || lhs.publisher != rhs.publisher
            || lhs.year != rhs.year
            || lhs.language != rhs.language
            || lhs.translator != rhs.translator
            || lhs.isbn != rhs.isbn
            || lhs.series != rhs.series
            || lhs.seriesIndex != rhs.seriesIndex
            || lhs.tags != rhs.tags
            || lhs.bookDescription != rhs.bookDescription
            || lhs.rating != rhs.rating
            || lhs.communityRating != rhs.communityRating
            || lhs.communityRatingCount != rhs.communityRatingCount
            || lhs.communityRatingSource != rhs.communityRatingSource
            || lhs.notes != rhs.notes
            || lhs.drmProtected != rhs.drmProtected
            || lhs.pageCount != rhs.pageCount
            || lhs.editionStatement != rhs.editionStatement
            || lhs.editionTypeRaw != rhs.editionTypeRaw
    }
}

private nonisolated enum LibraryTimeMachineSnapshotBuilder {
    static func makeBook(
        _ book: Book,
        coverURL: URL?,
        booksDirectory: URL,
        bookFileExists: Bool? = nil
    ) -> LibraryTimeMachineBookSnapshot {
        let sessions = book.readingSessions.map {
            LibraryTimeMachineReadingSessionSnapshot(
                id: $0.uuid,
                startedAt: $0.startedAt,
                endedAt: $0.endedAt,
                statusRaw: $0.statusRaw,
                progress: $0.progress
            )
        }
        .sorted {
            if $0.startedAt == $1.startedAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.startedAt < $1.startedAt
        }

        let highlights = book.highlights.map {
            LibraryTimeMachineHighlightSnapshot(
                text: $0.text,
                kindRaw: $0.kindRaw,
                location: $0.location,
                addedDate: $0.addedDate,
                dateImported: $0.dateImported
            )
        }
        .sorted {
            let lhsDate = $0.addedDate ?? $0.dateImported
            let rhsDate = $1.addedDate ?? $1.dateImported
            if lhsDate == rhsDate {
                let lhsKey = [
                    $0.text,
                    $0.kindRaw,
                    $0.location ?? "",
                    $0.dateImported.ISO8601Format(),
                ]
                let rhsKey = [
                    $1.text,
                    $1.kindRaw,
                    $1.location ?? "",
                    $1.dateImported.ISO8601Format(),
                ]
                return lhsKey.lexicographicallyPrecedes(rhsKey)
            }
            return lhsDate < rhsDate
        }

        let collections = book.collections.map {
            LibraryTimeMachineCollectionSnapshot(
                id: $0.id,
                name: $0.name,
                dateCreated: $0.dateCreated,
                savedSearch: $0.savedSearch,
                smartShelfRulesData: $0.smartShelfRulesData,
                systemKindRaw: $0.systemKindRaw
            )
        }
        .sorted { $0.id.uuidString < $1.id.uuidString }

        let assets = book.assets.map {
            LibraryTimeMachineAssetSnapshot(
                id: $0.uuid,
                fileName: $0.fileName,
                originRaw: $0.originRaw,
                contentHash: $0.contentHash,
                generatedFromContentHash: $0.generatedFromContentHash,
                sizeBytes: $0.sizeBytes,
                dateAdded: $0.dateAdded,
                validationStatusRaw: $0.validationStatusRaw
            )
        }
        .sorted { $0.id.uuidString < $1.id.uuidString }

        let work = book.work.map {
            LibraryTimeMachineWorkSnapshot(
                id: $0.uuid,
                title: $0.title,
                author: $0.author,
                originalTitle: $0.originalTitle,
                originalLanguage: $0.originalLanguage,
                openLibraryWorkKey: $0.openLibraryWorkKey,
                hardcoverBookID: $0.hardcoverBookID,
                preferredEditionUUID: $0.preferredEditionUUID,
                dateCreated: $0.dateCreated,
                notes: $0.notes
            )
        }

        let primaryFile = booksDirectory.appending(path: book.fileName)
        return LibraryTimeMachineBookSnapshot(
            id: book.uuid,
            fileName: book.fileName,
            originalFileName: book.originalFileName,
            dateAdded: book.dateAdded,
            fileSizeBytes: book.fileSizeBytes,
            coverVersion: book.coverVersion,
            metadata: LibraryTimeMachineMetadataSnapshot(
                title: book.title,
                author: book.author,
                publisher: book.publisher,
                year: book.year,
                language: book.language,
                translator: book.translator,
                isbn: book.isbn,
                series: book.series,
                seriesIndex: book.seriesIndex,
                tags: book.tags,
                bookDescription: book.bookDescription,
                rating: book.rating,
                communityRating: book.communityRating,
                communityRatingCount: book.communityRatingCount,
                communityRatingSource: book.communityRatingSource,
                onlineLookupAt: book.onlineLookupAt,
                onlineLookupConfiguration: book.onlineLookupConfiguration,
                notes: book.notes,
                drmProtected: book.drmProtected,
                pageCount: book.pageCount,
                sampleNoticeDismissed: book.sampleNoticeDismissed,
                editionStatement: book.editionStatement,
                editionTypeRaw: book.editionTypeRaw
            ),
            reading: LibraryTimeMachineReadingSnapshot(
                statusRaw: book.readingStatusRaw,
                dateStarted: book.dateStarted,
                dateFinished: book.dateFinished,
                sessions: sessions
            ),
            highlights: highlights,
            collections: collections,
            work: work,
            assets: assets,
            coverURL: coverURL,
            bookFileExists: bookFileExists ?? FileManager.default.fileExists(
                atPath: primaryFile.path(percentEncoded: false)
            )
        )
    }
}
