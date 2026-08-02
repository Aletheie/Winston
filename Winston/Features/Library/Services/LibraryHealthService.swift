import Foundation
import OSLog
import SwiftData

nonisolated enum LibraryIntegrityIssueCategory: String, CaseIterable, Sendable {
    case catalog
    case files
    case recovery
}

nonisolated enum LibraryIntegrityIssueSeverity: Int, Sendable {
    case warning
    case error
}

nonisolated struct LibraryIntegrityIssue: Identifiable, Sendable, Equatable {
    let id: String
    let category: LibraryIntegrityIssueCategory
    let severity: LibraryIntegrityIssueSeverity
    let title: String
    let detail: String
    let bookID: UUID?
    let workID: UUID?
    let assetID: UUID?
    let transactionID: UUID?
    let isAutomaticallyRepairable: Bool
}

nonisolated struct LibraryIntegrityReport: Sendable, Equatable {
    let scannedAt: Date
    let bookCount: Int
    let workCount: Int
    let assetCount: Int
    let metadataSuggestionCount: Int
    let issues: [LibraryIntegrityIssue]

    var catalogIssueCount: Int {
        issues.count { $0.category == .catalog }
    }

    var fileIssueCount: Int {
        issues.count { $0.category == .files }
    }

    var recoveryIssueCount: Int {
        issues.count { $0.category == .recovery }
    }

    var repairableBookIDs: Set<UUID> {
        Set(issues.compactMap {
            $0.category == .catalog && $0.isAutomaticallyRepairable
                ? $0.bookID
                : nil
        })
    }

    var repairableWorkIDs: Set<UUID> {
        Set(issues.compactMap {
            $0.category == .catalog && $0.isAutomaticallyRepairable
                ? $0.workID
                : nil
        })
    }

    var hasRepairableCatalogIssues: Bool {
        !repairableBookIDs.isEmpty || !repairableWorkIDs.isEmpty
    }
}

nonisolated struct LibraryIntegrityRepairResult: Sendable, Equatable {
    let repairedBookCount: Int
    let repairedWorkCount: Int
}

nonisolated private struct LibraryIntegrityFileInput: Sendable {
    let id: String
    let bookID: UUID?
    let assetID: UUID?
    let title: String
    let fileName: String
    let isPrimary: Bool
}

nonisolated private enum LibraryIntegrityFileFailure: Sendable {
    case missing
    case unreadable
}

nonisolated private struct LibraryIntegrityFileIssue: Sendable {
    let input: LibraryIntegrityFileInput
    let failure: LibraryIntegrityFileFailure
}

@MainActor
@Observable
final class LibraryHealthService {
    private let modelContext: ModelContext
    private let analysisCoordinator: CatalogAnalysisCoordinator
    private let mutations: CatalogMutationService
    private let managedFiles: ManagedFileCoordinator
    private(set) var missingFileUUIDs: Set<UUID> = []
    private(set) var lastCatalogReadFailed = false
    private var cachedMetadataAnalysis: MetadataFixAnalysis?
    private var cachedMetadataAnalysisRevision = -1
    private var metadataAnalysisTask: (revision: Int, task: Task<MetadataFixAnalysis, Never>)?
    private(set) var metadataCleanupProgress: MetadataCleanupProgress?
    private(set) var lastMetadataCleanupResult: MetadataCleanupApplyResult?
    private var cachedCleanupAnalysis: MetadataCleanupAnalysis?
    private var cachedCleanupAnalysisRevision = -1
    private var metadataCleanupTask: Task<MetadataCleanupAnalysis, Never>?
    private var metadataCleanupGeneration = UUID()
    private var metadataCleanupUndoChanges: [MetadataCleanupChange] = []

    init(
        modelContext: ModelContext,
        analysisCoordinator: CatalogAnalysisCoordinator = CatalogAnalysisCoordinator(),
        mutations: CatalogMutationService? = nil,
        managedFiles: ManagedFileCoordinator = .shared
    ) {
        self.modelContext = modelContext
        let resolvedMutations = mutations ?? CatalogMutationService(
            modelContext: modelContext,
            managedFiles: managedFiles,
            analysisCoordinator: analysisCoordinator
        )
        self.analysisCoordinator = resolvedMutations.analysisCoordinator
        self.mutations = resolvedMutations
        self.managedFiles = managedFiles
    }

    func isMissing(_ book: Book) -> Bool { missingFileUUIDs.contains(book.uuid) }

    func metadataFixes() async -> [MetadataFix] {
        await metadataAnalysis().fixes
    }

    func seriesSuggestions() async -> [String] {
        await metadataAnalysis().seriesSuggestions
    }

    var canUndoMetadataCleanup: Bool {
        !metadataCleanupUndoChanges.isEmpty
    }

