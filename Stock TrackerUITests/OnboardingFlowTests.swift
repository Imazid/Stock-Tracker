//
//  OnboardingFlowTests.swift
//  Stock TrackerUITests
//
//  Drives the redesigned onboarding end to end from a true first launch
//  (`-UITestFreshInstall` wipes saved data in DEBUG builds).
//

import XCTest

final class OnboardingFlowTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestFreshInstall"]
        app.launch()
    }

    /// A new user picks three stocks, skips the optional steps, and lands on a Home
    /// that shows those picks — on this launch, not the next one — and an honest,
    /// empty portfolio rather than demo holdings.
    func testNewUserLandsOnHomeWithTheirPicks() {
        let getStarted = app.buttons["onboarding.getStarted"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 15), "Welcome should show on first launch")
        attach("01-welcome")
        getStarted.tap()

        // Markets — ASX and US, whatever the device region defaulted to.
        waitForStep("What do you want to track?")
        for market in ["asx", "us"] {
            let row = app.buttons["onboarding.market.\(market)"]
            if !row.isSelected { row.tap() }
            XCTAssertTrue(row.isSelected, "\(market) should be selected")
        }
        attach("02-markets")
        tapContinue()

        // Follow — pick from both markets.
        waitForStep("Pick a few to follow")
        for symbol in ["BHP", "AAPL", "NVDA"] {
            let row = app.buttons["onboarding.pick.\(symbol)"]
            XCTAssertTrue(row.waitForExistence(timeout: 5), "\(symbol) should be in the picker")
            row.tap()
        }
        XCTAssertTrue(app.buttons["onboarding.continue"].label.contains("3"), "Continue should count the picks")
        attach("03-follow")
        tapContinue()

        // The demo changes sample value and leaves the user's portfolio empty.
        waitForStep("Add what you already own")
        app.buttons["onboarding.portfolio.demo"].tap()
        XCTAssertTrue(app.navigationBars["Portfolio demo"].waitForExistence(timeout: 8))
        let value = app.descendants(matching: .any)["onboarding.demo.value"].firstMatch
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Sample portfolio value'"), object: value)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 25), .completed)
        let initialValue = value.value as? String
        let increase = app.buttons["onboarding.demo.quantity-Increment"]
        XCTAssertTrue(increase.exists, app.debugDescription)
        increase.tap()
        XCTAssertNotEqual(value.value as? String, initialValue)
        attach("04-portfolio-demo")
        app.buttons["onboarding.demo.done"].tap()
        waitForStep("Add what you already own")
        attach("04-portfolio")
        tapContinue()

        // Alerts — decline (no system prompt in tests).
        waitForStep("Know when it moves")
        app.buttons["onboarding.notifications.notNow"].tap()

        // Face ID only appears when enrolled; skip it if present.
        if app.staticTexts["Keep your portfolio private"].waitForExistence(timeout: 2) {
            app.buttons["Not now"].tap()
        }

        // Account — keep it on this iPhone.
        waitForStep("Save your setup")
        attach("05-account")
        app.buttons["onboarding.account.skip"].tap()

        // Done.
        waitForStep("You're all set")
        let watchlistSummary = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "3 to follow")).firstMatch
        XCTAssertTrue(watchlistSummary.exists, "Summary should count the picks")
        attach("06-done")
        app.buttons["onboarding.finish"].tap()

        // Home: the picks are on the watchlist now, with live quotes.
        for symbol in ["BHP", "AAPL", "NVDA"] {
            XCTAssertTrue(app.buttons["home.watchlist.\(symbol)"].waitForExistence(timeout: 30),
                          "\(symbol) should be on Home's watchlist right after onboarding")
        }
        XCTAssertTrue(app.staticTexts["See everything you own in one place"].exists,
                      "A new user should see the empty-portfolio prompt, not demo holdings")
        XCTAssertFalse(app.descendants(matching: .any)["home.portfolio"].exists, "No portfolio summary without holdings")
        attach("07-home")
    }

    /// Adding a holding mid-onboarding (via the app's real manual-entry sheet)
    /// is reflected immediately and Home opens on the portfolio summary.
    func testHoldingAddedDuringOnboardingShowsOnHome() {
        XCTAssertTrue(app.buttons["onboarding.getStarted"].waitForExistence(timeout: 15))
        app.buttons["onboarding.getStarted"].tap()

        waitForStep("What do you want to track?")
        let us = app.buttons["onboarding.market.us"]
        if !us.isSelected { us.tap() }
        tapContinue()

        waitForStep("Pick a few to follow")
        app.buttons["onboarding.pick.AAPL"].tap()
        tapContinue()

        waitForStep("Add what you already own")
        app.buttons["onboarding.portfolio.manual"].tap()

        let symbolField = app.textFields["AAPL"]
        XCTAssertTrue(symbolField.waitForExistence(timeout: 5), "Manual entry sheet should open")
        symbolField.tap()
        symbolField.typeText("MSFT")
        let numberFields = app.textFields.matching(identifier: "0.00")
        XCTAssertEqual(numberFields.count, 2)
        numberFields.element(boundBy: 0).tap()
        numberFields.element(boundBy: 0).typeText("10")
        numberFields.element(boundBy: 1).tap()
        numberFields.element(boundBy: 1).typeText("300")
        attach("p1-manual-entry")
        app.buttons["Add to Portfolio"].tap()

        XCTAssertTrue(app.staticTexts["1 holding added"].waitForExistence(timeout: 5),
                      "Onboarding should confirm the holding")
        attach("p2-portfolio-added")
        tapContinue()

        waitForStep("Know when it moves")
        app.buttons["onboarding.notifications.notNow"].tap()
        if app.staticTexts["Keep your portfolio private"].waitForExistence(timeout: 2) {
            app.buttons["Not now"].tap()
        }
        waitForStep("Save your setup")
        app.buttons["onboarding.account.skip"].tap()
        waitForStep("You're all set")
        app.buttons["onboarding.finish"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["home.portfolio"].waitForExistence(timeout: 15),
                      "Home should lead with the portfolio summary once there are holdings")
        XCTAssertFalse(app.staticTexts["See everything you own in one place"].exists)
        Thread.sleep(forTimeInterval: 3) // let the live quote land for the screenshot
        attach("p3-home")
    }

    /// After a minimal onboarding (picks, no holdings) every tab renders —
    /// new users now start with an empty portfolio instead of demo holdings.
    func testEveryTabHandlesANewUsersEmptyPortfolio() {
        XCTAssertTrue(app.buttons["onboarding.getStarted"].waitForExistence(timeout: 15))
        app.buttons["onboarding.getStarted"].tap()
        waitForStep("What do you want to track?")
        let us = app.buttons["onboarding.market.us"]
        if !us.isSelected { us.tap() }
        tapContinue()
        waitForStep("Pick a few to follow")
        app.buttons["onboarding.pick.AAPL"].tap()
        app.buttons["onboarding.pick.NVDA"].tap()
        tapContinue()
        waitForStep("Add what you already own")
        tapContinue()
        waitForStep("Know when it moves")
        app.buttons["onboarding.notifications.notNow"].tap()
        if app.staticTexts["Keep your portfolio private"].waitForExistence(timeout: 2) { app.buttons["Not now"].tap() }
        waitForStep("Save your setup")
        app.buttons["onboarding.account.skip"].tap()
        waitForStep("You're all set")
        app.buttons["onboarding.finish"].tap()
        XCTAssertTrue(app.buttons["home.watchlist.AAPL"].waitForExistence(timeout: 30))

        for tab in ["Watchlist", "Portfolio", "News", "Search", "Agents", "Activity", "Home"] {
            XCTAssertTrue(app.open(tab, timeout: 5), "\(tab) should open")
            Thread.sleep(forTimeInterval: 2.5)
            XCTAssertEqual(app.state, .runningForeground, "App should still be running on \(tab)")
            attach("tab-\(tab)")
        }
    }

    /// Search finds curated tickers instantly and falls through to live search,
    /// always ending in results, "no matches" or a clear offline note — never a spinner.
    func testPickerSearch() {
        XCTAssertTrue(app.buttons["onboarding.getStarted"].waitForExistence(timeout: 15))
        app.buttons["onboarding.getStarted"].tap()
        waitForStep("What do you want to track?")
        for market in ["asx", "us"] {
            let row = app.buttons["onboarding.market.\(market)"]
            if !row.isSelected { row.tap() }
        }
        tapContinue()
        waitForStep("Pick a few to follow")

        let search = app.textFields["onboarding.search"]
        search.tap()
        search.typeText("tels")
        XCTAssertTrue(app.buttons["onboarding.pick.TLS"].waitForExistence(timeout: 10), "Curated match for Telstra")
        attach("s1-curated")

        app.buttons["Clear search"].tap()
        search.tap()
        search.typeText("shopify")
        // A well-known US listing must come back from live search (not just "no matches").
        let shop = app.buttons["onboarding.pick.SHOP"]
        if !shop.waitForExistence(timeout: 20) {
            let offline = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Search isn'")).count > 0
            XCTAssertTrue(offline, "Live search should find SHOP, or say it's unavailable — not 'No matches'")
        }
        let duplicates = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'onboarding.pick.' AND label CONTAINS[c] 'shopify'")).count
        XCTAssertLessThanOrEqual(duplicates, 1, "One row per company")
        attach("s2-live")
    }

    // MARK: Helpers

    private func waitForStep(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 8), "Expected step “\(title)”", file: file, line: line)
        // Let the slide transition finish so only one step's buttons are on screen.
        let settled = expectation(for: NSPredicate(format: "count == 1"),
                                  evaluatedWith: app.staticTexts.matching(identifier: title))
        wait(for: [settled], timeout: 3)
        Thread.sleep(forTimeInterval: 0.4)
    }

    private func tapContinue() {
        let buttons = app.buttons.matching(identifier: "onboarding.continue")
        XCTAssertEqual(buttons.count, 1)
        buttons.firstMatch.tap()
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
