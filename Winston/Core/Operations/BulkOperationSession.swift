import Foundation

/// Stable identity captured before a bulk operation starts. Catalog UUIDs are
/// Winston's context-independent persistent IDs; device IDs are stable for the
/// lifetime of a mounted device snapshot.
nonisolated enum BulkOperationTargetID: Hashable, Sendable {
    case catalogBook(UUID)
    case deviceBook(String)

    var catalogBookID: UUID? {
        guard case .catalogBook(let id) = self else { return nil }
        return id
    }

    var deviceBookID: String? {
        guard case .deviceBook(let id) = self else { return nil }
        return id
    }
}

nonisolated enum BulkOperationKind: String, Equatable, Sendable {
    case metadataEdit
    case catalogDelete
    case collectionAdd
    case collectionRemove
    case deviceSend
    case deviceDelete
}

nonisolated enum BulkOperationConflictReason: String, Equatable, Sendable {
    case missingTarget
    case invalidTarget
    case unavailable
    case drmProtected
    case destinationCollision
    case sourceChanged
    case itemFailed
}

nonisolated struct BulkOperationConflict: Equatable, Sendable {
    let targetID: BulkOperationTargetID
    let reason: BulkOperationConflictReason
    let detail: String?

    init(
        targetID: BulkOperationTargetID,
        reason: BulkOperationConflictReason,
        detail: String? = nil
    ) {
        self.targetID = targetID
        self.reason = reason
        self.detail = detail
    }
}

nonisolated enum BulkOperationWarningReason: String, Equatable, Sendable {
    case publicationPending
    case postProcessingFailed
}

nonisolated struct BulkOperationWarning: Equatable, Sendable {
    let targetIDs: [BulkOperationTargetID]
    let reason: BulkOperationWarningReason
    let detail: String?

    init(
        targetIDs: [BulkOperationTargetID],
        reason: BulkOperationWarningReason,
        detail: String? = nil
    ) {
        self.targetIDs = targetIDs
        self.reason = reason
        self.detail = detail
    }
}

/// Value-only validation result. These records can be assembled from a read
/// model snapshot and planned away from the main actor.
nonisolated struct BulkOperationCandidate: Equatable, Sendable {
    let targetID: BulkOperationTargetID
    let changeCount: Int
    let conflict: BulkOperationConflict?

    static func change(
        _ targetID: BulkOperationTargetID,
        count: Int = 1
    ) -> BulkOperationCandidate {
        BulkOperationCandidate(
            targetID: targetID,
            changeCount: max(1, count),
            conflict: nil
        )
    }

    static func unchanged(
        _ targetID: BulkOperationTargetID
    ) -> BulkOperationCandidate {
        BulkOperationCandidate(
            targetID: targetID,
            changeCount: 0,
            conflict: nil
        )
    }

    static func conflict(
        _ targetID: BulkOperationTargetID,
        reason: BulkOperationConflictReason,
        detail: String? = nil
    ) -> BulkOperationCandidate {
        BulkOperationCandidate(
            targetID: targetID,
            changeCount: 0,
            conflict: BulkOperationConflict(
                targetID: targetID,
                reason: reason,
                detail: detail
            )
        )
    }
}

nonisolated struct BulkOperationChunk: Equatable, Sendable {
    let index: Int
    let totalCount: Int
    let targetIDs: [BulkOperationTargetID]
}

