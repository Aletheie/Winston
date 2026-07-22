import Foundation

nonisolated struct CalibreImportCatalogBook: Sendable, Equatable {
    let bookID: UUID
    let workID: UUID?
    let title: String
    let author: String?
    let isbn: String?
    let language: String?
    let publisher: String?
    let year: String?
    var contentHashes: Set<String>
    var formats: Set<String>
}

nonisolated struct CalibreImportCandidate: Sendable, Equatable {
    let bookID: UUID
    let workID: UUID
    let title: String
    let author: String?
    let isbn: String?
    let language: String?
    let publisher: String?
    let year: String?
    let contentHashes: Set<String>
    let formats: Set<String>
}

/// Conservative identity reconciliation for Calibre imports.
///
/// Only byte-identical content can be skipped. ISBN may merge another format
/// into an existing edition, while title/author matches either create a known
/// different edition or remain reviewable instead of disappearing silently.
nonisolated struct CalibreImportReconciler: Sendable {
    private var books: [UUID: CalibreImportCatalogBook]
    private var bookIDsByHash: [String: Set<UUID>]
    private var bookIDsByISBN: [String: Set<UUID>]
    private var bookIDsByIdentity: [BookMatchKey: Set<UUID>]

    init(books: [CalibreImportCatalogBook]) {
        self.books = [:]
        self.bookIDsByHash = [:]
        self.bookIDsByISBN = [:]
        self.bookIDsByIdentity = [:]
        for rawBook in books {
            let book = Self.normalized(rawBook)
            guard self.books[book.bookID] == nil else { continue }
            insert(book)
        }
    }

    func decision(for rawCandidate: CalibreImportCandidate) -> CalibreImportDecision {
        let candidate = Self.normalized(rawCandidate)
        let incomingHashes = candidate.contentHashes
        var hashMatchIDs: Set<UUID> = []
        for hash in incomingHashes {
            hashMatchIDs.formUnion(bookIDsByHash[hash] ?? [])
        }
        let hashMatches = orderedBooks(with: hashMatchIDs)

        if !incomingHashes.isEmpty {
            let knownHashes = hashMatches.reduce(into: Set<String>()) {
                $0.formUnion($1.contentHashes)
            }
            if incomingHashes.isSubset(of: knownHashes), let target = bestHashTarget(
                for: incomingHashes,
                matches: hashMatches
            ) {
                return .skipExact(existingBookID: target.bookID)
            }
            if hashMatches.count == 1, let target = hashMatches.first {
                return .merge(existingBookID: target.bookID, workID: target.workID)
            }
            if hashMatches.count > 1 {
                return .needsReview(candidateWorkIDs: uniqueWorkIDs(in: hashMatches))
            }
        }

        let normalizedISBN = EditionMatcher.normalizedISBN(candidate.isbn)
        if !normalizedISBN.isEmpty {
            let isbnMatches = orderedBooks(with: bookIDsByISBN[normalizedISBN] ?? [])
            if isbnMatches.count == 1, let target = isbnMatches.first {
                return .merge(existingBookID: target.bookID, workID: target.workID)
            }
            if isbnMatches.count > 1 {
                return .needsReview(candidateWorkIDs: uniqueWorkIDs(in: isbnMatches))
            }
        }

        let candidateKey = BookMatchKey(title: candidate.title, author: candidate.author)
        if candidateKey.isComplete {
            let identityMatches = orderedBooks(
                with: bookIDsByIdentity[candidateKey] ?? []
            )
            let workIDs = uniqueWorkIDs(in: identityMatches)
            if workIDs.count == 1, let workID = workIDs.first,
               hasEditionDifference(candidate, comparedWith: identityMatches) {
                return .addEdition(workID: workID)
            }
            if !identityMatches.isEmpty {
                return .needsReview(candidateWorkIDs: workIDs)
            }
        }

        return .newWork
    }

    func contains(hash: String) -> Bool {
        let normalized = hash.lowercased()
        return !(bookIDsByHash[normalized]?.isEmpty ?? true)
    }

    mutating func record(
        _ rawCandidate: CalibreImportCandidate,
        decision: CalibreImportDecision
    ) {
        let candidate = Self.normalized(rawCandidate)
        switch decision {
        case .skipExact:
            break

        case .merge(let existingBookID, _):
            guard var existing = books[existingBookID] else { return }
            let newHashes = candidate.contentHashes.subtracting(existing.contentHashes)
            existing.contentHashes.formUnion(newHashes)
            existing.formats.formUnion(candidate.formats)
            books[existingBookID] = existing
            for hash in newHashes {
                bookIDsByHash[hash, default: []].insert(existingBookID)
            }

        case .addEdition(let workID):
            insert(catalogBook(from: candidate, workID: workID))

        case .newWork, .needsReview:
            insert(catalogBook(from: candidate, workID: candidate.workID))
        }
    }

    private func bestHashTarget(
        for hashes: Set<String>,
        matches: [CalibreImportCatalogBook]
    ) -> CalibreImportCatalogBook? {
        matches.max { lhs, rhs in
            let left = lhs.contentHashes.intersection(hashes).count
            let right = rhs.contentHashes.intersection(hashes).count
            if left == right { return lhs.bookID.uuidString > rhs.bookID.uuidString }
            return left < right
        }
    }

    private func hasEditionDifference(
        _ candidate: CalibreImportCandidate,
        comparedWith matches: [CalibreImportCatalogBook]
    ) -> Bool {
        let candidateISBN = EditionMatcher.normalizedISBN(candidate.isbn)
        let existingISBNs = Set(matches.map { EditionMatcher.normalizedISBN($0.isbn) }
            .filter { !$0.isEmpty })
        if !candidateISBN.isEmpty, !existingISBNs.isEmpty,
           !existingISBNs.contains(candidateISBN) {
            return true
        }

        let language = normalizedValue(candidate.language)
        let existingLanguages = Set(matches.map { normalizedValue($0.language) }
            .filter { !$0.isEmpty })
        if !language.isEmpty, !existingLanguages.isEmpty,
           !existingLanguages.contains(language) {
            return true
        }

        let publisher = normalizedValue(candidate.publisher)
        let year = normalizedValue(candidate.year)
        return !publisher.isEmpty && !year.isEmpty && matches.contains {
            let existingPublisher = normalizedValue($0.publisher)
            let existingYear = normalizedValue($0.year)
            return !existingPublisher.isEmpty && !existingYear.isEmpty
                && (publisher != existingPublisher || year != existingYear)
        }
    }

    private func uniqueWorkIDs(in matches: [CalibreImportCatalogBook]) -> [UUID] {
        Array(Set(matches.compactMap(\.workID))).sorted { $0.uuidString < $1.uuidString }
    }

    private func orderedBooks(with ids: Set<UUID>) -> [CalibreImportCatalogBook] {
        ids.compactMap { books[$0] }
            .sorted { $0.bookID.uuidString < $1.bookID.uuidString }
    }

    private mutating func insert(_ book: CalibreImportCatalogBook) {
        books[book.bookID] = book
        for hash in book.contentHashes {
            bookIDsByHash[hash, default: []].insert(book.bookID)
        }
        let isbn = EditionMatcher.normalizedISBN(book.isbn)
        if !isbn.isEmpty {
            bookIDsByISBN[isbn, default: []].insert(book.bookID)
        }
        let identity = BookMatchKey(title: book.title, author: book.author)
        if identity.isComplete {
            bookIDsByIdentity[identity, default: []].insert(book.bookID)
        }
    }

    private func catalogBook(
        from candidate: CalibreImportCandidate,
        workID: UUID
    ) -> CalibreImportCatalogBook {
        CalibreImportCatalogBook(
            bookID: candidate.bookID,
            workID: workID,
            title: candidate.title,
            author: candidate.author,
            isbn: candidate.isbn,
            language: candidate.language,
            publisher: candidate.publisher,
            year: candidate.year,
            contentHashes: candidate.contentHashes,
            formats: candidate.formats
        )
    }

    private static func normalized(_ book: CalibreImportCatalogBook) -> CalibreImportCatalogBook {
        CalibreImportCatalogBook(
            bookID: book.bookID,
            workID: book.workID,
            title: book.title,
            author: book.author,
            isbn: book.isbn,
            language: book.language,
            publisher: book.publisher,
            year: book.year,
            contentHashes: Set(book.contentHashes.map { $0.lowercased() }.filter { !$0.isEmpty }),
            formats: Set(book.formats.map { $0.lowercased() }.filter { !$0.isEmpty })
        )
    }

    private static func normalized(_ candidate: CalibreImportCandidate) -> CalibreImportCandidate {
        CalibreImportCandidate(
            bookID: candidate.bookID,
            workID: candidate.workID,
            title: candidate.title,
            author: candidate.author,
            isbn: candidate.isbn,
            language: candidate.language,
            publisher: candidate.publisher,
            year: candidate.year,
            contentHashes: Set(candidate.contentHashes.map { $0.lowercased() }.filter { !$0.isEmpty }),
            formats: Set(candidate.formats.map { $0.lowercased() }.filter { !$0.isEmpty })
        )
    }

    private func normalizedValue(_ value: String?) -> String {
        (value ?? "").normalizedMatchKey
    }
}
