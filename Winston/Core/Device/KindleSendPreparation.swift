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
    let availability: AssetAvailability
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

    static func allocatePath(
        originalFileName: String,
        targetFormat: String,
        ownerID: UUID
    ) -> DeviceTransferPath {
        allocatedPath(allocate(
            originalFileName: originalFileName,
            targetFormat: targetFormat,
            ownerID: ownerID
        ))
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

    private static func allocatedPath(_ fileName: String) -> DeviceTransferPath {
        guard let path = DeviceTransferPath(fileName: fileName) else {
            preconditionFailure("DevicePathAllocator produced an invalid leaf")
        }
        return path
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

nonisolated struct KindleSendDescriptor: Equatable, Sendable {
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
    let coverOwner: CoverOwner
    let coverVersion: Int
    let hasCover: Bool
    let drmProtected: Bool
    let fileUnavailable: Bool
}

nonisolated struct TransferPlanItem: Sendable, Identifiable {
    let descriptor: KindleSendDescriptor
    let sourceFileGeneration: TransferFileGeneration
    let destination: DeviceTransferPath
    let existingDeviceBookID: DeviceBook.ID?

    var id: UUID { descriptor.bookUUID }
    var displayName: String { descriptor.displayName }
}

nonisolated struct TransferPlan: Sendable {
    let deviceIdentifier: String
    let requestedBookIDs: [UUID]
    let items: [TransferPlanItem]
    let conflicts: [BulkOperationConflict]

    var conflictCount: Int { conflicts.count }
    var affectedTargetCount: Int { items.count }
}

/// Resolves catalog/read-model descriptors against one immutable device inventory.
/// Edition choice and destination allocation are complete when this returns.
nonisolated enum TransferPlanner {
    static func makePlan(
        readModel descriptors: [KindleSendDescriptor],
        inventory: DeviceInventorySnapshot
    ) -> TransferPlan {
        var seenBookIDs: Set<UUID> = []
        let unique = descriptors.filter {
            seenBookIDs.insert($0.bookUUID).inserted
        }
        let destinations = Dictionary(uniqueKeysWithValues: unique.map {
            (
                $0.bookUUID,
                DevicePathAllocator.allocatePath(
                    originalFileName: $0.originalFileName,
                    targetFormat: $0.targetFormat,
                    ownerID: $0.bookUUID
                )
            )
        })
        let destinationGroups = Dictionary(grouping: unique) {
            destinations[$0.bookUUID]?.fileName.lowercased() ?? ""
        }
        let collidingBookIDs = Set(destinationGroups.values.flatMap { group in
            group.count > 1 ? group.map(\.bookUUID) : []
        })
        var items: [TransferPlanItem] = []
        var conflicts: [BulkOperationConflict] = []

        for descriptor in unique {
            let targetID = BulkOperationTargetID.catalogBook(descriptor.bookUUID)
            guard let destination = destinations[descriptor.bookUUID] else {
                conflicts.append(BulkOperationConflict(
                    targetID: targetID,
                    reason: .invalidTarget
                ))
                continue
            }
            if collidingBookIDs.contains(descriptor.bookUUID) {
                conflicts.append(BulkOperationConflict(
                    targetID: targetID,
                    reason: .destinationCollision
                ))
            } else if descriptor.fileUnavailable {
                conflicts.append(BulkOperationConflict(
                    targetID: targetID,
                    reason: .unavailable
                ))
            } else if descriptor.drmProtected {
                conflicts.append(BulkOperationConflict(
                    targetID: targetID,
                    reason: .drmProtected
                ))
            } else if let sourceFileGeneration = TransferFileGeneration.capture(
                at: descriptor.sourceURL
            ) {
                let existing = inventory.books.first {
                    $0.fileName.caseInsensitiveCompare(destination.fileName) == .orderedSame
                }
                items.append(TransferPlanItem(
                    descriptor: descriptor,
                    sourceFileGeneration: sourceFileGeneration,
                    destination: destination,
                    existingDeviceBookID: existing?.id
                ))
            } else {
                conflicts.append(BulkOperationConflict(
                    targetID: targetID,
                    reason: .unavailable
                ))
            }
        }

        return TransferPlan(
            deviceIdentifier: inventory.info.identifier,
            requestedBookIDs: unique.map(\.bookUUID),
            items: items,
            conflicts: conflicts
        )
    }
}

/// Final, read-only payload produced for one concrete catalog asset generation.
/// The transport sees only `byteTransfer`; provenance stays above that boundary.
nonisolated struct TransferArtifact: Sendable {
    let bookID: UUID
    let assetGeneration: KindleTransferAssetGeneration
    let sourceIsPrimary: Bool
    let displayName: String
    let sourceFormat: String
    let sourceFingerprint: String
    let sourceSizeBytes: UInt64
    let fileURL: URL
    let format: String
    let fingerprint: String
    let byteCount: UInt64
    let destination: DeviceTransferPath
    let coverOwner: CoverOwner
    let coverVersion: Int

    var byteTransfer: DeviceByteTransfer {
        DeviceByteTransfer(
            sourceURL: fileURL,
            destination: destination,
            expectedByteCount: byteCount
        )
    }
}

nonisolated enum TransferArtifactError: Error, LocalizedError {
    case sourceUnavailable
    case sourceChanged
    case stagingFailed
    case transportResultMismatch

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable: "The source file is unavailable."
        case .sourceChanged: "The source file changed while waiting to transfer."
        case .stagingFailed: "The source file could not be prepared for transfer."
        case .transportResultMismatch: "The device reported an incomplete transfer."
        }
    }
}

