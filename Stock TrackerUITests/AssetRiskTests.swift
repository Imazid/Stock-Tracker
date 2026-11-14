import XCTest

final class AssetRiskTests: XCTestCase {
    func testHistoricalPriceRiskShowsCompletedClosesAndCanChangePeriod() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["ASSET_RISK_UI_EMAIL"] != nil, "Prepare a hosted read-only risk test account.")
        let email = try XCTUnwrap(env["ASSET_RISK_UI_EMAIL"])
        let password = try XCTUnwrap(env["ASSET_RISK_UI_PASSWORD"])
        let source = try XCTUnwrap(env["ASSET_RISK_UI_SOURCE"])
        let expectedDrawdown = try XCTUnwrap(env["ASSET_RISK_UI_DRAWDOWN"])
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-UITestFreshInstall", "-UITestTradingFixture", "-hasCompletedOnboarding", "YES",
                               "-UITestSignIn", "\(email):\(password)", "-AppleLanguages", "(en)",
                               "-AppleLocale", "en_US", "-app_theme_mode", "Light"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 35))
        XCUIDevice.shared.system.open(try XCTUnwrap(URL(string: "stocktracker://asset/AAPL")))
        let risk = app.buttons["detail.assetRisk"]
        for _ in 0..<5 where !risk.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(risk.waitForExistence(timeout: 15))
        risk.tap()
        XCTAssertTrue(app.navigationBars["AAPL Price Risk"].waitForExistence(timeout: 15))
        let drawdown = app.descendants(matching: .any)["assetRisk.drawdown"].firstMatch
        XCTAssertTrue(drawdown.waitForExistence(timeout: 35))
        let drawdownText = "\(drawdown.label) \(drawdown.value as? String ?? "")"
        XCTAssertTrue(drawdownText.contains(expectedDrawdown), drawdownText)
        let sourceRow = app.staticTexts["assetRisk.source"].firstMatch
        XCTAssertTrue(sourceRow.exists)
        XCTAssertEqual(sourceRow.label, source)
        let oneYear = app.segmentedControls["assetRisk.range"].buttons["1Y"]
        XCTAssertTrue(oneYear.exists)
        oneYear.tap()
        let through = try XCTUnwrap(env["ASSET_RISK_UI_YEAR_PERIOD"])
        XCTAssertTrue(app.staticTexts[through].waitForExistence(timeout: 30))
        XCTAssertTrue(oneYear.isSelected)
    }
}
