import Testing
import Foundation
@testable import Winston

struct DRMDetectorTests {

    private func writeMobi(encryption: UInt16, ext: String) throws -> URL {
        let r0 = 100
        var bytes = [UInt8](repeating: 0, count: 200)
        bytes[76] = 0x00; bytes[77] = 0x01
        bytes[78] = 0x00; bytes[79] = 0x00; bytes[80] = 0x00; bytes[81] = UInt8(r0)
        bytes[r0 + 12] = UInt8(encryption >> 8); bytes[r0 + 13] = UInt8(encryption & 0xFF)
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\(ext)")
        try Data(bytes).write(to: url)
        return url
    }

    @Test func detectsMobiEncryptionFlag() throws {
        let drm = try writeMobi(encryption: 2, ext: "azw3")
        let clear = try writeMobi(encryption: 0, ext: "azw3")
        defer {
            try? FileManager.default.removeItem(at: drm)
            try? FileManager.default.removeItem(at: clear)
        }
        #expect(DRMDetector.isProtected(url: drm) == true)
        #expect(DRMDetector.isProtected(url: clear) == false)
    }

    @Test func unknownExtensionIsNotProtected() {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).txt")
        #expect(DRMDetector.isProtected(url: url) == false)
    }
}
