import AppKit
import CoreText
import Foundation
import Testing
@testable import Winston

@Suite("Local full-text index")
struct FullTextIndexTests {
    @Test func epubPhraseFindsItsChapterUsingOnlyLocalFiles() async throws {
        let epub = try EPUBFixture.makeWithPercentEncodedImage(title: "Kůň", author: "Autor")
        let directory = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: epub.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: directory)
        }
        let bookID = UUID()
        let service = FullTextIndexService(indexDirectory: directory)
        let snapshot = FullTextBookSnapshot(
            bookID: bookID,
            title: "Kůň",
            author: "Autor",
            source: source(epub, contentHash: try ContentHasher.sha256(of: epub))
        )

        let summary = try await service.synchronize([snapshot])
        let results = try await service.search("žluťoučký kůň úpěl")

        #expect(summary.indexedBooks == 1)
        #expect(summary.searchableBooks == 1)
        let result = try #require(results.first)
        #expect(result.bookID == bookID)
        #expect(result.chapters.first?.title == "Kapitola první")
        #expect(result.chapters.first?.excerpts.first?.text.contains("žluťoučký kůň úpěl") == true)
    }

    @Test func unchangedContentHashReusesIndexInsteadOfExtractingAgain() async throws {
        let source = temporaryDirectory().appending(path: "book.txt")
        let directory = temporaryDirectory()
        try Data("CHAPTER ONE\n\nA cached sentence lives here.".utf8).write(to: source)
        defer {
            try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: directory)
        }
        let service = FullTextIndexService(indexDirectory: directory)
        let snapshot = FullTextBookSnapshot(
            bookID: UUID(),
            title: "Cached",
            author: nil,
            source: self.source(source, contentHash: try ContentHasher.sha256(of: source))
        )

        let first = try await service.synchronize([snapshot])
        let second = try await service.synchronize([snapshot])

        #expect(first.indexedBooks == 1)
        #expect(first.reusedBooks == 0)
        #expect(second.indexedBooks == 0)
        #expect(second.reusedBooks == 1)
        #expect(try await service.search("cached sentence").count == 1)
    }

    @Test func changedContentHashReplacesStaleSearchText() async throws {
        let directory = temporaryDirectory()
        let firstSource = directory.appending(path: "first.txt")
        let secondSource = directory.appending(path: "second.txt")
        let indexDirectory = directory.appending(path: "index", directoryHint: .isDirectory)
        try Data("CHAPTER ONE\n\nThe old lighthouse sentence.".utf8).write(to: firstSource)
        try Data("CHAPTER ONE\n\nThe new observatory sentence.".utf8).write(to: secondSource)
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = FullTextIndexService(indexDirectory: indexDirectory)
        let bookID = UUID()
        let assetID = UUID()
        let first = FullTextBookSnapshot(
            bookID: bookID,
            title: "Changing",
            author: nil,
            source: source(
                firstSource,
                assetID: assetID,
                contentHash: try ContentHasher.sha256(of: firstSource)
            )
        )
        let second = FullTextBookSnapshot(
            bookID: bookID,
            title: "Changing",
            author: nil,
            source: source(
                secondSource,
                assetID: assetID,
                contentHash: try ContentHasher.sha256(of: secondSource)
            )
        )

        _ = try await service.synchronize([first])
        let refreshed = try await service.synchronize([second])

        #expect(refreshed.indexedBooks == 1)
        #expect(refreshed.reusedBooks == 0)
        #expect(try await service.search("old lighthouse").isEmpty)
        #expect(try await service.search("new observatory").count == 1)
    }

    @Test func externalEditRebuildsEvenWhenCatalogHashIsStale() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "changing.txt")
        let indexDirectory = directory.appending(path: "index", directoryHint: .isDirectory)
        try Data("CHAPTER ONE\n\nThe old orchard sentence.".utf8).write(to: source)
        let originalHash = try ContentHasher.sha256(of: source)
        let snapshot = FullTextBookSnapshot(
            bookID: UUID(),
            title: "Externally Changed",
            author: nil,
            source: self.source(source, contentHash: originalHash)
        )
        let service = FullTextIndexService(indexDirectory: indexDirectory)
        _ = try await service.synchronize([snapshot])

        try Data("CHAPTER ONE\n\nThe new planet sentence.".utf8).write(to: source, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(5)],
            ofItemAtPath: source.path(percentEncoded: false)
        )
        let refreshed = try await service.synchronize([snapshot])

        #expect(refreshed.indexedBooks == 1)
        #expect(try await service.search("old orchard").isEmpty)
        #expect(try await service.search("new planet").count == 1)
    }

    @Test func relinkingToSameNamedFileDoesNotReuseAnotherFilesIndex() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstDirectory = directory.appending(path: "first", directoryHint: .isDirectory)
        let secondDirectory = directory.appending(path: "second", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let firstSource = firstDirectory.appending(path: "same-name.txt")
        let secondSource = secondDirectory.appending(path: "same-name.txt")
        try Data("CHAPTER\nalpha phrase".utf8).write(to: firstSource)
        try Data("CHAPTER\nbravo phrase".utf8).write(to: secondSource)
        let sharedDate = Date(timeIntervalSince1970: 1_700_000_000)
        for source in [firstSource, secondSource] {
            try FileManager.default.setAttributes(
                [.modificationDate: sharedDate],
                ofItemAtPath: source.path(percentEncoded: false)
            )
        }

        let bookID = UUID()
        let assetID = UUID()
        let originalHash = try ContentHasher.sha256(of: firstSource)
        let service = FullTextIndexService(
            indexDirectory: directory.appending(path: "index", directoryHint: .isDirectory)
        )
        _ = try await service.synchronize([
            FullTextBookSnapshot(
                bookID: bookID,
                title: "Relinked",
                author: nil,
                source: source(firstSource, assetID: assetID, contentHash: originalHash)
            ),
        ])

        let refreshed = try await service.synchronize([
            FullTextBookSnapshot(
                bookID: bookID,
                title: "Relinked",
                author: nil,
                source: source(secondSource, assetID: assetID, contentHash: originalHash)
            ),
        ])

        #expect(refreshed.indexedBooks == 1)
        #expect(try await service.search("alpha phrase").isEmpty)
        #expect(try await service.search("bravo phrase").count == 1)
    }

    @Test func htmlTextAndPDFProduceChapterOrPageResults() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let html = directory.appending(path: "essay.html")
        let text = directory.appending(path: "notes.txt")
        let pdf = directory.appending(path: "paper.pdf")
        try Data("<html><body><h2>Second Movement</h2><p>Amber violin phrase.</p></body></html>".utf8)
            .write(to: html)
        try Data("KAPITOLA DRUHÁ\n\nTiché nádraží čeká.".utf8).write(to: text)
        try makeTextPDF(text: "A searchable paper constellation.", at: pdf)

        let service = FullTextIndexService(
            indexDirectory: directory.appending(path: "index", directoryHint: .isDirectory)
        )
        let snapshots = [
            snapshot(title: "Essay", url: html),
            snapshot(title: "Notes", url: text),
            snapshot(title: "Paper", url: pdf),
        ]

        let summary = try await service.synchronize(snapshots)
        let htmlResult = try await service.search("amber violin")
        let textResult = try await service.search("tiché nádraží")
        let pdfResult = try await service.search("paper constellation")

        #expect(summary.searchableBooks == 3)
        #expect(htmlResult.first?.chapters.first?.title == "Second Movement")
        #expect(textResult.first?.chapters.first?.title == "KAPITOLA DRUHÁ")
        #expect(pdfResult.first?.chapters.first?.kind == .page)
        #expect(pdfResult.first?.chapters.first?.ordinal == 1)
    }

    @Test func globalRelevanceIsAppliedBeforeTheBookLimit() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let weak = directory.appending(path: "weak.txt")
        let strong = directory.appending(path: "strong.txt")
        try Data(
            ("CHAPTER\n" + Array(repeating: "filler", count: 120).joined(separator: " ")
                + " globalterm").utf8
        ).write(to: weak)
        try Data(
            ("CHAPTER\n" + Array(repeating: "globalterm", count: 12).joined(separator: " ")).utf8
        ).write(to: strong)
        let weakID = UUID()
        let strongID = UUID()
        let service = FullTextIndexService(
            indexDirectory: directory.appending(path: "index", directoryHint: .isDirectory)
        )
        _ = try await service.synchronize([
            FullTextBookSnapshot(
                bookID: weakID,
                title: "Aardvark",
                author: nil,
                source: source(weak, contentHash: try ContentHasher.sha256(of: weak))
            ),
            FullTextBookSnapshot(
                bookID: strongID,
                title: "Zebra",
                author: nil,
                source: source(strong, contentHash: try ContentHasher.sha256(of: strong))
            ),
        ])

        let page = try await service.searchPage("globalterm", limit: 1)

        #expect(page.results.map(\.bookID) == [strongID])
        #expect(page.nextOffset == 1)
    }

    @Test func paginationReturnsStableDisjointBookPages() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FullTextIndexService(
            indexDirectory: directory.appending(path: "index", directoryHint: .isDirectory)
        )
        var snapshots: [FullTextBookSnapshot] = []
        for index in 0 ..< 5 {
            let url = directory.appending(path: "page-\(index).txt")
            try Data("CHAPTER\npaginationtoken \(index)".utf8).write(to: url)
            snapshots.append(FullTextBookSnapshot(
                bookID: UUID(),
                title: "Book \(index)",
                author: nil,
                source: source(url, contentHash: try ContentHasher.sha256(of: url))
            ))
        }
        _ = try await service.synchronize(snapshots)

        let first = try await service.searchPage("paginationtoken", limit: 2)
        let second = try await service.searchPage(
            "paginationtoken",
            limit: 2,
            offset: try #require(first.nextOffset)
        )
        let third = try await service.searchPage(
            "paginationtoken",
            limit: 2,
            offset: try #require(second.nextOffset)
        )
        let firstIDs = Set(first.results.map(\.bookID))
        let secondIDs = Set(second.results.map(\.bookID))
        let thirdIDs = Set(third.results.map(\.bookID))

        #expect(first.results.count == 2)
        #expect(second.results.count == 2)
        #expect(third.results.count == 1)
        #expect(firstIDs.isDisjoint(with: secondIDs))
        #expect(firstIDs.isDisjoint(with: thirdIDs))
        #expect(secondIDs.isDisjoint(with: thirdIDs))
        #expect(firstIDs.union(secondIDs).union(thirdIDs) == Set(snapshots.map(\.bookID)))
        #expect(third.nextOffset == nil)
    }

    @Test func unicodeTokenizerMatchesCzechTextWithoutTypedDiacritics() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "czech.txt")
        try Data("KAPITOLA\nPříliš žluťoučký kůň úpěl ďábelské ódy.".utf8).write(to: url)
        let service = FullTextIndexService(
            indexDirectory: directory.appending(path: "index", directoryHint: .isDirectory)
        )
        _ = try await service.synchronize([
            FullTextBookSnapshot(
                bookID: UUID(),
                title: "Čeština",
                author: nil,
                source: source(url, contentHash: try ContentHasher.sha256(of: url))
            ),
        ])

        let results = try await service.search("prilis zlutoucky kun")

        #expect(results.count == 1)
        #expect(results.first?.chapters.first?.excerpts.first?.text.contains("žluťoučký kůň") == true)
    }

    @Test func incrementalAssetGenerationReplacesStaleRowsAndRemovalDeletesThem() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "generation.txt")
        try Data("CHAPTER\noldgenerationtoken".utf8).write(to: url)
        let service = FullTextIndexService(
            indexDirectory: directory.appending(path: "index", directoryHint: .isDirectory)
        )
        let bookID = UUID()
        let assetID = UUID()
        let original = FullTextBookSnapshot(
            bookID: bookID,
            title: "Generation",
            author: nil,
            source: source(
                url,
                assetID: assetID,
                contentHash: try ContentHasher.sha256(of: url)
            )
        )
        _ = try await service.synchronize([original])

        try Data("CHAPTER\nnewgenerationtoken with different bytes".utf8)
            .write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(5)],
            ofItemAtPath: url.path(percentEncoded: false)
        )
        let replacement = FullTextBookSnapshot(
            bookID: bookID,
            title: "Generation",
            author: nil,
            source: source(
                url,
                assetID: assetID,
                contentHash: try ContentHasher.sha256(of: url)
            )
        )

        let updated = try await service.applyChanges([replacement], removing: [])
        #expect(updated.indexedBooks == 1)
        #expect(try await service.search("oldgenerationtoken").isEmpty)
        #expect(try await service.search("newgenerationtoken").map(\.bookID) == [bookID])

        let removed = try await service.applyChanges([], removing: [bookID])
        #expect(removed.searchableBooks == 0)
        #expect(try await service.search("newgenerationtoken").isEmpty)
    }

    @Test func searchObservesCallerCancellationBeforeTouchingSQLite() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FullTextIndexService(
            indexDirectory: directory.appending(path: "index", directoryHint: .isDirectory)
        )

        let cancelled = await Task {
            withUnsafeCurrentTask { task in task?.cancel() }
            do {
                _ = try await service.search("cancelled query")
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value

        #expect(cancelled)
    }

    @Test func synchronizationCreatesSQLiteIndexAndRemovesLegacyJSONCache() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let indexDirectory = directory.appending(path: "index", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
        let legacy = indexDirectory.appending(path: "\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: legacy)
        let url = directory.appending(path: "sqlite.txt")
        try Data("CHAPTER\nsqlitebackendtoken".utf8).write(to: url)
        let service = FullTextIndexService(indexDirectory: indexDirectory)

        _ = try await service.synchronize([
            FullTextBookSnapshot(
                bookID: UUID(),
                title: "SQLite",
                author: nil,
                source: source(url, contentHash: try ContentHasher.sha256(of: url))
            ),
        ])

        #expect(FileManager.default.fileExists(
            atPath: indexDirectory.appending(path: "fulltext.sqlite3").path(percentEncoded: false)
        ))
        #expect(!FileManager.default.fileExists(atPath: legacy.path(percentEncoded: false)))
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["WINSTON_FULLTEXT_BENCHMARKS"] == "1"),
        arguments: [100, 1_024]
    )
    func optInCorpusBenchmark(megabytes: Int) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let indexDirectory = directory.appending(path: "index", directoryHint: .isDirectory)
        let service = FullTextIndexService(indexDirectory: indexDirectory)
        let bytesPerFile = 8 * 1_024 * 1_024
        let totalBytes = megabytes * 1_024 * 1_024
        let line = Data(
            "benchmark filler text for the derived index benchmarkneedle and unicode kůň\n".utf8
        )
        var payload = Data()
        payload.reserveCapacity(bytesPerFile)
        while payload.count + line.count <= bytesPerFile {
            payload.append(line)
        }

        var snapshots: [FullTextBookSnapshot] = []
        var writtenBytes = 0
        var fileIndex = 0
        while writtenBytes < totalBytes {
            let byteCount = min(bytesPerFile, totalBytes - writtenBytes)
            let url = directory.appending(path: "corpus-\(fileIndex).txt")
            try payload.prefix(byteCount).write(to: url)
            snapshots.append(FullTextBookSnapshot(
                bookID: UUID(),
                title: "Corpus \(fileIndex)",
                author: "Benchmark",
                source: source(url, contentHash: nil)
            ))
            writtenBytes += byteCount
            fileIndex += 1
        }

        let clock = ContinuousClock()
        let indexingDuration = try await clock.measure {
            _ = try await service.synchronize(snapshots)
        }
        let queryDuration = try await clock.measure {
            _ = try await service.searchPage("benchmarkneedle", limit: 20)
        }

        print(
            "FullTextIndex benchmark: corpus=\(megabytes) MB "
                + "documents=\(snapshots.count) index=\(indexingDuration) query=\(queryDuration)"
        )
    }

    private func snapshot(title: String, url: URL) -> FullTextBookSnapshot {
        FullTextBookSnapshot(
            bookID: UUID(),
            title: title,
            author: nil,
            source: source(url, contentHash: try? ContentHasher.sha256(of: url))
        )
    }

    private func source(
        _ url: URL,
        assetID: UUID = UUID(),
        contentHash: String?
    ) -> FullTextBookSnapshot.Source {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path(percentEncoded: false)
        )
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return FullTextBookSnapshot.Source(
            fileURL: url,
            generation: .init(
                assetID: assetID,
                fileName: url.lastPathComponent,
                contentHash: contentHash,
                sizeBytes: size,
                dateAdded: .distantPast
            )
        )
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "WinstonFullText-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeTextPDF(text: String, at url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.beginPDFPage(nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 24)]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
    }
}
