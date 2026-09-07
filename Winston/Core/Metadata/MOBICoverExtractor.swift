import Foundation

nonisolated enum MOBICoverExtractor {
    private static let maxImageRecordBytes = 32 * 1_024 * 1_024
    private static let maxHeaderBytes = 64 * 1_024
    private static let maxEXTHRecords = 65_536

    static func coverData(from url: URL) -> Data? {
        guard !Task.isCancelled,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let length = try? handle.seekToEnd(),
              let byteCount = Int(exactly: length) else { return nil }
        return coverData(byteCount: byteCount) { range in
            do {
                try handle.seek(toOffset: UInt64(range.lowerBound))
                return try handle.read(upToCount: range.count)
            } catch {
                return nil
            }
        }
    }

    static func coverData(from data: Data) -> Data? {
        coverData(byteCount: data.count) { data.subdata(in: $0) }
    }

    /// One parser for memory and file sources. Reads are confined to the PalmDB
    /// directory, MOBI/EXTH headers and candidate image; text and large unrelated
    /// EXTH values are skipped, even in a multi-gigabyte container.
    static func coverData(byteCount: Int, read: (Range<Int>) -> Data?) -> Data? {
        func bytes(at offset: Int, count: Int) -> Data? {
            guard !Task.isCancelled, offset >= 0, count >= 0,
                  offset <= byteCount, count <= byteCount - offset,
                  let data = read(offset..<(offset + count)), data.count == count else { return nil }
            return data
        }
        guard byteCount > 132, let pdb = bytes(at: 0, count: 78) else { return nil }
        let recordCount = Int(pdb.readUInt16BE(at: 76))
        guard recordCount > 1,
              let directory = bytes(at: 78, count: recordCount * 8) else { return nil }

        let offsets = (0..<recordCount).map {
            Int(directory.readUInt32BE(at: $0 * 8))
        }
        guard offsets[0] >= 78 + directory.count,
              offsets.allSatisfy({ $0 < byteCount }),
              zip(offsets, offsets.dropFirst()).allSatisfy({ $0 < $1 }) else { return nil }

        let recordZero = offsets[0]
        let recordZeroLength = offsets[1] - recordZero
        let mobiOffset = 16
        guard recordZeroLength >= 24,
              let prefix = bytes(at: recordZero, count: min(recordZeroLength, 132)),
              prefix[mobiOffset..<(mobiOffset + 4)] == Data("MOBI".utf8) else { return nil }

        let headerLength = Int(prefix.readUInt32BE(at: mobiOffset + 4))
        guard headerLength >= 8, headerLength <= maxHeaderBytes,
              headerLength <= recordZeroLength - mobiOffset else { return nil }

        var firstImageIndex: Int?
        if headerLength >= 96 {
            let standard = Int(prefix.readUInt32BE(at: mobiOffset + 92))
            if (1..<recordCount).contains(standard) {
                firstImageIndex = standard
            } else if headerLength >= 112 {
                let legacy = Int(prefix.readUInt32BE(at: mobiOffset + 108))
                if (1..<recordCount).contains(legacy) { firstImageIndex = legacy }
            }
        }

        var coverOffset: Int?
        var thumbnailOffset: Int?
        if MOBIIdentifiers.hasEXTH(in: prefix, mobiOff: mobiOffset),
           let header = bytes(at: recordZero, count: min(recordZeroLength, mobiOffset + headerLength + 19)) {
            let end = min(header.count - 3, mobiOffset + headerLength + 16)
            if let exth = (mobiOffset..<end).first(where: {
                header[$0] == 0x45 && header[$0 + 1] == 0x58 && header[$0 + 2] == 0x54 && header[$0 + 3] == 0x48
            }), recordZeroLength - exth >= 12,
            let exthHeader = bytes(at: recordZero + exth, count: 12) {
                let count = Int(exthHeader.readUInt32BE(at: 8))
                var cursor = recordZero + exth + 12
                for _ in 0..<min(count, maxEXTHRecords) {
                    guard offsets[1] - cursor >= 8,
                          let entry = bytes(at: cursor, count: 8) else { break }
                    let type = entry.readUInt32BE(at: 0)
                    let length = Int(entry.readUInt32BE(at: 4))
                    guard length >= 8, length <= 1 * 1_024 * 1_024,
                          length <= offsets[1] - cursor else { break }
                    if length == 12, type == 201 || type == 202,
                       let value = bytes(at: cursor + 8, count: 4) {
                        let offset = Int(value.readUInt32BE(at: 0))
                        if type == 201 { coverOffset = offset } else { thumbnailOffset = offset }
                    }
                    cursor += length
                }
            }
        }

        if firstImageIndex == nil {
            for index in 1..<recordCount {
                guard !Task.isCancelled else { return nil }
                if let magic = bytes(at: offsets[index], count: 4), isImageMagic(magic, at: 0) {
                    firstImageIndex = index
                    break
                }
            }
        }

        guard let firstImageIndex else { return nil }
        var candidates: [Int] = []
        if let coverOffset { candidates.append(firstImageIndex + coverOffset) }
        if let thumbnailOffset { candidates.append(firstImageIndex + thumbnailOffset) }
        candidates.append(firstImageIndex)

        for index in candidates where (0..<recordCount).contains(index) {
            let start = offsets[index]
            let end = index + 1 < offsets.count ? offsets[index + 1] : byteCount
            guard end - start >= 4, end - start <= maxImageRecordBytes,
                  let magic = bytes(at: start, count: 4), isImageMagic(magic, at: 0) else { continue }
            if let image = bytes(at: start, count: end - start) { return image }
        }
        return nil
    }

    private static func isImageMagic(_ data: Data, at offset: Int) -> Bool {
        guard offset >= 0, offset + 4 <= data.count else { return false }
        if data[offset] == 0xFF, data[offset + 1] == 0xD8 { return true }
        if data[offset] == 0x89, data[offset + 1] == 0x50,
           data[offset + 2] == 0x4E, data[offset + 3] == 0x47 { return true }
        if data[offset] == 0x47, data[offset + 1] == 0x49, data[offset + 2] == 0x46 { return true }
        return false
    }
}
