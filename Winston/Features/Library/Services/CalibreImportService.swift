import AppKit
import Foundation
import Observation
import SwiftData

nonisolated enum CalibreImportSummaryStyle: Sendable, Equatable {
    case success
    case info
    case error
}

@MainActor
@Observable
final class CalibreImportService {
    private struct PreparedSource {
        let assetID: UUID
        let format: String
        let transaction: ManagedFileTransaction
        let file: StagedManagedFile
    }

    private struct PreparedCandidate {
        let item: CalibreImportManifest.Item
        let decision: CalibreImportDecision
        let sources: [PreparedSource]
        let coverData: Data?
        let coverTransaction: ManagedFileTransaction?

        var transactions: [ManagedFileTransaction] {
            sources.map(\.transaction) + [coverTransaction].compactMap { $0 }
        }
    }

    private struct BookPreimage {
        let book: Book
        let assets: [BookAsset]
        let coverVersion: Int
    }

    private struct WorkPreimage {
        let work: Work
        let editions: [Book]
        let preferredEditionUUID: UUID?
    }

    private let modelContext: ModelContext
    private let settings: AppSettings
    private let metadata: MetadataService
    private let wishlist: WishlistService
    private let toasts: ToastCenter
    private let editions: CatalogReconciliationService?
    private let mutations: CatalogMutationService
    private let managedFiles: ManagedFileCoordinator
    private let sessionDirectory: URL
    private let chunkSize: Int
    private let maximumConcurrentInspections: Int

    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var activeSession: CalibreImportSession?
    @ObservationIgnored private var activeReconciler: CalibreImportReconciler?

    nonisolated static let kindlePreference = ["azw3", "mobi", "azw", "epub", "pdf", "txt"]

    private(set) var isImporting = false
    private(set) var isCancelling = false
    private(set) var isResuming = false
    private(set) var progress: CalibreImportProgress?
    private(set) var result: CalibreImportSummary?
    private(set) var summary: String?
    private(set) var summaryStyle: CalibreImportSummaryStyle = .success

    init(
        modelContext: ModelContext,
        settings: AppSettings,
        metadata: MetadataService,
        wishlist: WishlistService,
        toasts: ToastCenter,
        editions: CatalogReconciliationService? = nil,
        mutations: CatalogMutationService? = nil,
        managedFiles: ManagedFileCoordinator = .shared,
        sessionDirectory: URL? = nil,
        chunkSize: Int = 25,
        maximumConcurrentInspections: Int = 2
    ) {
        self.modelContext = modelContext
        self.settings = settings
        self.metadata = metadata
        self.wishlist = wishlist
        self.toasts = toasts
        self.editions = editions
        self.mutations = mutations ?? CatalogMutationService(
            modelContext: modelContext,
            managedFiles: managedFiles
        )
        self.managedFiles = managedFiles
        self.sessionDirectory = sessionDirectory ?? AppPaths.calibreImportSessionsDirectory
        self.chunkSize = max(1, chunkSize)
        self.maximumConcurrentInspections = max(1, maximumConcurrentInspections)
    }

    var progressText: String? {
        guard let progress else { return nil }
        if isCancelling || progress.phase == .cancelling {
            return String(localized: "Pausing Calibre import\u{2026}")
        }
        if isResuming {
            return String(
                localized: "Resuming Calibre import\u{2026} \(progress.completed)/\(progress.total)"
            )
        }
        return String(
            localized: "Importing from Calibre\u{2026} \(progress.completed)/\(progress.total)"
        )
    }

    var progressFraction: Double? {
        guard let progress, progress.total > 0 else { return nil }
        return Double(progress.completed) / Double(progress.total)
    }

    func importLibrary(at root: URL) {
        guard !isImporting else { return }
        isImporting = true
        isCancelling = false
        isResuming = false
        progress = nil
        result = nil
        summary = nil
        summaryStyle = .success

        importTask = Task { [weak self] in
            await self?.performImport(at: root)
        }
    }

