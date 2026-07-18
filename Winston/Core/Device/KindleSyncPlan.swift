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
    let sendSizeBytes: UInt64
    let requiresConversion: Bool
    let hasStaleTargetConversion: Bool
    let coverVersion: Int
    let hasCover: Bool
    let blockReason: KindleSyncReason?
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
        let receipts = Dictionary(
            profile.receipts.map { ($0.bookID, $0) },
            uniquingKeysWith: { lhs, rhs in lhs.syncedAt >= rhs.syncedAt ? lhs : rhs }
        )
        let deviceByKey = Dictionary(grouping: deviceBooks, by: \.matchKey)
        let candidateGroups = Dictionary(grouping: candidates, by: \.matchKey)
        let candidateKeys = Set(candidateGroups.keys)
        let collidingKeys = Set(candidateGroups.compactMap { entry in
            entry.value.count > 1 ? entry.key : nil
        })
        var consumedDeviceIDs: Set<DeviceBook.ID> = []
        var items: [KindleSyncPlanItem] = []

        for candidate in candidates.sorted(by: candidatePrecedes) {
            let matches = (deviceByKey[candidate.matchKey] ?? [])
                .filter { !consumedDeviceIDs.contains($0.id) }
            if collidingKeys.contains(candidate.matchKey) {
                items.append(collisionItem(for: candidate, deviceBook: matches.first))
                consumedDeviceIDs.formUnion(matches.map(\.id))
                continue
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

            if decision.action == .update {
                consumedDeviceIDs.formUnion(matches.map(\.id))
            } else {
                consumedDeviceIDs.insert(preferred.id)
            }
        }

        for deviceBook in deviceBooks where !consumedDeviceIDs.contains(deviceBook.id) {
            let hasLibraryPeer = candidateKeys.contains(deviceBook.matchKey)
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

    private static func collisionItem(
        for candidate: KindleSyncCandidate,
        deviceBook: DeviceBook?
    ) -> KindleSyncPlanItem {
        KindleSyncPlanItem(
            id: "blocked-collision|\(candidate.id.uuidString)",
            action: .blocked,
            reason: .fileNameCollision,
            bookID: candidate.id,
            deviceBookID: deviceBook?.id,
            deviceFileName: deviceBook?.fileName,
            title: candidate.title,
            author: candidate.author,
            sourceFormat: candidate.sourceFormat,
            targetFormat: candidate.targetFormat,
            selectedByDefault: false
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
            if receipt.sourceFingerprint != candidate.sourceFingerprint {
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
