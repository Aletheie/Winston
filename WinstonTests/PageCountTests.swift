import Testing
import Foundation
import CoreGraphics
@testable import Winston

@Suite("Page counts")
struct PageCountTests {

    // MARK: - EPUB

    @Test func epubEstimateComesFromSpineText() throws {
        let url = try EPUBFixture.make(
            title: "Long One", author: "A",
            bodyText: String(repeating: "x", count: 5000)
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let meta = MetadataExtractor.extractMetadata(from: url)
        #expect(meta.pageCount == 3)
    }

    @Test func epubShortBookIsAtLeastOnePage() throws {
        let url = try EPUBFixture.make(title: "Tiny", author: "A", bodyText: "Very short.")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let meta = MetadataExtractor.extractMetadata(from: url)
        #expect(meta.pageCount == 1)
    }

    @Test func epubExtractsTranslatorRole() throws {
        let url = try EPUBFixture.make(title: "Dune", author: "Frank Herbert", translator: "Jan Novák")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(MetadataExtractor.extractMetadata(from: url).translator == "Jan Novák")
    }

    // MARK: - PDF

    @Test func pdfReportsItsRealPageCount() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "WinstonPageCount-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = try #require(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
        for _ in 0..<3 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(mediaBox)
            context.endPDFPage()
        }
        context.closePDF()

        #expect(PageCountEstimator.pageCountSync(at: url, format: "PDF") == 3)
        #expect(MetadataExtractor.extractMetadata(from: url).pageCount == 3)
    }

    // MARK: - MOBI

    @Test func mobiUsesPalmDocTextLength() {
        var data = Data()
        data.appendZeros(76)          // PDB header up to the record count
        data.appendUInt16BE(1)        // numRecords @76
        data.appendUInt32BE(88)       // record 0 offset @78
        data.appendZeros(6)           // record entry tail + gap, record 0 starts at 88
        data.appendUInt16BE(2)        // PalmDoc: compression
        data.appendUInt16BE(0)        //          unused
        data.appendUInt32BE(6000)     //          text length → ceil(6000/2048) = 3
        data.appendUInt16BE(3)        //          record count
        data.appendUInt16BE(4096)     //          record size
        data.appendUInt32BE(0)        //          encryption + unused
        data.appendASCII("MOBI", length: 4)
        data.appendZeros(64)          // pad past the 132-byte minimum

        #expect(PageCountEstimator.mobiPageCount(in: data) == 3)
    }

    @Test func mobiWithoutTextLengthGivesNothing() {
        #expect(PageCountEstimator.mobiPageCount(in: Data(repeating: 0, count: 200)) == nil)
    }

    // MARK: - Merge and sample heuristics

    @Test func applyFillsPageCountOnlyWhenEmpty() {
        let book = Book(fileName: "a.epub", originalFileName: "A.epub")
        var meta = BookMetadata()
        meta.pageCount = 120
        book.apply(meta)
        #expect(book.pageCount == 120)

        meta.pageCount = 999
        book.apply(meta)
        #expect(book.pageCount == 120)
    }

    @Test func sampleNoticeShowsOnlyForShortUndismissedBooks() {
        let book = Book(fileName: "a.epub", originalFileName: "A.epub")
        #expect(!book.probablySample)

        book.pageCount = 12
        #expect(book.probablySample)

        book.sampleNoticeDismissed = true
        #expect(!book.probablySample)

        let long = Book(fileName: "b.epub", originalFileName: "B.epub")
        long.pageCount = 320
        #expect(!long.probablySample)
    }
}
