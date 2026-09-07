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
        #expect(!physicalSelection.canInspectWithBookDoctor)
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
        #expect(availability.canInspectWithBookDoctor)
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
        #expect(availability.canInspectWithBookDoctor)
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

    @Test @MainActor func sharedSelectionPassPreservesMixedFileCapabilities() {
        let epub = Book(fileName: "available.epub", originalFileName: "Available.epub")
        let protected = Book(fileName: "locked.pdf", originalFileName: "Locked.pdf")
        protected.drmProtected = true
        let kindle = Book(fileName: "ready.mobi", originalFileName: "Ready.mobi")
        let physical = Book(fileName: "", originalFileName: "Paper")
        let books = [epub, protected, kindle, physical]

        let result = BookActionAvailability.forBooks(
            books,
            primary: physical,
            calibreAvailable: false,
            onlineMetadataEnabled: true,
            deviceFileNames: [kindle.deviceMatchKey]
        )

        #expect(result.selectionCount == 4)
        #expect(result.hasPrimarySelection)
        #expect(!result.canUsePrimaryFile)
        #expect(result.persistedDigitalFileCount == 3)
        #expect(result.sendableDigitalFileCount == 2)
        #expect(result.drmProtectedDigitalFileCount == 1)
        #expect(result.conversionEligibleCount == 1)
        #expect(result.onDeviceSelectionCount == 1)
        #expect(result.canFetchMetadata)
    }

    @Test @MainActor func emptySelectionHasNoFileCapabilities() {
        let result = BookActionAvailability.forBooks(
            [], primary: nil, calibreAvailable: true,
            onlineMetadataEnabled: true, deviceFileNames: []
        )
        #expect(!result.hasSelection)
        #expect(!result.hasPrimarySelection)
        #expect(!result.canConvertForKindle)
        #expect(!result.canTransmit)
        #expect(!result.canFetchMetadata)
    }
}
