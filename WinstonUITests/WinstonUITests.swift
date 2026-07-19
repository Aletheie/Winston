
import XCTest

final class WinstonUITests: XCTestCase {

    override func setUpWithError() throws {

        continueAfterFailure = false

    }

    override func tearDownWithError() throws {
    }

    @MainActor
    func testExample() throws {
        let app = XCUIApplication()
        app.launch()

    }

    @MainActor
    func testReadingRecommendationSheet() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["XCTestConfigurationFilePath"] =
            "/private/tmp/WinstonReadingRecommendationUITest"
        app.launch()

        let recommendationButton = app.buttons["readingRecommendation.open"]
        XCTAssertTrue(recommendationButton.waitForExistence(timeout: 5))
        recommendationButton.click()

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
        app.launch()

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
        app.launch()

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
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
