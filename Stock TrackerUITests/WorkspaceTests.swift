import XCTest

final class WorkspaceTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-UITestFreshInstall", "-UITestTradingFixture",
            "-hasCompletedOnboarding", "YES", "-useBiometrics", "NO", "-app_theme_mode", "Dark"
        ]
        app.launch()
    }

    func testCommandsOpenCopilotAndNavigateBetweenTabs() {
        openPalette()
        let query = app.textFields["commands.query"]
        query.tap()
        query.typeText("ask Show me all my pending trades")
        let ask = app.buttons["commands.result.ask"]
        XCTAssertTrue(ask.waitForExistence(timeout: 5))
        ask.tap()
        XCTAssertTrue(app.staticTexts["copilot.question"].waitForExistence(timeout: 5))
        attachScreenshot("copilot")
        app.buttons["copilot.close"].tap()

        openPalette()
        let activity = app.buttons["commands.result.activity"]
        XCTAssertTrue(activity.waitForExistence(timeout: 5))
        activity.tap()
        XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 5))
    }

    func testAssetAndPracticeOrderCommandsOpenExistingFlows() {
        openPalette()
        let query = app.textFields["commands.query"]
        query.tap()
        query.typeText("AAPL")
        let asset = app.buttons["commands.result.us:AAPL"]
        XCTAssertTrue(asset.waitForExistence(timeout: 8), "Query: \(query.value ?? "unavailable")")
        attachScreenshot("command-results")
        asset.tap()
        XCTAssertTrue(app.buttons["detail.close"].waitForExistence(timeout: 7))
        attachScreenshot("asset-detail")
        app.buttons["detail.close"].tap()

        openPalette()
        query.tap()
        query.typeText("buy AAPL")
        let buy = app.buttons["commands.result.us:AAPL"]
        XCTAssertTrue(buy.waitForExistence(timeout: 5))
        buy.tap()
        XCTAssertTrue(app.navigationBars["Buy AAPL"].waitForExistence(timeout: 5))
        let start = app.buttons["practice.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        let simple = app.buttons["Simple"]
        XCTAssertTrue(simple.waitForExistence(timeout: 5))
        let advanced = app.buttons["Advanced"]
        XCTAssertTrue(advanced.exists)
        advanced.tap()
        attachScreenshot("advanced-ticket")
        XCTAssertTrue(app.staticTexts["Market quotes and history"].waitForExistence(timeout: 5))
        simple.tap()

        let amount = app.textFields["ticket.amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap()
        amount.typeText("100")
        let review = app.buttons["ticket.review"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        review.tap()
        XCTAssertTrue(app.staticTexts["ticket.review.sentence"].waitForExistence(timeout: 5))
        attachScreenshot("order-review")
    }

    private func openPalette() {
        let button = app.buttons["commands.open"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 12))
        button.tap()
        XCTAssertTrue(app.textFields["commands.query"].waitForExistence(timeout: 5))
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
