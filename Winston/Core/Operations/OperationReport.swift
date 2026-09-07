import Foundation

nonisolated enum OperationReportSource: String, CaseIterable, Sendable, Equatable {
    case reconciliation
    case bookImport
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
    case importRecovery
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
            route: nil
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

    static func runningImport(
        _ progress: ImportSessionProgress,
        now: Date = .now
    ) -> OperationReport {
        OperationReport(
            id: progress.sessionID,
            operationID: progress.sessionID.uuidString,
            source: .bookImport,
            status: .running,
            persistence: .sessionOnly,
            startedAt: now,
            updatedAt: now,
            counts: OperationReportCounts(
                total: progress.requestedCount,
                completed: progress.completedCount,
                failed: 0,
                pending: max(
                    0,
                    progress.requestedCount - progress.completedCount
                ),
                warnings: 0
            ),
            items: [],
            detail: progress.currentFilename,
            actions: [],
            route: nil
        )
    }

    static func importSummary(
        _ summary: ImportSummary,
        now: Date = .now
    ) -> OperationReport {
        let items = summary.failures.enumerated().map { index, failure in
            OperationReportItem(
                id: failure.requestedBookID?.uuidString
                    ?? "\(summary.sessionID.uuidString)-failure-\(index)",
                targetID: nil,
                title: failure.sourceURL?.lastPathComponent
                    ?? String(localized: "Unknown import source"),
                outcome: .failed,
                detail: failure.detail,
                retryEligibility: .requiresDurableRecovery
            )
        }
        let status: OperationReportStatus = summary.hasIssues
            ? .failed
            : .completed
        return OperationReport(
            id: summary.sessionID,
            operationID: summary.sessionID.uuidString,
            source: .bookImport,
            status: status,
            persistence: .sessionOnly,
            startedAt: now,
            updatedAt: now,
            counts: OperationReportCounts(
                total: summary.requestedCount,
                completed: summary.importedItemCount + summary.skippedCount,
                failed: summary.failedCount + summary.recoveryDeferredCount,
                pending: summary.cancelledCount,
                warnings: summary.skippedCount + summary.recoveryDeferredCount
            ),
            items: items,
            detail: summary.wasCancelled
                ? String(localized: "The import was cancelled before every file finished.")
                : nil,
            actions: [.dismiss],
            route: nil
        )
    }

    static func databaseRecovery(
        id: UUID,
        snapshotURL: URL,
        now: Date = .now
    ) -> OperationReport {
        let snapshotPath = snapshotURL.path(percentEncoded: false)
        return OperationReport(
            id: id,
            operationID: id.uuidString,
            source: .libraryHealth,
            status: .review,
            persistence: .sessionOnly,
            startedAt: now,
            updatedAt: now,
            counts: OperationReportCounts(
                total: 1,
                completed: 1,
                failed: 0,
                pending: 0,
                warnings: 1
            ),
            items: [],
            detail: String(
                localized: "Winston confirmed that the library database was corrupt and preserved a verified recovery snapshot at \(snapshotPath) before creating a fresh database."
            ),
            actions: [.dismiss],
            route: nil
        )
    }

    static func managedFileRecovery(
        id: UUID,
        report: ManagedFileRecoveryReport,
        now: Date = .now
    ) -> OperationReport {
        let detail = Array(Set(report.failureMessages))
            .sorted()
            .joined(separator: "\n")
        let count = max(1, report.pendingItemCount)
        return OperationReport(
            id: id,
            operationID: id.uuidString,
            source: .importRecovery,
            status: .failed,
            persistence: .sessionOnly,
            startedAt: now,
            updatedAt: now,
            counts: OperationReportCounts(
                total: count,
                completed: 0,
                failed: count,
                pending: 0,
                warnings: 0
            ),
            items: [],
            detail: detail.isEmpty ? nil : detail,
            actions: [.open, .dismiss],
            route: .importRecovery
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
