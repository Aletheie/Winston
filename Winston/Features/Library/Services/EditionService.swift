import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class EditionService {
    struct WorkSnapshot: Hashable, Sendable {
        let title: String?
        let author: String?
        let originalTitle: String?
        let originalLanguage: String?
        let openLibraryWorkKey: String?
        let hardcoverBookID: String?
        let notes: String?
    }

    struct AssignmentUndo: Hashable, Sendable {
        let bookUUID: UUID
        let previousWork: WorkSnapshot
    }

    private let modelContext: ModelContext
    private let defaults: UserDefaults
    private let covers: CoverRepository
    private let mutations: CatalogMutationService
    private let toasts: ToastCenter?
    private let dismissedDefaultsKey = "editionMatcherDismissedPairKeys"

    private(set) var pendingProposals: [EditionMatchProposal] = []
    private(set) var editionCounts: [UUID: Int] = [:]
    private var dismissedPairKeys: Set<String>

    init(
        modelContext: ModelContext,
        defaults: UserDefaults = .standard,
        covers: CoverRepository = .shared,
        mutations: CatalogMutationService? = nil,
        toasts: ToastCenter? = nil
    ) {
        self.modelContext = modelContext
        self.defaults = defaults
        self.covers = covers
        self.mutations = mutations ?? CatalogMutationService(modelContext: modelContext)
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

    @discardableResult
    func evaluate(_ book: Book, allowAutomaticAssignment: Bool = true) -> AssignmentUndo? {
        let allBooks = modelContext.allBooks()
        var index = EditionMatcher.CandidateIndex(allBooks.map(Self.candidate))
        return evaluate(
            book,
            allowAutomaticAssignment: allowAutomaticAssignment,
            index: &index,
            booksByUUID: Dictionary(uniqueKeysWithValues: allBooks.map { ($0.uuid, $0) }),
            incomingUUIDs: [book.uuid]
        )
    }

    func evaluate(_ books: [Book], allowAutomaticAssignment: Bool = true) -> [UUID: AssignmentUndo] {
        let books = books.filter { $0.modelContext != nil }
        guard !books.isEmpty else { return [:] }
        let allBooks = modelContext.allBooks()
        var index = EditionMatcher.CandidateIndex(allBooks.map(Self.candidate))
        let booksByUUID = Dictionary(uniqueKeysWithValues: allBooks.map { ($0.uuid, $0) })
        let incomingUUIDs = Set(books.map(\.uuid))
        var assignments: [UUID: AssignmentUndo] = [:]
        for book in books {
            if let undo = evaluate(
                book,
                allowAutomaticAssignment: allowAutomaticAssignment,
                index: &index,
                booksByUUID: booksByUUID,
                incomingUUIDs: incomingUUIDs
            ) {
                assignments[book.uuid] = undo
            }
        }
        return assignments
    }

    private func evaluate(
        _ book: Book,
        allowAutomaticAssignment: Bool,
        index: inout EditionMatcher.CandidateIndex,
        booksByUUID: [UUID: Book],
        incomingUUIDs: Set<UUID>
    ) -> AssignmentUndo? {
        let candidate = Self.candidate(book)
        let matches = index.matches(for: candidate).filter {
            candidate.workUUID == nil || candidate.workUUID != $0.workUUID
        }
        let proposals = EditionMatcher.proposals(for: candidate, against: matches)
            .filter { !dismissedPairKeys.contains($0.pairKey) }
        guard !proposals.isEmpty else { return nil }

        let containsDestructiveMatch = proposals.contains {
            $0.verdict == .duplicateFile || $0.verdict == .sameEditionOtherFormat
        }
        if allowAutomaticAssignment, !containsDestructiveMatch,
           (book.work?.editions.count ?? 0) <= 1,
           let other = automaticTarget(
               for: book,
               proposals: proposals,
               booksByUUID: booksByUUID,
               incomingUUIDs: incomingUUIDs
           ),
           let target = other.work {
            let undo = assignmentUndo(for: book)
            guard assign(book, to: target) != nil else { return nil }
            index.update(Self.candidate(book))
            pendingProposals.removeAll { $0.memberUUIDs.contains(book.uuid) }
            return undo
        }

        let existing = Set(pendingProposals.map(\.pairKey))
        pendingProposals.append(contentsOf: proposals.filter { !existing.contains($0.pairKey) })
        pendingProposals.sort(by: EditionMatcher.proposalPrecedes)
        return nil
    }

    private func automaticTarget(
        for book: Book,
        proposals: [EditionMatchProposal],
        booksByUUID: [UUID: Book],
        incomingUUIDs: Set<UUID>
    ) -> Book? {
        var best: Book?
        for proposal in proposals
        where proposal.verdict == .sameWorkOtherEdition && proposal.confidence == .high {
            guard let uuid = proposal.memberUUIDs.first(where: { $0 != book.uuid }),
                  let candidate = booksByUUID[uuid] else { continue }
            guard let current = best else { best = candidate; continue }
            let candidateRank = (
                incomingUUIDs.contains(candidate.uuid) ? 1 : 0,
                -(candidate.work?.editions.count ?? 0),
                candidate.uuid.uuidString
            )
            let currentRank = (
                incomingUUIDs.contains(current.uuid) ? 1 : 0,
                -(current.work?.editions.count ?? 0),
                current.uuid.uuidString
            )
            if candidateRank < currentRank { best = candidate }
        }
        return best
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
            succeeded = await absorb(loser, into: winner)
        case .duplicateFile:
            guard let winner = preferredBook(in: members),
                  let loser = members.first(where: { $0.uuid != winner.uuid }) else { return false }
            succeeded = await absorb(loser, into: winner, discardDuplicateAssets: true)
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

    @discardableResult
    func mergeEditions(_ books: [Book]) async -> Book? {
        let books = books.filter { $0.modelContext != nil }
        guard Set(books.map(\.uuid)).count > 1,
              let winner = preferredBook(in: books) else { return nil }
        for loser in books where loser.uuid != winner.uuid {
            guard await absorb(loser, into: winner) else { return winner }
        }
        return winner
    }

    @discardableResult
    func absorb(_ loser: Book, into winner: Book, discardDuplicateAssets: Bool = false) async -> Bool {
        guard loser.uuid != winner.uuid,
              loser.modelContext != nil,
              winner.modelContext != nil else { return false }
        let losingWork = loser.work
        let winningHashes = Set(winner.assets.compactMap(\.contentHash))
        let winningFileNames = Set(winner.assets.map(\.fileName))
        let losingAssets = loser.assets
        var discardedFileNames: [String] = []
        if !winner.hasDigitalFile, loser.hasDigitalFile {
            winner.fileName = loser.fileName
            winner.fileSizeBytes = loser.fileSizeBytes
            winner.drmProtected = loser.drmProtected
        }
        if losingAssets.isEmpty, loser.hasDigitalFile, !winningFileNames.contains(loser.fileName) {
            let asset = BookAsset(
                uuid: loser.uuid,
                fileName: loser.fileName,
                origin: .imported,
                sizeBytes: loser.fileSizeBytes,
                dateAdded: loser.dateAdded,
                book: winner
            )
            modelContext.insert(asset)
        } else {
            for asset in losingAssets {
                if discardDuplicateAssets,
                   let hash = asset.contentHash,
                   winningHashes.contains(hash) {
                    if !winningFileNames.contains(asset.fileName) {
                        discardedFileNames.append(asset.fileName)
                    }
                    modelContext.delete(asset)
                } else {
                    asset.book = winner
                }
            }
        }

        for highlight in loser.highlights { highlight.book = winner }
        for collection in loser.collections
        where !collection.books.contains(where: { $0.uuid == winner.uuid }) {
            collection.books.append(winner)
        }
        fillEmptyBookMetadata(winner, from: loser)
        winner.hasPhysicalCopy = winner.hasPhysicalCopy || loser.hasPhysicalCopy
        if winner.shelfLocation?.isEmpty != false { winner.shelfLocation = loser.shelfLocation }
        mergeReadingHistory(into: winner, from: loser)
        let winnerCoverToken = await covers.beginUserMutation(for: winner.uuid)
        let winnerCoverRollback = await covers.copy(
            from: loser.uuid,
            using: winnerCoverToken,
            onlyIfMissing: true
        )
        if winnerCoverRollback != nil {
            winner.coverVersion += 1
        }

        modelContext.delete(loser)
        do {
            try modelContext.saveAndPublish()
        } catch {
            modelContext.rollback()
            if let winnerCoverRollback { _ = await covers.rollback(winnerCoverRollback) }
            return false
        }

        let loserUUID = loser.uuid
        _ = await covers.deletePermanently(for: loserUUID)
        Task.detached(priority: .utility) {
            for fileName in discardedFileNames {
                BookFileStore.delete(fileName: fileName)
            }
        }
        pendingProposals.removeAll { $0.memberUUIDs.contains(loser.uuid) }
        WorkService.pruneIfOrphaned(losingWork, context: modelContext)
        refreshEditionCounts()
        return true
    }

    @discardableResult
    func undo(_ undo: AssignmentUndo) -> Bool {
        guard let book = lookupBook(uuid: undo.bookUUID) else { return false }
        let currentWorkID = book.work?.uuid
        let snapshot = undo.previousWork
        let restored = Work(title: snapshot.title, author: snapshot.author)
        restored.originalTitle = snapshot.originalTitle
        restored.originalLanguage = snapshot.originalLanguage
        restored.openLibraryWorkKey = snapshot.openLibraryWorkKey
        restored.hardcoverBookID = snapshot.hardcoverBookID
        restored.notes = snapshot.notes
        restored.preferredEditionUUID = book.uuid
        do {
            try mutations.commit(
                .assignEdition(bookIDs: [undo.bookUUID], workID: restored.uuid),
                affectedBookIDs: [undo.bookUUID],
                affectedWorkIDs: Set([restored.uuid, currentWorkID].compactMap { $0 })
            ) {
                let storedBook = try mutations.book(id: undo.bookUUID)
                let current = storedBook.work
                modelContext.insert(restored)
                storedBook.work = restored
                WorkService.pruneIfOrphaned(current, context: modelContext, save: false)
            }
        } catch {
            return reportMutationFailure()
        }
        refreshEditionCounts()
        return true
    }

    @discardableResult
    private func reportMutationFailure() -> Bool {
        toasts?.error(String(localized: "Couldn’t save library changes."))
        return false
    }

    private func assignmentUndo(for book: Book) -> AssignmentUndo {
        let work = book.work
        return AssignmentUndo(
            bookUUID: book.uuid,
            previousWork: WorkSnapshot(
                title: work?.title ?? book.title,
                author: work?.author ?? book.author,
                originalTitle: work?.originalTitle,
                originalLanguage: work?.originalLanguage,
                openLibraryWorkKey: work?.openLibraryWorkKey,
                hardcoverBookID: work?.hardcoverBookID,
                notes: work?.notes
            )
        )
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
            return left == right
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
