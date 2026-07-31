import Foundation

/// Stable file evidence used by every catalog import source.
///
/// A fingerprint is intentionally independent from source paths and SwiftData.
/// It can be produced while a file is staged and safely reconciled off the
/// main actor.
nonisolated struct ImportFingerprint: Sendable, Equatable, Hashable {
    let contentHashes: Set<String>
    let formats: Set<String>

    init(contentHashes: Set<String>, formats: Set<String>) {
        self.contentHashes = Set(
            contentHashes.map { $0.lowercased() }.filter { !$0.isEmpty }
        )
        self.formats = Set(
            formats.map { $0.lowercased() }.filter { !$0.isEmpty }
        )
    }

    init(contentHash: String, format: String) {
        self.init(contentHashes: [contentHash], formats: [format])
    }
}

/// Identity evidence extracted from the file or supplied by an import source.
nonisolated struct ImportIdentityRecord: Sendable, Equatable, Hashable {
    let title: String
    let author: String?
    let isbn: String?
    let language: String?
    let publisher: String?
    let year: String?
}

/// Rebuildable catalog input for `ImportReconciler`.
nonisolated struct ImportCatalogRecord: Sendable, Equatable {
    let bookID: UUID
    let workID: UUID?
    let fingerprint: ImportFingerprint
    let identity: ImportIdentityRecord
}

/// One source-neutral candidate entering the model-proposal phase.
nonisolated struct ImportReconciliationCandidate: Sendable, Equatable {
    let itemID: String
    let proposedBookID: UUID
    let proposedWorkID: UUID
    let fingerprint: ImportFingerprint
    let identity: ImportIdentityRecord
}

/// The complete set of non-writing reconciliation outcomes.
nonisolated enum ImportReconciliation: Sendable, Equatable {
    case exactDuplicate(existingBookID: UUID)
    case addFormatToEdition(existingBookID: UUID, workID: UUID?)
    case createAnotherEdition(workID: UUID)
    case createNewWork
    case ambiguousReview(candidateWorkIDs: [UUID])
}

/// Immutable authority handed to the main-actor mutation boundary.
nonisolated struct ImportModelProposal: Sendable, Equatable {
    let candidate: ImportReconciliationCandidate
    let reconciliation: ImportReconciliation

    var targetBookID: UUID {
        switch reconciliation {
        case .exactDuplicate(let existingBookID),
             .addFormatToEdition(let existingBookID, _):
            existingBookID
        case .createAnotherEdition, .createNewWork, .ambiguousReview:
            candidate.proposedBookID
        }
    }
}

