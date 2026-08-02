import Foundation
import Testing
@testable import Winston

private actor ReconciliationControllerGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspendCancellably() async throws {
        markEntered()
        try await Task.sleep(for: .seconds(30))
    }

    func suspendUntilReleased() async {
        markEntered()
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func markEntered() {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

@MainActor
@Suite("Reconciliation apply controller", .serialized)
struct ReconciliationApplyControllerTests {
    @Test func `Validation can be cancelled without entering commit`() async {
        let gate = ReconciliationControllerGate()
        let controller = ReconciliationApplyController()

        controller.start {
            do {
                try await gate.suspendCancellably()
                return .applied
            } catch {
                return .cancelled
            }
        }
        await gate.waitUntilEntered()

        #expect(controller.phase == .validating)
        #expect(controller.canCancel)
        #expect(controller.blocksDismissal)
        controller.cancel()
        #expect(controller.phase == .cancelling)
        #expect(controller.blocksDismissal)

        #expect(await eventually { controller.phase == .cancelled })
        #expect(!controller.blocksDismissal)
        #expect(controller.canApply)
    }

    @Test func `Commit cannot be cancelled or dismissed`() async {
        let gate = ReconciliationControllerGate()
        let controller = ReconciliationApplyController()

        controller.start {
            controller.report(.committing)
            await gate.suspendUntilReleased()
            return .applied
        }
        await gate.waitUntilEntered()

        #expect(controller.phase == .committing)
        #expect(!controller.canCancel)
        #expect(controller.blocksDismissal)
        controller.cancel()
        #expect(controller.phase == .committing)

        await gate.release()
        #expect(await eventually { controller.phase == .completed })
        #expect(!controller.blocksDismissal)
    }

    @Test func `Stale failure remains visible and can be retried`() async {
        let controller = ReconciliationApplyController()

        controller.start { .stale }

        #expect(await eventually { controller.phase == .failed(.stale) })
        #expect(controller.canApply)
        #expect(!controller.blocksDismissal)
    }

    private func eventually(
        _ predicate: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<100 {
            if predicate() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}
