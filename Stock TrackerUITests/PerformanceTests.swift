//
//  PerformanceTests.swift
//  Stock TrackerUITests
//
//  Performance baselines on the simulator. Each test onboards a fresh install with ten
//  picks (US, ASX and crypto — the free plan's limit), so Home and the Watchlist have
//  real rows to scroll, then measures one thing. Numbers are comparable run to run on
//  the same simulator; they are not device numbers.
//

import XCTest

final class PerformanceTests: XCTestCase {
    private var app: XCUIApplication!
    // Six that are on screen without scrolling: further down, rows sit under the pinned
    // "Continue with N" footer and a tap there lands on Continue instead.
    private let picks = ["BTC", "ETH", "BHP", "AAPL", "CBA", "NVDA"]

    /// ~20 minutes of measuring, so they're opt-in and the regular UI suite skips them:
    /// `TEST_RUNNER_RUN_PERF=1 xcodebuild test … -only-testing:"Stock TrackerUITests/PerformanceTests"`
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_PERF"] == "1",
                          "Performance tests run only with TEST_RUNNER_RUN_PERF=1")
        continueAfterFailure = false
        app = XCUIApplication()
    }

    // MARK: Launch

    /// Process launch to first responsive frame (Apple's launch metric).
    func testLaunchMetric() {
        onboardFreshInstall()
        app.terminate()
        app.launchArguments = []
        let options = XCTMeasureOptions()
        options.iterationCount = 10
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            app.launch()
        }
    }

    /// Launch until Home's watchlist rows are on screen with a price.
    func testLaunchToPricedHome() {
        onboardFreshInstall()
        app.terminate()
        app.launchArguments = []
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        options.invocationOptions = [.manuallyStop]
        measure(metrics: [XCTClockMetric()], options: options) {
            app.launch()
            let row = app.buttons["home.watchlist.AAPL"]
            XCTAssertTrue(row.waitForExistence(timeout: 30), "AAPL row on Home")
            let priced = expectation(for: NSPredicate(format: "label CONTAINS '$'"), evaluatedWith: row)
            wait(for: [priced], timeout: 30)
            stopMeasuring()
            app.terminate()
        }
    }

    // MARK: Scrolling

    func testScrollHome() {
        onboardFreshInstall()
        Thread.sleep(forTimeInterval: 5)   // let logos and sparklines settle
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        options.invocationOptions = [.manuallyStop]
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            app.swipeUp(velocity: .fast)
            stopMeasuring()
            app.swipeDown(velocity: .fast)
        }
    }

    func testScrollWatchlist() {
        onboardFreshInstall()
        tab("Watchlist")
        XCTAssertTrue(app.buttons["watchlist.row.AAPL"].waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 5)
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        options.invocationOptions = [.manuallyStop]
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            app.swipeUp(velocity: .fast)
            stopMeasuring()
            app.swipeDown(velocity: .fast)
        }
    }

    // MARK: Stock page

    /// Open AAPL, then time each range switch until the change label says that range.
    /// Logs PERF lines: first visit (network) and second visit (cache).
    func testChartRangeSwitching() {
        onboardFreshInstall()
        let row = app.buttons["home.watchlist.AAPL"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        var start = Date()
        row.tap()
        XCTAssertTrue(app.descendants(matching: .any)["detail.chart"].waitForExistence(timeout: 20))
        waitNoChartLoading()
        log("open-detail", Date().timeIntervalSince(start))

        let ranges: [(button: String, period: String)] = [
            ("1 week", "Past week"), ("1 month", "Past month"), ("3 months", "Past 3 months"),
            ("1 year", "Past year"), ("5 years", "Past 5 years"), ("1 day", "Today")
        ]
        for pass in ["first", "cached"] {
            for (button, period) in ranges {
                let control = app.buttons[button].firstMatch
                XCTAssertTrue(control.waitForExistence(timeout: 5), button)
                start = Date()
                control.tap()
                // Poll every 50ms (an NSPredicate expectation polls ~1s and hid the difference).
                let change = app.descendants(matching: .any)["detail.change"].firstMatch
                let deadline = Date().addingTimeInterval(25)
                while !change.label.contains(period) && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                waitNoChartLoading()
                log("range-\(pass)-\(period)", Date().timeIntervalSince(start))
            }
        }
    }

    // MARK: Memory and CPU

    func testMemoryAfterEveryTab() {
        onboardFreshInstall()
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTMemoryMetric(application: app)], options: options) {
            for name in ["Watchlist", "Portfolio", "News", "Search", "Home"] {
                tab(name)
                Thread.sleep(forTimeInterval: 2)
            }
        }
    }

    /// Sitting on Home with nothing animating should cost ~0% CPU.
    func testIdleCPUOnHome() {
        onboardFreshInstall()
        Thread.sleep(forTimeInterval: 10)   // first refresh finishes
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTCPUMetric(application: app)], options: options) {
            Thread.sleep(forTimeInterval: 15)
        }
    }

    // MARK: Network

    /// Walks a typical session and prints timestamped markers; NETREQ log lines from the
    /// app (DEBUG) are bucketed between markers to count requests per screen.
    func testNetworkTrace() {
        mark("start")
        onboardFreshInstall()
        mark("home-shown")
        Thread.sleep(forTimeInterval: 20)
        mark("home-settled")
        tab("Watchlist")
        Thread.sleep(forTimeInterval: 10)
        mark("watchlist-settled")
        tab("Home")
        Thread.sleep(forTimeInterval: 5)
        mark("home-again")
        app.buttons["home.watchlist.AAPL"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["detail.chart"].waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 12)
        mark("detail-open")
        app.buttons["detail.close"].tap()
        Thread.sleep(forTimeInterval: 2)
        app.buttons["home.watchlist.AAPL"].tap()
        Thread.sleep(forTimeInterval: 12)
        mark("detail-reopen")
        app.buttons["detail.close"].tap()
        tab("News")
        Thread.sleep(forTimeInterval: 8)
        mark("news")
        tab("Portfolio")
        Thread.sleep(forTimeInterval: 5)
        mark("portfolio")
        app.terminate()
        mark("relaunch")
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.buttons["home.watchlist.AAPL"].waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 20)
        mark("relaunch-settled")
    }

    private func mark(_ name: String) {
        print("MARK \(name) \(Date().timeIntervalSince1970)")
    }

    // MARK: Helpers

    private func onboardFreshInstall() {
        app.launchArguments = ["-UITestFreshInstall"]
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
            XCTAssertTrue(row.waitForExistence(timeout: 5), "\(symbol) in the picker")
            row.tap()
        }
        XCTAssertEqual(app.buttons["onboarding.continue"].label, "Continue with \(picks.count)")
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
        let finished = Date()
        app.buttons["onboarding.finish"].tap()
        // Time until every pick is on Home (each joins once its quote loads).
        var missing = Set(picks)
        while !missing.isEmpty && Date().timeIntervalSince(finished) < 120 {
            for symbol in missing where app.buttons["home.watchlist.\(symbol)"].exists {
                missing.remove(symbol)
                log("pick-\(symbol)-on-home", Date().timeIntervalSince(finished))
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        log("all-picks-on-home", Date().timeIntervalSince(finished))
        XCTAssertTrue(missing.isEmpty, "Picks still missing from Home after 120s: \(missing.sorted())")
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

    private func tab(_ name: String) {
        XCTAssertTrue(app.open(name, timeout: 5), "Tab \(name)")
    }

    private func waitNoChartLoading(timeout: TimeInterval = 25) {
        let loading = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Loading chart'"))
        let deadline = Date().addingTimeInterval(timeout)
        while loading.count > 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    }

    private func log(_ name: String, _ seconds: TimeInterval) {
        print(String(format: "PERF %@ %.2fs", name, seconds))
    }
}
