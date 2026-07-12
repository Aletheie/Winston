import Foundation
import AppKit
import ZIPFoundation

enum EPUBFixture {

    static func make(
        title: String, author: String,
        bodyText: String = "Hello from Winston's native conversion. The quick brown fox jumps over the lazy dog."
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "WinstonEPUBFixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appending(path: "book.epub")
        let archive = try Archive(url: url, accessMode: .create)

        func add(_ path: String, _ data: Data) throws {
            let staged = dir.appending(path: "stage_" + path.replacingOccurrences(of: "/", with: "_"))
            try data.write(to: staged)
            try archive.addEntry(with: path, fileURL: staged)
        }

        try add("mimetype", Data("application/epub+zip".utf8))
        try add("META-INF/container.xml", Data(container.utf8))
        try add("OEBPS/content.opf", Data(opf(title: title, author: author).utf8))
        try add("OEBPS/chap1.xhtml", Data(chapter(bodyText: bodyText).utf8))
        try add("OEBPS/cover.jpg", jpegData())
        return url
    }

    static func makeWithPercentEncodedImage(title: String, author: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "WinstonEPUBFixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appending(path: "book.epub")
        let archive = try Archive(url: url, accessMode: .create)

        func add(_ path: String, _ data: Data) throws {
            let staged = dir.appending(path: "stage_" + path.replacingOccurrences(of: "/", with: "_"))
            try data.write(to: staged)
            try archive.addEntry(with: path, fileURL: staged)
        }

        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>\(title)</dc:title>
            <dc:creator>\(author)</dc:creator>
            <dc:language>cs</dc:language>
            <dc:identifier id="bookid">urn:uuid:00000000-0000-0000-0000-000000000002</dc:identifier>
            <meta name="cover" content="cover-img"/>
          </metadata>
          <manifest>
            <item id="cover-img" href="cover%20image.jpg" media-type="image/jpeg"/>
            <item id="chap1" href="chap1.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="chap1"/>
          </spine>
        </package>
        """
        let chapter = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>Kapitola 1</title></head>
        <body>
          <h1>Kapitola první</h1>
          <p>Příliš žluťoučký kůň úpěl ďábelské ódy.</p>
          <img src="cover%20image.jpg" alt="cover"/>
        </body>
        </html>
        """

        try add("mimetype", Data("application/epub+zip".utf8))
        try add("META-INF/container.xml", Data(container.utf8))
        try add("OEBPS/content.opf", Data(opf.utf8))
        try add("OEBPS/chap1.xhtml", Data(chapter.utf8))
        try add("OEBPS/cover image.jpg", jpegData())
        return url
    }

    static func jpegData(width: Int = 120, height: Int = 180) -> Data {
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        let rep = NSBitmapImageRep(data: tiff)!
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])!
    }

    private static let container = """
    <?xml version="1.0"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """

    private static func opf(title: String, author: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>\(title)</dc:title>
            <dc:creator>\(author)</dc:creator>
            <dc:language>en</dc:language>
            <dc:identifier id="bookid">urn:uuid:00000000-0000-0000-0000-000000000001</dc:identifier>
            <meta name="cover" content="cover-img"/>
          </metadata>
          <manifest>
            <item id="cover-img" href="cover.jpg" media-type="image/jpeg"/>
            <item id="chap1" href="chap1.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="chap1"/>
          </spine>
        </package>
        """
    }

    private static func chapter(bodyText: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>Chapter 1</title></head>
        <body>
          <h1>Chapter One</h1>
          <p>\(bodyText)</p>
          <img src="cover.jpg" alt="cover"/>
        </body>
        </html>
        """
    }
}
