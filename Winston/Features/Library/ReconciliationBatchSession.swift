import Foundation
import Observation

actor ReconciliationBatchSession {
    let plan: ReconciliationBatchPlan
    private var cancellationRequested = false
    private var storedResult: ReconciliationBatchResult?
    private var isExecuting = false

    init(plan: ReconciliationBatchPlan) {
        self.plan = plan
    }

    func cancel() {
        cancellationRequested = true
    }

    func execute(
        onProgress: @MainActor @Sendable (ReconciliationBatchProgress) -> Void,
        applying applyItem: @escaping @MainActor @Sendable (
            ReconciliationBatchItem
        ) async -> ReconciliationBatchItemOutcome
    ) async -> ReconciliationBatchResult {
        if let storedResult { return storedResult }
        guard !isExecuting else {
            return ReconciliationBatchResult(
                id: UUID(),
                planID: plan.id,
                action: plan.action,
                wasCancelled: false,
                items: plan.items.map {
                    ReconciliationBatchResultItem(
                        pairKey: $0.pairKey,
                        memberUUIDs: $0.memberUUIDs,
                        outcome: .failed
                    )
                }
            )
        }
        isExecuting = true
        defer { isExecuting = false }

        var outcomes: [String: ReconciliationBatchItemOutcome] = [:]
        var completedCount = 0
        for item in plan.items {
            if let conflict = item.conflict {
                outcomes[item.pairKey] = .conflicting(conflict)
                completedCount += 1
                continue
            }
            if cancellationRequested || Task.isCancelled { break }

            await onProgress(ReconciliationBatchProgress(
                planID: plan.id,
                completedCount: completedCount,
                totalCount: plan.items.count,
                currentPairKey: item.pairKey,
                phase: .validating
            ))
            let outcome = await applyItem(item)
            if outcome == .pending {
                break
            }
            outcomes[item.pairKey] = outcome
            completedCount += 1

            if cancellationRequested || Task.isCancelled { break }
        }

        let wasCancelled = cancellationRequested || Task.isCancelled
        let result = ReconciliationBatchResult(
            id: UUID(),
            planID: plan.id,
            action: plan.action,
            wasCancelled: wasCancelled,
            items: plan.items.map { item in
                ReconciliationBatchResultItem(
                    pairKey: item.pairKey,
                    memberUUIDs: item.memberUUIDs,
                    outcome: outcomes[item.pairKey] ?? .pending
                )
            }
        )
        storedResult = result
        await onProgress(ReconciliationBatchProgress(
            planID: plan.id,
            completedCount: completedCount,
            totalCount: plan.items.count,
            currentPairKey: nil,
            phase: wasCancelled ? .cancelling : .validating
        ))
        return result
    }
}

@MainActor
@Observable
final class ReconciliationBatchController {
    private(set) var progress: ReconciliationBatchProgress?
    private(set) var result: ReconciliationBatchResult?
    private(set) var isCancelling = false

    @ObservationIgnored private var session: ReconciliationBatchSession?
    @ObservationIgnored private var executionTask: Task<Void, Never>?

    var isRunning: Bool { executionTask != nil }
    var canCancel: Bool {
        isRunning && !isCancelling && progress?.canCancel != false
    }

    func start(
        action: ReconciliationBatchAction,
        pairKeys: Set<String>,
        service: CatalogReconciliationService
    ) {
        guard !pairKeys.isEmpty, executionTask == nil else { return }
        let plan = service.makeBatchPlan(action: action, pairKeys: pairKeys)
        let session = ReconciliationBatchSession(plan: plan)
        self.session = session
        result = nil
        isCancelling = false
        progress = ReconciliationBatchProgress(
            planID: plan.id,
            completedCount: 0,
            totalCount: plan.items.count,
            currentPairKey: plan.items.first?.pairKey,
            phase: .validating
        )
        executionTask = Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            let result = await session.execute(onProgress: { [weak self] update in
                guard let self else { return }
                self.progress = self.isCancelling
                    ? ReconciliationBatchProgress(
                        planID: update.planID,
                        completedCount: update.completedCount,
                        totalCount: update.totalCount,
                        currentPairKey: update.currentPairKey,
                        phase: update.phase == .committing ? .committing : .cancelling
                    )
                    : update
            }) { [weak self] item in
                await service.performBatchItem(item, action: plan.action) { [weak self] phase in
                    self?.receive(phase, for: item)
                }
            }
            guard self.session === session else { return }
            self.session = nil
            self.executionTask = nil
            self.progress = nil
            self.isCancelling = false
            self.result = result
        }
    }

    func cancel() {
        guard canCancel, let session else { return }
        isCancelling = true
        if let progress {
            self.progress = ReconciliationBatchProgress(
                planID: progress.planID,
                completedCount: progress.completedCount,
                totalCount: progress.totalCount,
                currentPairKey: progress.currentPairKey,
                phase: .cancelling
            )
        }
        Task { await session.cancel() }
    }

    func clearResult() {
        result = nil
    }

    private func receive(
        _ phase: ReconciliationApprovalPhase,
        for item: ReconciliationBatchItem
    ) {
        guard let progress else { return }
        let batchPhase: ReconciliationBatchPhase = switch phase {
        case .validating: isCancelling ? .cancelling : .validating
        case .committing: .committing
        }
        self.progress = ReconciliationBatchProgress(
            planID: progress.planID,
            completedCount: progress.completedCount,
            totalCount: progress.totalCount,
            currentPairKey: item.pairKey,
            phase: batchPhase
        )
    }
}
