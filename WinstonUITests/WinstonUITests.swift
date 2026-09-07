
import XCTest

final class WinstonUITests: XCTestCase {

    override func setUpWithError() throws {

        continueAfterFailure = false

    }

    override func tearDownWithError() throws {
    }

    @MainActor
    func testLaunchShowsLibraryWindow() throws {
        let app = XCUIApplication()
        try launchIsolated(app)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    func testEmptyLibraryKeepsImportFocusedAndDisconnectedDeviceReachable() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-autoBackupEnabled", "NO",
        ]
        app.launchEnvironment["XCTestConfigurationFilePath"] =
            "/private/tmp/WinstonOnboardingUITest-\(UUID().uuidString)"
        app.launchEnvironment["WINSTON_UI_TEST_FORCE_DISCONNECTED"] = "1"
        try launchIsolated(app)

        let onboarding = app.descendants(matching: .any)["library.onboarding"]
        XCTAssertTrue(onboarding.waitForExistence(timeout: 8))
        XCTAssertGreaterThan(
            onboarding.frame.width,
            700,
            "Empty-library onboarding should use the content area instead of sharing it with an empty inspector."
        )
        XCTAssertTrue(app.buttons["library.onboarding.addFiles"].exists)
        XCTAssertTrue(app.buttons["library.onboarding.importCalibre"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["library.onboarding.backup"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["library.onboarding.device"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["library.tools"]
                .waitForExistence(timeout: 5)
        )

        let onboardingAttachment = XCTAttachment(screenshot: app.screenshot())
        onboardingAttachment.name = "Empty Library Onboarding"
        onboardingAttachment.lifetime = .keepAlways
        add(onboardingAttachment)

        let device = app.descendants(matching: .any)["sidebar.device"]
        XCTAssertTrue(device.waitForExistence(timeout: 5))
        device.click()

        XCTAssertTrue(
            app.descendants(matching: .any)["device.disconnected"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["device.retry"].exists)
        XCTAssertTrue(app.buttons["device.help"].exists)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Disconnected Device Recovery"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testSilentImportCanReachKindleSyncPlan() throws {
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Winston UI Test Book-\(UUID().uuidString).txt")
        try Data("A deterministic book used by the Winston UI test.".utf8)
            .write(to: fixtureURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-onlineMetadataEnabled", "NO",
        ]
        app.launchEnvironment["XCTestConfigurationFilePath"] =
            "/private/tmp/WinstonImportToKindleUITest-\(UUID().uuidString)"
        app.launchEnvironment["WINSTON_UI_TEST_FAKE_KINDLE"] = "1"
        app.launchEnvironment["WINSTON_UI_TEST_IMPORT_PATH"] = fixtureURL.path
        try launchIsolated(app)

        XCTAssertTrue(
            app.descendants(matching: .any)["library.onboarding"]
                .waitForNonExistence(timeout: 20)
        )

        let device = app.outlines.cells
            .containing(.staticText, identifier: "sidebar.device")
            .firstMatch
        XCTAssertTrue(device.waitForExistence(timeout: 8))
        device.click()

        let reviewPlan = app.buttons["device.reviewSyncPlan"]
        XCTAssertTrue(reviewPlan.waitForExistence(timeout: 8))
        reviewPlan.click()

        XCTAssertTrue(
            app.descendants(matching: .any)["kindleSyncPlan.title"]
                .waitForExistence(timeout: 15)
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Import to Kindle Sync Plan"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testReadingRecommendationSheet() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["XCTestConfigurationFilePath"] =
            "/private/tmp/WinstonReadingRecommendationUITest"
        try launchIsolated(app)

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        window.click()
        app.typeKey("s", modifierFlags: [.command, .option])

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.buttons["readingRecommendation.done"].exists)
        XCTAssertTrue(
            sheet.descendants(matching: .any)["readingRecommendation.empty"].exists
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Reading Recommendation Sheet"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testUpdatesKeepWindowSizeAndUseStandardPageMargin() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["XCTestConfigurationFilePath"] =
            "/private/tmp/WinstonUpdatesLayoutUITest-\(UUID().uuidString)"
        try launchIsolated(app)

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let initialWindowFrame = window.frame

        let updates = app.descendants(matching: .any)["sidebar.updates"]
        XCTAssertTrue(updates.waitForExistence(timeout: 5))
        updates.click()

        let title = app.staticTexts["notices.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(window.frame.width, initialWindowFrame.width, accuracy: 1)
        XCTAssertEqual(window.frame.height, initialWindowFrame.height, accuracy: 1)
        XCTAssertTrue(app.splitters.firstMatch.exists)
        XCTAssertEqual(title.frame.minX - app.splitters.firstMatch.frame.minX, 20, accuracy: 2)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Updates Layout"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testDiscoverAndCatalogsKeepWindowSizeAndUseNativeToolbar() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["XCTestConfigurationFilePath"] =
            "/private/tmp/WinstonTopLevelNavigationUITest-\(UUID().uuidString)"
        try launchIsolated(app)

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let initialWindowFrame = window.frame

        let discover = app.descendants(matching: .any)["sidebar.discover"]
        XCTAssertTrue(discover.waitForExistence(timeout: 5))
        discover.click()

        let discoverTitle = app.staticTexts["discovery.title"]
        let refresh = app.buttons["discovery.refresh"]
        XCTAssertTrue(discoverTitle.waitForExistence(timeout: 5))
        XCTAssertTrue(refresh.waitForExistence(timeout: 5))
        XCTAssertLessThan(refresh.frame.midY, discoverTitle.frame.minY)
        XCTAssertEqual(window.frame.width, initialWindowFrame.width, accuracy: 1)
        XCTAssertEqual(window.frame.height, initialWindowFrame.height, accuracy: 1)

        let catalogs = app.descendants(matching: .any)["sidebar.catalogs"]
        XCTAssertTrue(catalogs.waitForExistence(timeout: 5))
        catalogs.click()

        XCTAssertTrue(app.staticTexts["opds.title"].waitForExistence(timeout: 5))
        XCTAssertEqual(window.frame.width, initialWindowFrame.width, accuracy: 1)
        XCTAssertEqual(window.frame.height, initialWindowFrame.height, accuracy: 1)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Discover and Catalogs Navigation"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testCatalogsAndOperationsFillTheExistingWindow() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-onlineMetadataEnabled", "YES",
        ]
        app.launchEnvironment["XCTestConfigurationFilePath"] =
            "/private/tmp/WinstonTopLevelWidthUITest-\(UUID().uuidString)"
        try launchIsolated(app)

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let initialWindowFrame = window.frame

        let catalogs = app.descendants(matching: .any)["sidebar.catalogs"]
        XCTAssertTrue(catalogs.waitForExistence(timeout: 5))
        catalogs.click()

        let catalogList = app.descendants(matching: .any)["opds.catalogList"].firstMatch
        XCTAssertTrue(catalogList.waitForExistence(timeout: 5))
        XCTAssertEqual(window.frame.width, initialWindowFrame.width, accuracy: 1)
        XCTAssertEqual(window.frame.height, initialWindowFrame.height, accuracy: 1)
        XCTAssertLessThanOrEqual(
            abs(catalogList.frame.maxY - window.frame.maxY),
            24
        )

        let catalogAttachment = XCTAttachment(screenshot: app.screenshot())
        catalogAttachment.name = "Catalogs Full Width"
        catalogAttachment.lifetime = .keepAlways
        add(catalogAttachment)

        let operations = app.descendants(matching: .any)["sidebar.operations"]
        XCTAssertTrue(operations.waitForExistence(timeout: 5))
        operations.click()

        let operationsCenter = app.descendants(matching: .any)["operationsCenter"].firstMatch
        XCTAssertTrue(operationsCenter.waitForExistence(timeout: 5))
        XCTAssertEqual(window.frame.width, initialWindowFrame.width, accuracy: 1)
        XCTAssertEqual(window.frame.height, initialWindowFrame.height, accuracy: 1)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Catalogs and Operations Full Width"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testHighlightsLibraryDraftGuardPersistenceAndReviewSession() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-appLanguage", "english",
        ]
        app.launchEnvironment["XCTestConfigurationFilePath"] =
            "/private/tmp/WinstonHighlightsUITest-\(UUID().uuidString)"
        app.launchEnvironment["WINSTON_UI_TEST_HIGHLIGHTS"] = "1"
        try launchIsolated(app)

        app.activate()
        let window = app.windows.firstMatch
        if !window.waitForExistence(timeout: 8) {
            app.typeKey("n", modifierFlags: .command)
        }
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        openHighlights(in: app)

        let workspace = app.descendants(matching: .any)["highlights.workspace"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["highlights.list"].exists)
        XCTAssertTrue(app.staticTexts["Attention shapes the day."].waitForExistence(timeout: 5))

        let reflection = app.descendants(matching: .any)["highlights.reflection"]
        XCTAssertTrue(reflection.waitForExistence(timeout: 5))
        reflection.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("Edited UI reflection")

        let secondRow = app.descendants(matching: .any)
            .matching(identifier: "highlights.row")
            .element(boundBy: 1)
        XCTAssertTrue(secondRow.waitForExistence(timeout: 5))
        secondRow.buttons.firstMatch.click()
        let keepEditing = app.buttons["highlights.unsaved.keepEditing"]
        XCTAssertTrue(keepEditing.waitForExistence(timeout: 5))
        keepEditing.click()
        XCTAssertTrue(app.staticTexts["Attention shapes the day."].exists)

        let tags = app.descendants(matching: .any)["highlights.tags"]
        tags.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("Focus, UI Test")
        let save = app.buttons["highlights.save"]
        XCTAssertTrue(save.isEnabled)
        save.click()

        app.buttons["highlights.done"].click()
        XCTAssertFalse(workspace.waitForExistence(timeout: 2))
        openHighlights(in: app)
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        XCTAssertEqual(
            app.descendants(matching: .any)["highlights.tags"].value as? String,
            "Focus, UI Test"
        )
        XCTAssertEqual(
            app.descendants(matching: .any)["highlights.reflection"].value as? String,
            "Edited UI reflection"
        )

        app.descendants(matching: .any)["highlights.mode.review"].click()
        XCTAssertTrue(
            app.descendants(matching: .any)["highlights.review.session"]
                .waitForExistence(timeout: 5)
        )
        for _ in 0..<5 {
            let advance = app.buttons["highlights.review.advance"]
            XCTAssertTrue(advance.waitForExistence(timeout: 5))
            advance.click()
        }
        XCTAssertTrue(
            app.descendants(matching: .any)["highlights.review.complete"]
                .waitForExistence(timeout: 5)
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Highlights Review Complete"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func launchIsolated(_ app: XCUIApplication) throws {
        try configureIsolatedLibrary(for: app)
        app.launch()
    }

    @MainActor
    private func configureIsolatedLibrary(for app: XCUIApplication) throws {
        let rootKey = "WINSTON_LIBRARY_PERFORMANCE_ROOT"
        if app.launchEnvironment[rootKey] == nil {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("WinstonUITest-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            app.launchEnvironment[rootKey] = root.path
            addTeardownBlock { @MainActor in
                app.terminate()
                try FileManager.default.removeItem(at: root)
            }
        }
        app.launchEnvironment["XCTestConfigurationFilePath"] = app.launchEnvironment[rootKey]
        if app.launchEnvironment["WINSTON_UI_TEST_FAKE_KINDLE"] != "1" {
            app.launchEnvironment["WINSTON_UI_TEST_FORCE_DISCONNECTED"] = "1"
        }
        for key in ["autoBackupEnabled", "onlineMetadataEnabled", "releaseCheckEnabled", "watchFolderEnabled"] {
            if !app.launchArguments.contains("-\(key)") {
                app.launchArguments += ["-\(key)", "NO"]
            }
        }
    }

    @MainActor
    private func openHighlights(in app: XCUIApplication) {
        let englishMenu = app.menuBars.menuBarItems["Library"]
        let libraryMenu = englishMenu.exists
            ? englishMenu
            : app.menuBars.menuBarItems["Knihovna"]
        XCTAssertTrue(libraryMenu.waitForExistence(timeout: 5))
        libraryMenu.click()

        let englishItem = app.menuItems["Highlights…"]
        let highlights = englishItem.exists
            ? englishItem
            : app.menuItems["Zvýraznění…"]
        XCTAssertTrue(highlights.waitForExistence(timeout: 5))
        highlights.click()
    }

    @MainActor
    func testLaunchPerformance() throws {
        let app = XCUIApplication()
        try configureIsolatedLibrary(for: app)
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            app.launch()
        }
    }

    @MainActor
    func testBrowsingLargeLibraryRetainsSelectionAndReturnsToLoadedCovers() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WinstonBrowsingUITest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = XCUIApplication()
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: root)
        }
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(en)",
            "-autoBackupEnabled", "NO", "-onlineMetadataEnabled", "NO",
            "-watchFolderEnabled", "NO", "-gridZoom", "0",
            "-LogForEachSlowPath", "YES",
        ]
        app.launchEnvironment["XCTestConfigurationFilePath"] = root.path
        app.launchEnvironment["WINSTON_LIBRARY_PERFORMANCE_ROOT"] = root.path
        app.launchEnvironment["WINSTON_UI_TEST_FORCE_DISCONNECTED"] = "1"
        app.launchEnvironment["WINSTON_UI_TEST_BROWSING"] = "1"
        try launchIsolated(app)

        let grid = app.scrollViews["library.grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 30))
        let first = app.descendants(matching: .any)[
            "library.book.00000000-0000-4000-8000-000000000000"
        ].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.click()
        // Single-click recognition can wait for the system double-click
        // interval. Do not send keyboard input into the pending click.
        XCTAssertTrue(first.wait(for: \.isSelected, toEqual: true, timeout: 5))
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.space, modifierFlags: [])
        let second = app.descendants(matching: .any)[
            "library.book.00000000-0000-4000-8000-000000000001"
        ].firstMatch
        XCTAssertTrue(second.wait(for: \.isSelected, toEqual: true, timeout: 5),
                      "Space must select the keyboard-focused book.")

        let options = XCTMeasureOptions()
        options.iterationCount = 2
        measure(metrics: [
            XCTClockMetric(), XCTMemoryMetric(application: app), XCTHitchMetric(application: app),
        ], options: options) {
            for _ in 0..<12 { grid.scroll(byDeltaX: 0, deltaY: -1_000) }
            XCTAssertFalse(first.isHittable, "The scroll must actually move the first cover offscreen.")
            for _ in 0..<12 { grid.scroll(byDeltaX: 0, deltaY: 1_000) }
        }
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(first.isHittable)
        XCTAssertTrue(second.isSelected, "Scrolling must preserve the selected book.")
        first.click()
        XCTAssertTrue(first.wait(for: \.isSelected, toEqual: true, timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Large library after scrolling back to decoded covers"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
