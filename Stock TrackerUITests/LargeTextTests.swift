//
//  LargeTextTests.swift
//  Stock TrackerUITests
//
//  The main screens at an accessibility text size (AX L): nothing clipped, no rows
//  collapsing into unreadable truncation. Screenshots for review.
//

import XCTest

final class LargeTextTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestFreshInstall", "-app_theme_mode", "Light",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
    }

    func testMainScreensAtAccessibilityTextSize() {
        app.launch()
        let getStarted = app.buttons["onboarding.getStarted"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 20))
        attach("ax-onboarding-welcome")
        getStarted.tap()
        waitForStep("What do you want to track?")
        for market in ["asx", "us", "crypto"] {
            let row = app.buttons["onboarding.market.\(market)"]
            for _ in 0..<4 where !(row.exists && row.isHittable) { app.swipeUp(velocity: .slow) }
            if row.exists && !row.isSelected { row.tap() }
        }
        attach("ax-onboarding-markets")
        tapContinue()
        waitForStep("Pick a few to follow")
        for symbol in ["AAPL", "BHP", "BTC"] {
            let row = app.buttons["onboarding.pick.\(symbol)"]
            for _ in 0..<8 where !(row.exists && row.isHittable) { app.swipeUp(velocity: .slow) }
            if row.exists { row.tap() }
        }
        tapContinue()
        waitForStep("Add what you already own")
        tapContinue()
        waitForStep("Know when it moves")
        let notNow = app.buttons["onboarding.notifications.notNow"]
        for _ in 0..<4 where !(notNow.exists && notNow.isHittable) { app.swipeUp(velocity: .slow) }
        if notNow.exists { notNow.tap() } else { tapContinue() }
        if app.staticTexts["Keep your portfolio private"].waitForExistence(timeout: 2) { app.buttons["Not now"].tap() }
        waitForStep("Save your setup")
        let skip = app.buttons["onboarding.account.skip"]
        for _ in 0..<4 where !(skip.exists && skip.isHittable) { app.swipeUp(velocity: .slow) }
        skip.tap()
        waitForStep("You're all set")
        app.buttons["onboarding.finish"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15))
        _ = app.buttons["home.watchlist.AAPL"].waitForExistence(timeout: 20)
        Thread.sleep(forTimeInterval: 2)
        attach("ax-home-top")
        app.swipeUp(velocity: .slow)
        attach("ax-home-lower")

        tab("Watchlist"); Thread.sleep(forTimeInterval: 2); attach("ax-watchlist")
        tab("Portfolio"); Thread.sleep(forTimeInterval: 2); attach("ax-portfolio")
        tab("News"); Thread.sleep(forTimeInterval: 3); attach("ax-news")
        tab("Search"); Thread.sleep(forTimeInterval: 2); attach("ax-search")

        tab("Watchlist")
        let row = app.buttons["watchlist.row.AAPL"]
        if row.waitForExistence(timeout: 10) {
            row.tap()
            XCTAssertTrue(app.descendants(matching: .any)["detail.screen"].waitForExistence(timeout: 10))
            Thread.sleep(forTimeInterval: 3)
            attach("ax-detail-top")
            app.swipeUp(velocity: .slow)
            attach("ax-detail-stats")
        }
    }

    // MARK: - Helpers

    private func tab(_ name: String) {
        let button = app.tabBars.buttons[name].exists ? app.tabBars.buttons[name] : app.buttons[name].firstMatch
        if button.waitForExistence(timeout: 5) { button.tap() }
    }

    private func waitForStep(_ title: String) {
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10), "Step: \(title)")
        let settled = expectation(for: NSPredicate(format: "count == 1"),
                                  evaluatedWith: app.staticTexts.matching(identifier: title))
        wait(for: [settled], timeout: 5)
        Thread.sleep(forTimeInterval: 0.4)
    }

    private func tapContinue() {
        let button = app.buttons.matching(identifier: "onboarding.continue").firstMatch
        for _ in 0..<4 where !(button.exists && button.isHittable) { app.swipeUp(velocity: .slow) }
        button.tap()
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
