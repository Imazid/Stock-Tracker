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
    private let apiURL = "http://127.0.0.1:58321"
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
