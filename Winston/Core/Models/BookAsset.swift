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

/// Where a concrete file entered Winston. This is deliberately more precise
/// than `AssetOrigin`, which remains as a compatibility/display classification.
nonisolated enum AssetSourceProvenance: String, CaseIterable, Codable, Sendable {
    case directImport
    case manualFile
    case calibreImport
    case conversion
    case legacyMigration
    case backupRestore
    case unknown
}

/// Storage availability and content validation are separate concerns: a
/// corrupt file is still locally available, while a valid file may be offline.
nonisolated enum AssetAvailability: String, CaseIterable, Codable, Sendable {
    case available
    case missing
    case unavailable
}

nonisolated enum CoverScope: String, CaseIterable, Codable, Sendable {
    case work
    case edition
    case generatedAsset
}

/// Explicit owner of a cover payload. Edition filenames retain the legacy
/// layout; the prefixes make work and generated-asset covers collision-free.
nonisolated enum CoverOwner: Hashable, Codable, Sendable {
    case work(UUID)
    case edition(UUID)
    case generatedAsset(UUID)

    private enum CodingKeys: String, CodingKey {
        case scope
        case id
    }

    var scope: CoverScope {
        switch self {
        case .work: .work
        case .edition: .edition
        case .generatedAsset: .generatedAsset
        }
    }

    var id: UUID {
        switch self {
        case .work(let id), .edition(let id), .generatedAsset(let id):
            id
        }
    }

    var storageFileName: String {
        switch self {
        case .work(let id):
            "work-\(id.uuidString).jpg"
        case .edition(let id):
            // Compatibility with covers already stored by edition UUID.
            "\(id.uuidString).jpg"
        case .generatedAsset(let id):
            "asset-\(id.uuidString).jpg"
        }
    }

    var generationKey: String {
        "\(scope.rawValue):\(id.uuidString.lowercased())"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let scope = try container.decode(CoverScope.self, forKey: .scope)
        let id = try container.decode(UUID.self, forKey: .id)
        self = switch scope {
        case .work: .work(id)
        case .edition: .edition(id)
        case .generatedAsset: .generatedAsset(id)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scope, forKey: .scope)
        try container.encode(id, forKey: .id)
    }
}

nonisolated struct CoverReference: Codable, Equatable, Hashable, Sendable {
    let owner: CoverOwner
    let version: Int
}

@Model
final class BookAsset {
    @Attribute(.unique) var uuid: UUID
    var fileName: String
    var formatRaw: String?
    var originRaw: String?
    var sourceProvenanceRaw: String?
    var sourceIdentifier: String?
    var contentHash: String?
    var generatedFromContentHash: String?
    var sizeBytes: Int64 = 0
    var drmProtected: Bool?
    var dateAdded: Date
    var validationStatusRaw: String?
    var availabilityRaw: String?
    var coverVersionRaw: Int?
    var book: Book?

    init(
        uuid: UUID = UUID(),
        fileName: String,
        origin: AssetOrigin = .original,
        format: String? = nil,
        sourceProvenance: AssetSourceProvenance? = nil,
        sourceIdentifier: String? = nil,
        contentHash: String? = nil,
        generatedFromContentHash: String? = nil,
        sizeBytes: Int64 = 0,
        drmProtected: Bool? = nil,
        dateAdded: Date = Date(),
        validationStatus: AssetValidation? = nil,
        availability: AssetAvailability? = nil,
        coverVersion: Int = 0,
        book: Book? = nil
    ) {
        self.uuid = uuid
        self.fileName = fileName
        formatRaw = Self.normalizedFormat(
            format ?? (fileName as NSString).pathExtension
        )
        self.originRaw = origin.rawValue
        sourceProvenanceRaw = (
            sourceProvenance
                ?? (origin == .generated ? .conversion : .unknown)
        ).rawValue
        self.sourceIdentifier = sourceIdentifier
        self.contentHash = contentHash
        self.generatedFromContentHash = generatedFromContentHash
        self.sizeBytes = sizeBytes
        self.drmProtected = drmProtected
        self.dateAdded = dateAdded
        self.validationStatusRaw = validationStatus?.rawValue
        availabilityRaw = (
            availability
                ?? (validationStatus == .missing ? .missing : .available)
        ).rawValue
        coverVersionRaw = max(0, coverVersion)
        self.book = book
    }

