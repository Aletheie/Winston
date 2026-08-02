import Foundation

nonisolated enum OperationReportSource: String, CaseIterable, Sendable, Equatable {
    case reconciliation
    case importReview
    case bulkLibrary
    case kindleSync
    case conversion
    case libraryHealth
    case importRecovery
    case transferRecovery
}

nonisolated enum OperationReportStatus: String, CaseIterable, Sendable, Equatable {
    case review
    case running
    case failed
    case completed
}

nonisolated enum OperationReportPersistence: Sendable, Equatable {
    case sessionOnly
    case durableRecovery
}

nonisolated enum OperationReportAction: String, CaseIterable, Sendable, Equatable, Hashable {
    case open
    case retry
    case dismiss
}

nonisolated enum OperationReportRoute: Sendable, Equatable {
    case editionReview
    case importReview
    case importRecovery
    case bulkResult
    case kindle
    case libraryIntegrity
}

nonisolated enum OperationReportItemOutcome: Sendable, Equatable {
    case succeeded
    case warning
    case failed
    case pending
    case skipped
    case deliveryUnknown
}

nonisolated enum OperationReportRetryEligibility: Sendable, Equatable {
    case safe
    case notEligible
    case requiresDurableRecovery
}

nonisolated struct OperationReportItem: Identifiable, Sendable, Equatable {
    let id: String
    let targetID: String?
    let title: String
    let outcome: OperationReportItemOutcome
    let detail: String?
    let retryEligibility: OperationReportRetryEligibility
}

nonisolated struct OperationReportCounts: Sendable, Equatable {
    let total: Int
    let completed: Int
    let failed: Int
    let pending: Int
    let warnings: Int
}

nonisolated struct OperationReport: Identifiable, Sendable, Equatable {
    let id: UUID
    let operationID: String
    let source: OperationReportSource
    let status: OperationReportStatus
    let persistence: OperationReportPersistence
    let startedAt: Date
    let updatedAt: Date
    let counts: OperationReportCounts
    let items: [OperationReportItem]
    let detail: String?
    let actions: Set<OperationReportAction>
    let route: OperationReportRoute?

    var safeRetryTargetIDs: Set<String> {
        Set(items.lazy.compactMap { item in
            item.retryEligibility == .safe ? item.targetID : nil
        })
    }

    var canRetry: Bool {
        actions.contains(.retry) && !safeRetryTargetIDs.isEmpty
    }

    func pruningStaleTargets(_ validTargetIDs: Set<String>) -> OperationReport {
        var hasSafeRetry = false
        let reconciledItems = items.map { item in
            guard let targetID = item.targetID,
                  item.retryEligibility == .safe,
                  !validTargetIDs.contains(targetID) else {
                if item.retryEligibility == .safe { hasSafeRetry = true }
                return item
            }
            return OperationReportItem(
                id: item.id,
                targetID: targetID,
                title: item.title,
                outcome: .skipped,
                detail: item.detail,
                retryEligibility: .notEligible
            )
        }
        var reconciledActions = actions
        if !hasSafeRetry { reconciledActions.remove(.retry) }
        return OperationReport(
            id: id,
            operationID: operationID,
            source: source,
            status: status,
            persistence: persistence,
            startedAt: startedAt,
            updatedAt: updatedAt,
            counts: counts,
            items: reconciledItems,
            detail: detail,
            actions: reconciledActions,
            route: route
        )
    }
}

extension OperationReport {
    static func runningBulk(
        _ progress: BulkOperationProgress,
        now: Date = .now
    ) -> OperationReport {
        OperationReport(
            id: progress.sessionID,
            operationID: progress.sessionID.uuidString,
            source: .bulkLibrary,
            status: .running,
            persistence: .sessionOnly,
            startedAt: now,
            updatedAt: now,
            counts: OperationReportCounts(
                total: progress.totalTargetCount,
                completed: progress.completedTargetCount,
                failed: 0,
                pending: max(0, progress.totalTargetCount - progress.completedTargetCount),
                warnings: 0
            ),
            items: [],
            detail: nil,
            actions: [],
            route: nil
        )
    }

