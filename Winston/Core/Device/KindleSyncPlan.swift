import Foundation

nonisolated enum KindleSyncAction: String, CaseIterable, Sendable {
    case add
    case update
    case repairCover
    case keep
    case remove
    case blocked
}

nonisolated enum KindleSyncReason: String, Sendable {
    case notOnDevice
    case sourceChanged
    case outdatedConversion
    case formatChanged
    case coverChanged
    case upToDate
    case onlyOnDevice
    case duplicateVariant
    case drmProtected
    case fileUnavailable
    case fileNameCollision
}

nonisolated struct KindleSyncCandidate: Equatable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let author: String?
    let matchKey: String
    let sourceFormat: String
    let targetFileName: String
    let targetFormat: String
    let sourceFingerprint: String
    let sourceAssetID: UUID?
    let sourceFingerprintIsAuthoritative: Bool
    let sourceLineageFingerprint: String?
    let sendSizeBytes: UInt64
    let requiresConversion: Bool
    let hasStaleTargetConversion: Bool
    let coverVersion: Int
    let hasCover: Bool
    let blockReason: KindleSyncReason?

    init(
        id: UUID,
        title: String,
        author: String?,
        matchKey: String,
        sourceFormat: String,
        targetFileName: String,
        targetFormat: String,
        sourceFingerprint: String,
        sourceAssetID: UUID? = nil,
        sourceFingerprintIsAuthoritative: Bool = true,
        sourceLineageFingerprint: String?,
        sendSizeBytes: UInt64,
        requiresConversion: Bool,
        hasStaleTargetConversion: Bool,
        coverVersion: Int,
        hasCover: Bool,
        blockReason: KindleSyncReason?
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.matchKey = matchKey
        self.sourceFormat = sourceFormat
        self.targetFileName = targetFileName
        self.targetFormat = targetFormat
        self.sourceFingerprint = sourceFingerprint
        self.sourceAssetID = sourceAssetID
        self.sourceFingerprintIsAuthoritative = sourceFingerprintIsAuthoritative
        self.sourceLineageFingerprint = sourceLineageFingerprint
        self.sendSizeBytes = sendSizeBytes
        self.requiresConversion = requiresConversion
        self.hasStaleTargetConversion = hasStaleTargetConversion
        self.coverVersion = coverVersion
        self.hasCover = hasCover
        self.blockReason = blockReason
    }

    func allocatingDevicePath() -> KindleSyncCandidate {
        let allocated = DevicePathAllocator.allocate(
            proposedFileName: targetFileName,
            ownerID: id
        )
        guard allocated != targetFileName else { return self }
        return KindleSyncCandidate(
            id: id,
            title: title,
            author: author,
            matchKey: matchKey,
            sourceFormat: sourceFormat,
            targetFileName: allocated,
            targetFormat: targetFormat,
            sourceFingerprint: sourceFingerprint,
            sourceAssetID: sourceAssetID,
            sourceFingerprintIsAuthoritative: sourceFingerprintIsAuthoritative,
            sourceLineageFingerprint: sourceLineageFingerprint,
            sendSizeBytes: sendSizeBytes,
            requiresConversion: requiresConversion,
            hasStaleTargetConversion: hasStaleTargetConversion,
            coverVersion: coverVersion,
            hasCover: hasCover,
            blockReason: blockReason
        )
    }
}

nonisolated struct KindleSyncPlanItem: Equatable, Identifiable, Sendable {
    let id: String
    let action: KindleSyncAction
    let reason: KindleSyncReason
    let bookID: UUID?
    let deviceBookID: DeviceBook.ID?
    let deviceFileName: String?
    let title: String
    let author: String?
    let sourceFormat: String?
    let targetFormat: String?
    let selectedByDefault: Bool

    var isSelectable: Bool {
        switch action {
        case .add, .update, .repairCover, .remove: true
        case .keep, .blocked: false
        }
    }

    var isDestructive: Bool { action == .remove }
}

