import Foundation

nonisolated enum MOBIIdentifiers {
    private static let maxEXTHRecordBytes = 1 * 1_024 * 1_024

    enum PersonalDocumentPreparation: Equatable, Sendable {
        case updated
        case alreadyPersonalDocument
        case missingContentType
        case unsupportedContentType(String)
    }

    struct Identifiers: Equatable, Sendable {
        var asin: String?
        var cdeType: String?
    }

    private enum EXTH {
        static let asin = 113
        static let cdeType = 501
        static let asin504 = 504
    }

    nonisolated static func read(from url: URL) -> Identifiers {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count > 132 else { return Identifiers() }

        guard let layout = mobiLayout(in: data) else { return Identifiers() }

        var result = Identifiers()
        forEachEXTHRecord(
            in: data,
            mobiOff: layout.mobiOffset,
            headerLen: layout.headerLength
        ) { type, value in
            let string = String(data: value, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            switch type {
            case EXTH.asin, EXTH.asin504:
                if let string, !string.isEmpty, result.asin == nil { result.asin = string }
            case EXTH.cdeType:
                if let string, !string.isEmpty { result.cdeType = string }
            default:
                break
            }
        }
        return result
    }

    /// Marks a staged MOBI/AZW payload as a personal document without changing
    /// PalmDB offsets. Modern MTP Kindles hide `system/thumbnails`; PDOC makes
    /// their indexer use the cover embedded in the book instead.
    nonisolated static func markAsPersonalDocument(
        at url: URL
    ) throws -> PersonalDocumentPreparation {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let layout = mobiLayout(in: data) else {
            return .missingContentType
        }

        var valueRange: Range<Int>?
        forEachEXTHRecordRange(
            in: data,
            mobiOff: layout.mobiOffset,
            headerLen: layout.headerLength
        ) { type, range in
            if type == EXTH.cdeType { valueRange = range }
        }
        guard let valueRange else { return .missingContentType }

        let value = String(data: data.subdata(in: valueRange), encoding: .ascii) ?? ""
        switch value {
        case "PDOC":
            return .alreadyPersonalDocument
        case "EBOK":
            guard valueRange.count == 4 else {
                return .unsupportedContentType(value)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(valueRange.lowerBound))
            try handle.write(contentsOf: Data("PDOC".utf8))
            try handle.synchronize()
            return .updated
        default:
            return .unsupportedContentType(value)
        }
    }

    // Spec offset is +112; the +80 fallback matches files the older writer produced.
    nonisolated static func hasEXTH(in data: Data, mobiOff: Int) -> Bool {
        let spec = data.readUInt32BE(at: mobiOff + 112)
        let legacy = data.readUInt32BE(at: mobiOff + 80)
        return (spec & 0x40) != 0 || (legacy & 0x40) != 0
    }

    nonisolated static func forEachEXTHRecord(
        in data: Data, mobiOff: Int, headerLen: Int, _ body: (_ type: Int, _ value: Data) -> Void
    ) {
        forEachEXTHRecordRange(
            in: data,
            mobiOff: mobiOff,
            headerLen: headerLen
        ) { type, range in
            body(type, data.subdata(in: range))
        }
    }

    private struct MOBILayout {
        let mobiOffset: Int
        let headerLength: Int
    }

    private nonisolated static func mobiLayout(in data: Data) -> MOBILayout? {
        let numRecords = Int(data.readUInt16BE(at: 76))
        guard numRecords > 0 else { return nil }

        let record0 = Int(data.readUInt32BE(at: 78))
        let mobiOffset = record0 + 16
        guard mobiOffset + 8 <= data.count,
              data[mobiOffset] == 0x4D, data[mobiOffset + 1] == 0x4F,
              data[mobiOffset + 2] == 0x42, data[mobiOffset + 3] == 0x49
        else { return nil }

        let headerLength = Int(data.readUInt32BE(at: mobiOffset + 4))
        guard headerLength >= 84 else { return nil }
        return MOBILayout(
            mobiOffset: mobiOffset,
            headerLength: headerLength
        )
    }

    private nonisolated static func forEachEXTHRecordRange(
        in data: Data,
        mobiOff: Int,
        headerLen: Int,
        _ body: (_ type: Int, _ valueRange: Range<Int>) -> Void
    ) {
        guard hasEXTH(in: data, mobiOff: mobiOff) else { return }

        let searchEnd = min(data.count - 3, mobiOff + headerLen + 16)
        guard searchEnd > mobiOff else { return }
        var exthStart: Int?
        for i in mobiOff ..< searchEnd
        where data[i] == 0x45 && data[i + 1] == 0x58 && data[i + 2] == 0x54 && data[i + 3] == 0x48 {
            exthStart = i
            break
        }
        guard let exthStart, exthStart + 12 <= data.count else { return }

        let recordCount = Int(data.readUInt32BE(at: exthStart + 8))
        var offset = exthStart + 12
        for _ in 0 ..< recordCount {
            guard offset + 8 <= data.count else { break }
            let type = Int(data.readUInt32BE(at: offset))
            let length = Int(data.readUInt32BE(at: offset + 4))
            guard length >= 8,
                  length <= maxEXTHRecordBytes,
                  offset + length <= data.count else { break }
            body(type, (offset + 8) ..< (offset + length))
            offset += length
        }
    }
}
