import XCTest

final class PrivateMarketsFlowTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
        app.launchArguments = ["-UITestFreshInstall", "-hasCompletedOnboarding", "YES",
                               "-useBiometrics", "NO", "-app_theme_mode", "Dark"]
        app.launch()
    }

    func testManualHoldingAppearsInUnifiedPortfolioAndSurvivesRelaunch() {
        openPrivateMarkets()
        app.buttons["private.destination.briefcase"].tap()
        let add = app.buttons["private.holding.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()

        let name = app.textFields["private.holding.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Local test investment")
        app.buttons["private.holding.save"].tap()
        let holding = app.buttons["private.holding.row"].firstMatch
        XCTAssertTrue(holding.waitForExistence(timeout: 5))
        holding.tap()

        let valuation = app.buttons["private.valuation.add"]
        if !valuation.isHittable { app.swipeUp() }
        XCTAssertTrue(valuation.waitForExistence(timeout: 5))
        valuation.tap()
        let amount = app.textFields["private.ledger.amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap()
        amount.typeText("2400")
        let source = app.textFields["private.ledger.source"]
        source.tap()
        source.typeText("Test ownership statement")
        let method = app.textFields["private.ledger.method"]
        method.tap()
        method.typeText("Statement value")
        app.buttons["private.ledger.save"].tap()
        XCTAssertFalse(app.navigationBars["Record Valuation"].exists)
        let recordedMark = app.descendants(matching: .any)["private.valuation.record"].firstMatch
        if !recordedMark.isHittable { app.swipeUp() }
        XCTAssertTrue(recordedMark.waitForExistence(timeout: 5))
        XCTAssertTrue(recordedMark.label.contains("Test ownership statement"))

        app.terminate()
        app.launchArguments.removeAll { $0 == "-UITestFreshInstall" }
        app.launch()
        openPrivateMarkets()
        app.buttons["private.destination.briefcase"].tap()
        XCTAssertTrue(holding.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["private.allocation"].firstMatch.exists)
        XCTAssertTrue(holding.label.contains("Local test investment"))
    }

    func testProviderDirectoryAndOfflineCalculatorAreReachable() {
        openPrivateMarkets()
        app.buttons["private.destination.magnifyingglass"].tap()
        XCTAssertTrue(app.navigationBars["Discover Deals"].waitForExistence(timeout: 5))
        let birchal = app.staticTexts["Birchal"]
        if !birchal.isHittable { app.swipeUp() }
        XCTAssertTrue(birchal.waitForExistence(timeout: 8))
        let back = app.navigationBars["Discover Deals"].buttons["BackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        let research = app.buttons["private.destination.sparkles"]
        if !research.waitForExistence(timeout: 4) {
            app.tabBars.firstMatch.buttons["Private Markets"].tap()
        }
        XCTAssertTrue(research.waitForExistence(timeout: 6))
        research.tap()
        let calculator = app.buttons["Ownership, dilution and exit scenarios"]
        XCTAssertTrue(calculator.waitForExistence(timeout: 5))
        calculator.tap()
        XCTAssertTrue(app.navigationBars["Scenario Calculator"].waitForExistence(timeout: 5))
    }

    func testCopilotShowsPrivateAndListedExposure() {
        openPrivateMarkets()
        let copilot = app.buttons["trading.copilot"].firstMatch
        XCTAssertTrue(copilot.waitForExistence(timeout: 8))
        copilot.tap()
        let exposure = app.buttons["copilot.suggestion.Show my private in"]
        XCTAssertTrue(exposure.waitForExistence(timeout: 5))
        exposure.tap()
        XCTAssertTrue(app.descendants(matching: .any)["private.allocation"].firstMatch.waitForExistence(timeout: 6))
    }

    @MainActor
    func testOwnershipExcerptCanBeReviewedAndLinked() async throws {
        let host = "http://127.0.0.1:58531"
        let authHost = "http://127.0.0.1:58521"
        let key = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0"
        func post(_ url: String, _ fields: [String: String], token: String? = nil) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: try XCTUnwrap(URL(string: url)), timeoutInterval: 20)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(key, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token ?? key)", forHTTPHeaderField: "Authorization")
            var body: [String: Any] = fields
            if fields["action"] == "save_document" { body["authorized"] = true }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0,
                    (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
        }

        let edge = host + "/functions/v1/private-markets"
        var health = URLRequest(url: try XCTUnwrap(URL(string: authHost + "/auth/v1/health")), timeoutInterval: 5)
        health.setValue(key, forHTTPHeaderField: "apikey")
        let response = try? await URLSession.shared.data(for: health).1 as? HTTPURLResponse
        try XCTSkipUnless(response?.statusCode == 200, "Start the disposable Private Markets test stack and function proxy.")
        let catalogue = try await post(edge, ["action": "catalog"])
        XCTAssertEqual(catalogue.0, 200)
        let email = "private-ui-\(UUID().uuidString.lowercased())@example.com"
        let password = "Test-Private-Markets-2026!"
        let credentials = ["email": email, "password": password]
        let account = try await post(authHost + "/auth/v1/signup", credentials)
        XCTAssertEqual(account.0, 200)
        let session = try await post(authHost + "/auth/v1/token?grant_type=password", credentials)
        XCTAssertEqual(session.0, 200)
        let token = try XCTUnwrap(session.1["access_token"] as? String)
        let saved = try await post(edge, ["action": "save_document", "title": "Ownership statement fixture",
                                          "excerpt": "The unit registry statement records 25 ordinary units and AUD 9500 of paid capital."], token: token)
        XCTAssertEqual(saved.0, 201)

        app.terminate()
        app.launchArguments += ["-SupabaseURLOverride", host, "-SupabaseAnonKeyOverride", key,
                                "-UITestSignIn", "\(email):\(password)"]
        app.launch()
        openPrivateMarkets()
        app.buttons["private.destination.folder"].tap()
        XCTAssertTrue(app.buttons["Add research excerpt"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.navigationBars["Deal Room"].buttons["BackButton"].waitForExistence(timeout: 6))
        app.navigationBars["Deal Room"].buttons["BackButton"].tap()
        XCTAssertTrue(app.buttons["private.destination.briefcase"].waitForExistence(timeout: 6))
        app.buttons["private.destination.briefcase"].tap()
        let add = app.buttons["private.holding.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let name = app.textFields["private.holding.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Private evidence holding")
        app.buttons["private.holding.save"].tap()
        let holding = app.buttons["private.holding.row"].firstMatch
        XCTAssertTrue(holding.waitForExistence(timeout: 8))
        holding.tap()
        let evidence = app.buttons["private.ownership.evidence"]
        if !evidence.isHittable { app.swipeUp() }
        XCTAssertTrue(evidence.waitForExistence(timeout: 8))
        evidence.tap()
        let statement = app.buttons["private.ownership.excerpt"].firstMatch
        XCTAssertTrue(statement.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(statement.label.contains("Ownership statement fixture"))
        statement.tap()
        let reviewed = app.switches["private.ownership.reviewed"]
        XCTAssertTrue(reviewed.waitForExistence(timeout: 20), app.debugDescription)
        let control = reviewed.switches.firstMatch
        if control.exists { control.tap() } else { reviewed.tap() }
        let save = app.buttons["Save evidence review"]
        XCTAssertTrue(save.isEnabled, app.debugDescription)
        save.tap()
        XCTAssertTrue(app.buttons["private.ownership.linked"].waitForExistence(timeout: 8), app.debugDescription)
        app.buttons["private.ownership.linked"].tap()
        XCTAssertTrue(app.staticTexts["Reviewed by you"].waitForExistence(timeout: 8))

        for title in ["Ownership excerpt", "Ownership Evidence", "Private evidence holding", "My Private Portfolio"] {
            let back = app.navigationBars[title].buttons["BackButton"]
            XCTAssertTrue(back.waitForExistence(timeout: 6), app.debugDescription)
            back.tap()
        }
        app.buttons["private.companyUpdates"].tap()
        let monitor = app.switches["private.monitor.enable"]
        XCTAssertTrue(monitor.waitForExistence(timeout: 8), app.debugDescription)
        let monitorControl = monitor.switches.firstMatch
        if monitorControl.exists { monitorControl.tap() } else { monitor.tap() }
        XCTAssertTrue(app.switches["private.monitor.eligible"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Monitoring inbox"].waitForExistence(timeout: 8))
    }

    private func openPrivateMarkets() {
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 12))
        let direct = tabs.buttons["Private Markets"]
        XCTAssertTrue(direct.waitForExistence(timeout: 8))
        direct.tap()
        XCTAssertTrue(app.buttons["private.destination.magnifyingglass"].waitForExistence(timeout: 5))
    }
}