    var fileURL: URL { BookFileStore.url(for: fileName) }
    var format: String {
        get {
            Self.normalizedFormat(formatRaw)
                ?? Self.normalizedFormat((fileName as NSString).pathExtension)
                ?? ""
        }
        set { formatRaw = Self.normalizedFormat(newValue) }
    }

    var origin: AssetOrigin {
        get { originRaw.flatMap(AssetOrigin.init(rawValue:)) ?? .original }
        set { originRaw = newValue.rawValue }
    }

    var sourceProvenance: AssetSourceProvenance {
        get {
            sourceProvenanceRaw.flatMap(AssetSourceProvenance.init(rawValue:))
                ?? .unknown
        }
        set { sourceProvenanceRaw = newValue.rawValue }
    }

    var validationStatus: AssetValidation? {
        get { validationStatusRaw.flatMap(AssetValidation.init(rawValue:)) }
        set { validationStatusRaw = newValue?.rawValue }
    }

    var availability: AssetAvailability {
        get {
            availabilityRaw.flatMap(AssetAvailability.init(rawValue:))
                ?? (validationStatus == .missing ? .missing : .available)
        }
        set { availabilityRaw = newValue.rawValue }
    }

    var isUsable: Bool {
        availability == .available
            && validationStatus != .missing
            && validationStatus != .corrupt
    }

    var coverVersion: Int {
        get { max(0, coverVersionRaw ?? 0) }
        set { coverVersionRaw = max(0, newValue) }
    }

    var coverReference: CoverReference {
        CoverReference(owner: .generatedAsset(uuid), version: coverVersion)
    }

    var sizeDisplay: String {
        guard sizeBytes > 0 else { return "\u{2014}" }
        return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    fileprivate static func normalizedFormat(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value.uppercased()
    }
}

nonisolated enum CatalogModelInvariantViolation: Equatable, Sendable {
    case missingPrimaryAsset
    case danglingPrimaryAsset(UUID)
    case assetBelongsToAnotherEdition(UUID)
    case staleAssetFormat(assetID: UUID, expected: String)
    case missingAssetProvenance(UUID)
    case inconsistentAssetAvailability(UUID)
    case primaryFileNameMirror
    case primarySizeMirror
    case primaryDRMMirror
    case missingCoverScope
    case invalidCoverOwner
}

/// First-stage compatibility boundary for Work / Edition / Asset ownership.
/// `BookAsset` owns file facts. `Book.fileName`, `fileSizeBytes` and
/// `drmProtected` are maintained only as mirrors of the explicit primary asset.
@MainActor
enum CatalogModelInvariantService {
    @discardableResult
    static func repair(
        asset: BookAsset,
        fallbackProvenance: AssetSourceProvenance? = nil
    ) -> Bool {
        var changed = false
        let derivedFormat = BookAsset.normalizedFormat(
            (asset.fileName as NSString).pathExtension
        )
        if let derivedFormat, asset.formatRaw != derivedFormat {
            asset.formatRaw = derivedFormat
            changed = true
        }
        if asset.sourceProvenanceRaw.flatMap(AssetSourceProvenance.init(rawValue:)) == nil {
            asset.sourceProvenance = fallbackProvenance ?? inferredProvenance(for: asset.origin)
            changed = true
        }

        let parsedAvailability = asset.availabilityRaw.flatMap(AssetAvailability.init(rawValue:))
        let expectedAvailability: AssetAvailability
        if asset.validationStatus == .missing {
            expectedAvailability = .missing
        } else if parsedAvailability == nil || parsedAvailability == .missing {
            expectedAvailability = .available
        } else {
            expectedAvailability = parsedAvailability ?? .available
        }
        if asset.availabilityRaw != expectedAvailability.rawValue {
            asset.availability = expectedAvailability
            changed = true
        }
        if (asset.coverVersionRaw ?? 0) < 0 {
            asset.coverVersion = 0
            changed = true
        }
        return changed
    }