    func cancelImport() {
        guard isImporting, !isCancelling else { return }
        isCancelling = true
        importTask?.cancel()
        if let activeSession {
            Task { await activeSession.requestCancellation() }
        }
    }

    /// Test seam and a useful synchronization point for command-line callers.
    func waitForCurrentImport() async {
        await importTask?.value
    }

    nonisolated static func displayedPosition(for zeroBasedIndex: Int) -> Int {
        zeroBasedIndex + 1
    }

    private func performImport(at root: URL) async {
        let accessing = root.startAccessingSecurityScopedResource()
        defer {
            if accessing { root.stopAccessingSecurityScopedResource() }
            isImporting = false
            isCancelling = false
            isResuming = false
            activeSession = nil
            activeReconciler = nil
            importTask = nil
        }

        let session: CalibreImportSession
        do {
            if let resumable = try await CalibreImportSession.resumable(
                for: root,
                directory: sessionDirectory
            ) {
                session = resumable
                isResuming = true
            } else {
                let readResult = try await CalibreLibraryReader.read(
                    libraryRoot: root,
                    formatPreference: Self.kindlePreference
                )
                guard !readResult.books.isEmpty else {
                    reportEmptyImport(unsafeRejectedSources: readResult.unsafeRejectionCount)
                    return
                }
                session = try await CalibreImportSession.create(
                    libraryRoot: root,
                    books: readResult.books,
                    unsafeRejectedSources: readResult.unsafeRejectionCount,
                    collectionName: Self.collectionName(),
                    directory: sessionDirectory
                )
            }
        } catch CalibreImportError.noLibrary {
            toasts.error(String(localized: "No Calibre library (metadata.db) found in that folder."))
            return
        } catch {
            toasts.error(String(localized: "Couldn\u{2019}t read the Calibre library."))
            return
        }

        activeSession = session
        do {
            let canContinue = try await reconcileInterruptedWork(in: session)
            guard canContinue else {
                let failedSummary = await session.summary()
                present(failedSummary)
                toasts.error(String(localized: "Some Calibre files are still waiting for recovery."))
                return
            }
        } catch {
            let failedSummary = await session.summary()
            present(failedSummary)
            toasts.error(String(localized: "Couldn\u{2019}t resume the Calibre import."))
            return
        }

        activeReconciler = makeReconciler()
        let finalSummary = await session.run(
            chunkSize: chunkSize,
            progressHandler: { [weak self] progress in
                await self?.setProgress(progress)
            },
            processor: { [weak self, session] items in
                guard let self else {
                    return CalibreImportChunkResult(failure: CalibreImportChunkFailure(
                        calibreID: items.first?.calibreID,
                        message: "The import service became unavailable.",
                        isCancellation: true,
                        preservePreparedItems: false
                    ))
                }
                return await self.process(items, in: session)
            }
        )
        progress = nil
        result = finalSummary

        if finalSummary.isComplete {
            await performPostImportActions(for: session)
        }
        present(finalSummary)
    }

    private func setProgress(_ value: CalibreImportProgress) {
        progress = value
    }

