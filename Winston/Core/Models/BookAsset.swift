import Foundation
import SwiftData

nonisolated enum AssetOrigin: String, CaseIterable, Codable, Sendable {
    case original
    case generated
    case imported
}

nonisolated enum AssetValidation: String, CaseIterable, Codable, Sendable {
    case ok
    case missing
    case corrupt
}

@Model
final class BookAsset {
    @Attribute(.unique) var uuid: UUID
    var fileName: String
    var originRaw: String?
    var contentHash: String?
    var generatedFromContentHash: String?
    var sizeBytes: Int64 = 0
    var dateAdded: Date
    var validationStatusRaw: String?
    var book: Book?

    init(
        uuid: UUID = UUID(),
        fileName: String,
        origin: AssetOrigin = .original,
        contentHash: String? = nil,
        generatedFromContentHash: String? = nil,
        sizeBytes: Int64 = 0,
        dateAdded: Date = Date(),
        validationStatus: AssetValidation? = nil,
        book: Book? = nil
    ) {
        self.uuid = uuid
        self.fileName = fileName
        self.originRaw = origin.rawValue
        self.contentHash = contentHash
        self.generatedFromContentHash = generatedFromContentHash
        self.sizeBytes = sizeBytes
        self.dateAdded = dateAdded
        self.validationStatusRaw = validationStatus?.rawValue
        self.book = book
    }

    var fileURL: URL { BookFileStore.url(for: fileName) }
    var format: String { (fileName as NSString).pathExtension.uppercased() }

    var origin: AssetOrigin {
        get { originRaw.flatMap(AssetOrigin.init(rawValue:)) ?? .original }
        set { originRaw = newValue.rawValue }
    }

    var validationStatus: AssetValidation? {
        get { validationStatusRaw.flatMap(AssetValidation.init(rawValue:)) }
        set { validationStatusRaw = newValue?.rawValue }
    }

    var sizeDisplay: String {
        guard sizeBytes > 0 else { return "\u{2014}" }
        return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}
