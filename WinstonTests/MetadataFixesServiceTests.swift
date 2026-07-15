import Testing
@testable import Winston

@MainActor
@Suite(.serialized)
struct MetadataFixesServiceTests {
    @Test func `Health service invalidates cached fixes after a library mutation`() async throws {
        let library = try await TestLibrary()
        let books = [
            Book(fileName: "a.epub", originalFileName: "A.epub"),
            Book(fileName: "b.epub", originalFileName: "B.epub"),
            Book(fileName: "c.epub", originalFileName: "C.epub"),
        ]
        books[0].author = "Herbert, Frank"
        books[0].series = "Zaklinac"
        books[1].author = "Herbert, Frank"
        books[1].series = "Zaklínač"
        books[2].author = "Frank Herbert"
        books[2].series = "Zaklínač"
        for book in books { library.context.insert(book) }
        try library.context.save()

        let viewModel = LibraryViewModel(
            modelContext: library.context,
            settings: AppSettings(),
            toasts: ToastCenter()
        )
        let initial = await viewModel.metadataFixes()

        #expect(initial.first { $0.kind == .author }?.bookCount == 2)
        #expect(initial.first { $0.kind == .series }?.bookCount == 1)

        viewModel.renameAuthor("Herbert, Frank", to: "Frank Herbert")
        let refreshed = await viewModel.metadataFixes()

        #expect(!refreshed.contains { $0.kind == .author })
        #expect(refreshed.contains { $0.kind == .series })
    }

    @Test func `Series assignment uses the shared analysis and invalidates it after apply`() async throws {
        let library = try await TestLibrary()
        let existing = Book(fileName: "first.epub", originalFileName: "First.epub")
        existing.title = "Cval rytířských koní"
        existing.series = "Orel a lev"
        existing.seriesIndex = "1"
        let missing = Book(
            fileName: "second.epub",
            originalFileName: "Orel a lev 02 - Dvoji trun.epub"
        )
        missing.title = "Dvojí trůn"
        library.context.insert(existing)
        library.context.insert(missing)
        try library.context.save()

        let viewModel = LibraryViewModel(
            modelContext: library.context,
            settings: AppSettings(),
            toasts: ToastCenter()
        )

        #expect(await viewModel.seriesSuggestions() == ["Orel a lev"])
        let initial = await viewModel.metadataFixes()
        let assignment = try #require(initial.first { $0.bookID == missing.uuid })
        #expect(assignment.kind == .seriesAssignment)
        #expect(assignment.seriesIndex == "2")

        viewModel.applyMetadataFix(assignment)
        #expect(missing.series == "Orel a lev")
        #expect(missing.seriesIndex == "2")

        let refreshed = await viewModel.metadataFixes()
        #expect(!refreshed.contains { $0.bookID == missing.uuid })
    }
}
