import XCTest

/// The trading features driven through the real app: practice orders, agents and their
/// approvals, pause-all, the live-mode refusal, the audit trail and a Tokyo order.
///
/// `-UITestTradingFixture` gives the trading engine deterministic prices labelled as test
/// data (the engine refuses them in a normal run), so these tests don't depend on markets
/// being open or on rate-limited price feeds. Crypto trades around the clock, so crypto
/// orders fill at any hour; Tokyo orders fill or wait depending on the time of day, and
/// the test accepts either outcome — but nothing else.
final class TradingFlowTests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestFreshInstall", "-UITestTradingFixture", "-hasCompletedOnboarding", "YES",
                               "-app_theme_mode", "Light"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Agents"].waitForExistence(timeout: 30), "The app should open on the tabs")
    }

    // MARK: - Helpers

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func tap(_ id: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let target = app.buttons[id].exists ? app.buttons[id] : element(id)
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "\(id) should appear", file: file, line: line)
        if !target.isHittable { scrollTo(target) }
        target.tap()
    }

    private func scrollTo(_ target: XCUIElement, max: Int = 8) {
        var tries = 0
        while !target.isHittable && tries < max {
            app.swipeUp(velocity: .slow)
            tries += 1
        }
    }

    private func type(_ text: String, into id: String) {
        let field = app.textFields[id].exists ? app.textFields[id] : element(id)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "\(id) field")
        field.tap()
        field.typeText(text)
    }

    /// Taps a segment until it reports selected (a tap during a tab transition can be lost).
    private func select(_ segment: String, in control: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.segmentedControls[control].buttons[segment]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "\(segment) segment", file: file, line: line)
        for _ in 0..<4 where !button.isSelected {
            button.tap()
            _ = button.wait(for: \.isSelected, toEqual: true, timeout: 2)
        }
        XCTAssertTrue(button.isSelected, "\(segment) should be selected", file: file, line: line)
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Creates a USD practice portfolio from the Portfolio tab and opens it.
    private func createPracticePortfolio(currency: String? = nil, balance: Int? = nil) {
        XCTAssertTrue(app.open("Portfolio"))
        let setUp = app.buttons["Set up practice money"]
        let add = app.buttons["practice.add"]
        for _ in 0..<8 where !setUp.isHittable && !add.isHittable { app.swipeUp(velocity: .slow) }
        if setUp.isHittable { setUp.tap() } else { add.tap() }
        XCTAssertTrue(element("practice.setup").waitForExistence(timeout: 10), "Practice setup")
        if let currency {
            let picker = element("practice.currency")
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            picker.tap()
            let option = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", currency + " ")).firstMatch
            XCTAssertTrue(option.waitForExistence(timeout: 5), "\(currency) option")
            option.tap()
        }
        if let balance { tap("practice.balance.\(balance)") }
        attach("practice-setup-\(currency ?? "USD")")
        tap("practice.start")
    }

    // MARK: - Tests

    /// The tab bar has exactly the five places, labelled.
    func testFiveLabelledTabs() {
        for name in ["Home", "Markets", "Portfolio", "Agents", "Activity"] {
            XCTAssertTrue(app.tabBars.buttons[name].exists, "\(name) tab")
        }
        XCTAssertFalse(app.tabBars.buttons["More"].exists, "No overflow tab")
        XCTAssertTrue(app.open("Search"), "Search lives in Markets")
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        attach("tabs-search")
    }

    /// Buy practice crypto by hand: review shows the checks, the order fills, Activity and the
    /// portfolio both show it, and the audit trail verifies.
    func testManualPracticeOrderFillsAndIsAudited() {
        createPracticePortfolio(balance: 10000)
        let portfolio = app.buttons["practice.portfolio.Practice"]
        XCTAssertTrue(portfolio.waitForExistence(timeout: 10), "Practice portfolio card")
        portfolio.tap()
        tap("practice.buy")
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("BTC")
        tap("picker.BTC")

        XCTAssertTrue(element("ticket.screen").waitForExistence(timeout: 10), "Order ticket")
        XCTAssertTrue(element("ticket.price").waitForExistence(timeout: 20), "A price should load")
        type("1000", into: "ticket.amount")
        XCTAssertTrue(element("ticket.conversion").label.contains("BTC"), "Amount converts to BTC")
        attach("ticket-entry")
        tap("ticket.review")
        XCTAssertTrue(element("ticket.review.sentence").waitForExistence(timeout: 10), "Review step")
        XCTAssertTrue(element("risk.check.marketData.passed").exists || app.buttons["risk.showAll"].exists, "Risk checks shown")
        attach("ticket-review")
        tap("ticket.place")
        let title = element("ticket.result.title")
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.label, "Practice order filled", element("ticket.result.detail").label)
        attach("ticket-filled")
        tap("ticket.done")

        // The portfolio holds it.
        XCTAssertTrue(element("practice.position.BTC").waitForExistence(timeout: 10), "BTC position")
        app.buttons["Close"].firstMatch.tap()

        // Activity shows the filled order, and the audit trail is intact.
        XCTAssertTrue(app.open("Activity"))
        XCTAssertTrue(element("order.row.BTC.filled").waitForExistence(timeout: 10), "Filled order in Activity")
        select("Audit", in: "activity.section")
        XCTAssertTrue(element("audit.intact").waitForExistence(timeout: 5), "Audit trail verifies")
        XCTAssertTrue(element("audit.row.orderFilled").exists)
        attach("activity-audit")
    }

    /// A sentence becomes an agent; its first run proposes a trade that waits for approval;
    /// approving places a practice order that fills.
    func testAgentFromSentenceProposesAndApprovalFills() {
        XCTAssertTrue(app.open("Agents"))
        tap("agents.new")
        type("Monitor BTC and ETH and ask me before each trade, with an 8% stop loss", into: "agent.new.prompt")
        tap("agent.new.draft")
        XCTAssertTrue(element("agent.draft.understood").waitForExistence(timeout: 10), "What it understood")
        XCTAssertTrue(app.staticTexts["Stop loss: 8%"].exists)
        XCTAssertTrue(app.staticTexts["Each paper trade waits for your approval"].exists)
        attach("agent-draft")
        tap("agent.draft.start")

        // Its first look at the market produces a proposal that needs a decision.
        let approval = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'agents.approval.'")).firstMatch
        XCTAssertTrue(approval.waitForExistence(timeout: 40), "A proposal should wait for approval")
        attach("agents-approval")
        approval.tap()
        XCTAssertTrue(element("proposal.status.pending").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Risk checks"].exists)
        attach("proposal-review")
        tap("proposal.approve")
        XCTAssertTrue(element("proposal.outcome.placed").waitForExistence(timeout: 20), "Approving places the order")
        attach("proposal-approved")
        tap("proposal.done")

        XCTAssertTrue(app.open("Activity"))
        let filled = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'order.row.' AND identifier ENDSWITH '.filled'")).firstMatch
        XCTAssertTrue(filled.waitForExistence(timeout: 10), "The approved order filled")
    }

    /// Pause all stops every agent; turning it off doesn't restart them.
    func testPauseAllStopsAgentsUntilResumed() {
        XCTAssertTrue(app.open("Agents"))
        tap("agents.new")
        tap("agent.template.trend")
        tap("agent.draft.start")
        let card = app.buttons["agents.card.Trend Following Agent"]
        XCTAssertTrue(card.waitForExistence(timeout: 15), "Agent card")

        tap("agents.pauseAll")
        XCTAssertTrue(element("pauseAll.sheet").waitForExistence(timeout: 5))
        attach("pause-all-confirm")
        tap("pauseAll.confirm")
        XCTAssertTrue(element("pauseAll.pausedTitle").waitForExistence(timeout: 5))
        tap("pauseAll.dismiss")
        XCTAssertTrue(element("trading.pausedAllBanner").waitForExistence(timeout: 5), "Banner while paused")
        XCTAssertTrue(card.label.contains("Paused by Pause all"), card.label)
        attach("agents-paused")

        // Turning pause-all off leaves the agent paused until resumed by hand.
        card.tap()
        XCTAssertTrue(element("agent.detail").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["agent.resume"].isEnabled, "Resume is blocked while pause-all is on")
        app.navigationBars.buttons.firstMatch.tap()
        tap("trading.pausedAllBanner.review")
        tap("pauseAll.release")
        XCTAssertTrue(app.buttons["agents.card.Trend Following Agent"].label.contains("Paused"))
        app.buttons["agents.card.Trend Following Agent"].tap()
        tap("agent.resume")
        XCTAssertTrue(element("agent.status").label.contains("Running"), element("agent.status").label)
    }

    /// Live modes can't be chosen: the app says why instead.
    func testLiveModesAreRefusedWithReasons() {
        XCTAssertTrue(app.open("Agents"))
        tap("agents.new")
        tap("agent.template.momentum")
        tap("agent.draft.mode.autonomousLive")
        let alert = app.alerts["Live trading isn't available"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Refusal shown")
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'No trading account is connected'")).firstMatch.exists)
        attach("live-refused")
        alert.buttons["OK"].tap()
        XCTAssertTrue(app.buttons["agent.draft.mode.paper"].isSelected, "Still paper trading")
    }

    /// A yen portfolio buys Toyota in lots of 100: an odd quantity is flagged before review,
    /// and a full lot is filled or waits for the Tokyo session — never anything else.
    func testTokyoOrderUsesYenAndHundredShareLots() {
        createPracticePortfolio(currency: "JPY", balance: 5000000)
        let portfolio = app.buttons["practice.portfolio.Practice (JPY)"]
        XCTAssertTrue(portfolio.waitForExistence(timeout: 10), "Yen portfolio card")
        XCTAssertTrue(portfolio.label.contains("¥"), portfolio.label)
        portfolio.tap()
        tap("practice.buy")
        tap("picker.7203")
        XCTAssertTrue(element("ticket.price").waitForExistence(timeout: 20), "A price should load")
        XCTAssertTrue(element("ticket.lotNote").label.contains("lots of 100"))
        select("Shares", in: "ticket.entry")
        type("150", into: "ticket.amount")
        XCTAssertTrue(element("ticket.problem").waitForExistence(timeout: 5), "Odd lot flagged")
        XCTAssertTrue(element("ticket.problem").label.contains("lots of 100"), element("ticket.problem").label)
        XCTAssertTrue(element("ticket.problem").isHittable, "The odd-lot warning is visible without scrolling")
        XCTAssertFalse(app.buttons["ticket.review"].isEnabled, "Review waits until the lot is fixed")
        attach("tokyo-odd-lot")

        // The amount field hugs its number (it's centred), so tap its trailing edge to put
        // the cursor after the digits before deleting them.
        let field = app.textFields["ticket.amount"]
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3) + "100")
        attach("tokyo-full-lot")
        tap("ticket.review")
        XCTAssertTrue(element("ticket.review.sentence").waitForExistence(timeout: 10))
        attach("tokyo-review")
        tap("ticket.place")
        attach("tokyo-after-place")
        let title = element("ticket.result.title")
        XCTAssertTrue(title.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(["Practice order filled", "Practice order placed"].contains(title.label),
                      "\(title.label): \(element("ticket.result.detail").label)")
        attach("tokyo-result")
    }
}
