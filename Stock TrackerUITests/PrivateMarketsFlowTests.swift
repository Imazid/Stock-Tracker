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
    }

    func testCompanyUpdatesShowsMonitoringControls() {
        openPrivateMarkets()
        app.buttons["private.companyUpdates"].tap()
        let monitor = app.switches["private.monitor.enable"]
        XCTAssertTrue(monitor.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertFalse(monitor.isEnabled)
    }

    @MainActor
    func testSignedInMonitoringRequiresSeparateDigestConsent() async throws {
        let authHost = "http://127.0.0.1:58521"
        let host = "http://127.0.0.1:58531"
        let key = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0"
        let email = "private-monitor-ui-\(UUID().uuidString.lowercased())@example.com"
        let password = "Test-Private-Markets-2026!"
        var health = URLRequest(url: try XCTUnwrap(URL(string: authHost + "/auth/v1/health")), timeoutInterval: 5)
        health.setValue(key, forHTTPHeaderField: "apikey")
        let response = try? await URLSession.shared.data(for: health).1 as? HTTPURLResponse
        try XCTSkipUnless(response?.statusCode == 200, "Start the disposable Private Markets test stack and function proxy.")
        var signup = URLRequest(url: try XCTUnwrap(URL(string: authHost + "/auth/v1/signup")), timeoutInterval: 45)
        signup.httpMethod = "POST"
        signup.setValue(key, forHTTPHeaderField: "apikey")
        signup.setValue("application/json", forHTTPHeaderField: "Content-Type")
        signup.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        let (_, signUpResponse) = try await URLSession.shared.data(for: signup)
        XCTAssertEqual((signUpResponse as? HTTPURLResponse)?.statusCode, 200)

        app.terminate()
        app.launchArguments += ["-SupabaseURLOverride", host, "-SupabaseAnonKeyOverride", key,
                                "-UITestSignIn", "\(email):\(password)"]
        app.launch()
        openPrivateMarkets()
        app.buttons["private.companyUpdates"].tap()
        let monitor = app.switches["private.monitor.enable"]
        XCTAssertTrue(monitor.waitForExistence(timeout: 10))
        XCTAssertTrue(monitor.isEnabled, app.debugDescription)
        let monitorControl = monitor.switches.firstMatch
        if monitorControl.exists { monitorControl.tap() } else { monitor.tap() }

        let digest = app.switches["private.monitor.digest"]
        XCTAssertTrue(digest.waitForExistence(timeout: 20), app.debugDescription)
        let digestControl = digest.switches.firstMatch
        let toggle = digestControl.exists ? digestControl : digest
        XCTAssertTrue(toggle.wait(for: \.isEnabled, toEqual: true, timeout: 45), app.debugDescription)
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.tap()
        let ready = app.staticTexts["A summary appears after the next scheduled run with new announcements."]
        if !ready.isHittable { app.swipeUp() }
        XCTAssertTrue(ready.waitForExistence(timeout: 20), app.debugDescription)
    }

    @MainActor
    func testProviderWithdrawalTimelineShowsSourceAndStatus() async throws {
        // Optional disposable fixture seeded by the application lifecycle integration.
        try launchWithLocalSession("PRIVATE_LIFECYCLE_TEST_SESSION")
        openPrivateMarkets()
        let investor = app.buttons["Investor profile & applications"]
        if !investor.isHittable { app.swipeUp() }
        XCTAssertTrue(investor.waitForExistence(timeout: 10))
        investor.tap()
        let row = app.buttons["private.application.row"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 45), app.debugDescription)
        for _ in 0..<4 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.isHittable, app.debugDescription)
        row.tap()
        let status = app.staticTexts["private.application.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(status.label, "Provider recorded a withdrawal request")
        let timeline = app.staticTexts["Withdrawal requested"]
        if !timeline.isHittable { app.swipeUp() }
        XCTAssertTrue(timeline.waitForExistence(timeout: 8))
        let help = app.descendants(matching: .any)["private.application.withdrawalHelp"].firstMatch
        if !help.isHittable { app.swipeUp() }
        XCTAssertTrue(help.waitForExistence(timeout: 8), app.debugDescription)
    }

    @MainActor
    func testProviderDistributionAppearsInMonitoringInbox() async throws {
        try launchWithLocalSession("PRIVATE_DISTRIBUTION_TEST_SESSION")
        openPrivateMarkets()
        let updates = app.buttons["private.companyUpdates"]
        let monitor = app.switches["private.monitor.enable"]
        let ready = NSPredicate { _, _ in monitor.exists && monitor.isEnabled }
        for _ in 0..<3 {
            if updates.waitForExistence(timeout: 3), updates.isHittable { updates.tap() }
            let enabled = XCTNSPredicateExpectation(predicate: ready, object: monitor)
            if await XCTWaiter().fulfillment(of: [enabled], timeout: 8) == .completed { break }
        }
        XCTAssertTrue(monitor.exists, app.debugDescription)
        XCTAssertTrue(monitor.isEnabled, app.debugDescription)
        if monitor.value as? String != "1" {
            let control = monitor.switches.firstMatch
            if control.exists { control.tap() } else { monitor.tap() }
        }
        let alert = app.descendants(matching: .any)["private.monitor.alert.distribution"].firstMatch
        for _ in 0..<3 where !alert.exists {
            app.swipeUp()
            if alert.waitForExistence(timeout: 5) { break }
        }
        XCTAssertTrue(alert.exists, app.debugDescription)
        XCTAssertTrue(alert.staticTexts["Provider recorded a distribution"].exists)
        XCTAssertTrue(alert.staticTexts["Provider distribution statement"].exists)
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Received on ")).firstMatch.exists)
    }

    @MainActor
    func testPublishedCompanyShowsDatedFundingHistory() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PRIVATE_PUBLISHED_CATALOGUE_TEST"] == "1",
                          "Run this test with the hosted Private Markets configuration.")
        openPrivateMarkets()
        app.buttons["private.destination.building.2"].tap()
        let heidi = app.buttons["private.explorer.company.D72C4060-1AE7-4A2F-8F2E-9F4BF1577E01"]
        XCTAssertTrue(heidi.waitForExistence(timeout: 20), app.debugDescription)
        heidi.tap()
        XCTAssertTrue(app.navigationBars["Heidi"].waitForExistence(timeout: 8))
        let seriesC = app.buttons["private.funding.round.Series C"]
        let seriesB = app.buttons["private.funding.round.Series B"]
        XCTAssertTrue(seriesC.waitForExistence(timeout: 8), app.debugDescription)
        if !seriesB.isHittable { app.swipeUp() }
        XCTAssertTrue(seriesB.isHittable, app.debugDescription)
        XCTAssertTrue(seriesB.label.contains("Capital raised"))
        XCTAssertTrue(seriesB.label.contains("Reported valuation"))
        seriesB.tap()
        XCTAssertTrue(app.staticTexts["Announced"].waitForExistence(timeout: 8), app.debugDescription)
        let source = app.descendants(matching: .any)["Funding round source"].firstMatch
        for _ in 0..<2 where !source.isHittable { app.swipeUp() }
        XCTAssertTrue(source.isHittable, app.debugDescription)
    }

    @MainActor
    func testCompanyUpdatesShowsPublishedFinancing() async throws {
        try launchWithLocalSession("PRIVATE_FINANCING_TEST_SESSION")
        openPrivateMarkets()
        let explorer = app.buttons["private.destination.building.2"]
        let heidi = app.buttons["private.explorer.company.D72C4060-1AE7-4A2F-8F2E-9F4BF1577E01"]
        for _ in 0..<3 where !heidi.exists {
            if explorer.exists && explorer.isHittable { explorer.tap() }
            if heidi.waitForExistence(timeout: 6) { break }
        }
        XCTAssertTrue(heidi.exists, app.debugDescription)
        heidi.tap()
        let round = app.buttons["private.funding.round.Series C"]
        XCTAssertTrue(round.waitForExistence(timeout: 8))
        round.tap()
        let follow = app.buttons["Follow company"]
        for _ in 0..<3 where !follow.isHittable { app.swipeUp() }
        XCTAssertTrue(follow.isHittable, app.debugDescription)
        follow.tap()
        XCTAssertTrue(app.buttons["Unfollow company"].exists)

        let updates = app.buttons["private.companyUpdates"]
        for _ in 0..<4 where !updates.isHittable {
            let back = app.navigationBars.buttons["BackButton"].firstMatch
            if back.isHittable { back.tap() }
        }
        XCTAssertTrue(updates.isHittable)
        updates.tap()
        let completed = app.staticTexts["Series C closed"]
        for _ in 0..<3 where !completed.isHittable {
            if completed.waitForExistence(timeout: 5) && completed.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(completed.isHittable, app.debugDescription)
        let evidence = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "2026-09-22")).firstMatch
        XCTAssertTrue(evidence.exists)
        XCTAssertTrue(evidence.label.contains("USD 100000000"))
        let summary = app.buttons["Summarise published updates"]
        if !summary.isHittable { app.swipeDown() }
        XCTAssertTrue(summary.isHittable)
        summary.tap()
        XCTAssertTrue(app.navigationBars["AI Investment Research"].waitForExistence(timeout: 10))
        let fundingSource = app.switches.containing(NSPredicate(format: "label CONTAINS %@", "Series C closed")).firstMatch
        for _ in 0..<3 where !fundingSource.exists { app.swipeUp() }
        XCTAssertTrue(fundingSource.exists, app.debugDescription)
        XCTAssertEqual(fundingSource.value as? String, "1")
    }

    @MainActor
    func testResearchWorkspaceReloadsRecentRuns() throws {
        try launchWithLocalSession("PRIVATE_RESEARCH_TEST_SESSION")
        openPrivateMarkets()
        let run = app.descendants(matching: .any)["private.research.run.running"].firstMatch
        let destination = app.buttons["private.destination.sparkles"]
        for _ in 0..<3 where !run.exists {
            if destination.exists { destination.tap() }
            if app.navigationBars["AI Investment Research"].waitForExistence(timeout: 5) {
                for _ in 0..<3 where !run.exists { app.swipeUp() }
                if run.waitForExistence(timeout: 5) { break }
            }
        }
        XCTAssertTrue(run.exists, app.debugDescription)
        let failure = app.staticTexts.containing(NSPredicate(
            format: "identifier == %@ AND label == %@", "private.research.run.failed", "The research run timed out."
        )).firstMatch
        for _ in 0..<3 where !failure.exists { app.swipeUp() }
        XCTAssertTrue(failure.exists, app.debugDescription)
    }

    @MainActor
    func testProviderVerificationIsSeparateFromInvestorDeclaration() throws {
        try launchWithLocalSession("PRIVATE_ELIGIBILITY_TEST_SESSION")
        openPrivateMarkets()
        let active = app.staticTexts["private.investor.verificationStatus.birchal:AU"]
        let investor = app.buttons["Investor profile & applications"]
        for _ in 0..<3 where !active.exists {
            if investor.exists {
                if !investor.isHittable { app.swipeUp() }
                investor.tap()
            }
            if app.navigationBars["Investor Profile & Applications"].waitForExistence(timeout: 5) {
                for _ in 0..<3 where !active.exists { app.swipeUp() }
                if active.waitForExistence(timeout: 5) { break }
            }
        }
        XCTAssertTrue(active.exists, app.debugDescription)
        XCTAssertEqual(active.label, "Verification current")
        let certificate = app.descendants(matching: .any)["private.investor.certificate.birchal:AU"].firstMatch
        XCTAssertTrue(certificate.exists)
        let revoked = app.staticTexts["private.investor.verificationStatus.onmarket:AU"]
        for _ in 0..<3 where !revoked.exists { app.swipeUp() }
        XCTAssertTrue(revoked.exists, app.debugDescription)
        XCTAssertEqual(revoked.label, "Connection revoked")
    }

    @MainActor
    func testCancelledCapitalCallShowsProviderEvidence() async throws {
        try launchWithLocalSession("PRIVATE_CAPITAL_CANCELLATION_TEST_SESSION")
        openPrivateMarkets()
        let capital = app.buttons["private.destination.arrow.left.arrow.right"]
        let cancelled = app.otherElements["private.capital.cancelledCall"].firstMatch
        for _ in 0..<3 where !cancelled.exists {
            if capital.exists {
                if !capital.isHittable { app.swipeUp() }
                if capital.isHittable { capital.tap() }
            }
            if cancelled.waitForExistence(timeout: 8) { break }
        }
        XCTAssertTrue(cancelled.exists, app.debugDescription)
        XCTAssertTrue(cancelled.staticTexts["Provider rescission"].exists)
        let original = cancelled.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Original call notice")).firstMatch
        XCTAssertTrue(original.exists)
        XCTAssertTrue(original.label.hasPrefix("Originally due "))
        XCTAssertFalse(app.buttons["Record as paid"].exists)
    }

    @MainActor
    func testProviderExitShowsSettlementSourceAndRemainingUnits() async throws {
        try launchWithLocalSession("PRIVATE_DISPOSITION_TEST_SESSION")
        openPrivateMarkets()
        let portfolio = app.buttons["private.destination.briefcase"]
        let row = app.descendants(matching: .any)["private.holding.providerRow"].firstMatch
        for _ in 0..<4 {
            // Restoring a user resets the workspace navigation for the new account.
            if portfolio.exists { portfolio.tap() }
            if app.navigationBars["My Private Portfolio"].waitForExistence(timeout: 3) {
                if row.waitForExistence(timeout: 5) { break }
                if app.navigationBars["My Private Portfolio"].exists {
                    // A transient failure in the disposable gateway can leave the ledger empty.
                    app.swipeDown()
                    if row.waitForExistence(timeout: 5) { break }
                    app.swipeUp()
                    if row.waitForExistence(timeout: 3) { break }
                }
            }
        }
        XCTAssertTrue(row.exists, app.debugDescription)
        for _ in 0..<3 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.isHittable)
        row.tap()
        let status = app.staticTexts["Exited · Provider confirmed"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        let source = app.descendants(matching: .any)["private.holding.exitSource"].firstMatch
        let remaining = app.descendants(matching: .any)["private.holding.units"].firstMatch
        for _ in 0..<3 where !source.exists || !remaining.exists { app.swipeUp() }
        XCTAssertTrue(source.exists, app.debugDescription)
        XCTAssertEqual(source.value as? String, "Final sale receipt")
        XCTAssertTrue(remaining.exists, app.debugDescription)
        XCTAssertEqual(remaining.label, "Remaining shares or units")
        XCTAssertEqual(remaining.value as? String, 0.formatted())
    }

    @MainActor
    private func launchWithLocalSession(_ variable: String) throws {
        let session = ProcessInfo.processInfo.environment[variable]
        try XCTSkipUnless(session != nil, "Set \(variable) to the access and refresh tokens of a seeded disposable account.")
        let key = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0"
        let port = ProcessInfo.processInfo.environment["PRIVATE_TEST_BACKEND_PORT"].flatMap(UInt16.init) ?? 58533
        app.terminate()
        app.launchArguments += ["-SupabaseURLOverride", "http://127.0.0.1:\(port)", "-SupabaseAnonKeyOverride", key]
        app.launchEnvironment["UITEST_LOCAL_SUPABASE_SESSION"] = try XCTUnwrap(session)
        app.launch()
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
