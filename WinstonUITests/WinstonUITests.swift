
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
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
