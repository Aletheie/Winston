import Foundation
import Testing
@testable import Winston

struct MetadataFixFinderTests {
    @Test(arguments: [
        ("Herbert, Frank", "Frank Herbert"),
        ("Tolkien, J. R. R.", "J. R. R. Tolkien"),
    ])
    func `Reversed author names are suggested in display order`(
        name: String,
        expected: String
    ) {
        #expect(MetadataFixFinder.reversedAuthorSuggestion(name) == expected)
    }

    @Test(arguments: [
        "Frank Herbert",
        "Herbert, Frank, Jr.",
    ])
    func `Names without exactly one separator are ignored`(name: String) {
        #expect(MetadataFixFinder.reversedAuthorSuggestion(name) == nil)
    }

    @Test func `Finder returns both kinds with affected book counts`() {
        let fixes = MetadataFixFinder.fixes(rows: [
            MetadataFixRow(author: "Herbert, Frank", series: "Zaklinac"),
            MetadataFixRow(author: "Herbert, Frank", series: "Zaklínač"),
            MetadataFixRow(author: "Frank Herbert", series: "Zaklínač"),
        ])

        #expect(fixes == [
            MetadataFix(
                kind: .author,
                original: "Herbert, Frank",
                suggestion: "Frank Herbert",
                bookCount: 2
            ),
            MetadataFix(
                kind: .series,
                original: "Zaklinac",
                suggestion: "Zaklínač",
                bookCount: 1
            ),
        ])
    }

    @Test func `Finder proposes explicit missing series membership and position`() throws {
        let prefixedID = UUID()
        let parentheticalID = UUID()
        let standaloneID = UUID()
        let fixes = MetadataFixFinder.fixes(rows: [
            MetadataFixRow(author: "Ludmila Vaňková", series: "Orel a lev"),
            MetadataFixRow(
                bookID: prefixedID,
                title: "Dvojí trůn",
                originalFileName: "Orel a lev 02 - Dvoji trun - Vankova.epub",
                author: "Ludmila Vaňková",
                series: nil
            ),
            MetadataFixRow(
                bookID: parentheticalID,
                title: "The Serpent and the Wings of Night (Crowns of Nyaxia Book 1)",
                author: "Carissa Broadbent",
                series: nil
            ),
            MetadataFixRow(
                bookID: standaloneID,
                title: "A Standalone Novel",
                author: "Ludmila Vaňková",
                series: nil
            ),
        ])

        let assignments = fixes.filter { $0.kind == .seriesAssignment }
        #expect(assignments.count == 2)

        let prefixed = try #require(assignments.first { $0.bookID == prefixedID })
        #expect(prefixed.suggestion == "Orel a lev")
        #expect(prefixed.seriesIndex == "2")

        let parenthetical = try #require(assignments.first { $0.bookID == parentheticalID })
        #expect(parenthetical.suggestion == "Crowns of Nyaxia")
        #expect(parenthetical.seriesIndex == "1")
        #expect(!assignments.contains { $0.bookID == standaloneID })
    }

    @Test func `Known series in parentheses is proposed without inventing a position`() throws {
        let bookID = UUID()
        let fixes = MetadataFixFinder.fixes(rows: [
            MetadataFixRow(author: "Victoria Aveyard", series: "Red Queen"),
            MetadataFixRow(
                bookID: bookID,
                title: "War Storm (Red Queen)",
                author: "Victoria Aveyard",
                series: nil
            ),
        ])

        let fix = try #require(fixes.first { $0.bookID == bookID })
        #expect(fix.kind == .seriesAssignment)
        #expect(fix.suggestion == "Red Queen")
        #expect(fix.seriesIndex == nil)
    }

    @Test func `Repeated numbered prefixes establish a new series without guessing from one title`() {
        let secondID = UUID()
        let thirdID = UUID()
        let ambiguousID = UUID()
        let fixes = MetadataFixFinder.fixes(rows: [
            MetadataFixRow(
                bookID: secondID,
                title: "Zrození království 02 - Kdo na kamenný trůn",
                author: "Ludmila Vaňková",
                series: nil
            ),
            MetadataFixRow(
                bookID: thirdID,
                title: "Zrození království 03 - Cestou krále",
                author: "Ludmila Vaňková",
                series: nil
            ),
            MetadataFixRow(
                bookID: ambiguousID,
                title: "World War 2 - A History",
                author: "Someone",
                series: nil
            ),
        ])

        let assignments = fixes.filter { $0.kind == .seriesAssignment }
        #expect(assignments.filter { $0.suggestion == "Zrození království" }.count == 2)
        #expect(assignments.first { $0.bookID == secondID }?.seriesIndex == "2")
        #expect(assignments.first { $0.bookID == thirdID }?.seriesIndex == "3")
        #expect(!assignments.contains { $0.bookID == ambiguousID })
    }
}
