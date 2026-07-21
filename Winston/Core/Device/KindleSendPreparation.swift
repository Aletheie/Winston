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

nonisolated struct KindleSendBookSnapshot: Sendable {
    struct Asset: Sendable {
        let fileName: String
        let format: String
        let validation: AssetValidation?
        let origin: AssetOrigin
        let generatedFromContentHash: String?
        let contentHash: String?
        let sizeBytes: Int64
        let dateAdded: Date
    }

    let uuid: UUID
    let displayTitle: String
    let displayAuthor: String?
    let deviceMatchKey: String
    let originalFileName: String
    let primaryFileName: String
    let primaryFormat: String
    let primarySizeBytes: Int64
    let dateAdded: Date
    let coverVersion: Int
    let drmProtected: Bool
    let assets: [Asset]
}

enum KindleSendPreparation {
    @MainActor
    static func snapshot(for book: Book) -> KindleSendBookSnapshot {
        KindleSendBookSnapshot(
            uuid: book.uuid,
            displayTitle: book.displayTitle,
            displayAuthor: book.displayAuthor,
            deviceMatchKey: book.deviceMatchKey,
            originalFileName: book.originalFileName,
            primaryFileName: book.fileName,
            primaryFormat: book.format,
            primarySizeBytes: book.fileSizeBytes,
            dateAdded: book.dateAdded,
            coverVersion: book.coverVersion,
            drmProtected: book.drmProtected == true,
            assets: book.assets.map {
                KindleSendBookSnapshot.Asset(
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
        )
    }

    @MainActor
    static func descriptor(for book: Book) -> KindleSendDescriptor {
        descriptor(for: snapshot(for: book))
    }

    nonisolated static func descriptor(for snapshot: KindleSendBookSnapshot) -> KindleSendDescriptor {
        let options = assetOptions(for: snapshot)
        let primarySourceHash = options.first(where: { $0.fileName == snapshot.primaryFileName })?.contentHash
        let usable = options.filter {
            guard $0.validation != .missing, $0.validation != .corrupt else { return false }
            guard $0.fileName != snapshot.primaryFileName, $0.origin == .generated else { return true }
            guard let primarySourceHash else { return false }
            return $0.generatedFromContentHash == primarySourceHash
        }
        let primary = usable.first(where: { $0.fileName == snapshot.primaryFileName })
        let chosen: KindleSendBookSnapshot.Asset
        if let primary, !EbookConverter.needsConversion(format: primary.format) {
            chosen = primary
        } else if let ready = usable.filter({ !EbookConverter.needsConversion(format: $0.format) })
            .sorted(by: assetPrecedes).first {
            chosen = ready
        } else {
            chosen = primary ?? usable.first ?? options.first ?? fallbackOption(for: snapshot)
        }

        let requiresConversion = EbookConverter.needsConversion(format: chosen.format)
        let targetFormat = requiresConversion
            ? EbookConverter.kindleTarget(forFormat: chosen.format).ext
            : chosen.format.lowercased()
        let originalLeaf = ManagedLeafName(rawValue: snapshot.originalFileName)
        let baseName = originalLeaf.map { ($0.rawValue as NSString).deletingPathExtension }
            ?? snapshot.uuid.uuidString
        let proposedTargetFileName = "\(baseName).\(targetFormat)"
        let targetLeaf = ManagedLeafName(rawValue: proposedTargetFileName)
        let targetFileName = targetLeaf?.rawValue ?? "\(snapshot.uuid.uuidString).\(targetFormat)"
        let primaryOption = options.first(where: { $0.fileName == snapshot.primaryFileName })
        let sourceFingerprint = primarySourceHash ?? fallbackFingerprint(for: snapshot, primary: primaryOption)
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
        let validatedSourceURL = BookFileStore.validatedURL(for: chosen.fileName)
        let sourceURL = validatedSourceURL ?? BookFileStore.url(for: chosen.fileName)
        let unavailable = chosen.validation == .missing
            || chosen.validation == .corrupt
            || validatedSourceURL == nil
            || originalLeaf == nil
            || targetLeaf == nil
            || !FileManager.default.fileExists(atPath: sourceURL.path(percentEncoded: false))
        let supportsCoverThumbnail = ["azw", "azw3", "mobi"].contains(targetFormat)
        let storedSize = UInt64(max(0, chosen.sizeBytes))
        let resolvedSize = storedSize > 0
            ? storedSize
            : UInt64(max(0, BookFileStore.size(of: chosen.fileName)))

        return KindleSendDescriptor(
            bookUUID: snapshot.uuid,
            displayName: snapshot.displayTitle,
            sourceURL: sourceURL,
            originalFileName: snapshot.originalFileName,
            sourceFormat: chosen.format,
            targetFileName: targetFileName,
            targetFormat: targetFormat,
            sourceFingerprint: sourceFingerprint,
            sendSizeBytes: requiresConversion ? 0 : resolvedSize,
            requiresConversion: requiresConversion,
            hasStaleTargetConversion: staleTarget,
            coverVersion: snapshot.coverVersion,
            hasCover: supportsCoverThumbnail && CoverStore.exists(for: snapshot.uuid),
            drmProtected: snapshot.drmProtected,
            fileUnavailable: unavailable
        )
    }

    @MainActor
    static func candidate(for book: Book) -> KindleSyncCandidate {
        candidate(for: snapshot(for: book))
    }

    nonisolated static func candidate(for snapshot: KindleSendBookSnapshot) -> KindleSyncCandidate {
        let descriptor = descriptor(for: snapshot)
        let blockReason: KindleSyncReason?
        if descriptor.drmProtected {
            blockReason = .drmProtected
        } else if descriptor.fileUnavailable {
            blockReason = .fileUnavailable
        } else {
            blockReason = nil
        }
        return KindleSyncCandidate(
            id: snapshot.uuid,
            title: snapshot.displayTitle,
            author: snapshot.displayAuthor,
            matchKey: snapshot.deviceMatchKey,
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

    nonisolated private static func assetOptions(
        for snapshot: KindleSendBookSnapshot
    ) -> [KindleSendBookSnapshot.Asset] {
        if snapshot.assets.isEmpty {
            return [fallbackOption(for: snapshot)]
        }
        return snapshot.assets
    }

    nonisolated private static func fallbackOption(
        for snapshot: KindleSendBookSnapshot
    ) -> KindleSendBookSnapshot.Asset {
        KindleSendBookSnapshot.Asset(
            fileName: snapshot.primaryFileName,
            format: snapshot.primaryFormat,
            validation: nil,
            origin: .original,
            generatedFromContentHash: nil,
            contentHash: nil,
            sizeBytes: snapshot.primarySizeBytes,
            dateAdded: snapshot.dateAdded
        )
    }

    nonisolated private static func fallbackFingerprint(
        for snapshot: KindleSendBookSnapshot,
        primary: KindleSendBookSnapshot.Asset?
    ) -> String {
        let date = primary?.dateAdded ?? snapshot.dateAdded
        let size = primary?.sizeBytes ?? snapshot.primarySizeBytes
        return "fallback:\(snapshot.uuid.uuidString):\(snapshot.primaryFileName):\(size):\(date.timeIntervalSinceReferenceDate)"
    }

    nonisolated private static func assetPreference(_ format: String) -> Int {
        let preference = EbookConverter.prefersAZW3ForKindle
            ? ["azw3", "mobi", "azw", "pdf", "txt"]
            : ["mobi", "azw", "azw3", "pdf", "txt"]
        guard let index = preference.firstIndex(of: format.lowercased()) else { return 0 }
        return preference.count - index
    }

    nonisolated private static func assetPrecedes(
        _ lhs: KindleSendBookSnapshot.Asset,
        _ rhs: KindleSendBookSnapshot.Asset
    ) -> Bool {
        let leftScore = assetPreference(lhs.format)
        let rightScore = assetPreference(rhs.format)
        if leftScore != rightScore { return leftScore > rightScore }
        return lhs.fileName < rhs.fileName
    }
}