    private func reconcileInterruptedWork(
        in session: CalibreImportSession
    ) async throws -> Bool {
        let recovery = await mutations.recoverManagedFiles()
        var pendingTransactionIDs = Set((await managedFiles.pendingTransactions()).map(\.id))
        pendingTransactionIDs.formUnion(recovery.failedTransactionIDs)
        pendingTransactionIDs.formUnion(recovery.unreadableJournalURLs.compactMap {
            UUID(uuidString: $0.deletingPathExtension().lastPathComponent)
        })
        let manifest = await session.snapshot()
        let recoveryItems = manifest.items.filter {
            $0.state == .prepared || $0.state == .failed
        }
        let recoveryBookIDs = Set(recoveryItems.compactMap { item -> UUID? in
            guard let decision = item.decision else { return nil }
            return Self.targetBookID(for: decision, item: item)
        })
        let books = recoveryBookIDs.compactMap { try? mutations.book(id: $0) }
        let booksByID = Dictionary(uniqueKeysWithValues: books.map { ($0.uuid, $0) })
        let assetsByID = Dictionary(
            books.flatMap(\.assets).map { ($0.uuid, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var durableOutcomes: [CalibreImportOutcome] = []
        var preserve: Set<Int64> = []
        for item in recoveryItems {
            guard let decision = item.decision else { continue }
            let pending = !pendingTransactionIDs.isDisjoint(with: item.transactionIDs)
            let evidence = catalogEvidence(
                for: item,
                decision: decision,
                booksByID: booksByID,
                assetsByID: assetsByID
            )
            if pending {
                preserve.insert(item.calibreID)
            } else if evidence.isDurable {
                if evidence.filesExist {
                    durableOutcomes.append(Self.outcome(for: item, decision: decision))
                } else {
                    preserve.insert(item.calibreID)
                }
            }
        }
        try await session.reconcileForResume(
            durableOutcomes: durableOutcomes,
            preservingPreparedItemIDs: preserve
        )
        return preserve.isEmpty
    }

    private func catalogEvidence(
        for item: CalibreImportManifest.Item,
        decision: CalibreImportDecision,
        booksByID: [UUID: Book],
        assetsByID: [UUID: BookAsset]
    ) -> (isDurable: Bool, filesExist: Bool) {
        switch decision {
        case .skipExact:
            return (false, false)

        case .merge(let existingBookID, _):
            let importedAssets = item.assetIDs.compactMap { assetsByID[$0] }
            guard booksByID[existingBookID] != nil, !importedAssets.isEmpty else {
                return (false, false)
            }
            return (true, importedAssets.allSatisfy { Self.fileExists(at: $0.fileURL) })

        case .addEdition, .newWork, .needsReview:
            guard let book = booksByID[item.bookID] else { return (false, false) }
            let importedAssets = book.assets.filter { item.assetIDs.contains($0.uuid) }
            guard !importedAssets.isEmpty else { return (false, false) }
            return (
                true,
                importedAssets.allSatisfy { Self.fileExists(at: $0.fileURL) }
                    && book.primaryFileURL != nil
            )
        }
    }

    private func makeReconciler() -> CalibreImportReconciler {
        CalibreImportReconciler(books: ((try? modelContext.fetchAllBooksForGlobalAnalysis()) ?? []).map { book in
            CalibreImportCatalogBook(
                bookID: book.uuid,
                workID: book.work?.uuid,
                title: book.displayTitle,
                author: book.displayAuthor,
                isbn: book.isbn,
                language: book.language,
                publisher: book.publisher,
                year: book.year,
                contentHashes: Set(book.assets.compactMap(\.contentHash)),
                formats: Set(book.assets.map(\.format) + [book.format])
            )
        })
    }

    private func process(
        _ items: [CalibreImportManifest.Item],
        in session: CalibreImportSession
    ) async -> CalibreImportChunkResult {
        guard !modelContext.hasChanges else {
            return failureResult(
                calibreID: items.first?.calibreID,
                error: CatalogMutationError.dirtyContext
            )
        }
        guard var tentativeReconciler = activeReconciler else {
            return failureResult(
                calibreID: items.first?.calibreID,
                error: CatalogMutationError.modelNotFound
            )
        }

        let inspections = await CalibreImportInspector.inspect(
            items,
            maximumConcurrentTasks: maximumConcurrentInspections
        )
        var result = CalibreImportChunkResult(
            unsafeRejectedSourcesByItem: inspections.mapValues(\.unsafeRejectedSources)
        )
        var preparedCandidates: [PreparedCandidate] = []
        var stagedTransactions: [ManagedFileTransaction] = []
        var coveredBookIDs: Set<UUID> = []

        for item in items {
            if await cancellationRequested(in: session) {
                await abort(stagedTransactions)
                result.resetItemIDs.formUnion(preparedCandidates.map { $0.item.calibreID })
                result.failure = CalibreImportChunkFailure(
                    calibreID: nil,
                    message: "Calibre import was paused.",
                    isCancellation: true,
                    preservePreparedItems: false
                )
                return result
            }
            guard let inspection = inspections[item.calibreID], !inspection.sources.isEmpty else {
                await abort(stagedTransactions)
                result.failure = CalibreImportChunkFailure(
                    calibreID: item.calibreID,
                    message: "No validated source file remains for this Calibre item.",
                    isCancellation: false,
                    preservePreparedItems: false
                )
                return result
            }

            var stagedSources: [PreparedSource] = []
            do {
                for source in inspection.sources {
                    let managedSource = try ManagedFileSource.book(
                        sourceURL: source.url,
                        fileID: source.assetID
                    )
                    let transaction = try await managedFiles.stage(
                        intent: .calibreImport,
                        sources: [managedSource],
                        requirement: ManagedFileRequirement(
                            referencedBookFileNames: [managedSource.finalRelativeName]
                        )
                    )
                    guard let file = transaction.files.first else {
                        await managedFiles.abort(transaction)
                        throw CocoaError(.fileReadUnknown)
                    }
                    stagedTransactions.append(transaction)
                    stagedSources.append(PreparedSource(
                        assetID: source.assetID,
                        format: source.format,
                        transaction: transaction,
                        file: file
                    ))
                }
            } catch {
                await abort(stagedTransactions)
                result.failure = CalibreImportChunkFailure(
                    calibreID: item.calibreID,
                    message: error.localizedDescription,
                    isCancellation: false,
                    preservePreparedItems: false
                )
                return result
            }

            let candidate = Self.candidate(for: item, stagedSources: stagedSources)
            let decision = tentativeReconciler.decision(for: candidate)
            if case .skipExact = decision {
                await abort(stagedSources.map(\.transaction))
                let abortedIDs = Set(stagedSources.map { $0.transaction.id })
                stagedTransactions.removeAll { abortedIDs.contains($0.id) }
                result.outcomes.append(Self.outcome(for: item, decision: decision))
                continue
            }

            var seenIncomingHashes: Set<String> = []
            var keptSources: [PreparedSource] = []
            for source in stagedSources {
                let hash = source.file.sha256.lowercased()
                if tentativeReconciler.contains(hash: hash)
                    || !seenIncomingHashes.insert(hash).inserted {
                    await managedFiles.abort(source.transaction)
                    stagedTransactions.removeAll { $0.id == source.transaction.id }
                } else {
                    keptSources.append(source)
                }
            }
            guard !keptSources.isEmpty else {
                result.outcomes.append(CalibreImportOutcome(
                    calibreID: item.calibreID,
                    category: .skippedExact,
                    bookID: Self.targetBookID(for: decision, item: item),
                    message: nil
                ))
                continue
            }

            let targetBookID = Self.targetBookID(for: decision, item: item)
            var coverTransaction: ManagedFileTransaction?
            var coverData: Data?
            if let data = inspection.coverData,
               !coveredBookIDs.contains(targetBookID),
               shouldImportCover(for: targetBookID, decision: decision) {
                let version = (book(withID: targetBookID)?.coverVersion ?? 0) + 1
                do {
                    let transaction = try await managedFiles.stage(
                        intent: .calibreImport,
                        sources: [.cover(data: data, bookID: targetBookID)],
                        requirement: ManagedFileRequirement(
                            presentBookIDs: [targetBookID],
                            coverVersions: [targetBookID: version]
                        )
                    )
                    coverTransaction = transaction
                    coverData = data
                    coveredBookIDs.insert(targetBookID)
                    stagedTransactions.append(transaction)
                } catch {
                    await abort(stagedTransactions)
                    result.failure = CalibreImportChunkFailure(
                        calibreID: item.calibreID,
                        message: error.localizedDescription,
                        isCancellation: false,
                        preservePreparedItems: false
                    )
                    return result
                }
            }

            preparedCandidates.append(PreparedCandidate(
                item: item,
                decision: decision,
                sources: keptSources,
                coverData: coverData,
                coverTransaction: coverTransaction
            ))
            tentativeReconciler.record(candidate, decision: decision)
        }

        guard !preparedCandidates.isEmpty else { return result }
        if await cancellationRequested(in: session) {
            await abort(stagedTransactions)
            result.failure = CalibreImportChunkFailure(
                calibreID: nil,
                message: "Calibre import was paused.",
                isCancellation: true,
                preservePreparedItems: false
            )
            return result
        }

        do {
            try await session.prepare(preparedCandidates.map {
                CalibreImportPreparedItem(
                    calibreID: $0.item.calibreID,
                    decision: $0.decision,
                    transactionIDs: $0.transactions.map(\.id)
                )
            })
        } catch {
            await abort(stagedTransactions)
            result.failure = CalibreImportChunkFailure(
                calibreID: preparedCandidates.first?.item.calibreID,
                message: error.localizedDescription,
                isCancellation: false,
                preservePreparedItems: false
            )
            return result
        }

        do {
            let commitResult = try await commit(
                preparedCandidates,
                manifest: await session.snapshot()
            )
            activeReconciler = tentativeReconciler
            if !commitResult.pendingTransactionIDs.isEmpty {
                let pending = Set(commitResult.pendingTransactionIDs)
                let affected = preparedCandidates.first {
                    !$0.transactions.map(\.id).allSatisfy { !pending.contains($0) }
                }
                result.failure = CalibreImportChunkFailure(
                    calibreID: affected?.item.calibreID ?? preparedCandidates.first?.item.calibreID,
                    message: "Managed files are waiting for recovery.",
                    isCancellation: false,
                    preservePreparedItems: true
                )
                return result
            }
        } catch {
            result.resetItemIDs.formUnion(preparedCandidates.map { $0.item.calibreID })
            result.failure = CalibreImportChunkFailure(
                calibreID: preparedCandidates.first?.item.calibreID,
                message: error.localizedDescription,
                isCancellation: false,
                preservePreparedItems: false
            )
            return result
        }

        for candidate in preparedCandidates {
            result.outcomes.append(Self.outcome(
                for: candidate.item,
                decision: candidate.decision
            ))
            let coverURL = book(withID: Self.targetBookID(
                for: candidate.decision,
                item: candidate.item
            ))?.fileURL
            if let data = candidate.coverData,
               let image = NSImage(data: data),
               let coverURL {
                await CoverCache.shared.replace(image, for: coverURL)
            }
        }
        return result
    }

    private func commit(
        _ candidates: [PreparedCandidate],
        manifest: CalibreImportManifest
    ) async throws -> CatalogFileCommitResult {
        let createdBookIDs = Set(candidates.compactMap { candidate -> UUID? in
            switch candidate.decision {
            case .addEdition, .newWork, .needsReview:
                candidate.item.bookID
            case .skipExact, .merge:
                nil
            }
        })
        var requiredBookIDs = Set(candidates.compactMap { candidate -> UUID? in
            guard case .merge(let existingBookID, _) = candidate.decision else {
                return nil
            }
            return existingBookID
        })
        requiredBookIDs.subtract(createdBookIDs)
        var booksByID = Dictionary(
            uniqueKeysWithValues: try requiredBookIDs.map {
                let book = try mutations.book(id: $0)
                return (book.uuid, book)
            }
        )
        let createdWorkIDs = Set(candidates.compactMap { candidate -> UUID? in
            switch candidate.decision {
            case .newWork, .needsReview:
                candidate.item.workID
            case .skipExact, .merge, .addEdition:
                nil
            }
        })
        var requiredWorkIDs = Set(candidates.compactMap { candidate -> UUID? in
            guard case .addEdition(let workID) = candidate.decision else {
                return nil
            }
            return workID
        })
        requiredWorkIDs.subtract(createdWorkIDs)
        var worksByID = Dictionary(
            uniqueKeysWithValues: try requiredWorkIDs.map {
                let work = try mutations.work(id: $0)
                return (work.uuid, work)
            }
        )

        var collectionDescriptor = FetchDescriptor<BookCollection>(
            predicate: #Predicate { $0.id == manifest.collectionID }
        )
        collectionDescriptor.fetchLimit = 1
        let existingCollection = try modelContext.fetch(collectionDescriptor).first
        let collection = existingCollection ?? BookCollection(
            id: manifest.collectionID,
            name: manifest.collectionName
        )
        let collectionBooksPreimage = existingCollection?.books
        if existingCollection == nil { modelContext.insert(collection) }

        var bookPreimages: [UUID: BookPreimage] = [:]
        var workPreimages: [UUID: WorkPreimage] = [:]
        var affectedBookIDs: Set<UUID> = []
        var affectedWorkIDs: Set<UUID> = []

        for candidate in candidates {
            let targetBook: Book
            switch candidate.decision {
            case .skipExact:
                continue

            case .merge(let existingBookID, let workID):
                guard let existing = booksByID[existingBookID] else {
                    throw CatalogMutationError.modelNotFound
                }
                if bookPreimages[existingBookID] == nil {
                    bookPreimages[existingBookID] = BookPreimage(
                        book: existing,
                        assets: existing.assets,
                        coverVersion: existing.coverVersion
                    )
                }
                targetBook = existing
                if let workID { affectedWorkIDs.insert(workID) }

            case .addEdition(let workID):
                guard let work = worksByID[workID] else {
                    throw CatalogMutationError.modelNotFound
                }
                if workPreimages[workID] == nil {
                    workPreimages[workID] = WorkPreimage(
                        work: work,
                        editions: work.editions,
                        preferredEditionUUID: work.preferredEditionUUID
                    )
                }
                targetBook = makeBook(from: candidate, work: work)
                booksByID[targetBook.uuid] = targetBook

            case .newWork, .needsReview:
                let work = Work(
                    uuid: candidate.item.workID,
                    title: candidate.item.book.title,
                    author: Self.author(for: candidate.item.book),
                    dateCreated: candidate.item.book.dateAdded ?? .now
                )
                modelContext.insert(work)
                worksByID[work.uuid] = work
                targetBook = makeBook(from: candidate, work: work)
                booksByID[targetBook.uuid] = targetBook
            }

            for source in candidate.sources {
                let asset = BookAsset(
                    uuid: source.assetID,
                    fileName: source.file.finalRelativeName,
                    origin: .imported,
                    contentHash: source.file.sha256,
                    sizeBytes: source.file.byteCount,
                    dateAdded: targetBook.dateAdded,
                    validationStatus: .ok,
                    book: targetBook
                )
                modelContext.insert(asset)
            }
            if candidate.coverTransaction != nil {
                targetBook.coverVersion += 1
            }
            if !collection.books.contains(where: { $0.uuid == targetBook.uuid }) {
                collection.books.append(targetBook)
            }
            affectedBookIDs.insert(targetBook.uuid)
            if let workID = targetBook.work?.uuid { affectedWorkIDs.insert(workID) }
        }

        let transactions = candidates.flatMap(\.transactions)
        return try await mutations.commitStagedFiles(
            .calibreImport(bookIDs: Array(affectedBookIDs)),
            transactions: transactions,
            affectedBookIDs: affectedBookIDs,
            affectedWorkIDs: affectedWorkIDs,
            affectedCollectionIDs: [manifest.collectionID],
            revertingOnFailure: {
                for preimage in bookPreimages.values {
                    preimage.book.assets = preimage.assets
                    preimage.book.coverVersion = preimage.coverVersion
                }
                for preimage in workPreimages.values {
                    preimage.work.editions = preimage.editions
                    preimage.work.preferredEditionUUID = preimage.preferredEditionUUID
                }
                if let collectionBooksPreimage {
                    collection.books = collectionBooksPreimage
                }
            }
        )
    }

    private func makeBook(from candidate: PreparedCandidate, work: Work) -> Book {
        let primary = candidate.sources[0]
        let calibreBook = candidate.item.book
        let book = Book(
            uuid: candidate.item.bookID,
            fileName: primary.file.finalRelativeName,
            originalFileName: primary.file.originalSourceURL?.lastPathComponent
                ?? primary.file.finalRelativeName,
            dateAdded: calibreBook.dateAdded ?? .now
        )
        book.apply(Self.metadata(from: calibreBook))
        book.rating = calibreBook.rating
        book.fileSizeBytes = primary.file.byteCount
        modelContext.insert(book)
        book.work = work
        if work.preferredEditionUUID == nil { work.preferredEditionUUID = book.uuid }
        return book
    }

    private func shouldImportCover(
        for targetBookID: UUID,
        decision: CalibreImportDecision
    ) -> Bool {
        switch decision {
        case .merge:
            return book(withID: targetBookID)?.coverVersion == 0
        case .skipExact:
            return false
        case .addEdition, .newWork, .needsReview:
            return true
        }
    }

    private func book(withID id: UUID) -> Book? {
        var descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.uuid == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func abort(_ transactions: [ManagedFileTransaction]) async {
        for transaction in transactions { await managedFiles.abort(transaction) }
    }

    private func cancellationRequested(in session: CalibreImportSession) async -> Bool {
        if Task.isCancelled { return true }
        return await session.shouldCancel()
    }

    private func failureResult(
        calibreID: Int64?,
        error: Error
    ) -> CalibreImportChunkResult {
        CalibreImportChunkResult(failure: CalibreImportChunkFailure(
            calibreID: calibreID,
            message: error.localizedDescription,
            isCancellation: false,
            preservePreparedItems: false
        ))
    }

    private func performPostImportActions(for session: CalibreImportSession) async {
        let manifest = await session.snapshot()
        let importedIDs = Set(manifest.items.compactMap { item -> UUID? in
            guard let outcome = item.outcome else { return nil }
            switch outcome.category {
            case .imported, .merged, .needsReview:
                return outcome.bookID
            case .skippedExact, .failed:
                return nil
            }
        })
        let imported = importedIDs.compactMap { try? mutations.book(id: $0) }
        wishlist.fulfil(with: imported)

        if let editions {
            let previousKeys = Set(editions.pendingProposals.map(\.pairKey))
            await editions.scanLibrary()
            if editions.pendingProposals.contains(where: {
                !previousKeys.contains($0.pairKey)
                    && !$0.memberUUIDs.allSatisfy { !importedIDs.contains($0) }
            }) {
                toasts.post(
                    String(localized: "Edition suggestions are ready to review."),
                    style: .info,
                    action: .reviewEditionProposals
                )
            }
        }
        if settings.onlineMetadataEnabled {
            await metadata.backfillMissingOnlineMetadata()
        }
    }

    private func present(_ importSummary: CalibreImportSummary) {
        result = importSummary
        switch importSummary.phase {
        case .completed:
            summaryStyle = .success
        case .cancelled, .cancelling:
            summaryStyle = .info
        case .failed:
            summaryStyle = .error
        case .prepared, .running:
            summaryStyle = .info
        }
        finish(summary: Self.summaryText(importSummary))
    }

    private func reportEmptyImport(unsafeRejectedSources: Int) {
        let noBooks = String(localized: "No importable books found in that Calibre library.")
        if unsafeRejectedSources > 0 {
            toasts.error("\(noBooks) \(Self.unsafeRejectionText(unsafeRejectedSources))")
        } else {
            toasts.error(noBooks)
        }
    }

    private func finish(summary: String) {
        self.summary = summary
        Task {
            try? await Task.sleep(for: .seconds(8))
            if !isImporting { self.summary = nil }
        }
    }

    private static func candidate(
        for item: CalibreImportManifest.Item,
        stagedSources: [PreparedSource]
    ) -> CalibreImportCandidate {
        CalibreImportCandidate(
            bookID: item.bookID,
            workID: item.workID,
            title: item.book.title,
            author: author(for: item.book),
            isbn: item.book.isbn,
            language: item.book.language,
            publisher: item.book.publisher,
            year: item.book.year,
            contentHashes: Set(stagedSources.map { $0.file.sha256 }),
            formats: Set(stagedSources.map(\.format))
        )
    }

    private static func targetBookID(
        for decision: CalibreImportDecision,
        item: CalibreImportManifest.Item
    ) -> UUID {
        switch decision {
        case .skipExact(let existingBookID), .merge(let existingBookID, _):
            existingBookID
        case .addEdition, .newWork, .needsReview:
            item.bookID
        }
    }

    private static func outcome(
        for item: CalibreImportManifest.Item,
        decision: CalibreImportDecision
    ) -> CalibreImportOutcome {
        switch decision {
        case .skipExact(let existingBookID):
            CalibreImportOutcome(
                calibreID: item.calibreID,
                category: .skippedExact,
                bookID: existingBookID,
                message: nil
            )
        case .merge(let existingBookID, _):
            CalibreImportOutcome(
                calibreID: item.calibreID,
                category: .merged,
                bookID: existingBookID,
                message: nil
            )
        case .addEdition:
            CalibreImportOutcome(
                calibreID: item.calibreID,
                category: .imported,
                bookID: item.bookID,
                message: nil
            )
        case .newWork:
            CalibreImportOutcome(
                calibreID: item.calibreID,
                category: .imported,
                bookID: item.bookID,
                message: nil
            )
        case .needsReview:
            CalibreImportOutcome(
                calibreID: item.calibreID,
                category: .needsReview,
                bookID: item.bookID,
                message: nil
            )
        }
    }

    private static func metadata(from cb: CalibreBook) -> BookMetadata {
        var metadata = BookMetadata()
        metadata.title = cb.title
        metadata.author = author(for: cb)
        metadata.publisher = cb.publisher
        metadata.year = cb.year
        metadata.language = cb.language
        metadata.isbn = cb.isbn
        metadata.series = cb.series
        metadata.seriesIndex = cb.seriesIndex
        metadata.tags = cb.tags
        metadata.description = cb.bookDescription
        return metadata
    }

    private static func author(for book: CalibreBook) -> String? {
        book.authors.isEmpty ? nil : book.authors.joined(separator: ", ")
    }

    private static func collectionName() -> String {
        let date = Date.now.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))
        return String(localized: "Calibre Import \(date)")
    }

    private static func summaryText(_ summary: CalibreImportSummary) -> String {
        let counts = String(
            localized: "Imported: \(summary.imported), merged: \(summary.merged), exact duplicates skipped: \(summary.skippedExact), needs review: \(summary.needsReview), failed: \(summary.failed)."
        )
        let base: String
        switch summary.phase {
        case .completed:
            base = String(localized: "Calibre import completed. \(counts)")
        case .cancelled, .cancelling:
            base = String(localized: "Calibre import paused and can be resumed. \(counts)")
        case .failed:
            base = String(localized: "Calibre import stopped and can be resumed. \(counts)")
        case .prepared, .running:
            base = counts
        }
        guard summary.unsafeRejectedSources > 0 else { return base }
        return "\(base) \(unsafeRejectionText(summary.unsafeRejectedSources))"
    }

    private static func unsafeRejectionText(_ count: Int) -> String {
        String(localized: "Rejected unsafe Calibre sources: \(count).")
    }

    nonisolated private static func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }
}
