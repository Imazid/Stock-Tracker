import XCTest

/// Trading in an account, end to end against the local Supabase stack: the app signs in,
/// moves practice trading to the server, and every order, agent and approval goes through
/// `trading-api`. Rows are checked through REST as the person (RLS applies), and a fresh
/// install that signs in again sees the same portfolio — proof it lives on the server, not
/// on the phone.
///
/// Needs the stack and the functions served with the UI-test fixture switched on:
///
///   supabase start && supabase db reset
///   supabase functions serve --env-file <file with TRADING_ALLOW_FIXTURE_DATA=1 and TRADING_SCHEDULER_SECRET>
///
/// Skips (doesn't fail) when either isn't running. The anon key is the well-known local
/// demo key, not a secret.
final class TradingAccountTests: XCTestCase {
    private let apiURL = "http://127.0.0.1:58321"
    private let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0"
    private let password = "Stock-tracker-e2e-1"
    private var app: XCUIApplication!
    private var email = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        let health = try? request("GET", "/auth/v1/health")
        try XCTSkipUnless(health?.status == 200, "Local Supabase isn't running on \(apiURL)")
        // 401 without a session means the function is being served; 404 means it isn't.
        let probe = try? request("POST", "/functions/v1/trading-api", body: Data(#"{"action":"capabilities"}"#.utf8))
        try XCTSkipUnless(probe?.status == 401, "trading-api isn't being served (got \(probe?.status ?? 0))")

        email = "trading-e2e-\(Int(Date().timeIntervalSince1970))-\(Int.random(in: 100...999))@example.com"
        let signUp = try request("POST", "/auth/v1/signup",
                                 body: try JSONSerialization.data(withJSONObject: ["email": email, "password": password]))
        XCTAssertEqual(signUp.status, 200, String(decoding: signUp.data, as: UTF8.self))
        app = XCUIApplication()
    }

    private func launchSignedIn() {
        app.launchArguments = ["-UITestFreshInstall", "-UITestTradingFixture", "-hasCompletedOnboarding", "YES",
                               "-app_theme_mode", "Light",
                               "-SupabaseURLOverride", apiURL, "-SupabaseAnonKeyOverride", anonKey,
                               "-UITestSignIn", "\(email):\(password)"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Portfolio"].waitForExistence(timeout: 30), "The app should open on the tabs")
        XCTAssertTrue(app.open("Agents"))
        let inAccount = element("trading.home.account")
        if !inAccount.waitForExistence(timeout: 30) {
            attach("not-in-account")
            XCTFail("Trading should move to the account. Problem shown: \(element("trading.syncProblem").exists ? element("trading.syncProblem").label : "none")")
        }
    }

    // MARK: - Tests

    func testReconciledPortfolioReturnSyncs() throws {
        let token = try signIn()
        let probe = try request("GET", "/rest/v1/portfolio_performance_results?select=id,time_weighted_return_pct,money_weighted_return_pct&limit=1", token: token)
        try XCTSkipIf(probe.status == 404, "The local database needs the portfolio performance migration.")
        XCTAssertEqual(probe.status, 200)
        launchSignedIn()
        XCTAssertTrue(app.open("Portfolio"))
        tap("portfolio.returns.add")
        type("1000", into: "portfolio.returns.opening")
        type("1100", into: "portfolio.returns.closing")
        tap("portfolio.returns.save")
        let result = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "10.00%")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 25), "The saved period shows its return")
        let saved = try rows("portfolio_performance_results", select: "return_pct,time_weighted_return_pct,money_weighted_return_pct,investment_change_usd", token: token)
        for key in ["return_pct", "time_weighted_return_pct", "money_weighted_return_pct"] {
            XCTAssertEqual((saved.first?[key] as? NSNumber)?.doubleValue, 10, key)
        }
        XCTAssertEqual((saved.first?["investment_change_usd"] as? NSNumber)?.doubleValue, 100)
    }

    /// A manual order placed in the app is made by the server, and a fresh install that signs
    /// in again shows the same portfolio and position.
    func testPracticeOrderLivesInTheAccount() throws {
        launchSignedIn()
        attach("agents-in-account")

        createPracticePortfolio()
        let portfolio = app.buttons["practice.portfolio.Practice"]
        XCTAssertTrue(portfolio.waitForExistence(timeout: 15), "Practice portfolio card")
        portfolio.tap()
        tap("practice.buy")
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("BTC")
        tap("picker.BTC")

        XCTAssertTrue(element("ticket.price").waitForExistence(timeout: 20), "A price should load")
        type("1000", into: "ticket.amount")
        tap("ticket.review")
        XCTAssertTrue(element("ticket.review.sentence").waitForExistence(timeout: 10), "Review step")
        tap("ticket.place")
        let title = element("ticket.result.title")
        if !title.waitForExistence(timeout: 20) {
            attach("place-failed")
            XCTFail("No result. Problem shown: \(element("ticket.placeProblem").exists ? element("ticket.placeProblem").label : "none")")
        }
        XCTAssertEqual(title.label, "Practice order filled", element("ticket.result.detail").label)
        attach("account-order-filled")
        tap("ticket.done")
        XCTAssertTrue(element("practice.position.BTC").waitForExistence(timeout: 10), "BTC position")

        // On the server, seen as the person.
        let token = try signIn()
        let accounts = try rows("trading_accounts", select: "name,kind,currency,cash", token: token)
        XCTAssertEqual(accounts.filter { $0["kind"] as? String == "manualPaper" }.count, 1, "\(accounts)")
        let orders = try rows("orders", select: "status,side,source_kind,mode,instrument_id", token: token)
        XCTAssertEqual(orders.count, 1, "\(orders)")
        XCTAssertEqual(orders.first?["status"] as? String, "filled")
        XCTAssertEqual(orders.first?["mode"] as? String, "paper")
        XCTAssertEqual(orders.first?["source_kind"] as? String, "manual")
        let positions = try rows("positions", select: "instrument_id,quantity", token: token)
        XCTAssertEqual(positions.first?["instrument_id"] as? String, "crypto:BTC", "\(positions)")

        // A fresh install keeps nothing on the phone. Signing in again brings it all back.
        app.terminate()
        launchSignedIn()
        XCTAssertTrue(app.open("Portfolio"))
        let again = app.buttons["practice.portfolio.Practice"]
        for _ in 0..<6 where !again.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(again.waitForExistence(timeout: 15), "The portfolio comes back from the account")
        again.tap()
        XCTAssertTrue(element("practice.position.BTC").waitForExistence(timeout: 10), "The position comes back too")
        attach("account-restored")
    }

    /// An agent made in the app runs on the server: its first run proposes a trade, the
    /// approval is made by the server, and the agent and its order are rows in the account.
    func testAgentRunsOnTheServerAndApprovalFills() throws {
        launchSignedIn()
        tap("agents.new")
        type("Monitor BTC and ETH and ask me before each trade, with an 8% stop loss", into: "agent.new.prompt")
        tap("agent.new.draft")
        XCTAssertTrue(element("agent.draft.understood").waitForExistence(timeout: 10), "What it understood")
        tap("agent.draft.start")

        let approval = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'agents.approval.'")).firstMatch
        if !approval.waitForExistence(timeout: 60) {
            attach("no-proposal")
            XCTFail("A proposal should wait for approval. Problem shown: \(element("trading.syncProblem").exists ? element("trading.syncProblem").label : "none")")
        }
        attach("account-approval")
        approval.tap()
        XCTAssertTrue(element("proposal.status.pending").waitForExistence(timeout: 10))
        tap("proposal.approve")
        XCTAssertTrue(element("proposal.outcome.placed").waitForExistence(timeout: 30), "Approving places the order")
        tap("proposal.done")

        let token = try signIn()
        let agents = try rows("trading_agents", select: "name,mode,status,review_each_paper_trade", token: token)
        XCTAssertEqual(agents.count, 1, "\(agents)")
        XCTAssertEqual(agents.first?["review_each_paper_trade"] as? Bool, true)
        let proposals = try rows("trade_proposals", select: "status", token: token)
        // An approved proposal is "submitted": its order was placed (filled or not is the order's story).
        XCTAssertTrue(proposals.contains { $0["status"] as? String == "submitted" }, "\(proposals)")
        let orders = try rows("orders", select: "status,source_kind", token: token)
        XCTAssertTrue(orders.contains { $0["source_kind"] as? String == "agent" && $0["status"] as? String == "filled" }, "\(orders)")

        XCTAssertTrue(app.open("Activity"))
        let filled = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'order.row.' AND identifier ENDSWITH '.filled'")).firstMatch
        XCTAssertTrue(filled.waitForExistence(timeout: 10), "The approved order shows in Activity")
        select("Audit", in: "activity.section")
        XCTAssertTrue(element("audit.intact").waitForExistence(timeout: 5), "The server's audit trail verifies on the phone")
        attach("account-audit")
    }

    /// Pause-all goes through the server and comes back in the state the app shows.
    func testPauseAllInTheAccount() throws {
        launchSignedIn()
        tap("agents.new")
        tap("agent.template.trend")
        tap("agent.draft.start")
        let card = app.buttons["agents.card.Trend Following Agent"]
        XCTAssertTrue(card.waitForExistence(timeout: 30), "Agent card")

        tap("agents.pauseAll")
        XCTAssertTrue(element("pauseAll.sheet").waitForExistence(timeout: 5))
        tap("pauseAll.confirm")
        XCTAssertTrue(element("pauseAll.pausedTitle").waitForExistence(timeout: 15), "Paused (the server answered)")
        tap("pauseAll.dismiss")
        XCTAssertTrue(element("trading.pausedAllBanner").waitForExistence(timeout: 5), "Banner while paused")
        XCTAssertTrue(card.label.contains("Paused by Pause all"), card.label)
        let token = try signIn()
        let agents = try rows("trading_agents", select: "status,pause_reason", token: token)
        XCTAssertEqual(agents.first?["status"] as? String, "paused", "\(agents)")
        XCTAssertEqual(agents.first?["pause_reason"] as? String, "killSwitch", "\(agents)")
        attach("account-paused")
    }

    // MARK: - App helpers

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    private func tap(_ id: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let target = app.buttons[id].exists ? app.buttons[id] : element(id)
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "\(id) should appear", file: file, line: line)
        var tries = 0
        while !target.isHittable && tries < 8 { app.swipeUp(velocity: .slow); tries += 1 }
        target.tap()
    }

    private func type(_ text: String, into id: String) {
        let field = app.textFields[id].exists ? app.textFields[id] : element(id)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "\(id) field")
        field.tap()
        field.typeText(text)
    }

    private func select(_ segment: String, in control: String) {
        let button = app.segmentedControls[control].buttons[segment]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "\(segment) segment")
        for _ in 0..<4 where !button.isSelected {
            button.tap()
            _ = button.wait(for: \.isSelected, toEqual: true, timeout: 2)
        }
    }

    private func createPracticePortfolio() {
        XCTAssertTrue(app.open("Portfolio"))
        let setUp = app.buttons["Set up practice money"]
        let add = app.buttons["practice.add"]
        for _ in 0..<8 where !setUp.isHittable && !add.isHittable { app.swipeUp(velocity: .slow) }
        if setUp.isHittable { setUp.tap() } else { add.tap() }
        XCTAssertTrue(element("practice.setup").waitForExistence(timeout: 10), "Practice setup")
        tap("practice.balance.10000")
        tap("practice.start")
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - REST as the person

    private func signIn() throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        let response = try request("POST", "/auth/v1/token?grant_type=password", body: body)
        XCTAssertEqual(response.status, 200, "Password sign-in")
        let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
        return try XCTUnwrap(json?["access_token"] as? String)
    }

    private func rows(_ table: String, select: String, token: String) throws -> [[String: Any]] {
        let response = try request("GET", "/rest/v1/\(table)?select=\(select)", token: token)
        XCTAssertEqual(response.status, 200, "GET \(table): \(String(decoding: response.data, as: UTF8.self))")
        return (try JSONSerialization.jsonObject(with: response.data) as? [[String: Any]]) ?? []
    }

    private func request(_ method: String, _ path: String, body: Data? = nil, token: String? = nil) throws -> (status: Int, data: Data) {
        var req = URLRequest(url: URL(string: apiURL + path)!, timeoutInterval: 15)
        req.httpMethod = method
        req.httpBody = body
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token ?? anonKey)", forHTTPHeaderField: "Authorization")
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        var result: (Int, Data)?
        var failure: Error?
        let done = expectation(description: "\(method) \(path)")
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error { failure = error }
            result = ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data())
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 20)
        if let failure { throw failure }
        return try XCTUnwrap(result)
    }
}
