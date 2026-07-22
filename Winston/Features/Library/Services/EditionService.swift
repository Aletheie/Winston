import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class CatalogReconciliationService {
    private let modelContext: ModelContext
    private let defaults: UserDefaults
    private let covers: CoverRepository
    private let mutations: CatalogMutationService
    private let managedFiles: ManagedFileCoordinator
    private let toasts: ToastCenter?
    private let dismissedDefaultsKey = "editionMatcherDismissedPairKeys"

    private(set) var pendingProposals: [EditionMatchProposal] = []
    private(set) var editionCounts: [UUID: Int] = [:]
    private var dismissedPairKeys: Set<String>

    private enum AssetMergePolicy {
        case retainAll
        case removeExactDuplicates(evidence: [ExactDuplicateEvidence])
    }

    private struct AssetFileSnapshot: Sendable {
        let assetID: UUID
        let fileName: String
        let storedSHA256: String
    }

    private struct ExactDuplicateEvidence: Hashable, Sendable {
        let discardedAssetID: UUID
        let discardedFileName: String
        let retainedFileName: String
        let sha256: String
    }

    private struct AssetGeneration: Equatable {
        let uuid: UUID
        let fileName: String
        let contentHash: String?
        let sizeBytes: Int64
        let dateAdded: Date
        let validationStatus: AssetValidation?
    }

    private struct BookGeneration: Equatable {
        let candidate: EditionCandidate
        let fileName: String
        let fileSizeBytes: Int64
        let coverVersion: Int
        let assets: [AssetGeneration]
    }

    private struct BookMergeScalarPreimage {
        let metadata: CatalogBookMetadataPreimage
        let fileName: String
        let hasPhysicalCopyRaw: Bool?
        let readingStatusRaw: String?
        let dateStarted: Date?
        let dateFinished: Date?
        let editionStatement: String?
        let editionTypeRaw: String?

        init(_ book: Book) {
            metadata = CatalogBookMetadataPreimage(book)
            fileName = book.fileName
            hasPhysicalCopyRaw = book.hasPhysicalCopyRaw
            readingStatusRaw = book.readingStatusRaw
            dateStarted = book.dateStarted
            dateFinished = book.dateFinished
            editionStatement = book.editionStatement
            editionTypeRaw = book.editionTypeRaw
        }

        func restore(on book: Book) {
            metadata.restore()
            book.fileName = fileName
            book.hasPhysicalCopyRaw = hasPhysicalCopyRaw
            book.readingStatusRaw = readingStatusRaw
            book.dateStarted = dateStarted
            book.dateFinished = dateFinished
            book.editionStatement = editionStatement
            book.editionTypeRaw = editionTypeRaw
        }
    }

    private struct CollectionMembershipPreimage {
        let collection: BookCollection
        let containedWinner: Bool
        let containedLoser: Bool
    }

    private struct BookMergePreimage {
        let winner: Book
        let loser: Book
        let winnerScalar: BookMergeScalarPreimage
        let winnerWork: Work?
        let loserWork: Work?
        let workPreimages: [CatalogWorkPreimage]
        let loserAssets: [BookAsset]
        let loserHighlights: [Highlight]
        let loserReadingSessions: [ReadingSession]
        let collectionMemberships: [CollectionMembershipPreimage]

        init(winner: Book, loser: Book) {
            self.winner = winner
            self.loser = loser
            winnerScalar = BookMergeScalarPreimage(winner)
            winnerWork = winner.work
            loserWork = loser.work
            var seenWorkIDs: Set<UUID> = []
            workPreimages = [winner.work, loser.work].compactMap { work in
                guard let work, seenWorkIDs.insert(work.uuid).inserted else { return nil }
                return CatalogWorkPreimage(work)
            }
            loserAssets = loser.assets
            loserHighlights = loser.highlights
            loserReadingSessions = loser.readingSessions
            var seenCollectionIDs: Set<UUID> = []
            collectionMemberships = (winner.collections + loser.collections).compactMap { collection in
                guard seenCollectionIDs.insert(collection.id).inserted else { return nil }
                return CollectionMembershipPreimage(
                    collection: collection,
                    containedWinner: collection.books.contains { $0.uuid == winner.uuid },
                    containedLoser: collection.books.contains { $0.uuid == loser.uuid }
                )
            }
        }

        func restore(in modelContext: ModelContext, removing insertedAsset: BookAsset?) {
            if let insertedAsset {
                winner.assets.removeAll { $0 === insertedAsset }
                if insertedAsset.modelContext != nil { modelContext.delete(insertedAsset) }
            }
            for work in [winnerWork, loserWork].compactMap({ $0 })
            where work.modelContext == nil {
                modelContext.insert(work)
            }
            if loser.modelContext == nil { modelContext.insert(loser) }
            winnerScalar.restore(on: winner)
            winner.work = winnerWork
            loser.work = loserWork
            for asset in loserAssets {
                if asset.modelContext == nil { modelContext.insert(asset) }
                asset.book = loser
            }
            for highlight in loserHighlights {
                if highlight.modelContext == nil { modelContext.insert(highlight) }
                highlight.book = loser
            }
            for session in loserReadingSessions {
                if session.modelContext == nil { modelContext.insert(session) }
                session.book = loser
            }
            for membership in collectionMemberships {
                membership.collection.books.removeAll {
                    $0.uuid == winner.uuid || $0.uuid == loser.uuid
                }
                if membership.containedWinner { membership.collection.books.append(winner) }
                if membership.containedLoser { membership.collection.books.append(loser) }
            }
            for preimage in workPreimages { preimage.restore() }
        }
    }

    init(
        modelContext: ModelContext,
        defaults: UserDefaults = .standard,
        covers: CoverRepository = .shared,
        mutations: CatalogMutationService? = nil,
        managedFiles: ManagedFileCoordinator = .shared,
        toasts: ToastCenter? = nil
    ) {
        self.modelContext = modelContext
        self.defaults = defaults
        self.covers = covers
        self.mutations = mutations ?? CatalogMutationService(
            modelContext: modelContext,
            managedFiles: managedFiles
        )
        self.managedFiles = managedFiles
        self.toasts = toasts
        self.dismissedPairKeys = Set(defaults.stringArray(forKey: dismissedDefaultsKey) ?? [])
        refreshEditionCounts()
    }

    var pendingCount: Int { pendingProposals.count }

    func refreshEditionCounts() {
        var counts: [UUID: Int] = [:]
        var descriptor = FetchDescriptor<Work>()
        descriptor.relationshipKeyPathsForPrefetching = [\.editions]
        let works = (try? modelContext.fetch(descriptor)) ?? []
        for work in works {
            let editions = work.editions
            guard editions.count > 1 else { continue }
            for edition in editions { counts[edition.uuid] = editions.count }
        }
        editionCounts = counts
    }

    @discardableResult
    func updateWork(_ work: Work, title: String, author: String) -> Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
        let workID = work.uuid
        do {
            try mutations.commit(
                .updateWork(workID: workID, fields: ["title", "author"]),
                affectedWorkIDs: [workID]
            ) {
                let storedWork = try mutations.work(id: workID)
                storedWork.title = trimmedTitle.isEmpty ? nil : trimmedTitle
                storedWork.author = trimmedAuthor.isEmpty ? nil : trimmedAuthor
                storedWork.refreshMatchKey()
            }
            return true
        } catch {
            return reportMutationFailure()
        }
    }

    @discardableResult
    func setPreferred(_ book: Book, in work: Work) -> Bool {
        let bookID = book.uuid
        let workID = work.uuid
        do {
            try mutations.commit(
                .updateWork(workID: workID, fields: ["preferredEditionUUID"]),
                affectedBookIDs: [bookID],
                affectedWorkIDs: [workID]
            ) {
                let storedBook = try mutations.book(id: bookID)
                let storedWork = try mutations.work(id: workID)
                guard storedBook.work?.uuid == storedWork.uuid else {
                    throw CatalogMutationError.modelNotFound
                }
                storedWork.preferredEditionUUID = storedBook.uuid
            }
            return true
        } catch {
            return reportMutationFailure()
        }
    }

    func scanLibrary() async {
        var descriptor = FetchDescriptor<Book>()
        descriptor.relationshipKeyPathsForPrefetching = [\Book.assets, \Book.work]
        let books = (try? modelContext.fetch(descriptor)) ?? []
        var candidates: [EditionCandidate] = []
        candidates.reserveCapacity(books.count)
        for (index, book) in books.enumerated() {
            guard !Task.isCancelled else { return }
            candidates.append(Self.candidate(book))
            if index > 0, index.isMultiple(of: 128) { await Task.yield() }
        }
        let proposals = await EditionMatcher.scan(candidates)
        guard !Task.isCancelled else { return }
        pendingProposals = proposals.filter { !dismissedPairKeys.contains($0.pairKey) }
    }

    func evaluate(_ book: Book) {
        let allBooks = modelContext.allBooks()
        var index = EditionMatcher.CandidateIndex(allBooks.map(Self.candidate))
        evaluate(
            book,
            index: &index
        )
    }

    func evaluate(_ books: [Book]) {
        let books = books.filter { $0.modelContext != nil }
        guard !books.isEmpty else { return }
        let allBooks = modelContext.allBooks()
        var index = EditionMatcher.CandidateIndex(allBooks.map(Self.candidate))
        for book in books {
            evaluate(book, index: &index)
        }
    }

    private func evaluate(
        _ book: Book,
        index: inout EditionMatcher.CandidateIndex
    ) {
        let candidate = Self.candidate(book)
        let matches = index.matches(for: candidate)
        let proposals = EditionMatcher.proposals(for: candidate, against: matches)
            .filter { !dismissedPairKeys.contains($0.pairKey) }
        guard !proposals.isEmpty else { return }

        let existing = Set(pendingProposals.map(\.pairKey))
        pendingProposals.append(contentsOf: proposals.filter { !existing.contains($0.pairKey) })
        pendingProposals.sort(by: EditionMatcher.proposalPrecedes)
    }

    func dismiss(_ proposal: EditionMatchProposal) {
        dismissedPairKeys.insert(proposal.pairKey)
        persistDismissals()
        pendingProposals.removeAll { $0.pairKey == proposal.pairKey }
    }

    func dismiss(_ proposals: [EditionMatchProposal]) {
        for proposal in proposals { dismissedPairKeys.insert(proposal.pairKey) }
        persistDismissals()
        let keys = Set(proposals.map(\.pairKey))
        pendingProposals.removeAll { keys.contains($0.pairKey) }
    }

    @discardableResult
    func approve(_ proposal: EditionMatchProposal) async -> Bool {
        guard proposal.canApply else { return false }
        let members = proposal.memberUUIDs.compactMap { lookupBook(uuid: $0) }
        guard members.count == proposal.memberUUIDs.count else {
            let liveUUIDs = Set(members.map(\.uuid))
            let missingUUIDs = Set(proposal.memberUUIDs).subtracting(liveUUIDs)
            pendingProposals.removeAll { pending in
                pending.memberUUIDs.contains(where: missingUUIDs.contains)
            }
            return false
        }
        let revalidated = revalidatedProposal(between: members)
        guard let current = revalidated,
              current.verdict == proposal.verdict,
              current.confidence == proposal.confidence else {
            replacePendingProposal(proposal, with: revalidated)
            return false
        }
        let succeeded: Bool
        switch current.verdict {
        case .sameWorkOtherEdition:
            succeeded = groupIntoWork(members) != nil
        case .sameEditionOtherFormat:
            guard let winner = preferredBook(in: members),
                  let loser = members.first(where: { $0.uuid != winner.uuid }) else { return false }
            succeeded = await absorb(
                loser,
                into: winner,
                policy: .retainAll,
                expectedProposal: current
            )
        case .duplicateFile:
            guard current.isExactContentDuplicate else { return false }
            guard let winner = preferredBook(in: members),
                  let loser = members.first(where: { $0.uuid != winner.uuid }) else { return false }
            let evidence = await verifiedExactDuplicateEvidence(winner: winner, loser: loser)
            guard !evidence.isEmpty else { return false }
            succeeded = await absorb(
                loser,
                into: winner,
                policy: .removeExactDuplicates(evidence: evidence),
                expectedProposal: current
            )
        case .similarItem:
            succeeded = false
        }
        if succeeded {
            pendingProposals.removeAll { $0.pairKey == proposal.pairKey }
            removeResolvedProposals()
        }
        return succeeded
    }

    func removeProposals(referencing bookUUID: UUID) {
        removeProposals(referencing: [bookUUID])
    }

    func removeProposals(referencing bookUUIDs: Set<UUID>) {
        guard !bookUUIDs.isEmpty else { return }
        pendingProposals.removeAll { proposal in
            proposal.memberUUIDs.contains { bookUUIDs.contains($0) }
        }
    }

    @discardableResult
    func assign(_ book: Book, to work: Work) -> Work? {
        guard book.modelContext != nil, work.modelContext != nil else { return nil }
        let bookID = book.uuid
        let workID = work.uuid
        let previousWork = book.work
        let previousWorkID = previousWork?.uuid
        let targetPreimage = CatalogWorkPreimage(work)
        let previousPreimage = previousWork.map(CatalogWorkPreimage.init)
        do {
            try mutations.commit(
                .assignEdition(bookIDs: [bookID], workID: workID),
                affectedBookIDs: [bookID],
                affectedWorkIDs: Set([workID, previousWorkID].compactMap { $0 }),
                revertingOnFailure: {
                    targetPreimage.restore()
                    previousPreimage?.restore()
                    if let previousWork, previousWork.modelContext == nil {
                        modelContext.insert(previousWork)
                    }
                    if previousWork !== work {
                        work.editions.removeAll { $0 === book }
                    }
                    book.work = previousWork
                    if let previousWork,
                       !previousWork.editions.contains(where: { $0 === book }) {
                        previousWork.editions.append(book)
                    }
                }
            ) {
                let storedBook = try mutations.book(id: bookID)
                let storedWork = try mutations.work(id: workID)
                let previous = storedBook.work
                storedBook.work = storedWork
                fillEmptyWorkMetadata(storedWork, from: storedBook)
                storedWork.preferredEditionUUID = WorkService.preferredEdition(in: storedWork)?.uuid ?? storedBook.uuid
                WorkService.pruneIfOrphaned(previous, context: modelContext, save: false)
            }
        } catch {
            _ = reportMutationFailure()
            return nil
        }
        refreshEditionCounts()
        removeResolvedProposals()
        return work
    }

    @discardableResult
    func groupIntoWork(_ books: [Book]) -> Work? {
        let books = books.filter { $0.modelContext != nil }
        let bookIDs = Set(books.map(\.uuid))
        guard bookIDs.count > 1 else { return nil }
        guard let winner = preferredBook(in: books) else { return nil }
        let winnerID = winner.uuid
        let pendingWork = winner.work == nil
            ? Work(title: winner.title, author: winner.author, dateCreated: winner.dateAdded)
            : nil
        let targetWorkID = winner.work?.uuid ?? pendingWork?.uuid
        let originalWorkIDs = Set(books.compactMap { $0.work?.uuid })
        var target: Work?
        do {
            try mutations.commit(
                .assignEdition(bookIDs: Array(bookIDs), workID: targetWorkID),
                affectedBookIDs: bookIDs,
                affectedWorkIDs: originalWorkIDs.union(Set([targetWorkID].compactMap { $0 }))
            ) {
                let storedBooks = try mutations.books(ids: bookIDs)
                guard let storedWinner = storedBooks.first(where: { $0.uuid == winnerID }) else {
                    throw CatalogMutationError.modelNotFound
                }
                let storedTarget: Work
                if let targetWorkID = storedWinner.work?.uuid {
                    storedTarget = try mutations.work(id: targetWorkID)
                } else if let pendingWork {
                    modelContext.insert(pendingWork)
                    storedWinner.work = pendingWork
                    storedTarget = pendingWork
                } else {
                    throw CatalogMutationError.modelNotFound
                }
                var seenWorkIDs: Set<UUID> = []
                let previousWorks = storedBooks.compactMap(\.work).filter {
                    $0.uuid != storedTarget.uuid && seenWorkIDs.insert($0.uuid).inserted
                }
                for storedBook in storedBooks {
                    storedBook.work = storedTarget
                    fillEmptyWorkMetadata(storedTarget, from: storedBook)
                }
                storedTarget.preferredEditionUUID = WorkService.preferredEdition(in: storedTarget)?.uuid ?? storedWinner.uuid
                for previous in previousWorks {
                    WorkService.pruneIfOrphaned(previous, context: modelContext, save: false)
                }
                target = storedTarget
            }
        } catch {
            _ = reportMutationFailure()
            return nil
        }
        refreshEditionCounts()
        removeResolvedProposals()
        return target
    }

    @discardableResult
    func mergeWorks(_ source: Work, into destination: Work) -> Work? {
        guard source.uuid != destination.uuid,
              source.modelContext != nil,
              destination.modelContext != nil else { return nil }
        let sourceID = source.uuid
        let destinationID = destination.uuid
        let bookIDs = Set(source.editions.map(\.uuid))
        do {
            try mutations.commit(
                .assignEdition(bookIDs: Array(bookIDs), workID: destinationID),
                affectedBookIDs: bookIDs,
                affectedWorkIDs: [sourceID, destinationID]
            ) {
                let storedSource = try mutations.work(id: sourceID)
                let storedDestination = try mutations.work(id: destinationID)
                fillEmptyWorkMetadata(storedDestination, from: storedSource)
                for book in storedSource.editions { book.work = storedDestination }
                storedDestination.preferredEditionUUID = WorkService.preferredEdition(in: storedDestination)?.uuid
                WorkService.pruneIfOrphaned(storedSource, context: modelContext, save: false)
            }
        } catch {
            _ = reportMutationFailure()
            return nil
        }
        refreshEditionCounts()
        removeResolvedProposals()
        return destination
    }

    @discardableResult
    func detach(_ book: Book) -> Work? {
        guard book.modelContext != nil else { return nil }
        let bookID = book.uuid
        let previousWorkID = book.work?.uuid
        let work = Work(title: book.title, author: book.author, dateCreated: Date())
        work.originalLanguage = book.language
        work.preferredEditionUUID = book.uuid
        do {
            try mutations.commit(
                .assignEdition(bookIDs: [bookID], workID: work.uuid),
                affectedBookIDs: [bookID],
                affectedWorkIDs: Set([work.uuid, previousWorkID].compactMap { $0 })
            ) {
                let storedBook = try mutations.book(id: bookID)
                let previous = storedBook.work
                modelContext.insert(work)
                storedBook.work = work
                WorkService.pruneIfOrphaned(previous, context: modelContext, save: false)
            }
        } catch {
            _ = reportMutationFailure()
            return nil
        }
        refreshEditionCounts()
        return work
    }

    func mergeSurvivor(among books: [Book]) -> Book? {
        preferredBook(in: books)
    }

    func mergeProposal(among books: [Book]) -> EditionMatchProposal? {
        let books = books.filter { $0.modelContext != nil }
        guard books.count == 2,
              let proposal = revalidatedProposal(between: books) else { return nil }
        switch proposal.verdict {
        case .duplicateFile, .sameEditionOtherFormat:
            return proposal
        case .sameWorkOtherEdition, .similarItem:
            return nil
        }
    }

    @discardableResult
    func mergeEditions(_ books: [Book]) async -> Book? {
        let books = books.filter { $0.modelContext != nil }
        guard Set(books.map(\.uuid)).count == 2,
              let proposal = mergeProposal(among: books),
              let winner = preferredBook(in: books),
              let loser = books.first(where: { $0.uuid != winner.uuid }) else { return nil }
        // Manual merging from a Work keeps every file. Physical cleanup is
        // available only through the exact-hash reconciliation proposal.
        return await absorb(
            loser,
            into: winner,
            policy: .retainAll,
            expectedProposal: proposal
        ) ? winner : nil
    }

    @discardableResult
    private func absorb(
        _ loser: Book,
        into winner: Book,
        policy: AssetMergePolicy,
        expectedProposal: EditionMatchProposal?
    ) async -> Bool {
        guard loser.uuid != winner.uuid,
              loser.modelContext != nil,
              winner.modelContext != nil else { return false }
        let winnerID = winner.uuid
        let loserID = loser.uuid
        let winnerGeneration = Self.generation(of: winner)
        let loserGeneration = Self.generation(of: loser)
        let preimage = BookMergePreimage(winner: winner, loser: loser)
        let discardAssetIDs: Set<UUID>
        let exactEvidence: [ExactDuplicateEvidence]
        switch policy {
        case .retainAll:
            discardAssetIDs = []
            exactEvidence = []
        case .removeExactDuplicates(let evidence):
            let losingAssets = Dictionary(uniqueKeysWithValues: loser.assets.map { ($0.uuid, $0) })
            let winningFilesByHash = Dictionary(grouping: winner.assets) { asset in
                asset.contentHash?.lowercased() ?? ""
            }
            guard !evidence.isEmpty,
                  evidence.allSatisfy({ item in
                      guard let losingAsset = losingAssets[item.discardedAssetID],
                            losingAsset.fileName == item.discardedFileName,
                            losingAsset.contentHash?.lowercased() == item.sha256 else { return false }
                      return winningFilesByHash[item.sha256]?.contains {
                          $0.fileName == item.retainedFileName
                      } == true
                  }) else { return false }
            exactEvidence = evidence
            discardAssetIDs = Set(evidence.map(\.discardedAssetID))
            guard !discardAssetIDs.isEmpty else { return false }
        }

        let retainedFileNames = Set(winner.assets.map(\.fileName))
            .union(loser.assets.lazy.filter { !discardAssetIDs.contains($0.uuid) }.map(\.fileName))
            .union([winner.fileName].filter { !$0.isEmpty })
        let discardedFileNames = Set(loser.assets.lazy
            .filter { discardAssetIDs.contains($0.uuid) }
            .map(\.fileName))
            .subtracting(retainedFileNames)
        let evidenceByDiscardedFile = Dictionary(
            exactEvidence.map { ($0.discardedFileName, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let bookCleanups = discardedFileNames.compactMap { fileName -> ManagedFileCleanup? in
            guard let evidence = evidenceByDiscardedFile[fileName] else { return nil }
            return .book(
                fileName,
                expectedSHA256: evidence.sha256,
                retainedEquivalentFileName: evidence.retainedFileName
            )
        }
        guard bookCleanups.count == discardedFileNames.count else { return false }

        let winnerCoverToken = await covers.beginUserMutation(for: winner.uuid)
        let winnerCoverRollback = await covers.copy(
            from: loser.uuid,
            using: winnerCoverToken,
            onlyIfMissing: true
        )
        let coverVersion = winner.coverVersion + (winnerCoverRollback == nil ? 0 : 1)
        let transaction: ManagedFileTransaction
        do {
            transaction = try await managedFiles.prepareCleanup(
                intent: .deleteBook,
                requirement: ManagedFileRequirement(
                    presentBookIDs: [winnerID],
                    absentBookIDs: [loserID],
                    referencedBookFileNames: Set(exactEvidence.map(\.retainedFileName)),
                    unreferencedBookFileNames: discardedFileNames,
                    coverVersions: winnerCoverRollback == nil ? [:] : [winnerID: coverVersion]
                ),
                // A second cover has no lossless catalog representation yet.
                // Keep the source cover on disk even after a successful copy;
                // only byte-verified BookAsset payloads may be retired here.
                cleanups: bookCleanups
            )
        } catch {
            if let winnerCoverRollback { _ = await covers.rollback(winnerCoverRollback) }
            return false
        }

        guard let currentWinner = lookupBook(uuid: winnerID),
              let currentLoser = lookupBook(uuid: loserID),
              Self.generation(of: currentWinner) == winnerGeneration,
              Self.generation(of: currentLoser) == loserGeneration else {
            await managedFiles.abort(transaction)
            if let winnerCoverRollback { _ = await covers.rollback(winnerCoverRollback) }
            return false
        }

        var insertedAsset: BookAsset?
        do {
            let result = try await mutations.commitFileMutation(
                .reconcileEditions(
                    survivorID: winnerID,
                    removedID: loserID,
                    removesExactDuplicateFiles: !discardAssetIDs.isEmpty
                ),
                transaction: transaction,
                affectedBookIDs: [winnerID, loserID],
                affectedWorkIDs: Set([winner.work?.uuid, loser.work?.uuid].compactMap { $0 }),
                affectedCollectionIDs: Set((winner.collections + loser.collections).map(\.id)),
                revertingOnFailure: {
                    preimage.restore(in: modelContext, removing: insertedAsset)
                }
            ) {
                let storedWinner = try mutations.book(id: winnerID)
                let storedLoser = try mutations.book(id: loserID)
                guard Self.generation(of: storedWinner) == winnerGeneration,
                      Self.generation(of: storedLoser) == loserGeneration else {
                    throw CatalogMutationError.staleReconciliation
                }
                if let expectedProposal {
                    guard revalidatedProposal(between: [storedWinner, storedLoser]) == expectedProposal else {
                        throw CatalogMutationError.staleReconciliation
                    }
                }

                let losingWork = storedLoser.work
                let winningFileNames = Set(storedWinner.assets.map(\.fileName))
                let losingAssets = storedLoser.assets
                if !storedWinner.hasDigitalFile, storedLoser.hasDigitalFile {
                    storedWinner.fileName = storedLoser.fileName
                    storedWinner.fileSizeBytes = storedLoser.fileSizeBytes
                    storedWinner.drmProtected = storedLoser.drmProtected
                }
                if losingAssets.isEmpty,
                   storedLoser.hasDigitalFile,
                   !winningFileNames.contains(storedLoser.fileName) {
                    let asset = BookAsset(
                        uuid: storedLoser.uuid,
                        fileName: storedLoser.fileName,
                        origin: .imported,
                        sizeBytes: storedLoser.fileSizeBytes,
                        dateAdded: storedLoser.dateAdded,
                        book: storedWinner
                    )
                    modelContext.insert(asset)
                    insertedAsset = asset
                } else {
                    for asset in losingAssets {
                        if discardAssetIDs.contains(asset.uuid) {
                            modelContext.delete(asset)
                        } else {
                            asset.book = storedWinner
                        }
                    }
                }

                for highlight in storedLoser.highlights { highlight.book = storedWinner }
                for collection in storedLoser.collections
                where !collection.books.contains(where: { $0.uuid == storedWinner.uuid }) {
                    collection.books.append(storedWinner)
                }
                fillEmptyBookMetadata(storedWinner, from: storedLoser)
                storedWinner.hasPhysicalCopy = storedWinner.hasPhysicalCopy || storedLoser.hasPhysicalCopy
                if storedWinner.shelfLocation?.isEmpty != false {
                    storedWinner.shelfLocation = storedLoser.shelfLocation
                }
                mergeReadingHistory(into: storedWinner, from: storedLoser)
                if winnerCoverRollback != nil { storedWinner.coverVersion = coverVersion }

                if storedWinner.work?.preferredEditionUUID == loserID {
                    storedWinner.work?.preferredEditionUUID = winnerID
                }
                storedLoser.work = nil
                modelContext.delete(storedLoser)
                WorkService.pruneIfOrphaned(losingWork, context: modelContext, save: false)
            }
            if !result.isFullyPublished {
                toasts?.info(String(localized: "Edition merge completed; file cleanup will resume automatically."))
            }
        } catch {
            if let winnerCoverRollback { _ = await covers.rollback(winnerCoverRollback) }
            return false
        }

        await covers.invalidate(for: loserID)
        pendingProposals.removeAll { $0.memberUUIDs.contains(loserID) }
        refreshEditionCounts()
        return true
    }

    @discardableResult
    private func reportMutationFailure() -> Bool {
        toasts?.error(String(localized: "Couldn’t save library changes."))
        return false
    }

    /// Re-hashes both sides away from the main actor. Stored fingerprints are
    /// useful for discovery, but physical cleanup requires current byte-level
    /// evidence from a retained file and the file proposed for removal.
    private func verifiedExactDuplicateEvidence(
        winner: Book,
        loser: Book
    ) async -> [ExactDuplicateEvidence] {
        let winnerFiles = winner.assets.compactMap(Self.assetFileSnapshot)
        let loserFiles = loser.assets.compactMap(Self.assetFileSnapshot)
        let sharedStoredHashes = Set(winnerFiles.map(\.storedSHA256))
            .intersection(loserFiles.map(\.storedSHA256))
        guard !sharedStoredHashes.isEmpty else { return [] }

        let retainedCandidates = winnerFiles.filter { sharedStoredHashes.contains($0.storedSHA256) }
        let discardedCandidates = loserFiles.filter { sharedStoredHashes.contains($0.storedSHA256) }
        return await Task.detached(priority: .userInitiated) {
            var actualHashes: [UUID: String] = [:]
            for file in retainedCandidates + discardedCandidates {
                guard !Task.isCancelled,
                      let url = BookFileStore.validatedURL(for: file.fileName),
                      let actual = try? ContentHasher.sha256Cancellable(of: url) else { continue }
                actualHashes[file.assetID] = actual
            }
            guard !Task.isCancelled else { return [] }

            var retainedByHash: [String: [AssetFileSnapshot]] = [:]
            for file in retainedCandidates
            where actualHashes[file.assetID] == file.storedSHA256 {
                retainedByHash[file.storedSHA256, default: []].append(file)
            }

            return discardedCandidates.compactMap { file in
                guard actualHashes[file.assetID] == file.storedSHA256,
                      let retained = retainedByHash[file.storedSHA256]?.first else { return nil }
                return ExactDuplicateEvidence(
                    discardedAssetID: file.assetID,
                    discardedFileName: file.fileName,
                    retainedFileName: retained.fileName,
                    sha256: file.storedSHA256
                )
            }
        }.value
    }

    private static func assetFileSnapshot(_ asset: BookAsset) -> AssetFileSnapshot? {
        guard let hash = asset.contentHash?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !hash.isEmpty,
              ManagedLeafName(rawValue: asset.fileName) != nil else { return nil }
        return AssetFileSnapshot(assetID: asset.uuid, fileName: asset.fileName, storedSHA256: hash)
    }

    private func lookupBook(uuid: UUID) -> Book? {
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.uuid == uuid })
        return try? modelContext.fetch(descriptor).first
    }

    private func preferredBook(in books: [Book]) -> Book? {
        books.min(by: WorkService.editionPrecedes)
    }

    private func revalidatedProposal(between books: [Book]) -> EditionMatchProposal? {
        guard books.count == 2 else { return nil }
        return EditionMatcher.proposals(
            for: Self.candidate(books[0]),
            against: [Self.candidate(books[1])]
        ).first
    }

    private func replacePendingProposal(
        _ stale: EditionMatchProposal,
        with current: EditionMatchProposal?
    ) {
        pendingProposals.removeAll { $0.pairKey == stale.pairKey }
        guard let current,
              !dismissedPairKeys.contains(current.pairKey) else { return }
        pendingProposals.append(current)
        pendingProposals.sort(by: EditionMatcher.proposalPrecedes)
    }

    private func removeResolvedProposals() {
        let workByBook = Dictionary(uniqueKeysWithValues: modelContext.allBooks().compactMap { book in
            book.work.map { (book.uuid, $0.uuid) }
        })
        pendingProposals.removeAll { proposal in
            guard proposal.memberUUIDs.count == 2,
                  let left = workByBook[proposal.memberUUIDs[0]],
                  let right = workByBook[proposal.memberUUIDs[1]] else { return true }
            guard left == right else { return false }
            switch proposal.verdict {
            case .sameWorkOtherEdition, .similarItem:
                return true
            case .duplicateFile, .sameEditionOtherFormat:
                // Being grouped under one Work does not resolve duplicate bytes or
                // two edition records that still need an explicit reviewed merge.
                return false
            }
        }
    }

    private static func candidate(_ book: Book) -> EditionCandidate {
        EditionCandidate(
            uuid: book.uuid,
            workUUID: book.work?.uuid,
            title: book.displayTitle,
            author: book.author,
            language: book.language,
            translator: book.translator,
            isbn: book.isbn,
            publisher: book.publisher,
            year: book.year,
            format: book.format,
            sizeBytes: book.fileSizeBytes,
            contentHashes: Set(book.assets.compactMap(\.contentHash)),
            openLibraryWorkKey: book.work?.openLibraryWorkKey
        )
    }

    private static func generation(of book: Book) -> BookGeneration {
        BookGeneration(
            candidate: candidate(book),
            fileName: book.fileName,
            fileSizeBytes: book.fileSizeBytes,
            coverVersion: book.coverVersion,
            assets: book.assets.map { asset in
                AssetGeneration(
                    uuid: asset.uuid,
                    fileName: asset.fileName,
                    contentHash: asset.contentHash,
                    sizeBytes: asset.sizeBytes,
                    dateAdded: asset.dateAdded,
                    validationStatus: asset.validationStatus
                )
            }.sorted { $0.uuid.uuidString < $1.uuid.uuidString }
        )
    }

    private func fillEmptyWorkMetadata(_ work: Work, from book: Book) {
        work.title = fill(work.title, book.title)
        work.author = fill(work.author, book.author)
        work.originalLanguage = fill(work.originalLanguage, book.language)
        work.refreshMatchKey()
    }

    private func fillEmptyWorkMetadata(_ destination: Work, from source: Work) {
        destination.title = fill(destination.title, source.title)
        destination.author = fill(destination.author, source.author)
        destination.originalTitle = fill(destination.originalTitle, source.originalTitle)
        destination.originalLanguage = fill(destination.originalLanguage, source.originalLanguage)
        destination.openLibraryWorkKey = fill(destination.openLibraryWorkKey, source.openLibraryWorkKey)
        destination.hardcoverBookID = fill(destination.hardcoverBookID, source.hardcoverBookID)
        destination.notes = fill(destination.notes, source.notes)
        destination.refreshMatchKey()
    }

    private func fillEmptyBookMetadata(_ winner: Book, from loser: Book) {
        winner.title = fill(winner.title, loser.title)
        winner.author = fill(winner.author, loser.author)
        winner.translator = fill(winner.translator, loser.translator)
        winner.publisher = fill(winner.publisher, loser.publisher)
        winner.year = fill(winner.year, loser.year)
        winner.language = fill(winner.language, loser.language)
        winner.isbn = fill(winner.isbn, loser.isbn)
        winner.series = fill(winner.series, loser.series)
        winner.seriesIndex = fill(winner.seriesIndex, loser.seriesIndex)
        winner.editionStatement = fill(winner.editionStatement, loser.editionStatement)
        winner.bookDescription = fill(winner.bookDescription, loser.bookDescription)
        if winner.tags.isEmpty { winner.tags = loser.tags }
        if winner.rating == nil { winner.rating = loser.rating }
        if winner.pageCount == nil { winner.pageCount = loser.pageCount }
        winner.notes = fill(winner.notes, loser.notes)
    }

    private func mergeReadingHistory(into winner: Book, from loser: Book) {
        let losingSessions = loser.readingSessions
        for session in losingSessions {
            session.book = winner
        }
        if winner.refreshReadingSummaryFromHistory() { return }

        if readingStatusRank(loser.readingStatus) > readingStatusRank(winner.readingStatus) {
            winner.readingStatusRaw = loser.readingStatusRaw
        }
        winner.dateStarted = [winner.dateStarted, loser.dateStarted].compactMap { $0 }.min()
        if winner.readingStatus == .finished {
            winner.dateFinished = [winner.dateFinished, loser.dateFinished].compactMap { $0 }.max()
        }
    }

    private func readingStatusRank(_ status: ReadingStatus) -> Int {
        switch status {
        case .unread: 0
        case .didNotFinish: 1
        case .paused: 2
        case .reading: 3
        case .finished: 4
        }
    }

    private func fill(_ current: String?, _ newValue: String?) -> String? {
        if let current, !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return current }
        guard let newValue = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !newValue.isEmpty else {
            return current
        }
        return newValue
    }

    private func persistDismissals() {
        defaults.set(dismissedPairKeys.sorted(), forKey: dismissedDefaultsKey)
    }
}
