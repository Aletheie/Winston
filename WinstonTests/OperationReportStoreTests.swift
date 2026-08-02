import Foundation
import Testing
@testable import Winston

@MainActor
@Suite("Operation report store")
struct OperationReportStoreTests {
    @Test func completedHistoryIsBoundedAndKeepsNewestReports() {
        let store = OperationReportStore(maximumReportCount: 3)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let reports = (0..<5).map { index in
            report(
                id: UUID(),
                status: .completed,
                updatedAt: base.addingTimeInterval(Double(index))
            )
        }

        for report in reports { store.upsert(report) }

        #expect(store.reports.count == 3)
        #expect(Set(store.reports.map(\.id)) == Set(reports.suffix(3).map(\.id)))
    }

    @Test func itemHistoryIsBoundedWithoutChangingAggregateCounts() {
        let store = OperationReportStore(
            maximumReportCount: 10,
            maximumItemCount: 2
        )
        let items = (0..<5).map { index in
            OperationReportItem(
                id: "item-\(index)",
                targetID: "book:\(index)",
                title: "Book \(index)",
                outcome: .succeeded,
                detail: nil,
                retryEligibility: .notEligible
            )
        }
        let source = report(status: .completed, items: items, total: 5)

        store.upsert(source)

        #expect(store.reports.first?.items.count == 2)
        #expect(store.reports.first?.counts.total == 5)
    }

    @Test func durableLinksAreAggregatedButOnlyRemovedByDurableStateRefresh() {
        let store = OperationReportStore()
        let durable = report(
            status: .review,
            persistence: .durableRecovery,
            actions: [.open]
        )
        store.replaceDurableLinks([durable])

        store.dismiss(id: durable.id)
        #expect(store.reports.map(\.id) == [durable.id])

        store.replaceDurableLinks([])
        #expect(store.reports.isEmpty)
    }

    @Test func staleCatalogTargetsLoseRetryWithoutAffectingValidTargets() throws {
        let validID = UUID()
        let staleID = UUID()
        let source = report(
            source: .bulkLibrary,
            status: .failed,
            actions: [.retry, .dismiss],
            items: [
                retryItem(id: validID),
                retryItem(id: staleID),
            ],
            total: 2
        )
        let store = OperationReportStore()
        store.upsert(source)

        store.reconcileSessionTargets(validTargetIDs: ["book:\(validID.uuidString)"])
        let reconciled = try #require(store.reports.first)

        #expect(reconciled.safeRetryTargetIDs == ["book:\(validID.uuidString)"])
        #expect(reconciled.canRetry == true)
        #expect(reconciled.items.first { $0.targetID == "book:\(staleID.uuidString)" }?.outcome == .skipped)
    }

    @Test func kindleDeliveryUnknownIsNeverRetryEligible() {
        let unknownBookID = UUID()
        let safeBookID = UUID()
        let info = DeviceInfo(
            name: "Kindle",
            model: "Test",
            kind: .mtp,
            totalBytes: 1,
            freeBytes: 1,
            identifier: "test"
        )
        let planItems = [
            kindleItem(id: "unknown", bookID: unknownBookID),
            kindleItem(id: "safe", bookID: safeBookID),
        ]
        var state = KindleSyncExecutionState(selectedItems: planItems, deviceInfo: info)
        state.mergeTransferSnapshots([
            unknownBookID: KindleTransferExecutionSnapshot(
                bookID: unknownBookID,
                outcome: .deliveryUnknown,
                progress: 1,
                detail: nil,
                retryEligibility: .deliveryUnknown
            ),
            safeBookID: KindleTransferExecutionSnapshot(
                bookID: safeBookID,
                outcome: .failed,
                progress: 1,
                detail: nil,
                retryEligibility: .safe
            ),
        ])

        let report = OperationReport.kindle(state.makeReport())

        #expect(!report.safeRetryTargetIDs.contains("book:\(unknownBookID.uuidString)"))
        #expect(report.safeRetryTargetIDs.contains("book:\(safeBookID.uuidString)"))
    }

    private func report(
        id: UUID = UUID(),
        source: OperationReportSource = .bulkLibrary,
        status: OperationReportStatus,
        persistence: OperationReportPersistence = .sessionOnly,
        actions: Set<OperationReportAction> = [.dismiss],
        items: [OperationReportItem] = [],
        total: Int = 0,
        updatedAt: Date = .now
    ) -> OperationReport {
        OperationReport(
            id: id,
            operationID: id.uuidString,
            source: source,
            status: status,
            persistence: persistence,
            startedAt: updatedAt,
            updatedAt: updatedAt,
            counts: OperationReportCounts(
                total: total,
                completed: status == .completed ? total : 0,
                failed: status == .failed ? total : 0,
                pending: status == .completed ? 0 : total,
                warnings: 0
            ),
            items: items,
            detail: nil,
            actions: actions,
            route: nil
        )
    }

    private func retryItem(id: UUID) -> OperationReportItem {
        OperationReportItem(
            id: id.uuidString,
            targetID: "book:\(id.uuidString)",
            title: id.uuidString,
            outcome: .pending,
            detail: nil,
            retryEligibility: .safe
        )
    }

    private func kindleItem(id: String, bookID: UUID) -> KindleSyncPlanItem {
        KindleSyncPlanItem(
            id: id,
            action: .add,
            reason: .notOnDevice,
            bookID: bookID,
            deviceBookID: nil,
            deviceFileName: nil,
            title: id,
            author: nil,
            sourceFormat: "EPUB",
            targetFormat: "AZW3",
            selectedByDefault: true
        )
    }
}
