import Testing
import Foundation
@testable import Winston

struct HighlightsExporterTests {

    @Test func markdownRendersHeaderQuotesAndNotes() {
        let book = HighlightsExporter.BookHighlights(
            title: "Dune",
            author: "Frank Herbert",
            entries: [
                .init(text: "Fear is the mind-killer.", isNote: false, location: "42"),
                .init(text: "remember this", isNote: true, location: nil),
            ])
        let md = HighlightsExporter.markdown(for: book)
        #expect(md.hasPrefix("# Dune"))
        #expect(md.contains("_Frank Herbert_"))
        #expect(md.contains("> Fear is the mind-killer."))
        #expect(md.contains("— location 42"))
        #expect(md.contains("**Note:** remember this"))
    }

    @Test func markdownOmitsAuthorWhenAbsent() {
        let book = HighlightsExporter.BookHighlights(title: "Untitled", author: nil, entries: [])
        #expect(!HighlightsExporter.markdown(for: book).contains("_"))
    }

    @Test func fileNameCombinesAuthorTitleAndSanitizes() {
        let book = HighlightsExporter.BookHighlights(title: "A/B: C", author: "X", entries: [])
        let name = HighlightsExporter.fileName(for: book)
        #expect(name.hasSuffix(".md"))
        #expect(!name.contains("/") && !name.contains(":"))
        #expect(name.contains("X"))
    }

    @Test func markdownIncludesFavoriteTagsAndReflection() {
        let book = HighlightsExporter.BookHighlights(
            title: "Dune",
            author: nil,
            entries: [
                .init(
                    text: "A beginning is a delicate time.",
                    isNote: false,
                    location: nil,
                    isFavorite: true,
                    tags: ["Beginnings", "Politics"],
                    reflection: "A useful warning before starting a project."
                ),
            ]
        )

        let markdown = HighlightsExporter.markdown(for: book)
        #expect(markdown.contains("**Favorite**"))
        #expect(markdown.contains("Tags: `Beginnings`, `Politics`"))
        #expect(markdown.contains("**Reflection:**"))
        #expect(markdown.contains("A useful warning before starting a project."))
    }
}
