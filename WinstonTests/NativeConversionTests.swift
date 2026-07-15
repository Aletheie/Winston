import Testing
import Foundation
import AppKit
import CoreText
@testable import Winston

@MainActor
struct NativeConversionTests {

    // MARK: - TXT

    @Test func textReaderBuildsParagraphsAndHeadings() throws {
        let url = try TempFile.write("Chapter 1\n\nHello & welcome to <Winston>.\n\nSecond paragraph.",
                                     name: "Plain Book", ext: "txt")
        defer { TempFile.cleanup(url) }

        let doc = try TextReader.read(url)
        #expect(doc.title == "Plain Book")
        let html = try #require(doc.sections.first)
        #expect(html.contains("<h2>Chapter 1</h2>"))
        #expect(html.contains("Hello &amp; welcome to &lt;Winston&gt;."))
        #expect(html.contains("<p>Second paragraph.</p>"))
    }

    @Test func txtConvertsToReadableMOBI() throws {
        let url = try TempFile.write("Chapter 1\n\nThe quick brown fox jumps over the lazy dog.",
                                     name: "TXT Sample", ext: "txt")
        defer { TempFile.cleanup(url) }

        let output = try MOBIWriter.write(document: TextReader.read(url), source: url)
        defer { try? FileManager.default.removeItem(at: output) }

        #expect(output.pathExtension == "mobi")
        #expect(FileManager.default.fileExists(atPath: output.path(percentEncoded: false)))
        #expect(MOBIIdentifiers.read(from: output).cdeType == "EBOK")
        #expect(MetadataExtractor.extractMetadata(from: output).title == "TXT Sample")
    }

    @Test func textReaderDecodesWindows1250BeforeLatin1() throws {
        let text = "Příliš žluťoučký kůň úpěl ďábelské ódy."
        let data = try #require(text.data(using: .windowsCP1250))
        let directory = TempFile.makeDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Czech.txt")
        try data.write(to: url)

        let document = try TextReader.read(url)
        #expect(document.sections.joined().contains(text))
    }

    @Test func dispatcherRoutesTextNatively() {
        #expect(EbookConverter.canConvertNatively(from: "txt", to: .mobi))
        #expect(EbookConverter.canConvertNatively(from: "html", to: .mobi))
        #expect(EbookConverter.canConvertNatively(from: "pdf", to: .mobi))
        #expect(EbookConverter.kindleTarget(forFormat: "html") == .mobi)
        #expect(!EbookConverter.canConvertNatively(from: "doc", to: .mobi))
    }

    // MARK: - HTML

    @Test func htmlReaderPullsTitleBodyAndLocalImage() throws {
        let dir = TempFile.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try sampleJPEG().write(to: dir.appending(path: "pic.jpg"))
        let html = """
        <html><head><title>HTML &amp; Title</title></head>
        <body><h1>Heading</h1><p>Body text.</p><img src="pic.jpg" alt="x"/></body></html>
        """
        let url = dir.appending(path: "page.html")
        try Data(html.utf8).write(to: url)

        let doc = try HTMLReader.read(url)
        #expect(doc.title == "HTML & Title")
        #expect(try #require(doc.sections.first).contains("Body text."))
        #expect(doc.images.count == 1)
        #expect(doc.images.first?.ref == "pic.jpg")

        let content = MOBIHTMLBuilder.build(from: doc)
        #expect(content.images.count == 1)
        let rendered = String(decoding: content.html, as: UTF8.self)
        #expect(rendered.contains("recindex=\"1\""))
    }

    @Test func importedHTMLKeepsLocalImagesWithoutEscapingItsFolder() throws {
        let root = TempFile.makeDir()
        let managedRoot = TempFile.makeDir()
        let sourceDir = root.appending(path: "book", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: managedRoot)
        }

