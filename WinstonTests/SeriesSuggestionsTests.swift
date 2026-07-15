import Foundation
import Testing
@testable import Winston

struct SeriesSuggestionsTests {
    @Test func suggestsUnifyingDiacriticVariantsTowardTheMoreCommonName() {
        let tips = SeriesSuggestions.unificationTips(counts: [
            "Zaklínač": 3,
            "Zaklinac": 1,
            "Kroniky": 4,
        ])
        #expect(tips.count == 1)
        #expect(tips.first?.original == "Zaklinac")
        #expect(tips.first?.suggestion == "Zaklínač")
    }

    @Test func countOutweighsDiacriticsAndTiesPreferAccentedName() {
        let byCount = SeriesSuggestions.unificationTips(counts: [
            "zaklinac": 5,
            "Zaklínač": 2,
        ])
        #expect(byCount.first?.suggestion == "zaklinac")

        let tie = SeriesSuggestions.unificationTips(counts: [
            "Zaklinac": 2,
            "Zaklínač": 2,
        ])
        #expect(tie.first?.suggestion == "Zaklínač")
    }

    @Test func uniqueSeriesProduceNoTips() {
        let tips = SeriesSuggestions.unificationTips(counts: [
            "Zaklínač": 3,
            "Kroniky": 1,
        ])
        #expect(tips.isEmpty)
    }

    @Test func `Common series wrappers collapse to one stable family`() {
        let tips = SeriesSuggestions.unificationTips(counts: [
            "The Vorkosigan Saga": 3,
            "Vorkosigan": 2,
            "Vorkosigan Saga (Publication)": 1,
            "Vorkosigan: Publication Order": 1,
            "The Road to Nowhere": 1,
        ])

        #expect(tips.map { "\($0.original) -> \($0.suggestion)" } == [
            "Vorkosigan -> The Vorkosigan Saga",
            "Vorkosigan Saga (Publication) -> The Vorkosigan Saga",
            "Vorkosigan: Publication Order -> The Vorkosigan Saga",
        ])
    }

    @Test func `Leading articles and descriptive suffixes match without swallowing real names`() {
        let tips = SeriesSuggestions.unificationTips(counts: [
            "The Lunar Chronicles": 3,
            "Lunar Chronicles": 1,
            "Mistborn Trilogy": 2,
            "Mistborn": 1,
            "The Order": 1,
            "Order of Darkness": 1,
        ])

        #expect(tips.contains {
            $0.original == "Lunar Chronicles" && $0.suggestion == "The Lunar Chronicles"
        })
        #expect(tips.contains {
            $0.original == "Mistborn" && $0.suggestion == "Mistborn Trilogy"
        })
        #expect(!tips.contains { $0.original == "The Order" || $0.original == "Order of Darkness" })
    }

    @MainActor
    @Test func rankedListsSeriesByUsageThenName() throws {
        let container = PersistenceController.inMemory()
        let context = container.mainContext
        for (series, count) in [("Kroniky", 1), ("Zaklínač", 3), ("Alenka", 1)] {
            for index in 0..<count {
                let book = Book(fileName: "\(series)-\(index).epub", originalFileName: "\(series) \(index).epub")
                book.series = series
                context.insert(book)
            }
        }
        try context.save()

        let ranked = SeriesSuggestions.ranked(from: context.allBooks())
        #expect(ranked == ["Zaklínač", "Alenka", "Kroniky"])
    }
}
