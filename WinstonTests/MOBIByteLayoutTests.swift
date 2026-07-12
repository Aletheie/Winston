import Testing
import Foundation
@testable import Winston

@MainActor
// Golden bytes verified against a real Kindle sideload — don't update expectations
// without re-verifying on hardware.
struct MOBIByteLayoutTests {

    private struct MOBIFile {
        let data: Data
        let offsets: [Int]
        var recordCount: Int { offsets.count }

        init(data: Data) {
            self.data = data
            let count = Int(data.readUInt16BE(at: 76))
            self.offsets = (0 ..< count).map { Int(data.readUInt32BE(at: 78 + $0 * 8)) }
        }

        func record(_ index: Int) -> Data {
            let end = index + 1 < offsets.count ? offsets[index + 1] : data.count
            return Data(data[offsets[index] ..< end])
        }
    }

    private func makeMOBI(
        title: String = "Layout", author: String = "L",
        bodyText: String = "The quick brown fox jumps over the lazy dog."
    ) throws -> MOBIFile {
        let epub = try EPUBFixture.make(title: title, author: author, bodyText: bodyText)
        defer { try? FileManager.default.removeItem(at: epub.deletingLastPathComponent()) }
        let mobi = try MOBIWriter.write(epub: epub)
        defer { try? FileManager.default.removeItem(at: mobi) }
        return try MOBIFile(data: Data(contentsOf: mobi))
    }

    @Test func pdbContainerIsWellFormed() throws {
        let file = try makeMOBI()
        let data = file.data

        #expect(String(data: data.subdata(in: 60 ..< 64), encoding: .ascii) == "BOOK")
        #expect(String(data: data.subdata(in: 64 ..< 68), encoding: .ascii) == "MOBI")

        try #require(file.recordCount >= 5)
        #expect(file.offsets[0] == 78 + file.recordCount * 8 + 2)
        for (a, b) in zip(file.offsets, file.offsets.dropFirst()) {
            #expect(a < b)
        }
        #expect(file.offsets.last! < data.count)
    }

    @Test func record0PinsHardwareVerifiedOffsets() throws {
        let file = try makeMOBI()
        let r0 = file.record(0)
        let flis = file.recordCount - 3
        let fcis = file.recordCount - 2

        #expect(r0.readUInt16BE(at: 0) == 1)
        #expect(r0.readUInt16BE(at: 10) == 4096)

        let textRecordCount = Int(r0.readUInt16BE(at: 8))
        let textLength = Int(r0.readUInt32BE(at: 4))
        let actualTextBytes = (1 ... textRecordCount).reduce(0) { $0 + file.record($1).count }
        #expect(actualTextBytes == textLength)

        let m = 16
        #expect(String(data: r0.subdata(in: m ..< m + 4), encoding: .ascii) == "MOBI")
        #expect(r0.readUInt32BE(at: m + 4) == 232)
        #expect(r0.readUInt32BE(at: m + 8) == 2)
        #expect(r0.readUInt32BE(at: m + 12) == 65001)
        #expect(r0.readUInt32BE(at: m + 20) == 6)

        let firstImage = Int(r0.readUInt32BE(at: m + 92))
        #expect(firstImage == 1 + textRecordCount)
        #expect(Int(r0.readUInt32BE(at: m + 108)) == firstImage)
        #expect(Int(r0.readUInt32BE(at: m + 64)) == firstImage)

        #expect(r0.readUInt32BE(at: m + 80) == 0x40)
        #expect(r0.readUInt32BE(at: m + 112) == 0x50)

        #expect(r0.readUInt32BE(at: m + 148) == 0xFFFF_FFFF)
        #expect(r0.readUInt32BE(at: m + 156) == 0)

        #expect(Int(r0.readUInt32BE(at: m + 176)) == (1 << 16) | (flis - 1))
        #expect(Int(r0.readUInt32BE(at: m + 184)) == fcis)
        #expect(r0.readUInt32BE(at: m + 188) == 1)
        #expect(Int(r0.readUInt32BE(at: m + 192)) == flis)
        #expect(r0.readUInt32BE(at: m + 196) == 1)
        #expect(r0.readUInt32BE(at: m + 224) == 0)
        #expect(r0.readUInt32BE(at: m + 228) == 0xFFFF_FFFF)

        let nameOffset = Int(r0.readUInt32BE(at: m + 68))
        let nameLength = Int(r0.readUInt32BE(at: m + 72))
        #expect(String(data: r0.subdata(in: nameOffset ..< nameOffset + nameLength), encoding: .utf8) == "Layout")
    }

