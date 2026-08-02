import Foundation
import Observation

@MainActor
@Observable
final class OperationReportStore {
    let maximumReportCount: Int
    let maximumItemCount: Int

    private(set) var reports: [OperationReport] = []

    init(
        maximumReportCount: Int = 60,
        maximumItemCount: Int = 200
    ) {
        self.maximumReportCount = max(1, maximumReportCount)
        self.maximumItemCount = max(1, maximumItemCount)
    }

    var unresolvedCount: Int {
        reports.count { $0.status != .completed }
    }

    func reports(status: OperationReportStatus) -> [OperationReport] {
        reports.filter { $0.status == status }
    }

    func upsert(_ report: OperationReport) {
        let bounded = boundedItems(in: report)
        if let index = reports.firstIndex(where: { $0.id == report.id }) {
            reports[index] = bounded
        } else {
            reports.append(bounded)
        }
        sortAndTrim()
    }

    func remove(id: OperationReport.ID) {
        reports.removeAll { $0.id == id }
    }

    func dismiss(id: OperationReport.ID) {
        guard let report = reports.first(where: { $0.id == id }),
              report.persistence == .sessionOnly,
              report.actions.contains(.dismiss) else { return }
        remove(id: id)
    }

    func replaceDurableLinks(_ links: [OperationReport]) {
        let desiredIDs = Set(links.map(\.id))
        reports.removeAll {
            $0.persistence == .durableRecovery && !desiredIDs.contains($0.id)
        }
        for link in links where link.persistence == .durableRecovery {
            upsert(link)
        }
        sortAndTrim()
    }

    func reconcileSessionTargets(validTargetIDs: Set<String>) {
        reports = reports.map { report in
            guard report.persistence == .sessionOnly,
                  report.source == .bulkLibrary else { return report }
            return report.pruningStaleTargets(validTargetIDs)
        }
        sortAndTrim()
    }

    private func boundedItems(in report: OperationReport) -> OperationReport {
        guard report.items.count > maximumItemCount else { return report }
        return OperationReport(
            id: report.id,
            operationID: report.operationID,
            source: report.source,
            status: report.status,
            persistence: report.persistence,
            startedAt: report.startedAt,
            updatedAt: report.updatedAt,
            counts: report.counts,
            items: Array(report.items.prefix(maximumItemCount)),
            detail: report.detail,
            actions: report.actions,
            route: report.route
        )
    }

    private func sortAndTrim() {
        reports.sort {
            if $0.status != $1.status {
                return $0.status.sortPriority < $1.status.sortPriority
            }
            return $0.updatedAt > $1.updatedAt
        }
        guard reports.count > maximumReportCount else { return }
        var overflow = reports.count - maximumReportCount
        for index in reports.indices.reversed()
            where overflow > 0 && reports[index].status == .completed {
            reports.remove(at: index)
            overflow -= 1
        }
        if overflow > 0 {
            reports.removeLast(min(overflow, reports.count))
        }
    }
}

private extension OperationReportStatus {
    var sortPriority: Int {
        switch self {
        case .review: 0
        case .running: 1
        case .failed: 2
        case .completed: 3
        }
    }
}
