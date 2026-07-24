import CryptoKit
import Foundation

nonisolated struct TransferFileGeneration: Equatable, Sendable {
    let resourceIdentifier: String?
    let modificationDate: Date?
    let fileSize: Int64

    static func capture(at url: URL) -> TransferFileGeneration? {
        guard let values = try? url.resourceValues(forKeys: [
            .fileResourceIdentifierKey,
            .contentModificationDateKey,
            .fileSizeKey,
            .isRegularFileKey,
        ]), values.isRegularFile == true else { return nil }
        return TransferFileGeneration(
            resourceIdentifier: values.fileResourceIdentifier.map { String(reflecting: $0) },
            modificationDate: values.contentModificationDate,
            fileSize: Int64(values.fileSize ?? -1)
        )
    }
}

nonisolated struct KindleTransferAssetGeneration: Equatable, Sendable {
    let assetID: UUID
    let fileName: String
    let format: String
    let validationStatus: AssetValidation?
    let origin: AssetOrigin
    let contentHash: String?
    let sizeBytes: Int64
    let dateAdded: Date
    let generatedFromContentHash: String?
    let isCatalogued: Bool
}

nonisolated enum DevicePathAllocator {
    private static let marker = "--winston-"
    private static let maximumUTF8Length = 240
    private static let reservedExtensionUTF8Length = 16
    private static let hexadecimalScalars = CharacterSet(
        charactersIn: "0123456789abcdefABCDEF"
    )

    static func allocate(
        originalFileName: String,
        targetFormat: String,
        ownerID: UUID
    ) -> String {
        let originalBase = ManagedLeafName(rawValue: originalFileName).map {
            ($0.rawValue as NSString).deletingPathExtension
        }
        let baseName = originalBase.flatMap { $0.isEmpty ? nil : $0 } ?? ownerID.uuidString
        return allocate(
            proposedFileName: "\(baseName).\(targetFormat.lowercased())",
            ownerID: ownerID
        )
    }

    static func allocate(proposedFileName: String, ownerID: UUID) -> String {
        let token = stableToken(for: ownerID)
        let proposed = ManagedLeafName(rawValue: proposedFileName)?.rawValue
            ?? "\(ownerID.uuidString).bin"
        let nsName = proposed as NSString
        let fileExtension = normalizedExtension(nsName.pathExtension)
        var baseName = nsName.deletingPathExtension
        let suffix = marker + token
        if baseName.lowercased().hasSuffix(suffix) {
            return limitedFileName(
                baseName: baseName,
                suffix: "",
                fileExtension: fileExtension,
                fallbackToken: token
            )
        }
        if baseName.isEmpty { baseName = ownerID.uuidString }
        return limitedFileName(
            baseName: baseName,
            suffix: suffix,
            fileExtension: fileExtension,
            fallbackToken: token
        )
    }

    static func legacyMatchKey(for deviceFileName: String) -> String {
        let baseName = (deviceFileName as NSString).deletingPathExtension
        guard let markerRange = baseName.range(of: marker, options: [.backwards, .caseInsensitive]) else {
            return baseName.lowercased()
        }
        let token = String(baseName[markerRange.upperBound...])
        guard token.count == 32,
              token.unicodeScalars.allSatisfy(hexadecimalScalars.contains)
        else { return baseName.lowercased() }
        return String(baseName[..<markerRange.lowerBound]).lowercased()
    }

    static func rawMatchKey(for fileName: String) -> String {
        (fileName as NSString).deletingPathExtension.lowercased()
    }

    static func allocatedMatchKey(originalFileName: String, ownerID: UUID) -> String {
        rawMatchKey(for: allocate(
            originalFileName: originalFileName,
            targetFormat: "bin",
            ownerID: ownerID
        ))
    }

    private static func stableToken(for ownerID: UUID) -> String {
        ownerID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func normalizedExtension(_ proposed: String) -> String {
        guard let leaf = ManagedLeafName(rawValue: proposed.lowercased()),
              !leaf.rawValue.isEmpty else { return "bin" }
        var normalized = leaf.rawValue
        while normalized.utf8.count > 16 { normalized.removeLast() }
        return normalized
    }

    private static func limitedFileName(
        baseName: String,
        suffix: String,
        fileExtension: String,
        fallbackToken: String
    ) -> String {
        let fixed = "\(suffix).\(fileExtension)"
        let reservedFixedLength = suffix.utf8.count + 1 + reservedExtensionUTF8Length
        let maximumBaseLength = max(1, maximumUTF8Length - reservedFixedLength)
        var limitedBase = baseName
        while limitedBase.utf8.count > maximumBaseLength {
            limitedBase.removeLast()
        }
        let candidate = "\(limitedBase)\(fixed)"
        return ManagedLeafName(rawValue: candidate)?.rawValue
            ?? "\(fallbackToken).\(fileExtension)"
    }
}

nonisolated struct KindleSendDescriptor: Sendable {
    let bookUUID: UUID
    let assetGeneration: KindleTransferAssetGeneration
    let sourceIsPrimary: Bool
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

nonisolated struct TransferArtifact: Sendable {
    let bookID: UUID
    let assetGeneration: KindleTransferAssetGeneration
    let sourceFileGeneration: TransferFileGeneration
    let sourceIsPrimary: Bool
    let displayName: String
    let sourceURL: URL
    let sourceFormat: String
    let targetFileName: String
    let coverVersion: Int

    init(
        descriptor: KindleSendDescriptor,
        sourceURL: URL,
        sourceFileGeneration: TransferFileGeneration
    ) {
        bookID = descriptor.bookUUID
        assetGeneration = descriptor.assetGeneration
        self.sourceFileGeneration = sourceFileGeneration
        sourceIsPrimary = descriptor.sourceIsPrimary
        displayName = descriptor.displayName
        self.sourceURL = sourceURL
        sourceFormat = descriptor.sourceFormat
        targetFileName = descriptor.targetFileName
        coverVersion = descriptor.coverVersion
    }

    func sourceGenerationIsCurrent() -> Bool {
        TransferFileGeneration.capture(at: sourceURL) == sourceFileGeneration
    }

    func materialize(in directory: URL) async throws -> MaterializedTransferArtifact {
        try await TransferArtifactMaterializer.materialize(self, in: directory)
    }

    /// Performs the only filesystem validation used by send preparation.
    /// Descriptors and sync candidates remain cheap immutable catalog values;
    /// the concrete file generation is captured immediately before staging.
    @concurrent
    static func prepare(
        descriptor: KindleSendDescriptor
    ) async throws -> TransferArtifact {
        guard !descriptor.fileUnavailable,
              let sourceURL = BookFileStore.validatedURL(
                for: descriptor.assetGeneration.fileName
              ),
              let generation = TransferFileGeneration.capture(at: sourceURL)
        else {
            throw TransferArtifactError.sourceUnavailable
        }
        let catalogSize = descriptor.assetGeneration.sizeBytes
        guard catalogSize <= 0 || generation.fileSize == catalogSize else {
            throw TransferArtifactError.sourceChanged
        }
        return TransferArtifact(
            descriptor: descriptor,
            sourceURL: sourceURL,
            sourceFileGeneration: generation
        )
    }
}

nonisolated struct MaterializedTransferArtifact: Sendable {
    let artifact: TransferArtifact
    let sourceURL: URL
    let sourceFingerprint: String
    let sourceSizeBytes: UInt64
}

nonisolated enum TransferArtifactError: Error, LocalizedError {
    case sourceUnavailable
    case sourceChanged
    case stagingFailed

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable: "The source file is unavailable."
        case .sourceChanged: "The source file changed while waiting to transfer."
        case .stagingFailed: "The source file could not be prepared for transfer."
        }
    }
}

