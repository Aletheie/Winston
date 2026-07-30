import Testing
@testable import Winston

struct BookActionAvailabilityTests {
    @Test func fileActionsRequireAPrimaryPersistedDigitalFile() {
        let physicalSelection = BookActionAvailability(
            selectionCount: 1,
            hasPrimarySelection: true
        )

        #expect(physicalSelection.hasSelection)
        #expect(!physicalSelection.canUsePrimaryFile)
        #expect(physicalSelection.canReplaceOrAttachFile)
        #expect(physicalSelection.canEditMetadata)
        #expect(!physicalSelection.canTransmit)
    }

    @Test func selectionCapabilitiesUseTheirSpecificEligibilityInputs() {
        let availability = BookActionAvailability(
            selectionCount: 3,
            hasPrimarySelection: true,
            primaryHasPersistedDigitalFile: true,
            persistedDigitalFileCount: 2,
            sendableDigitalFileCount: 1,
            drmProtectedDigitalFileCount: 1,
            conversionEligibleCount: 1,
            calibreAvailable: true,
            onlineMetadataEnabled: true,
            onDeviceSelectionCount: 2,
            hasMeaningfulSearch: true
        )

        #expect(availability.canUsePrimaryFile)
        #expect(availability.canFetchMetadata)
        #expect(availability.canConvertForKindle)
        #expect(availability.canRemoveFromDevice)
        #expect(availability.canTransmit)
        #expect(availability.canSaveSearch)
    }

    @Test func settingsAndSearchDoNotBorrowSelectionSemantics() {
        let availability = BookActionAvailability(
            selectionCount: 1,
            hasPrimarySelection: true,
            primaryHasPersistedDigitalFile: true,
            persistedDigitalFileCount: 1,
            sendableDigitalFileCount: 1
        )

        #expect(!availability.canFetchMetadata)
        #expect(!availability.canConvertForKindle)
        #expect(!availability.canRemoveFromDevice)
        #expect(!availability.canSaveSearch)
    }

    @Test func drmOnlySelectionIsNotSendable() {
        let availability = BookActionAvailability(
            selectionCount: 2,
            hasPrimarySelection: true,
            primaryHasPersistedDigitalFile: true,
            persistedDigitalFileCount: 2,
            drmProtectedDigitalFileCount: 2
        )

        #expect(availability.hasDRMOnlyDigitalSelection)
        #expect(!availability.canTransmit)
    }
}