nonisolated struct BulkOperationPlan: Equatable, Sendable {
    let id: UUID
    let operation: BulkOperationKind
    let requestedTargetIDs: [BulkOperationTargetID]
    let actionableTargetIDs: [BulkOperationTargetID]
    let unchangedTargetIDs: [BulkOperationTargetID]
    let conflicts: [BulkOperationConflict]
    let changeCountsByTarget: [BulkOperationTargetID: Int]
    let chunkSize: Int

    var requestedTargetCount: Int { requestedTargetIDs.count }
    var affectedTargetCount: Int { actionableTargetIDs.count }
    var unchangedTargetCount: Int { unchangedTargetIDs.count }
    var conflictCount: Int { conflicts.count }
    var changeCount: Int { changeCountsByTarget.values.reduce(0, +) }

    var chunks: [BulkOperationChunk] {
        guard !actionableTargetIDs.isEmpty else { return [] }
        let size = max(1, chunkSize)
        let total = (actionableTargetIDs.count + size - 1) / size
        return stride(from: 0, to: actionableTargetIDs.count, by: size)
            .enumerated()
            .map { offset, start in
                let end = min(start + size, actionableTargetIDs.count)
                return BulkOperationChunk(
                    index: offset,
                    totalCount: total,
                    targetIDs: Array(actionableTargetIDs[start ..< end])
                )
            }
    }
}

