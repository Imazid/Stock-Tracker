//
//  DetailScreenTests.swift
//  Stock TrackerUITests
//
//  The stock / crypto / index detail screen: one scroll with header, chart,
//  ranges, position prompt, stats and listing-appropriate sections; actions
//  (watchlist, alert, add to portfolio); Pro candles. Starts from a true first
//  launch so every run sees the same empty portfolio and three follows.
//

import XCTest

final class DetailScreenTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    // MARK: - Tests

    /// US stock: real header + chart, every range answers (chart or honest error),
    /// scrubbing hands the price back, the page scrolls to stats and about.
    func testUSStockDetail() {
        launchAndOnboard(theme: "Light")
        openFromHome("AAPL")

        XCTAssertTrue(app.staticTexts["detail.price"].firstMatch.waitForExistence(timeout: 10), "Price should show")
        XCTAssertTrue(identityLabel.contains("AAPL"), "Identity should name the ticker: \(identityLabel)")
        XCTAssertTrue(waitForChart(), "1D chart (or an honest error) should appear")
        attach("aapl-1D-light")

        for range in ["1 week", "1 month", "Year to date", "1 year", "5 years", "1 day"] {
            let button = app.buttons[range]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "\(range) range button")
            button.tap()
            XCTAssertTrue(waitForChart(), "\(range) should load a chart or say it's unavailable")
            if range == "1 year" { attach("aapl-1Y-light") }
        }

        // Scrub: press and drag along the chart; the live price comes back on release.
        let before = app.staticTexts["detail.price"].firstMatch.label
        let chart = chartElement
        let start = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        let end = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
        start.press(forDuration: 0.5, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(waitFor(app.staticTexts["detail.price"].firstMatch, label: before, timeout: 4),
                      "Releasing the scrub should restore the live price")

        // Stop with the stats card in view (two fixed swipes overshot it into Earnings).
        let stats = app.descendants(matching: .any)["detail.stats"].firstMatch
        for _ in 0..<6 where !(stats.exists && stats.frame.minY < app.frame.height * 0.45) {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(stats.waitForExistence(timeout: 5), "Key statistics")
        Thread.sleep(forTimeInterval: 1)
        attach("aapl-stats-light")
        let more = app.buttons["detail.stats.more"]
        if more.exists && more.isHittable {
            more.tap()
            Thread.sleep(forTimeInterval: 1)
            attach("aapl-stats-all-light")
        }
        scrollDown(times: 3)
        attach("aapl-lower-light")
        XCTAssertTrue(app.descendants(matching: .any)["detail.financials"].exists, "US stocks show Financials")
        XCTAssertTrue(app.buttons["detail.financials.unlock"].exists, "Free plan sees the Pro lock")
        XCTAssertTrue(app.descendants(matching: .any)["detail.sources"].exists, "Sources note at the bottom")
    }

    /// Watchlist toggle with confirmation, alert sheet, add-to-portfolio sheet,
    /// and the Pro gate on candles.
    func testActions() {
        launchAndOnboard(theme: "Dark")
        openFromHome("AAPL")
        XCTAssertTrue(app.staticTexts["detail.price"].firstMatch.waitForExistence(timeout: 10))

        // Watchlist: toggle twice from whatever state it starts in (AAPL was picked in
        // onboarding, but it only joins the watchlist once its quote loads).
        let star = app.buttons["detail.watchlist"]
        XCTAssertTrue(star.waitForExistence(timeout: 5))
        let startsWatched = star.label == "Remove from Watchlist"
        let flipped = startsWatched ? "Add to Watchlist" : "Remove from Watchlist"
        let original = startsWatched ? "Remove from Watchlist" : "Add to Watchlist"
        let toast = app.descendants(matching: .any)["detail.toast"].firstMatch
        star.tap()
        XCTAssertTrue(toast.waitForExistence(timeout: 2), "The change is confirmed on screen")
        XCTAssertTrue(waitFor(star, label: flipped, timeout: 3), "Star should flip")
        star.tap()
        let confirmation = startsWatched ? "Added to Watchlist" : "Removed from Watchlist"
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", confirmation))
                        .firstMatch.waitForExistence(timeout: 2), "The second change is confirmed too")
        XCTAssertTrue(waitFor(star, label: original, timeout: 3), "Star should flip back")
        attach("aapl-watch-toast-dark")

        // Price alert sheet opens and cancels.
        app.buttons["detail.alert"].tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "Alert sheet should open")
        attach("aapl-alert-sheet-dark")
        cancel.tap()
        XCTAssertTrue(app.staticTexts["detail.price"].firstMatch.waitForExistence(timeout: 5))

        // Add to portfolio from the "Own AAPL?" prompt.
        let add = app.buttons["detail.position.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "Own-it prompt for a stock you don't hold")
        add.tap()
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 5), "Add-to-portfolio sheet should open")
        attach("aapl-add-portfolio-dark")
        app.buttons["Cancel"].firstMatch.tap()

        // …or bring it in from a broker (Yahoo's "Link broker").
        let link = app.buttons["detail.position.linkBroker"]
        XCTAssertTrue(link.waitForExistence(timeout: 5), "Own-it prompt offers linking a broker")
        link.tap()
        XCTAssertTrue(app.descendants(matching: .any)["broker.hero"].waitForExistence(timeout: 5), "Brokers screen opens")
        // SnapTrade's live directory (read-only, no user created): real slugs + logos.
        Thread.sleep(forTimeInterval: 3)
        attach("broker-connect-live")
        app.buttons["broker.seeAll"].tap()
        XCTAssertTrue(app.navigationBars["Choose your broker"].waitForExistence(timeout: 5), "Full list")
        Thread.sleep(forTimeInterval: 2)
        attach("broker-picker-live")
        app.navigationBars["Choose your broker"].buttons["Cancel"].tap()
        app.buttons["broker.done"].tap()
        XCTAssertTrue(add.waitForExistence(timeout: 5))

        // The overflow menu offers share + add to portfolio.
        app.buttons["detail.more"].tap()
        XCTAssertTrue(app.buttons["Share"].waitForExistence(timeout: 3) || app.staticTexts["Share"].exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()

        // Candles are Pro: the free plan sees the paywall.
        app.buttons["detail.chartStyle"].tap()
        XCTAssertTrue(app.staticTexts["Candlestick Charts"].waitForExistence(timeout: 5), "Free plan sees the Pro paywall")
        XCTAssertFalse(app.descendants(matching: .any)["chart.candles"].firstMatch.exists, "Free plan shouldn't get candles")
        attach("candles-paywall-dark")
        dismissSheet()
        XCTAssertTrue(app.staticTexts["detail.price"].firstMatch.waitForExistence(timeout: 5))
        attach("aapl-1D-dark")
    }

    /// ASX gets an honest note instead of US-only data (BHP isn't the NYSE ADR).
    func testASXDetail() {
        launchAndOnboard(theme: "Dark")
        openFromHome("BHP", market: "asx")
        XCTAssertTrue(app.staticTexts["detail.price"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(identityLabel.contains("ASX"), "BHP is the ASX listing: \(identityLabel)")
        XCTAssertTrue(waitForChart())
        attach("bhp-top-dark")
        scrollDown(times: 2)
        XCTAssertTrue(app.descendants(matching: .any)["detail.asxNote"].waitForExistence(timeout: 5), "ASX gets an honest note")
        XCTAssertFalse(app.descendants(matching: .any)["detail.analysts"].exists, "No US analyst data for ASX")
        XCTAssertFalse(app.descendants(matching: .any)["detail.financials"].exists, "No US financials for ASX")
        attach("bhp-lower-dark")
        close()
    }

    /// Crypto: coin facts, no candles, no company sections (BTC isn't the Grayscale ETF).
    /// Opened from Search, whose crypto results are local — no dependency on CoinGecko
    /// having priced the onboarding pick (keyless CoinGecko throttles).
    func testCryptoDetail() {
        launchAndOnboard(theme: "Light")
        let tab = app.tabBars.buttons["Search"].exists ? app.tabBars.buttons["Search"] : app.buttons["Search"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "Search tab")
        tab.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Search field")
        field.tap()
        field.typeText("bitcoin")
        let result = app.buttons["search.result.crypto.BTC"]
        XCTAssertTrue(result.waitForExistence(timeout: 25), "Bitcoin should be found")
        result.tap()
        XCTAssertTrue(app.descendants(matching: .any)["detail.screen"].waitForExistence(timeout: 10), "Detail should open")
        XCTAssertTrue(app.staticTexts["detail.price"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(identityLabel.contains("Crypto"), "BTC is crypto: \(identityLabel)")
        XCTAssertFalse(app.buttons["detail.chartStyle"].exists, "No candles for crypto")
        XCTAssertTrue(waitForChart(), "A chart or an honest 'unavailable' — never a spinner forever")
        attach("btc-top-light")
        scrollDown(times: 2)
        XCTAssertTrue(app.descendants(matching: .any)["detail.stats"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["detail.financials"].exists, "No company financials for a coin")
        XCTAssertFalse(app.descendants(matching: .any)["detail.analysts"].exists, "No analyst data for a coin")
        XCTAssertFalse(app.descendants(matching: .any)["detail.asxNote"].exists)
        attach("btc-lower-light")
        app.buttons["detail.close"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["detail.screen"].waitForNonExistence(timeout: 5), "Detail closes")
    }

    /// An index card on Home opens the same screen in points, without tracking actions.
    func testIndexDetail() throws {
        launchAndOnboard(theme: "Light")
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'home.index.^'")).firstMatch
        if !card.waitForExistence(timeout: 30) {
            // Home reloads index levels on each quote refresh.
            pullToRefreshHome()
            guard card.waitForExistence(timeout: 30) else {
                throw XCTSkip("Home's index levels didn't load from Yahoo on this run")
            }
        }
        card.tap()
        XCTAssertTrue(app.staticTexts["detail.price"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(identityLabel.contains("Index"), "Index identity: \(identityLabel)")
        XCTAssertFalse(app.buttons["detail.watchlist"].exists, "Indices aren't followable here")
        XCTAssertFalse(app.buttons["detail.position.add"].exists, "Indices can't be held")
        XCTAssertTrue(waitForChart())
        attach("index-top-light")
        close()
    }

    /// Pro (debug override): candles from real OHLC, O/H/L/C on scrub, financial statements.
    func testProCandlesAndFinancials() {
        launchAndOnboard(theme: "Light")
        setProTier()
        openFromHome("AAPL")
        XCTAssertTrue(app.staticTexts["detail.price"].firstMatch.waitForExistence(timeout: 10))

        app.buttons["detail.chartStyle"].tap()
        let candles = app.descendants(matching: .any)["chart.candles"].firstMatch
        XCTAssertTrue(candles.waitForExistence(timeout: 10), "Pro gets candles (or an honest note)")
        app.buttons["1 month"].tap()
        Thread.sleep(forTimeInterval: 2)
        attach("aapl-candles-1M-light")
        app.buttons["detail.chartStyle"].tap()
        XCTAssertTrue(waitForChart(), "Back to the line chart")

        scrollDown(times: 4)
        let picker = app.descendants(matching: .any)["detail.financials.picker"]
        if !picker.waitForExistence(timeout: 5) { scrollDown(times: 2) }
        XCTAssertTrue(picker.exists, "Pro sees the statements picker")
        attach("aapl-financials-light")
    }

    // MARK: - Helpers

    private var identityLabel: String {
        app.descendants(matching: .any)["detail.identity"].firstMatch.label
    }

    private var chartElement: XCUIElement {
        let line = app.descendants(matching: .any)["detail.chart"].firstMatch
        return line.exists ? line : app.descendants(matching: .any)["chart.candles"].firstMatch
    }

    /// A chart, a loading placeholder that resolves, or an honest error — never nothing.
    private func waitForChart(timeout: TimeInterval = 25) -> Bool {
        let chart = app.descendants(matching: .any)["detail.chart"].firstMatch
        guard chart.waitForExistence(timeout: timeout) else { return false }
        let loading = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Loading chart'"))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if loading.count == 0 { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    private func waitFor(_ element: XCUIElement, label: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label == %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func launchAndOnboard(theme: String) {
        app.launchArguments = ["-UITestFreshInstall", "-app_theme_mode", theme]
        app.launch()
        let getStarted = app.buttons["onboarding.getStarted"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 20))
        getStarted.tap()
        waitForStep("What do you want to track?")
        for market in ["asx", "us", "crypto"] {
            let row = app.buttons["onboarding.market.\(market)"]
            if !row.isSelected { row.tap() }
        }
        tapContinue()
        waitForStep("Pick a few to follow")
        for symbol in ["BHP", "AAPL", "BTC"] {
            let row = app.buttons["onboarding.pick.\(symbol)"]
            XCTAssertTrue(row.waitForExistence(timeout: 5), "\(symbol) in the picker")
            row.tap()
        }
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
        // Picks join the watchlist once their quote loads; tests fall back to Search if not.
        _ = app.buttons["home.watchlist.AAPL"].waitForExistence(timeout: 20)
    }

    /// Opens a listing from its Home watchlist row, or from Search when the
    /// onboarding pick hasn't been priced yet (shared API keys get throttled).
    private func openFromHome(_ symbol: String, market: String = "us") {
        let row = app.buttons["home.watchlist.\(symbol)"]
        if row.waitForExistence(timeout: 10) {
            if !row.isHittable { scrollHome() }
            row.tap()
        } else {
            let tab = app.tabBars.buttons["Search"].exists ? app.tabBars.buttons["Search"] : app.buttons["Search"]
            XCTAssertTrue(tab.waitForExistence(timeout: 5), "Search tab")
            tab.tap()
            let field = app.searchFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5), "Search field")
            field.tap()
            field.typeText(symbol)
            let result = app.buttons["search.result.\(market).\(symbol)"]
            XCTAssertTrue(result.waitForExistence(timeout: 25), "\(symbol) from Search")
            result.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["detail.screen"].waitForExistence(timeout: 10), "Detail should open")
    }

    private func close() {
        let close = app.buttons["detail.close"]
        if close.waitForExistence(timeout: 3) { close.tap() }
        XCTAssertTrue(app.descendants(matching: .any)["detail.screen"].waitForNonExistence(timeout: 5), "Detail closes")
    }

    private func setProTier() {
        app.buttons["Settings"].firstMatch.tap()
        let debug = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] 'Debug tools'")).firstMatch
        _ = debug.waitForExistence(timeout: 5)
        for _ in 0..<8 where !debug.isHittable { app.swipeUp() }
        debug.tap()
        let pro = app.segmentedControls.buttons.containing(NSPredicate(format: "label CONTAINS 'Pro'")).firstMatch
        // Once the API checks finish, their rows push the (lazily built) picker below the fold.
        for _ in 0..<6 where !pro.waitForExistence(timeout: 1) { app.swipeUp() }
        XCTAssertTrue(pro.exists, "Debug tier picker")
        pro.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()       // back to Settings
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 3) { done.tap() }
        XCTAssertTrue(done.waitForNonExistence(timeout: 5), "Settings should close")
    }

    private func dismissSheet() {
        for label in ["Close", "Done", "Cancel", "Not now", "Maybe Later"] where app.buttons[label].exists {
            app.buttons[label].firstMatch.tap()
            return
        }
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
        top.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
    }

    /// Scroll the detail page from below the chart so the gesture is a plain scroll.
    private func scrollDown(times: Int) {
        for _ in 0..<times {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.86))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            from.press(forDuration: 0.05, thenDragTo: to)
            Thread.sleep(forTimeInterval: 0.6)
        }
    }

    private func pullToRefreshHome() {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        from.press(forDuration: 0.1, thenDragTo: to)
    }

    private func scrollHome() {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        from.press(forDuration: 0.05, thenDragTo: to)
    }

    private func waitForStep(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10), "Expected step “\(title)”", file: file, line: line)
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
        Thread.sleep(forTimeInterval: 0.8)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
