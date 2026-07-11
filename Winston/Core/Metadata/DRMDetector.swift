import Foundation
import PDFKit

nonisolated enum DRMDetector {
    static func isProtected(url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "mobi", "azw", "azw3": return mobiEncrypted(url)
        case "epub":                return EPUBArchive.entry("META-INF/rights.xml", in: url) != nil
        case "pdf":                 return pdfLocked(url)
        default:                    return false
        }
    }

    private static func mobiEncrypted(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count > 132 else { return false }
        guard Int(data.readUInt16BE(at: 76)) > 0 else { return false }
        let record0 = Int(data.readUInt32BE(at: 78))
        guard record0 + 14 <= data.count else { return false }
        let encryption = data.readUInt16BE(at: record0 + 12)
        return encryption == 1 || encryption == 2
    }

    private static func pdfLocked(_ url: URL) -> Bool {
        guard let document = PDFDocument(url: url) else { return false }
        return document.isEncrypted && document.isLocked
    }
}