    func metadataCleanup(
        scope: MetadataCleanupScope
    ) async -> MetadataCleanupAnalysis {
        let revision = LibraryMutationLog.shared.catalogRevision
        if scope == .wholeLibrary,
           cachedCleanupAnalysisRevision == revision,
           let cachedCleanupAnalysis {
            return cachedCleanupAnalysis
        }

        metadataCleanupTask?.cancel()
        let books: [Book]
        do {
            switch scope {
            case .wholeLibrary:
                books = try modelContext.fetchAllBooksForGlobalAnalysis()
            case .books(let ids, _):
                books = try mutations.books(ids: ids)
            }
            lastCatalogReadFailed = false
        } catch {
            lastCatalogReadFailed = true
            Log.persistence.error(
                "Metadata cleanup could not read its scope: \(error.localizedDescription, privacy: .public)"
            )
            return MetadataCleanupAnalysis(
                scope: scope,
                scannedBookCount: 0,
                groups: []
            )
        }

        metadataCleanupProgress = MetadataCleanupProgress(
            completedCount: 0,
            totalCount: books.count
        )
        var rows: [MetadataFixRow] = []
        rows.reserveCapacity(books.count)
        for (index, book) in books.enumerated() {
            guard !Task.isCancelled else {
                metadataCleanupProgress = nil
                return MetadataCleanupAnalysis(
                    scope: scope,
                    scannedBookCount: 0,
                    groups: []
                )
            }
            rows.append(Self.metadataFixRow(book))
            if index.isMultiple(of: 128) || index == books.count - 1 {
                metadataCleanupProgress = MetadataCleanupProgress(
                    completedCount: index + 1,
                    totalCount: books.count
                )
                await Task.yield()
            }
        }

        let snapshot = rows
        let generation = UUID()
        metadataCleanupGeneration = generation
        let task = Task {
            await Self.computeMetadataCleanup(rows: snapshot, scope: scope)
        }
        metadataCleanupTask = task
        let analysis = await task.value
        if metadataCleanupGeneration == generation {
            metadataCleanupTask = nil
        }
        guard metadataCleanupGeneration == generation else { return analysis }
        metadataCleanupProgress = nil
        guard !Task.isCancelled else { return analysis }
        if scope == .wholeLibrary,
           LibraryMutationLog.shared.catalogRevision == revision {
            cachedCleanupAnalysis = analysis
            cachedCleanupAnalysisRevision = revision
        }
        return analysis
    }

    func cancelMetadataCleanupAnalysis() {
        metadataCleanupTask?.cancel()
        metadataCleanupTask = nil
        metadataCleanupGeneration = UUID()
        metadataCleanupProgress = nil
    }

    func applyMetadataCleanup(
        _ changes: [MetadataCleanupChange]
    ) -> Result<MetadataCleanupApplyResult, CatalogMutationError> {
        let result = mutations.applyMetadataCleanup(changes)
        if case .success(let applied) = result {
            lastMetadataCleanupResult = applied
            metadataCleanupUndoChanges = applied.appliedChanges.map(\.inverse)
            cachedCleanupAnalysis = nil
            cachedCleanupAnalysisRevision = -1
        }
        return result
    }

    func undoLastMetadataCleanup()
        -> Result<MetadataCleanupApplyResult, CatalogMutationError> {
        guard !metadataCleanupUndoChanges.isEmpty else {
            return .success(MetadataCleanupApplyResult(
                requestedChangeCount: 0,
                appliedChanges: [],
                conflicts: [],
                missingBookIDs: []
            ))
        }
        let inverse = metadataCleanupUndoChanges
        let result = mutations.applyMetadataCleanup(
            inverse,
            operation: "metadataCleanupUndo"
        )
        if case .success(let undone) = result {
            lastMetadataCleanupResult = undone
            metadataCleanupUndoChanges = undone.conflicts.map(\.change)
            cachedCleanupAnalysis = nil
            cachedCleanupAnalysisRevision = -1
        }
        return result
    }

