import Foundation

extension Data {
    nonisolated func readUInt16BE(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[startIndex + offset]) << 8
             | UInt16(self[startIndex + offset + 1])
    }

    nonisolated func readUInt32BE(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return UInt32(self[startIndex + offset]) << 24
             | UInt32(self[startIndex + offset + 1]) << 16
             | UInt32(self[startIndex + offset + 2]) << 8
             | UInt32(self[startIndex + offset + 3])
    }
}