    @Test func trailerRecordsAreByteExact() throws {
        let file = try makeMOBI()
        let textLength = file.record(0).readUInt32BE(at: 4)

        let expectedFLIS = Data([
            0x46, 0x4C, 0x49, 0x53,
            0x00, 0x00, 0x00, 0x08,
            0x00, 0x41,
            0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0xFF, 0xFF, 0xFF, 0xFF,
            0x00, 0x01,
            0x00, 0x03,
            0x00, 0x00, 0x00, 0x03,
            0x00, 0x00, 0x00, 0x01,
            0xFF, 0xFF, 0xFF, 0xFF,
        ])
        #expect(file.record(file.recordCount - 3) == expectedFLIS)

        var expectedFCIS = Data()
        expectedFCIS.appendASCII("FCIS", length: 4)
        expectedFCIS.appendUInt32BE(0x14)
        expectedFCIS.appendUInt32BE(0x10)
        expectedFCIS.appendUInt32BE(1)
        expectedFCIS.appendUInt32BE(0)
        expectedFCIS.appendUInt32BE(textLength)
        expectedFCIS.appendUInt32BE(0)
        expectedFCIS.appendUInt32BE(0x20)
        expectedFCIS.appendUInt32BE(8)
        expectedFCIS.appendUInt16BE(1)
        expectedFCIS.appendUInt16BE(1)
        expectedFCIS.appendUInt32BE(0)
        #expect(file.record(file.recordCount - 2) == expectedFCIS)

        #expect(file.record(file.recordCount - 1) == Data([0xE9, 0x8E, 0x0D, 0x0A]))
    }

    @Test func exthCarriesKindleIdentity() throws {
        let file = try makeMOBI()
        let r0 = file.record(0)

        let exthStart = 16 + 232
        #expect(String(data: r0.subdata(in: exthStart ..< exthStart + 4), encoding: .ascii) == "EXTH")

        var records: [Int: [Data]] = [:]
        let count = Int(r0.readUInt32BE(at: exthStart + 8))
        var cursor = exthStart + 12
        for _ in 0 ..< count {
            let type = Int(r0.readUInt32BE(at: cursor))
            let length = Int(r0.readUInt32BE(at: cursor + 4))
            records[type, default: []].append(r0.subdata(in: (cursor + 8) ..< (cursor + length)))
            cursor += length
        }

        #expect(records[501]?.first == Data("EBOK".utf8))

        let asin = try #require(records[113]?.first.flatMap { String(data: $0, encoding: .ascii) })
        #expect(records[504]?.first == Data(asin.utf8))
        #expect(asin.count == 10)
        #expect(asin.allSatisfy { ("A" ... "Z").contains($0) || ("0" ... "9").contains($0) })

        #expect(records[201]?.first == Data([0, 0, 0, 0]))
        #expect(records[202]?.first == Data([0, 0, 0, 0]))

        #expect(records[100]?.first == Data("L".utf8))
        #expect(records[503]?.first == Data("Layout".utf8))
    }

    @Test func czechTextNeverSplitsMidCharacter() throws {
        let czech = String(repeating: "Příliš žluťoučký kůň úpěl ďábelské ódy. ", count: 300)
        let file = try makeMOBI(bodyText: czech)
        let textRecordCount = Int(file.record(0).readUInt16BE(at: 8))
        try #require(textRecordCount >= 2)
        for index in 1 ... textRecordCount {
            #expect(String(data: file.record(index), encoding: .utf8) != nil,
                    "text record \(index) does not decode as standalone UTF-8")
        }
    }
}