        let pixel = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZQmcAAAAASUVORK5CYII="
        ))
        try pixel.write(to: sourceDir.appending(path: "inside.png"))
        try pixel.write(to: root.appending(path: "outside.png"))
        let source = sourceDir.appending(path: "page.html")
        try Data("<body><img data-src=\"../outside.png\" alt=\"inside.png\" src=\"inside.png\"><img src=\"../outside.png\"></body>".utf8)
            .write(to: source)

        let managed = managedRoot.appending(path: "page.html")
        let portable = try #require(try HTMLAssetInliner.portableData(for: source))
        try portable.write(to: managed)
        let managedHTML = try String(contentsOf: managed, encoding: .utf8)
        #expect(managedHTML.contains("data:image/png;base64,"))
        #expect(managedHTML.contains("alt=\"inside.png\""))
        #expect(managedHTML.contains("../outside.png"))
        #expect(try HTMLReader.read(source).images.count == 1)

        try FileManager.default.removeItem(at: root)
        let document = try HTMLReader.read(managed)
        #expect(document.images.count == 1)
        #expect(MOBIHTMLBuilder.build(from: document).images.count == 1)
    }

    @Test func htmlConvertsToReadableMOBI() throws {
        let dir = TempFile.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "doc.html")
        try Data("<html><head><title>HTML Book</title></head><body><p>Readable.</p></body></html>".utf8)
            .write(to: url)

        let output = try MOBIWriter.write(document: HTMLReader.read(url), source: url)
        defer { try? FileManager.default.removeItem(at: output) }

        #expect(FileManager.default.fileExists(atPath: output.path(percentEncoded: false)))
        #expect(MetadataExtractor.extractMetadata(from: output).title == "HTML Book")
    }

    @Test func htmlReaderToleratesCommentsScriptsAndBodyAttributes() throws {
        let dir = TempFile.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let html = """
        <html><head>
          <title>Real Title</title>
          <style>.x{color:red}</style>
          <script>document.write('<img src="evil.jpg">');</script>
        </head>
        <body class="chapter" data-x="1">
          <!-- a stray </body> and <img src="ghost.jpg"> inside a comment -->
          <p>Visible &amp; real.</p>
        </body></html>
        """
        let url = dir.appending(path: "messy.html")
        try Data(html.utf8).write(to: url)

        let doc = try HTMLReader.read(url)
        #expect(doc.title == "Real Title")
        let body = try #require(doc.sections.first)
        #expect(body.contains("Visible &amp; real."))
        #expect(!body.contains("evil.jpg"))
        #expect(!body.contains("color:red"))
        #expect(doc.images.isEmpty)
    }

    @Test func htmlReaderHandlesUnclosedBodyAndUnquotedImg() throws {
        let dir = TempFile.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try sampleJPEG().write(to: dir.appending(path: "cover.jpg"))
        let url = dir.appending(path: "trunc.html")
        try Data("<html><body><p>Hello.</p><img src=cover.jpg></html>".utf8).write(to: url)

        let doc = try HTMLReader.read(url)
        #expect(try #require(doc.sections.first).contains("Hello."))
        #expect(doc.images.first?.ref == "cover.jpg")
    }

    @Test func htmlMetadataIgnoresCommentedOutTitle() throws {
        let dir = TempFile.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "commented.html")
        try Data("<html><head><!-- <title>Fake</title> --><title>Genuine</title></head><body><p>x</p></body></html>".utf8)
            .write(to: url)
        #expect(MetadataExtractor.extractMetadata(from: url).title == "Genuine")
    }

    // MARK: - PDF (best-effort)

    @Test func pdfReflowsTextAndConvertsToMOBI() throws {
        let url = TempFile.makeDir().appending(path: "Scanned.pdf")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try makeTextPDF(text: "Marmalade paragraph one.", at: url)

        let doc = try PDFReader.read(url)
        #expect(doc.sections.joined().contains("Marmalade"))
        #expect(doc.coverImage != nil)

        let output = try MOBIWriter.write(document: doc, source: url)
        defer { try? FileManager.default.removeItem(at: output) }
        #expect(FileManager.default.fileExists(atPath: output.path(percentEncoded: false)))
        #expect(MOBIIdentifiers.read(from: output).cdeType == "EBOK")
    }

    // MARK: - Fixtures

    private func sampleJPEG() -> Data {
        let image = NSImage(size: NSSize(width: 80, height: 120))
        image.lockFocus()
        NSColor.systemGreen.setFill()
        NSRect(x: 0, y: 0, width: 80, height: 120).fill()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])!
    }

    private func makeTextPDF(text: String, at url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        ctx.beginPDFPage(nil)
        let attributed = NSAttributedString(
            string: text, attributes: [.font: NSFont.systemFont(ofSize: 24)]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        ctx.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, ctx)
        ctx.endPDFPage()
        ctx.closePDF()
    }
}

// MARK: - Temp helpers

private enum TempFile {
    static func makeDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "WinstonConvTest-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func write(_ contents: String, name: String, ext: String) throws -> URL {
        let url = makeDir().appending(path: "\(name).\(ext)")
        try Data(contents.utf8).write(to: url)
        return url
    }

    static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