/// Conservative, value-only catalog reconciliation shared by standard and
/// Calibre imports. It owns indexes, but never models, contexts, or files.
nonisolated struct ImportReconciler: Sendable {
    private var records: [UUID: ImportCatalogRecord]
    private var bookIDsByHash: [String: Set<UUID>]
    private var bookIDsByISBN: [String: Set<UUID>]
    private var bookIDsByIdentity: [BookMatchKey: Set<UUID>]

    init(records: [ImportCatalogRecord]) {
        self.records = [:]
        self.bookIDsByHash = [:]
        self.bookIDsByISBN = [:]
        self.bookIDsByIdentity = [:]
        for record in records where self.records[record.bookID] == nil {
            insert(record)
        }
    }

    func reconcile(
        fingerprint: ImportFingerprint,
        identity: ImportIdentityRecord
    ) -> ImportReconciliation {
        var hashMatchIDs: Set<UUID> = []
        for hash in fingerprint.contentHashes {
            hashMatchIDs.formUnion(bookIDsByHash[hash] ?? [])
        }
        let hashMatches = orderedRecords(with: hashMatchIDs)

        if !fingerprint.contentHashes.isEmpty {
            // Exactness belongs to one concrete edition. Never combine hash
            // evidence from multiple records: doing so can silently skip a
            // multi-file import that no existing edition actually contains.
            if let target = hashMatches.first(where: {
                fingerprint.contentHashes.isSubset(
                    of: $0.fingerprint.contentHashes
                )
            }) {
                return .exactDuplicate(existingBookID: target.bookID)
            }
            if hashMatches.count == 1, let target = hashMatches.first {
                return .addFormatToEdition(
                    existingBookID: target.bookID,
                    workID: target.workID
                )
            }
            if hashMatches.count > 1 {
                return .ambiguousReview(candidateWorkIDs: uniqueWorkIDs(in: hashMatches))
            }
        }

        let normalizedISBN = EditionMatcher.normalizedISBN(identity.isbn)
        if !normalizedISBN.isEmpty {
            let isbnMatches = orderedRecords(with: bookIDsByISBN[normalizedISBN] ?? [])
            if isbnMatches.count == 1, let target = isbnMatches.first {
                return .addFormatToEdition(
                    existingBookID: target.bookID,
                    workID: target.workID
                )
            }
            if isbnMatches.count > 1 {
                return .ambiguousReview(candidateWorkIDs: uniqueWorkIDs(in: isbnMatches))
            }
        }

        let identityKey = BookMatchKey(title: identity.title, author: identity.author)
        if identityKey.isComplete {
            let identityMatches = orderedRecords(
                with: bookIDsByIdentity[identityKey] ?? []
            )
            let workIDs = uniqueWorkIDs(in: identityMatches)
            if workIDs.count == 1, let workID = workIDs.first,
               hasEditionDifference(identity, comparedWith: identityMatches) {
                return .createAnotherEdition(workID: workID)
            }
            if !identityMatches.isEmpty {
                return .ambiguousReview(candidateWorkIDs: workIDs)
            }
        }

        return .createNewWork
    }

    func contains(contentHash: String) -> Bool {
        !(bookIDsByHash[contentHash.lowercased()]?.isEmpty ?? true)
    }

    mutating func record(
        _ candidate: ImportReconciliationCandidate,
        reconciliation: ImportReconciliation
    ) {
        switch reconciliation {
        case .exactDuplicate:
            break

        case .addFormatToEdition(let existingBookID, _):
            guard var existing = records[existingBookID] else { return }
            let newHashes = candidate.fingerprint.contentHashes.subtracting(
                existing.fingerprint.contentHashes
            )
            existing = ImportCatalogRecord(
                bookID: existing.bookID,
                workID: existing.workID,
                fingerprint: ImportFingerprint(
                    contentHashes: existing.fingerprint.contentHashes
                        .union(candidate.fingerprint.contentHashes),
                    formats: existing.fingerprint.formats
                        .union(candidate.fingerprint.formats)
                ),
                identity: existing.identity
            )
            records[existingBookID] = existing
            for hash in newHashes {
                bookIDsByHash[hash, default: []].insert(existingBookID)
            }

        case .createAnotherEdition(let workID):
            insert(catalogRecord(from: candidate, workID: workID))

        case .createNewWork, .ambiguousReview:
            insert(catalogRecord(from: candidate, workID: candidate.proposedWorkID))
        }
    }

    /// Applies a durable catalog change set without rebuilding the complete
    /// in-memory index. IDs are removed first so deletions and updates share
    /// one deterministic path.
    mutating func synchronize(
        records changedRecords: [ImportCatalogRecord],
        removingBookIDs: Set<UUID>
    ) {
        var idsToRemove = removingBookIDs
        idsToRemove.formUnion(changedRecords.map(\.bookID))
        for bookID in idsToRemove {
            remove(bookID: bookID)
        }
        for record in changedRecords.sorted(by: {
            $0.bookID.uuidString < $1.bookID.uuidString
        }) {
            insert(record)
        }
    }

    private func hasEditionDifference(
        _ identity: ImportIdentityRecord,
        comparedWith matches: [ImportCatalogRecord]
    ) -> Bool {
        let candidateISBN = EditionMatcher.normalizedISBN(identity.isbn)
        let existingISBNs = Set(matches.map {
            EditionMatcher.normalizedISBN($0.identity.isbn)
        }.filter { !$0.isEmpty })
        if !candidateISBN.isEmpty, !existingISBNs.isEmpty,
           !existingISBNs.contains(candidateISBN) {
            return true
        }

        let language = normalizedLanguageValue(identity.language)
        let existingLanguages = Set(matches.map {
            normalizedLanguageValue($0.identity.language)
        }.filter { !$0.isEmpty })
        if !language.isEmpty, !existingLanguages.isEmpty,
           !existingLanguages.contains(language) {
            return true
        }

        let publisher = normalizedValue(identity.publisher)
        let year = normalizedValue(identity.year)
        return !publisher.isEmpty && !year.isEmpty && matches.contains {
            let existingPublisher = normalizedValue($0.identity.publisher)
            let existingYear = normalizedValue($0.identity.year)
            return !existingPublisher.isEmpty && !existingYear.isEmpty
                && (publisher != existingPublisher || year != existingYear)
        }
    }

    private func uniqueWorkIDs(in matches: [ImportCatalogRecord]) -> [UUID] {
        Array(Set(matches.compactMap(\.workID))).sorted { $0.uuidString < $1.uuidString }
    }

    private func orderedRecords(with ids: Set<UUID>) -> [ImportCatalogRecord] {
        ids.compactMap { records[$0] }
            .sorted { $0.bookID.uuidString < $1.bookID.uuidString }
    }

    private mutating func insert(_ record: ImportCatalogRecord) {
        records[record.bookID] = record
        for hash in record.fingerprint.contentHashes {
            bookIDsByHash[hash, default: []].insert(record.bookID)
        }
        let isbn = EditionMatcher.normalizedISBN(record.identity.isbn)
        if !isbn.isEmpty {
            bookIDsByISBN[isbn, default: []].insert(record.bookID)
        }
        let identity = BookMatchKey(
            title: record.identity.title,
            author: record.identity.author
        )
        if identity.isComplete {
            bookIDsByIdentity[identity, default: []].insert(record.bookID)
        }
    }

    private mutating func remove(bookID: UUID) {
        guard let record = records.removeValue(forKey: bookID) else { return }
        for hash in record.fingerprint.contentHashes {
            bookIDsByHash[hash]?.remove(bookID)
            if bookIDsByHash[hash]?.isEmpty == true {
                bookIDsByHash.removeValue(forKey: hash)
            }
        }
        let isbn = EditionMatcher.normalizedISBN(record.identity.isbn)
        if !isbn.isEmpty {
            bookIDsByISBN[isbn]?.remove(bookID)
            if bookIDsByISBN[isbn]?.isEmpty == true {
                bookIDsByISBN.removeValue(forKey: isbn)
            }
        }
        let identity = BookMatchKey(
            title: record.identity.title,
            author: record.identity.author
        )
        if identity.isComplete {
            bookIDsByIdentity[identity]?.remove(bookID)
            if bookIDsByIdentity[identity]?.isEmpty == true {
                bookIDsByIdentity.removeValue(forKey: identity)
            }
        }
    }

    private func catalogRecord(
        from candidate: ImportReconciliationCandidate,
        workID: UUID
    ) -> ImportCatalogRecord {
        ImportCatalogRecord(
            bookID: candidate.proposedBookID,
            workID: workID,
            fingerprint: candidate.fingerprint,
            identity: candidate.identity
        )
    }

    private func normalizedValue(_ value: String?) -> String {
        (value ?? "").normalizedMatchKey
    }

    private func normalizedLanguageValue(_ value: String?) -> String {
        let language = MetadataNormalizer.language(value)
        return language.canonicalTag
            ?? MetadataNormalizer.comparisonKey(value)
    }
}

/// Executes the value-only reconciliation/proposal step away from MainActor.
nonisolated enum ImportProposalBuilder {
    @concurrent
    static func build(
        candidate: ImportReconciliationCandidate,
        using reconciler: ImportReconciler,
        assigningTo requestedWorkID: UUID? = nil
    ) async -> ImportModelProposal {
        var decision = reconciler.reconcile(
            fingerprint: candidate.fingerprint,
            identity: candidate.identity
        )
        if let requestedWorkID {
            switch decision {
            case .exactDuplicate:
                break
            case .addFormatToEdition(_, let workID) where workID == requestedWorkID:
                break
            case .addFormatToEdition, .createAnotherEdition,
                 .createNewWork, .ambiguousReview:
                decision = .createAnotherEdition(workID: requestedWorkID)
            }
        }
        return ImportModelProposal(candidate: candidate, reconciliation: decision)
    }
}
