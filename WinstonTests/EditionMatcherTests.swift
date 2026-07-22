import Foundation
import Testing
@testable import Winston

@Suite("Edition matcher")
struct EditionMatcherTests {
    struct ReconciliationScenario: Sendable {
        let name: String
        let lhsLanguage: String?
        let rhsLanguage: String?
        let lhsTranslator: String?
        let rhsTranslator: String?
        let lhsISBN: String?
        let rhsISBN: String?
        let lhsPublisher: String?
        let rhsPublisher: String?
        let lhsYear: String?
        let rhsYear: String?
        let lhsAuthor: String?
        let rhsAuthor: String?
        let lhsHash: String?
        let rhsHash: String?
        let expectedVerdict: EditionVerdict
    }

    private func candidate(
        uuid: UUID = UUID(),
        workUUID: UUID? = nil,
        title: String? = "Dune",
        author: String? = "Frank Herbert",
        language: String? = "en",
        translator: String? = nil,
        isbn: String? = nil,
        publisher: String? = nil,
        year: String? = nil,
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
            publisher: publisher,
            year: year,
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
        #expect(result.verdict == .similarItem)
        #expect(result.confidence == .uncertain)
        #expect(!result.canApply)
    }

    @Test func titleOnlyWithMissingAuthorIsUncertain() throws {
        let result = try #require(EditionMatcher.proposals(
            for: candidate(author: nil), against: [candidate(author: "Two")]
        ).first)
        #expect(result.verdict == .similarItem)
        #expect(result.confidence == .uncertain)
        #expect(result.signals == [.sameTitle])
    }

    @Test func sameTitleWithDifferentAuthorsIsReviewOnly() throws {
        let result = try #require(EditionMatcher.proposals(
            for: candidate(author: "One"), against: [candidate(author: "Two")]
        ).first)
        #expect(result.verdict == .similarItem)
        #expect(!result.canApply)
        #expect(result.changePlan.assetPolicy == .reviewOnly)
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

    @Test func scanSkipsAlreadyGroupedDistinctEditions() async {
        let work = UUID()
        let proposals = await EditionMatcher.scan([
            candidate(workUUID: work, title: "Dune", openLibraryKey: "/works/OL1W"),
            candidate(workUUID: work, title: "Duna", language: "cs", openLibraryKey: "/works/OL1W"),
        ])
        #expect(proposals.isEmpty)
    }

    @Test(arguments: [
        ReconciliationScenario(
            name: "translation",
            lhsLanguage: "en", rhsLanguage: "cs",
            lhsTranslator: nil, rhsTranslator: "Jan Novák",
            lhsISBN: nil, rhsISBN: nil,
            lhsPublisher: nil, rhsPublisher: nil,
            lhsYear: nil, rhsYear: nil,
            lhsAuthor: "Frank Herbert", rhsAuthor: "Frank Herbert",
            lhsHash: nil, rhsHash: nil,
            expectedVerdict: .sameWorkOtherEdition
        ),
        ReconciliationScenario(
            name: "revised edition",
            lhsLanguage: "en", rhsLanguage: "en",
            lhsTranslator: nil, rhsTranslator: nil,
            lhsISBN: "9780000000001", rhsISBN: "9780000000002",
            lhsPublisher: "Ace", rhsPublisher: "Ace",
            lhsYear: "1965", rhsYear: "2005",
            lhsAuthor: "Frank Herbert", rhsAuthor: "Frank Herbert",
            lhsHash: nil, rhsHash: nil,
            expectedVerdict: .sameWorkOtherEdition
        ),
        ReconciliationScenario(
            name: "same title, different author",
            lhsLanguage: "en", rhsLanguage: "en",
            lhsTranslator: nil, rhsTranslator: nil,
            lhsISBN: nil, rhsISBN: nil,
            lhsPublisher: nil, rhsPublisher: nil,
            lhsYear: nil, rhsYear: nil,
            lhsAuthor: "Author One", rhsAuthor: "Author Two",
            lhsHash: nil, rhsHash: nil,
            expectedVerdict: .similarItem
        ),
        ReconciliationScenario(
            name: "same edition, other format",
            lhsLanguage: "en", rhsLanguage: "en",
            lhsTranslator: nil, rhsTranslator: nil,
            lhsISBN: "9780441013593", rhsISBN: "9780441013593",
            lhsPublisher: "Ace", rhsPublisher: "Ace",
            lhsYear: "2005", rhsYear: "2005",
            lhsAuthor: "Frank Herbert", rhsAuthor: "Frank Herbert",
            lhsHash: nil, rhsHash: nil,
            expectedVerdict: .sameEditionOtherFormat
        ),
        ReconciliationScenario(
            name: "identical bytes",
            lhsLanguage: "en", rhsLanguage: "cs",
            lhsTranslator: nil, rhsTranslator: "Jan Novák",
            lhsISBN: "one", rhsISBN: "two",
            lhsPublisher: "Ace", rhsPublisher: "Argo",
            lhsYear: "1965", rhsYear: "2005",
            lhsAuthor: "Frank Herbert", rhsAuthor: "Frank Herbert",
            lhsHash: "same-content", rhsHash: "same-content",
            expectedVerdict: .duplicateFile
        ),
    ])
    func reconciliationBoundaryIsConservative(_ scenario: ReconciliationScenario) throws {
        let lhs = candidate(
            author: scenario.lhsAuthor,
            language: scenario.lhsLanguage,
            translator: scenario.lhsTranslator,
            isbn: scenario.lhsISBN,
            publisher: scenario.lhsPublisher,
            year: scenario.lhsYear,
            hash: scenario.lhsHash,
            format: "epub"
        )
        let rhs = candidate(
            author: scenario.rhsAuthor,
            language: scenario.rhsLanguage,
            translator: scenario.rhsTranslator,
            isbn: scenario.rhsISBN,
            publisher: scenario.rhsPublisher,
            year: scenario.rhsYear,
            hash: scenario.rhsHash,
            format: "mobi"
        )

        let proposal = try #require(EditionMatcher.proposals(for: lhs, against: [rhs]).first)

        #expect(proposal.verdict == scenario.expectedVerdict, "\(scenario.name)")
        #expect(proposal.isAutomaticallySafe == (scenario.expectedVerdict == .duplicateFile))
        let expectedPolicy: ReconciliationAssetPolicy = switch scenario.expectedVerdict {
        case .duplicateFile: .removeExactContentDuplicates
        case .sameEditionOtherFormat: .retainAll
        case .sameWorkOtherEdition: .unchanged
        case .similarItem: .reviewOnly
        }
        #expect(proposal.changePlan.assetPolicy == expectedPolicy)
    }
}
