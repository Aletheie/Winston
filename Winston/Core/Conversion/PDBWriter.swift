import Foundation

nonisolated enum PDBWriter {

    static func assemble(records: [Data], name: String) -> Data {
        let numRecords = records.count
        let dataStart = 78 + numRecords * 8 + 2

        var offsets: [Int] = []
        offsets.reserveCapacity(numRecords)
        var cursor = dataStart
        for record in records {
            offsets.append(cursor)
            cursor += record.count
        }

        var file = Data()

        file.appendASCII(sanitizedName(name), length: 32)
        file.appendUInt16BE(0)
        file.appendUInt16BE(0)
        let palmTime = UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970) + 2_082_844_800)
        file.appendUInt32BE(palmTime)
        file.appendUInt32BE(palmTime)
        file.appendUInt32BE(0)
        file.appendUInt32BE(0)
        file.appendUInt32BE(0)
        file.appendUInt32BE(0)
        file.appendASCII("BOOK", length: 4)
        file.appendASCII("MOBI", length: 4)
        file.appendUInt32BE(UInt32(numRecords * 2))
        file.appendUInt32BE(0)
        file.appendUInt16BE(UInt16(numRecords))

        for (index, offset) in offsets.enumerated() {
            file.appendUInt32BE(UInt32(offset))
            let uid = UInt32(index * 2)
            file.appendUInt8(0)
            file.appendUInt8(UInt8(truncatingIfNeeded: uid >> 16))
            file.appendUInt8(UInt8(truncatingIfNeeded: uid >> 8))
            file.appendUInt8(UInt8(truncatingIfNeeded: uid))
        }

        file.appendUInt16BE(0)

        for record in records { file.append(record) }
        return file
    }

    private static func sanitizedName(_ name: String) -> String {
        let allowed = name.unicodeScalars.filter { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == " " || $0 == "-" || $0 == "_") }
        let cleaned = String(String.UnicodeScalarView(allowed)).trimmingCharacters(in: .whitespaces)
        let base = cleaned.isEmpty ? "Winston" : cleaned
        return String(base.prefix(31))
    }
}