nonisolated enum TransferArtifactBuilder {
    private struct MaterializedFile {
        let url: URL
        let fingerprint: String
        let byteCount: UInt64
    }

    /// Captures and validates the selected asset, performs any required conversion,
    /// and seals the exact bytes that will be handed to transport.
    @concurrent
    static func build(
        _ item: TransferPlanItem,
        in directory: URL
    ) async throws -> TransferArtifact {
        let descriptor = item.descriptor
        guard !descriptor.fileUnavailable,
              let sourceURL = BookFileStore.validatedURL(
                for: descriptor.assetGeneration.fileName
              ),
              TransferFileGeneration.capture(at: sourceURL)
                == item.sourceFileGeneration
        else {
            throw TransferArtifactError.sourceChanged
        }
        let catalogSize = descriptor.assetGeneration.sizeBytes
        guard catalogSize <= 0
                || item.sourceFileGeneration.fileSize == catalogSize else {
            throw TransferArtifactError.sourceChanged
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceExtension = normalizedExtension(descriptor.sourceFormat)
        let immutableSource = directory.appending(
            path: "source-\(descriptor.assetGeneration.assetID.uuidString).\(sourceExtension)"
        )
        let sourceFile = try copyAndHash(
            from: sourceURL,
            to: immutableSource,
            expectedGeneration: item.sourceFileGeneration
        )
        if let expectedFingerprint = descriptor.assetGeneration.contentHash,
           expectedFingerprint.caseInsensitiveCompare(sourceFile.fingerprint) != .orderedSame {
            throw TransferArtifactError.sourceChanged
        }

        let payload: MaterializedFile
        if descriptor.requiresConversion {
            let converted = try await EbookConverter.convertForKindle(sourceFile.url)
            defer { try? FileManager.default.removeItem(at: converted) }
            payload = try copyAndHash(
                from: converted,
                to: directory.appending(
                    path: "payload-\(descriptor.assetGeneration.assetID.uuidString).\(normalizedExtension(descriptor.targetFormat))"
                ),
                expectedGeneration: nil
            )
        } else {
            payload = sourceFile
        }

        return TransferArtifact(
            bookID: descriptor.bookUUID,
            assetGeneration: descriptor.assetGeneration,
            sourceIsPrimary: descriptor.sourceIsPrimary,
            displayName: descriptor.displayName,
            sourceFormat: descriptor.sourceFormat,
            sourceFingerprint: sourceFile.fingerprint,
            sourceSizeBytes: sourceFile.byteCount,
            fileURL: payload.url,
            format: descriptor.targetFormat,
            fingerprint: payload.fingerprint,
            byteCount: payload.byteCount,
            destination: item.destination,
            coverOwner: descriptor.coverOwner,
            coverVersion: descriptor.coverVersion
        )
    }

    private static func copyAndHash(
        from source: URL,
        to destination: URL,
        expectedGeneration: TransferFileGeneration?
    ) throws -> MaterializedFile {
        guard FileManager.default.createFile(
            atPath: destination.path(percentEncoded: false),
            contents: nil
        ) else {
            throw TransferArtifactError.stagingFailed
        }

        do {
            let input = try FileHandle(forReadingFrom: source)
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
            if let expectedGeneration {
                guard TransferFileGeneration.capture(at: source) == expectedGeneration,
                      byteCount == UInt64(max(0, expectedGeneration.fileSize)) else {
                    throw TransferArtifactError.sourceChanged
                }
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o400],
                ofItemAtPath: destination.path(percentEncoded: false)
            )
            let fingerprint = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return MaterializedFile(
                url: destination,
                fingerprint: fingerprint,
                byteCount: byteCount
            )
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func normalizedExtension(_ format: String) -> String {
        ManagedLeafName(rawValue: format.lowercased())?.rawValue ?? "bin"
    }
}

nonisolated struct KindleSendBookSnapshot: Sendable {
    struct Asset: Sendable {
        let id: UUID
        let fileName: String
        let format: String
        let validation: AssetValidation?
        let availability: AssetAvailability
        let drmProtected: Bool?
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
    let coverOwner: CoverOwner
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
            coverOwner: book.coverReference.owner,
            coverVersion: book.coverReference.version,
            drmProtected: book.primaryDRMProtected == true,
            assets: book.assets.map {
                KindleSendBookSnapshot.Asset(
                    id: $0.uuid,
                    fileName: $0.fileName,
                    format: $0.format,
                    validation: $0.validationStatus,
                    availability: $0.availability,
                    drmProtected: $0.drmProtected,
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
            guard option.availability == .available,
                  option.validation != .missing,
                  option.validation != .corrupt,
                  let primarySourceHash else { return false }
            return option.generatedFromContentHash == primarySourceHash
        }
        let staleTarget = !generatedTargets.isEmpty && !hasCurrentTarget
        let catalogSourceURL = BookFileStore.catalogURL(for: chosen.fileName)
        let sourceURL = catalogSourceURL
            ?? AppPaths.booksDirectory.appending(path: ".invalid-managed-reference")
        let selectedAssetWasFound = selectedAssetID == nil || chosen.id == selectedAssetID
        let selectedAssetIsAvailable = chosen.availability == .available
            && chosen.validation != .missing
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
                availability: chosen.availability,
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
            coverOwner: snapshot.coverOwner,
            coverVersion: snapshot.coverVersion,
            hasCover: supportsCoverThumbnail && snapshot.coverVersion > 0,
            drmProtected: chosen.drmProtected ?? snapshot.drmProtected,
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
            coverIdentity: descriptor.coverOwner.generationKey,
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
            availability: .available,
            drmProtected: snapshot.drmProtected,
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
        guard asset.availability == .available,
              asset.validation != .missing,
              asset.validation != .corrupt else { return false }
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