    /// Explicit full-library diagnostic. All SwiftData models are reduced to
    /// Sendable values before filesystem and journal inspection suspend.
    func integrityReport() async throws -> LibraryIntegrityReport {
        while true {
            guard !modelContext.hasChanges else {
                throw MaintenanceSchedulerError.dirtyContext
            }
            let revision = LibraryMutationLog.shared.catalogRevision
            let books: [Book]
            let works: [Work]
            let assets: [BookAsset]
            do {
                var bookDescriptor = FetchDescriptor<Book>(
                    sortBy: [
                        SortDescriptor(\Book.dateAdded),
                        SortDescriptor(\Book.uuid),
                    ]
                )
                bookDescriptor.relationshipKeyPathsForPrefetching = [
                    \Book.assets,
                    \Book.work,
                ]
                var workDescriptor = FetchDescriptor<Work>(
                    sortBy: [SortDescriptor(\Work.uuid)]
                )
                workDescriptor.relationshipKeyPathsForPrefetching = [\Work.editions]
                var assetDescriptor = FetchDescriptor<BookAsset>(
                    sortBy: [SortDescriptor(\BookAsset.uuid)]
                )
                assetDescriptor.relationshipKeyPathsForPrefetching = [\BookAsset.book]
                books = try modelContext.fetch(bookDescriptor)
                works = try modelContext.fetch(workDescriptor)
                assets = try modelContext.fetch(assetDescriptor)
                lastCatalogReadFailed = false
            } catch {
                lastCatalogReadFailed = true
                Log.persistence.error(
                    "Library integrity scan failed to read the catalog: \(error.localizedDescription, privacy: .public)"
                )
                throw error
            }

            var issues: [LibraryIntegrityIssue] = []
            var fileInputs: [LibraryIntegrityFileInput] = []
            var metadataRows: [MetadataFixRow] = []
            let titlesByBookID = Dictionary(uniqueKeysWithValues:
                books.map { ($0.uuid, $0.displayTitle) }
            )

            issues.reserveCapacity(books.count / 8)
            fileInputs.reserveCapacity(assets.count + books.count)
            metadataRows.reserveCapacity(books.count)

            for (index, book) in books.enumerated() {
                try Task.checkCancellation()
                metadataRows.append(Self.metadataFixRow(book))

                if book.work == nil {
                    issues.append(LibraryIntegrityIssue(
                        id: "catalog:book:\(book.uuid.uuidString):missing-work",
                        category: .catalog,
                        severity: .warning,
                        title: book.displayTitle,
                        detail: String(localized: "This edition is not attached to a bibliographic work."),
                        bookID: book.uuid,
                        workID: nil,
                        assetID: nil,
                        transactionID: nil,
                        isAutomaticallyRepairable: true
                    ))
                }
                for violation in CatalogModelInvariantService.violations(in: book) {
                    issues.append(Self.issue(for: violation, book: book))
                }

                if let rawLanguage = book.language,
                   !rawLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   MetadataNormalizer.language(rawLanguage).status == .unrecognized {
                    issues.append(LibraryIntegrityIssue(
                        id: "catalog:book:\(book.uuid.uuidString):unrecognized-language",
                        category: .catalog,
                        severity: .warning,
                        title: book.displayTitle,
                        detail: String(
                            localized: "Language metadata is unrecognized: \(rawLanguage)"
                        ),
                        bookID: book.uuid,
                        workID: book.work?.uuid,
                        assetID: nil,
                        transactionID: nil,
                        isAutomaticallyRepairable: false
                    ))
                }
                if let rawISBN = book.isbn,
                   MetadataNormalizer.isbn(rawISBN).status == .invalid {
                    issues.append(LibraryIntegrityIssue(
                        id: "catalog:book:\(book.uuid.uuidString):invalid-isbn",
                        category: .catalog,
                        severity: .warning,
                        title: book.displayTitle,
                        detail: String(
                            localized: "ISBN metadata has an invalid checksum: \(rawISBN)"
                        ),
                        bookID: book.uuid,
                        workID: book.work?.uuid,
                        assetID: nil,
                        transactionID: nil,
                        isAutomaticallyRepairable: false
                    ))
                }

                if book.assets.isEmpty,
                   !book.fileName.isEmpty {
                    if ManagedLeafName(rawValue: book.fileName) == nil {
                        issues.append(Self.unsafeFileNameIssue(
                            id: "legacy-\(book.uuid.uuidString)",
                            bookID: book.uuid,
                            assetID: nil,
                            title: book.displayTitle,
                            fileName: book.fileName
                        ))
                    } else {
                        fileInputs.append(LibraryIntegrityFileInput(
                            id: "legacy-\(book.uuid.uuidString)",
                            bookID: book.uuid,
                            assetID: nil,
                            title: book.displayTitle,
                            fileName: book.fileName,
                            isPrimary: true
                        ))
                    }
                }
                if index > 0, index.isMultiple(of: 256) {
                    await Task.yield()
                }
            }

            for (index, asset) in assets.enumerated() {
                try Task.checkCancellation()
                let bookID = asset.book?.uuid
                let title = bookID.flatMap { titlesByBookID[$0] }
                    ?? String(localized: "Unattached book file")
                if bookID == nil {
                    issues.append(LibraryIntegrityIssue(
                        id: "catalog:asset:\(asset.uuid.uuidString):orphan",
                        category: .catalog,
                        severity: .warning,
                        title: title,
                        detail: String(localized: "A catalog file record is not attached to an edition."),
                        bookID: nil,
                        workID: nil,
                        assetID: asset.uuid,
                        transactionID: nil,
                        isAutomaticallyRepairable: false
                    ))
                }
                if ManagedLeafName(rawValue: asset.fileName) == nil {
                    issues.append(Self.unsafeFileNameIssue(
                        id: "asset-\(asset.uuid.uuidString)",
                        bookID: bookID,
                        assetID: asset.uuid,
                        title: title,
                        fileName: asset.fileName
                    ))
                } else {
                    fileInputs.append(LibraryIntegrityFileInput(
                        id: "asset-\(asset.uuid.uuidString)",
                        bookID: bookID,
                        assetID: asset.uuid,
                        title: title,
                        fileName: asset.fileName,
                        isPrimary: asset.book?.primaryAsset?.uuid == asset.uuid
                    ))
                }
                if index > 0, index.isMultiple(of: 256) {
                    await Task.yield()
                }
            }

            for (index, work) in works.enumerated() {
                try Task.checkCancellation()
                if work.editions.isEmpty {
                    issues.append(LibraryIntegrityIssue(
                        id: "catalog:work:\(work.uuid.uuidString):orphan",
                        category: .catalog,
                        severity: .warning,
                        title: work.displayTitle,
                        detail: String(localized: "This work has no editions. It is retained for manual review."),
                        bookID: nil,
                        workID: work.uuid,
                        assetID: nil,
                        transactionID: nil,
                        isAutomaticallyRepairable: false
                    ))
                }
                for violation in WorkService.violations(in: work) {
                    issues.append(Self.issue(for: violation, work: work))
                }
                if index > 0, index.isMultiple(of: 256) {
                    await Task.yield()
                }
            }

            async let fileIssues = Self.inspectFiles(fileInputs)
            async let pendingInspection = managedFiles.inspectPendingTransactions()
            async let metadata = Self.computeMetadataAnalysis(rows: metadataRows)
            let (resolvedFileIssues, resolvedPending, resolvedMetadata) =
                try await (fileIssues, pendingInspection, metadata)
            try Task.checkCancellation()
            guard revision == LibraryMutationLog.shared.catalogRevision else {
                continue
            }

            let primaryMissingBookIDs = Set(resolvedFileIssues.compactMap {
                $0.input.isPrimary ? $0.input.bookID : nil
            })
            missingFileUUIDs = primaryMissingBookIDs
            for fileIssue in resolvedFileIssues {
                let failureLabel: String
                let severity: LibraryIntegrityIssueSeverity
                switch fileIssue.failure {
                case .missing:
                    failureLabel = String(localized: "The managed file is missing: \(fileIssue.input.fileName)")
                    severity = .error
                case .unreadable:
                    failureLabel = String(localized: "The managed file cannot be read: \(fileIssue.input.fileName)")
                    severity = .error
                }
                issues.append(LibraryIntegrityIssue(
                    id: "files:\(fileIssue.input.id)",
                    category: .files,
                    severity: severity,
                    title: fileIssue.input.title,
                    detail: failureLabel,
                    bookID: fileIssue.input.bookID,
                    workID: nil,
                    assetID: fileIssue.input.assetID,
                    transactionID: nil,
                    isAutomaticallyRepairable: false
                ))
            }

            for item in resolvedPending.items {
                issues.append(LibraryIntegrityIssue(
                    id: "recovery:\(item.id.uuidString)",
                    category: .recovery,
                    severity: .warning,
                    title: Self.label(for: item.intent),
                    detail: String(
                        localized: "\(item.stagedFileCount) staged files and \(item.cleanupCount) cleanups are waiting for reconciliation."
                    ),
                    bookID: nil,
                    workID: nil,
                    assetID: nil,
                    transactionID: item.id,
                    isAutomaticallyRepairable: false
                ))
            }
            for (index, url) in resolvedPending.unreadableJournalURLs.enumerated() {
                let detail = resolvedPending.failureMessages.indices.contains(index)
                    ? resolvedPending.failureMessages[index]
                    : String(localized: "The recovery journal could not be decoded.")
                issues.append(LibraryIntegrityIssue(
                    id: "recovery:unreadable:\(url.lastPathComponent)",
                    category: .recovery,
                    severity: .error,
                    title: String(localized: "Unreadable recovery journal"),
                    detail: "\(url.lastPathComponent): \(detail)",
                    bookID: nil,
                    workID: nil,
                    assetID: nil,
                    transactionID: nil,
                    isAutomaticallyRepairable: false
                ))
            }

            issues.sort(by: Self.issuePrecedes)
            cachedMetadataAnalysis = resolvedMetadata
            cachedMetadataAnalysisRevision = revision
            return LibraryIntegrityReport(
                scannedAt: .now,
                bookCount: books.count,
                workCount: works.count,
                assetCount: assets.count,
                metadataSuggestionCount: resolvedMetadata.fixes.count,
                issues: issues
            )
        }
    }

