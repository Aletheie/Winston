import Testing
@testable import Winston

@Suite("Operation presentation policy")
struct OperationPresentationTests {
    @Test(arguments: [
        (0, 8, 0),
        (1, 8, 0),
        (2, 8, 25),
        (4, 8, 50),
        (6, 8, 75),
        (8, 8, 100),
        (20, 8, 100),
    ])
    func progressAnnouncementsUseBoundedQuarterMilestones(
        _ completed: Int,
        _ total: Int,
        _ expected: Int
    ) {
        #expect(OperationProgressMilestones.milestone(
            completedCount: completed,
            totalCount: total
        ) == expected)
    }

    @Test
    func unknownOrInvalidTotalsDoNotProduceAnnouncements() {
        #expect(OperationProgressMilestones.milestone(
            completedCount: 0,
            totalCount: 0
        ) == nil)
        #expect(OperationProgressMilestones.milestone(
            completedCount: 3,
            totalCount: -1
        ) == nil)
    }

    @Test @MainActor
    func errorsAndRecoveryActionsRemainUntilExplicitlyDismissed() throws {
        let center = ToastCenter()
        center.error("Save failed")
        center.post(
            "Review recovery",
            style: .info,
            action: .reviewImport
        )

        #expect(center.messages.count == 2)
        #expect(center.messages.allSatisfy { $0.persistence == .untilDismissed })

        let firstID = try #require(center.messages.first?.id)
        center.dismiss(firstID)
        #expect(center.messages.count == 1)
    }

    @Test @MainActor
    func smallCompleteFeedbackUsesAutomaticDismissalByDefault() {
        let center = ToastCenter()
        center.success("Done")
        center.info("Nothing new")

        #expect(center.messages.count == 2)
        #expect(center.messages.allSatisfy { $0.persistence == .automatic })
    }
}
