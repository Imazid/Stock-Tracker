//
//  EnhancementTests.swift
//  Stock TrackerUITests
//
//  "Coming up" earnings, deep links from widgets/notifications/Siri, and Home Screen
//  quick actions.
//

import XCTest

final class EnhancementTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestFreshInstall", "-app_theme_mode", "Light"]
    }

    /// AAPL (followed in onboarding) reports within 30 days, so Home lists it under
    /// "Coming up"; its stock page shows the next report with a reminder button.
    func testComingUpEarningsOnHomeAndStockPage() {
        onboard(picks: ["AAPL"])
        let section = app.descendants(matching: .any)["home.comingUp"]
        for _ in 0..<6 where !section.exists { app.swipeUp(velocity: .slow); Thread.sleep(forTimeInterval: 1) }
        XCTAssertTrue(section.waitForExistence(timeout: 30), "Coming up should list upcoming earnings")
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'earnings.row.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("reports earnings"), row.label)
        attach("home-coming-up")
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["detail.screen"].waitForExistence(timeout: 10), "Stock page opens")
        let next = app.descendants(matching: .any)["detail.nextEarnings"]
        for _ in 0..<6 where !(next.exists && next.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(next.waitForExistence(timeout: 15), "Stock page shows the next report")
        XCTAssertTrue(app.buttons["detail.earnings.remind"].exists, "Remind me is offered")
        attach("detail-next-earnings")
    }

    /// Widget/notification/Siri links: stocktracker://asset/SYM opens that stock's page
    /// (it used to only switch tabs), stocktracker://alerts opens the alerts list.
    func testDeepLinksOpenStockPageAndAlerts() {
        onboard(picks: ["AAPL"])
        XCUIDevice.shared.system.open(URL(string: "stocktracker://asset/MSFT")!)
        XCTAssertTrue(app.descendants(matching: .any)["detail.screen"].waitForExistence(timeout: 15),
                      "A stock link opens the stock's page")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'MSFT'")).firstMatch.exists)
        attach("deeplink-msft")
        app.buttons["detail.close"].tap()

        XCUIDevice.shared.system.open(URL(string: "stocktracker://alerts")!)
        XCTAssertTrue(app.staticTexts["Price alerts"].waitForExistence(timeout: 10), "The alerts link opens alerts")
        attach("deeplink-alerts")
    }

    /// Long-press the app icon on the Home Screen → "Search" opens the Search tab.
    func testHomeScreenQuickActionOpensSearch() throws {
        onboard(picks: ["AAPL"])
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // The icon can appear more than once (Home Screen page + App Library); use a visible one.
        let icons = springboard.icons.matching(identifier: "Stock Tracker")
        var icon: XCUIElement? = nil
        for _ in 0..<5 {
            icon = icons.allElementsBoundByIndex.first { $0.isHittable }
            if icon != nil { break }
            springboard.swipeLeft()
        }
        let target = try XCTUnwrap(icon, "App icon not found on the Home Screen")
        // Acting on a SpringBoard element waits for SpringBoard to go idle, and on iOS 27 that
        // signal doesn't come around the long-press menu (the lost-didStop problem the app works
        // around in test mode, but in Apple's process): the press and the tap each waited 60 s.
        // The press goes through the app's screen coordinates, which don't wait on SpringBoard.
        // The tap can't: with the menu up, XCUITest brings the app forward before a coordinate
        // gesture, closing the menu — so "Search" is still tapped as SpringBoard's (one wait).
        let iconPoint = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: target.frame.midX, dy: target.frame.midY))
        iconPoint.press(forDuration: 1.5)
        let search = springboard.buttons["Search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), "Quick actions should include Search")
        attach("quick-actions", from: springboard)
        search.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 10), "Search tab should be open")
        attach("quick-action-search")
    }

    // MARK: - Helpers

    private func onboard(picks: [String]) {
        app.launch()
        let getStarted = app.buttons["onboarding.getStarted"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 20))
        getStarted.tap()
        waitForStep("What do you want to track?")
        for market in ["asx", "us", "crypto"] {
            let row = app.buttons["onboarding.market.\(market)"]
            if row.exists && !row.isSelected { row.tap() }
        }
        tapContinue()
        waitForStep("Pick a few to follow")
        for symbol in picks {
            let row = app.buttons["onboarding.pick.\(symbol)"]
            for _ in 0..<6 where !(row.exists && row.isHittable) { app.swipeUp(velocity: .slow) }
            if row.exists { row.tap() }
        }
        tapContinue()
        waitForStep("Add what you already own")
        tapContinue()
        waitForStep("Know when it moves")
        let notNow = app.buttons["onboarding.notifications.notNow"]
        if notNow.exists { notNow.tap() } else { tapContinue() }
        if app.staticTexts["Keep your portfolio private"].waitForExistence(timeout: 2) { app.buttons["Not now"].tap() }
        waitForStep("Save your setup")
        app.buttons["onboarding.account.skip"].tap()
        waitForStep("You're all set")
        app.buttons["onboarding.finish"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15), "Home should appear")
    }

    private func waitForStep(_ title: String) {
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

    private func attach(_ name: String, from target: XCUIApplication? = nil) {
        let shot = XCTAttachment(screenshot: (target ?? app).screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