    /// Safe repairs are committed in bounded store-scoped transactions. A
    /// later chunk failure never rolls back an earlier durable chunk.
    func repairCatalogInvariants(
        from report: LibraryIntegrityReport,
        chunkSize: Int = 64
    ) async throws -> LibraryIntegrityRepairResult {
        let boundedChunkSize = max(1, chunkSize)
        let bookIDs = report.repairableBookIDs.sorted {
            $0.uuidString < $1.uuidString
        }
        let workIDs = report.repairableWorkIDs.sorted {
            $0.uuidString < $1.uuidString
        }
        var repairedBooks = 0
        var repairedWorks = 0

        for start in stride(from: 0, to: bookIDs.count, by: boundedChunkSize) {
            try Task.checkCancellation()
            let end = min(start + boundedChunkSize, bookIDs.count)
            let chunk = Set(bookIDs[start..<end])
            _ = try mutations.repairCatalogInvariants(
                bookIDs: chunk,
                workIDs: []
            )
            repairedBooks += chunk.count
            await Task.yield()
        }
        for start in stride(from: 0, to: workIDs.count, by: boundedChunkSize) {
            try Task.checkCancellation()
            let end = min(start + boundedChunkSize, workIDs.count)
            let chunk = Set(workIDs[start..<end])
            _ = try mutations.repairCatalogInvariants(
                bookIDs: [],
                workIDs: chunk
            )
            repairedWorks += chunk.count
            await Task.yield()
        }
        cachedMetadataAnalysis = nil
        cachedMetadataAnalysisRevision = -1
        return LibraryIntegrityRepairResult(
            repairedBookCount: repairedBooks,
            repairedWorkCount: repairedWorks
        )
    }

