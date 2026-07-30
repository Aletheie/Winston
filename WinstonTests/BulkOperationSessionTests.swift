import Foundation
import SwiftData
import Testing
@testable import Winston

@MainActor
@Suite(.serialized)
struct BulkOperationSessionTests {
    @Test func plannerSeparatesChangesUnchangedConflictsAndChunks() async {
        let ids = (0 ..< 5).map { _ in UUID() }
        let targets = ids.map(BulkOperationTargetID.catalogBook)
        let plan = await BulkOperationPlanner.shared.makePlan(
            operation: .metadataEdit,
            requestedTargetIDs: targets + [targets[0]],
            candidates: [
                .change(targets[0], count: 2),
                .change(targets[1]),
                .unchanged(targets[2]),
                .conflict(targets[3], reason: .invalidTarget),
            ],
            chunkSize: 1
        )

        #expect(plan.requestedTargetCount == 5)
        #expect(plan.affectedTargetCount == 2)
        #expect(plan.changeCount == 3)
        #expect(plan.unchangedTargetIDs == [targets[2]])
        #expect(plan.conflicts.map(\.reason) == [.invalidTarget, .missingTarget])
        #expect(plan.chunks.map(\.targetIDs) == [[targets[0]], [targets[1]]])
    }

    @Test func cancellationIsObservedBetweenCommittedChunks() async {
        let targets = (0 ..< 3).map { _ in
            BulkOperationTargetID.catalogBook(UUID())
        }
        let plan = await BulkOperationPlanner.shared.makePlan(
            operation: .collectionAdd,
            requestedTargetIDs: targets,
            candidates: targets.map { .change($0) },
            chunkSize: 1
        )
        let session = BulkOperationSession(plan: plan)
        var appliedChunks = 0
        var progress: [BulkOperationProgress] = []

        let result = await session.execute(onProgress: {
            progress.append($0)
        }) { chunk in
            appliedChunks += 1
            if appliedChunks == 1 { await session.cancel() }
            return .applied(chunk.targetIDs)
        }

        #expect(result.completion == .cancelled)
        #expect(result.completedChunkCount == 1)
        #expect(result.appliedTargetIDs == [targets[0]])
        #expect(result.pendingTargetIDs == Array(targets.dropFirst()))
        #expect(result.outcomeKind == .cancelled)
        #expect(progress.map(\.completedTargetCount) == [0, 1])
        #expect(progress.allSatisfy { $0.totalTargetCount == 3 })
        let latestProgress = await session.progress()
        #expect(latestProgress == progress.last)
    }

    @Test func durableFailureStopsBeforeLaterChunks() async {
        let targets = (0 ..< 3).map { _ in
            BulkOperationTargetID.catalogBook(UUID())
        }
        let plan = await BulkOperationPlanner.shared.makePlan(
            operation: .catalogDelete,
            requestedTargetIDs: targets,
            candidates: targets.map { .change($0) },
            chunkSize: 1
        )
        let session = BulkOperationSession(plan: plan)

        let result = await session.execute { chunk in
            if chunk.index == 1 {
                throw BulkOperationDurableError(.catalogSave, detail: "injected")
            }
            return .applied(chunk.targetIDs)
        }

        #expect(result.completion == .failed)
        #expect(result.completedChunkCount == 1)
        #expect(result.appliedTargetIDs == [targets[0]])
        #expect(result.durableFailure?.code == .catalogSave)
        #expect(result.durableFailure?.targetIDs == [targets[1]])
        #expect(result.pendingTargetIDs == [targets[1], targets[2]])
        #expect(result.outcomeKind == .partialSuccess)
    }

