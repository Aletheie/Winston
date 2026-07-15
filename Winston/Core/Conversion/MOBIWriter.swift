import Foundation
import OSLog

nonisolated enum MOBIWriter {

    enum WriteError: Error, LocalizedError {
        case unreadableEPUB(Error)
        case outputTooLarge

        var errorDescription: String? {
            switch self {
            case .unreadableEPUB(let underlying):
                "Couldn’t read the EPUB: \(underlying.localizedDescription)"
            case .outputTooLarge:
                "The book is too large for the MOBI format"
            }
        }
    }

    static func write(epub source: URL) throws -> URL {
        let parsed: ParsedEPUB
        let archive: EPUBArchive
        do {
            archive = try EPUBArchive(url: source)
            parsed = try EPUBReader.read(source, archive: archive)
        } catch {
            throw WriteError.unreadableEPUB(error)
        }

        let coverJPEG = parsed.coverImageHref
            .flatMap { archive.entry($0) }
            .flatMap { ImageTranscoder.jpegData(from: $0) }
        let content = MOBIHTMLBuilder.build(from: parsed, coverJPEG: coverJPEG, archive: archive)
        guard !archive.rejectedUnsafeEntry else { throw WriteError.outputTooLarge }
        let title = parsed.metadata.title?.nonEmpty
            ?? source.deletingPathExtension().lastPathComponent
        return try emit(content: content, title: title, metadata: parsed.metadata, source: source)
    }

    static func write(document doc: SourceDocument, source: URL) throws -> URL {
        let content = MOBIHTMLBuilder.build(from: doc)
        let title = doc.title.nonEmpty ?? source.deletingPathExtension().lastPathComponent
        return try emit(content: content, title: title, metadata: doc.metadata, source: source)
    }

    // MARK: - Emit

    private static func emit(
        content: MOBIContent, title: String, metadata: BookMetadata, source: URL
    ) throws -> URL {
        let html = content.html
        let textRecords = splitText(html, maxRecordSize: 4096)

        let firstImageRecord = 1 + textRecords.count
        let imageCount = content.images.count
        let flisRecord = firstImageRecord + imageCount
        let fcisRecord = flisRecord + 1
        let recordCount = fcisRecord + 2
        let firstImageIndex = imageCount > 0 ? firstImageRecord : recordCount
        guard html.count <= Int(UInt32.max),
              textRecords.count <= Int(UInt16.max),
              recordCount <= Int(UInt16.max) else {
            throw WriteError.outputTooLarge
        }

        Log.conversion.debug(
            "MOBI \"\(title, privacy: .public)\": \(html.count) HTML bytes, \(textRecords.count) text record(s), \(imageCount) image record(s), cover=\(content.coverIndex != nil), FLIS=\(flisRecord) FCIS=\(fcisRecord)"
        )

        let record0 = MOBIRecord0.build(
            title: title,
            metadata: metadata,
            asin: synthesizeASIN(),
            hasCover: content.coverIndex != nil,
            compression: 1,
            textLength: html.count,
            textRecordCount: textRecords.count,
            firstImageRecord: firstImageIndex,
            flisRecord: flisRecord,
            fcisRecord: fcisRecord
        )

        var records: [Data] = [record0]
        records.append(contentsOf: textRecords)
        records.append(contentsOf: content.images)
        // Kindle's indexer ignores a MOBI without the FLIS/FCIS/EOF trailer — the file copies over but never shows up.
        records.append(MOBITrailer.flis())
        records.append(MOBITrailer.fcis(textLength: html.count))
        records.append(MOBITrailer.eof())

        let fileSize = records.reduce(UInt64(80 + records.count * 8)) {
            $0 + UInt64($1.count)
        }
        guard fileSize <= UInt64(UInt32.max) else { throw WriteError.outputTooLarge }

        let file = PDBWriter.assemble(records: records, name: title)
        return try writeToTemp(file, basedOn: source)
    }

    // Split on UTF-8 character boundaries so accented text isn't garbled at record edges.
    static func splitText(_ data: Data, maxRecordSize: Int) -> [Data] {
        guard !data.isEmpty else { return [Data()] }
        let base = data.startIndex
        let count = data.count
        var records: [Data] = []
        var pos = 0
        while pos < count {
            var end = Swift.min(pos + maxRecordSize, count)
            if end < count {
                while end > pos, (data[base + end] & 0xC0) == 0x80 { end -= 1 }
                if end == pos { end = Swift.min(pos + maxRecordSize, count) }
            }
            records.append(data.subdata(in: (base + pos) ..< (base + end)))
            pos = end
        }
        return records
    }

    // MARK: - Helpers

    private static func writeToTemp(_ data: Data, basedOn source: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "WinstonConversions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let output = dir.appending(
            path: "\(UUID().uuidString)-\(source.deletingPathExtension().lastPathComponent).mobi"
        )
        try data.write(to: output, options: .atomic)
        return output
    }

    private static func synthesizeASIN() -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0 ..< 10).map { _ in chars.randomElement()! })
    }
}

// MARK: - Trailer records

nonisolated enum MOBITrailer {

    static func flis() -> Data {
        var d = Data()
        d.appendASCII("FLIS", length: 4)
        d.appendUInt32BE(8)
        d.appendUInt16BE(0x41)
        d.appendUInt16BE(0)
        d.appendUInt32BE(0)
        d.appendUInt32BE(0xFFFF_FFFF)
        d.appendUInt16BE(1)
        d.appendUInt16BE(3)
        d.appendUInt32BE(3)
        d.appendUInt32BE(1)
        d.appendUInt32BE(0xFFFF_FFFF)
        return d
    }

    static func fcis(textLength: Int) -> Data {
        var d = Data()
        d.appendASCII("FCIS", length: 4)
        d.appendUInt32BE(0x14)
        d.appendUInt32BE(0x10)
        d.appendUInt32BE(1)
        d.appendUInt32BE(0)
        d.appendUInt32BE(UInt32(truncatingIfNeeded: textLength))
        d.appendUInt32BE(0)
        d.appendUInt32BE(0x20)
        d.appendUInt32BE(8)
        d.appendUInt16BE(1)
        d.appendUInt16BE(1)
        d.appendUInt32BE(0)
        return d
    }

    static func eof() -> Data {
        Data([0xE9, 0x8E, 0x0D, 0x0A])
    }
}