    @concurrent
    private static func inspectFiles(
        _ inputs: [LibraryIntegrityFileInput]
    ) async throws -> [LibraryIntegrityFileIssue] {
        var issues: [LibraryIntegrityFileIssue] = []
        issues.reserveCapacity(inputs.count / 8)
        for input in inputs {
            try Task.checkCancellation()
            let url = BookFileStore.url(for: input.fileName)
            let path = url.path(percentEncoded: false)
            if !FileManager.default.fileExists(atPath: path) {
                issues.append(LibraryIntegrityFileIssue(
                    input: input,
                    failure: .missing
                ))
            } else if !FileManager.default.isReadableFile(atPath: path) {
                issues.append(LibraryIntegrityFileIssue(
                    input: input,
                    failure: .unreadable
                ))
            }
        }
        return issues
    }

    private static func issue(
        for violation: CatalogModelInvariantViolation,
        book: Book
    ) -> LibraryIntegrityIssue {
        let key: String
        let detail: String
        let assetID: UUID?
        switch violation {
        case .missingPrimaryAsset:
            key = "missing-primary"
            detail = String(localized: "No primary file is selected for this edition.")
            assetID = nil
        case .danglingPrimaryAsset(let id):
            key = "dangling-primary-\(id.uuidString)"
            detail = String(localized: "The selected primary file no longer belongs to this edition.")
            assetID = id
        case .assetBelongsToAnotherEdition(let id):
            key = "foreign-asset-\(id.uuidString)"
            detail = String(localized: "A file relationship points to another edition.")
            assetID = id
        case .staleAssetFormat(let id, let expected):
            key = "stale-format-\(id.uuidString)"
            detail = String(localized: "A file format mirror should be \(expected).")
            assetID = id
        case .missingAssetProvenance(let id):
            key = "missing-provenance-\(id.uuidString)"
            detail = String(localized: "A file is missing its import provenance.")
            assetID = id
        case .inconsistentAssetAvailability(let id):
            key = "availability-\(id.uuidString)"
            detail = String(localized: "File availability conflicts with its validation status.")
            assetID = id
        case .primaryFileNameMirror:
            key = "primary-name-mirror"
            detail = String(localized: "The edition filename mirror differs from its primary file.")
            assetID = book.primaryAssetUUID
        case .primarySizeMirror:
            key = "primary-size-mirror"
            detail = String(localized: "The edition size mirror differs from its primary file.")
            assetID = book.primaryAssetUUID
        case .primaryDRMMirror:
            key = "primary-drm-mirror"
            detail = String(localized: "The edition DRM mirror differs from its primary file.")
            assetID = book.primaryAssetUUID
        case .missingCoverScope:
            key = "missing-cover-scope"
            detail = String(localized: "The cover does not have an explicit owner scope.")
            assetID = nil
        case .invalidCoverOwner:
            key = "invalid-cover-owner"
            detail = String(localized: "The selected cover owner is not valid for this edition.")
            assetID = book.coverAssetUUID
        }
        return LibraryIntegrityIssue(
            id: "catalog:book:\(book.uuid.uuidString):\(key)",
            category: .catalog,
            severity: .warning,
            title: book.displayTitle,
            detail: detail,
            bookID: book.uuid,
            workID: book.work?.uuid,
            assetID: assetID,
            transactionID: nil,
            isAutomaticallyRepairable: true
        )
    }

