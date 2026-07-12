import Testing
import Foundation
@testable import Winston

@MainActor
struct MOBIWriterTests {

    @Test func convertsEPUBToReadableMOBIWithCoverAndMetadata() throws {
        let epub = try EPUBFixture.make(title: "Native Title", author: "Jane Doe")
        defer { try? FileManager.default.removeItem(at: epub.deletingLastPathComponent()) }

        let output = try MOBIWriter.write(epub: epub)
        defer { try? FileManager.default.removeItem(at: output) }

        #expect(output.pathExtension == "mobi")
        #expect(FileManager.default.fileExists(atPath: output.path(percentEncoded: false)))

        #expect(CoverExtractor.extractCover(from: output) != nil)

        let ids = MOBIIdentifiers.read(from: output)
        #expect(ids.asin != nil)
        #expect(ids.cdeType == "EBOK")

        let meta = MetadataExtractor.extractMetadata(from: output)
        #expect(meta.title == "Native Title")
        #expect(meta.author == "Jane Doe")
    }

    @Test func dispatchesEPUBToAZW3RequestNatively() {
        #expect(EbookConverter.canConvertNatively(from: "epub", to: .mobi))
        #expect(EbookConverter.canConvertForKindle("epub"))
        #expect(EbookConverter.kindleTarget(forFormat: "epub") == .mobi)
        #expect(EbookConverter.kindleTarget(forFormat: "fb2") == .azw3)
    }

    @Test func preparesKindleCoverThumbnailFromSentMOBI() throws {
        let epub = try EPUBFixture.make(title: "Thumb Title", author: "A")
        defer { try? FileManager.default.removeItem(at: epub.deletingLastPathComponent()) }
        let mobi = try MOBIWriter.write(epub: epub)
        defer { try? FileManager.default.removeItem(at: mobi) }

        let asin = try #require(MOBIIdentifiers.read(from: mobi).asin)
        let prepared = try #require(
            KindleCoverThumbnail.prepare(sentFile: mobi, coverSourceUUID: UUID())
        )
        defer { try? FileManager.default.removeItem(at: prepared.fileURL) }

        #expect(prepared.name == "thumbnail_\(asin)_EBOK_portrait.jpg")
        #expect(FileManager.default.fileExists(atPath: prepared.fileURL.path(percentEncoded: false)))
    }

    @Test func nativeMOBICarriesKindleTrailerRecords() throws {
        let epub = try EPUBFixture.make(title: "Trailer Title", author: "T")
        defer { try? FileManager.default.removeItem(at: epub.deletingLastPathComponent()) }
        let mobi = try MOBIWriter.write(epub: epub)
        defer { try? FileManager.default.removeItem(at: mobi) }

        let data = try Data(contentsOf: mobi)
        let numRecords = Int(data.readUInt16BE(at: 76))
        var offsets: [Int] = []
        for i in 0 ..< numRecords { offsets.append(Int(data.readUInt32BE(at: 78 + i * 8))) }
        func record(_ i: Int) -> Data {
            let start = offsets[i]
            let end = i + 1 < numRecords ? offsets[i + 1] : data.count
            return Data(data[start ..< end])
        }

        try #require(numRecords >= 4)
        #expect(record(numRecords - 3).prefix(4) == Data("FLIS".utf8))
        #expect(record(numRecords - 3).count == 36)
        #expect(record(numRecords - 2).prefix(4) == Data("FCIS".utf8))
        #expect(record(numRecords - 2).count == 44)
        #expect(Array(record(numRecords - 1)) == [0xE9, 0x8E, 0x0D, 0x0A])

        let r0 = record(0)
        let mobiOff = 16
        #expect(Int(r0.readUInt32BE(at: mobiOff + 0xC0)) == numRecords - 3)
        #expect(Int(r0.readUInt32BE(at: mobiOff + 0xB8)) == numRecords - 2)
        let firstImage = Int(r0.readUInt32BE(at: mobiOff + 0x5C))
        #expect(firstImage > 0 && firstImage < numRecords - 3)
    }

    @Test func splitTextKeepsMultibyteCharactersIntact() {
        let text = String(repeating: "a", count: 4095) + "€€€"
        let data = Data(text.utf8)
        let records = MOBIWriter.splitText(data, maxRecordSize: 4096)

        #expect(records.reduce(Data(), +) == data)
        for record in records {
            #expect(String(data: record, encoding: .utf8) != nil)
        }
    }
}

