import Foundation
import SwiftData
import Testing
@testable import Winston

@MainActor
struct HighlightsWorkspaceTests {
    @Test func tagNormalizationTrimsCollapsesAndDeduplicatesCaseInsensitively() {
        #expect(HighlightTagNormalizer.normalize(
            "  Philosophy,deep   work, PHILOSOPHY, Cafe\u{301}, café,  "
        ) == ["Philosophy", "deep work", "Café"])
    }

    @Test func filtersCombineQuickBookTagAndSearchConstraints() throws {
        let fixture = makeItems()
        let selected = HighlightWorkspaceFilter.apply(
            to: fixture.items,
            request: HighlightFilterRequest(
                query: "attention",
                quickFilter: .favorites,
                bookID: fixture.firstBookID,
                tag: "Focus",
                sourceGeneration: 1
            )
        )

        #expect(selected.map(\.text) == ["Attention shapes the day."])
        #expect(HighlightWorkspaceFilter.apply(
            to: fixture.items,
            request: HighlightFilterRequest(
                query: "personal insight",
                quickFilter: .reflections,
                bookID: nil,
                tag: nil,
                sourceGeneration: 1
            )
        ).map(\.text) == ["Attention shapes the day."])
    }

    @Test func reviewPlannerUsesUnreviewedThenOldestAndHonorsExclusions() throws {
        let fixture = makeItems()
        let session = HighlightReviewPlanner.makeSession(
            from: fixture.items,
            excluding: [fixture.items[0].id],
            limit: 2
        )

        #expect(session.map(\.text) == [
            "A second unreviewed passage.",
            "The oldest reviewed passage.",
        ])
    }

    @Test func groupingKeepsInterleavedPassagesUnderOneBookIdentity() {
        let items = makeItems().items
        let groups = HighlightWorkspaceFilter.groups(from: [
            items[0], items[2], items[1], items[3],
        ])

        #expect(groups.map(\.id) == [items[0].bookID, items[2].bookID])
        #expect(groups[0].items.map(\.id) == [items[0].id, items[1].id])
        #expect(groups[1].items.map(\.id) == [items[2].id, items[3].id])
    }

    @Test func identicalBookTitlesKeepPassagesTogether() throws {
        let container = PersistenceController.inMemory()
        let context = container.mainContext
        for index in 0..<2 {
            let book = Book(fileName: "edition-\(index).epub", originalFileName: "Same Title.epub")
            book.title = "Same Title"
            context.insert(book)
            for location in ["10", "20"] {
                let highlight = Highlight(text: "Passage \(index)", isNote: false,
                                          location: location, addedDate: nil)
                highlight.book = book
                context.insert(highlight)
            }
        }
        try context.save()

        let items = try HighlightsService(modelContext: context).workspaceItems()
        #expect(items.count == 4)
        #expect(items[0].bookID == items[1].bookID)
        #expect(items[2].bookID == items[3].bookID)
        #expect(items[0].bookID != items[2].bookID)
        #expect(items.map(\.location) == ["10", "20", "10", "20"])
    }

    @Test func favoriteChangesInvalidateOutstandingFilterRequests() async throws {
        let container = PersistenceController.inMemory()
        let context = container.mainContext
        let book = Book(fileName: "favorite.epub", originalFileName: "Favorite.epub")
        let highlight = Highlight(text: "A saved passage", isNote: false, location: nil, addedDate: nil)
        context.insert(book)
        context.insert(highlight)
        highlight.book = book
        highlight.isFavorite = true
        try context.save()
        let service = HighlightsService(modelContext: context)
        let model = HighlightsWorkspaceModel()
        model.quickFilter = .favorites
        await model.reload(using: service)
        let outstandingRequest = model.filterRequest
        #expect(model.visibleCount == 1)

        let updated = try service.updateHighlight(
            id: highlight.persistentModelID,
            patch: HighlightPatch(fields: [.favorite], favorite: false)
        ).get()
        model.acceptFavoriteUpdate(updated)

        #expect(model.filterRequest != outstandingRequest)
        #expect(model.visibleItems.isEmpty)
        await model.applyFilter(outstandingRequest)
        #expect(model.visibleItems.isEmpty)
    }

    @Test func workspaceServicePersistsNormalizedEnrichmentWithoutChangingSourceText() throws {
        let container = PersistenceController.inMemory()
        let context = container.mainContext
        let book = Book(fileName: "focus.epub", originalFileName: "Focus.epub")
        book.title = "Focus"
        let highlight = Highlight(
            text: "Imported source text",
            isNote: false,
            location: "12",
            addedDate: nil
        )
        context.insert(book)
        context.insert(highlight)
        highlight.book = book
        try context.save()

        let reviewedAt = Date(timeIntervalSince1970: 500)
        let service = HighlightsService(modelContext: context)
        let result = service.updateHighlight(
            id: highlight.persistentModelID,
            patch: HighlightPatch(
                fields: [.favorite, .tags, .reflection, .lastReviewedAt],
                favorite: true,
                tags: [" Focus ", "focus", "Deep   Work"],
                reflection: "A personal connection.",
                lastReviewedAt: reviewedAt
            )
        )

        let saved: HighlightWorkspaceItem
        switch result {
        case .success(let item): saved = item
        case .failure(let error):
            Issue.record("Expected a saved highlight, got \(error)")
            return
        }
        #expect(saved.text == "Imported source text")
        #expect(saved.isFavorite)
        #expect(saved.tags == ["Focus", "Deep Work"])
        #expect(saved.reflection == "A personal connection.")
        #expect(saved.lastReviewedAt == reviewedAt)
        #expect(!context.hasChanges)
    }

    private func makeItems() -> (
        items: [HighlightWorkspaceItem],
        firstBookID: UUID
    ) {
        let container = PersistenceController.inMemory()
        let context = container.mainContext
        let firstBook = Book(fileName: "focus.epub", originalFileName: "Focus.epub")
        firstBook.title = "Deep Work"
        firstBook.author = "Cal Newport"
        let secondBook = Book(fileName: "other.epub", originalFileName: "Other.epub")
        secondBook.title = "Other"
        context.insert(firstBook)
        context.insert(secondBook)

        let first = Highlight(
            text: "Attention shapes the day.",
            isNote: false,
            location: "1",
            addedDate: nil
        )
        first.isFavorite = true
        first.userTags = ["Focus"]
        first.reflection = "Personal insight"
        first.book = firstBook
        context.insert(first)

        let second = Highlight(
            text: "A second unreviewed passage.",
            isNote: false,
            location: "2",
            addedDate: nil
        )
        second.book = firstBook
        context.insert(second)

        let third = Highlight(
            text: "The oldest reviewed passage.",
            isNote: false,
            location: "3",
            addedDate: nil
        )
        third.lastReviewedAt = Date(timeIntervalSince1970: 100)
        third.book = secondBook
        context.insert(third)

        let fourth = Highlight(
            text: "The newest reviewed passage.",
            isNote: false,
            location: "4",
            addedDate: nil
        )
        fourth.lastReviewedAt = Date(timeIntervalSince1970: 200)
        fourth.book = secondBook
        context.insert(fourth)

        let items = [first, second, third, fourth].compactMap(HighlightWorkspaceItem.init)
        return (items, firstBook.uuid)
    }
}
