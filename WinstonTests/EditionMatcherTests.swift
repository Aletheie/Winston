import Foundation
import Testing
@testable import Winston

@Suite("Edition matcher")
struct EditionMatcherTests {
    private func candidate(
        uuid: UUID = UUID(),
        workUUID: UUID? = nil,
        title: String? = "Dune",
        author: String? = "Frank Herbert",
        language: String? = "en",
        translator: String? = nil,
        isbn: String? = nil,
        hash: String? = nil,
        openLibraryKey: String? = nil,
        format: String = "epub"
    ) -> EditionCandidate {
        EditionCandidate(
            uuid: uuid,
            workUUID: workUUID,
            title: title,
            author: author,
            language: language,
            translator: translator,
            isbn: isbn,
            publisher: nil,
            year: nil,
            format: format,
            sizeBytes: 100,
            contentHashes: hash.map { [$0] } ?? [],
            openLibraryWorkKey: openLibraryKey
        )
    }

    @Test func identicalHashHasHighestPriority() throws {
        let lhs = candidate(isbn: "978-1", hash: "abc")
        let rhs = candidate(isbn: "978-1", hash: "abc", format: "mobi")
        let result = try #require(EditionMatcher.proposals(for: lhs, against: [rhs]).first)
        #expect(result.verdict == .duplicateFile)
        #expect(result.confidence == .high)
        #expect(result.signals == [.identicalContent])
    }

    @Test func normalizedISBNMeansSameEditionOtherFormat() throws {
        let lhs = candidate(isbn: "978-0-441-01359-3")
        let rhs = candidate(isbn: "978 0 441 01359 3", format: "mobi")
        let result = try #require(EditionMatcher.proposals(for: lhs, against: [rhs]).first)
        #expect(result.verdict == .sameEditionOtherFormat)
        #expect(result.confidence == .high)
    }

    @Test func workKeyIsHighConfidenceOtherEdition() throws {
        let lhs = candidate(title: "Dune", openLibraryKey: "/works/OL1W")
        let rhs = candidate(title: "Duna", language: "cs", translator: "Jan", openLibraryKey: "/works/OL1W")
        let result = try #require(EditionMatcher.proposals(for: lhs, against: [rhs]).first)
        #expect(result.verdict == .sameWorkOtherEdition)
        #expect(result.confidence == .high)
        #expect(result.signals == [.sameOpenLibraryWork])
    }

    @Test func titleAuthorWithDifferentTranslatorIsLikely() throws {
        let lhs = candidate(language: "cs", translator: "Jan Novák")
        let rhs = candidate(language: "cs", translator: "Petr Nový")
        let result = try #require(EditionMatcher.proposals(for: lhs, against: [rhs]).first)
        #expect(result.verdict == .sameWorkOtherEdition)
        #expect(result.confidence == .likely)
        #expect(result.signals.contains(.differentTranslator))
    }

    @Test func titleAuthorWithoutEditionDifferenceIsUncertain() throws {
        let result = try #require(EditionMatcher.proposals(
            for: candidate(), against: [candidate(format: "pdf")]
        ).first)
        #expect(result.confidence == .uncertain)
    }

    @Test func titleOnlyWithMissingAuthorIsUncertain() throws {
        let result = try #require(EditionMatcher.proposals(
            for: candidate(author: nil), against: [candidate(author: "Two")]
        ).first)
        #expect(result.confidence == .uncertain)
        #expect(result.signals == [.sameTitle])
    }

    @Test func sameTitleWithDifferentAuthorsDoesNotMatch() {
        #expect(EditionMatcher.proposals(
            for: candidate(author: "One"), against: [candidate(author: "Two")]
        ).isEmpty)
    }

    @Test func unrelatedBooksDoNotMatch() {
        #expect(EditionMatcher.proposals(
            for: candidate(title: "Dune"), against: [candidate(title: "Foundation")]
        ).isEmpty)
    }

    @Test func pairKeyIsOrderIndependentAndStable() throws {
        let lhs = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let rhs = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        #expect(EditionMatcher.pairKey(lhs, rhs) == EditionMatcher.pairKey(rhs, lhs))
        #expect(EditionMatcher.pairKey(lhs, rhs) == "00000000-0000-0000-0000-000000000001:00000000-0000-0000-0000-000000000002")
    }

    @Test func scanSkipsBooksAlreadyInOneWork() async {
        let work = UUID()
        let proposals = await EditionMatcher.scan([
            candidate(workUUID: work, isbn: "9780441013593"),
            candidate(workUUID: work, isbn: "9780441013593", format: "mobi"),
        ])
        #expect(proposals.isEmpty)
    }
}