    static func runningConversion(
        id: UUID,
        count: Int,
        now: Date = .now
    ) -> OperationReport {
        OperationReport(
            id: id,
            operationID: id.uuidString,
            source: .conversion,
            status: .running,
            persistence: .sessionOnly,
            startedAt: now,
            updatedAt: now,
            counts: OperationReportCounts(
                total: count,
                completed: 0,
                failed: 0,
                pending: count,
                warnings: 0
            ),
            items: [],
            detail: nil,
            actions: [],
            route: nil
        )
    }

    static func bulk(
        _ report: BulkOperationPresentationReport,
        now: Date = .now
    ) -> OperationReport {
        let items = report.items.map { item in
            let targetID = item.targetID.operationReportID
            let outcome: OperationReportItemOutcome
            let retry: OperationReportRetryEligibility
            switch item.outcome {
            case .applied, .unchanged:
                outcome = .succeeded
                retry = .notEligible
            case .warning:
                outcome = .warning
                retry = .notEligible
            case .conflict:
                outcome = .failed
                retry = .notEligible
            case .pending:
                outcome = .pending
                retry = .safe
            }
            return OperationReportItem(
                id: item.id,
                targetID: targetID,
                title: item.title,
                outcome: outcome,
                detail: item.detail,
                retryEligibility: retry
            )
        }
        let status: OperationReportStatus = report.pendingCount > 0
            || report.conflictCount > 0
            || report.durableFailureCode != nil
            ? .failed
            : .completed
        var actions: Set<OperationReportAction> = [.dismiss]
        if items.contains(where: { $0.retryEligibility == .safe }) {
            actions.insert(.retry)
        }
        return OperationReport(
            id: report.id,
            operationID: report.id.uuidString,
            source: .bulkLibrary,
            status: status,
            persistence: .sessionOnly,
            startedAt: now,
            updatedAt: now,
            counts: OperationReportCounts(
                total: items.count,
                completed: report.appliedChangeCount,
                failed: report.conflictCount,
                pending: report.pendingCount,
                warnings: report.warningCount
            ),
            items: items,
            detail: report.durableFailureDetail,
            actions: actions,
            route: .bulkResult
        )
    }

    static func kindle(
        _ report: KindleSyncExecutionReport
    ) -> OperationReport {
        let items = report.items.map { item in
            let outcome: OperationReportItemOutcome = switch item.outcome {
            case .succeeded: .succeeded
            case .failed: .failed
            case .pending, .running, .cancelled: .pending
            case .deliveryUnknown: .deliveryUnknown
            }
            return OperationReportItem(
                id: item.id,
                targetID: item.bookID.map { "book:\($0.uuidString)" }
                    ?? item.deviceBookID.map { "device:\($0)" },
                title: item.title,
                outcome: outcome,
                detail: item.detail,
                retryEligibility: item.isSafelyRetryable ? .safe
                    : (item.retryEligibility == .durableRecovery
                        || item.retryEligibility == .deliveryUnknown
                        ? .requiresDurableRecovery
                        : .notEligible)
            )
        }
        let status: OperationReportStatus = report.deliveryUnknownCount > 0
            ? .review
            : (report.failedCount > 0 || report.cancelledCount > 0 ? .failed : .completed)
        return OperationReport(
            id: report.id,
            operationID: report.id.uuidString,
            source: .kindleSync,
            status: status,
            persistence: .sessionOnly,
            startedAt: report.completedAt,
            updatedAt: report.completedAt,
            counts: OperationReportCounts(
                total: report.totalCount,
                completed: report.succeededCount,
                failed: report.failedCount + report.deliveryUnknownCount,
                pending: report.cancelledCount,
                warnings: report.deliveryUnknownCount
            ),
            items: items,
            detail: nil,
            actions: [.open, .dismiss],
            route: .kindle
        )
    }

