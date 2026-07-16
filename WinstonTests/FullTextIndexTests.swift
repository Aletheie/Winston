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
            source: .init(fileURL: epub, contentHash: try ContentHasher.sha256(of: epub))
        )

        let summary = try await service.synchronize([snapshot])
        let results = await service.search("žluťoučký kůň úpěl")

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
            source: .init(fileURL: source, contentHash: try ContentHasher.sha256(of: source))
        )

        let first = try await service.synchronize([snapshot])
        let second = try await service.synchronize([snapshot])

        #expect(first.indexedBooks == 1)
        #expect(first.reusedBooks == 0)
        #expect(second.indexedBooks == 0)
        #expect(second.reusedBooks == 1)
        #expect(await service.search("cached sentence").count == 1)
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
        let first = FullTextBookSnapshot(
            bookID: bookID,
            title: "Changing",
            author: nil,
            source: .init(fileURL: firstSource, contentHash: try ContentHasher.sha256(of: firstSource))
        )
        let second = FullTextBookSnapshot(
            bookID: bookID,
            title: "Changing",
            author: nil,
            source: .init(fileURL: secondSource, contentHash: try ContentHasher.sha256(of: secondSource))
        )

        _ = try await service.synchronize([first])
        let refreshed = try await service.synchronize([second])

        #expect(refreshed.indexedBooks == 1)
        #expect(refreshed.reusedBooks == 0)
        #expect(await service.search("old lighthouse").isEmpty)
        #expect(await service.search("new observatory").count == 1)
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
        let htmlResult = await service.search("amber violin")
        let textResult = await service.search("tiché nádraží")
        let pdfResult = await service.search("paper constellation")

        #expect(summary.searchableBooks == 3)
        #expect(htmlResult.first?.chapters.first?.title == "Second Movement")
        #expect(textResult.first?.chapters.first?.title == "KAPITOLA DRUHÁ")
        #expect(pdfResult.first?.chapters.first?.kind == .page)
        #expect(pdfResult.first?.chapters.first?.ordinal == 1)
    }

    private func snapshot(title: String, url: URL) -> FullTextBookSnapshot {
        FullTextBookSnapshot(
            bookID: UUID(),
            title: title,
            author: nil,
            source: .init(fileURL: url, contentHash: try? ContentHasher.sha256(of: url))
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
