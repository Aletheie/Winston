import Foundation

nonisolated enum MOBIRecord0 {

    private static let mobiHeaderLength = 232

    static func build(
        title: String,
        metadata: BookMetadata,
        asin: String,
        hasCover: Bool,
        compression: UInt16,
        textLength: Int,
        textRecordCount: Int,
        firstImageRecord: Int,
        flisRecord: Int,
        fcisRecord: Int
    ) -> Data {
        let titleBytes = Data(title.utf8)
        let exth = buildEXTH(title: title, metadata: metadata, asin: asin, hasCover: hasCover)

        var rec = Data()

        rec.appendUInt16BE(compression)
        rec.appendUInt16BE(0)
        rec.appendUInt32BE(UInt32(textLength))
        rec.appendUInt16BE(UInt16(textRecordCount))
        rec.appendUInt16BE(4096)
        rec.appendUInt16BE(0)
        rec.appendUInt16BE(0)

        rec.appendASCII("MOBI", length: 4)
        rec.appendUInt32BE(UInt32(mobiHeaderLength))
        rec.appendUInt32BE(2)
        rec.appendUInt32BE(65001)
        rec.appendUInt32BE(UInt32.random(in: 1 ... .max))
        rec.appendUInt32BE(6)
        for _ in 0 ..< 10 { rec.appendUInt32BE(0xFFFF_FFFF) }
        rec.appendUInt32BE(UInt32(firstImageRecord))

        let fullNameOffsetField = rec.count
        rec.appendUInt32BE(0)
        rec.appendUInt32BE(UInt32(titleBytes.count))
        rec.appendUInt32BE(0)
        rec.appendUInt32BE(0x40)
        rec.appendUInt32BE(0)
        rec.appendUInt32BE(6)
        rec.appendUInt32BE(UInt32(firstImageRecord))
        rec.appendUInt32BE(0)
        rec.appendUInt32BE(0)
        rec.appendUInt32BE(0)
        rec.appendUInt32BE(UInt32(firstImageRecord))
        rec.appendUInt32BE(0x50)

        rec.appendZeros(148 - 116)
        rec.appendUInt32BE(0xFFFF_FFFF)
        rec.appendUInt32BE(0xFFFF_FFFF)
        rec.appendUInt32BE(0)
        rec.appendUInt32BE(0)
        rec.appendZeros(176 - 164)
        let lastContentRecord = UInt32(Swift.max(1, flisRecord - 1))
        rec.appendUInt32BE((UInt32(1) << 16) | lastContentRecord)
        rec.appendUInt32BE(1)
        rec.appendUInt32BE(UInt32(fcisRecord))
        rec.appendUInt32BE(1)
        rec.appendUInt32BE(UInt32(flisRecord))
        rec.appendUInt32BE(1)
        rec.appendUInt32BE(0)
        rec.appendUInt32BE(0)
        rec.appendUInt32BE(0xFFFF_FFFF)
        rec.appendUInt32BE(0)
        rec.appendUInt32BE(0xFFFF_FFFF)
        rec.appendUInt32BE(0xFFFF_FFFF)
        rec.appendUInt32BE(0)
        rec.appendUInt32BE(0xFFFF_FFFF)

        rec.append(exth)
        let fullNameOffset = rec.count
        rec.append(titleBytes)
        rec.appendUInt16BE(0)
        rec.padTo4()

        rec.replaceUInt32BE(at: fullNameOffsetField, with: UInt32(fullNameOffset))
        return rec
    }

    // MARK: - EXTH

    private static func buildEXTH(
        title: String, metadata: BookMetadata, asin: String, hasCover: Bool
    ) -> Data {
        var records: [(type: Int, value: Data)] = []
        func addString(_ type: Int, _ string: String?) {
            guard let string, !string.isEmpty else { return }
            records.append((type, Data(string.utf8)))
        }

        addString(100, metadata.author)
        addString(101, metadata.publisher)
        addString(103, metadata.description)
        addString(104, metadata.isbn)
        addString(106, metadata.year)
        addString(113, asin)
        if hasCover {
            records.append((201, Data(uint32BE: 0)))
            records.append((202, Data(uint32BE: 0)))
        }
        records.append((501, Data("EBOK".utf8)))
        addString(503, title)
        addString(504, asin)

        var body = Data()
        for record in records {
            body.appendUInt32BE(UInt32(record.type))
            body.appendUInt32BE(UInt32(8 + record.value.count))
            body.append(record.value)
        }

        let unpadded = 12 + body.count
        let padded = (unpadded + 3) & ~3
        var exth = Data()
        exth.appendASCII("EXTH", length: 4)
        exth.appendUInt32BE(UInt32(padded))
        exth.appendUInt32BE(UInt32(records.count))
        exth.append(body)
        exth.appendZeros(padded - unpadded)
        return exth
    }
}