    static func reconciliation(
        _ result: ReconciliationBatchResult,
        titlesByBookID: [UUID: String],
        now: Date = .now
    ) -> OperationReport {
        let items = result.items.map { item in
            let outcome: OperationReportItemOutcome
            let retry: OperationReportRetryEligibility
            switch item.outcome {
            case .applied, .dismissed:
                outcome = .succeeded
                retry = .notEligible
            case .stale, .failed, .pending:
                outcome = item.outcome == .pending ? .pending : .failed
                retry = .safe
            case .conflicting:
                outcome = .skipped
                retry = .notEligible
            }
            let title = item.memberUUIDs.compactMap { titlesByBookID[$0] }
                .joined(separator: " ↔ ")
            return OperationReportItem(
                id: item.pairKey,
                targetID: item.pairKey,
                title: title.isEmpty ? item.pairKey : title,
                outcome: outcome,
                detail: nil,
                retryEligibility: retry
            )
        }
        return OperationReport(
            id: result.id,
            operationID: result.planID.uuidString,
            source: .reconciliation,
            status: result.failedCount + result.staleCount + result.pendingCount > 0
                ? .failed
                : .completed,
            persistence: .sessionOnly,
            startedAt: now,
            updatedAt: now,
            counts: OperationReportCounts(
                total: items.count,
                completed: result.appliedCount + result.dismissedCount,
                failed: result.failedCount + result.staleCount + result.conflictCount,
                pending: result.pendingCount,
                warnings: result.conflictCount
            ),
            items: items,
            detail: nil,
            actions: [.open, .dismiss],
            route: .editionReview
        )
    }

    static func importBatch(
        _ batch: PreparedImportBatch,
        now: Date = .now
    ) -> OperationReport {
        let items = batch.items.map { item in
            let batchOutcome = batch.itemOutcomes[item.id]
            let outcome: OperationReportItemOutcome = switch batchOutcome {
            case .imported: .succeeded
            case .skipped: .skipped
            case .failed: .failed
            case .cancelled: .pending
            case nil: item.willImport ? .pending : .skipped
            }
            return OperationReportItem(
                id: item.id.uuidString,
                targetID: "import:\(item.id.uuidString)",
                title: item.sourceName,
                outcome: outcome,
                detail: (item.reasons + item.warnings).first,
                retryEligibility: outcome == .failed || outcome == .pending
                    ? .safe
                    : .notEligible
            )
        }
        let status: OperationReportStatus = switch batch.phase {
        case .preparing, .committing: .running
        case .ready: .review
        case .failed: .failed
        case .completed(let summary): summary.hasIssues ? .failed : .completed
        }
        let completed = items.count { $0.outcome == .succeeded || $0.outcome == .skipped }
        let failed = items.count { $0.outcome == .failed }
        let pending = items.count { $0.outcome == .pending }
        var actions: Set<OperationReportAction> = status == .running ? [] : [.open]
        if status == .completed { actions.insert(.dismiss) }
        return OperationReport(
            id: batch.id,
            operationID: batch.sessionID.uuidString,
            source: .importReview,
            status: status,
            persistence: .sessionOnly,
            startedAt: now,
            updatedAt: now,
            counts: OperationReportCounts(
                total: items.count,
                completed: completed,
                failed: failed,
                pending: pending,
                warnings: batch.items.reduce(0) { $0 + $1.warnings.count }
            ),
            items: items,
            detail: batch.phase.failureDetail,
            actions: actions,
            route: .importReview
        )
    }

    static func reviewLink(
        id: UUID,
        source: OperationReportSource,
        count: Int,
        route: OperationReportRoute,
        persistence: OperationReportPersistence = .sessionOnly,
        detail: String? = nil,
        now: Date = .now
    ) -> OperationReport {
        OperationReport(
            id: id,
            operationID: id.uuidString,
            source: source,
            status: .review,
            persistence: persistence,
            startedAt: now,
            updatedAt: now,
            counts: OperationReportCounts(
                total: count,
                completed: 0,
                failed: 0,
                pending: count,
                warnings: count
            ),
            items: [],
            detail: detail,
            actions: [.open],
            route: route
        )
    }
}

private extension BulkOperationTargetID {
    var operationReportID: String {
        switch self {
        case .catalogBook(let id): "book:\(id.uuidString)"
        case .deviceBook(let id): "device:\(id)"
        }
    }
}

private extension ImportReviewPhase {
    var failureDetail: String? {
        if case .failed(let detail) = self { return detail }
        return nil
    }
}
