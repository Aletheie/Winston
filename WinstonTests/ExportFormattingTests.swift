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
    private let fixedNow = Date(timeIntervalSince1970: 2_000_000_000)

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
        let parent = root.appending(path: "output", directoryHint: .isDirectory)
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let first = root.appending(path: "first.epub")
        let second = root.appending(path: "second.epub")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)

        func row(title: String, source: URL) -> ExportRow {
            ExportRow(
                title: title, author: "Author", translator: "", series: "", seriesIndex: "",
                year: "", publisher: "", format: "EPUB", tags: "", rating: 0,
                status: "Unread", sourcePath: source.path(percentEncoded: false),
                readableName: "Author - Shared.epub", workUUID: "", workTitle: "",
                editionUUID: "", editionStatement: ""
            )
        }

        let result = LibraryExporter.export(
            [row(title: "One", source: first), row(title: "Two", source: second)],
            to: parent,
            now: fixedNow
        )
        let output = try #require(result.finalURL)
        #expect(result.copied == 2)
        #expect(result.failed == 0)

        let data = try Data(contentsOf: output.appending(path: "metadata.json"))
        let objects = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(objects.compactMap { $0["file"] as? String } == [
            "Author - Shared.epub", "Author - Shared (2).epub",
        ])
        #expect(fm.fileExists(atPath: output.appending(path: "Author - Shared.epub").path(percentEncoded: false)))
        #expect(fm.fileExists(atPath: output.appending(path: "Author - Shared (2).epub").path(percentEncoded: false)))
    }

    @Test func preexistingParentFilesAndExportDirectoriesAreNeverChanged() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(
            path: "ExportSentinel-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let source = root.appending(path: "source.epub")
        try Data("new book".utf8).write(to: source)
        let sentinel = root.appending(path: "Author - Shared.epub")
        try Data("sentinel".utf8).write(to: sentinel)
        let occupiedExport = root.appending(
            path: "Winston Export 2033-05-18 03-33-20",
            directoryHint: .isDirectory
        )
        try fm.createDirectory(at: occupiedExport, withIntermediateDirectories: false)
        try Data("owned by user".utf8).write(
            to: occupiedExport.appending(path: "keep.txt")
        )

        let result = LibraryExporter.export(
            [row(source: source)],
            to: root,
            now: fixedNow
        )
        let output = try #require(result.finalURL)

        #expect(output != occupiedExport)
        #expect(try Data(contentsOf: sentinel) == Data("sentinel".utf8))
        #expect(
            try Data(contentsOf: occupiedExport.appending(path: "keep.txt"))
                == Data("owned by user".utf8)
        )
        #expect(
            try Data(contentsOf: output.appending(path: "Author - Shared.epub"))
                == Data("new book".utf8)
        )
    }

    @Test func copyFailureProducesAPartialCommittedExport() throws {
        let fixture = try exportFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var fileSystem = LibraryExporter.FileSystem.live
        fileSystem.copyItem = { source, destination in
            if source == fixture.second {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        }

        let result = LibraryExporter.export(
            [
                row(title: "One", source: fixture.first, readableName: "One.epub"),
                row(title: "Two", source: fixture.second, readableName: "Two.epub"),
            ],
            to: fixture.parent,
            fileSystem: fileSystem,
            now: fixedNow
        )
        let output = try #require(result.finalURL)

        #expect(result.copied == 1)
        #expect(result.failed == 1)
        #expect(result.failures.first?.stage == .copyBook)
        #expect(FileManager.default.fileExists(
            atPath: output.appending(path: "One.epub").path(percentEncoded: false)
        ))
        #expect(!FileManager.default.fileExists(
            atPath: output.appending(path: "Two.epub").path(percentEncoded: false)
        ))
        let data = try Data(contentsOf: output.appending(path: "metadata.json"))
        let objects = try #require(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        #expect(objects.compactMap { $0["title"] as? String } == ["One"])
    }

    @Test func allRowsFailingStillPublishesTruthfulEmptyManifests() throws {
        let fixture = try exportFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var fileSystem = LibraryExporter.FileSystem.live
        fileSystem.copyItem = { _, _ in
            throw CocoaError(.fileReadNoSuchFile)
        }

        let result = LibraryExporter.export(
            [
                row(title: "One", source: fixture.first, readableName: "One.epub"),
                row(title: "Two", source: fixture.second, readableName: "Two.epub"),
            ],
            to: fixture.parent,
            fileSystem: fileSystem,
            now: fixedNow
        )
        let output = try #require(result.finalURL)
        let data = try Data(contentsOf: output.appending(path: "metadata.json"))
        let objects = try #require(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )

        #expect(result.copied == 0)
        #expect(result.failed == 2)
        #expect(result.failures.allSatisfy { $0.stage == .copyBook })
        #expect(objects.isEmpty)
    }

    @Test(arguments: ["metadata.csv", "metadata.json"])
    func requiredManifestFailurePreventsPublication(_ failingName: String) throws {
        let fixture = try exportFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var fileSystem = LibraryExporter.FileSystem.live
        fileSystem.writeData = { data, destination in
            if destination.lastPathComponent == failingName {
                throw CocoaError(.fileWriteNoPermission)
            }
            try data.write(to: destination, options: .atomic)
        }

        let result = LibraryExporter.export(
            [row(source: fixture.first)],
            to: fixture.parent,
            fileSystem: fileSystem,
            now: fixedNow
        )

        #expect(result.finalURL == nil)
        #expect(result.stagingURL == nil)
        #expect(result.failures.contains {
            $0.stage == (failingName == "metadata.csv" ? .writeCSV : .writeJSON)
        })
        #expect(try FileManager.default.contentsOfDirectory(
            at: fixture.parent,
            includingPropertiesForKeys: nil
        ).isEmpty)
    }

    @Test func publicationFailureCleansOnlyTheOwnedStagingDirectory() throws {
        let fixture = try exportFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sentinel = fixture.parent.appending(path: "keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        var fileSystem = LibraryExporter.FileSystem.live
        fileSystem.moveItem = { _, _ in
            throw CocoaError(.fileWriteUnknown)
        }

        let result = LibraryExporter.export(
            [row(source: fixture.first)],
            to: fixture.parent,
            fileSystem: fileSystem,
            now: fixedNow
        )

        #expect(result.finalURL == nil)
        #expect(result.stagingURL == nil)
        #expect(result.failures.contains { $0.stage == .publish })
        #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
        let remainingNames = try FileManager.default.contentsOfDirectory(
            at: fixture.parent,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)
        #expect(remainingNames == [sentinel.lastPathComponent])
    }

    @Test func emptyLibraryPublishesValidEmptyManifests() throws {
        let fixture = try exportFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = LibraryExporter.export(
            [],
            to: fixture.parent,
            now: fixedNow
        )
        let output = try #require(result.finalURL)
        let json = try Data(contentsOf: output.appending(path: "metadata.json"))
        let objects = try #require(
            JSONSerialization.jsonObject(with: json) as? [[String: Any]]
        )

        #expect(result.copied == 0)
        #expect(result.skipped == 0)
        #expect(result.failed == 0)
        #expect(objects.isEmpty)
    }

    private func row(
        title: String = "One",
        source: URL,
        readableName: String = "Author - Shared.epub"
    ) -> ExportRow {
        ExportRow(
            title: title,
            author: "Author",
            translator: "",
            series: "",
            seriesIndex: "",
            year: "",
            publisher: "",
            format: "EPUB",
            tags: "",
            rating: 0,
            status: "Unread",
            sourcePath: source.path(percentEncoded: false),
            readableName: readableName,
            workUUID: "",
            workTitle: "",
            editionUUID: "",
            editionStatement: ""
        )
    }

    private func exportFixture() throws -> (
        root: URL,
        parent: URL,
        first: URL,
        second: URL
    ) {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "ExportFixture-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let parent = root.appending(path: "parent", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        let first = root.appending(path: "first.epub")
        let second = root.appending(path: "second.epub")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)
        return (root, parent, first, second)
    }
}

