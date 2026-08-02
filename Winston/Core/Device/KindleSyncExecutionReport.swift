import Foundation

nonisolated enum KindleSyncExecutionOutcome: String, Equatable, Sendable {
    case pending
    case running
    case succeeded
    case failed
    case cancelled
    case deliveryUnknown

    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled, .deliveryUnknown: true
        case .pending, .running: false
        }
    }
}

nonisolated enum KindleSyncRetryEligibility: Equatable, Sendable {
    case safe
    case notNeeded
    case deliveryUnknown
    case durableRecovery
}

nonisolated struct KindleSyncExecutionItem: Identifiable, Equatable, Sendable {
    let id: KindleSyncPlanItem.ID
    let action: KindleSyncAction
    let title: String
    let bookID: UUID?
    let deviceBookID: DeviceBook.ID?
    var outcome: KindleSyncExecutionOutcome
    var progress: Double
    var detail: String?
    var retryEligibility: KindleSyncRetryEligibility

    init(planItem: KindleSyncPlanItem) {
        id = planItem.id
        action = planItem.action
        title = planItem.title
        bookID = planItem.bookID
        deviceBookID = planItem.deviceBookID
        outcome = .pending
        progress = 0
        detail = nil
        retryEligibility = .notNeeded
    }

    var isSafelyRetryable: Bool {
        retryEligibility == .safe
            && (outcome == .failed || outcome == .cancelled)
    }
}

nonisolated struct KindleTransferExecutionSnapshot: Equatable, Sendable {
    let bookID: UUID
    let outcome: KindleSyncExecutionOutcome
    let progress: Double
    let detail: String?
    let retryEligibility: KindleSyncRetryEligibility
}

nonisolated struct KindleSyncExecutionProgress: Equatable, Sendable {
    let completedCount: Int
    let totalCount: Int
    let fractionCompleted: Double
    let currentTitle: String?
    let currentAction: KindleSyncAction?
    let isCancelling: Bool
}

nonisolated struct KindleSyncExecutionState: Equatable, Sendable {
    let id: UUID
    let deviceIdentifier: String
    let deviceName: String
    let connectionKind: DeviceConnectionKind
    private(set) var items: [KindleSyncExecutionItem]
    private(set) var isCancelling = false

    init(
        selectedItems: [KindleSyncPlanItem],
        deviceInfo: DeviceInfo,
        id: UUID = UUID()
    ) {
        self.id = id
        deviceIdentifier = deviceInfo.identifier
        deviceName = deviceInfo.name
        connectionKind = deviceInfo.kind
        items = selectedItems.map(KindleSyncExecutionItem.init)
    }

    var progress: KindleSyncExecutionProgress {
        let total = items.count
        let completed = items.count(where: { $0.outcome.isTerminal })
        let aggregate = items.reduce(0.0) { partial, item in
            partial + min(1, max(0, item.progress))
        }
        let current = items.first(where: { $0.outcome == .running })
            ?? items.first(where: { $0.outcome == .pending })
        return KindleSyncExecutionProgress(
            completedCount: completed,
            totalCount: total,
            fractionCompleted: total == 0 ? 0 : aggregate / Double(total),
            currentTitle: current?.title,
            currentAction: current?.action,
            isCancelling: isCancelling
        )
    }

    mutating func markRunning(_ id: KindleSyncPlanItem.ID) {
        update(id) { item in
            guard !item.outcome.isTerminal else { return }
            item.outcome = .running
            item.retryEligibility = .notNeeded
        }
    }

    mutating func markSucceeded(_ id: KindleSyncPlanItem.ID) {
        finish(
            id,
            outcome: .succeeded,
            detail: nil,
            retryEligibility: .notNeeded
        )
    }

    mutating func markFailed(
        _ id: KindleSyncPlanItem.ID,
        detail: String?,
        retryEligibility: KindleSyncRetryEligibility = .safe
    ) {
        finish(
            id,
            outcome: .failed,
            detail: detail,
            retryEligibility: retryEligibility
        )
    }

    mutating func requestCancellation() {
        isCancelling = true
    }

    mutating func mergeTransferSnapshots(
        _ snapshots: [UUID: KindleTransferExecutionSnapshot]
    ) {
        for index in items.indices {
            guard let bookID = items[index].bookID,
                  let snapshot = snapshots[bookID],
                  items[index].action == .add || items[index].action == .update
            else { continue }
            items[index].outcome = snapshot.outcome
            items[index].progress = snapshot.outcome.isTerminal
                ? 1
                : min(1, max(0, snapshot.progress))
            items[index].detail = snapshot.detail
            items[index].retryEligibility = snapshot.retryEligibility
        }
    }

    mutating func cancelUnfinished() {
        for index in items.indices where !items[index].outcome.isTerminal {
            items[index].outcome = .cancelled
            items[index].progress = 1
            items[index].retryEligibility = .safe
        }
        isCancelling = false
    }

    mutating func finishUnresolvedAsFailures(detail: String?) {
        for index in items.indices where !items[index].outcome.isTerminal {
            items[index].outcome = .failed
            items[index].progress = 1
            items[index].detail = detail
            items[index].retryEligibility = .safe
        }
        isCancelling = false
    }

    func mergingTransferSnapshots(
        _ snapshots: [UUID: KindleTransferExecutionSnapshot]
    ) -> KindleSyncExecutionState {
        var copy = self
        copy.mergeTransferSnapshots(snapshots)
        return copy
    }

    func makeReport(
        completedAt: Date = .now
    ) -> KindleSyncExecutionReport {
        KindleSyncExecutionReport(
            id: id,
            deviceIdentifier: deviceIdentifier,
            deviceName: deviceName,
            connectionKind: connectionKind,
            items: items,
            completedAt: completedAt
        )
    }

    private mutating func finish(
        _ id: KindleSyncPlanItem.ID,
        outcome: KindleSyncExecutionOutcome,
        detail: String?,
        retryEligibility: KindleSyncRetryEligibility
    ) {
        update(id) { item in
            item.outcome = outcome
            item.progress = 1
            item.detail = detail
            item.retryEligibility = retryEligibility
        }
    }

    private mutating func update(
        _ id: KindleSyncPlanItem.ID,
        mutation: (inout KindleSyncExecutionItem) -> Void
    ) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        mutation(&items[index])
    }
}

nonisolated struct KindleSyncExecutionReport: Identifiable, Equatable, Sendable {
    let id: UUID
    let deviceIdentifier: String
    let deviceName: String
    let connectionKind: DeviceConnectionKind
    let items: [KindleSyncExecutionItem]
    let completedAt: Date

    var succeededCount: Int { count(.succeeded) }
    var failedCount: Int { count(.failed) }
    var cancelledCount: Int { count(.cancelled) }
    var deliveryUnknownCount: Int { count(.deliveryUnknown) }
    var totalCount: Int { items.count }

    var safeRetryPlanItemIDs: Set<KindleSyncPlanItem.ID> {
        Set(items.lazy.filter(\.isSafelyRetryable).map(\.id))
    }

    var canRetry: Bool { !safeRetryPlanItemIDs.isEmpty }

    var successfulDeviceMutationCount: Int {
        items.count {
            $0.outcome == .succeeded
                && ($0.action == .add
                    || $0.action == .update
                    || $0.action == .repairCover
                    || $0.action == .remove)
        }
    }

    var needsMassStorageEjectGuidance: Bool {
        connectionKind == .massStorage && successfulDeviceMutationCount > 0
    }

    private func count(_ outcome: KindleSyncExecutionOutcome) -> Int {
        items.count { $0.outcome == outcome }
    }
}
