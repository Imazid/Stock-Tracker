import XCTest

final class PrivateMarketsFlowTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        app.launchArguments = ["-UITestFreshInstall", "-hasCompletedOnboarding", "YES",
                               "-useBiometrics", "NO", "-app_theme_mode", "Dark"]
        app.launch()
    }

    func testManualHoldingAppearsInUnifiedPortfolioAndSurvivesRelaunch() {
        openPrivateMarkets()
        app.buttons["private.destination.briefcase"].tap()
        let add = app.buttons["private.holding.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()

        let name = app.textFields["private.holding.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Local test investment")
        app.buttons["private.holding.save"].tap()
        let holding = app.buttons["private.holding.row"].firstMatch
        XCTAssertTrue(holding.waitForExistence(timeout: 5))
        holding.tap()

        let valuation = app.buttons["private.valuation.add"]
        if !valuation.isHittable { app.swipeUp() }
        XCTAssertTrue(valuation.waitForExistence(timeout: 5))
        valuation.tap()
        let amount = app.textFields["private.ledger.amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap()
        amount.typeText("2400")
        let source = app.textFields["private.ledger.source"]
        source.tap()
        source.typeText("Test ownership statement")
        let method = app.textFields["private.ledger.method"]
        method.tap()
        method.typeText("Statement value")
        app.buttons["private.ledger.save"].tap()
        XCTAssertFalse(app.navigationBars["Record Valuation"].exists)
        let recordedMark = app.descendants(matching: .any)["private.valuation.record"].firstMatch
        if !recordedMark.isHittable { app.swipeUp() }
        XCTAssertTrue(recordedMark.waitForExistence(timeout: 5))
        XCTAssertTrue(recordedMark.label.contains("Test ownership statement"))

        app.terminate()
        app.launchArguments.removeAll { $0 == "-UITestFreshInstall" }
        app.launch()
        openPrivateMarkets()
        app.buttons["private.destination.briefcase"].tap()
        XCTAssertTrue(holding.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["private.allocation"].firstMatch.exists)
        XCTAssertTrue(holding.label.contains("Local test investment"))
    }

    func testProviderDirectoryAndOfflineCalculatorAreReachable() {
        openPrivateMarkets()
        app.buttons["private.destination.magnifyingglass"].tap()
        XCTAssertTrue(app.navigationBars["Discover Deals"].waitForExistence(timeout: 5))
        let birchal = app.staticTexts["Birchal"]
        if !birchal.isHittable { app.swipeUp() }
        XCTAssertTrue(birchal.waitForExistence(timeout: 8))
        let back = app.navigationBars["Discover Deals"].buttons["BackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        let research = app.buttons["private.destination.sparkles"]
        if !research.waitForExistence(timeout: 4) {
            app.tabBars.firstMatch.buttons["Private Markets"].tap()
        }
        XCTAssertTrue(research.waitForExistence(timeout: 6))
        research.tap()
        let calculator = app.buttons["Ownership, dilution and exit scenarios"]
        XCTAssertTrue(calculator.waitForExistence(timeout: 5))
        calculator.tap()
        XCTAssertTrue(app.navigationBars["Scenario Calculator"].waitForExistence(timeout: 5))
    }

    private func openPrivateMarkets() {
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 12))
        let direct = tabs.buttons["Private Markets"]
        XCTAssertTrue(direct.waitForExistence(timeout: 8))
        direct.tap()
        XCTAssertTrue(app.buttons["private.destination.magnifyingglass"].waitForExistence(timeout: 5))
    }
}
