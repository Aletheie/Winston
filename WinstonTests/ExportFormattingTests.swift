import Testing
import Foundation
@testable import Winston

// MARK: - CSV escaping

struct CSVEscapeTests {

    @Test(arguments: zip(
        ["plain", "with space", "12345"],
        ["plain", "with space", "12345"]
    ))
    func leavesSimpleValuesUnquoted(_ input: String, _ expected: String) {
        #expect(LibraryExporter.csvEscape(input) == expected)
    }

    @Test func quotesValuesWithCommas() {
        #expect(LibraryExporter.csvEscape("Last, First") == "\"Last, First\"")
    }

    @Test func quotesAndDoublesEmbeddedQuotes() {
        #expect(LibraryExporter.csvEscape("He said \"hi\"") == "\"He said \"\"hi\"\"\"")
    }

    @Test func quotesValuesWithNewlines() {
        #expect(LibraryExporter.csvEscape("line1\nline2") == "\"line1\nline2\"")
    }
}

// MARK: - Export filename collisions

struct UniqueNameTests {

    @Test func returnsBaseWhenUnused() {
        var used = Set<String>()
        #expect(FileNaming.uniqueName("book.epub", in: &used) == "book.epub")
        #expect(used.contains("book.epub"))
    }

    @Test func suffixesRepeatedCollisions() {
        var used = Set<String>()
        let names = (0..<3).map { _ in FileNaming.uniqueName("book.epub", in: &used) }
        #expect(names == ["book.epub", "book (2).epub", "book (3).epub"])
    }

    @Test func handlesNamesWithoutExtension() {
        var used: Set<String> = ["report"]
        #expect(FileNaming.uniqueName("report", in: &used) == "report (2)")
    }

    @Test func exportManifestUsesDeconflictedFileNames() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "ExportNames-\(UUID().uuidString)", directoryHint: .isDirectory)
        let output = root.appending(path: "output", directoryHint: .isDirectory)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let first = root.appending(path: "first.epub")
        let second = root.appending(path: "second.epub")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)

        func row(title: String, source: URL) -> ExportRow {
            ExportRow(
                title: title, author: "Author", series: "", seriesIndex: "",
                year: "", publisher: "", format: "EPUB", tags: "", rating: 0,
                status: "Unread", sourcePath: source.path(percentEncoded: false),
                readableName: "Author - Shared.epub"
            )
        }

        let result = LibraryExporter.export(
            [row(title: "One", source: first), row(title: "Two", source: second)],
            to: output
        )
        #expect(result.copied == 2)

        let data = try Data(contentsOf: output.appending(path: "metadata.json"))
        let objects = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(objects.compactMap { $0["file"] as? String } == [
            "Author - Shared.epub", "Author - Shared (2).epub",
        ])
        #expect(fm.fileExists(atPath: output.appending(path: "Author - Shared.epub").path(percentEncoded: false)))
        #expect(fm.fileExists(atPath: output.appending(path: "Author - Shared (2).epub").path(percentEncoded: false)))
    }
}