nonisolated private enum TransferArtifactMaterializer {
    @concurrent
    static func materialize(
        _ artifact: TransferArtifact,
        in directory: URL
    ) async throws -> MaterializedTransferArtifact {
        guard artifact.sourceGenerationIsCurrent() else {
            throw TransferArtifactError.sourceChanged
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = ManagedLeafName(rawValue: artifact.sourceFormat.lowercased())?.rawValue ?? "bin"
        let destination = directory.appending(
            path: "\(artifact.assetGeneration.assetID.uuidString).\(ext)"
        )
        guard FileManager.default.createFile(
            atPath: destination.path(percentEncoded: false),
            contents: nil
        ) else {
            throw TransferArtifactError.stagingFailed
        }

        do {
            let input = try FileHandle(forReadingFrom: artifact.sourceURL)
            let output = try FileHandle(forWritingTo: destination)
            defer {
                try? input.close()
                try? output.close()
            }
            var hasher = SHA256()
            var byteCount: UInt64 = 0
            while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
                byteCount += UInt64(chunk.count)
                try output.write(contentsOf: chunk)
            }
            try output.synchronize()
            guard artifact.sourceGenerationIsCurrent(),
                  byteCount == UInt64(max(0, artifact.sourceFileGeneration.fileSize))
            else {
                throw TransferArtifactError.sourceChanged
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o400],
                ofItemAtPath: destination.path(percentEncoded: false)
            )
            let fingerprint = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            if let expectedFingerprint = artifact.assetGeneration.contentHash,
               expectedFingerprint.caseInsensitiveCompare(fingerprint) != .orderedSame {
                throw TransferArtifactError.sourceChanged
            }
            return MaterializedTransferArtifact(
                artifact: artifact,
                sourceURL: destination,
                sourceFingerprint: fingerprint,
                sourceSizeBytes: byteCount
            )
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}

nonisolated struct KindleSendBookSnapshot: Sendable {
    struct Asset: Sendable {
        let id: UUID
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
        let primaryAsset = book.primaryAsset
        return KindleSendBookSnapshot(
            uuid: book.uuid,
            displayTitle: book.displayTitle,
            displayAuthor: book.displayAuthor,
            deviceMatchKey: book.deviceMatchKey,
            originalFileName: book.originalFileName,
            primaryFileName: primaryAsset?.fileName ?? book.fileName,
            primaryFormat: primaryAsset?.format ?? book.format,
            primarySizeBytes: primaryAsset?.sizeBytes ?? book.fileSizeBytes,
            dateAdded: book.dateAdded,
            coverVersion: book.coverVersion,
            drmProtected: book.drmProtected == true,
            assets: book.assets.map {
                KindleSendBookSnapshot.Asset(
                    id: $0.uuid,
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

    @MainActor
    static func descriptor(for asset: BookAsset, in book: Book) -> KindleSendDescriptor {
        descriptor(for: snapshot(for: book), selectedAssetID: asset.uuid)
    }

    nonisolated static func descriptor(
        for snapshot: KindleSendBookSnapshot,
        selectedAssetID: UUID? = nil
    ) -> KindleSendDescriptor {
        let options = assetOptions(for: snapshot)
        let primarySourceHash = options.first(where: { $0.fileName == snapshot.primaryFileName })?.contentHash
        let usable = options.filter {
            isUsable(
                $0,
                primaryFileName: snapshot.primaryFileName,
                primarySourceHash: primarySourceHash
            )
        }
        let primary = usable.first(where: { $0.fileName == snapshot.primaryFileName })
        let chosen: KindleSendBookSnapshot.Asset
        if let selectedAssetID,
           let selected = options.first(where: { $0.id == selectedAssetID }) {
            chosen = selected
        } else if let primary, !EbookConverter.needsConversion(format: primary.format) {
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
        let targetFileName = DevicePathAllocator.allocate(
            originalFileName: snapshot.originalFileName,
            targetFormat: targetFormat,
            ownerID: snapshot.uuid
        )
        let sourceFingerprint = chosen.contentHash
            ?? fallbackFingerprint(for: snapshot, asset: chosen)
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
        let catalogSourceURL = BookFileStore.catalogURL(for: chosen.fileName)
        let sourceURL = catalogSourceURL
            ?? AppPaths.booksDirectory.appending(path: ".invalid-managed-reference")
        let selectedAssetWasFound = selectedAssetID == nil || chosen.id == selectedAssetID
        let selectedAssetIsAvailable = chosen.validation != .missing
            && chosen.validation != .corrupt
            && !chosen.fileName.isEmpty
        let chosenAssetIsUsable = selectedAssetID == nil
            ? isUsable(
                chosen,
                primaryFileName: snapshot.primaryFileName,
                primarySourceHash: primarySourceHash
            )
            : selectedAssetIsAvailable
        let unavailable = !selectedAssetWasFound
            || !chosenAssetIsUsable
            || catalogSourceURL == nil
        let supportsCoverThumbnail = ["azw", "azw3", "mobi"].contains(targetFormat)
        let storedSize = UInt64(max(0, chosen.sizeBytes))

        return KindleSendDescriptor(
            bookUUID: snapshot.uuid,
            assetGeneration: KindleTransferAssetGeneration(
                assetID: chosen.id,
                fileName: chosen.fileName,
                format: chosen.format,
                validationStatus: chosen.validation,
                origin: chosen.origin,
                contentHash: chosen.contentHash,
                sizeBytes: chosen.sizeBytes,
                dateAdded: chosen.dateAdded,
                generatedFromContentHash: chosen.generatedFromContentHash,
                isCatalogued: snapshot.assets.contains(where: { $0.id == chosen.id })
            ),
            sourceIsPrimary: chosen.fileName == snapshot.primaryFileName,
            displayName: snapshot.displayTitle,
            sourceURL: sourceURL,
            originalFileName: snapshot.originalFileName,
            sourceFormat: chosen.format,
            targetFileName: targetFileName,
            targetFormat: targetFormat,
            sourceFingerprint: sourceFingerprint,
            sendSizeBytes: requiresConversion ? 0 : storedSize,
            requiresConversion: requiresConversion,
            hasStaleTargetConversion: staleTarget,
            coverVersion: snapshot.coverVersion,
            hasCover: supportsCoverThumbnail && snapshot.coverVersion > 0,
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
            sourceAssetID: descriptor.assetGeneration.assetID,
            sourceFingerprintIsAuthoritative:
                descriptor.assetGeneration.contentHash != nil,
            sourceLineageFingerprint: descriptor.assetGeneration.generatedFromContentHash,
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
            id: snapshot.uuid,
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
        asset: KindleSendBookSnapshot.Asset
    ) -> String {
        "fallback:\(snapshot.uuid.uuidString):\(asset.id.uuidString):\(asset.fileName):\(asset.sizeBytes):\(asset.dateAdded.timeIntervalSinceReferenceDate)"
    }

    nonisolated private static func isUsable(
        _ asset: KindleSendBookSnapshot.Asset,
        primaryFileName: String,
        primarySourceHash: String?
    ) -> Bool {
        guard asset.validation != .missing, asset.validation != .corrupt else { return false }
        guard !asset.fileName.isEmpty else { return false }
        guard asset.fileName != primaryFileName, asset.origin == .generated else { return true }
        guard let primarySourceHash else { return false }
        return asset.generatedFromContentHash == primarySourceHash
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