    @discardableResult
    static func repair(book: Book) -> Bool {
        var changed = false
        for asset in book.assets {
            if asset.book?.uuid != book.uuid {
                asset.book = book
                changed = true
            }
            if repair(asset: asset) { changed = true }
        }

        guard !book.assets.isEmpty else {
            if book.primaryAssetUUID != nil {
                book.primaryAssetUUID = nil
                changed = true
            }
            return repairCoverInvariant(book) || changed
        }

        let selected = book.explicitPrimaryAsset
            ?? book.assets.first(where: { $0.fileName == book.fileName })
            ?? book.assets.first(where: { $0.uuid == book.uuid })
            ?? book.assets
                .filter(\.isUsable)
                .sorted(by: assetPrecedes)
                .first
            ?? book.assets.sorted(by: assetPrecedes).first

        if let selected {
            if book.primaryAssetUUID != selected.uuid {
                book.primaryAssetUUID = selected.uuid
                changed = true
            }
            if selected.sizeBytes <= 0, book.fileSizeBytes > 0 {
                selected.sizeBytes = book.fileSizeBytes
                changed = true
            }
            if selected.drmProtected == nil, book.drmProtected != nil {
                selected.drmProtected = book.drmProtected
                changed = true
            }
            if book.fileName != selected.fileName {
                book.fileName = selected.fileName
                changed = true
            }
            if book.fileSizeBytes != selected.sizeBytes {
                book.fileSizeBytes = selected.sizeBytes
                changed = true
            }
            if book.drmProtected != selected.drmProtected {
                book.drmProtected = selected.drmProtected
                changed = true
            }
        }
        return repairCoverInvariant(book) || changed
    }

    static func violations(in book: Book) -> [CatalogModelInvariantViolation] {
        var result: [CatalogModelInvariantViolation] = []
        if book.assets.isEmpty {
            if let primaryID = book.primaryAssetUUID {
                result.append(.danglingPrimaryAsset(primaryID))
            }
        } else if let primaryID = book.primaryAssetUUID {
            if !book.assets.contains(where: { $0.uuid == primaryID }) {
                result.append(.danglingPrimaryAsset(primaryID))
            }
        } else {
            result.append(.missingPrimaryAsset)
        }
        for asset in book.assets {
            if asset.book?.uuid != book.uuid {
                result.append(.assetBelongsToAnotherEdition(asset.uuid))
            }
            if let expected = BookAsset.normalizedFormat(
                (asset.fileName as NSString).pathExtension
            ), asset.formatRaw != expected {
                result.append(.staleAssetFormat(assetID: asset.uuid, expected: expected))
            }
            if asset.sourceProvenanceRaw.flatMap(AssetSourceProvenance.init(rawValue:)) == nil {
                result.append(.missingAssetProvenance(asset.uuid))
            }
            let parsedAvailability = asset.availabilityRaw.flatMap(AssetAvailability.init(rawValue:))
            if parsedAvailability == nil
                || (asset.validationStatus == .missing && parsedAvailability != .missing)
                || (asset.validationStatus != .missing && parsedAvailability == .missing) {
                result.append(.inconsistentAssetAvailability(asset.uuid))
            }
        }
        if let primary = book.explicitPrimaryAsset {
            if book.fileName != primary.fileName { result.append(.primaryFileNameMirror) }
            if book.fileSizeBytes != primary.sizeBytes { result.append(.primarySizeMirror) }
            if book.drmProtected != primary.drmProtected { result.append(.primaryDRMMirror) }
        }
        if book.coverScopeRaw.flatMap(CoverScope.init(rawValue:)) == nil {
            result.append(.missingCoverScope)
        } else if !book.hasValidCoverOwner
                    || (book.coverScope != .generatedAsset && book.coverAssetUUID != nil) {
            result.append(.invalidCoverOwner)
        }
        return result
    }

    private static func inferredProvenance(
        for origin: AssetOrigin
    ) -> AssetSourceProvenance {
        switch origin {
        case .original: .unknown
        case .generated: .conversion
        case .imported: .unknown
        }
    }

    private static func assetPrecedes(_ lhs: BookAsset, _ rhs: BookAsset) -> Bool {
        if lhs.dateAdded != rhs.dateAdded { return lhs.dateAdded < rhs.dateAdded }
        return lhs.uuid.uuidString < rhs.uuid.uuidString
    }

    private static func repairCoverInvariant(_ book: Book) -> Bool {
        guard book.coverScopeRaw.flatMap(CoverScope.init(rawValue:)) != nil else {
            book.coverScopeRaw = CoverScope.edition.rawValue
            book.coverAssetUUID = nil
            return true
        }
        guard book.hasValidCoverOwner else {
            book.coverScopeRaw = CoverScope.edition.rawValue
            book.coverAssetUUID = nil
            return true
        }
        if book.coverScope != .generatedAsset, book.coverAssetUUID != nil {
            book.coverAssetUUID = nil
            return true
        }
        return false
    }
}
