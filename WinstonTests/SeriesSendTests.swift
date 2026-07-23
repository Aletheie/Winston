import Foundation
import Testing
@testable import Winston

@Suite("Series send")
@MainActor
struct SeriesSendTests {
    private func book(_ name: String, index: String?, drm: Bool = false) -> Book {
        let book = Book(fileName: "\(name).epub", originalFileName: "\(name).epub")
        book.series = "Earthsea"
        book.seriesIndex = index
        book.drmProtected = drm
        return book
    }

    @Test func pendingSendSkipsDeviceCopiesAndDRMAndSortsBySeriesOrder() {
        let wizard = book("wizard", index: "1")
        let tombs = book("tombs", index: "2")
        let shore = book("shore", index: "3", drm: true)
        let tehanu = book("tehanu", index: nil)

        let pending = SendSeriesButton.pendingSend(
            in: [tehanu, tombs, shore, wizard],
            deviceFileNames: ["tombs"]
        )

        #expect(pending.map(\.originalFileName) == ["wizard.epub", "tehanu.epub"])
    }

    @Test func completeMeansEveryBookIncludingDRMIsAlreadyOnDevice() {
        let wizard = book("wizard", index: "1")
        let shore = book("shore", index: "3", drm: true)

        #expect(!SendSeriesButton.entireSeriesIsOnDevice(
            [wizard, shore],
            deviceFileNames: ["wizard"]
        ))
        #expect(SendSeriesButton.entireSeriesIsOnDevice(
            [wizard, shore],
            deviceFileNames: ["wizard", "shore"]
        ))
    }

    @Test func allocatedDeviceKeyDoesNotHideAnotherBookWithTheSameBasename() {
        let first = book("first", index: "1")
        let second = book("second", index: "2")
        first.originalFileName = "book.epub"
        second.originalFileName = "book.epub"

        let pending = SendSeriesButton.pendingSend(
            in: [first, second],
            deviceFileNames: [first.allocatedDeviceMatchKey]
        )

        #expect(pending.map(\.uuid) == [second.uuid])
        #expect(first.allocatedDeviceMatchKey != second.allocatedDeviceMatchKey)
    }

    @Test func physicalOnlyCopiesAreNotSentOrCountedAsMissingFromKindle() {
        let wizard = book("wizard", index: "1")
        let physical = Book(fileName: "", originalFileName: "Tombs")
        physical.hasPhysicalCopy = true

        #expect(SendSeriesButton.pendingSend(
            in: [wizard, physical],
            deviceFileNames: []
        ).map(\.uuid) == [wizard.uuid])
        #expect(SendSeriesButton.entireSeriesIsOnDevice(
            [wizard, physical],
            deviceFileNames: ["wizard"]
        ))
    }

    @Test func inspectorShowsSingletonOnlyAfterOnlineCatalogConfirmsMoreBooks() {
        #expect(!DetailSeries.shouldDisplay(
            localBookCount: 1,
            remoteBookCount: nil,
            onlineMetadataEnabled: true
        ))
        #expect(!DetailSeries.shouldDisplay(
            localBookCount: 1,
            remoteBookCount: 4,
            onlineMetadataEnabled: false
        ))
        #expect(DetailSeries.shouldDisplay(
            localBookCount: 1,
            remoteBookCount: 4,
            onlineMetadataEnabled: true
        ))
        #expect(DetailSeries.shouldDisplay(
            localBookCount: 2,
            remoteBookCount: nil,
            onlineMetadataEnabled: false
        ))
    }
}
