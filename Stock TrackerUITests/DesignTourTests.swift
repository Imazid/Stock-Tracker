import XCTest

/// Walks the main screens in light and dark and keeps a screenshot of each, for design
/// review (before/after a restyle). Opt-in, because it is slow and asserts little:
///
///   TEST_RUNNER_RUN_DESIGN=1 xcodebuild test … -only-testing:"Stock TrackerUITests/DesignTourTests"
///   xcrun xcresulttool export attachments --path <result>.xcresult --output-path <dir>
///
/// Uses the trading fixture (deterministic practice prices) and a seeded watchlist; the
/// watchlist prices themselves are live, so they vary between runs.
final class DesignTourTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_DESIGN"] == "1",
                          "Design tour runs only with TEST_RUNNER_RUN_DESIGN=1")
        continueAfterFailure = true
    }

    func testTourLight() { tour("Light") }
    func testTourDark() { tour("Dark") }

    func testOnboardingLook() {
        for mode in ["Light", "Dark"] {
            app = XCUIApplication()
            app.launchArguments = ["-UITestFreshInstall", "-app_theme_mode", mode]
            app.launch()
            sleep(3)
            shot("onboarding-welcome-\(mode)")
            app.terminate()
        }
    }

    // MARK: - Tour

    private func tour(_ mode: String) {
        app = XCUIApplication()
        app.launchArguments = ["-UITestFreshInstall", "-UITestTradingFixture", "-hasCompletedOnboarding", "YES",
                               "-app_theme_mode", mode, "-onboarding_stocks", "(AAPL, NVDA, MSFT, BHP.AX, TSLA)"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 30))
        sleep(6)                                   // let quotes and sparklines arrive
        shot("01-home-\(mode)")
        app.swipeUp(velocity: .slow)
        shot("02-home-scrolled-\(mode)")

        app.open("Watchlist")
        sleep(2)
        shot("03-markets-watchlist-\(mode)")
        let aapl = app.descendants(matching: .any)["watchlist.row.AAPL"]
        if aapl.waitForExistence(timeout: 10) {
            aapl.tap()
            sleep(4)
            shot("04-detail-\(mode)")
            app.swipeUp(velocity: .slow)
            shot("05-detail-scrolled-\(mode)")
            let close = app.buttons["detail.close"]
            if close.exists { close.tap() } else { app.navigationBars.buttons.firstMatch.tap() }
        }
        app.open("Search")
        sleep(1)
        shot("06-markets-search-\(mode)")
        app.open("News")
        sleep(3)
        shot("07-markets-news-\(mode)")

        app.open("Portfolio")
        sleep(1)
        shot("08-portfolio-empty-\(mode)")

        // Practice money and an order.
        let setUp = app.buttons["Set up practice money"]
        let add = app.buttons["practice.add"]
        for _ in 0..<8 where !setUp.isHittable && !add.isHittable { app.swipeUp(velocity: .slow) }
        if setUp.isHittable { setUp.tap() } else if add.isHittable { add.tap() }
        if element("practice.setup").waitForExistence(timeout: 8) {
            shot("09-practice-setup-\(mode)")
            tap("practice.balance.10000")
            tap("practice.start")
        }
        let portfolio = app.buttons["practice.portfolio.Practice"]
        if portfolio.waitForExistence(timeout: 10) {
            portfolio.tap()
            tap("practice.buy")
            let search = app.searchFields.firstMatch
            if search.waitForExistence(timeout: 5) {
                search.tap()
                search.typeText("BTC")
                tap("picker.BTC")
                if element("ticket.price").waitForExistence(timeout: 20) {
                    let field = app.textFields["ticket.amount"].exists ? app.textFields["ticket.amount"] : element("ticket.amount")
                    field.tap()
                    field.typeText("1000")
                    shot("10-ticket-entry-\(mode)")
                    tap("ticket.review")
                    sleep(1)
                    shot("11-ticket-review-\(mode)")
                    tap("ticket.place")
                    if element("ticket.result.title").waitForExistence(timeout: 15) {
                        sleep(1)
                        shot("12-ticket-filled-\(mode)")
                        tap("ticket.done")
                    }
                }
            }
            sleep(1)
            shot("13-practice-portfolio-\(mode)")
            app.buttons["Close"].firstMatch.tap()
        }
        app.swipeDown(velocity: .fast)
        shot("14-portfolio-with-practice-\(mode)")

        // Agents.
        app.open("Agents")
        sleep(1)
        shot("15-agents-empty-\(mode)")
        tap("agents.new")
        sleep(1)
        shot("16-agent-new-\(mode)")
        tap("agent.template.trend")
        sleep(1)
        shot("17-agent-draft-\(mode)")
        tap("agent.draft.start")
        sleep(4)
        shot("18-agents-list-\(mode)")
        let card = app.buttons["agents.card.Trend Following Agent"]
        if card.waitForExistence(timeout: 10) {
            card.tap()
            sleep(2)
            shot("19-agent-detail-\(mode)")
            app.navigationBars.buttons.firstMatch.tap()
        }

        // Activity.
        app.open("Activity")
        sleep(1)
        shot("20-activity-\(mode)")
        let audit = app.segmentedControls["activity.section"].buttons["Audit"]
        if audit.exists { audit.tap(); sleep(1); shot("21-activity-audit-\(mode)") }

        // Copilot.
        let copilot = app.buttons["trading.copilot"].firstMatch
        if copilot.exists {
            copilot.tap()
            sleep(2)
            shot("22-copilot-\(mode)")
        }
        app.terminate()
    }

    // MARK: - Helpers

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func tap(_ id: String) {
        let target = app.buttons[id].exists ? app.buttons[id] : element(id)
        guard target.waitForExistence(timeout: 10) else { return }
        var tries = 0
        while !target.isHittable && tries < 6 { app.swipeUp(velocity: .slow); tries += 1 }
        if target.isHittable { target.tap() }
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