    private static func issue(
        for violation: CatalogWorkInvariantViolation,
        work: Work
    ) -> LibraryIntegrityIssue {
        let key: String
        let detail: String
        let bookID: UUID?
        switch violation {
        case .staleMatchKey:
            key = "stale-match-key"
            detail = String(localized: "The work identity key does not match its title and author.")
            bookID = nil
        case .danglingPreferredEdition(let id):
            key = "dangling-preferred-\(id.uuidString)"
            detail = String(localized: "The preferred edition no longer belongs to this work.")
            bookID = id
        case .editionPointsToAnotherWork(let id):
            key = "foreign-edition-\(id.uuidString)"
            detail = String(localized: "An inverse edition relationship points to another work.")
            bookID = id
        }
        return LibraryIntegrityIssue(
            id: "catalog:work:\(work.uuid.uuidString):\(key)",
            category: .catalog,
            severity: .warning,
            title: work.displayTitle,
            detail: detail,
            bookID: bookID,
            workID: work.uuid,
            assetID: nil,
            transactionID: nil,
            isAutomaticallyRepairable: true
        )
    }

    private static func unsafeFileNameIssue(
        id: String,
        bookID: UUID?,
        assetID: UUID?,
        title: String,
        fileName: String
    ) -> LibraryIntegrityIssue {
        LibraryIntegrityIssue(
            id: "catalog:unsafe-file:\(id)",
            category: .catalog,
            severity: .error,
            title: title,
            detail: String(localized: "The managed filename is unsafe and needs manual review: \(fileName)"),
            bookID: bookID,
            workID: nil,
            assetID: assetID,
            transactionID: nil,
            isAutomaticallyRepairable: false
        )
    }

    private static func issuePrecedes(
        _ lhs: LibraryIntegrityIssue,
        _ rhs: LibraryIntegrityIssue
    ) -> Bool {
        if lhs.severity != rhs.severity {
            return lhs.severity.rawValue > rhs.severity.rawValue
        }
        if lhs.category != rhs.category {
            return lhs.category.rawValue < rhs.category.rawValue
        }
        let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
        if titleOrder != .orderedSame {
            return titleOrder == .orderedAscending
        }
        return lhs.id < rhs.id
    }

    private static func label(for intent: ManagedFileIntent) -> String {
        switch intent {
        case .importBook:
            String(localized: "Book import awaiting recovery")
        case .replaceBookFile:
            String(localized: "Replacement file awaiting recovery")
        case .conversionOutput:
            String(localized: "Conversion output awaiting recovery")
        case .deleteBook, .deleteBookFile:
            String(localized: "File cleanup awaiting recovery")
        case .calibreImport:
            String(localized: "Calibre import awaiting recovery")
        case .legacyMigration:
            String(localized: "Library migration awaiting recovery")
        case .coverUpdate:
            String(localized: "Cover update awaiting recovery")
        case .restore:
            String(localized: "Library restore awaiting recovery")
        }
    }

    private func metadataAnalysis() async -> MetadataFixAnalysis {
        while true {
            let revision = LibraryMutationLog.shared.catalogRevision
            if cachedMetadataAnalysisRevision == revision, let cachedMetadataAnalysis {
                return cachedMetadataAnalysis
            }

            let task: Task<MetadataFixAnalysis, Never>
            if let inFlight = metadataAnalysisTask, inFlight.revision == revision {
                task = inFlight.task
            } else {
                let books: [Book]
                do {
                    books = try modelContext.fetchAllBooksForGlobalAnalysis()
                    lastCatalogReadFailed = false
                } catch {
                    lastCatalogReadFailed = true
                    Log.persistence.error(
                        "Metadata analysis retained its previous result because the catalog fetch failed: \(error.localizedDescription, privacy: .public)"
                    )
                    return cachedMetadataAnalysis
                        ?? MetadataFixAnalysis(fixes: [], seriesSuggestions: [])
                }
                var rows: [MetadataFixRow] = []
                rows.reserveCapacity(books.count)
                for (index, book) in books.enumerated() {
                    guard !Task.isCancelled else { return MetadataFixAnalysis(fixes: [], seriesSuggestions: []) }
                    rows.append(Self.metadataFixRow(book))
                    if index > 0, index.isMultiple(of: 128) { await Task.yield() }
                }
                let snapshotRows = rows
                task = Task { await Self.computeMetadataAnalysis(rows: snapshotRows) }
                metadataAnalysisTask = (revision, task)
            }

            let analysis = await task.value
            if metadataAnalysisTask?.revision == revision {
                metadataAnalysisTask = nil
            }
            guard LibraryMutationLog.shared.catalogRevision == revision else { continue }

            cachedMetadataAnalysis = analysis
            cachedMetadataAnalysisRevision = revision
            return analysis
        }
    }

