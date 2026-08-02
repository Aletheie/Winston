import Observation

typealias ReconciliationApprovalOperation = @MainActor @Sendable (
) async -> ReconciliationApprovalOutcome

@MainActor
@Observable
final class ReconciliationApplyController {
    enum Phase: Equatable {
        case reviewing
        case validating
        case cancelling
        case committing
        case completed
        case cancelled
        case failed(ReconciliationApprovalOutcome)
    }

    private(set) var phase: Phase = .reviewing
    @ObservationIgnored private var applyTask: Task<Void, Never>?

    var isRunning: Bool {
        switch phase {
        case .validating, .cancelling, .committing:
            true
        case .reviewing, .completed, .cancelled, .failed:
            false
        }
    }

    var canCancel: Bool { phase == .validating }
    var blocksDismissal: Bool { isRunning }

    var canApply: Bool {
        switch phase {
        case .reviewing, .cancelled, .failed:
            true
        case .validating, .cancelling, .committing, .completed:
            false
        }
    }

    func start(operation: @escaping ReconciliationApprovalOperation) {
        guard canApply, applyTask == nil else { return }
        phase = .validating
        applyTask = Task { @MainActor [weak self] in
            let outcome = await operation()
            self?.finish(with: outcome)
        }
    }

    func start(
        proposal: EditionMatchProposal,
        service: CatalogReconciliationService
    ) {
        start { [weak self] in
            await service.approveResult(proposal) { [weak self] approvalPhase in
                self?.report(approvalPhase)
            }
        }
    }

    func report(_ approvalPhase: ReconciliationApprovalPhase) {
        receive(approvalPhase)
    }

    func cancel() {
        guard canCancel else { return }
        phase = .cancelling
        applyTask?.cancel()
    }

    func cancelIfPossible() {
        guard phase == .validating || phase == .cancelling else { return }
        applyTask?.cancel()
    }

    private func receive(_ approvalPhase: ReconciliationApprovalPhase) {
        switch approvalPhase {
        case .validating:
            guard phase != .cancelling else { return }
            phase = .validating
        case .committing:
            phase = .committing
        }
    }

    private func finish(with outcome: ReconciliationApprovalOutcome) {
        applyTask = nil
        switch outcome {
        case .applied:
            phase = .completed
        case .cancelled:
            phase = .cancelled
        case .stale, .notApplicable, .failed:
            phase = .failed(outcome)
        }
    }
}
