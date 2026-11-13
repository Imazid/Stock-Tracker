//
//  BrokerFlowTests.swift
//  Stock TrackerUITests
//
//  Connecting a broker, end to end, against the DEBUG broker fixture (no network,
//  no real login): the Portfolio "Accounts" card, the connect screen, holdings
//  importing on their own, per-institution cards, and the review when the broker
//  stops reporting a position.
//

import XCTest

final class BrokerFlowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    /// One holding added by hand → connect → the broker's three positions arrive in the
    /// portfolio, the Accounts card shows where each comes from, and when a later sync
    /// no longer has BHP the person is asked before it's removed.
    func testConnectImportsHoldingsAndReviewsRemovals() {
        app.launchArguments = ["-UITestFreshInstall", "-app_theme_mode", "Light",
                               "-UITestBrokerFixture", "-UITestBrokerFixtureDrop", "BHP"]
        app.launch()
        onboard(manualHolding: ("AAPL", "10", "150"))
        tab("Portfolio")

        let manual = app.descendants(matching: .any)["portfolio.account.manual"]
        reveal(manual)
        XCTAssertTrue(manual.label.contains("Added by you"), manual.label)
        let connect = app.buttons["portfolio.account.connect"]
        XCTAssertTrue(connect.exists, "Without a broker, the Accounts card offers to connect one")
        attach("light-1-accounts-not-connected")

        connect.tap()
        XCTAssertTrue(app.descendants(matching: .any)["broker.hero"].waitForExistence(timeout: 5))
        let tile = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'broker.popular.'")).firstMatch
        XCTAssertTrue(tile.exists, "Popular brokers are one tap away")
        attach("light-2-connect")
        tile.tap()

        // The fixture "links" CommSec + Coinbase; the positions import without another step.
        let imported = app.descendants(matching: .any)["broker.import"]
        XCTAssertTrue(imported.waitForExistence(timeout: 10), "Connected screen with what was imported")
        XCTAssertTrue(imported.label.contains("Added 3 holdings"), imported.label)
        for name in ["CommSec", "Coinbase"] {
            XCTAssertTrue(app.descendants(matching: .any)["broker.institution.\(name)"].exists, "\(name) card")
        }
        attach("light-3-connected")
        let cba = app.descendants(matching: .any)["broker.position.CBA"]
        for _ in 0..<4 where !(cba.exists && cba.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(cba.exists, "Positions list")
        attach("light-4-positions")
        app.buttons["broker.done"].tap()

        // Back on Portfolio: each source with its holdings, and the imports in the list.
        let commsec = app.buttons["portfolio.account.CommSec"]
        reveal(commsec)
        XCTAssertTrue(commsec.label.contains("2 holdings"), commsec.label)
        XCTAssertTrue(app.buttons["portfolio.account.Coinbase"].label.contains("1 holding"))
        XCTAssertFalse(app.buttons["portfolio.account.connect"].exists, "No connect row once connected")
        attach("light-5-accounts-connected")
        for symbol in ["CBA", "BHP", "BTC", "AAPL"] {
            let row = app.buttons["portfolio.holding.\(symbol)"]
            for _ in 0..<5 where !row.exists { app.swipeUp(velocity: .slow) }
            XCTAssertTrue(row.exists, "\(symbol) is in the portfolio")
        }
        // Imported rows say where they come from; the holding page warns that syncs own them.
        let cbaRow = app.buttons["portfolio.holding.CBA"]
        XCTAssertTrue(cbaRow.label.contains("CommSec"), cbaRow.label)
        XCTAssertFalse(app.buttons["portfolio.holding.AAPL"].label.contains("CommSec"))
        for _ in 0..<3 where !cbaRow.isHittable { app.swipeUp(velocity: .slow) }
        cbaRow.tap()
        let note = app.descendants(matching: .any)["holding.syncedFrom"]
        for _ in 0..<6 where !note.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(note.waitForExistence(timeout: 5), "Holding page says it's synced from CommSec")
        attach("light-5b-holding-synced")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // A later sync without BHP: flagged for review, never removed silently.
        app.swipeDown(velocity: .fast); app.swipeDown(velocity: .fast)
        reveal(commsec)
        commsec.tap()
        let sync = app.buttons["broker.sync"]
        XCTAssertTrue(sync.waitForExistence(timeout: 5))
        sync.tap()
        let review = app.descendants(matching: .any)["broker.removals"]
        XCTAssertTrue(review.waitForExistence(timeout: 10), "BHP left the broker → review")
        attach("light-6-removal-review")
        app.buttons["broker.removals.remove"].tap()
        let confirm = app.sheets.buttons["Remove"].exists ? app.sheets.buttons["Remove"] : app.buttons["Remove"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(waitForDisappearance(review), "Review clears once confirmed")
        app.buttons["broker.done"].tap()
        let bhp = app.buttons["portfolio.holding.BHP"]
        XCTAssertTrue(waitForDisappearance(bhp), "BHP removed after confirming")
        XCTAssertTrue(app.buttons["portfolio.holding.AAPL"].exists || {
            for _ in 0..<5 { app.swipeUp(velocity: .slow) }
            return app.buttons["portfolio.holding.AAPL"].exists
        }(), "The holding added by hand is never touched")
    }

    /// The same screens in dark mode, for review.
    func testBrokerScreensDark() {
        app.launchArguments = ["-UITestFreshInstall", "-app_theme_mode", "Dark", "-UITestBrokerFixture"]
        app.launch()
        onboard(manualHolding: nil)
        tab("Portfolio")
        let connect = app.buttons["Connect a broker"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10), "Empty portfolio offers a broker")
        connect.tap()
        XCTAssertTrue(app.descendants(matching: .any)["broker.hero"].waitForExistence(timeout: 5))
        attach("dark-1-connect")
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'broker.popular.'")).firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["broker.import"].waitForExistence(timeout: 10))
        attach("dark-2-connected")
        app.buttons["broker.done"].tap()
        let commsec = app.buttons["portfolio.account.CommSec"]
        reveal(commsec)
        attach("dark-3-accounts")
    }

    // MARK: - Helpers

    private func onboard(manualHolding: (symbol: String, shares: String, cost: String)?) {
        XCTAssertTrue(app.buttons["onboarding.getStarted"].waitForExistence(timeout: 20))
        app.buttons["onboarding.getStarted"].tap()
        step("What do you want to track?")
        for market in ["us", "asx", "crypto"] {
            let row = app.buttons["onboarding.market.\(market)"]
            if row.exists && !row.isSelected { row.tap() }
        }
        tapContinue()
        step("Pick a few to follow")
        let pick = app.buttons["onboarding.pick.AAPL"]
        if pick.waitForExistence(timeout: 5) { pick.tap() }
        tapContinue()
        step("Add what you already own")
        if let h = manualHolding {
            app.buttons["onboarding.portfolio.manual"].tap()
            let symbolField = app.textFields["AAPL"]
            XCTAssertTrue(symbolField.waitForExistence(timeout: 5))
            symbolField.tap(); symbolField.typeText(h.symbol)
            let numbers = app.textFields.matching(identifier: "0.00")
            numbers.element(boundBy: 0).tap(); numbers.element(boundBy: 0).typeText(h.shares)
            numbers.element(boundBy: 1).tap(); numbers.element(boundBy: 1).typeText(h.cost)
            app.buttons["Add to Portfolio"].tap()
            XCTAssertTrue(app.staticTexts["1 holding added"].waitForExistence(timeout: 5))
        }
        tapContinue()
        step("Know when it moves")
        app.buttons["onboarding.notifications.notNow"].tap()
        if app.staticTexts["Keep your portfolio private"].waitForExistence(timeout: 2) { app.buttons["Not now"].tap() }
        step("Save your setup")
        app.buttons["onboarding.account.skip"].tap()
        step("You're all set")
        app.buttons["onboarding.finish"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15), "Home")
    }

    private func reveal(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(element)")
        for _ in 0..<4 where !element.isHittable { app.swipeUp(velocity: .slow) }
    }

    private func tab(_ name: String) {
        XCTAssertTrue(app.open(name), "\(name) tab")
    }

    private func step(_ title: String) {
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10), "Step: \(title)")
        let settled = expectation(for: NSPredicate(format: "count == 1"),
                                  evaluatedWith: app.staticTexts.matching(identifier: title))
        wait(for: [settled], timeout: 5)
        Thread.sleep(forTimeInterval: 0.4)
    }

    private func tapContinue() {
        let buttons = app.buttons.matching(identifier: "onboarding.continue")
        XCTAssertEqual(buttons.count, 1)
        buttons.firstMatch.tap()
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