    @concurrent
    private static func computeMetadataAnalysis(rows: [MetadataFixRow]) async -> MetadataFixAnalysis {
        MetadataFixFinder.analysis(rows: rows)
    }

    @concurrent
    private static func computeMetadataCleanup(
        rows: [MetadataFixRow],
        scope: MetadataCleanupScope
    ) async -> MetadataCleanupAnalysis {
        guard !Task.isCancelled else {
            return MetadataCleanupAnalysis(
                scope: scope,
                scannedBookCount: 0,
                groups: []
            )
        }
        return MetadataCleanupFinder.analysis(rows: rows, scope: scope)
    }

    private static func metadataFixRow(_ book: Book) -> MetadataFixRow {
        MetadataFixRow(
            bookID: book.uuid,
            title: book.title ?? book.displayTitle,
            storedTitle: book.title,
            originalFileName: book.originalFileName,
            author: book.author ?? book.displayAuthor,
            storedAuthor: book.author,
            publisher: book.publisher,
            language: book.language,
            isbn: book.isbn,
            series: book.series,
            seriesIndex: book.seriesIndex,
            tags: book.tags
        )
    }

    @discardableResult
    func scanForMissingFiles() async -> Int {
        let books: [Book]
        let assets: [BookAsset]
        do {
            books = try modelContext.fetchAllBooksForGlobalAnalysis()
            assets = try modelContext.fetch(FetchDescriptor<BookAsset>())
            lastCatalogReadFailed = false
        } catch {
            lastCatalogReadFailed = true
            Log.persistence.error(
                "Missing-file scan retained its previous result because the catalog fetch failed: \(error.localizedDescription, privacy: .public)"
            )
            return missingFileUUIDs.count
        }
        var primaryEntries: [(uuid: UUID, fileName: String)] = []
        primaryEntries.reserveCapacity(books.count)
        for (index, book) in books.enumerated() {
            guard !Task.isCancelled else { return 0 }
            let primaryFileName = book.primaryAsset?.fileName ?? book.fileName
            if !primaryFileName.isEmpty {
                primaryEntries.append((book.uuid, primaryFileName))
            }
            if let primaryAsset = book.primaryAsset,
               book.fileName != primaryAsset.fileName
                    || book.primaryAssetUUID != primaryAsset.uuid {
                Log.persistence.error(
                    "Primary asset invariant drift for book \(book.uuid.uuidString, privacy: .public)"
                )
            }
            if index > 0, index.isMultiple(of: 256) { await Task.yield() }
        }
        var assetEntries: [(uuid: UUID, fileName: String)] = []
        assetEntries.reserveCapacity(assets.count)
        for (index, asset) in assets.enumerated() {
            guard !Task.isCancelled else { return 0 }
            assetEntries.append((asset.uuid, asset.fileName))
            if index > 0, index.isMultiple(of: 256) { await Task.yield() }
        }
        let result = await Task.detached(priority: .utility) {
            var missingBooks: Set<UUID> = []
            var assetStatus: [UUID: AssetValidation] = [:]
            for entry in primaryEntries {
                let path = BookFileStore.url(for: entry.fileName).path(percentEncoded: false)
                if !FileManager.default.fileExists(atPath: path) { missingBooks.insert(entry.uuid) }
            }
            for entry in assetEntries {
                let path = BookFileStore.url(for: entry.fileName).path(percentEncoded: false)
                assetStatus[entry.uuid] = FileManager.default.fileExists(atPath: path) ? .ok : .missing
            }
            return (missingBooks, assetStatus)
        }.value
        missingFileUUIDs = result.0
        var updates: [CatalogAssetValidationUpdate] = []
        updates.reserveCapacity(assets.count)
        for (index, asset) in assets.enumerated() {
            // The yields below let deletions interleave; a removed asset must not be written to.
            guard asset.modelContext != nil, let status = result.1[asset.uuid] else { continue }
            let updatedStatus: AssetValidation?
            if status == .missing {
                updatedStatus = asset.validationStatus == .missing ? nil : .missing
            } else if asset.validationStatus == nil || asset.validationStatus == .missing {
                updatedStatus = .ok
            } else {
                updatedStatus = nil
            }
            if let updatedStatus {
                updates.append(CatalogAssetValidationUpdate(
                    assetID: asset.uuid,
                    expectedFileName: asset.fileName,
                    expectedDateAdded: asset.dateAdded,
                    validation: updatedStatus
                ))
            }
            if index > 0, index.isMultiple(of: 256) { await Task.yield() }
        }
        if !updates.isEmpty {
            _ = mutations.execute(.updateAssetValidations(updates))
        }
        return result.0.count
    }

