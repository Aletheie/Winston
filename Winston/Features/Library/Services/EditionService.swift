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
    private let dismissedDefaultsKey = "editionMatcherDismissedPairKeys"

    private(set) var pendingProposals: [EditionMatchProposal] = []
    private(set) var editionCounts: [UUID: Int] = [:]
    private var dismissedPairKeys: Set<String>

    init(modelContext: ModelContext, defaults: UserDefaults = .standard) {
        self.modelContext = modelContext
        self.defaults = defaults
        self.dismissedPairKeys = Set(defaults.stringArray(forKey: dismissedDefaultsKey) ?? [])
        refreshEditionCounts()
    }

    var pendingCount: Int { pendingProposals.count }

    func refreshEditionCounts() {
        var counts: [UUID: Int] = [:]
        let works = (try? modelContext.fetch(FetchDescriptor<Work>())) ?? []
        for work in works {
            let editions = work.editions
            guard editions.count > 1 else { continue }
            for edition in editions { counts[edition.uuid] = editions.count }
        }
        editionCounts = counts
    }

    func updateWork(_ work: Work, title: String, author: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
        work.title = trimmedTitle.isEmpty ? nil : trimmedTitle
        work.author = trimmedAuthor.isEmpty ? nil : trimmedAuthor
        work.refreshMatchKey()
        modelContext.saveQuietly()
    }

    func setPreferred(_ book: Book, in work: Work) {
        WorkService.setPreferred(book, in: work, context: modelContext)
    }

    func scanLibrary() async {
        let candidates = modelContext.allBooks().map(Self.candidate)
        let proposals = await EditionMatcher.scan(candidates)
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
            assign(book, to: target)
            guard book.work?.uuid == target.uuid else { return nil }
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
    func approve(_ proposal: EditionMatchProposal) -> Bool {
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
            succeeded = absorb(loser, into: winner)
        case .duplicateFile:
            guard let winner = preferredBook(in: members),
                  let loser = members.first(where: { $0.uuid != winner.uuid }) else { return false }
            succeeded = absorb(loser, into: winner, discardDuplicateAssets: true)
        }
        if succeeded {
            pendingProposals.removeAll { $0.pairKey == proposal.pairKey }
            removeResolvedProposals()
        }
        return succeeded
    }

    func removeProposals(referencing bookUUID: UUID) {
        pendingProposals.removeAll { $0.memberUUIDs.contains(bookUUID) }
    }

    @discardableResult
    func assign(_ book: Book, to work: Work) -> Work {
        guard book.modelContext != nil, work.modelContext != nil else { return work }
        let previous = book.work
        book.work = work
        fillEmptyWorkMetadata(work, from: book)
        work.preferredEditionUUID = WorkService.preferredEdition(in: work)?.uuid ?? book.uuid
        modelContext.saveQuietly()
        WorkService.pruneIfOrphaned(previous, context: modelContext)
        refreshEditionCounts()
        removeResolvedProposals()
        return work
    }

    @discardableResult
    func groupIntoWork(_ books: [Book]) -> Work? {
        let books = books.filter { $0.modelContext != nil }
        guard Set(books.map(\.uuid)).count > 1 else { return nil }
        guard let winner = preferredBook(in: books) else { return nil }
        let target = winner.work ?? {
            let work = Work(title: winner.title, author: winner.author, dateCreated: winner.dateAdded)
            modelContext.insert(work)
            winner.work = work
            return work
        }()
        var seenWorkUUIDs: Set<UUID> = []
        let previousWorks = books.compactMap(\.work).filter {
            $0.uuid != target.uuid && seenWorkUUIDs.insert($0.uuid).inserted
        }
        for book in books {
            book.work = target
            fillEmptyWorkMetadata(target, from: book)
        }
        target.preferredEditionUUID = WorkService.preferredEdition(in: target)?.uuid ?? winner.uuid
        modelContext.saveQuietly()
        for work in previousWorks { WorkService.pruneIfOrphaned(work, context: modelContext, save: false) }
        modelContext.saveQuietly()
        refreshEditionCounts()
        removeResolvedProposals()
        return target
    }

    @discardableResult
    func mergeWorks(_ source: Work, into destination: Work) -> Work {
        guard source.uuid != destination.uuid,
              source.modelContext != nil,
              destination.modelContext != nil else { return destination }
        fillEmptyWorkMetadata(destination, from: source)
        let editions = source.editions
        for book in editions { book.work = destination }
        destination.preferredEditionUUID = WorkService.preferredEdition(in: destination)?.uuid
        modelContext.saveQuietly()
        WorkService.pruneIfOrphaned(source, context: modelContext)
        refreshEditionCounts()
        removeResolvedProposals()
        return destination
    }

    @discardableResult
    func detach(_ book: Book) -> Work? {
        guard book.modelContext != nil else { return nil }
        let previous = book.work
        let work = Work(title: book.title, author: book.author, dateCreated: Date())
        work.originalLanguage = book.language
        work.preferredEditionUUID = book.uuid
        modelContext.insert(work)
        book.work = work
        modelContext.saveQuietly()
        WorkService.pruneIfOrphaned(previous, context: modelContext)
        refreshEditionCounts()
        return work
    }

    func mergeSurvivor(among books: [Book]) -> Book? {
        preferredBook(in: books)
    }

    @discardableResult
    func mergeEditions(_ books: [Book]) -> Book? {
        let books = books.filter { $0.modelContext != nil }
        guard Set(books.map(\.uuid)).count > 1,
              let winner = preferredBook(in: books) else { return nil }
        for loser in books where loser.uuid != winner.uuid {
            guard absorb(loser, into: winner) else { return winner }
        }
        return winner
    }

    @discardableResult
    func absorb(_ loser: Book, into winner: Book, discardDuplicateAssets: Bool = false) -> Bool {
        guard loser.uuid != winner.uuid,
              loser.modelContext != nil,
              winner.modelContext != nil else { return false }
        let losingWork = loser.work
        let winningHashes = Set(winner.assets.compactMap(\.contentHash))
        let winningFileNames = Set(winner.assets.map(\.fileName))
        let losingAssets = loser.assets
        var discardedFileNames: [String] = []
        if losingAssets.isEmpty, !winningFileNames.contains(loser.fileName) {
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
        mergeReadingHistory(into: winner, from: loser)
        let installedWinnerCover: Bool
        if !CoverStore.exists(for: winner.uuid),
           let cover = CoverStore.load(for: loser.uuid),
           CoverStore.save(cover, for: winner.uuid) {
            winner.coverVersion += 1
            installedWinnerCover = true
        } else {
            installedWinnerCover = false
        }

        modelContext.delete(loser)
        do {
            try modelContext.save()
            LibraryMutationLog.shared.bump()
        } catch {
            modelContext.rollback()
            if installedWinnerCover { CoverStore.delete(for: winner.uuid) }
            return false
        }

        discardedFileNames.forEach { BookFileStore.delete(fileName: $0) }
        CoverStore.delete(for: loser.uuid)
        pendingProposals.removeAll { $0.memberUUIDs.contains(loser.uuid) }
        WorkService.pruneIfOrphaned(losingWork, context: modelContext)
        refreshEditionCounts()
        return true
    }

    func undo(_ undo: AssignmentUndo) {
        guard let book = lookupBook(uuid: undo.bookUUID) else { return }
        let current = book.work
        let snapshot = undo.previousWork
        let restored = Work(title: snapshot.title, author: snapshot.author)
        restored.originalTitle = snapshot.originalTitle
        restored.originalLanguage = snapshot.originalLanguage
        restored.openLibraryWorkKey = snapshot.openLibraryWorkKey
        restored.hardcoverBookID = snapshot.hardcoverBookID
        restored.notes = snapshot.notes
        restored.preferredEditionUUID = book.uuid
        modelContext.insert(restored)
        book.work = restored
        modelContext.saveQuietly()
        WorkService.pruneIfOrphaned(current, context: modelContext)
        refreshEditionCounts()
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

        let rank: [ReadingStatus: Int] = [
            .unread: 0,
            .didNotFinish: 1,
            .paused: 2,
            .reading: 3,
            .finished: 4,
        ]
        if (rank[loser.readingStatus] ?? 0) > (rank[winner.readingStatus] ?? 0) {
            winner.readingStatusRaw = loser.readingStatusRaw
        }
        winner.dateStarted = [winner.dateStarted, loser.dateStarted].compactMap { $0 }.min()
        if winner.readingStatus == .finished {
            winner.dateFinished = [winner.dateFinished, loser.dateFinished].compactMap { $0 }.max()
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
