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

    private func launch() {
        app.launchArguments = ["-UITestFreshInstall", "-app_theme_mode", "Light",
                               "-SupabaseURLOverride", apiURL, "-SupabaseAnonKeyOverride", anonKey]
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
                let close = app.buttons["xmark"].exists ? app.buttons["xmark"] : app.buttons["Close"]
                if close.exists { close.tap() }
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