/// Pure planner actor. It never sees SwiftData models; callers hand it stable
/// IDs and immutable candidate evaluations.
actor BulkOperationPlanner {
    static let shared = BulkOperationPlanner()

    func makePlan(
        operation: BulkOperationKind,
        requestedTargetIDs: [BulkOperationTargetID],
        candidates: [BulkOperationCandidate],
        chunkSize: Int
    ) -> BulkOperationPlan {
        var seen: Set<BulkOperationTargetID> = []
        let requested = requestedTargetIDs.filter { seen.insert($0).inserted }
        let candidatesByID = Dictionary(
            candidates.map { ($0.targetID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var actionable: [BulkOperationTargetID] = []
        var unchanged: [BulkOperationTargetID] = []
        var conflicts: [BulkOperationConflict] = []
        var changeCounts: [BulkOperationTargetID: Int] = [:]

        for targetID in requested {
            guard let candidate = candidatesByID[targetID] else {
                conflicts.append(BulkOperationConflict(
                    targetID: targetID,
                    reason: .missingTarget
                ))
                continue
            }
            if let conflict = candidate.conflict {
                conflicts.append(conflict)
            } else if candidate.changeCount > 0 {
                actionable.append(targetID)
                changeCounts[targetID] = candidate.changeCount
            } else {
                unchanged.append(targetID)
            }
        }

        return BulkOperationPlan(
            id: UUID(),
            operation: operation,
            requestedTargetIDs: requested,
            actionableTargetIDs: actionable,
            unchangedTargetIDs: unchanged,
            conflicts: conflicts,
            changeCountsByTarget: changeCounts,
            chunkSize: max(1, chunkSize)
        )
    }
}

nonisolated struct BulkOperationChunkOutcome: Equatable, Sendable {
    let appliedTargetIDs: Set<BulkOperationTargetID>
    let unchangedTargetIDs: Set<BulkOperationTargetID>
    let conflicts: [BulkOperationConflict]
    let warnings: [BulkOperationWarning]

    init(
        appliedTargetIDs: Set<BulkOperationTargetID> = [],
        unchangedTargetIDs: Set<BulkOperationTargetID> = [],
        conflicts: [BulkOperationConflict] = [],
        warnings: [BulkOperationWarning] = []
    ) {
        self.appliedTargetIDs = appliedTargetIDs
        self.unchangedTargetIDs = unchangedTargetIDs
        self.conflicts = conflicts
        self.warnings = warnings
    }

    static func applied(
        _ targetIDs: [BulkOperationTargetID],
        warnings: [BulkOperationWarning] = []
    ) -> BulkOperationChunkOutcome {
        BulkOperationChunkOutcome(
            appliedTargetIDs: Set(targetIDs),
            warnings: warnings
        )
    }
}

nonisolated enum BulkOperationDurableFailureCode: String, Equatable, Sendable {
    case catalogSave
    case fileTransaction
    case deviceDisconnected
    case operationInProgress
    case executionFailed
}

nonisolated struct BulkOperationDurableError: Error, Equatable, Sendable {
    let code: BulkOperationDurableFailureCode
    let detail: String?

    init(_ code: BulkOperationDurableFailureCode, detail: String? = nil) {
        self.code = code
        self.detail = detail
    }
}

nonisolated struct BulkOperationDurableFailure: Equatable, Sendable {
    let code: BulkOperationDurableFailureCode
    let detail: String?
    let chunkIndex: Int
    let targetIDs: [BulkOperationTargetID]
}

nonisolated enum BulkOperationCompletion: String, Equatable, Sendable {
    case completed
    case cancelled
    case failed
}

nonisolated struct BulkOperationProgress: Equatable, Sendable {
    let sessionID: UUID
    let operation: BulkOperationKind
    let completedTargetCount: Int
    let totalTargetCount: Int

    var fraction: Double {
        guard totalTargetCount > 0 else { return 1 }
        return min(
            max(Double(completedTargetCount) / Double(totalTargetCount), 0),
            1
        )
    }
}

nonisolated enum BulkOperationOutcomeKind: Equatable, Sendable {
    case success
    case partialSuccess
    case cancelled
    case conflict
    case failure
}

nonisolated struct BulkOperationResult: Equatable, Sendable {
    let sessionID: UUID
    let plan: BulkOperationPlan
    let completion: BulkOperationCompletion
    let completedChunkCount: Int
    let appliedTargetIDs: [BulkOperationTargetID]
    let unchangedTargetIDs: [BulkOperationTargetID]
    let conflicts: [BulkOperationConflict]
    let warnings: [BulkOperationWarning]
    let durableFailure: BulkOperationDurableFailure?

    var appliedTargetCount: Int { appliedTargetIDs.count }
    var conflictCount: Int { conflicts.count }
    var appliedChangeCount: Int {
        appliedTargetIDs.reduce(0) {
            $0 + (plan.changeCountsByTarget[$1] ?? 0)
        }
    }

    var pendingTargetIDs: [BulkOperationTargetID] {
        let terminal = Set(appliedTargetIDs)
            .union(unchangedTargetIDs)
            .union(conflicts.map(\.targetID))
        return plan.actionableTargetIDs.filter { !terminal.contains($0) }
    }

    var outcomeKind: BulkOperationOutcomeKind {
        if completion == .cancelled {
            return .cancelled
        }
        if completion == .failed {
            return appliedTargetIDs.isEmpty ? .failure : .partialSuccess
        }
        if !conflicts.isEmpty || !pendingTargetIDs.isEmpty {
            return appliedTargetIDs.isEmpty ? .conflict : .partialSuccess
        }
        return .success
    }
}

/// Executes a prevalidated plan exactly once. Each callback is main-actor
/// isolated so SwiftData chunks stay behind CatalogMutationService, while the
/// session's ordering and cancellation state remain on their own actor.
actor BulkOperationSession {
    let id: UUID
    let plan: BulkOperationPlan

    private var cancellationRequested = false
    private var isExecuting = false
    private var storedResult: BulkOperationResult?
    private var currentProgress: BulkOperationProgress

    init(plan: BulkOperationPlan, id: UUID = UUID()) {
        self.id = id
        self.plan = plan
        currentProgress = BulkOperationProgress(
            sessionID: id,
            operation: plan.operation,
            completedTargetCount: 0,
            totalTargetCount: plan.actionableTargetIDs.count
        )
    }

    func cancel() {
        cancellationRequested = true
    }

    func progress() -> BulkOperationProgress {
        currentProgress
    }

    func execute(
        onProgress: (@MainActor @Sendable (BulkOperationProgress) -> Void)? = nil,
        applying applyChunk: @escaping @MainActor @Sendable (
            BulkOperationChunk
        ) async throws -> BulkOperationChunkOutcome
    ) async -> BulkOperationResult {
        if let storedResult { return storedResult }
        guard !isExecuting else {
            let firstChunk = plan.chunks.first
            return BulkOperationResult(
                sessionID: id,
                plan: plan,
                completion: .failed,
                completedChunkCount: 0,
                appliedTargetIDs: [],
                unchangedTargetIDs: plan.unchangedTargetIDs,
                conflicts: plan.conflicts,
                warnings: [],
                durableFailure: BulkOperationDurableFailure(
                    code: .operationInProgress,
                    detail: nil,
                    chunkIndex: firstChunk?.index ?? 0,
                    targetIDs: firstChunk?.targetIDs ?? []
                )
            )
        }
        isExecuting = true
        defer { isExecuting = false }
        if let onProgress {
            await onProgress(currentProgress)
        }

        var completion: BulkOperationCompletion = .completed
        var completedChunkCount = 0
        var completedTargetCount = 0
        var applied: Set<BulkOperationTargetID> = []
        var unchanged = Set(plan.unchangedTargetIDs)
        var conflicts = plan.conflicts
        var warnings: [BulkOperationWarning] = []
        var durableFailure: BulkOperationDurableFailure?

        for chunk in plan.chunks {
            if cancellationRequested || Task.isCancelled {
                completion = .cancelled
                break
            }

            do {
                let outcome = try await applyChunk(chunk)
                let chunkTargets = Set(chunk.targetIDs)
                let chunkApplied = outcome.appliedTargetIDs.intersection(chunkTargets)
                let chunkUnchanged = outcome.unchangedTargetIDs.intersection(chunkTargets)
                let chunkConflicts = outcome.conflicts.filter {
                    chunkTargets.contains($0.targetID)
                }
                let reported = chunkApplied
                    .union(chunkUnchanged)
                    .union(chunkConflicts.map(\.targetID))

                applied.formUnion(chunkApplied)
                unchanged.formUnion(chunkUnchanged)
                conflicts.append(contentsOf: chunkConflicts)
                warnings.append(contentsOf: outcome.warnings)
                for targetID in chunk.targetIDs where !reported.contains(targetID) {
                    conflicts.append(BulkOperationConflict(
                        targetID: targetID,
                        reason: .itemFailed
                    ))
                }
                completedChunkCount += 1
                completedTargetCount += chunk.targetIDs.count
                currentProgress = BulkOperationProgress(
                    sessionID: id,
                    operation: plan.operation,
                    completedTargetCount: completedTargetCount,
                    totalTargetCount: plan.actionableTargetIDs.count
                )
                if let onProgress {
                    await onProgress(currentProgress)
                }
            } catch is CancellationError {
                completion = .cancelled
                break
            } catch let error as BulkOperationDurableError {
                completion = .failed
                durableFailure = BulkOperationDurableFailure(
                    code: error.code,
                    detail: error.detail,
                    chunkIndex: chunk.index,
                    targetIDs: chunk.targetIDs
                )
                break
            } catch {
                completion = .failed
                durableFailure = BulkOperationDurableFailure(
                    code: .executionFailed,
                    detail: error.localizedDescription,
                    chunkIndex: chunk.index,
                    targetIDs: chunk.targetIDs
                )
                break
            }

            if cancellationRequested || Task.isCancelled {
                completion = .cancelled
                break
            }
        }

        let result = BulkOperationResult(
            sessionID: id,
            plan: plan,
            completion: completion,
            completedChunkCount: completedChunkCount,
            appliedTargetIDs: ordered(applied),
            unchangedTargetIDs: ordered(unchanged),
            conflicts: deduplicated(conflicts),
            warnings: warnings,
            durableFailure: durableFailure
        )
        storedResult = result
        return result
    }

    private func ordered(
        _ targetIDs: Set<BulkOperationTargetID>
    ) -> [BulkOperationTargetID] {
        plan.requestedTargetIDs.filter { targetIDs.contains($0) }
    }

    private func deduplicated(
        _ conflicts: [BulkOperationConflict]
    ) -> [BulkOperationConflict] {
        var seen: Set<ConflictIdentity> = []
        return conflicts.filter {
            seen.insert(ConflictIdentity(targetID: $0.targetID, reason: $0.reason)).inserted
        }
    }

    private struct ConflictIdentity: Hashable {
        let targetID: BulkOperationTargetID
        let reason: BulkOperationConflictReason
    }
}
