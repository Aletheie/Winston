import Foundation
import Testing
@testable import Winston

@Suite("Related entity navigation")
struct EntityNavigationModelTests {
    @Test
    func selectingAnAssetMovesToItsEditionWithoutChangingIdentifiers() {
        let workID = UUID()
        let firstEditionID = UUID()
        let secondEditionID = UUID()
        let firstAssetID = UUID()
        let secondAssetID = UUID()
        var model = makeModel(
            workID: workID,
            editions: [
                edition(firstEditionID, assets: [asset(firstAssetID, primary: true)]),
                edition(secondEditionID, assets: [asset(secondAssetID, primary: true)]),
            ],
            selectedEditionID: firstEditionID,
            selectedAssetID: firstAssetID
        )

        model.selectAsset(secondAssetID)

        #expect(model.workID == workID)
        #expect(model.selectedEditionID == secondEditionID)
        #expect(model.selectedAssetID == secondAssetID)
        #expect(model.level == .asset)
        #expect(model.position == .init(current: 1, total: 1))
    }

    @Test
    func deletedSelectedEditionFallsBackToAnExistingEdition() {
        let workID = UUID()
        let deletedEditionID = UUID()
        let survivorID = UUID()
        let survivorAssetID = UUID()
        var model = makeModel(
            workID: workID,
            editions: [
                edition(deletedEditionID, assets: [asset(UUID(), primary: true)]),
                edition(survivorID, assets: [asset(survivorAssetID, primary: true)]),
            ],
            selectedEditionID: deletedEditionID
        )
        model.selectEdition(deletedEditionID)

        let updated = makeModel(
            workID: workID,
            editions: [edition(survivorID, assets: [asset(survivorAssetID, primary: true)])],
            selectedEditionID: survivorID,
            selectedAssetID: survivorAssetID
        )
        model.reconcile(with: updated)

        #expect(model.selectedEditionID == survivorID)
        #expect(model.selectedAssetID == survivorAssetID)
        #expect(model.level == .edition)
    }

    @Test
    func deletedSelectedAssetFallsBackToPrimaryWithoutLeavingAssetContext() {
        let editionID = UUID()
        let deletedAssetID = UUID()
        let primaryAssetID = UUID()
        var model = makeModel(
            editions: [
                edition(
                    editionID,
                    assets: [
                        asset(deletedAssetID),
                        asset(primaryAssetID, primary: true),
                    ]
                ),
            ],
            selectedEditionID: editionID,
            selectedAssetID: deletedAssetID
        )
        model.selectAsset(deletedAssetID)

        let updated = makeModel(
            editions: [edition(editionID, assets: [asset(primaryAssetID, primary: true)])],
            selectedEditionID: editionID,
            selectedAssetID: primaryAssetID
        )
        model.reconcile(with: updated)

        #expect(model.selectedEditionID == editionID)
        #expect(model.selectedAssetID == primaryAssetID)
        #expect(model.level == .asset)
    }

    @Test
    func physicalOnlyEditionCannotEnterStaleAssetContext() {
        let editionID = UUID()
        var model = makeModel(
            workID: nil,
            editions: [edition(editionID, assets: [])],
            selectedEditionID: editionID,
            selectedAssetID: UUID(),
            level: .asset
        )

        #expect(model.level == .edition)
        #expect(model.selectedAssetID == nil)
        #expect(model.position == .init(current: 1, total: 1))

        model.selectWork()
        #expect(model.level == .edition)
    }

    @Test
    func previousAndNextStayWithinTheCurrentEntityLevel() {
        let firstEditionID = UUID()
        let secondEditionID = UUID()
        let firstAssetID = UUID()
        let secondAssetID = UUID()
        var model = makeModel(
            editions: [
                edition(
                    firstEditionID,
                    assets: [
                        asset(firstAssetID, primary: true),
                        asset(secondAssetID),
                    ]
                ),
                edition(secondEditionID, assets: []),
            ],
            selectedEditionID: firstEditionID,
            selectedAssetID: firstAssetID
        )

        model.selectAsset(firstAssetID)
        model.moveNext()
        #expect(model.selectedEditionID == firstEditionID)
        #expect(model.selectedAssetID == secondAssetID)
        #expect(model.position == .init(current: 2, total: 2))

        model.selectEdition(firstEditionID)
        model.moveNext()
        #expect(model.selectedEditionID == secondEditionID)
        #expect(model.selectedAssetID == nil)
        #expect(model.level == .edition)
    }

    private func makeModel(
        workID: UUID? = UUID(),
        editions: [EntityNavigationModel.Edition],
        selectedEditionID: UUID?,
        selectedAssetID: UUID? = nil,
        level: EntityNavigationModel.Level = .edition
    ) -> EntityNavigationModel {
        EntityNavigationModel(
            workID: workID,
            workTitle: "A work",
            editions: editions,
            selectedEditionID: selectedEditionID,
            selectedAssetID: selectedAssetID,
            level: level
        )
    }

    private func edition(
        _ id: UUID,
        assets: [EntityNavigationModel.Asset]
    ) -> EntityNavigationModel.Edition {
        .init(id: id, label: id.uuidString, assets: assets)
    }

    private func asset(
        _ id: UUID,
        primary: Bool = false
    ) -> EntityNavigationModel.Asset {
        .init(
            id: id,
            label: "EPUB",
            fileName: "\(id.uuidString).epub",
            isPrimary: primary
        )
    }
}
