import XCTest

final class BrokerPaperOrderTests: XCTestCase {
    /// Uses the actual order and connection functions against a local broker transport fixture.
    /// The fixture listens only on loopback and provides a preconnected paper account.
    func testPaperOrderNeedsApprovalAndShowsBrokerFill() throws {
        let app = try launchFixtureAccount()
        XCTAssertTrue(app.open("Search"))
        let search = app.searchFields.firstMatch
        tap(search, in: app)
        search.typeText("AAPL")
        tap(app.buttons["search.result.us.AAPL"], in: app, timeout: 30)
        XCTAssertTrue(app.descendants(matching: .any)["detail.screen"].firstMatch.waitForExistence(timeout: 10))
        tap(app.buttons["Trade with Alpaca Paper"], in: app, timeout: 30)
        tap(app.buttons["brokerPaper.prepare"], in: app, timeout: 35)
        let quantity = app.textFields["brokerPaper.size"]
        tap(quantity, in: app)
        quantity.typeText("1")
        XCTAssertEqual(quantity.value as? String, "1", app.debugDescription)
        let keyboardDone = app.buttons["brokerPaper.keyboardDone"]
        if keyboardDone.waitForExistence(timeout: 5) { keyboardDone.tap() }
        let draft = app.buttons["brokerPaper.draft"]
        XCTAssertTrue(draft.isEnabled, app.debugDescription)
        tap(draft, in: app)
        let fees = app.descendants(matching: .any)["brokerPaper.fees"].firstMatch
        XCTAssertTrue(fees.waitForExistence(timeout: 20))
        XCTAssertTrue(fees.label.contains("0 USD"), fees.label)
        XCTAssertFalse(app.buttons["brokerPaper.submit"].exists)

        tap(app.buttons["brokerPaper.riskCheck"], in: app)
        let approve = app.buttons["brokerPaper.approve"]
        XCTAssertTrue(approve.waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Passed"].exists)
        XCTAssertFalse(app.buttons["brokerPaper.submit"].exists)
        XCTAssertFalse(app.staticTexts["Confirmed by Alpaca"].exists)
        tap(approve, in: app)

        let submit = app.buttons["brokerPaper.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Confirmed by Alpaca"].exists)
        tap(submit, in: app)
        let brokerID = app.descendants(matching: .any)["brokerPaper.brokerID"].firstMatch
        XCTAssertTrue(brokerID.waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertTrue(brokerID.label.contains("paper-fixture-order-"), brokerID.label)
        tap(app.buttons["brokerPaper.reconcile"], in: app)
        let status = app.descendants(matching: .any)["brokerPaper.brokerStatus"].firstMatch
        let filled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'Filled'"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [filled], timeout: 20), .completed, status.label)

        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        let detailDone = app.buttons["Done"].firstMatch
        if detailDone.waitForExistence(timeout: 5) { detailDone.tap() }
        XCTAssertTrue(app.open("Activity"))
        tap(app.buttons["brokerPaper.activity"], in: app, timeout: 15)
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'brokerPaper.history.'")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 15))
        XCTAssertTrue(saved.label.contains("Buy AAPL") && saved.label.contains("Filled"), saved.label)
        tap(saved, in: app)
        XCTAssertTrue(brokerID.waitForExistence(timeout: 12))
    }

    private func launchFixtureAccount() throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["BROKER_PAPER_UI_ORIGIN"] != nil, "Set BROKER_PAPER_UI_ORIGIN for the isolated broker fixture.")
        let base = try XCTUnwrap(env["BROKER_PAPER_UI_ORIGIN"])
        let email = try XCTUnwrap(env["BROKER_PAPER_UI_EMAIL"])
        let password = try XCTUnwrap(env["BROKER_PAPER_UI_PASSWORD"])
        let key = try XCTUnwrap(env["BROKER_PAPER_UI_ANON"])
        let origin = try XCTUnwrap(URL(string: base))
        try XCTSkipUnless(origin.scheme == "http" && origin.host == "127.0.0.1", "Use an isolated fixture.")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-UITestFreshInstall", "-UITestTradingFixture", "-hasCompletedOnboarding", "YES",
                               "-SupabaseURLOverride", base, "-SupabaseAnonKeyOverride", key,
                               "-UITestSignIn", "\(email):\(password)", "-app_theme_mode", "Light"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 35))
        XCTAssertTrue(app.open("Activity"))
        XCTAssertTrue(app.buttons["brokerPaper.activity"].waitForExistence(timeout: 35), app.debugDescription)
        XCTAssertTrue(app.open("Home"))
        return app
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval = 15,
                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(element) should appear", file: file, line: line)
        for _ in 0..<6 where !element.isHittable || !app.frame.insetBy(dx: 0, dy: 70).contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) {
            let above = element.frame.midY < app.frame.midY
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: above ? 0.36 : 0.66))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: above ? 0.66 : 0.36))
            start.press(forDuration: 0.04, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
        }
        XCTAssertTrue(element.isHittable, app.debugDescription, file: file, line: line)
        element.tap()
    }
}
