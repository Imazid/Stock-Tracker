//
//  MotionTests.swift
//  Stock TrackerUITests
//
//  The motion kit with motion left on (`-UITestKeepMotion`): screenshots taken
//  mid-animation — confetti on "You're all set", Home's sections rising in, a chart
//  drawing in after a range change, confetti when a broker's holdings arrive —
//  and the app still answering taps afterwards. Opt-in, because frame timing
//  depends on the machine: `TEST_RUNNER_RUN_MOTION=1`.
//

import XCTest

final class MotionTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_MOTION"] == "1",
                          "Motion captures run only with TEST_RUNNER_RUN_MOTION=1")
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestFreshInstall", "-UITestKeepMotion", "-app_theme_mode", "Light",
                               "-UITestBrokerFixture"]
    }

    func testMotionMoments() {
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.getStarted"].waitForExistence(timeout: 20))
        app.buttons["onboarding.getStarted"].tap()
        step("What do you want to track?")
        for market in ["us", "asx", "crypto"] {
            let row = app.buttons["onboarding.market.\(market)"]
            if row.exists && !row.isSelected { row.tap() }
        }
        app.buttons.matching(identifier: "onboarding.continue").firstMatch.tap()
        step("Pick a few to follow")
        for symbol in ["AAPL", "BHP"] {
            let row = app.buttons["onboarding.pick.\(symbol)"]
            if row.waitForExistence(timeout: 5) { row.tap() }
        }
        app.buttons.matching(identifier: "onboarding.continue").firstMatch.tap()
        step("Add what you already own")
        app.buttons.matching(identifier: "onboarding.continue").firstMatch.tap()
        step("Know when it moves")
        app.buttons["onboarding.notifications.notNow"].tap()
        if app.staticTexts["Keep your portfolio private"].waitForExistence(timeout: 2) { app.buttons["Not now"].tap() }
        step("Save your setup")
        app.buttons["onboarding.account.skip"].tap()

        // "You're all set": check pops, confetti falls, rows rise in.
        XCTAssertTrue(app.staticTexts["You're all set"].waitForExistence(timeout: 10))
        capture("motion-1-done-0.3s", after: 0.3)
        capture("motion-2-done-1.0s", after: 0.7)
        capture("motion-3-done-settled", after: 2.5)

        app.buttons["onboarding.finish"].tap()
        // Home: sections rising in.
        capture("motion-4-home-0.2s", after: 0.2)
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15))
        capture("motion-5-home-settled", after: 2.0)

        // Portfolio → connect a broker → holdings arrive with confetti.
        let portfolioTab = app.tabBars.buttons["Portfolio"].exists ? app.tabBars.buttons["Portfolio"] : app.buttons["Portfolio"].firstMatch
        portfolioTab.tap()
        let connect = app.buttons["Connect a broker"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        connect.tap()
        XCTAssertTrue(app.descendants(matching: .any)["broker.hero"].waitForExistence(timeout: 5))
        capture("motion-6-connect-tiles", after: 0.15)
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'broker.popular.'")).firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["broker.import"].waitForExistence(timeout: 10))
        capture("motion-7-imported-confetti", after: 0.4)
        capture("motion-8-imported-settled", after: 3.0)
        app.buttons["broker.done"].tap()

        // Portfolio chart: switch range, catch it drawing in.
        let week = app.buttons["1 week"].firstMatch
        if week.waitForExistence(timeout: 10) {
            Thread.sleep(forTimeInterval: 2)
            week.tap()
            capture("motion-9-chart-drawing", after: 0.25)
            capture("motion-10-chart-drawn", after: 1.5)
        }
        // Still responsive after all of it.
        XCTAssertTrue(app.buttons["portfolio.add"].isHittable)
    }

    private func capture(_ name: String, after seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func step(_ title: String) {
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10), "Step: \(title)")
        Thread.sleep(forTimeInterval: 0.6)
    }
}
