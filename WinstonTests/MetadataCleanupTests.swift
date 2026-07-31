import Foundation
import Testing
@testable import Winston

@MainActor
@Suite("Metadata cleanup", .serialized)
struct MetadataCleanupTests {
    @Test func finderSeparatesSafeReviewAndInformationalChanges() {
        let firstID = UUID()
        let secondID = UUID()
        let rows = [
            MetadataFixRow(
                bookID: firstID,
                title: "  Dune\u{00A0}Messiah  ",
                storedTitle: "  Dune\u{00A0}Messiah  ",
                originalFileName: "Dune Messiah.epub",
                author: " Herbert, Frank ",
                storedAuthor: " Herbert, Frank ",
                publisher: "Ace  Books",
                language: "eng",
                isbn: "0-306-40615-2",
                series: " Dune ",
                tags: [" Science Fiction ", "science fiction", ""]
            ),
            MetadataFixRow(
                bookID: secondID,
                title: "Unknown",
                storedTitle: "Unknown",
                originalFileName: "Unknown.epub",
                author: "Someone",
                storedAuthor: "Someone",
                publisher: "ACE BOOKS",
                language: "???",
                isbn: "123",
                series: nil,
                tags: []
            ),
        ]

        let analysis = MetadataCleanupFinder.analysis(
            rows: rows,
            scope: .wholeLibrary
        )

        #expect(analysis.scannedBookCount == 2)
        #expect(analysis.groups.contains {
            $0.risk == .safe
                && $0.changes.contains { $0.field == .language }
        })
        #expect(analysis.groups.contains {
            $0.risk == .safe
                && $0.changes.contains { $0.field == .isbn }
        })
        #expect(analysis.groups.contains {
            $0.risk == .safe
                && $0.changes.contains { $0.field == .tags }
        })
        #expect(analysis.groups.contains {
            $0.risk == .review
                && $0.changes.contains { $0.field == .author }
        })
        #expect(analysis.groups.count {
            $0.risk == .informational
        } == 2)
        let tagChange = analysis.groups
            .flatMap(\.changes)
            .first { $0.field == .tags }
        #expect(tagChange?.after == .tags(["Science Fiction"]))

        let applicableChanges = analysis.groups
            .filter(\.isApplicable)
            .flatMap(\.changes)
        let changesByBookAndField = Dictionary(grouping: applicableChanges) {
            "\($0.bookID.uuidString):\($0.field.rawValue)"
        }
        #expect(changesByBookAndField.values.allSatisfy { $0.count == 1 })
    }

    @Test func finderDoesNotTurnDisplayFallbacksIntoStoredMetadata() {
        let bookID = UUID()
        let analysis = MetadataCleanupFinder.analysis(
            rows: [
                MetadataFixRow(
                    bookID: bookID,
                    title: "Fallback Title",
                    storedTitle: nil,
                    originalFileName: "Fallback Title.epub",
                    author: "Unknown Author",
                    storedAuthor: nil,
                    series: nil
                ),
            ],
            scope: .wholeLibrary
        )

        #expect(analysis.groups.flatMap(\.changes).allSatisfy {
            $0.field != .title && $0.field != .author
        })
    }

    @Test func scopedAnalysisOnlySnapshotsRequestedBooks() async throws {
        let library = try await TestLibrary()
        let first = Book(fileName: "", originalFileName: "First")
        first.title = "  First  "
        let second = Book(fileName: "", originalFileName: "Second")
        second.title = "  Second  "
        library.context.insert(first)
        library.context.insert(second)
        try library.context.fixtureSaveAndPublish(
            affectedBookIDs: [first.uuid, second.uuid],
            fields: [.identity, .displayMetadata],
            changesBookMembership: true
        )
        let mutations = CatalogMutationService(modelContext: library.context)
        let health = LibraryHealthService(
            modelContext: library.context,
            mutations: mutations
        )

        let analysis = await health.metadataCleanup(
            scope: .books(ids: [first.uuid], label: "Selection")
        )

        #expect(analysis.scannedBookCount == 1)
        #expect(analysis.groups.flatMap(\.changes).allSatisfy {
            $0.bookID == first.uuid
        })
    }

    @Test func applyReportsConflictsAndUndoNeverOverwritesANewerEdit() async throws {
        let library = try await TestLibrary()
        let first = Book(fileName: "", originalFileName: "First")
        first.title = "  First  "
        let second = Book(fileName: "", originalFileName: "Second")
        second.title = "  Second  "
        library.context.insert(first)
        library.context.insert(second)
        try library.context.fixtureSaveAndPublish(
            affectedBookIDs: [first.uuid, second.uuid],
            fields: [.identity, .displayMetadata],
            changesBookMembership: true
        )
        let mutations = CatalogMutationService(modelContext: library.context)
        let health = LibraryHealthService(
            modelContext: library.context,
            mutations: mutations
        )
        let analysis = await health.metadataCleanup(scope: .wholeLibrary)
        let titleChanges = analysis.groups
            .flatMap(\.changes)
            .filter { $0.field == .title }
        #expect(titleChanges.count == 2)

        let userEdit = CatalogBookUpdate(
            bookID: first.uuid,
            patch: CatalogBookPatch(
                fields: [.title],
                title: "User Edit"
            )
        )
        if case .failure(let error) = mutations.execute(
            .updateBook(userEdit, source: .manual)
        ) {
            Issue.record("Could not create conflict fixture: \(error)")
        }

        let applied = try #require(
            try? health.applyMetadataCleanup(titleChanges).get()
        )
        #expect(applied.appliedCount == 1)
        #expect(applied.conflictCount == 1)
        #expect(first.title == "User Edit")
        #expect(second.title == "Second")
        #expect(health.canUndoMetadataCleanup)

        let newerEdit = CatalogBookUpdate(
            bookID: second.uuid,
            patch: CatalogBookPatch(
                fields: [.title],
                title: "Newer Edit"
            )
        )
        if case .failure(let error) = mutations.execute(
            .updateBook(newerEdit, source: .manual)
        ) {
            Issue.record("Could not create undo conflict fixture: \(error)")
        }

        let undo = try #require(
            try? health.undoLastMetadataCleanup().get()
        )
        #expect(undo.appliedCount == 0)
        #expect(undo.conflictCount == 1)
        #expect(second.title == "Newer Edit")
        #expect(health.canUndoMetadataCleanup)
        #expect(!library.context.hasChanges)
    }
}
