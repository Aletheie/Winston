import Foundation

nonisolated enum ReconciliationBatchAction: Sendable, Equatable {
    case apply
    case dismiss
}

nonisolated struct ReconciliationAssetGenerationToken: Equatable, Sendable {
    let uuid: UUID
    let fileName: String
    let contentHash: String?
    let sizeBytes: Int64
    let dateAdded: Date
    let validationStatusRaw: String?
    let availabilityRaw: String
    let drmProtected: Bool?
}

nonisolated struct ReconciliationBookGenerationToken: Equatable, Sendable {
    let candidate: EditionCandidate
    let fileName: String
    let fileSizeBytes: Int64
    let coverOwner: CoverOwner
    let coverVersion: Int
    let assets: [ReconciliationAssetGenerationToken]
}

nonisolated enum ReconciliationBatchConflictReason: Sendable, Equatable {
    case overlappingProposal
    case missingProposal
    case notApplicable
    case sourceChanged
}

nonisolated struct ReconciliationBatchItem: Identifiable, Sendable, Equatable {
    let pairKey: String
    let proposal: EditionMatchProposal?
    let memberUUIDs: [UUID]
    let sourceGenerations: [UUID: ReconciliationBookGenerationToken]
    let conflict: ReconciliationBatchConflictReason?

    var id: String { pairKey }
}

nonisolated struct ReconciliationBatchPlan: Identifiable, Sendable, Equatable {
    let id: UUID
    let action: ReconciliationBatchAction
    let items: [ReconciliationBatchItem]

    var actionableCount: Int { items.count { $0.conflict == nil } }
    var conflictCount: Int { items.count { $0.conflict != nil } }
}

nonisolated enum ReconciliationBatchPhase: Sendable, Equatable {
    case validating
    case committing
    case cancelling
}

nonisolated struct ReconciliationBatchProgress: Sendable, Equatable {
    let planID: UUID
    let completedCount: Int
    let totalCount: Int
    let currentPairKey: String?
    let phase: ReconciliationBatchPhase

    var fraction: Double {
        guard totalCount > 0 else { return 1 }
        return min(max(Double(completedCount) / Double(totalCount), 0), 1)
    }

    var canCancel: Bool { phase != .committing }
}

nonisolated enum ReconciliationBatchItemOutcome: Sendable, Equatable {
    case applied
    case dismissed
    case stale
    case conflicting(ReconciliationBatchConflictReason)
    case failed
    case pending
}

nonisolated struct ReconciliationBatchResultItem: Identifiable, Sendable, Equatable {
    let pairKey: String
    let memberUUIDs: [UUID]
    let outcome: ReconciliationBatchItemOutcome

    var id: String { pairKey }
}

nonisolated struct ReconciliationBatchResult: Identifiable, Sendable, Equatable {
    let id: UUID
    let planID: UUID
    let action: ReconciliationBatchAction
    let wasCancelled: Bool
    let items: [ReconciliationBatchResultItem]

    var appliedCount: Int { items.count { $0.outcome == .applied } }
    var dismissedCount: Int { items.count { $0.outcome == .dismissed } }
    var staleCount: Int { items.count { $0.outcome == .stale } }
    var conflictCount: Int {
        items.count {
            if case .conflicting = $0.outcome { return true }
            return false
        }
    }
    var failedCount: Int { items.count { $0.outcome == .failed } }
    var pendingCount: Int { items.count { $0.outcome == .pending } }
    var retryablePairKeys: Set<String> {
        Set(items.compactMap { item in
            switch item.outcome {
            case .stale, .failed, .pending: item.pairKey
            case .applied, .dismissed, .conflicting: nil
            }
        })
    }
}
