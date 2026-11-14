//
//  AccountSyncTests.swift
//  Stock TrackerUITests
//
//  End-to-end accounts against a LOCAL Supabase stack built from supabase/migrations:
//  sign up during onboarding → picks upload → referral code is created → a fresh
//  install signs in and gets the watchlist back → a friend signs up with the code.
//
//  Start the stack first from the repo root (the test skips itself otherwise):
//    supabase start -x vector,logflare,imgproxy,studio,storage-api,realtime,edge-runtime,postgres-meta,supavisor
//  The anon key below is the well-known local-development demo key, not a secret.
//

import XCTest

final class AccountSyncTests: XCTestCase {
    private let apiURL = ProcessInfo.processInfo.environment["STOCK_TRACKER_UI_TEST_API"] ?? "http://127.0.0.1:58321"
    private let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0"
    private let password = "Stock-tracker-e2e-1"
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let health = try? request("GET", "/auth/v1/health")
        try XCTSkipUnless(health?.status == 200, "Local Supabase isn't running on \(apiURL)")
        app = XCUIApplication()
        // iOS's "Save Password?" / strong-password prompts after sign-up.
        addUIInterruptionMonitor(withDescription: "Password prompts") { prompt in
            for label in ["Not Now", "Not now", "Never for This Website"] where prompt.buttons[label].exists {
                prompt.buttons[label].tap()
                return true
            }
            return false
        }
    }

    func testExploreShowsSourcedRankingsAndOpensSavedList() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STOCK_TRACKER_UI_TEST_EXPLORE"] == "1",
                          "Start the signed-in Explore relay")
        let email = "explore-ios-\(UUID().uuidString.lowercased())@example.com"
        let signup = try request("POST", "/auth/v1/signup", body: JSONSerialization.data(withJSONObject: [
            "email": email, "password": password,
        ]))
        XCTAssertEqual(signup.status, 200)
        let token = try signIn(email: email)
        let result = try request("POST", "/functions/v1/market-workspace",
                                 body: JSONSerialization.data(withJSONObject: ["action": "explore"]), token: token)
        XCTAssertEqual(result.status, 200)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        let data = try XCTUnwrap(envelope["data"] as? [String: Any])
        let movers = try XCTUnwrap(data["us"] as? [String: Any])
        let source = try XCTUnwrap(movers["source"] as? String)
        let session = try request("GET", "/auth/v1/user", token: token)
        let user = try XCTUnwrap(JSONSerialization.jsonObject(with: session.data) as? [String: Any])
        let owner = try XCTUnwrap(user["id"] as? String)
        let seed = try request("POST", "/rest/v1/rpc/apply_watchlist_change",
                               body: JSONSerialization.data(withJSONObject: [
            "p_user_id": owner, "p_id": UUID().uuidString, "p_group_id": UUID().uuidString,
            "p_action": "import", "p_name": "Research", "p_assets": [[
                "listing_id": "us:AAPL", "symbol": "AAPL", "name": "Apple", "kind": "Stock", "exchange": "US",
            ]],
        ]), token: token)
        XCTAssertEqual(seed.status, 204)

        app.launchArguments = ["-UITestFreshInstall", "-UITestTradingFixture", "-hasCompletedOnboarding", "YES",
                               "-SupabaseURLOverride", apiURL, "-SupabaseAnonKeyOverride", anonKey,
                               "-UITestSignIn", "\(email):\(password)", "-app_theme_mode", "Light"]
        app.launch()
        XCTAssertTrue(app.open("Explore", timeout: 25))
        let sourceLabel = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", source)).firstMatch
        XCTAssertTrue(sourceLabel.waitForExistence(timeout: 20))
        let losers = app.segmentedControls["explore.moverDirection"].buttons["Losers"]
        if !losers.isHittable { app.swipeUp() }
        losers.tap()
        XCTAssertTrue(losers.isSelected)
        XCTAssertTrue(app.staticTexts["Trending crypto"].exists)

        let research = app.buttons["explore.watchlist.Research"]
        for _ in 0..<9 where !research.isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Recently added"].exists)
        XCTAssertTrue(research.isHittable)
        research.tap()
        XCTAssertTrue(app.buttons["watchlist.row.AAPL"].waitForExistence(timeout: 8))

        XCTAssertTrue(app.open("Search"))
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        field.typeText("^GSPC")
        let index = app.buttons["search.result.index.^GSPC"]
        XCTAssertTrue(index.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["search.result.index.^GSPC.toggle"].exists)
    }

    func testNamedPortfoliosKeepHoldingsSeparateAcrossSignInAndRename() throws {
        let email = "portfolio-groups-ios-\(UUID().uuidString.lowercased())@example.com"
        let signup = try request("POST", "/auth/v1/signup", body: JSONSerialization.data(withJSONObject: [
            "email": email, "password": password,
        ]))
        XCTAssertEqual(signup.status, 200)
        let token = try signIn(email: email)
        let session = try request("GET", "/auth/v1/user", token: token)
        let user = try XCTUnwrap(JSONSerialization.jsonObject(with: session.data) as? [String: Any])
        let owner = try XCTUnwrap(user["id"] as? String)
        let research = UUID().uuidString
        let income = UUID().uuidString
        for (id, name) in [(research, "Research"), (income, "Income")] {
            let result = try request("POST", "/rest/v1/rpc/apply_portfolio_group_change",
                                     body: JSONSerialization.data(withJSONObject: [
                "p_user_id": owner, "p_id": UUID().uuidString, "p_group_id": id,
                "p_action": "create", "p_name": name, "p_emoji": "💼",
            ]), token: token)
            XCTAssertEqual(result.status, 204, String(decoding: result.data, as: UTF8.self))
        }
        let fixtures: [(String, String, Any)] = [
            ("AAPL", "Apple", NSNull()), ("QQQ", "Invesco QQQ", research), ("MSFT", "Microsoft", income),
        ]
        let holdings = fixtures.map { symbol, name, group in
            ["id": UUID().uuidString, "user_id": owner, "asset_symbol": symbol, "asset_name": name,
             "asset_exchange": "US", "asset_kind": symbol == "QQQ" ? "ETF" : "Stock",
             "shares": 2, "avg_cost": 20, "portfolio_group_id": group] as [String: Any]
        }
        let inserted = try request("POST", "/rest/v1/portfolio_holdings",
                                   body: JSONSerialization.data(withJSONObject: holdings), token: token)
        XCTAssertEqual(inserted.status, 201, String(decoding: inserted.data, as: UTF8.self))
        app.launchArguments = ["-UITestFreshInstall", "-UITestTradingFixture", "-hasCompletedOnboarding", "YES",
                               "-SupabaseURLOverride", apiURL, "-SupabaseAnonKeyOverride", anonKey,
                               "-UITestSignIn", "\(email):\(password)", "-app_theme_mode", "Light"]
        app.launch()
        XCTAssertTrue(app.open("Portfolio", timeout: 25))

        func verifyHolding(_ ticker: String) {
            let row = app.buttons["portfolio.holding.\(ticker)"]
            for _ in 0..<9 where !row.isHittable { app.swipeUp() }
            XCTAssertTrue(row.waitForExistence(timeout: 12), app.debugDescription)
            for (symbol, _, _) in fixtures where symbol != ticker {
                XCTAssertFalse(app.buttons["portfolio.holding.\(symbol)"].exists)
            }
        }
        func openMenu(_ name: String) {
            let bar = app.navigationBars[name]
            XCTAssertTrue(bar.waitForExistence(timeout: 8))
            let title = bar.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
            XCTAssertTrue(title.exists, bar.debugDescription)
            title.tap()
        }
        verifyHolding("AAPL")
        openMenu("Main Portfolio")
        app.buttons["Research"].tap()
        verifyHolding("QQQ")
        openMenu("Research")
        app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Income", "portfolio.segment.income")).firstMatch.tap()
        verifyHolding("MSFT")
        openMenu("Income")
        app.buttons["Rename…"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Income".count) + "Dividends")
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Dividends"].waitForExistence(timeout: 8))

        var cloud: [[String: Any]] = []
        for _ in 0..<15 {
            cloud = try rows("portfolio_groups", select: "id,name", token: token)
            if cloud.contains(where: { $0["name"] as? String == "Dividends" }) { break }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertEqual(cloud.first { $0["name"] as? String == "Dividends" }?["id"] as? String, income.lowercased())
        app.terminate()
        app.launch()
        XCTAssertTrue(app.open("Portfolio", timeout: 25))
        verifyHolding("AAPL")
        openMenu("Main Portfolio")
        app.buttons["Dividends"].tap()
        verifyHolding("MSFT")
    }

    func testNamedWatchlistsSyncBetweenAppAndAccount() throws {
        let email = "watchlists-ios-\(UUID().uuidString.lowercased())@example.com"
        let signup = try request("POST", "/auth/v1/signup", body: JSONSerialization.data(withJSONObject: [
            "email": email, "password": password,
        ]))
        XCTAssertEqual(signup.status, 200)
        let session = try request("POST", "/auth/v1/token?grant_type=password", body: JSONSerialization.data(withJSONObject: [
            "email": email, "password": password,
        ]))
        let account = try XCTUnwrap(JSONSerialization.jsonObject(with: session.data) as? [String: Any])
        let token = try XCTUnwrap(account["access_token"] as? String)
        let user = try XCTUnwrap(account["user"] as? [String: Any])
        let owner = try XCTUnwrap(user["id"] as? String)
        let named = UUID().uuidString
        let defaultID = "00000000-0000-0000-0000-000000000001"
        let apple = ["listing_id": "us:AAPL", "symbol": "AAPL", "name": "Apple", "kind": "Stock", "exchange": "US"]
        let bitcoin = ["listing_id": "crypto:BTC", "symbol": "BTC", "name": "Bitcoin", "kind": "Crypto"]
        func mutate(_ action: String, group: String, name: String? = nil, assets: [[String: String]] = []) throws {
            var payload: [String: Any] = [
                "p_user_id": owner, "p_id": UUID().uuidString, "p_group_id": group, "p_action": action, "p_assets": assets,
            ]
            payload["p_name"] = name
            let response = try request("POST", "/rest/v1/rpc/apply_watchlist_change",
                                       body: JSONSerialization.data(withJSONObject: payload), token: token)
            XCTAssertEqual(response.status, 204, String(decoding: response.data, as: UTF8.self))
        }
        func cloud() throws -> [[String: Any]] {
            let response = try request("POST", "/rest/v1/rpc/get_watchlists",
                                       body: JSONSerialization.data(withJSONObject: ["p_user_id": owner]), token: token)
            XCTAssertEqual(response.status, 200)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: response.data) as? [[String: Any]])
        }
        func symbols(_ groups: [[String: Any]], named name: String) -> [String] {
            let group = groups.first { ($0["name"] as? String) == name }
            return (group?["assets"] as? [[String: Any]] ?? []).compactMap { $0["symbol"] as? String }
        }
        try mutate("add", group: defaultID, assets: [apple])
        try mutate("import", group: named, name: "Research", assets: [apple, bitcoin])

        app.launchArguments = ["-UITestFreshInstall", "-UITestTradingFixture", "-hasCompletedOnboarding", "YES",
                               "-SupabaseURLOverride", apiURL, "-SupabaseAnonKeyOverride", anonKey,
                               "-UITestSignIn", "\(email):\(password)", "-app_theme_mode", "Light"]
        app.launch()
        XCTAssertTrue(app.open("Watchlist", timeout: 25))
        let appleRow = app.buttons["watchlist.row.AAPL"]
        let bitcoinRow = app.buttons["watchlist.row.BTC"]
        let menu = app.buttons["watchlist.listMenu"]
        XCTAssertTrue(appleRow.waitForExistence(timeout: 20))
        XCTAssertFalse(bitcoinRow.exists)
        menu.tap()
        let research = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Research ·")).firstMatch
        XCTAssertTrue(research.waitForExistence(timeout: 5))
        research.tap()
        XCTAssertTrue(appleRow.exists)
        XCTAssertTrue(bitcoinRow.waitForExistence(timeout: 8))
        app.buttons["watchlist.edit"].tap()
        appleRow.tap()
        app.buttons["watchlist.deleteSelected"].tap()
        app.buttons["watchlist.done"].tap()
        XCTAssertTrue(appleRow.waitForNonExistence(timeout: 5))

        menu.tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Rename “Research”")).firstMatch.tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        if let value = field.value as? String {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        field.typeText("Ideas")
        app.alerts.buttons["Save"].tap()

        var groups: [[String: Any]] = []
        for _ in 0..<15 {
            groups = try cloud()
            if symbols(groups, named: "Ideas") == ["BTC"] { break }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertEqual(symbols(groups, named: "Ideas"), ["BTC"])
        XCTAssertEqual(symbols(groups, named: "My Watchlist"), ["AAPL"])

        app.terminate()
        app.launch()
        XCTAssertTrue(app.open("Watchlist", timeout: 25))
        XCTAssertTrue(appleRow.waitForExistence(timeout: 20))
        menu.tap()
        let ideas = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Ideas ·")).firstMatch
        XCTAssertTrue(ideas.waitForExistence(timeout: 5))
        ideas.tap()
        XCTAssertTrue(bitcoinRow.waitForExistence(timeout: 8))
        XCTAssertFalse(appleRow.exists)
    }

    func testNewInvestorSignsUpAndReviewsLinkedBrokerage() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STOCK_TRACKER_UI_TEST_ONBOARDING_BROKER"] == "1",
                          "Start the signed-in onboarding brokerage relay")
        let email = "investor-onboarding-ios-\(UUID().uuidString.lowercased())@example.com"
        launch(extraArguments: ["-UITestTypeOwnPassword", "-AppleLocale", "en_US"])
        app.buttons["onboarding.welcome.create"].tap()
        waitForStep("Create your Stock Tracker account")
        fillCredentials(email: email)
        let submit = app.buttons["auth.submit"]
        XCTAssertTrue(submit.isEnabled, app.debugDescription)
        app.secureTextFields["auth.password"].typeText("\n")
        waitForStep("What do you want to track?", timeout: 25)
        declineSavePassword()
        let continueButton = app.buttons["onboarding.continue"]
        XCTAssertTrue(continueButton.wait(for: \.isHittable, toEqual: true, timeout: 8), app.debugDescription)
        let us = app.buttons["onboarding.market.us"]
        if !us.isSelected {
            for _ in 0..<3 where !us.isHittable { app.swipeUp(velocity: .slow) }
            XCTAssertTrue(us.isHittable, app.debugDescription)
            us.tap()
        }
        XCTAssertTrue(us.isSelected)
        continueButton.tap()
        waitForStep("Pick a few to follow")
        let apple = app.buttons["onboarding.pick.AAPL"]
        if !apple.exists { app.buttons["US"].firstMatch.tap() }
        XCTAssertTrue(apple.waitForExistence(timeout: 8))
        apple.tap()
        tapContinue()
        waitForStep("Add what you already own")
        let connectBroker = app.buttons["onboarding.portfolio.broker"]
        for _ in 0..<3 where !connectBroker.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(connectBroker.isHittable, app.debugDescription)
        connectBroker.tap()
        XCTAssertTrue(app.navigationBars["Brokers & exchanges"].waitForExistence(timeout: 10))
        app.buttons["broker.seeAll"].tap()
        let picker = app.searchFields.firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.tap()
        picker.typeText("Sandbox")
        let sandbox = app.buttons["broker.pick.SANDBOX"]
        XCTAssertTrue(sandbox.waitForExistence(timeout: 15))
        sandbox.tap()
        let linked = app.descendants(matching: .any)["broker.connected"].firstMatch
        let closePortal = app.buttons.matching(NSPredicate(format: "label IN {'Done', 'Close'} AND identifier != 'broker.done'")).firstMatch
        let portalOrLinked = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in linked.exists || closePortal.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [portalOrLinked], timeout: 55), .completed)
        if !linked.exists && closePortal.exists { closePortal.tap() }
        XCTAssertTrue(linked.waitForExistence(timeout: 30), app.debugDescription)
        let brokerActivity = app.buttons["broker.activity"]
        for _ in 0..<7 where !brokerActivity.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(brokerActivity.isHittable)
        brokerActivity.tap()
        XCTAssertTrue(app.navigationBars["Recent broker activity"].waitForExistence(timeout: 8))
        app.buttons["Find linked accounts"].tap()
        XCTAssertTrue(app.buttons["Load broker activity"].waitForExistence(timeout: 15))
        app.buttons["Load broker activity"].tap()
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !self.app.staticTexts["Loading brokerage data"].exists &&
                !self.app.staticTexts["Couldn’t load brokerage activity. Try again."].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 25), .completed)
        app.navigationBars["Recent broker activity"].buttons.firstMatch.tap()
        app.buttons["broker.done"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'holding' AND label CONTAINS[c] 'added'")).firstMatch.waitForExistence(timeout: 10))
        tapContinue()
        waitForStep("Know when it moves")
        app.buttons["onboarding.notifications.notNow"].tap()
        if app.staticTexts["Keep your portfolio private"].waitForExistence(timeout: 2) { app.buttons["Not now"].tap() }
        waitForStep("You're all set")
        app.buttons["onboarding.finish"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["home.portfolio"].firstMatch.waitForExistence(timeout: 20))
        let token = try signIn(email: email)
        let holdings = try rows("portfolio_holdings", select: "asset_symbol,shares,broker_account", token: token)
        XCTAssertFalse(holdings.isEmpty)
        XCTAssertTrue(holdings.allSatisfy { ($0["shares"] as? Double ?? 0) > 0 && $0["broker_account"] is [String: Any] })
    }

    func testSignUpSyncsWatchlistReferralAndRestoresOnNewInstall() throws {
        let email = "e2e-\(Int(Date().timeIntervalSince1970))@example.com"
        let picks = ["BHP", "AAPL", "BTC"]

        // 1. New user signs up on onboarding's account step.
        launch()
        signUpThroughOnboarding(email: email, picks: picks)
        for symbol in picks {
            XCTAssertTrue(app.buttons["home.watchlist.\(symbol)"].waitForExistence(timeout: 30), "\(symbol) on Home")
        }

        // 2. The picks reach the cloud (2s upload debounce), visible to this user under RLS.
        let token = try signIn(email: email)
        var cloud: [String] = []
        for _ in 0..<20 {
            cloud = try rows("watchlist_assets", select: "symbol", token: token).compactMap { $0["symbol"] as? String }
            if Set(picks).isSubset(of: cloud) { break }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertEqual(Set(cloud), Set(picks), "Watchlist uploaded to Supabase")

        // 3. Refer a friend creates a real code (generate_referral_code RPC) and shows it.
        let gear = app.buttons["Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 5), "Settings button on Home")
        gear.tap()
        XCTAssertTrue(app.buttons["settings.done"].waitForExistence(timeout: 5), "Settings should open")
        attach("settings-signed-in")
        // Settings is a lazy List: rows below the fold don't exist until scrolled to.
        let referrals = app.buttons["settings.referrals"]
        for _ in 0..<8 where !(referrals.exists && referrals.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(referrals.exists, "Refer a friend in Settings")
        referrals.tap()
        let codeView = app.descendants(matching: .any)["referrals.code"]
        XCTAssertTrue(codeView.waitForExistence(timeout: 20), "Invite code appears for a signed-in user")
        Thread.sleep(forTimeInterval: 1)
        attach("referral-code")
        let codes = try rows("referral_codes", select: "code", token: token).compactMap { $0["code"] as? String }
        XCTAssertEqual(codes.count, 1, "One code per user")
        let code = try XCTUnwrap(codes.first)
        XCTAssertTrue(app.staticTexts[code].exists || codeView.label.contains(code), "Screen shows the server's code \(code)")

        // 4. A fresh install (local data and keychain wiped) signs in: the watchlist comes back.
        app.terminate()
        launch()
        app.buttons["I already have an account"].tap()
        fillCredentials(email: email)
        app.buttons["auth.submit"].tap()
        declineSavePassword()
        for symbol in picks {
            XCTAssertTrue(app.buttons["home.watchlist.\(symbol)"].waitForExistence(timeout: 40),
                          "\(symbol) restored from the cloud")
        }
        attach("restored-home")

        // 5. A friend signs up with that code: the server records the referral for the
        //    code's owner (validated through referral_code_owner, not a readable table).
        app.terminate()
        launch()
        let friend = "friend-" + email
        signUpThroughOnboarding(email: friend, picks: ["AAPL"], referralCode: code)
        var recorded: [[String: Any]] = []
        for _ in 0..<15 {
            recorded = try rows("referrals", select: "code_used,status,signed_up_at", token: token)
            if !recorded.isEmpty { break }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertEqual(recorded.count, 1, "The referrer sees their friend's referral")
        XCTAssertEqual(recorded.first?["code_used"] as? String, code)
        XCTAssertEqual(recorded.first?["status"] as? String, "pending")
        let friendToken = try signIn(email: friend)
        XCTAssertEqual(try rows("referral_codes", select: "code", token: friendToken)
                        .compactMap { $0["code"] as? String }.contains(code), false,
                       "Other people's codes aren't readable")
    }

    func testBrokerHoldingsKeepAccountsSeparateAfterTransferAndFreshSignIn() throws {
        let email = "income-ui-\(UUID().uuidString.lowercased())@example.com"
        let signup = try request("POST", "/auth/v1/signup", body: JSONSerialization.data(withJSONObject: [
            "email": email, "password": password
        ]))
        XCTAssertEqual(signup.status, 200)
        let token = try signIn(email: email)
        let source = "a8cc1385-31a7-4c4d-9955-6789589cc956"
        let receiver = "0cc77f5f-2b5f-481a-95cb-e44b9c0ad97f"

        func launch() {
            app.launchArguments = ["-UITestFreshInstall", "-UITestTradingFixture", "-hasCompletedOnboarding", "YES",
                "-UITestBrokerFixture", "-UITestBrokerMultiAccount", "-SupabaseURLOverride", apiURL,
                "-SupabaseAnonKeyOverride", anonKey, "-UITestSignIn", "\(email):\(password)"]
            app.launch()
            XCTAssertTrue(app.open("Portfolio"))
        }
        func brokerRows() throws -> [[String: Any]] {
            try rows("portfolio_holdings", select: "id,asset_symbol,shares,broker_account,deleted_at", token: token)
                .filter { $0["asset_symbol"] as? String == "BHP" && $0["broker_account"] is [String: Any] }
        }
        func byAccount(_ positions: [[String: Any]]) -> [String: Double] {
            Dictionary(positions.compactMap { row in
                guard let account = row["broker_account"] as? [String: Any], let id = account["account_id"] as? String,
                      let shares = row["shares"] as? Double else { return nil }
                return (id, shares)
            }, uniquingKeysWith: { _, latest in latest })
        }
        func waitForPositions(_ expected: [String: Double]) throws -> [[String: Any]] {
            for _ in 0..<12 {
                let current = try brokerRows()
                if byAccount(current) == expected { return current }
                Thread.sleep(forTimeInterval: 1)
            }
            let current = try brokerRows()
            XCTAssertEqual(byAccount(current), expected)
            return current
        }

        launch()
        XCTAssertTrue(app.staticTexts["Dividends and distributions"].waitForExistence(timeout: 15))
        let connect = app.buttons["Connect a broker"].firstMatch
        XCTAssertTrue(connect.waitForExistence(timeout: 8))
        connect.tap()
        let tile = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'broker.popular.'")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 8))
        tile.tap()
        let before = try waitForPositions([source: 50, receiver: 20])
        XCTAssertEqual(before.count, 2)
        let beforeIDs = Set(before.compactMap { $0["id"] as? String })
        let original = try rows("transactions", select: "id,holding_id,shares,trade_provenance,deleted_at", token: token)
            .filter { beforeIDs.contains($0["holding_id"] as? String ?? "") }
        XCTAssertEqual(original.count, 2)
        let sync = app.buttons["broker.sync"].firstMatch
        for _ in 0..<5 where !sync.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(sync.isHittable)
        sync.tap()
        let after = try waitForPositions([source: 0, receiver: 70])
        XCTAssertEqual(Set(after.compactMap { $0["id"] as? String }), beforeIDs)
        XCTAssertEqual(after.filter { $0["deleted_at"] is NSNull }.count, 2)
        let retained = try rows("transactions", select: "id,holding_id,shares,trade_provenance,deleted_at", token: token)
            .filter { beforeIDs.contains($0["holding_id"] as? String ?? "") && $0["deleted_at"] is NSNull }
        XCTAssertEqual(Set(retained.compactMap { $0["id"] as? String }), Set(original.compactMap { $0["id"] as? String }))
        XCTAssertEqual(retained.compactMap { $0["shares"] as? Double }.sorted(), [20, 50])

        app.terminate()
        launch()
        let holding = app.buttons["portfolio.holding.BHP"].firstMatch
        for _ in 0..<8 where !holding.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(holding.isHittable)
        XCTAssertTrue(holding.label.contains("70 shares"), holding.label)
        XCTAssertTrue(holding.label.contains("4321"), holding.label)
        XCTAssertEqual(app.buttons.matching(identifier: "portfolio.holding.BHP").count, 1)
        XCTAssertEqual(try brokerRows().count, 2)
    }

    func testCurrentBrokerPositionsKeepPriorQuantitiesWhenAnAccountFails() throws {
        // Start scripts/snaptrade-positions-fixture.py and point STOCK_TRACKER_UI_TEST_API at port 58346.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STOCK_TRACKER_UI_TEST_BROKER_POSITIONS"] == "1",
                          "Start the SnapTrade positions fixture relay")
        let email = "income-ui-\(UUID().uuidString.lowercased())@example.com"
        let signup = try request("POST", "/auth/v1/signup", body: JSONSerialization.data(withJSONObject: [
            "email": email, "password": password
        ]))
        XCTAssertEqual(signup.status, 200)
        let token = try signIn(email: email)
        func holdings() throws -> [[String: Any]] {
            try rows("portfolio_holdings", select: "id,asset_symbol,shares,broker_account", token: token)
        }
        func quantities(_ rows: [[String: Any]]) -> [Double] {
            rows.compactMap { $0["shares"] as? Double }.sorted()
        }

        app.launchArguments = ["-UITestFreshInstall", "-UITestTradingFixture", "-hasCompletedOnboarding", "YES",
            "-SupabaseURLOverride", apiURL, "-SupabaseAnonKeyOverride", anonKey, "-UITestSignIn", "\(email):\(password)"]
        app.launch()
        XCTAssertTrue(app.open("Portfolio"))
        var original: [[String: Any]] = []
        for _ in 0..<15 {
            original = try holdings()
            if quantities(original) == [20, 50] { break }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertEqual(quantities(original), [20, 50])
        XCTAssertEqual(original.compactMap { $0["asset_symbol"] as? String }, ["BHP", "BHP"])
        let account = app.buttons["portfolio.account.CommSec"]
        for _ in 0..<7 where !account.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(account.isHittable)
        account.tap()
        let sync = app.buttons["broker.sync"]
        XCTAssertTrue(sync.waitForExistence(timeout: 8))
        for phase in ["disconnected", "failure"] {
            XCTAssertEqual(try request("POST", "/qa/broker-positions/\(phase)", token: token).status, 200)
            sync.tap()
            let failure = app.alerts["Couldn’t sync brokerage positions"]
            XCTAssertTrue(failure.waitForExistence(timeout: 12), phase)
            XCTAssertEqual(quantities(try holdings()), [20, 50], phase)
            failure.buttons["OK"].tap()
        }
        XCTAssertEqual(try request("POST", "/qa/broker-positions/transfer", token: token).status, 200)
        sync.tap()
        var refreshed: [[String: Any]] = []
        for _ in 0..<15 {
            refreshed = try holdings()
            if quantities(refreshed) == [0, 70] { break }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertEqual(quantities(refreshed), [0, 70])
        XCTAssertEqual(Set(refreshed.compactMap { $0["id"] as? String }), Set(original.compactMap { $0["id"] as? String }))
    }

    func testBrokerCashShowsOriginalCurrenciesAndRespectsHiddenValues() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STOCK_TRACKER_UI_TEST_BROKER_CASH"] == "1",
                          "Start the brokerage fixture relay")
        let email = "broker-cash-ui-\(UUID().uuidString.lowercased())@example.com"
        let signup = try request("POST", "/auth/v1/signup", body: JSONSerialization.data(withJSONObject: [
            "email": email, "password": password,
        ]))
        XCTAssertEqual(signup.status, 200)
        let token = try signIn(email: email)
        func openCash(hidden: Bool) {
            app.launchArguments = ["-UITestFreshInstall", "-UITestTradingFixture", "-hasCompletedOnboarding", "YES",
                "-SupabaseURLOverride", apiURL, "-SupabaseAnonKeyOverride", anonKey, "-UITestSignIn", "\(email):\(password)",
                "-portfolioValueHidden", hidden ? "YES" : "NO"]
            app.launch()
            XCTAssertTrue(app.open("Portfolio"))
            let entry = app.descendants(matching: .any)["portfolio.brokerCash.open"].firstMatch
            let screen = app.frame.insetBy(dx: 0, dy: 70)
            for _ in 0..<6 {
                if entry.exists && !entry.frame.isEmpty && screen.contains(entry.frame) { break }
                app.swipeUp(velocity: .slow)
            }
            XCTAssertTrue(entry.exists && !entry.frame.isEmpty && screen.contains(entry.frame))
            entry.tap()
            XCTAssertTrue(app.navigationBars["Brokerage cash"].waitForExistence(timeout: 8))
        }

        openCash(hidden: false)
        let balance = "portfolio.brokerCash.balance.a8cc1385-31a7-4c4d-9955-6789589cc956."
        let aud = app.staticTexts[balance + "AUD"]
        let debit = app.staticTexts[balance + "USD"]
        XCTAssertTrue(aud.waitForExistence(timeout: 10))
        XCTAssertTrue(aud.label.contains("312.34"))
        XCTAssertTrue(debit.label.contains("12.34") && (debit.label.contains("-") || debit.label.contains("−")))
        XCTAssertTrue(app.staticTexts[balance + "GBP"].label.contains("Unavailable"))
        XCTAssertTrue(app.staticTexts["Cash balance unavailable."].exists)
        let original = try rows("portfolio_holdings", select: "id,shares", token: token)
        XCTAssertTrue(try rows("portfolio_performance_periods", select: "id", token: token).isEmpty)

        app.terminate()
        openCash(hidden: true)
        XCTAssertTrue(aud.waitForExistence(timeout: 10))
        XCTAssertTrue(aud.label.contains("••••") && !aud.label.contains("312.34"))
        XCTAssertTrue(debit.label.contains("••••") && !debit.label.contains("12.34"))
        XCTAssertEqual(try rows("portfolio_holdings", select: "id,shares", token: token).count, original.count)
    }

    func testHoldingsComparisonSearchFiltersAndRespectsHiddenBalances() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STOCK_TRACKER_UI_TEST_HOLDINGS_COMPARISON"] == "1",
                          "Start the holdings comparison quote fixture relay")
        let email = "holdings-comparison-ui-\(UUID().uuidString.lowercased())@example.com"
        let signup = try request("POST", "/auth/v1/signup", body: JSONSerialization.data(withJSONObject: [
            "email": email, "password": password,
        ]))
        XCTAssertEqual(signup.status, 200)
        let account = try XCTUnwrap(JSONSerialization.jsonObject(with: signup.data) as? [String: Any])
        let userId = try XCTUnwrap((account["user"] as? [String: Any] ?? account)["id"] as? String)
        let token = try signIn(email: email)
        let now = ISO8601DateFormatter().string(from: Date())
        func holding(_ symbol: String, name: String, kind: String, exchange: String, units: Double, account: String? = nil) -> [String: Any] {
            var row: [String: Any] = [
                "id": UUID().uuidString.lowercased(), "user_id": userId, "asset_symbol": symbol,
                "asset_name": name, "asset_kind": kind, "asset_exchange": exchange,
                "shares": units, "avg_cost": 40, "date_added": now,
                "broker_account": NSNull(),
            ]
            if let account {
                row["broker_account"] = [
                    "account_id": UUID().uuidString.lowercased(), "label": "Test Broker ••••\(account)",
                    "institution": "Test Broker", "observed_at": now, "tracking": true,
                ] as [String: Any]
            }
            return row
        }
        let holdings = [
            holding("AAPL", name: "Apple", kind: "Stock", exchange: "NASDAQ", units: 2, account: "1212"),
            holding("AAPL", name: "Apple", kind: "Stock", exchange: "NASDAQ", units: 1, account: "3434"),
            holding("QQQ", name: "Invesco Nasdaq 100", kind: "Stock", exchange: "NASDAQ", units: 1),
            holding("BTC", name: "Bitcoin", kind: "Crypto", exchange: "Crypto", units: 0.001),
        ]
        XCTAssertEqual(try request("POST", "/rest/v1/portfolio_holdings",
                                   body: JSONSerialization.data(withJSONObject: holdings), token: token).status, 201)

        app.launchArguments = ["-UITestFreshInstall", "-UITestTradingFixture",
            "-SupabaseURLOverride", apiURL, "-SupabaseAnonKeyOverride", anonKey,
            "-UITestSignIn", "\(email):\(password)", "-app_theme_mode", "Dark", "-portfolioSegment", "holdings",
            "-preferredCurrency", "USD"]
        app.launch()
        XCTAssertTrue(app.open("Portfolio"))

        func reveal(_ element: XCUIElement, lookingAbove: Bool = false) {
            for _ in 0..<16 {
                let frame = element.exists ? element.frame : .zero
                if !frame.isEmpty && app.frame.insetBy(dx: 0, dy: 90).contains(CGPoint(x: frame.midX, y: frame.midY)) { return }
                let down = frame.isEmpty ? lookingAbove : frame.midY < app.frame.midY
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.54, dy: down ? 0.37 : 0.65))
                let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.54, dy: down ? 0.63 : 0.38))
                start.press(forDuration: 0.04, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
            }
            XCTAssertTrue(element.isHittable, "Expected \(element)")
        }

        let search = app.textFields["portfolio.holdings.search"]
        let filter = app.buttons["portfolio.holdings.filter"]
        let sort = app.buttons["portfolio.sort"]
        let appleRows = app.buttons.matching(identifier: "portfolio.holding.AAPL")
        let apple = appleRows.matching(NSPredicate(format: "label CONTAINS '1212'")).firstMatch
        let secondApple = appleRows.matching(NSPredicate(format: "label CONTAINS '3434'")).firstMatch
        let fund = app.buttons["portfolio.holding.QQQ"]
        let bitcoin = app.buttons["portfolio.holding.BTC"]
        reveal(apple)
        let quoted = NSPredicate(format: "label CONTAINS 'Price per unit US$50.00'")
        let observation = expectation(for: quoted, evaluatedWith: apple)
        XCTAssertEqual(XCTWaiter.wait(for: [observation], timeout: 25), .completed, apple.label)
        XCTAssertTrue(apple.label.contains("Apple") && apple.label.contains("2 shares"), apple.label)
        XCTAssertTrue(apple.label.contains("Position value US$100.00"), apple.label)
        XCTAssertTrue(apple.label.contains("Average cost US$40.00"), apple.label)
        XCTAssertTrue(apple.label.contains("Unrealised gain or loss +US$20.00"), apple.label)
        let weight = try XCTUnwrap(apple.label.firstMatch(of: /[0-9.]+ percent of portfolio/)).0
        reveal(secondApple)

        reveal(search, lookingAbove: true)
        search.tap()
        search.typeText("apple 1212")
        app.keyboards.buttons["Done"].tap()
        reveal(apple)
        XCTAssertTrue(apple.label.contains(weight))
        XCTAssertFalse(secondApple.exists)
        XCTAssertFalse(fund.exists)
        attach("holdings-search")
        app.buttons["portfolio.privacy"].tap()
        let masked = expectation(for: NSPredicate(format: "label CONTAINS 'Position figures hidden'"), evaluatedWith: apple)
        XCTAssertEqual(XCTWaiter.wait(for: [masked], timeout: 5), .completed, apple.label)
        XCTAssertTrue(apple.label.contains("Price per unit US$50.00"), apple.label)
        for privateValue in ["2 shares", "US$100.00", "US$40.00", "+US$20.00"] {
            XCTAssertFalse(apple.label.contains(privateValue), apple.label)
        }
        app.buttons["portfolio.privacy"].tap()

        let clear = app.buttons["Clear holdings search"]
        reveal(clear)
        clear.tap()
        reveal(filter)
        filter.tap()
        app.buttons["ETFs"].firstMatch.tap()
        reveal(fund)
        XCTAssertTrue(fund.label.contains("ETF"), fund.label)
        XCTAssertFalse(appleRows.firstMatch.exists)
        XCTAssertFalse(bitcoin.exists)
        reveal(filter)
        filter.tap()
        app.buttons["Crypto"].firstMatch.tap()
        reveal(bitcoin)
        XCTAssertFalse(fund.exists)
        reveal(filter)
        filter.tap()
        app.buttons["Stocks"].firstMatch.tap()
        reveal(sort)
        sort.tap()
        app.buttons["Unrealised gain or loss"].firstMatch.tap()
        reveal(apple)
        XCTAssertTrue(sort.label.contains("Unrealised gain or loss"), sort.label)
        XCTAssertTrue(appleRows.firstMatch.label.contains("1212"), appleRows.firstMatch.label)
        apple.tap()
        XCTAssertTrue(app.navigationBars["AAPL"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["holding.position"].waitForExistence(timeout: 8))
        app.navigationBars["AAPL"].buttons.firstMatch.tap()

        let movement = app.buttons["portfolio.intelligence.movement"]
        reveal(movement, lookingAbove: true)
        movement.tap()
        let coverage = app.staticTexts["copilot.movement.coverage"]
        XCTAssertTrue(coverage.waitForExistence(timeout: 8))
        XCTAssertTrue(["Price evidence for 2 of 4 positions", "Price evidence for 3 of 4 positions"].contains(coverage.label))
        let unavailable = app.staticTexts["copilot.movement.unavailable"]
        XCTAssertTrue(unavailable.label.contains("QQQ"), unavailable.label)
        let amount = app.staticTexts["copilot.movement.amount.us:AAPL"].firstMatch
        reveal(amount)
        XCTAssertEqual(amount.label, "+US$3.00")
        let units = app.staticTexts["copilot.movement.units.us:AAPL"]
        reveal(units)
        XCTAssertEqual(units.label, "3 shares")
        let source = app.staticTexts["copilot.movement.source.us:AAPL"]
        XCTAssertTrue(source.label.hasPrefix("Alpaca IEX · "))
        XCTAssertTrue(source.label.contains(String(Calendar.current.component(.year, from: Date()))))
        XCTAssertEqual(app.staticTexts["copilot.movement.prices.us:AAPL"].label,
                       "Latest US$50.00 · Previous session close US$49.00")
        let holdingID = try XCTUnwrap(holdings[1]["id"] as? String).uppercased()
        let openHolding = app.buttons["copilot.movement.holding.\(holdingID)"]
        reveal(openHolding)
        XCTAssertTrue(openHolding.label.contains("3434"))
        attach("portfolio-price-movement")
        openHolding.tap()
        XCTAssertTrue(app.navigationBars["AAPL"].waitForExistence(timeout: 8))
        let accountLine = app.descendants(matching: .any)["holding.brokerAccount"].firstMatch
        reveal(accountLine)
        XCTAssertTrue(accountLine.label.contains("3434"), accountLine.label)
        app.navigationBars["AAPL"].buttons.firstMatch.tap()
        app.buttons["copilot.close"].tap()

        app.buttons["portfolio.privacy"].tap()
        reveal(movement, lookingAbove: true)
        movement.tap()
        XCTAssertTrue(coverage.waitForExistence(timeout: 8))
        reveal(source)
        XCTAssertFalse(amount.exists)
        XCTAssertFalse(units.exists)
        XCTAssertTrue(app.staticTexts["copilot.movement.prices.us:AAPL"].exists)
        reveal(openHolding)
        openHolding.tap()
        XCTAssertTrue(app.navigationBars["AAPL"].waitForExistence(timeout: 8))
        let holdingUnits = app.descendants(matching: .any)["holding.units"].firstMatch
        reveal(holdingUnits)
        XCTAssertTrue(holdingUnits.label.contains("••••"), holdingUnits.label)
        XCTAssertTrue(app.descendants(matching: .any)["holding.avgCost"].firstMatch.label.contains("••••"))
        app.navigationBars["AAPL"].buttons.firstMatch.tap()
        app.buttons["copilot.close"].tap()

        let concentration = app.buttons["portfolio.intelligence.concentration"]
        reveal(concentration, lookingAbove: true)
        concentration.tap()
        let title = app.staticTexts["Your tracked portfolio"]
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        func listingRow(_ name: String) -> XCUIElement {
            app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", name + "[ ,]+[0-9]+[.][0-9]+%")).firstMatch
        }
        let appleListing = listingRow("AAPL · US")
        let fundListing = listingRow("QQQ · US")
        XCTAssertTrue(appleListing.waitForExistence(timeout: 8))
        XCTAssertTrue(fundListing.exists)
        func listingWeight(_ row: XCUIElement) throws -> Double {
            let percent = try XCTUnwrap(row.label.firstMatch(of: /([0-9]+[.][0-9]+)%/))
            return try XCTUnwrap(Double(percent.1))
        }
        XCTAssertEqual(try listingWeight(appleListing), try listingWeight(fundListing) * 1.5, accuracy: 0.15)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "positions priced")).firstMatch.exists)
    }

    func testPortfolioVisitShowsSyncedPositionChangesAndHidesValues() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STOCK_TRACKER_UI_TEST_HOLDINGS_COMPARISON"] == "1",
                          "Start the holdings comparison fixture relay")
        let email = "holdings-comparison-ui-\(UUID().uuidString.lowercased())@example.com"
        let signup = try request("POST", "/auth/v1/signup", body: JSONSerialization.data(withJSONObject: [
            "email": email, "password": password,
        ]))
        XCTAssertEqual(signup.status, 200)
        let account = try XCTUnwrap(JSONSerialization.jsonObject(with: signup.data) as? [String: Any])
        let userID = try XCTUnwrap((account["user"] as? [String: Any] ?? account)["id"] as? String)
        let token = try signIn(email: email)
        let appleID = UUID().uuidString.lowercased()
        let fundID = UUID().uuidString.lowercased()
        let date = ISO8601DateFormatter().string(from: Date())

        func position(_ id: String, _ symbol: String, _ units: Double) -> [String: Any] {
            ["id": id, "user_id": userID, "asset_symbol": symbol, "asset_name": symbol,
             "asset_kind": "Stock", "asset_exchange": "NASDAQ", "shares": units, "avg_cost": 40, "date_added": date]
        }
        func insert(_ rows: [[String: Any]]) throws {
            XCTAssertEqual(try request("POST", "/rest/v1/portfolio_holdings",
                                       body: JSONSerialization.data(withJSONObject: rows), token: token).status, 201)
        }
        func update(_ id: String, _ values: [String: Any]) throws {
            let response = try request("PATCH", "/rest/v1/portfolio_holdings?id=eq.\(id)",
                                       body: JSONSerialization.data(withJSONObject: values), token: token)
            XCTAssertTrue([200, 204].contains(response.status), "Update returned \(response.status)")
        }
        try insert([position(appleID, "AAPL", 2), position(fundID, "QQQ", 1)])

        app.launchArguments = ["-UITestFreshInstall", "-UITestTradingFixture",
            "-SupabaseURLOverride", apiURL, "-SupabaseAnonKeyOverride", anonKey,
            "-UITestSignIn", "\(email):\(password)", "-app_theme_mode", "Dark", "-portfolioSegment", "holdings",
            "-preferredCurrency", "USD"]
        app.launch()
        XCTAssertTrue(app.open("Portfolio"))
        let visit = app.buttons["portfolio.intelligence.visit"]
        func revealVisit(lookingAbove: Bool = false) {
            for _ in 0..<12 {
                let frame = visit.exists ? visit.frame : .zero
                if !frame.isEmpty, app.frame.insetBy(dx: 0, dy: 90).contains(CGPoint(x: frame.midX, y: frame.midY)) {
                    return
                }
                let down = frame.isEmpty ? lookingAbove : frame.midY < app.frame.midY
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: down ? 0.36 : 0.64))
                let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: down ? 0.65 : 0.35))
                start.press(forDuration: 0.04, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
            }
            XCTAssertTrue(visit.isHittable, app.debugDescription)
        }
        let movement = app.buttons["portfolio.intelligence.movement"]
        for _ in 0..<6 where !movement.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(movement.waitForExistence(timeout: 15))
        revealVisit(lookingAbove: true)
        let firstVisit = NSPredicate(format: "label == %@", "First portfolio visit on this device")
        XCTAssertTrue(firstVisit.evaluate(with: visit), visit.label)

        XCTAssertTrue(app.open("Markets"))
        try update(appleID, ["shares": 3, "avg_cost": 43])
        try update(fundID, ["deleted_at": date])
        try insert([position(UUID().uuidString.lowercased(), "AMZN", 1)])
        XCTAssertTrue(app.open("Portfolio"))
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.19))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.84))
        top.press(forDuration: 0.08, thenDragTo: bottom, withVelocity: .slow, thenHoldForDuration: 0)
        top.press(forDuration: 0.08, thenDragTo: bottom, withVelocity: .slow, thenHoldForDuration: 0)
        revealVisit()
        let changed = NSPredicate(format: "label == %@", "3 positions changed since your last visit")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: changed, evaluatedWith: visit)], timeout: 20), .completed, visit.label)
        visit.tap()
        let summary = app.staticTexts["portfolio.visit.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 8))
        XCTAssertEqual(summary.label, "3 positions changed since your last visit")
        XCTAssertTrue(app.staticTexts["New open position"].exists)
        XCTAssertTrue(app.staticTexts["No longer open"].exists)
        XCTAssertEqual(app.staticTexts["portfolio.visit.units"].label, "Units 2 → 3")
        XCTAssertEqual(app.staticTexts["portfolio.visit.cost"].label, "Average cost US$40.00 → US$43.00")
        attach("portfolio-visit-changes")
        app.buttons["portfolio.visit.done"].tap()

        app.buttons["portfolio.privacy"].tap()
        visit.tap()
        XCTAssertTrue(summary.waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["portfolio.visit.units"].exists)
        XCTAssertFalse(app.staticTexts["portfolio.visit.cost"].exists)
        XCTAssertTrue(app.staticTexts["Quantity · Average cost updated"].exists)
        app.buttons["portfolio.visit.done"].tap()

        XCTAssertTrue(app.open("Markets"))
        XCTAssertTrue(app.open("Portfolio"))
        let unchanged = NSPredicate(format: "label == %@", "No position changes since your last visit")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: unchanged, evaluatedWith: visit)], timeout: 8), .completed)

        guard ProcessInfo.processInfo.environment["STOCK_TRACKER_UI_TEST_HOLDING_EVENTS"] == "1" else { return }
        let events = app.buttons["portfolio.intelligence.events"]
        for _ in 0..<6 where !events.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(events.isHittable)
        events.tap()
        XCTAssertTrue(app.navigationBars["Earnings and news"].waitForExistence(timeout: 8))
        let earnings = app.staticTexts["portfolio.events.earnings.coverage"]
        let news = app.staticTexts["portfolio.events.news.coverage"]
        let check = NSPredicate(format: "label BEGINSWITH %@", "2 of 2 eligible listings checked")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: check, evaluatedWith: earnings)], timeout: 15), .completed)
        XCTAssertTrue(news.label.hasPrefix("1 of 2 eligible listings checked"))
        XCTAssertTrue(app.staticTexts["Apple announces a company update"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Example Publisher")).firstMatch.exists)
        let report = app.descendants(matching: .any)["portfolio.events.earnings.AAPL"].firstMatch
        XCTAssertTrue(report.exists)
        report.tap()
        XCTAssertTrue(app.navigationBars["AAPL"].waitForExistence(timeout: 8))
    }

    func testSignedInStrategyEditsBacktestsAndStartsPaperAgent() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STOCK_TRACKER_UI_TEST_STRATEGY_STUDIO"] == "1",
                          "Start the signed-in strategy relay with historical market data")
        let email = "strategy-studio-ui-\(UUID().uuidString.lowercased())@example.com"
        let signup = try request("POST", "/auth/v1/signup", body: JSONSerialization.data(withJSONObject: [
            "email": email, "password": password,
        ]))
        XCTAssertEqual(signup.status, 200)
        let token = try signIn(email: email)
        app.launchArguments = ["-UITestFreshInstall", "-hasCompletedOnboarding", "YES",
            "-SupabaseURLOverride", apiURL, "-SupabaseAnonKeyOverride", anonKey,
            "-UITestSignIn", "\(email):\(password)", "-app_theme_mode", "Dark"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.open("Agents"))
        app.buttons["agents.new"].tap()
        let prompt = app.descendants(matching: .any)["agent.new.prompt"].firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        prompt.tap()
        prompt.typeText("Trade the 20 and 50 day moving average crossover for AAPL in a paper portfolio")
        app.buttons["agent.new.draft"].tap()

        let buy = app.buttons["agent.draft.rule.entry"]
        XCTAssertTrue(buy.waitForExistence(timeout: 10))
        XCTAssertTrue(buy.label.contains("20-day average"), buy.label)
        buy.tap()
        let period = app.textFields["strategy.rule.left.period"]
        XCTAssertTrue(period.waitForExistence(timeout: 10))
        app.buttons["strategy.rule.left.period.clear"].tap()
        period.tap()
        period.typeText("15")
        app.buttons["strategy.rule.apply"].tap()
        XCTAssertTrue(buy.waitForExistence(timeout: 8))
        XCTAssertTrue(buy.label.contains("15-day average"), buy.label)

        let backtest = app.buttons["agent.draft.backtest"]
        for _ in 0..<10 where !backtest.isHittable { app.swipeUp(velocity: .fast) }
        XCTAssertTrue(backtest.isHittable && backtest.isEnabled)
        backtest.tap()
        XCTAssertTrue(app.navigationBars["Backtest"].waitForExistence(timeout: 90), app.debugDescription)
        XCTAssertFalse(app.staticTexts["backtest.testData"].exists)
        let provider = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Prices: Alpaca")).firstMatch
        XCTAssertTrue(provider.exists, app.debugDescription)
        let assumptions = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "at the next bar's open")).firstMatch
        for _ in 0..<8 where !assumptions.isHittable { app.swipeUp(velocity: .fast) }
        XCTAssertTrue(assumptions.isHittable)
        XCTAssertTrue(app.staticTexts["Buy when 15-day average crosses above 50-day average."].exists)
        attach("strategy-backtest-assumptions")
        app.buttons["backtest.done"].tap()

        let start = app.buttons["agent.draft.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 8))
        XCTAssertEqual(start.label, "Start in practice")
        start.tap()
        let agentCard = app.buttons["agents.card.Trend Following Agent"]
        XCTAssertTrue(agentCard.waitForExistence(timeout: 25), app.debugDescription)
        let saved = try request("POST", "/functions/v1/trading-api",
                                body: JSONSerialization.data(withJSONObject: ["action": "state"]), token: token)
        XCTAssertEqual(saved.status, 200)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: saved.data) as? [String: Any])
        let data = try XCTUnwrap(envelope["data"] as? [String: Any])
        let state = try XCTUnwrap(data["state"] as? [String: Any])
        let agents = try XCTUnwrap(state["agents"] as? [[String: Any]])
        let agent = try XCTUnwrap(agents.first { $0["name"] as? String == "Trend Following Agent" })
        XCTAssertEqual(agent["mode"] as? String, "paper")
        XCTAssertEqual(agent["status"] as? String, "active")
        let versions = try XCTUnwrap(agent["versions"] as? [[String: Any]])
        let spec = try XCTUnwrap(versions.last?["spec"] as? [String: Any])
        let entry = try XCTUnwrap(spec["entry"] as? [String: Any])
        let left = try XCTUnwrap(entry["left"] as? [String: Any])
        XCTAssertEqual(left["period"] as? Int, 15)
    }

    func testSignedInAssetResearchSearchChartEvidenceAIAndWatchlist() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STOCK_TRACKER_UI_TEST_RESEARCH_JOURNEY"] == "1",
                          "Start the signed-in research journey relay")
        let email = "research-journey-ui-\(UUID().uuidString.lowercased())@example.com"
        let signup = try request("POST", "/auth/v1/signup", body: JSONSerialization.data(withJSONObject: [
            "email": email, "password": password,
        ]))
        XCTAssertEqual(signup.status, 200)
        let token = try signIn(email: email)
        app.launchArguments = ["-UITestFreshInstall", "-hasCompletedOnboarding", "YES",
            "-SupabaseURLOverride", apiURL, "-SupabaseAnonKeyOverride", anonKey,
            "-UITestSignIn", "\(email):\(password)", "-app_theme_mode", "Dark"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.open("Search"))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("AAPL")
        let result = app.buttons["search.result.us.AAPL"]
        XCTAssertTrue(result.waitForExistence(timeout: 25))
        result.tap()
        let chart = app.descendants(matching: .any)["detail.chart"].firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 25))
        let month = app.buttons["1 month"].firstMatch
        XCTAssertTrue(month.waitForExistence(timeout: 10))
        month.tap()
        XCTAssertTrue(month.isSelected)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            chart.exists && !self.app.staticTexts["Chart unavailable"].exists &&
                !self.app.staticTexts["No price history for this period"].exists &&
                !self.app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Loading chart'")).firstMatch.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 25), .completed)

        let research = app.buttons["detail.companyResearch"]
        for _ in 0..<7 where !research.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(research.isHittable)
        research.tap()
        XCTAssertTrue(app.navigationBars["AAPL Research"].waitForExistence(timeout: 10))
        let ask = app.buttons["companyResearch.ask"]
        XCTAssertTrue(ask.waitForExistence(timeout: 40))
        let fact = app.staticTexts["companyResearch.factValue"].firstMatch
        XCTAssertTrue(fact.exists)
        XCTAssertTrue(app.descendants(matching: .any)["companyResearch.filingSource"].firstMatch.exists)
        let news = app.descendants(matching: .any)["companyResearch.headline"].firstMatch
        for _ in 0..<6 where !news.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(news.isHittable)
        XCTAssertFalse(news.label.isEmpty)
        attach("research-journey-sourced-news")
        for _ in 0..<7 where !ask.isHittable { app.swipeDown(velocity: .slow) }
        XCTAssertTrue(ask.isHittable)
        ask.tap()
        XCTAssertTrue(app.navigationBars["Ask about AAPL"].waitForExistence(timeout: 10))
        let question = app.descendants(matching: .any)["companyQuestion.input"].firstMatch
        question.tap()
        question.typeText("What does the annual filing show about net sales?")
        XCTAssertTrue((question.value as? String)?.contains("net sales") == true, app.debugDescription)
        app.navigationBars["Ask about AAPL"].staticTexts["Ask about AAPL"].tap()
        let send = app.buttons["companyQuestion.ask"]
        XCTAssertFalse(send.isEnabled)
        let consent = app.switches["companyQuestion.consent"]
        consent.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(send.wait(for: \.isEnabled, toEqual: true, timeout: 5), app.debugDescription)
        send.tap()
        let answer = app.staticTexts["companyQuestion.answer"]
        let error = app.staticTexts["companyQuestion.error"]
        let response = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in answer.exists || error.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [response], timeout: 55), .completed)
        XCTAssertTrue(answer.exists, error.exists ? error.label : app.debugDescription)
        XCTAssertTrue(answer.label.contains("478,834,000,000"), answer.label)
        let citation = app.descendants(matching: .any).matching(identifier: "companyQuestion.citation")
            .matching(NSPredicate(format: "label CONTAINS[c] 'net sales'")).firstMatch
        XCTAssertTrue(citation.exists)
        XCTAssertTrue(citation.label.localizedCaseInsensitiveContains("net sales"), citation.label)
        attach("research-journey-cited-answer")

        app.navigationBars["Ask about AAPL"].buttons.firstMatch.tap()
        app.buttons["companyResearch.done"].tap()
        let watch = app.buttons["detail.watchlist"]
        XCTAssertTrue(watch.waitForExistence(timeout: 8))
        XCTAssertEqual(watch.label, "Add to Watchlist")
        watch.tap()
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Remove from Watchlist'"), object: watch)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
        var stored: [[String: Any]] = []
        for _ in 0..<10 {
            stored = try rows("watchlist_assets", select: "symbol", token: token)
            if stored.contains(where: { $0["symbol"] as? String == "AAPL" }) { break }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(stored.contains { $0["symbol"] as? String == "AAPL" })
    }

    func testSignedInHoldingOpensCompanyReport() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STOCK_TRACKER_UI_TEST_COMPANY_REPORT"] == "1",
                          "Start the signed-in company report relay")
        let email = "holdings-comparison-ui-\(UUID().uuidString.lowercased())@example.com"
        let signup = try request("POST", "/auth/v1/signup", body: JSONSerialization.data(withJSONObject: [
            "email": email, "password": password,
        ]))
        XCTAssertEqual(signup.status, 200)
        let account = try XCTUnwrap(JSONSerialization.jsonObject(with: signup.data) as? [String: Any])
        let userID = try XCTUnwrap((account["user"] as? [String: Any] ?? account)["id"] as? String)
        let token = try signIn(email: email)
        let position: [String: Any] = [
            "id": UUID().uuidString.lowercased(), "user_id": userID,
            "asset_symbol": "AAPL", "asset_name": "Apple", "asset_kind": "Stock", "asset_exchange": "NASDAQ",
            "shares": 2, "avg_cost": 40, "date_added": ISO8601DateFormatter().string(from: Date()),
        ]
        XCTAssertEqual(try request("POST", "/rest/v1/portfolio_holdings",
                                   body: JSONSerialization.data(withJSONObject: [position]), token: token).status, 201)
        app.launchArguments = ["-UITestFreshInstall", "-UITestTradingFixture",
            "-SupabaseURLOverride", apiURL, "-SupabaseAnonKeyOverride", anonKey,
            "-UITestSignIn", "\(email):\(password)", "-app_theme_mode", "Dark", "-portfolioSegment", "holdings"]
        app.launch()
        XCTAssertTrue(app.open("Portfolio"))
        let holding = app.buttons["portfolio.holding.AAPL"].firstMatch
        for _ in 0..<12 where !holding.isHittable {
            let frame = holding.exists ? holding.frame : .zero
            let direction = !frame.isEmpty && frame.midY < app.frame.midY
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: direction ? 0.36 : 0.64))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: direction ? 0.65 : 0.35))
            start.press(forDuration: 0.04, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
        }
        XCTAssertTrue(holding.isHittable, app.debugDescription)
        holding.tap()
        XCTAssertTrue(app.navigationBars["AAPL"].waitForExistence(timeout: 8))
        let research = app.buttons["holding.companyResearch"]
        for _ in 0..<6 where !research.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(research.isHittable)
        research.tap()
        XCTAssertTrue(app.navigationBars["AAPL Research"].waitForExistence(timeout: 8))
        let filing = app.descendants(matching: .any)["companyResearch.eventSource"].firstMatch
        XCTAssertTrue(filing.waitForExistence(timeout: 35))
        XCTAssertTrue(filing.label.contains("issuer filing"), filing.label)
        XCTAssertTrue(app.staticTexts["Last price"].firstMatch.exists)
        attach("company-research-from-holding")
        app.buttons["companyResearch.done"].tap()
        XCTAssertTrue(app.navigationBars["AAPL"].exists)
    }

    func testIssuerExposureKeepsDualListingPricesAndShowsFilingSources() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STOCK_TRACKER_UI_TEST_ISSUER_EXPOSURE"] == "1",
                          "Start the issuer allocation quote fixture relay")
        let email = "issuer-exposure-ui-\(UUID().uuidString.lowercased())@example.com"
        let signup = try request("POST", "/auth/v1/signup", body: JSONSerialization.data(withJSONObject: [
            "email": email, "password": password,
        ]))
        XCTAssertEqual(signup.status, 200)
        let account = try XCTUnwrap(JSONSerialization.jsonObject(with: signup.data) as? [String: Any])
        let userId = try XCTUnwrap((account["user"] as? [String: Any] ?? account)["id"] as? String)
        let token = try signIn(email: email)
        let now = ISO8601DateFormatter().string(from: Date())
        let listings: [(String, String, Double)] = [
            ("BHP", "ASX", 1), ("BHP", "NYSE", 1), ("TSM", "NYSE", 1), ("QQQ", "NASDAQ", 1),
        ]
        let holdings = listings.map { symbol, exchange, quantity in
            ["id": UUID().uuidString.lowercased(), "user_id": userId, "asset_symbol": symbol,
             "asset_name": symbol, "asset_kind": "Stock", "asset_exchange": exchange,
             "shares": quantity, "avg_cost": 10, "date_added": now] as [String: Any]
        }
        XCTAssertEqual(try request("POST", "/rest/v1/portfolio_holdings",
                                   body: JSONSerialization.data(withJSONObject: holdings), token: token).status, 201)

        app.launchArguments = ["-UITestFreshInstall", "-UITestTradingFixture",
            "-SupabaseURLOverride", apiURL, "-SupabaseAnonKeyOverride", anonKey,
            "-UITestSignIn", "\(email):\(password)", "-app_theme_mode", "Light", "-portfolioSegment", "allocation"]
        app.launch()
        XCTAssertTrue(app.open("Portfolio"))
        func reveal(_ element: XCUIElement) {
            for _ in 0..<18 {
                let frame = element.exists ? element.frame : .zero
                if !frame.isEmpty, app.frame.insetBy(dx: 0, dy: 65).contains(CGPoint(x: frame.midX, y: frame.midY)) { return }
                let movingDown = !frame.isEmpty && frame.midY < app.frame.midY
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: movingDown ? 0.37 : 0.66))
                let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: movingDown ? 0.63 : 0.40))
                start.press(forDuration: 0.04, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
            }
            XCTAssertTrue(element.isHittable, "Expected \(element)")
        }
        XCTAssertTrue(app.buttons["portfolio.privacy"].waitForExistence(timeout: 30))
        let grouping = app.buttons["portfolio.allocation.grouping"]
        func choose(_ name: String) {
            reveal(grouping)
            grouping.tap()
            app.buttons[name].firstMatch.tap()
        }
        func slice(_ name: String) -> XCUIElement {
            app.descendants(matching: .any)["portfolio.allocation.slice.\(name)"].firstMatch
        }
        choose("SIC sector")
        XCTAssertTrue(app.staticTexts["4 of 4 holdings valued."].waitForExistence(timeout: 30))
        for name in ["Mining and extraction", "Manufacturing", "ETFs"] {
            reveal(slice(name))
        }
        choose("Issuer incorporation")
        let sources = app.buttons["portfolio.allocation.filings"]
        reveal(sources)
        sources.tap()
        XCTAssertTrue(app.navigationBars["Issuer filing sources"].waitForExistence(timeout: 8))
        for id in ["asx:BHP", "us:BHP", "us:TSM"] {
            XCTAssertTrue(app.descendants(matching: .any)["portfolio.allocation.filing.\(id)"].firstMatch.exists)
        }
        XCTAssertFalse(app.descendants(matching: .any)["portfolio.allocation.filing.us:QQQ"].exists)
        app.navigationBars["Issuer filing sources"].buttons["Done"].tap()
        let australia = slice("Australia")
        reveal(australia)
        // The ASX leg uses the live ASX quote converted to USD. The controlled US
        // leg is US$200 and the other two holdings are US$100 each.
        let amount = try XCTUnwrap(australia.label.firstMatch(of: /\$\s*([0-9]+(?:\.[0-9]+)?)/))
        let australiaValue = try XCTUnwrap(Double(amount.1))
        XCTAssertGreaterThan(australiaValue, 210, australia.label)
        XCTAssertLessThan(australiaValue, 300, australia.label)
        let weight = australiaValue / (australiaValue + 200) * 100
        let expected = String(format: "%.1f%%", weight)
        XCTAssertTrue(australia.label.contains(expected), australia.label)
        reveal(slice("Taiwan"))
        app.buttons["portfolio.privacy"].tap()
        reveal(australia)
        XCTAssertTrue(australia.label.contains("••••"), australia.label)
        XCTAssertTrue(australia.label.contains(expected), australia.label)
        attach("issuer-incorporation")
    }

    func testReviewedStockTransferSyncsAcrossSignIn() throws {
        // Run scripts/snaptrade-positions-fixture.py with STOCK_TRACKER_UI_TEST_API pointing to it.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STOCK_TRACKER_UI_TEST_STOCK_TRANSFERS"] == "1",
                          "Start the stock transfer activity fixture relay")
        let email = "stock-transfer-ui-\(UUID().uuidString.lowercased())@example.com"
        let signup = try request("POST", "/auth/v1/signup", body: JSONSerialization.data(withJSONObject: [
            "email": email, "password": password,
        ]))
        XCTAssertEqual(signup.status, 200)
        let account = try XCTUnwrap(JSONSerialization.jsonObject(with: signup.data) as? [String: Any])
        let user = account["user"] as? [String: Any] ?? account
        let userId = try XCTUnwrap(user["id"] as? String)
        let token = try signIn(email: email)
        let sender = UUID().uuidString.lowercased()
        let receiver = UUID().uuidString.lowercased()
        let outgoing = "a8cc1385-31a7-4c4d-9955-6789589cc956"
        let incoming = "0cc77f5f-2b5f-481a-95cb-e44b9c0ad97f"
        let now = ISO8601DateFormatter().string(from: Date())
        let holdings = [(sender, outgoing, "CommSec ••••1234"), (receiver, incoming, "CommSec ••••4321")].map { id, accountId, label in
            ["id": id, "user_id": userId, "asset_symbol": "BHP", "asset_name": "BHP Group",
             "asset_kind": "Stock", "asset_exchange": "ASX", "shares": 2.25, "avg_cost": 10, "date_added": now,
             "broker_account": ["account_id": accountId, "label": label, "institution": "CommSec",
                                "observed_at": now, "tracking": false]] as [String: Any]
        }
        XCTAssertEqual(try request("POST", "/rest/v1/portfolio_holdings", body: JSONSerialization.data(withJSONObject: holdings), token: token).status, 201)
        let snapshot = UUID().uuidString.lowercased()
        let receipt: [String: Any] = ["id": snapshot, "user_id": userId, "holding_id": receiver, "type": "Buy",
            "transaction_date": now, "shares": 2.25, "price_per_share": 0, "fees": 0,
            "trade_provenance": ["source": "broker_position"]]
        XCTAssertEqual(try request("POST", "/rest/v1/transactions", body: JSONSerialization.data(withJSONObject: receipt), token: token).status, 201)

        func launch() {
            app.launchArguments = ["-UITestFreshInstall", "-UITestTradingFixture", "-hasCompletedOnboarding", "YES",
                "-SupabaseURLOverride", apiURL, "-SupabaseAnonKeyOverride", anonKey, "-UITestSignIn", "\(email):\(password)"]
            app.launch()
        }
        func openLedger() {
            XCTAssertTrue(app.open("Portfolio"))
            let transfers = app.descendants(matching: .any)["portfolio.stockTransfers.open"].firstMatch
            for _ in 0..<7 where !transfers.isHittable { app.swipeUp(velocity: .slow) }
            XCTAssertTrue(transfers.isHittable)
            transfers.tap()
        }
        func saved() throws -> [[String: Any]] {
            try rows("portfolio_stock_transfers",
                     select: "id,shares::text,from_holding_id,to_holding_id,receiving_snapshot_id,statement_reference,snaptrade_reference", token: token)
        }

        launch()
        openLedger()
        let find = app.buttons["portfolio.stockTransfers.find"]
        XCTAssertTrue(find.waitForExistence(timeout: 12))
        XCTAssertTrue(find.wait(for: \.isEnabled, toEqual: true, timeout: 12))
        find.tap()
        let search = app.buttons["portfolio.stockTransfers.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.tap()
        let match = app.buttons["portfolio.stockTransfers.match." + String(repeating: "1", count: 64)]
        XCTAssertTrue(match.waitForExistence(timeout: 12))
        match.tap()
        let save = app.buttons["portfolio.stockTransfers.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 8))
        XCTAssertFalse(save.isEnabled)
        XCTAssertTrue(try saved().isEmpty)

        let position = app.buttons["portfolio.stockTransfers.snapshot"]
        for _ in 0..<5 where !position.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(position.isHittable)
        position.tap()
        let snapshotChoice = app.buttons["portfolio.stockTransfers.snapshot." + snapshot]
        XCTAssertTrue(snapshotChoice.waitForExistence(timeout: 8))
        snapshotChoice.tap()

        let confirmation = app.switches["portfolio.stockTransfers.confirm"]
        for _ in 0..<5 where !confirmation.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(confirmation.isHittable)
        let toggle = confirmation.switches.firstMatch
        if toggle.exists {
            toggle.tap()
        } else {
            confirmation.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.5)).tap()
        }
        XCTAssertTrue(save.wait(for: \.isEnabled, toEqual: true, timeout: 5))
        save.tap()

        var written: [[String: Any]] = []
        for _ in 0..<12 {
            written = try saved()
            if !written.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertEqual(written.count, 1)
        let transfer = try XCTUnwrap(written.first)
        let transferId = try XCTUnwrap(transfer["id"] as? String)
        XCTAssertEqual(transfer["from_holding_id"] as? String, sender)
        XCTAssertEqual(transfer["to_holding_id"] as? String, receiver)
        XCTAssertEqual(transfer["receiving_snapshot_id"] as? String, snapshot)
        XCTAssertEqual(transfer["shares"] as? String, "2.25")
        let references = try XCTUnwrap(transfer["snaptrade_reference"] as? [String: String])
        XCTAssertEqual(references["sentId"], String(repeating: "1", count: 64))
        XCTAssertEqual(references["receivedId"], String(repeating: "2", count: 64))

        app.terminate()
        launch()
        openLedger()
        let row = app.buttons["portfolio.stockTransfers.entry." + transferId]
        XCTAssertTrue(row.waitForExistence(timeout: 12))
        XCTAssertTrue(row.label.contains("SnapTrade reference attached"))
        row.tap()
        XCTAssertTrue(save.waitForExistence(timeout: 8))
        let statement = app.textFields["portfolio.stockTransfers.statement"]
        for _ in 0..<5 where !statement.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(statement.isHittable)
        statement.tap()
        statement.typeText("Transfer checked")
        save.tap()
        var edited = false
        for _ in 0..<12 {
            let records = try saved()
            if records.first?["statement_reference"] as? String == "Transfer checked" {
                XCTAssertEqual(records.count, 1)
                XCTAssertEqual(records.first?["snaptrade_reference"] as? [String: String], references)
                edited = true
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(edited)
        XCTAssertTrue(row.waitForExistence(timeout: 12))
        row.swipeLeft()
        let remove = app.buttons["Remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 8))
        remove.tap()
        let confirmRemoval = app.buttons["Remove transfer"]
        XCTAssertTrue(confirmRemoval.waitForExistence(timeout: 8))
        confirmRemoval.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 8))
        XCTAssertTrue(try saved().isEmpty)
    }

    func testReconciledReturnsCompareWithBenchmarks() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STOCK_TRACKER_UI_TEST_BENCHMARK"] == "1",
                          "Use a test market-workspace server with benchmark data")
        let email = "benchmark-ui-\(UUID().uuidString.lowercased())@example.com"
        let signup = try request("POST", "/auth/v1/signup", body: JSONSerialization.data(withJSONObject: [
            "email": email, "password": password,
        ]))
        XCTAssertEqual(signup.status, 200)
        let token = try signIn(email: email)
        let owner = try request("GET", "/auth/v1/user", token: token)
        let account = try XCTUnwrap(JSONSerialization.jsonObject(with: owner.data) as? [String: Any])
        let userId = try XCTUnwrap(account["id"] as? String)
        let periods: [[String: Any]] = [
            ["starts_on": "2026-08-03", "ends_on": "2026-09-04", "opening_value_usd": 1000, "closing_value_usd": 1100,
             "external_flows": []],
            ["starts_on": "2026-09-04", "ends_on": "2026-10-03", "opening_value_usd": 1100, "closing_value_usd": 1600,
             "external_flows": [["date": "2026-09-16", "kind": "deposit", "amount": 500]]],
        ].map { $0.merging(["user_id": userId]) { old, _ in old } }
        let saved = try request("POST", "/rest/v1/portfolio_performance_periods",
                                body: JSONSerialization.data(withJSONObject: periods), token: token)
        XCTAssertEqual(saved.status, 201)

        func launch(hidden: Bool) {
            app.launchArguments = ["-UITestFreshInstall", "-UITestTradingFixture", "-hasCompletedOnboarding", "YES",
                "-portfolioValueHidden", hidden ? "YES" : "NO", "-preferredMarket", "US",
                "-SupabaseURLOverride", apiURL, "-SupabaseAnonKeyOverride", anonKey, "-UITestSignIn", "\(email):\(password)"]
            app.launch()
            XCTAssertTrue(app.open("Portfolio"))
        }

        let open = app.buttons["portfolio.returns.benchmark.open"]
        launch(hidden: false)
        for _ in 0..<6 where !open.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(open.isHittable)
        open.tap()
        XCTAssertTrue(app.navigationBars["Benchmark comparison"].waitForExistence(timeout: 8), app.debugDescription)
        let etf = app.descendants(matching: .any)["portfolio.returns.benchmark.etf"].firstMatch
        let portfolio = app.descendants(matching: .any)["portfolio.returns.benchmark.portfolio"].firstMatch
        let difference = app.descendants(matching: .any)["portfolio.returns.benchmark.difference"].firstMatch
        XCTAssertTrue(etf.waitForExistence(timeout: 25))
        XCTAssertTrue(portfolio.label.contains("Unavailable"))
        XCTAssertTrue(difference.label.contains("Unavailable"))
        XCTAssertTrue(app.staticTexts["ETF closes 2026-08-03 and 2026-10-02."].exists)

        app.descendants(matching: .any)["portfolio.returns.benchmark.period"].firstMatch.tap()
        let period = app.buttons["benchmark.period.2026-08-03.2026-09-04.false"]
        XCTAssertTrue(period.waitForExistence(timeout: 6), app.debugDescription)
        period.tap()
        app.descendants(matching: .any)["portfolio.returns.benchmark.fund"].firstMatch.tap()
        let stw = app.buttons["benchmark.fund.STW"]
        XCTAssertTrue(stw.waitForExistence(timeout: 6), app.debugDescription)
        stw.tap()
        let rates = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "ECB AUD/USD rates observed")).firstMatch
        XCTAssertTrue(rates.waitForExistence(timeout: 25))
        XCTAssertTrue(portfolio.label.contains("10.00%"))
        XCTAssertTrue(difference.label.contains("pp"))
        XCTAssertTrue(app.buttons["ETF details"].exists || app.links["ETF details"].exists)
        attach("statement-period-benchmark")
        app.navigationBars["Benchmark comparison"].buttons["Done"].tap()
        let add = app.buttons["portfolio.returns.add"]
        for _ in 0..<4 where !add.isHittable { app.swipeDown(velocity: .slow) }
        XCTAssertTrue(add.isHittable)
        add.tap()
        XCTAssertTrue(app.textFields["portfolio.returns.opening"].waitForExistence(timeout: 8))

        app.terminate()
        launch(hidden: true)
        let hidden = app.staticTexts["portfolio.returns.hidden"]
        for _ in 0..<6 where !hidden.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(hidden.exists, app.debugDescription)
        XCTAssertFalse(open.exists)
    }

    func testInternalBrokerCashStaysOutOfPortfolioReturns() throws {
        // Run scripts/snaptrade-positions-fixture.py and set STOCK_TRACKER_UI_TEST_API to its loopback URL.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STOCK_TRACKER_UI_TEST_INTERNAL_CASH"] == "1",
                          "Start the brokerage cash activity fixture relay")
        let email = "income-ui-\(UUID().uuidString.lowercased())@example.com"
        let signup = try request("POST", "/auth/v1/signup", body: JSONSerialization.data(withJSONObject: [
            "email": email, "password": password
        ]))
        XCTAssertEqual(signup.status, 200)
        let token = try signIn(email: email)
        app.launchArguments = ["-UITestFreshInstall", "-UITestTradingFixture", "-hasCompletedOnboarding", "YES",
            "-SupabaseURLOverride", apiURL, "-SupabaseAnonKeyOverride", anonKey, "-UITestSignIn", "\(email):\(password)"]
        app.launch()
        XCTAssertTrue(app.open("Portfolio"))
        let add = app.buttons["portfolio.returns.add"]
        for _ in 0..<6 where !add.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(add.isHittable)
        add.tap()
        for (field, amount) in [("opening", "1000"), ("closing", "1700")] {
            let input = app.textFields["portfolio.returns.\(field)"]
            XCTAssertTrue(input.waitForExistence(timeout: 8))
            input.tap()
            input.typeText(amount)
        }
        app.swipeUp(velocity: .slow)
        let find = app.buttons["Find linked accounts"]
        for _ in 0..<6 where !find.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(find.isHittable)
        find.tap()
        let load = app.buttons["Load broker activity"]
        XCTAssertTrue(load.waitForExistence(timeout: 8))
        load.tap()
        let outgoing = app.staticTexts["Outgoing cash transfer between accounts"]
        for _ in 0..<5 where !outgoing.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(outgoing.isHittable)
        XCTAssertTrue(app.staticTexts["Incoming cash transfer between accounts"].exists)
        XCTAssertFalse(app.buttons["Look up USD value"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Include Outgoing cash transfer")).firstMatch.exists)
        let contribution = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Include Cash contribution")).firstMatch
        for _ in 0..<4 where !contribution.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(contribution.isHittable)
        contribution.tap()
        app.buttons["portfolio.returns.save"].tap()
        var saved: [[String: Any]] = []
        for _ in 0..<10 {
            saved = try rows("portfolio_performance_results", select: "external_flows,deposits_usd,withdrawals_usd,investment_change_usd", token: token)
            if !saved.isEmpty { break }
            Thread.sleep(forTimeInterval: 1)
        }
        let period = try XCTUnwrap(saved.first)
        let flows = try XCTUnwrap(period["external_flows"] as? [[String: Any]])
        XCTAssertEqual(flows.count, 1)
        XCTAssertEqual(flows.first?["snaptrade_id"] as? String, String(repeating: "a", count: 64))
        XCTAssertEqual((period["deposits_usd"] as? NSNumber)?.doubleValue, 600)
        XCTAssertEqual((period["withdrawals_usd"] as? NSNumber)?.doubleValue, 0)
        XCTAssertEqual((period["investment_change_usd"] as? NSNumber)?.doubleValue, 100)
    }

    func testCashIncomeSyncsBetweenAccountAndPhone() throws {
        let email = "income-ui-\(UUID().uuidString.lowercased())@example.com"
        let signup = try request("POST", "/auth/v1/signup", body: JSONSerialization.data(withJSONObject: [
            "email": email, "password": password
        ]))
        XCTAssertEqual(signup.status, 200)
        let account = try XCTUnwrap(JSONSerialization.jsonObject(with: signup.data) as? [String: Any])
        let user = try XCTUnwrap(account["user"] as? [String: Any])
        let userId = try XCTUnwrap(user["id"] as? String)
        let token = try signIn(email: email)
        let table = "portfolio_cash_income"
        let path = "/rest/v1/\(table)"
        let probe = try request("GET", path + "?select=id&limit=1", token: token)
        try XCTSkipIf(probe.status == 404, "Apply the cash income migration to the local stack first.")
        XCTAssertEqual(probe.status, 200)
        let fixture: [String: String] = [
            "user_id": userId, "paid_on": "2025-06-30", "kind": "dividend", "payer": "Web issuer",
            "currency": "USD", "cash_received": "8.12345678", "gross_amount": "10.12345678", "withholding": "2",
            "snaptrade_activity_id": String(repeating: "a", count: 64), "snaptrade_reported_on": "2025-07-01",
            "snaptrade_reported_currency": "USD", "snaptrade_reported_amount": "10.12345678",
        ]
        XCTAssertEqual(try request("POST", path, body: JSONSerialization.data(withJSONObject: fixture), token: token).status, 201)

        func launchAccount() {
            app.launchArguments = ["-UITestFreshInstall", "-UITestTradingFixture", "-hasCompletedOnboarding", "YES",
                                   "-portfolioValueHidden", "NO", "-SupabaseURLOverride", apiURL, "-SupabaseAnonKeyOverride", anonKey,
                                   "-UITestSignIn", "\(email):\(password)"]
            app.launch()
            XCTAssertTrue(app.open("Portfolio"))
        }
        func reveal(_ element: XCUIElement) {
            for _ in 0..<8 where !element.isHittable { app.swipeUp(velocity: .slow) }
            if !element.isHittable { attach("cash-income-control-unreachable") }
            XCTAssertTrue(element.isHittable, element.debugDescription)
        }
        func replace(_ id: String, with text: String) {
            let field = app.textFields["portfolio.cashIncome.\(id)"].firstMatch
            reveal(field)
            field.tap()
            if let current = field.value as? String, !current.isEmpty, current != field.placeholderValue {
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
            }
            field.typeText(text)
            let done = app.buttons["portfolio.cashIncome.keyboardDone"].firstMatch
            if done.exists { done.tap() }
        }

        launchAccount()
        let webOptions = app.buttons["portfolio.cashIncome.options.Web issuer"].firstMatch
        reveal(webOptions)
        let total = app.staticTexts["portfolio.cashIncome.total.USD"].firstMatch
        XCTAssertTrue(total.label.contains("8.12345678"))
        webOptions.tap()
        app.buttons["Edit payment"].tap()
        XCTAssertTrue(app.textFields["portfolio.cashIncome.cash"].firstMatch.waitForExistence(timeout: 5))
        replace("cash", with: "7.12345678")
        app.buttons["portfolio.cashIncome.save"].tap()
        XCTAssertTrue(app.buttons["portfolio.cashIncome.save"].waitForNonExistence(timeout: 12))
        let projection = "id,payer,currency,cash_received::text,franking_credit_aud::text,snaptrade_reported_amount::text,snaptrade_reported_on"
        let edited = try XCTUnwrap(try rows(table, select: projection, token: token).first)
        XCTAssertEqual(edited["cash_received"] as? String, "7.12345678")
        XCTAssertEqual(edited["snaptrade_reported_amount"] as? String, "10.12345678")
        XCTAssertEqual(edited["snaptrade_reported_on"] as? String, "2025-07-01")

        let add = app.buttons["portfolio.cashIncome.add"].firstMatch
        reveal(add)
        add.tap()
        replace("payer", with: "Phone fund")
        replace("cash", with: "0.10000001")
        replace("credit", with: "0.05")
        app.buttons["portfolio.cashIncome.save"].tap()
        XCTAssertTrue(app.buttons["portfolio.cashIncome.save"].waitForNonExistence(timeout: 12))
        let phone = try XCTUnwrap(try rows(table, select: projection, token: token).first { $0["payer"] as? String == "Phone fund" })
        XCTAssertEqual(phone["cash_received"] as? String, "0.10000001")
        XCTAssertEqual(phone["franking_credit_aud"] as? String, "0.05")
        XCTAssertEqual(phone["currency"] as? String, "AUD")

        app.terminate()
        launchAccount()
        let phoneOptions = app.buttons["portfolio.cashIncome.options.Phone fund"].firstMatch
        reveal(phoneOptions)
        phoneOptions.tap()
        app.buttons["Remove payment"].tap()
        app.buttons["Remove payment"].tap()
        XCTAssertTrue(phoneOptions.waitForNonExistence(timeout: 12))
        XCTAssertEqual(try rows(table, select: "payer", token: token).compactMap { $0["payer"] as? String }, ["Web issuer"])

        if ProcessInfo.processInfo.environment["STOCK_TRACKER_UI_TEST_INCOME_BROKER"] == "1" {
            reveal(add)
            add.tap()
            let lookup = app.buttons["portfolio.cashIncome.brokerLookup"].firstMatch
            reveal(lookup)
            lookup.tap()
            let find = app.buttons["Find linked accounts"].firstMatch
            XCTAssertTrue(find.waitForExistence(timeout: 5))
            reveal(find)
            find.tap()
            let load = app.buttons["Load broker activity"].firstMatch
            reveal(load)
            load.tap()
            let review = app.buttons["Review payment"].firstMatch
            reveal(review)
            review.tap()
            let cash = app.textFields["portfolio.cashIncome.cash"].firstMatch
            reveal(cash)
            let displayedCash = cash.value as? String ?? ""
            XCTAssertTrue(displayedCash.isEmpty || displayedCash == cash.placeholderValue)
            replace("cash", with: "5.10")
            app.buttons["portfolio.cashIncome.save"].tap()
            XCTAssertTrue(app.buttons["portfolio.cashIncome.save"].waitForNonExistence(timeout: 12))
            let reviewed = try XCTUnwrap(try rows(table, select: projection, token: token).first { $0["payer"] as? String == "Broker issuer" })
            XCTAssertEqual(reviewed["cash_received"] as? String, "5.10")
            XCTAssertEqual(reviewed["snaptrade_reported_amount"] as? String, "5.25")
            XCTAssertEqual(reviewed["currency"] as? String, "USD")
        }

        let export = app.buttons["portfolio.cashIncome.export"].firstMatch
        reveal(export)
        export.tap()
        let picker = app.buttons["Save"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 12), "Cash income CSV reaches the Files save dialog")
    }

    func testDividendReinvestmentSyncAndIncomeExport() throws {
        let email = "income-ui-\(UUID().uuidString.lowercased())@example.com"
        let signup = try request("POST", "/auth/v1/signup", body: JSONSerialization.data(withJSONObject: [
            "email": email, "password": password
        ]))
        XCTAssertEqual(signup.status, 200)
        let account = try XCTUnwrap(JSONSerialization.jsonObject(with: signup.data) as? [String: Any])
        let user = try XCTUnwrap(account["user"] as? [String: Any])
        let userId = try XCTUnwrap(user["id"] as? String)
        let token = try signIn(email: email)
        let table = "portfolio_dividend_reinvestments"
        let path = "/rest/v1/\(table)"
        XCTAssertEqual(try request("GET", path + "?select=id&limit=1", token: token).status, 200)

        let holding = UUID().uuidString.lowercased()
        let position: [String: Any] = [
            "id": holding, "user_id": userId, "asset_symbol": "BHP", "asset_name": "BHP Group",
            "asset_kind": "Stock", "asset_exchange": "ASX", "shares": 0, "avg_cost": 0,
            "deleted_at": "2025-08-01T00:00:00Z",
        ]
        XCTAssertEqual(try request("POST", "/rest/v1/portfolio_holdings",
                                   body: JSONSerialization.data(withJSONObject: position), token: token).status, 201)
        let webEntry: [String: String] = [
            "user_id": userId, "holding_id": holding, "paid_on": "2025-06-30",
            "acquired_on": "2025-07-01", "currency": "AUD", "dividend_amount": "15.12345678",
            "reinvested_amount": "14.12345678", "shares": "0.123456789012345678",
            "basis_usd": "9.42", "franking_credit_aud": "2", "statement_reference": "Web statement",
        ]
        XCTAssertEqual(try request("POST", path, body: JSONSerialization.data(withJSONObject: webEntry),
                                   token: token).status, 201)
        let projection = "id,holding_id,paid_on,acquired_on,currency,shares::text,reinvested_amount::text,basis_usd::text,statement_reference,snaptrade_activity_id,snaptrade_reported_amount::text,snaptrade_reported_units::text"
        let withBroker = ProcessInfo.processInfo.environment["STOCK_TRACKER_UI_TEST_REINVESTMENT_BROKER"] == "1"
        let seeded = try XCTUnwrap(try rows(table, select: projection, token: token).first)
        let seededId = try XCTUnwrap(seeded["id"] as? String)
        let cash: [String: String] = [
            "user_id": userId, "paid_on": "2025-06-30", "kind": "dividend", "payer": "BHP cash",
            "currency": "AUD", "cash_received": "1.00",
        ]
        XCTAssertEqual(try request("POST", "/rest/v1/portfolio_cash_income",
                                   body: JSONSerialization.data(withJSONObject: cash), token: token).status, 201)

        func launchAccount() {
            app.launchArguments = ["-UITestFreshInstall", "-UITestTradingFixture", "-hasCompletedOnboarding", "YES",
                                   "-portfolioValueHidden", "NO", "-SupabaseURLOverride", apiURL, "-SupabaseAnonKeyOverride", anonKey,
                                   "-UITestSignIn", "\(email):\(password)"]
            app.launch()
            XCTAssertTrue(app.open("Portfolio"))
        }
        func reveal(_ element: XCUIElement) {
            for _ in 0..<8 where !element.isHittable { app.swipeUp(velocity: .slow) }
            if !element.isHittable { attach("reinvestment-control-unreachable") }
            XCTAssertTrue(element.isHittable, element.debugDescription)
        }
        func replace(_ id: String, with text: String) {
            let field = app.textFields["portfolio.reinvestment.\(id)"].firstMatch
            reveal(field)
            field.tap()
            if let current = field.value as? String, !current.isEmpty, current != field.placeholderValue {
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
            }
            field.typeText(text)
            let done = app.buttons["portfolio.reinvestment.keyboardDone"].firstMatch
            if done.exists { done.tap() }
        }
        func openReinvestments() {
            let reinvestments = app.buttons["Reinvestments"].firstMatch
            reveal(reinvestments)
            reinvestments.tap()
        }

        launchAccount()
        let total = app.staticTexts["portfolio.cashIncome.total.AUD"].firstMatch
        reveal(total)
        XCTAssertEqual(total.label, "AUD 1.00")
        openReinvestments()
        let options = app.buttons["portfolio.reinvestment.options.\(seededId)"].firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 12))
        reveal(options)
        options.tap()
        app.buttons["Edit reinvestment"].tap()
        if withBroker {
            let lookup = app.buttons["portfolio.reinvestment.brokerLookup"].firstMatch
            XCTAssertTrue(lookup.waitForExistence(timeout: 5))
            lookup.tap()
            let find = app.buttons["Find linked accounts"].firstMatch
            reveal(find)
            find.tap()
            let load = app.buttons["Load broker activity"].firstMatch
            reveal(load)
            load.tap()
            let review = app.buttons["Review reinvestment"].firstMatch
            reveal(review)
            review.tap()
        }
        let shares = app.textFields["portfolio.reinvestment.shares"].firstMatch
        XCTAssertTrue(shares.waitForExistence(timeout: 8))
        XCTAssertEqual(shares.value as? String, "0.123456789012345678")
        replace("reinvested", with: "14.00000001")
        let save = app.buttons["portfolio.reinvestment.save"].firstMatch
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 12))
        let edited = try XCTUnwrap(try rows(table, select: projection, token: token).first)
        XCTAssertEqual(edited["reinvested_amount"] as? String, "14.00000001")
        XCTAssertEqual(edited["paid_on"] as? String, "2025-06-30")
        XCTAssertEqual(edited["acquired_on"] as? String, "2025-07-01")
        XCTAssertEqual(edited["basis_usd"] as? String, "9.42")
        if withBroker {
            XCTAssertEqual(edited["snaptrade_activity_id"] as? String, String(repeating: "c", count: 64))
            XCTAssertEqual(edited["snaptrade_reported_amount"] as? String, "-13.5")
            XCTAssertEqual(edited["snaptrade_reported_units"] as? String, "0.125")
        }

        let add = app.buttons["portfolio.reinvestment.add"].firstMatch
        reveal(add)
        add.tap()
        save.tap()
        XCTAssertTrue(app.staticTexts["portfolio.reinvestment.error"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["portfolio.reinvestment.holding"].firstMatch.tap()
        let choose = app.buttons["portfolio.reinvestment.holding.\(holding)"].firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 12))
        XCTAssertTrue(choose.label.contains("Archived"))
        choose.tap()
        replace("dividend", with: "12.34")
        replace("reinvested", with: "11.34")
        replace("shares", with: "0.000000000000000001")
        replace("reference", with: "Phone statement")
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 12))
        let phone = try XCTUnwrap(try rows(table, select: projection, token: token).first {
            $0["statement_reference"] as? String == "Phone statement"
        })
        XCTAssertEqual(phone["holding_id"] as? String, holding)
        XCTAssertEqual(phone["shares"] as? String, "0.000000000000000001")
        XCTAssertTrue(phone["basis_usd"] is NSNull)
        let phoneId = try XCTUnwrap(phone["id"] as? String)

        app.terminate()
        launchAccount()
        openReinvestments()
        let phoneOptions = app.buttons["portfolio.reinvestment.options.\(phoneId)"].firstMatch
        XCTAssertTrue(phoneOptions.waitForExistence(timeout: 12))

        let export = app.buttons["portfolio.cashIncome.export"].firstMatch
        reveal(export)
        export.tap()
        let fileSave = app.buttons["Save"].firstMatch
        XCTAssertTrue(fileSave.waitForExistence(timeout: 12), "Combined income CSV reaches the Files save dialog")
        attach("reinvestment-files")
        if ProcessInfo.processInfo.environment["STOCK_TRACKER_UI_TEST_SAVE_CSV"] == "1" {
            fileSave.tap()
        } else {
            app.buttons["Cancel"].firstMatch.tap()
        }
        for _ in 0..<8 where !phoneOptions.isHittable { app.swipeDown(velocity: .slow) }
        reveal(phoneOptions)
        phoneOptions.tap()
        app.buttons["Remove reinvestment"].tap()
        app.buttons["Remove reinvestment"].tap()
        XCTAssertTrue(phoneOptions.waitForNonExistence(timeout: 12))
        XCTAssertEqual(try rows(table, select: "id", token: token).compactMap { $0["id"] as? String }, [seededId])
    }

    func testStaleSaleKeepsSyncedHoldingAndPendingTradeForReview() throws {
        let email = "ledger-revision-ios-\(UUID().uuidString.lowercased())@example.com"
        let signup = try request("POST", "/auth/v1/signup", body: JSONSerialization.data(withJSONObject: [
            "email": email, "password": password,
        ]))
        XCTAssertEqual(signup.status, 200)
        let token = try signIn(email: email)
        let session = try request("GET", "/auth/v1/user", token: token)
        let user = try XCTUnwrap(JSONSerialization.jsonObject(with: session.data) as? [String: Any])
        let owner = try XCTUnwrap(user["id"] as? String)
        let holding = UUID().uuidString
        let initial: [String: Any] = [
            "id": holding, "user_id": owner, "asset_symbol": "AAPL", "asset_name": "Apple",
            "asset_exchange": "US", "asset_kind": "Stock", "shares": 3, "avg_cost": 100,
        ]
        XCTAssertEqual(try request("POST", "/rest/v1/portfolio_holdings",
                                   body: JSONSerialization.data(withJSONObject: initial), token: token).status, 201)
        app.launchArguments = ["-UITestFreshInstall", "-UITestTradingFixture", "-hasCompletedOnboarding", "YES",
                               "-SupabaseURLOverride", apiURL, "-SupabaseAnonKeyOverride", anonKey,
                               "-UITestSignIn", "\(email):\(password)", "-app_theme_mode", "Light"]
        app.launch()
        XCTAssertTrue(app.open("Portfolio", timeout: 25))
        func reveal(_ element: XCUIElement) {
            for _ in 0..<10 where !element.isHittable { app.swipeUp(velocity: .slow) }
            XCTAssertTrue(element.isHittable, app.debugDescription)
        }
        let position = app.buttons["portfolio.holding.AAPL"].firstMatch
        reveal(position)
        position.tap()
        let add = app.buttons["holding.addTransaction"]
        reveal(add)
        add.tap()

        // A different signed-in client makes an absolute holding correction while the form is open.
        let patched = try request("PATCH", "/rest/v1/portfolio_holdings?id=eq.\(holding)",
                                  body: JSONSerialization.data(withJSONObject: ["shares": 6, "avg_cost": 115]), token: token)
        XCTAssertEqual(patched.status, 204)
        let sell = app.buttons["tx.type.sell"]
        XCTAssertTrue(sell.waitForExistence(timeout: 8))
        sell.tap()
        let quantity = app.textFields.matching(identifier: "0.00").element(boundBy: 0)
        quantity.tap()
        quantity.typeText("1")
        let price = app.textFields["tx.price"].firstMatch
        let original = (price.value as? String) ?? ""
        price.tap()
        if original != "0.00" { price.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: original.count)) }
        price.typeText("150")
        app.buttons["keyboard.done"].firstMatch.tap()
        app.buttons["tx.save"].tap()
        XCTAssertTrue(app.navigationBars["AAPL"].waitForExistence(timeout: 8))
        app.navigationBars["AAPL"].buttons.firstMatch.tap()

        for _ in 0..<6 { app.swipeDown(velocity: .fast) }
        let review = app.buttons["portfolio.syncConflicts"]
        XCTAssertTrue(review.waitForExistence(timeout: 18), app.debugDescription)
        review.tap()
        XCTAssertTrue(app.navigationBars["Holding sync"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Synced units"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Sell 1"].exists)
        let cloud = try rows("portfolio_holdings", select: "id,shares,avg_cost", token: token)
        XCTAssertEqual(cloud.first?["shares"] as? Double, 6)
        XCTAssertEqual(cloud.first?["avg_cost"] as? Double, 115)
        XCTAssertTrue(try rows("transactions", select: "id", token: token).isEmpty)
        reveal(app.buttons["Discard pending changes"])
        app.buttons["Discard pending changes"].tap()
        app.buttons["Discard changes"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(review.waitForNonExistence(timeout: 8))
    }

    func testClosingSaleAndDeletedTransactionSync() throws {
        let email = "ledger-ui-\(UUID().uuidString.lowercased())@example.com"
        let signup = try request("POST", "/auth/v1/signup", body: try JSONSerialization.data(withJSONObject: [
            "email": email, "password": password
        ]))
        XCTAssertEqual(signup.status, 200)
        let account = try XCTUnwrap(JSONSerialization.jsonObject(with: signup.data) as? [String: Any])
        let user = try XCTUnwrap(account["user"] as? [String: Any])
        let userId = try XCTUnwrap(user["id"] as? String)
        let token = try signIn(email: email)
        let schema = try request("GET", "/rest/v1/portfolio_holdings?select=closed_at&limit=1", token: token)
        try XCTSkipIf(schema.status == 400, "Apply the portfolio ledger sync migration to the local stack first.")
        XCTAssertEqual(schema.status, 200)
        let provenanceSchema = try request("GET", "/rest/v1/transactions?select=trade_provenance&limit=1", token: token)
        try XCTSkipIf(provenanceSchema.status == 400, "Apply the trade provenance migration to the local stack first.")
        XCTAssertEqual(provenanceSchema.status, 200)
        let holding = UUID().uuidString
        let first = UUID()
        let extra = UUID()
        let position: [String: Any] = [
            "id": holding, "user_id": userId, "asset_symbol": "BHP", "asset_name": "BHP",
            "asset_kind": "Stock", "asset_exchange": "ASX", "shares": 3, "avg_cost": 100
        ]
        XCTAssertEqual(try request("POST", "/rest/v1/portfolio_holdings", body: JSONSerialization.data(withJSONObject: position), token: token).status, 201)
        let trades: [[String: Any]] = [(first, 2), (extra, 1)].map { id, shares in
            ["id": id.uuidString, "user_id": userId, "holding_id": holding,
             "transaction_date": "2026-10-07T00:00:00Z", "shares": shares, "price_per_share": 100, "type": "Buy"]
        }
        XCTAssertEqual(try request("POST", "/rest/v1/transactions", body: JSONSerialization.data(withJSONObject: trades), token: token).status, 201)

        func launchAccount() {
            app.launchArguments = ["-UITestFreshInstall", "-UITestTradingFixture", "-hasCompletedOnboarding", "YES",
                                   "-SupabaseURLOverride", apiURL, "-SupabaseAnonKeyOverride", anonKey,
                                   "-UITestSignIn", "\(email):\(password)"]
            app.launch()
            XCTAssertTrue(app.open("Portfolio"))
        }
        func reveal(_ element: XCUIElement) {
            for _ in 0..<8 where !element.isHittable { app.swipeUp(velocity: .slow) }
            XCTAssertTrue(element.isHittable)
        }
        launchAccount()
        let positionRow = app.buttons["portfolio.holding.BHP"].firstMatch
        // Holdings are a lazy list below the portfolio summary.
        for _ in 0..<10 where !positionRow.exists {
            app.swipeUp(velocity: .slow)
            if !positionRow.exists { Thread.sleep(forTimeInterval: 1) }
        }
        reveal(positionRow)
        positionRow.tap()
        let extraRow = app.buttons["holding.tx.\(extra.uuidString.prefix(8))"].firstMatch
        reveal(extraRow)
        extraRow.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(extraRow.waitForNonExistence(timeout: 8))

        let add = app.buttons["holding.addTransaction"]
        reveal(add)
        add.tap()
        let sell = app.buttons["tx.type.sell"]
        XCTAssertTrue(sell.waitForExistence(timeout: 5))
        sell.tap()
        let quantity = app.textFields.matching(identifier: "0.00").element(boundBy: 0)
        quantity.tap()
        quantity.typeText("2")
        let price = app.textFields["tx.price"].firstMatch
        let original = (price.value as? String) ?? ""
        price.tap()
        if original != "0.00" { price.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: original.count)) }
        price.typeText("150")
        let fee = app.textFields["tx.fees"].firstMatch
        fee.tap()
        fee.typeText("2.35")
        app.buttons["keyboard.done"].firstMatch.tap()
        app.buttons["tx.save"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["holding.closed"].firstMatch.waitForExistence(timeout: 8))

        var saved: [[String: Any]] = []
        for _ in 0..<15 {
            saved = try rows("transactions", select: "id,shares,type,price_per_share,fees,trade_provenance,deleted_at", token: token)
            if saved.contains(where: { $0["type"] as? String == "Sell" }) { break }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertEqual(saved.filter { $0["type"] as? String == "Sell" }.count, 1)
        let sale = try XCTUnwrap(saved.first { $0["type"] as? String == "Sell" })
        XCTAssertEqual(sale["shares"] as? Double, 2)
        let provenance = try XCTUnwrap(sale["trade_provenance"] as? [String: Any])
        XCTAssertEqual(provenance["currency"] as? String, "AUD")
        XCTAssertEqual(provenance["source"] as? String, "manual_trade")
        XCTAssertEqual(provenance["unitPrice"] as? Double, 150)
        XCTAssertEqual(provenance["fees"] as? Double, 2.35)
        let factor = try XCTUnwrap(provenance["usdPerUnit"] as? Double)
        XCTAssertEqual(try XCTUnwrap(sale["price_per_share"] as? Double), 150 * factor, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(sale["fees"] as? Double), 2.35 * factor, accuracy: 0.000001)
        XCTAssertTrue(saved.first { ($0["id"] as? String)?.lowercased() == first.uuidString.lowercased() }?["trade_provenance"] is NSNull)
        XCTAssertTrue(saved.first { ($0["id"] as? String)?.lowercased() == extra.uuidString.lowercased() }?["deleted_at"] is String)
        let archived = try rows("portfolio_holdings", select: "shares,closed_at,deleted_at", token: token)
        XCTAssertEqual(archived.first?["shares"] as? Double, 0)
        XCTAssertTrue(archived.first?["closed_at"] is String)
        XCTAssertTrue(archived.first?["deleted_at"] is String)

        app.terminate()
        launchAccount()
        let closed = app.buttons["portfolio.closed.BHP"].firstMatch
        reveal(closed)
        closed.tap()
        XCTAssertTrue(app.descendants(matching: .any)["closed.realised"].firstMatch.waitForExistence(timeout: 8))
    }

    // MARK: - Helpers

    /// Welcome → markets → picks → … → account step: email sign-up → "You're all set" → Home.
    private func signUpThroughOnboarding(email: String, picks: [String], referralCode: String? = nil) {
        app.buttons["onboarding.getStarted"].tap()
        waitForStep("What do you want to track?")
        for market in ["asx", "us", "crypto"] {
            let row = app.buttons["onboarding.market.\(market)"]
            if !row.isSelected { row.tap() }
        }
        tapContinue()
        waitForStep("Pick a few to follow")
        for symbol in picks {
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
        XCTAssertFalse(app.descendants(matching: .any)["account.unavailable"].exists,
                       "The local account service is up, so sign-up must be offered")
        if let referralCode {
            app.buttons["onboarding.referral.open"].tap()
            let field = app.textFields["onboarding.referral.code"]
            XCTAssertTrue(field.waitForExistence(timeout: 5), "Referral code field")
            field.tap()
            field.typeText(referralCode + "\n")
        }
        app.buttons["onboarding.account.email"].tap()
        fillCredentials(email: email)
        attach("signup-filled")
        app.buttons["auth.submit"].tap()
        waitForStep("You're all set", timeout: 20)
        attach("signup-done")
        declineSavePassword()
        // A password prompt can swallow the tap; a person would just tap again.
        let finish = app.buttons["onboarding.finish"]
        for _ in 0..<5 where finish.exists {
            finish.tap()
            _ = finish.waitForNonExistence(timeout: 3)
        }
        XCTAssertFalse(finish.exists, "Onboarding finished")
    }

    private func launch(extraArguments: [String] = []) {
        app.launchArguments = ["-UITestFreshInstall", "-app_theme_mode", "Light",
                               "-SupabaseURLOverride", apiURL, "-SupabaseAnonKeyOverride", anonKey] + extraArguments
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.getStarted"].waitForExistence(timeout: 20))
    }

    private func fillCredentials(email: String) {
        let emailField = app.textFields["auth.email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 5), "Email field")
        emailField.tap()
        emailField.typeText(email)
        let passwordField = app.secureTextFields["auth.password"].exists
            ? app.secureTextFields["auth.password"] : app.textFields["auth.password"]
        // A new-password field brings up iOS's strong-password AutoFill (a panel above the
        // keyboard or a sheet, depending on the simulator's state), which swallows typing.
        // Do what a person would: choose your own password, clear the field, type it again.
        for _ in 0..<3 {
            passwordField.tap()
            for label in ["Choose My Own Password", "Other Options…"] where app.buttons[label].waitForExistence(timeout: 1) {
                app.buttons[label].tap()
            }
            if app.staticTexts["Use Strong Password?"].exists {
                let buttons = app.buttons.matching(NSPredicate(format: "identifier == 'xmark' OR label == 'Close'"))
                if let close = buttons.allElementsBoundByIndex.last(where: { $0.isHittable }) { close.tap() }
            }
            let current = (passwordField.value as? String) ?? ""
            let typed = current.allSatisfy { $0 == "•" } ? current.count : 0
            if typed > 0 {
                passwordField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: typed))
            }
            passwordField.typeText(password)
            if (passwordField.value as? String)?.count == password.count { break }
        }
        XCTAssertEqual((passwordField.value as? String)?.count, password.count, "Whole password typed")
    }

    /// Waits for the step's title, then for the page transition to settle (mid-transition
    /// both pages' titles and Continue buttons are on screen).
    /// iOS offers to save the new password ("Save Password?") and the sheet swallows
    /// the next tap. Answer it like a person would.
    private func declineSavePassword() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            for target in [app!, springboard] where target.buttons["Not Now"].exists {
                target.buttons["Not Now"].tap()
                return
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    private func waitForStep(_ title: String, timeout: TimeInterval = 10) {
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: timeout), "Step: \(title)")
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

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: Supabase REST (as the user, so row-level security applies)

    private func signIn(email: String) throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        let response = try request("POST", "/auth/v1/token?grant_type=password", body: body)
        let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
        return try XCTUnwrap(json?["access_token"] as? String, "Password sign-in for \(email)")
    }

    private func rows(_ table: String, select: String, token: String) throws -> [[String: Any]] {
        let response = try request("GET", "/rest/v1/\(table)?select=\(select)", token: token)
        XCTAssertEqual(response.status, 200, "GET \(table)")
        return (try JSONSerialization.jsonObject(with: response.data) as? [[String: Any]]) ?? []
    }

    private func request(_ method: String, _ path: String, body: Data? = nil,
                         token: String? = nil) throws -> (status: Int, data: Data) {
        var req = URLRequest(url: URL(string: apiURL + path)!, timeoutInterval: 10)
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
        wait(for: [done], timeout: 15)
        if let failure { throw failure }
        return try XCTUnwrap(result)
    }
}
