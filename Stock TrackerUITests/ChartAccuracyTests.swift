//
//  ChartAccuracyTests.swift
//  Stock TrackerUITests
//
//  Home's portfolio chart across ranges, with scrubbing. Screenshots are
//  attached so the rendering can be checked against real prices.
//

import XCTest

final class ChartAccuracyTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestFreshInstall"]
        app.launch()
    }

    func testHomePortfolioChartRangesAndScrub() {
        onboardWithHolding(symbol: "AAPL", shares: "10", cost: "150")

        let hero = app.descendants(matching: .any)["home.portfolio"]
        XCTAssertTrue(hero.waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 4)
        attach("chart-1D")

        for (range, label) in [("1W", "1 week"), ("1M", "1 month"), ("3M", "3 months"), ("YTD", "Year to date"), ("1Y", "1 year")] {
            let button = app.buttons[label]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "\(range) range button")
            button.tap()
            Thread.sleep(forTimeInterval: 3.5)
            attach("chart-\(range)")
        }

        // Scrub: press and drag along the chart. (Selection is verified from the
        // DEBUG "CHARTSCRUB" log — it clears when the finger lifts.)
        let chart = app.descendants(matching: .any)["chart.price"].firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 5))
        let start = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        let end = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5))
        start.press(forDuration: 0.4, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 2.0)
        attach("chart-scrub-after")
    }

    /// Home in light mode, top and scrolled, for a visual check.
    func testHomeLightMode() {
        app.terminate()
        app.launchArguments = ["-UITestFreshInstall", "-app_theme_mode", "Light"]
        app.launch()
        onboardWithHolding(symbol: "AAPL", shares: "10", cost: "150")
        XCTAssertTrue(app.descendants(matching: .any)["home.portfolio"].waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 5)
        attach("light-home-top")
        app.swipeUp()
        Thread.sleep(forTimeInterval: 3)
        attach("light-home-scrolled")
    }

    // MARK: Helpers

    private func onboardWithHolding(symbol: String, shares: String, cost: String) {
        XCTAssertTrue(app.buttons["onboarding.getStarted"].waitForExistence(timeout: 15))
        app.buttons["onboarding.getStarted"].tap()
        step("What do you want to track?")
        let us = app.buttons["onboarding.market.us"]
        if !us.isSelected { us.tap() }
        tapContinue()
        step("Pick a few to follow")
        app.buttons["onboarding.pick.NVDA"].tap()
        tapContinue()
        step("Add what you already own")
        app.buttons["onboarding.portfolio.manual"].tap()
        let symbolField = app.textFields["AAPL"]
        XCTAssertTrue(symbolField.waitForExistence(timeout: 5))
        symbolField.tap(); symbolField.typeText(symbol)
        let numbers = app.textFields.matching(identifier: "0.00")
        numbers.element(boundBy: 0).tap(); numbers.element(boundBy: 0).typeText(shares)
        numbers.element(boundBy: 1).tap(); numbers.element(boundBy: 1).typeText(cost)
        app.buttons["Add to Portfolio"].tap()
        XCTAssertTrue(app.staticTexts["1 holding added"].waitForExistence(timeout: 5))
        tapContinue()
        step("Know when it moves")
        app.buttons["onboarding.notifications.notNow"].tap()
        if app.staticTexts["Keep your portfolio private"].waitForExistence(timeout: 2) { app.buttons["Not now"].tap() }
        step("Save your setup")
        app.buttons["onboarding.account.skip"].tap()
        step("You're all set")
        app.buttons["onboarding.finish"].tap()
    }

    private func step(_ title: String) {
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 8), "Expected “\(title)”")
        Thread.sleep(forTimeInterval: 0.6)
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
