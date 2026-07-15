import Foundation

nonisolated enum MOBIIdentifiers {
    private static let maxEXTHRecordBytes = 1 * 1_024 * 1_024

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

        let numRecords = Int(data.readUInt16BE(at: 76))
        guard numRecords > 0 else { return Identifiers() }

        let r0 = Int(data.readUInt32BE(at: 78))
        let mobiOff = r0 + 16
        guard mobiOff + 8 <= data.count,
              data[mobiOff] == 0x4D, data[mobiOff + 1] == 0x4F,
              data[mobiOff + 2] == 0x42, data[mobiOff + 3] == 0x49
        else { return Identifiers() }

        let headerLen = Int(data.readUInt32BE(at: mobiOff + 4))
        guard headerLen >= 84 else { return Identifiers() }

        var result = Identifiers()
        forEachEXTHRecord(in: data, mobiOff: mobiOff, headerLen: headerLen) { type, value in
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

    // Spec offset is +112; the +80 fallback matches files the older writer produced.
    nonisolated static func hasEXTH(in data: Data, mobiOff: Int) -> Bool {
        let spec = data.readUInt32BE(at: mobiOff + 112)
        let legacy = data.readUInt32BE(at: mobiOff + 80)
        return (spec & 0x40) != 0 || (legacy & 0x40) != 0
    }

    nonisolated static func forEachEXTHRecord(
        in data: Data, mobiOff: Int, headerLen: Int, _ body: (_ type: Int, _ value: Data) -> Void
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
            body(type, data.subdata(in: (offset + 8) ..< (offset + length)))
            offset += length
        }
    }
}