    func relink(_ book: Book, from url: URL) async {
        guard book.modelContext != nil else { return }
        let asset = book.primaryAsset
        let bookID = book.uuid
        let primaryAssetID = asset?.uuid
        let primaryAssetDateAdded = asset?.dateAdded
        let oldFileName = asset?.fileName ?? book.fileName
        let replacementUUID = asset?.uuid ?? bookID
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let previousIdentity: ManagedFileIdentitySnapshot
        let source: ManagedFileSource
        do {
            previousIdentity = try await managedFiles.captureIdentity(
                of: .book(oldFileName)
            )
            source = try .book(
                sourceURL: url,
                destination: .replacement(
                    assetID: replacementUUID,
                    previous: previousIdentity
                )
            )
        } catch {
            return
        }
        let fileName = source.finalRelativeName
        let transaction: ManagedFileTransaction
        do {
            transaction = try await managedFiles.stage(
                intent: .replaceBookFile,
                sources: [source],
                requirement: ManagedFileRequirement(
                    presentBookIDs: [bookID],
                    referencedBookFileNames: [fileName],
                    unreferencedBookFileNames: [oldFileName]
                ),
                cleanups: [.file(previousIdentity)]
            )
        } catch {
            return
        }
        guard let staged = transaction.files.first else {
            await managedFiles.abort(transaction)
            return
        }
        let primaryIsCurrent = if let primaryAssetID {
            book.primaryAsset?.uuid == primaryAssetID
                && book.primaryAsset?.fileName == oldFileName
                && book.primaryAsset?.dateAdded == primaryAssetDateAdded
        } else {
            book.assets.isEmpty && book.fileName == oldFileName
        }
        guard book.modelContext != nil,
              primaryIsCurrent else {
            await managedFiles.abort(transaction)
            return
        }
        let drmProtected = await Task.detached(priority: .utility) {
            DRMDetector.isProtected(url: staged.stagedURL)
        }.value
        let replacementDate = Date()
        let updatedAssetID = primaryAssetID ?? bookID
        let bookPreimage = CatalogBookMetadataPreimage(book)
        let assetPreimage = asset.map(CatalogBookAssetPreimage.init)
        var insertedAsset: BookAsset?
        do {
            _ = try await mutations.commitFileMutation(
                primaryAssetID == nil
                    ? .addFile(bookID: bookID, assetID: updatedAssetID)
                    : .replaceFile(bookID: bookID, assetID: updatedAssetID),
                transaction: transaction,
                affectedBookIDs: [bookID],
                revertingOnFailure: {
                    bookPreimage.restore()
                    assetPreimage?.restore()
                    if let insertedAsset, insertedAsset.modelContext != nil {
                        self.modelContext.delete(insertedAsset)
                    }
                }
            ) {
                let storedBook = try self.mutations.book(id: bookID)
                let sourceIsCurrent = if let primaryAssetID {
                    storedBook.primaryAsset?.uuid == primaryAssetID
                        && storedBook.primaryAsset?.fileName == oldFileName
                        && storedBook.primaryAsset?.dateAdded == primaryAssetDateAdded
                } else {
                    storedBook.assets.isEmpty && storedBook.fileName == oldFileName
                }
                guard sourceIsCurrent else {
                    throw CatalogMutationError.staleGeneration
                }

                storedBook.fileName = fileName
                storedBook.fileSizeBytes = staged.byteCount
                storedBook.drmProtected = drmProtected

                let updatedAsset: BookAsset
                if let primaryAssetID,
                   let storedAsset = storedBook.assets.first(where: { $0.uuid == primaryAssetID }) {
                    storedAsset.fileName = fileName
                    storedAsset.sizeBytes = staged.byteCount
                    storedAsset.contentHash = staged.sha256
                    storedAsset.generatedFromContentHash = nil
                    storedAsset.origin = .imported
                    storedAsset.sourceProvenance = .manualFile
                    storedAsset.sourceIdentifier = nil
                    storedAsset.drmProtected = drmProtected
                    storedAsset.validationStatus = .ok
                    storedAsset.availability = .available
                    storedAsset.dateAdded = replacementDate
                    updatedAsset = storedAsset
                } else {
                    let storedAsset = BookAsset(
                        uuid: updatedAssetID,
                        fileName: fileName,
                        origin: .original,
                        sourceProvenance: .manualFile,
                        contentHash: staged.sha256,
                        sizeBytes: staged.byteCount,
                        drmProtected: drmProtected,
                        dateAdded: replacementDate,
                        validationStatus: .ok,
                        book: storedBook
                    )
                    self.modelContext.insert(storedAsset)
                    insertedAsset = storedAsset
                    updatedAsset = storedAsset
                }
                storedBook.primaryAssetUUID = updatedAsset.uuid
            }
        } catch {
            return
        }
        analysisCoordinator.cancelAll(for: bookID)
        missingFileUUIDs.remove(bookID)
    }

}
