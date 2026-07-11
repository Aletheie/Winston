import Foundation

nonisolated enum MOBICoverExtractor {
    static func coverData(from url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count > 132 else { return nil }

        let recordCount = Int(data.readUInt16BE(at: 76))
        guard recordCount > 1,
              78 + recordCount * 8 <= data.count else { return nil }

        let offsets = (0..<recordCount).map {
            Int(data.readUInt32BE(at: 78 + $0 * 8))
        }
        guard offsets.allSatisfy({ $0 >= 0 && $0 < data.count }),
              zip(offsets, offsets.dropFirst()).allSatisfy({ $0 < $1 }) else { return nil }

        let recordZero = offsets[0]
        let mobiOffset = recordZero + 16
        guard mobiOffset + 8 <= data.count,
              data[mobiOffset] == 0x4D, data[mobiOffset + 1] == 0x4F,
              data[mobiOffset + 2] == 0x42, data[mobiOffset + 3] == 0x49 else { return nil }

        let headerLength = Int(data.readUInt32BE(at: mobiOffset + 4))
        var firstImageIndex: Int?
        if headerLength >= 96 {
            let standard = Int(data.readUInt32BE(at: mobiOffset + 92))
            if (1..<recordCount).contains(standard) {
                firstImageIndex = standard
            } else if headerLength >= 112 {
                let legacy = Int(data.readUInt32BE(at: mobiOffset + 108))
                if (1..<recordCount).contains(legacy) { firstImageIndex = legacy }
            }
        }

        var coverOffset: Int?
        var thumbnailOffset: Int?
        MOBIIdentifiers.forEachEXTHRecord(
            in: data,
            mobiOff: mobiOffset,
            headerLen: headerLength
        ) { type, value in
            guard value.count == 4 else { return }
            if type == 201 { coverOffset = Int(value.readUInt32BE(at: 0)) }
            if type == 202 { thumbnailOffset = Int(value.readUInt32BE(at: 0)) }
        }

        if firstImageIndex == nil {
            firstImageIndex = (1..<recordCount).first { isImageMagic(data, at: offsets[$0]) }
        }

        guard let firstImageIndex else { return nil }
        var candidates: [Int] = []
        if let coverOffset { candidates.append(firstImageIndex + coverOffset) }
        if let thumbnailOffset { candidates.append(firstImageIndex + thumbnailOffset) }
        candidates.append(firstImageIndex)

        for index in candidates where (0..<recordCount).contains(index) {
            let image = record(at: index, offsets: offsets, data: data)
            if isImageMagic(image, at: 0) { return image }
        }
        return nil
    }

    private static func record(at index: Int, offsets: [Int], data: Data) -> Data {
        let start = offsets[index]
        let end = index + 1 < offsets.count ? offsets[index + 1] : data.count
        guard start < end, start < data.count else { return Data() }
        return data.subdata(in: start..<min(end, data.count))
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
