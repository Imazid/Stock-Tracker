//
//  PortfolioScreenTests.swift
//  Stock TrackerUITests
//
//  The Portfolio tab end to end from a fresh install: empty state, adding
//  through search (an ASX ticker must resolve to the ASX company), the plan
//  limit, every segment, the holding detail (overselling is blocked, a sell
//  updates the position at once) and removal. Screenshots are attached in
//  light and dark mode.
//

import XCTest

final class PortfolioScreenTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    // MARK: Tests

    /// A new user with no holdings gets one clear prompt and a working add sheet.
    func testEmptyPortfolioOffersEveryWayToAdd() {
        launch(theme: "Light")
        onboard(holdings: [])
        openPortfolio()

        XCTAssertTrue(app.descendants(matching: .any)["portfolio.empty"].waitForExistence(timeout: 8),
                      "An empty portfolio shows the start prompt, not a $0 chart")
        XCTAssertFalse(app.descendants(matching: .any)["portfolio.chart"].exists)
        attach("empty-1-overview")

        app.buttons["Add a holding"].tap()
        XCTAssertTrue(app.textFields["add.search"].waitForExistence(timeout: 5))
        for id in ["add.broker", "add.csv", "add.manual"] {
            XCTAssertTrue(app.buttons[id].exists, "\(id) should be offered")
        }
        attach("empty-2-add-sheet")
    }

    /// Search → add (ASX resolves to Telstra, not Telos) → plan limit → segments →
    /// detail with a blocked oversell and a valid sell → swipe to remove.
    func testAddSegmentsDetailAndRemove() throws {
        launch(theme: "Light")
        onboard(holdings: [("MSFT", false, "10", "300"), ("BTC", true, "0.05", "60000")])
        openPortfolio()

        let chart = app.descendants(matching: .any)["portfolio.chart"].firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 10), "Hero chart")
        Thread.sleep(forTimeInterval: 5)          // live quotes + real history land
        attach("light-1-overview")
        XCTAssertTrue(reveal(holdingRow("MSFT")), "MSFT row")
        XCTAssertTrue(reveal(holdingRow("BTC")), "BTC row")
        attach("light-1b-holdings")
        app.swipeDown(); app.swipeDown(); app.swipeDown()

        // Add an ASX stock through search.
        app.buttons["portfolio.add"].tap()
        let search = app.textFields["add.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Telstra")
        let telstra = app.buttons["add.result.ASX.TLS"]
        XCTAssertTrue(telstra.waitForExistence(timeout: 20), "Telstra should come back as an ASX result")
        attach("light-2-search")
        telstra.tap()
        XCTAssertTrue(app.descendants(matching: .any)["holding.form.asset"].waitForExistence(timeout: 15))
        let numbers = app.textFields.matching(identifier: "0.00")
        numbers.element(boundBy: 0).tap()
        numbers.element(boundBy: 0).typeText("100")
        attach("light-3-form")
        app.buttons["Add to Portfolio"].tap()
        let tls = holdingRow("TLS")
        XCTAssertTrue(reveal(tls), "TLS is added")
        XCTAssertTrue(tls.label.localizedCaseInsensitiveContains("Telstra"),
                      "TLS must be Telstra (ASX), got: \(tls.label)")

        // Fourth holding fills the Free plan; a fifth is offered an upgrade instead.
        addFromSearch("NVDA", market: "US", quantity: "2")
        XCTAssertTrue(reveal(holdingRow("NVDA")), "NVDA is added")
        app.swipeDown(); app.swipeDown(); app.swipeDown()
        app.buttons["portfolio.add"].tap()
        let search2 = app.textFields["add.search"]
        XCTAssertTrue(search2.waitForExistence(timeout: 5))
        search2.tap()
        search2.typeText("AMZN")
        let amzn = app.buttons["add.result.US.AMZN"]
        XCTAssertTrue(amzn.waitForExistence(timeout: 20))
        amzn.tap()
        XCTAssertTrue(app.buttons["holding.form.upgrade"].waitForExistence(timeout: 15),
                      "A 5th holding on Free shows the plan limit, not a silent add")
        attach("light-4-limit")
        app.navigationBars.buttons.element(boundBy: 0).tap()     // back to search
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertFalse(holdingRow("AMZN").exists)

        // Segments.
        for segment in ["allocation", "performance", "income", "holdings"] {
            let button = app.buttons["portfolio.segment.\(segment)"]
            scrollTo(button)
            button.tap()
            Thread.sleep(forTimeInterval: 3)
            attach("light-5-\(segment)")
            if segment != "holdings" {
                app.swipeUp()
                Thread.sleep(forTimeInterval: 0.6)
                attach("light-5-\(segment)-scrolled")
                app.swipeDown(); app.swipeDown()
            }
        }

        // Detail: oversell is blocked, a valid sell updates the position immediately.
        let msft = holdingRow("MSFT")
        XCTAssertTrue(reveal(msft), "MSFT row")
        msft.tap()
        XCTAssertTrue(app.descendants(matching: .any)["holding.position"].waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 2)
        attach("light-6-detail")
        let addTx = app.buttons["holding.addTransaction"]
        scrollTo(addTx)
        addTx.tap()
        XCTAssertTrue(app.buttons["tx.type.sell"].waitForExistence(timeout: 5))
        app.buttons["tx.type.sell"].tap()
        let qty = app.textFields.matching(identifier: "0.00").element(boundBy: 0)
        qty.tap()
        qty.typeText("15")
        XCTAssertTrue(app.descendants(matching: .any)["tx.error"].waitForExistence(timeout: 3), "Selling 15 of 10 is blocked")
        XCTAssertFalse(app.buttons["tx.save"].isEnabled)
        attach("light-7-oversell-blocked")
        qty.typeText(XCUIKeyboardKey.delete.rawValue + XCUIKeyboardKey.delete.rawValue + "4")
        XCTAssertTrue(app.buttons["tx.save"].isEnabled)
        app.buttons["tx.save"].tap()
        let position = app.descendants(matching: .any)["holding.position"]
        XCTAssertTrue(position.waitForExistence(timeout: 5))
        let sale = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Sold 4 shares")).firstMatch
        XCTAssertTrue(sale.waitForExistence(timeout: 5), "The sale shows in transactions at once")
        let shares = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Shares' AND label CONTAINS '6'")).firstMatch
        XCTAssertTrue(shares.waitForExistence(timeout: 5), "Position is now 6 shares")

        // Realised profit = 4 × (sale price − average cost), all in the display currency.
        let realizedLine = app.descendants(matching: .any)["holding.realized"]
        XCTAssertTrue(realizedLine.waitForExistence(timeout: 5), "A sale adds a Realised line")
        let avgCost = try XCTUnwrap(money(in: app.descendants(matching: .any)["holding.avgCost"].label), "average cost")
        let price1 = try XCTUnwrap(money(in: sale.label, after: ", at "), "sale price in \(sale.label)")
        let realized1 = try XCTUnwrap(money(in: realizedLine.label), "realised in \(realizedLine.label)")
        XCTAssertEqual(realized1, 4 * (price1 - avgCost), accuracy: 0.06,
                       "Realised \(realized1) should be 4 × (\(price1) − \(avgCost))")
        attach("light-8-after-sell")

        // Sell the other 6: the keyboard's Done works, the form previews the profit,
        // and the holding moves to Closed positions with its realised profit kept.
        scrollTo(addTx)
        addTx.tap()
        XCTAssertTrue(app.buttons["tx.type.sell"].waitForExistence(timeout: 5))
        app.buttons["tx.type.sell"].tap()
        let qty2 = app.textFields.matching(identifier: "0.00").element(boundBy: 0)
        qty2.tap()
        qty2.typeText("6")
        let done = app.buttons["keyboard.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 3), "Done shows while a number field is focused")
        done.tap()
        XCTAssertTrue(waitForDisappearance(app.keyboards.firstMatch), "Done puts the keyboard away")
        XCTAssertTrue(app.descendants(matching: .any)["tx.realized"].waitForExistence(timeout: 3), "Sell form previews the realised profit")
        attach("light-8b-sell-all-form")
        app.buttons["tx.save"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["holding.closed"].waitForExistence(timeout: 5), "Selling everything closes the position")
        attach("light-8c-closed")
        app.buttons["holding.closed.back"].tap()

        let closedRow = app.buttons["portfolio.closed.MSFT"]
        XCTAssertTrue(reveal(closedRow), "MSFT is listed under Closed positions")
        XCTAssertFalse(holdingRow("MSFT").exists, "MSFT is no longer an open holding")
        attach("light-8d-closed-list")
        closedRow.tap()
        let closedRealized = app.descendants(matching: .any)["closed.realised"]
        XCTAssertTrue(closedRealized.waitForExistence(timeout: 5))
        // The combined rows only (their child texts are exposed too).
        let saleRows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Sold ' AND label CONTAINS ', at '")).allElementsBoundByIndex
        XCTAssertEqual(saleRows.count, 2, "Both sales are listed")
        var expected = 0.0
        for row in saleRows {
            let q = row.label.hasPrefix("Sold 4") ? 4.0 : 6.0
            let p = try XCTUnwrap(money(in: row.label, after: ", at "), "price in \(row.label)")
            let r = try XCTUnwrap(money(in: row.label, after: "Realised"), "realised in \(row.label)")
            XCTAssertEqual(r, q * (p - avgCost), accuracy: 0.06, "Sale row: \(row.label)")
            expected += q * (p - avgCost)
        }
        let total = try XCTUnwrap(money(in: closedRealized.label))
        XCTAssertEqual(total, expected, accuracy: 0.12, "Closed MSFT realised \(total) = sum of both sales \(expected)")
        attach("light-8e-closed-sheet")
        app.buttons["Done"].firstMatch.tap()

        // The summary's total return now carries the realised part.
        app.swipeDown(); app.swipeDown(); app.swipeDown(); app.swipeDown()
        let breakdown = app.descendants(matching: .any)["portfolio.summary.breakdown"]
        XCTAssertTrue(breakdown.waitForExistence(timeout: 5), "Summary shows unrealised · realised")
        let summaryRealized = try XCTUnwrap(money(in: breakdown.label, after: "Realised"))
        XCTAssertEqual(summaryRealized, total, accuracy: 0.02, "Summary realised = the closed position's")
        attach("light-8f-summary")

        // Swipe to remove.
        let btc = holdingRow("BTC")
        XCTAssertTrue(reveal(btc), "BTC row")
        btc.swipeLeft()
        app.buttons["Remove"].firstMatch.tap()
        let confirm = app.alerts.buttons["Remove"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        attach("light-9-remove-confirm")
        confirm.tap()
        XCTAssertTrue(waitForDisappearance(holdingRow("BTC")), "BTC is removed")
        attach("light-10-after-remove")
        app.swipeDown(); app.swipeDown(); app.swipeDown()
        Thread.sleep(forTimeInterval: 5)
        attach("light-11-hero-after-remove")
    }

    /// Dark mode screens (no mutations beyond onboarding).
    /// Performance's "Working it out…" and Allocation's "Calculating…" must settle — into a
    /// result or an honest "couldn't be loaded" — not spin for minutes when crypto history
    /// is throttled. Reports how long each took.
    func testAnalyticsSettle() {
        launch(theme: "Light")
        onboard(holdings: [("MSFT", false, "10", "300"), ("BTC", true, "0.05", "60000")])
        openPortfolio()
        app.swipeDown(); app.swipeDown()

        let performance = app.buttons["portfolio.segment.performance"]
        scrollTo(performance)
        performance.tap()
        var start = Date()
        let working = app.staticTexts["Working it out…"]
        let settledPerf = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: working)
        XCTAssertEqual(XCTWaiter.wait(for: [settledPerf], timeout: 45), .completed, "Performance should settle")
        let perfSeconds = Date().timeIntervalSince(start)
        attach("analytics-performance-settled")

        let allocation = app.buttons["portfolio.segment.allocation"]
        scrollTo(allocation)
        allocation.tap()
        start = Date()
        let calculating = app.staticTexts["Calculating…"]
        let settledVol = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: calculating)
        XCTAssertEqual(XCTWaiter.wait(for: [settledVol], timeout: 45), .completed, "Volatility should settle")
        let volSeconds = Date().timeIntervalSince(start)
        attach("analytics-allocation-settled")
        let timing = XCTAttachment(string: String(format: "performance settled in %.1fs, volatility in %.1fs", perfSeconds, volSeconds))
        timing.name = "analytics-timing"
        timing.lifetime = .keepAlways
        add(timing)
        print(String(format: "ANALYTICS performance=%.1fs volatility=%.1fs", perfSeconds, volSeconds))
    }

    func testDarkModeScreens() {
        launch(theme: "Dark")
        onboard(holdings: [("MSFT", false, "10", "300"), ("BTC", true, "0.05", "60000"), ("CBA.AX", false, "20", "100")])
        openPortfolio()
        Thread.sleep(forTimeInterval: 5)
        attach("dark-1-overview")
        XCTAssertTrue(reveal(holdingRow("MSFT")), "MSFT row")
        attach("dark-1b-holdings")
        app.swipeDown(); app.swipeDown(); app.swipeDown()
        for segment in ["allocation", "performance", "income"] {
            let button = app.buttons["portfolio.segment.\(segment)"]
            scrollTo(button)
            button.tap()
            Thread.sleep(forTimeInterval: 3)
            attach("dark-2-\(segment)")
        }
        app.buttons["portfolio.segment.holdings"].tap()
        let msft = holdingRow("MSFT")
        XCTAssertTrue(reveal(msft), "MSFT row")
        msft.tap()
        XCTAssertTrue(app.descendants(matching: .any)["holding.position"].waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 2)
        attach("dark-3-detail")

        // A partial sale with brokerage, then the rest: realised lines, closed state, closed list.
        sell(quantity: "4", fees: "9.95")
        XCTAssertTrue(app.descendants(matching: .any)["holding.realized"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        attach("dark-3b-detail-after-sale")
        sell(quantity: "6", fees: nil)
        XCTAssertTrue(app.descendants(matching: .any)["holding.closed"].waitForExistence(timeout: 5))
        attach("dark-3c-closed")
        app.buttons["holding.closed.back"].tap()
        let closedRow = app.buttons["portfolio.closed.MSFT"]
        XCTAssertTrue(reveal(closedRow))
        attach("dark-3d-closed-list")
        closedRow.tap()
        XCTAssertTrue(app.descendants(matching: .any)["closed.realised"].waitForExistence(timeout: 5))
        attach("dark-3e-closed-sheet")
        app.buttons["Done"].firstMatch.tap()
        app.swipeDown(); app.swipeDown(); app.swipeDown(); app.swipeDown()
        for segment in ["performance", "income"] {
            let button = app.buttons["portfolio.segment.\(segment)"]
            scrollTo(button)
            button.tap()
            Thread.sleep(forTimeInterval: 4)
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.6)
            attach("dark-4-\(segment)-after-sales")
            app.swipeDown(); app.swipeDown()
        }
        app.buttons["portfolio.add"].tap()
        XCTAssertTrue(app.textFields["add.search"].waitForExistence(timeout: 5))
        attach("dark-5-add")
    }


    // MARK: Helpers

    private func launch(theme: String) {
        app.launchArguments = ["-UITestFreshInstall", "-app_theme_mode", theme]
        app.launch()
    }

    private func onboard(holdings: [(symbol: String, crypto: Bool, quantity: String, cost: String)]) {
        XCTAssertTrue(app.buttons["onboarding.getStarted"].waitForExistence(timeout: 15))
        app.buttons["onboarding.getStarted"].tap()
        step("What do you want to track?")
        for market in ["asx", "us"] {
            let row = app.buttons["onboarding.market.\(market)"]
            if !row.isSelected { row.tap() }
        }
        tapContinue()
        step("Pick a few to follow")
        app.buttons["onboarding.pick.AAPL"].tap()
        tapContinue()
        step("Add what you already own")
        for (index, h) in holdings.enumerated() {
            app.buttons["onboarding.portfolio.manual"].tap()
            if h.crypto {
                let crypto = app.buttons["holding.kind.crypto"]
                XCTAssertTrue(crypto.waitForExistence(timeout: 5))
                crypto.tap()
            }
            let symbolField = app.textFields[h.crypto ? "BTC" : "AAPL"]
            XCTAssertTrue(symbolField.waitForExistence(timeout: 5))
            symbolField.tap()
            symbolField.typeText(h.symbol)
            let numbers = app.textFields.matching(identifier: "0.00")
            XCTAssertEqual(numbers.count, 2)
            numbers.element(boundBy: 0).tap()
            numbers.element(boundBy: 0).typeText(h.quantity)
            numbers.element(boundBy: 1).tap()
            numbers.element(boundBy: 1).typeText(h.cost)
            app.buttons["Add to Portfolio"].tap()
            let expected = index == 0 ? "1 holding added" : "\(index + 1) holdings added"
            XCTAssertTrue(app.staticTexts[expected].waitForExistence(timeout: 5), "Expected “\(expected)”")
        }
        tapContinue()
        step("Know when it moves")
        app.buttons["onboarding.notifications.notNow"].tap()
        if app.staticTexts["Keep your portfolio private"].waitForExistence(timeout: 2) { app.buttons["Not now"].tap() }
        step("Save your setup")
        app.buttons["onboarding.account.skip"].tap()
        step("You're all set")
        app.buttons["onboarding.finish"].tap()
    }

    private func addFromSearch(_ query: String, market: String, quantity: String) {
        app.buttons["portfolio.add"].tap()
        let search = app.textFields["add.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText(query)
        let result = app.buttons["add.result.\(market).\(query)"]
        XCTAssertTrue(result.waitForExistence(timeout: 20), "\(query) search result")
        result.tap()
        XCTAssertTrue(app.descendants(matching: .any)["holding.form.asset"].waitForExistence(timeout: 15))
        let qty = app.textFields.matching(identifier: "0.00").element(boundBy: 0)
        qty.tap()
        qty.typeText(quantity)
        app.buttons["Add to Portfolio"].tap()
    }

    /// Records a sale from the open holding page.
    private func sell(quantity: String, fees: String?) {
        let addTx = app.buttons["holding.addTransaction"]
        scrollTo(addTx)
        addTx.tap()
        XCTAssertTrue(app.buttons["tx.type.sell"].waitForExistence(timeout: 5))
        app.buttons["tx.type.sell"].tap()
        let qty = app.textFields.matching(identifier: "0.00").element(boundBy: 0)
        qty.tap()
        qty.typeText(quantity)
        if let fees {
            let field = app.textFields["tx.fees"]
            field.tap()
            field.typeText(fees)
        }
        if app.buttons["keyboard.done"].exists { app.buttons["keyboard.done"].tap() }
        XCTAssertTrue(app.buttons["tx.save"].isEnabled, "Sale can be saved")
        app.buttons["tx.save"].tap()
    }

    /// The first money amount in an accessibility label ("+A$1,234.56", "−US$3.20", "A$451.23"),
    /// optionally the first one after `marker`. Signed with the label's + / − if present.
    private func money(in label: String, after marker: String? = nil) -> Double? {
        var text = Substring(label)
        if let marker {
            guard let r = label.range(of: marker) else { return nil }
            text = label[r.upperBound...]
        }
        guard let match = text.firstMatch(of: /([+\-−])?\s?[A-Z]{0,3}\$\s?([0-9][0-9,]*(?:\.[0-9]+)?)/) else { return nil }
        guard let value = Double(match.2.replacingOccurrences(of: ",", with: "")) else { return nil }
        return match.1 == "−" || match.1 == "-" ? -value : value
    }

    private func openPortfolio() {
        let tab = app.tabBars.buttons["Portfolio"].exists ? app.tabBars.buttons["Portfolio"] : app.buttons["Portfolio"]
        XCTAssertTrue(tab.waitForExistence(timeout: 20))
        tab.tap()
    }

    private func holdingRow(_ symbol: String) -> XCUIElement {
        app.buttons["portfolio.holding.\(symbol)"]
    }

    /// Scrolls *towards* the element (see ListsFlowTests: swiping down past the top of a
    /// sheet dismisses it).
    private func scrollTo(_ element: XCUIElement, attempts: Int = 6) {
        for _ in 0..<(attempts * 2) {
            if element.exists && element.isHittable { return }
            if element.exists && element.frame.maxY < app.windows.firstMatch.frame.midY {
                app.swipeDown(velocity: .slow)
            } else {
                app.swipeUp(velocity: .slow)
            }
        }
    }

    /// Lists only create rows near the viewport: scroll down until the element exists and is hittable.
    private func reveal(_ element: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isHittable { return true }
            app.swipeUp(velocity: .slow)
            Thread.sleep(forTimeInterval: 0.5)
        }
        return element.exists
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    private func step(_ title: String) {
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 8), "Expected step “\(title)”")
        Thread.sleep(forTimeInterval: 0.7)
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
