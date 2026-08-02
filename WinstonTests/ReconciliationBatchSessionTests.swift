import Foundation
import Testing
@testable import Winston

@MainActor
@Suite("Reconciliation batch session", .serialized)
struct ReconciliationBatchSessionTests {
    @Test func `Items execute serially in deterministic plan order`() async {
        let plan = makePlan(count: 3)
        let session = ReconciliationBatchSession(plan: plan)
        var visited: [String] = []
        var progress: [ReconciliationBatchProgress] = []

        let result = await session.execute(onProgress: {
            progress.append($0)
        }) { item in
            visited.append(item.pairKey)
            return .applied
        }

        #expect(visited == plan.items.map(\.pairKey))
        #expect(result.appliedCount == 3)
        #expect(result.pendingCount == 0)
        #expect(progress.map(\.completedCount).starts(with: [0, 1, 2]))
    }

    @Test func `Cancellation is observed between item boundaries`() async {
        let plan = makePlan(count: 3)
        let session = ReconciliationBatchSession(plan: plan)
        var visited: [String] = []

        let result = await session.execute(onProgress: { _ in }) { item in
            visited.append(item.pairKey)
            if visited.count == 1 { await session.cancel() }
            return .applied
        }

        #expect(visited == [plan.items[0].pairKey])
        #expect(result.wasCancelled)
        #expect(result.appliedCount == 1)
        #expect(result.pendingCount == 2)
        #expect(result.retryablePairKeys == Set(plan.items.dropFirst().map(\.pairKey)))
    }

    @Test func `Preflight conflicts are inspectable and never executed`() async {
        let conflict = ReconciliationBatchItem(
            pairKey: "conflict",
            proposal: nil,
            memberUUIDs: [],
            sourceGenerations: [:],
            conflict: .overlappingProposal
        )
        let applicable = item(index: 1)
        let plan = ReconciliationBatchPlan(
            id: UUID(),
            action: .apply,
            items: [conflict, applicable]
        )
        let session = ReconciliationBatchSession(plan: plan)
        var visited: [String] = []

        let result = await session.execute(onProgress: { _ in }) { item in
            visited.append(item.pairKey)
            return .failed
        }

        #expect(visited == [applicable.pairKey])
        #expect(result.conflictCount == 1)
        #expect(result.failedCount == 1)
        #expect(result.retryablePairKeys == [applicable.pairKey])
    }

    private func makePlan(count: Int) -> ReconciliationBatchPlan {
        ReconciliationBatchPlan(
            id: UUID(),
            action: .apply,
            items: (0..<count).map(item(index:))
        )
    }

    private func item(index: Int) -> ReconciliationBatchItem {
        ReconciliationBatchItem(
            pairKey: "pair-\(index)",
            proposal: nil,
            memberUUIDs: [UUID()],
            sourceGenerations: [:],
            conflict: nil
        )
    }
}
