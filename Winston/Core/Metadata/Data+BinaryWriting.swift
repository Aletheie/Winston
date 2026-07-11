import Foundation

extension Data {

    nonisolated mutating func appendUInt8(_ value: UInt8) {
        append(value)
    }

    nonisolated mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    nonisolated mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    nonisolated mutating func appendASCII(_ string: String, length: Int) {
        var bytes = Array(string.utf8.prefix(length))
        bytes.append(contentsOf: repeatElement(0, count: Swift.max(0, length - bytes.count)))
        append(contentsOf: bytes)
    }

    nonisolated mutating func appendZeros(_ count: Int) {
        guard count > 0 else { return }
        append(contentsOf: repeatElement(UInt8(0), count: count))
    }

    nonisolated mutating func padTo4() {
        appendZeros((4 - (count % 4)) % 4)
    }

    nonisolated mutating func replaceUInt32BE(at offset: Int, with value: UInt32) {
        guard offset >= 0, offset + 4 <= count else { return }
        let base = startIndex + offset
        self[base]     = UInt8(truncatingIfNeeded: value >> 24)
        self[base + 1] = UInt8(truncatingIfNeeded: value >> 16)
        self[base + 2] = UInt8(truncatingIfNeeded: value >> 8)
        self[base + 3] = UInt8(truncatingIfNeeded: value)
    }
}

extension Data {
    nonisolated init(uint32BE value: UInt32) {
        self.init([
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ])
    }
}
