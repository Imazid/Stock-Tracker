//
//  LiveBrokerTests.swift
//  Stock TrackerUITests
//
//  The real SnapTrade path, no fixture: tapping a broker registers with SnapTrade,
//  asks for a connection portal and opens it — everything up to the broker's own
//  sign-in, which needs the person's credentials. Opt-in (`TEST_RUNNER_RUN_LIVE_BROKER=1`)
//  because each run registers a SnapTrade user on the app's SnapTrade account.
//

import XCTest

final class LiveBrokerTests: XCTestCase {
    /// SnapTrade's Sandbox broker, end to end: sign in on the portal → back in the app the
    /// sandbox account's positions sync and import → Disconnect deletes it at SnapTrade.
    func testSandboxConnectionImportsHoldings() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_LIVE_BROKER"] == "1",
                          "Live broker test runs only with TEST_RUNNER_RUN_LIVE_BROKER=1")
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = ["-UITestFreshInstall", "-app_theme_mode", "Light"]
        app.launch()
        skipOnboarding(app)

        let portfolioTab = app.tabBars.buttons["Portfolio"].exists ? app.tabBars.buttons["Portfolio"] : app.buttons["Portfolio"].firstMatch
        portfolioTab.tap()
        let connect = app.buttons["Connect a broker"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        connect.tap()
        XCTAssertTrue(app.buttons["broker.seeAll"].waitForExistence(timeout: 10))
        app.buttons["broker.seeAll"].tap()
        let sandbox = app.buttons["broker.pick.SANDBOX"]
        for _ in 0..<8 where !sandbox.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(sandbox.waitForExistence(timeout: 10), "SnapTrade Sandbox listed (DEBUG)")
        sandbox.tap()

        let portal = app.webViews.firstMatch
        XCTAssertTrue(portal.waitForExistence(timeout: 30), "Portal opened")
        Thread.sleep(forTimeInterval: 6)
        snap("sandbox-1-portal")
        print("PORTALTREE-1 \(portal.debugDescription)")

        // Consent → the sandbox "broker" sign-in.
        let consent = portal.buttons["Continue"]
        XCTAssertTrue(consent.waitForExistence(timeout: 10), "SnapTrade consent")
        consent.tap()
        Thread.sleep(forTimeInterval: 6)
        snap("sandbox-2-after-consent")

        // Default scenario: "Self-directed — two funded accounts with positions".
        let link = portal.buttons["Connect"]
        XCTAssertTrue(link.waitForExistence(timeout: 10), "Sandbox scenario screen")
        link.tap()
        Thread.sleep(forTimeInterval: 8)
        snap("sandbox-3-after-connect")
        print("PORTALTREE-3 \(portal.debugDescription)")

        // Close Safari with its own Close (top-left), not the page's.
        let closes = app.buttons.matching(NSPredicate(format: "label == 'Close'")).allElementsBoundByIndex.filter(\.exists)
        let safariClose = closes.min { $0.frame.minX < $1.frame.minX }
        XCTAssertNotNil(safariClose, "Safari's Close")
        safariClose?.tap()

        // Back in the app: accounts sync, positions import (SnapTrade's first sync can lag — retry).
        let imported = app.descendants(matching: .any)["broker.import"]
        for _ in 0..<8 where !imported.exists {
            if !imported.waitForExistence(timeout: 8), app.buttons["broker.sync"].exists, app.buttons["broker.sync"].isEnabled {
                app.buttons["broker.sync"].tap()
            }
        }
        XCTAssertTrue(imported.exists, "Holdings arrived from the sandbox")
        print("IMPORTLABEL \(imported.label)")
        snap("sandbox-4-imported")
        let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'broker.institution.'"))
        XCTAssertGreaterThan(cards.count, 0, "Institution card")
        print("INSTITUTIONS \(cards.allElementsBoundByIndex.map(\.identifier))")
        let positions = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'broker.position.'"))
        print("POSITIONS \(positions.allElementsBoundByIndex.map(\.label))")
        XCTAssertGreaterThan(positions.count, 0, "Positions listed")

        // Portfolio: the sandbox shows as an account with its holdings.
        app.buttons["broker.done"].tap()
        let excluded = ["portfolio.account.manual", "portfolio.account.connect", "portfolio.account.review", "portfolio.account.brokers"]
        let account = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'portfolio.account.' AND NOT (identifier IN %@)", excluded)).firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 10), "Broker row in Accounts")
        for _ in 0..<3 where !account.isHittable { app.swipeUp(velocity: .slow) }
        print("ACCOUNTROW \(account.label)")
        snap("sandbox-5-portfolio")

        // Disconnect → deleted at SnapTrade (no "Couldn't disconnect"), back to not connected.
        account.tap()
        let disconnect = app.buttons["broker.disconnect"]
        for _ in 0..<6 where !(disconnect.exists && disconnect.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(disconnect.waitForExistence(timeout: 5))
        disconnect.tap()
        let confirm = app.sheets.buttons["Disconnect"].exists ? app.sheets.buttons["Disconnect"] : app.buttons.matching(NSPredicate(format: "label == 'Disconnect'")).element(boundBy: 1)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.descendants(matching: .any)["broker.hero"].waitForExistence(timeout: 20), "Back to not connected")
        XCTAssertFalse(app.alerts["Couldn't disconnect"].exists, "Deleted at SnapTrade")
        snap("sandbox-6-disconnected")
    }

    private func skipOnboarding(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["onboarding.getStarted"].waitForExistence(timeout: 20))
        app.buttons["onboarding.getStarted"].tap()
        XCTAssertTrue(app.staticTexts["What do you want to track?"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 0.6)
        for market in ["us", "asx", "crypto"] {
            let row = app.buttons["onboarding.market.\(market)"]
            if row.exists && !row.isSelected { row.tap() }
        }
        app.buttons.matching(identifier: "onboarding.continue").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Pick a few to follow"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 0.6)
        app.buttons["onboarding.pick.AAPL"].tap()
        app.buttons.matching(identifier: "onboarding.continue").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Add what you already own"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 0.6)
        app.buttons.matching(identifier: "onboarding.continue").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Know when it moves"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 0.6)
        app.buttons["onboarding.notifications.notNow"].tap()
        if app.staticTexts["Keep your portfolio private"].waitForExistence(timeout: 2) { app.buttons["Not now"].tap() }
        XCTAssertTrue(app.staticTexts["Save your setup"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 0.6)
        app.buttons["onboarding.account.skip"].tap()
        XCTAssertTrue(app.staticTexts["You're all set"].waitForExistence(timeout: 10))
        app.buttons["onboarding.finish"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15))
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testConnectOpensTheBrokersSignInThroughSnapTrade() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_LIVE_BROKER"] == "1",
                          "Live broker test runs only with TEST_RUNNER_RUN_LIVE_BROKER=1")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-UITestFreshInstall", "-app_theme_mode", "Light"]
        app.launch()

        XCTAssertTrue(app.buttons["onboarding.getStarted"].waitForExistence(timeout: 20))
        app.buttons["onboarding.getStarted"].tap()
        XCTAssertTrue(app.staticTexts["What do you want to track?"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 0.6)
        for market in ["us", "asx", "crypto"] {
            let row = app.buttons["onboarding.market.\(market)"]
            if row.exists && !row.isSelected { row.tap() }
        }
        app.buttons.matching(identifier: "onboarding.continue").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Pick a few to follow"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 0.6)
        app.buttons["onboarding.pick.AAPL"].tap()
        app.buttons.matching(identifier: "onboarding.continue").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Add what you already own"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 0.6)

        // Onboarding's own "Connect a broker" → the Brokers screen → a popular broker.
        let broker = app.buttons["onboarding.portfolio.broker"]
        XCTAssertTrue(broker.waitForExistence(timeout: 5))
        broker.tap()
        let tile = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'broker.popular.'")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "Brokers screen")
        let tileName = tile.label
        tile.tap()

        // Success = SnapTrade's portal opens in Safari; failure = the "Couldn't connect" alert.
        let failed = app.alerts["Couldn't connect"]
        let portal = app.webViews.firstMatch
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline && !failed.exists && !portal.exists { Thread.sleep(forTimeInterval: 0.5) }
        Thread.sleep(forTimeInterval: 4)   // let the portal page render for the screenshot
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "live-broker-portal"
        shot.lifetime = .keepAlways
        add(shot)

        if failed.exists {
            XCTFail("SnapTrade refused (\(tileName)): \(failed.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "))")
        }
        XCTAssertTrue(portal.exists, "SnapTrade's connection portal opened for \(tileName)")

        // Back out without signing in, then "Start over": the half-made SnapTrade user is
        // deleted at SnapTrade (DELETE /snapTrade/deleteUser) — also cleans up after this test.
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), "Safari's Close button")
        close.tap()
        let startOver = app.buttons["broker.startOver"]
        XCTAssertTrue(startOver.waitForExistence(timeout: 15), "Unfinished connection offers Start over")
        startOver.tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: startOver)
        wait(for: [gone], timeout: 20)
        XCTAssertFalse(app.alerts["Couldn't disconnect"].exists, "SnapTrade deleted the user")
    }
}
