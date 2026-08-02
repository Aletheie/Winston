import Foundation

nonisolated enum BulkOperationPresentationOutcome: Equatable, Sendable {
    case applied
    case unchanged
    case warning(BulkOperationWarningReason)
    case conflict(BulkOperationConflictReason)
    case pending
}

nonisolated struct BulkOperationPresentationItem: Identifiable, Equatable, Sendable {
    let targetID: BulkOperationTargetID
    let title: String
    let outcome: BulkOperationPresentationOutcome
    let detail: String?

    var id: String {
        switch targetID {
        case .catalogBook(let id): "catalog-\(id.uuidString)"
        case .deviceBook(let id): "device-\(id)"
        }
    }
}

nonisolated struct BulkOperationPresentationReport: Identifiable, Equatable, Sendable {
    let id: UUID
    let operation: BulkOperationKind
    let completion: BulkOperationCompletion
    let outcomeKind: BulkOperationOutcomeKind
    let appliedChangeCount: Int
    let conflictCount: Int
    let warningCount: Int
    let pendingCount: Int
    let items: [BulkOperationPresentationItem]
    let durableFailureCode: BulkOperationDurableFailureCode?
    let durableFailureDetail: String?

    var canRetry: Bool { pendingCount > 0 }

    static func make(
        from result: BulkOperationResult,
        targetNames: [BulkOperationTargetID: String]
    ) -> BulkOperationPresentationReport {
        let conflicts = Dictionary(
            result.conflicts.map { ($0.targetID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var warnings: [BulkOperationTargetID: BulkOperationWarning] = [:]
        for warning in result.warnings {
            for targetID in warning.targetIDs where warnings[targetID] == nil {
                warnings[targetID] = warning
            }
        }
        let applied = Set(result.appliedTargetIDs)
        let unchanged = Set(result.unchangedTargetIDs)
        let pending = Set(result.pendingTargetIDs)
        let items = result.plan.requestedTargetIDs.map { targetID in
            let outcome: BulkOperationPresentationOutcome
            let detail: String?
            if let conflict = conflicts[targetID] {
                outcome = .conflict(conflict.reason)
                detail = conflict.detail
            } else if let warning = warnings[targetID] {
                outcome = .warning(warning.reason)
                detail = warning.detail
            } else if applied.contains(targetID) {
                outcome = .applied
                detail = nil
            } else if unchanged.contains(targetID) {
                outcome = .unchanged
                detail = nil
            } else if pending.contains(targetID) {
                outcome = .pending
                detail = nil
            } else {
                outcome = .pending
                detail = nil
            }
            return BulkOperationPresentationItem(
                targetID: targetID,
                title: targetNames[targetID] ?? fallbackName(for: targetID),
                outcome: outcome,
                detail: detail
            )
        }
        return BulkOperationPresentationReport(
            id: result.sessionID,
            operation: result.plan.operation,
            completion: result.completion,
            outcomeKind: result.outcomeKind,
            appliedChangeCount: result.appliedChangeCount,
            conflictCount: result.conflictCount,
            warningCount: result.warnings.count,
            pendingCount: result.pendingTargetIDs.count,
            items: items,
            durableFailureCode: result.durableFailure?.code,
            durableFailureDetail: result.durableFailure?.detail
        )
    }

    private static func fallbackName(for targetID: BulkOperationTargetID) -> String {
        switch targetID {
        case .catalogBook(let id): id.uuidString
        case .deviceBook(let id): id
        }
    }
}

extension BulkOperationResult {
    nonisolated var safeRetryPlan: BulkOperationPlan? {
        let pending = pendingTargetIDs
        guard !pending.isEmpty else { return nil }
        return BulkOperationPlan(
            id: UUID(),
            operation: plan.operation,
            requestedTargetIDs: pending,
            actionableTargetIDs: pending,
            unchangedTargetIDs: [],
            conflicts: [],
            changeCountsByTarget: Dictionary(
                uniqueKeysWithValues: pending.map {
                    ($0, plan.changeCountsByTarget[$0] ?? 1)
                }
            ),
            chunkSize: plan.chunkSize
        )
    }
}
