import Testing
import Foundation
import AppKit
import UniformTypeIdentifiers
@testable import Winston

@MainActor
struct ConversionPipelineTests {

    @Test func epubConversionOpensTheArchiveExactlyOnce() throws {
        let epub = try EPUBFixture.make(title: "Single Open", author: "S")
        defer { try? FileManager.default.removeItem(at: epub.deletingLastPathComponent()) }

        #expect(EPUBArchive.openCount(for: epub) == 0)
        let mobi = try MOBIWriter.write(epub: epub)
        defer { try? FileManager.default.removeItem(at: mobi) }

        #expect(EPUBArchive.openCount(for: epub) == 1)
    }

    @Test func percentEncodedImageHrefsStillResolve() throws {
        let epub = try EPUBFixture.makeWithPercentEncodedImage(title: "Encoded", author: "E")
        defer { try? FileManager.default.removeItem(at: epub.deletingLastPathComponent()) }
        let mobi = try MOBIWriter.write(epub: epub)
        defer { try? FileManager.default.removeItem(at: mobi) }

        #expect(CoverExtractor.extractCover(from: mobi) != nil)

        let data = try Data(contentsOf: mobi)
        #expect(data.range(of: Data("žluťoučký".utf8)) != nil)

        #expect(EPUBArchive.openCount(for: epub) == 1)
    }

    @Test func metadataAndCoverExtractionMatchWriterOutput() throws {
        let epub = try EPUBFixture.make(title: "Shared Parse", author: "P")
        defer { try? FileManager.default.removeItem(at: epub.deletingLastPathComponent()) }

        let parsed = try EPUBReader.read(epub)
        let direct = MetadataExtractor.extractMetadata(from: epub)
        #expect(parsed.metadata == direct)
        #expect(parsed.coverImageHref == "OEBPS/cover.jpg")
    }

    @Test func quickLookPayloadExtractsMOBIAndAZW3Cover() throws {
        let epub = try EPUBFixture.make(title: "Quick Look", author: "Q")
        defer { try? FileManager.default.removeItem(at: epub.deletingLastPathComponent()) }
        let mobi = try MOBIWriter.write(epub: epub)
        defer { try? FileManager.default.removeItem(at: mobi) }

        let mobiPayload = try #require(KindleQuickLookPreview.payload(for: mobi))
        #expect(mobiPayload.contentTypeIdentifier == UTType.jpeg.identifier)
        #expect(mobiPayload.pixelWidth > 0)
        #expect(mobiPayload.pixelHeight > mobiPayload.pixelWidth)
        #expect(NSImage(data: mobiPayload.imageData) != nil)

        let azw3 = mobi.deletingPathExtension().appendingPathExtension("azw3")
        try Data(contentsOf: mobi).write(to: azw3)
        defer { try? FileManager.default.removeItem(at: azw3) }
        let azw3Payload = try #require(KindleQuickLookPreview.payload(for: azw3))
        #expect(azw3Payload.imageData == mobiPayload.imageData)
    }

    @Test func quickLookPayloadRejectsInvalidOrUnsupportedFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "WinstonQuickLookInvalid-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalidMOBI = directory.appending(path: "broken.mobi")
        let unsupported = directory.appending(path: "cover.epub")
        try Data("not a book".utf8).write(to: invalidMOBI)
        try Data("not a book".utf8).write(to: unsupported)

        #expect(KindleQuickLookPreview.payload(for: invalidMOBI) == nil)
        #expect(KindleQuickLookPreview.payload(for: unsupported) == nil)
    }
}