@MainActor
struct EditionExportRowTests {
    @Test func emitsOneRowPerAssetWithWorkAndEditionFields() {
        let work = Work(title: "Dune", author: "Frank Herbert")
        let book = Book(fileName: "primary.epub", originalFileName: "Dune.epub")
        book.translator = "Jan Novák"
        book.editionStatement = "First Czech edition"
        book.work = work
        book.assets = [
            BookAsset(fileName: "primary.epub", book: book),
            BookAsset(fileName: "sibling.mobi", origin: .generated, book: book),
        ]

        let rows = ExportService.rows(for: [book])

        #expect(rows.map(\.format).sorted() == ["EPUB", "MOBI"])
        #expect(rows.allSatisfy { $0.workUUID == work.uuid.uuidString })
        #expect(rows.allSatisfy { $0.editionUUID == book.uuid.uuidString })
        #expect(rows.allSatisfy { $0.translator == "Jan Novák" })
    }
}

@MainActor
@Suite(.serialized)
struct ExportServiceTests {
    @Test func revealsTheCommittedChildAndReportsTheResult() async throws {
        let library = try await TestLibrary()
        let source = library.root.appending(path: "service-source.epub")
        try Data("book".utf8).write(to: source)
        let book = Book(
            fileName: "service.epub",
            originalFileName: "Service.epub"
        )
        book.title = "Service"
        try library.installBookFile(from: source, fileName: book.fileName)
        library.context.insert(book)
        try library.context.save()
        let parent = library.root.appending(
            path: "Exports",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        let toasts = ToastCenter()
        var revealedURL: URL?
        let service = ExportService(
            modelContext: library.context,
            toasts: toasts,
            revealExport: { revealedURL = $0 }
        )

        service.exportLibrary(to: parent)
        let deadline = Date.now.addingTimeInterval(3)
        while service.isExporting, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        let result = try #require(service.lastResult)
        let finalURL = try #require(result.finalURL)
        #expect(finalURL.deletingLastPathComponent() == parent)
        #expect(revealedURL == finalURL)
        #expect(revealedURL != parent)
        #expect(toasts.messages.last?.style == .success)
    }
}