    @Test func resultClassificationSeparatesSuccessConflictAndFailure() async {
        let successTarget = BulkOperationTargetID.deviceBook("success")
        let successPlan = await BulkOperationPlanner.shared.makePlan(
            operation: .deviceDelete,
            requestedTargetIDs: [successTarget],
            candidates: [.change(successTarget)],
            chunkSize: 1
        )
        let success = await BulkOperationSession(plan: successPlan).execute {
            .applied($0.targetIDs)
        }

        let conflictTarget = BulkOperationTargetID.deviceBook("conflict")
        let conflictPlan = await BulkOperationPlanner.shared.makePlan(
            operation: .deviceDelete,
            requestedTargetIDs: [conflictTarget],
            candidates: [
                .conflict(conflictTarget, reason: .sourceChanged),
            ],
            chunkSize: 1
        )
        let conflict = await BulkOperationSession(plan: conflictPlan).execute { _ in
            Issue.record("A conflict-only plan must not execute a chunk")
            return BulkOperationChunkOutcome()
        }

        let failureTarget = BulkOperationTargetID.deviceBook("failure")
        let failurePlan = await BulkOperationPlanner.shared.makePlan(
            operation: .deviceDelete,
            requestedTargetIDs: [failureTarget],
            candidates: [.change(failureTarget)],
            chunkSize: 1
        )
        let failure = await BulkOperationSession(plan: failurePlan).execute { _ in
            throw BulkOperationDurableError(.deviceDisconnected)
        }

        #expect(success.outcomeKind == .success)
        #expect(conflict.outcomeKind == .conflict)
        #expect(failure.outcomeKind == .failure)
    }

    @Test func metadataBulkCommitStopsAfterTheFirstDurableSaveFailure() async throws {
        struct InjectedFailure: Error {}

        let lib = try await TestLibrary()
        let books = (0 ..< 205).map { index in
            Book(
                fileName: "",
                originalFileName: "Physical \(index)",
                dateAdded: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        for book in books {
            book.hasPhysicalCopy = true
            lib.context.insert(book)
        }
        lib.context.insert(BookCollection(
            name: "Wishlist",
            systemKind: .wishlist
        ))
        try lib.context.save()

        var saveCount = 0
        let viewModel = LibraryViewModel(
            modelContext: lib.context,
            settings: AppSettings(),
            toasts: ToastCenter(),
            saveAdapter: CatalogSaveAdapter { context in
                saveCount += 1
                if saveCount == 2 { throw InjectedFailure() }
                try context.save()
            }
        )
        var edit = BulkEdit()
        edit.publisher = "Chunked Publisher"

        let result = await viewModel.bulkUpdate(
            bookIDs: Set(books.map(\.uuid)),
            edit: edit
        )

        #expect(result.completion == .failed)
        #expect(result.completedChunkCount == 1)
        #expect(result.appliedTargetCount == 100)
        #expect(result.pendingTargetIDs.count == 105)
        #expect(books.count { $0.publisher == "Chunked Publisher" } == 100)
        #expect(books.count { $0.publisher == nil } == 105)
    }

    @Test func collectionPlanDoesNotScheduleExistingMembers() async throws {
        let lib = try await TestLibrary()
        let existing = Book(fileName: "", originalFileName: "Existing")
        let addition = Book(fileName: "", originalFileName: "Addition")
        existing.hasPhysicalCopy = true
        addition.hasPhysicalCopy = true
        let collection = BookCollection(name: "Shelf")
        collection.books = [existing]
        lib.context.insert(existing)
        lib.context.insert(addition)
        lib.context.insert(collection)
        try lib.context.save()
        let viewModel = LibraryViewModel(
            modelContext: lib.context,
            settings: AppSettings(),
            toasts: ToastCenter()
        )
        let missingID = UUID()

        let plan = await viewModel.planCollectionChange(
            bookIDs: [existing.uuid, addition.uuid, missingID],
            collectionID: collection.id,
            adding: true
        )

        #expect(plan.actionableTargetIDs == [.catalogBook(addition.uuid)])
        #expect(plan.unchangedTargetIDs == [.catalogBook(existing.uuid)])
        #expect(plan.conflicts == [
            BulkOperationConflict(
                targetID: .catalogBook(missingID),
                reason: .missingTarget
            ),
        ])
    }
}