nonisolated struct KindleSyncPlan: Equatable, Sendable {
    let profileID: UUID
    let profileName: String
    let items: [KindleSyncPlanItem]
    private let selectedByDefaultIDs: Set<KindleSyncPlanItem.ID>
    private let actionCounts: [KindleSyncAction: Int]

    init(profileID: UUID, profileName: String, items: [KindleSyncPlanItem]) {
        self.profileID = profileID
        self.profileName = profileName
        self.items = items
        self.selectedByDefaultIDs = Set(items.lazy.filter(\.selectedByDefault).map(\.id))
        self.actionCounts = items.reduce(into: [:]) { counts, item in
            counts[item.action, default: 0] += 1
        }
    }

    var selectedByDefault: Set<KindleSyncPlanItem.ID> {
        selectedByDefaultIDs
    }

    func count(for action: KindleSyncAction) -> Int {
        actionCounts[action, default: 0]
    }
}

nonisolated enum KindleSyncPlanner {
    static func makePlan(
        candidates: [KindleSyncCandidate],
        deviceBooks: [DeviceBook],
        profile: KindleSyncProfile
    ) -> KindleSyncPlan {
        let candidates = candidates.map { $0.allocatingDevicePath() }
        let receipts = Dictionary(
            profile.receipts.map { ($0.bookID, $0) },
            uniquingKeysWith: { lhs, rhs in lhs.syncedAt >= rhs.syncedAt ? lhs : rhs }
        )
        let deviceByKey = Dictionary(grouping: deviceBooks, by: \.matchKey)
        let candidateKeys = Set(candidates.flatMap {
            [
                $0.matchKey,
                DevicePathAllocator.rawMatchKey(for: $0.targetFileName),
            ]
        })
        var consumedDeviceIDs: Set<DeviceBook.ID> = []
        var items: [KindleSyncPlanItem] = []

        for candidate in candidates.sorted(by: candidatePrecedes) {
            let targetMatchKey = DevicePathAllocator.rawMatchKey(
                for: candidate.targetFileName
            )
            var seenMatchIDs: Set<DeviceBook.ID> = []
            let matches = ((deviceByKey[targetMatchKey] ?? [])
                + (deviceByKey[candidate.matchKey] ?? []))
                .filter { book in
                    !consumedDeviceIDs.contains(book.id)
                        && seenMatchIDs.insert(book.id).inserted
                }
            guard !matches.isEmpty else {
                items.append(missingItem(for: candidate))
                continue
            }

            guard let preferred = preferredDeviceBook(
                in: matches,
                targetFileName: candidate.targetFileName
            ) else {
                items.append(missingItem(for: candidate))
                continue
            }
            let receipt = receipts[candidate.id]
            let decision = decision(for: candidate, deviceBook: preferred, receipt: receipt)
            items.append(item(for: candidate, deviceBook: preferred, decision: decision))
            consumedDeviceIDs.insert(preferred.id)
        }

        for deviceBook in deviceBooks where !consumedDeviceIDs.contains(deviceBook.id) {
            let hasLibraryPeer = candidateKeys.contains(deviceBook.matchKey)
                || candidateKeys.contains(deviceBook.legacyMatchKey)
            items.append(KindleSyncPlanItem(
                id: "remove|\(deviceBook.id)",
                action: .remove,
                reason: hasLibraryPeer ? .duplicateVariant : .onlyOnDevice,
                bookID: nil,
                deviceBookID: deviceBook.id,
                deviceFileName: deviceBook.fileName,
                title: deviceBook.displayName,
                author: nil,
                sourceFormat: deviceBook.format,
                targetFormat: nil,
                selectedByDefault: false
            ))
        }

        items.sort(by: itemPrecedes)
        return KindleSyncPlan(profileID: profile.id, profileName: profile.name, items: items)
    }

    private static func missingItem(for candidate: KindleSyncCandidate) -> KindleSyncPlanItem {
        if let blockReason = candidate.blockReason {
            return KindleSyncPlanItem(
                id: "blocked|\(candidate.id.uuidString)",
                action: .blocked,
                reason: blockReason,
                bookID: candidate.id,
                deviceBookID: nil,
                deviceFileName: nil,
                title: candidate.title,
                author: candidate.author,
                sourceFormat: candidate.sourceFormat,
                targetFormat: candidate.targetFormat,
                selectedByDefault: false
            )
        }
        return KindleSyncPlanItem(
            id: "add|\(candidate.id.uuidString)",
            action: .add,
            reason: .notOnDevice,
            bookID: candidate.id,
            deviceBookID: nil,
            deviceFileName: nil,
            title: candidate.title,
            author: candidate.author,
            sourceFormat: candidate.sourceFormat,
            targetFormat: candidate.targetFormat,
            selectedByDefault: true
        )
    }

    private static func decision(
        for candidate: KindleSyncCandidate,
        deviceBook: DeviceBook,
        receipt: KindleSyncReceipt?
    ) -> (action: KindleSyncAction, reason: KindleSyncReason) {
        if let blockReason = candidate.blockReason {
            return (.blocked, blockReason)
        }
        if candidate.hasStaleTargetConversion {
            return (.update, .outdatedConversion)
        }
        if deviceBook.format.caseInsensitiveCompare(candidate.targetFormat) != .orderedSame {
            return (.update, .formatChanged)
        }
        if let receipt {
            let receiptMatchesSource: Bool
            if candidate.sourceFingerprintIsAuthoritative {
                receiptMatchesSource = receipt.sourceFingerprint == candidate.sourceFingerprint
                    || receipt.sourceFingerprint == candidate.sourceLineageFingerprint
            } else {
                // Legacy rows may not have a persisted content hash yet. Avoid
                // opening the source during plan construction: the receipt still
                // belongs to the same immutable asset identity and the transfer
                // path will perform the authoritative byte validation.
                receiptMatchesSource = receipt.assetID == candidate.sourceAssetID
            }
            if !receiptMatchesSource {
                return (.update, .sourceChanged)
            }
            if receipt.sentFileName.caseInsensitiveCompare(deviceBook.fileName) != .orderedSame {
                return (.update, .formatChanged)
            }
            if candidate.hasCover, receipt.coverVersion != candidate.coverVersion {
                return (.repairCover, .coverChanged)
            }
        } else if !candidate.requiresConversion,
                  candidate.sendSizeBytes > 0,
                  deviceBook.sizeBytes > 0,
                  candidate.sendSizeBytes != deviceBook.sizeBytes {
            return (.update, .sourceChanged)
        }
        return (.keep, .upToDate)
    }

    private static func item(
        for candidate: KindleSyncCandidate,
        deviceBook: DeviceBook,
        decision: (action: KindleSyncAction, reason: KindleSyncReason)
    ) -> KindleSyncPlanItem {
        KindleSyncPlanItem(
            id: "\(decision.action.rawValue)|\(candidate.id.uuidString)|\(deviceBook.id)",
            action: decision.action,
            reason: decision.reason,
            bookID: candidate.id,
            deviceBookID: deviceBook.id,
            deviceFileName: deviceBook.fileName,
            title: candidate.title,
            author: candidate.author,
            sourceFormat: candidate.sourceFormat,
            targetFormat: candidate.targetFormat,
            selectedByDefault: decision.action == .add
                || decision.action == .update
                || decision.action == .repairCover
        )
    }

    private static func preferredDeviceBook(
        in books: [DeviceBook],
        targetFileName: String
    ) -> DeviceBook? {
        if let exact = books.first(where: {
            $0.fileName.caseInsensitiveCompare(targetFileName) == .orderedSame
        }) {
            return exact
        }
        let targetFormat = (targetFileName as NSString).pathExtension
        if let matchingFormat = books.first(where: {
            $0.format.caseInsensitiveCompare(targetFormat) == .orderedSame
        }) {
            return matchingFormat
        }
        return books.min {
            $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
        }
    }

    private static func candidatePrecedes(_ lhs: KindleSyncCandidate, _ rhs: KindleSyncCandidate) -> Bool {
        let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func itemPrecedes(_ lhs: KindleSyncPlanItem, _ rhs: KindleSyncPlanItem) -> Bool {
        let leftRank = actionRank(lhs.action)
        let rightRank = actionRank(rhs.action)
        if leftRank != rightRank { return leftRank < rightRank }
        let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
        return lhs.id < rhs.id
    }

    private static func actionRank(_ action: KindleSyncAction) -> Int {
        switch action {
        case .update: 0
        case .add: 1
        case .repairCover: 2
        case .remove: 3
        case .blocked: 4
        case .keep: 5
        }
    }
}
