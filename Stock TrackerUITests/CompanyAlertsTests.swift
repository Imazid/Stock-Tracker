import XCTest

final class CompanyAlertsTests: XCTestCase {
    func testAccountAlertsOpenFromActivityAndCanBeManaged() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["COMPANY_ALERT_UI_EMAIL"] != nil, "Prepare the hosted company alerts test account.")
        let email = try XCTUnwrap(env["COMPANY_ALERT_UI_EMAIL"])
        let password = try XCTUnwrap(env["COMPANY_ALERT_UI_PASSWORD"])
        let event = try XCTUnwrap(env["COMPANY_ALERT_UI_EVENT"])
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments = ["-UITestFreshInstall", "-UITestTradingFixture", "-hasCompletedOnboarding", "YES",
                               "-UITestSignIn", "\(email):\(password)", "-AppleLanguages", "(en)",
                               "-AppleLocale", "en_US", "-app_theme_mode", "Light"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 35))
        XCTAssertTrue(app.open("Activity"))
        let companyAlerts = app.buttons["activity.companyAlerts"]
        XCTAssertTrue(companyAlerts.waitForExistence(timeout: 35))
        companyAlerts.tap()

        let trigger = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", event)).firstMatch
        XCTAssertTrue(trigger.waitForExistence(timeout: 25))
        trigger.tap()
        XCTAssertTrue(app.navigationBars["AAPL Alerts"].waitForExistence(timeout: 10))
        let threshold = app.textFields["companyAlerts.threshold"]
        let addButton = app.buttons["companyAlerts.add"]
        XCTAssertTrue(threshold.waitForExistence(timeout: 25))
        XCTAssertFalse(addButton.isEnabled)
        threshold.tap()
        threshold.typeText("432.15")
        XCTAssertTrue(addButton.isEnabled)
        addButton.tap()
        let saved = app.staticTexts["432.15 USD"]
        XCTAssertTrue(saved.waitForExistence(timeout: 25))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Shared company price rules on iPhone"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let remove = app.buttons["companyAlerts.remove"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 12))
        for _ in 0..<3 where !remove.isHittable { app.swipeUp(velocity: .slow) }
        remove.tap()
        let confirmation = app.alerts["Remove company alert?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Remove alert"].tap()
        XCTAssertTrue(saved.waitForNonExistence(timeout: 25))
        XCTAssertTrue(app.staticTexts["0.01 USD"].exists)
    }
}
