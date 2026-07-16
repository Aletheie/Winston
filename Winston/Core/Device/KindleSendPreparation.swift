import Foundation

struct KindleSendDescriptor {
    let bookUUID: UUID
    let displayName: String
    let sourceURL: URL
    let originalFileName: String
    let sourceFormat: String
    let targetFileName: String
    let targetFormat: String
    let sourceFingerprint: String
    let sendSizeBytes: UInt64
    let requiresConversion: Bool
    let hasStaleTargetConversion: Bool
    let coverVersion: Int
    let hasCover: Bool
    let drmProtected: Bool
    let fileUnavailable: Bool
}

@MainActor
enum KindleSendPreparation {
    private struct AssetOption {
        let fileName: String
        let format: String
        let validation: AssetValidation?
        let origin: AssetOrigin
        let generatedFromContentHash: String?
        let contentHash: String?
        let sizeBytes: Int64
        let dateAdded: Date
    }

    static func descriptor(for book: Book) -> KindleSendDescriptor {
        let options = assetOptions(for: book)
        let primarySourceHash = options.first(where: { $0.fileName == book.fileName })?.contentHash
        let usable = options.filter {
            guard $0.validation != .missing, $0.validation != .corrupt else { return false }
            guard $0.fileName != book.fileName, $0.origin == .generated else { return true }
            guard let primarySourceHash else { return false }
            return $0.generatedFromContentHash == primarySourceHash
        }
        let primary = usable.first(where: { $0.fileName == book.fileName })
        let chosen: AssetOption
        if let primary, !EbookConverter.needsConversion(format: primary.format) {
            chosen = primary
        } else if let ready = usable.filter({ !EbookConverter.needsConversion(format: $0.format) })
            .sorted(by: assetPrecedes).first {
            chosen = ready
        } else {
            chosen = primary ?? usable.first ?? options.first ?? fallbackOption(for: book)
        }

        let requiresConversion = EbookConverter.needsConversion(format: chosen.format)
        let targetFormat = requiresConversion
            ? EbookConverter.kindleTarget(forFormat: chosen.format).ext
            : chosen.format.lowercased()
        let baseName = (book.originalFileName as NSString).deletingPathExtension
        let targetFileName = "\(baseName).\(targetFormat)"
        let primaryOption = options.first(where: { $0.fileName == book.fileName })
        let sourceFingerprint = primarySourceHash ?? fallbackFingerprint(for: book, primary: primaryOption)
        let generatedTargets = options.filter {
            $0.origin == .generated
                && $0.format.caseInsensitiveCompare(targetFormat) == .orderedSame
        }
        let hasCurrentTarget = generatedTargets.contains { option in
            guard option.validation != .missing, option.validation != .corrupt,
                  let primarySourceHash else { return false }
            return option.generatedFromContentHash == primarySourceHash
        }
        let staleTarget = !generatedTargets.isEmpty && !hasCurrentTarget
        let sourceURL = BookFileStore.url(for: chosen.fileName)
        let unavailable = chosen.validation == .missing
            || chosen.validation == .corrupt
            || !FileManager.default.fileExists(atPath: sourceURL.path(percentEncoded: false))
        let supportsCoverThumbnail = ["azw", "azw3", "mobi"].contains(targetFormat)
        let storedSize = UInt64(max(0, chosen.sizeBytes))
        let resolvedSize = storedSize > 0
            ? storedSize
            : UInt64(max(0, BookFileStore.size(of: chosen.fileName)))

        return KindleSendDescriptor(
            bookUUID: book.uuid,
            displayName: book.displayTitle,
            sourceURL: sourceURL,
            originalFileName: book.originalFileName,
            sourceFormat: chosen.format,
            targetFileName: targetFileName,
            targetFormat: targetFormat,
            sourceFingerprint: sourceFingerprint,
            sendSizeBytes: requiresConversion ? 0 : resolvedSize,
            requiresConversion: requiresConversion,
            hasStaleTargetConversion: staleTarget,
            coverVersion: book.coverVersion,
            hasCover: supportsCoverThumbnail && CoverStore.exists(for: book.uuid),
            drmProtected: book.drmProtected == true,
            fileUnavailable: unavailable
        )
    }

    static func candidate(for book: Book) -> KindleSyncCandidate {
        let descriptor = descriptor(for: book)
        let blockReason: KindleSyncReason?
        if descriptor.drmProtected {
            blockReason = .drmProtected
        } else if descriptor.fileUnavailable {
            blockReason = .fileUnavailable
        } else {
            blockReason = nil
        }
        return KindleSyncCandidate(
            id: book.uuid,
            title: book.displayTitle,
            author: book.displayAuthor,
            matchKey: book.deviceMatchKey,
            sourceFormat: descriptor.sourceFormat.uppercased(),
            targetFileName: descriptor.targetFileName,
            targetFormat: descriptor.targetFormat.uppercased(),
            sourceFingerprint: descriptor.sourceFingerprint,
            sendSizeBytes: descriptor.sendSizeBytes,
            requiresConversion: descriptor.requiresConversion,
            hasStaleTargetConversion: descriptor.hasStaleTargetConversion,
            coverVersion: descriptor.coverVersion,
            hasCover: descriptor.hasCover,
            blockReason: blockReason
        )
    }

    private static func assetOptions(for book: Book) -> [AssetOption] {
        if book.assets.isEmpty {
            return [fallbackOption(for: book)]
        }
        return book.assets.map {
            AssetOption(
                fileName: $0.fileName,
                format: $0.format,
                validation: $0.validationStatus,
                origin: $0.origin,
                generatedFromContentHash: $0.generatedFromContentHash,
                contentHash: $0.contentHash,
                sizeBytes: $0.sizeBytes,
                dateAdded: $0.dateAdded
            )
        }
    }

    private static func fallbackOption(for book: Book) -> AssetOption {
        AssetOption(
            fileName: book.fileName,
            format: book.format,
            validation: nil,
            origin: .original,
            generatedFromContentHash: nil,
            contentHash: nil,
            sizeBytes: book.fileSizeBytes,
            dateAdded: book.dateAdded
        )
    }

    private static func fallbackFingerprint(for book: Book, primary: AssetOption?) -> String {
        let date = primary?.dateAdded ?? book.dateAdded
        let size = primary?.sizeBytes ?? book.fileSizeBytes
        return "fallback:\(book.uuid.uuidString):\(book.fileName):\(size):\(date.timeIntervalSinceReferenceDate)"
    }

    private static func assetPreference(_ format: String) -> Int {
        let preference = EbookConverter.prefersAZW3ForKindle
            ? ["azw3", "mobi", "azw", "pdf", "txt"]
            : ["mobi", "azw", "azw3", "pdf", "txt"]
        guard let index = preference.firstIndex(of: format.lowercased()) else { return 0 }
        return preference.count - index
    }

    private static func assetPrecedes(_ lhs: AssetOption, _ rhs: AssetOption) -> Bool {
        let leftScore = assetPreference(lhs.format)
        let rightScore = assetPreference(rhs.format)
        if leftScore != rightScore { return leftScore > rightScore }
        return lhs.fileName < rhs.fileName
    }
}
