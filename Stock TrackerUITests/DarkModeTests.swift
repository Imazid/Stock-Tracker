//
//  DarkModeTests.swift
//  Stock TrackerUITests
//
//  Dark mode stays checked: every main screen is screenshotted in Dark, and the page
//  background is sampled from the screenshot (left gutter) so a light surface — or a
//  light palette paired with white text — fails the test instead of slipping through.
//

import XCTest

final class DarkModeTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        XCUIDevice.shared.appearance = .light
        super.tearDown()
    }

    /// New installs are black (the app's look since 2026-11-13), whatever the device says.
    func testNewInstallsStartDark() {
        XCUIDevice.shared.appearance = .light
        app.launchArguments = ["-UITestFreshInstall"]
        app.launch()
        onboard(holdings: [])
        tab("Home")
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15), "Home")
        Thread.sleep(forTimeInterval: 2)
        assertBackground(dark: true, "new-install-home")
    }

    /// With System chosen, the theme the views read follows the device — including a live
    /// switch — or a dark device gets the light palette with white text.
    /// If it fails with a light screen on a dark device, check the simulator first: its
    /// appearance can get stuck (Apple's Settings app stays light too). Reboot it.
    func testSystemAppearanceFollowsTheDevice() {
        XCUIDevice.shared.appearance = .dark
        app.launchArguments = ["-UITestFreshInstall", "-app_theme_mode", "System"]
        app.launch()
        onboard(holdings: [])
        tab("Home")
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15), "Home")
        Thread.sleep(forTimeInterval: 2)
        assertBackground(dark: true, "system-dark-home")

        XCUIDevice.shared.appearance = .light
        Thread.sleep(forTimeInterval: 2)
        assertBackground(dark: false, "system-light-home")

        XCUIDevice.shared.appearance = .dark
        Thread.sleep(forTimeInterval: 2)
        assertBackground(dark: true, "system-dark-again-home")

        tab("Watchlist")
        Thread.sleep(forTimeInterval: 1.5)
        assertBackground(dark: true, "system-dark-watchlist")
        tab("Portfolio")
        Thread.sleep(forTimeInterval: 1.5)
        assertBackground(dark: true, "system-dark-portfolio")
    }

    /// Onboarding is dark by design: it must stay dark (and its secondary text readable)
    /// when the device and the app are both in Light.
    func testOnboardingStaysDarkInLightMode() {
        XCUIDevice.shared.appearance = .light
        app.launchArguments = ["-UITestFreshInstall", "-app_theme_mode", "Light"]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.getStarted"].waitForExistence(timeout: 15))
        assertBackground(dark: true, "onboarding-light-welcome")
        app.buttons["onboarding.getStarted"].tap()
        step("What do you want to track?")
        assertBackground(dark: true, "onboarding-light-markets")
        tapContinue()
        step("Pick a few to follow")
        assertBackground(dark: true, "onboarding-light-follow")
    }

    /// Walks every main screen in Dark and attaches a screenshot of each.
    func testDarkModeWalkthrough() {
        app.launchArguments = ["-UITestFreshInstall", "-app_theme_mode", "Dark"]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.getStarted"].waitForExistence(timeout: 15))
        attach("dark-00-welcome")
        onboard(holdings: [("MSFT", false, "10", "300"), ("BTC", true, "0.05", "60000")])

        // Home
        tab("Home")
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 4)
        assertBackground(dark: true, "dark-01-home")
        app.swipeUp(velocity: .slow)
        Thread.sleep(forTimeInterval: 1)
        attach("dark-01b-home-lower")
        app.swipeDown(); app.swipeDown()

        // Watchlist (+ edit mode)
        tab("Watchlist")
        Thread.sleep(forTimeInterval: 2)
        assertBackground(dark: true, "dark-02-watchlist")
        if app.buttons["watchlist.edit"].waitForExistence(timeout: 3) {
            app.buttons["watchlist.edit"].tap()
            Thread.sleep(forTimeInterval: 1)
            attach("dark-02b-watchlist-edit")
            if app.buttons["watchlist.done"].exists { app.buttons["watchlist.done"].tap() }
        }

        // Alerts: list + create sheet
        if app.buttons["watchlist.alerts"].waitForExistence(timeout: 3) {
            app.buttons["watchlist.alerts"].tap()
            Thread.sleep(forTimeInterval: 1)
            attach("dark-03-alerts")
            if app.buttons["alerts.new"].exists {
                app.buttons["alerts.new"].tap()
                Thread.sleep(forTimeInterval: 1.5)
                attach("dark-03b-alert-picker")
                let aapl = app.buttons.matching(NSPredicate(format: "identifier CONTAINS 'AAPL'")).firstMatch
                if aapl.waitForExistence(timeout: 3) && aapl.isHittable {
                    aapl.tap()
                    Thread.sleep(forTimeInterval: 1.5)
                    attach("dark-03c-alert-create")
                }
                dismissSheets()
            }
            if app.buttons["alerts.done"].exists { app.buttons["alerts.done"].tap() }
        }

        // Portfolio: segments + holding page
        tab("Portfolio")
        Thread.sleep(forTimeInterval: 4)
        assertBackground(dark: true, "dark-04-portfolio")
        for segment in ["allocation", "performance", "income", "holdings"] {
            let button = app.buttons["portfolio.segment.\(segment)"]
            scrollTo(button)
            guard button.exists else { continue }
            button.tap()
            Thread.sleep(forTimeInterval: 3)
            attach("dark-04-\(segment)")
        }
        let msft = app.buttons["portfolio.holding.MSFT"]
        if reveal(msft) {
            msft.tap()
            Thread.sleep(forTimeInterval: 2.5)
            assertBackground(dark: true, "dark-05-holding")
            let addTx = app.buttons["holding.addTransaction"]
            scrollTo(addTx)
            if addTx.exists {
                addTx.tap()
                Thread.sleep(forTimeInterval: 1.5)
                attach("dark-05b-transaction-form")
                dismissSheets()
            }
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        if app.buttons["portfolio.add"].waitForExistence(timeout: 3) {
            app.buttons["portfolio.add"].tap()
            Thread.sleep(forTimeInterval: 1.5)
            attach("dark-05c-add-sheet")
            dismissSheets()
        }

        // News + an article
        tab("News")
        Thread.sleep(forTimeInterval: 4)
        assertBackground(dark: true, "dark-06-news")

        // Search: idle, results, no matches
        tab("Search")
        Thread.sleep(forTimeInterval: 1.5)
        assertBackground(dark: true, "dark-07-search-idle")
        let field = app.searchFields.firstMatch
        if field.waitForExistence(timeout: 5) {
            field.tap()
            field.typeText("BHP")
            _ = app.buttons["search.result.asx.BHP"].waitForExistence(timeout: 20)
            attach("dark-07b-search-results")
            let bhp = app.buttons["search.result.asx.BHP"]
            if bhp.exists {
                bhp.tap()
                if app.descendants(matching: .any)["detail.screen"].waitForExistence(timeout: 10) {
                    Thread.sleep(forTimeInterval: 4)
                    attach("dark-08-detail-asx")
                    app.swipeUp(); Thread.sleep(forTimeInterval: 1)
                    attach("dark-08b-detail-asx-stats")
                    closeDetail()
                }
            }
            field.tap()
            if let text = field.value as? String, !text.isEmpty, text != field.placeholderValue {
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count))
            }
            field.typeText("zzqxnomatch")
            Thread.sleep(forTimeInterval: 4)
            attach("dark-07c-search-none")
            for label in ["Close", "Cancel"] where app.buttons[label].firstMatch.exists {
                app.buttons[label].firstMatch.tap(); break
            }
        }

        // Stock detail: US (from Home), crypto, index
        tab("Home")
        let aaplRow = app.buttons["home.watchlist.AAPL"]
        if aaplRow.waitForExistence(timeout: 15) {
            if !aaplRow.isHittable { app.swipeUp(velocity: .slow) }
            aaplRow.tap()
            if app.descendants(matching: .any)["detail.screen"].waitForExistence(timeout: 10) {
                Thread.sleep(forTimeInterval: 4)
                assertBackground(dark: true, "dark-09-detail-us")
                let chart = app.descendants(matching: .any)["detail.chart"].firstMatch
                if chart.exists {
                    let start = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
                    start.press(forDuration: 1.2)
                }
                app.swipeUp(); Thread.sleep(forTimeInterval: 1)
                attach("dark-09b-detail-us-stats")
                app.swipeUp(); Thread.sleep(forTimeInterval: 1)
                attach("dark-09c-detail-us-analysts")
                app.swipeUp(); Thread.sleep(forTimeInterval: 1)
                attach("dark-09d-detail-us-lower")
                closeDetail()
            }
        }
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'home.index.'")).firstMatch
        if card.waitForExistence(timeout: 15) {
            card.tap()
            if app.descendants(matching: .any)["detail.screen"].waitForExistence(timeout: 10) {
                Thread.sleep(forTimeInterval: 4)
                attach("dark-10-detail-index")
                closeDetail()
            }
        }

        // Settings and what's under it
        tab("Home")
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["settings.done"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        attach("dark-11-settings")
        for row in ["settings.subscription", "settings.account", "settings.referrals"] {
            let button = app.buttons[row]
            // Rows are visited top to bottom (a swipe down at the top would dismiss Settings).
            for _ in 0..<8 where !(button.exists && button.isHittable) { app.swipeUp(velocity: .slow) }
            guard button.exists, button.isHittable else { continue }
            button.tap()
            Thread.sleep(forTimeInterval: 2.5)
            attach("dark-12-\(row.replacingOccurrences(of: "settings.", with: ""))")
            if row == "settings.subscription" {
                // The plan page's upgrade button opens the paywall.
                let upgrade = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Upgrade' OR label CONTAINS[c] 'See plans' OR label CONTAINS[c] 'Pro'")).firstMatch
                if upgrade.exists && upgrade.isHittable {
                    upgrade.tap()
                    Thread.sleep(forTimeInterval: 2.5)
                    attach("dark-13-paywall")
                    let close = app.buttons["paywall.close"]
                    if close.exists { close.tap() } else { app.swipeDown(velocity: .fast) }
                    Thread.sleep(forTimeInterval: 1)
                }
            }
            goBack()
        }
        app.swipeUp(); Thread.sleep(forTimeInterval: 0.5)
        attach("dark-11b-settings-lower")
    }

    // MARK: - Background check

    /// Median luminance (0…1) of the left gutter, which is page background on every screen.
    private func backgroundLuminance() -> Double {
        guard let cg = app.screenshot().image.cgImage else { return -1 }
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return -1 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let raw = ctx.data else { return -1 }
        let px = raw.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var values: [Double] = []
        for y in stride(from: Int(Double(h) * 0.18), to: Int(Double(h) * 0.82), by: 10) {
            for x in stride(from: max(1, Int(Double(w) * 0.008)), to: Int(Double(w) * 0.03), by: 2) {
                let i = (y * w + x) * 4
                let r = Double(px[i]) / 255, g = Double(px[i + 1]) / 255, b = Double(px[i + 2]) / 255
                values.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
            }
        }
        values.sort()
        return values.isEmpty ? -1 : values[values.count / 2]
    }

    private func assertBackground(dark: Bool, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        attach(name)
        let lum = backgroundLuminance()
        if dark {
            XCTAssertLessThan(lum, 0.25, "\(name): background should be dark (luminance \(lum))", file: file, line: line)
        } else {
            XCTAssertGreaterThan(lum, 0.75, "\(name): background should be light (luminance \(lum))", file: file, line: line)
        }
    }

    // MARK: - Helpers

    private func onboard(holdings: [(symbol: String, crypto: Bool, quantity: String, cost: String)]) {
        XCTAssertTrue(app.buttons["onboarding.getStarted"].waitForExistence(timeout: 15))
        app.buttons["onboarding.getStarted"].tap()
        step("What do you want to track?")
        for market in ["asx", "us", "crypto"] {
            let row = app.buttons["onboarding.market.\(market)"]
            if row.exists && !row.isSelected { row.tap() }
        }
        tapContinue()
        step("Pick a few to follow")
        for symbol in ["AAPL", "BHP"] {
            let row = app.buttons["onboarding.pick.\(symbol)"]
            if row.waitForExistence(timeout: 5) { row.tap() }
        }
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
            numbers.element(boundBy: 0).tap()
            numbers.element(boundBy: 0).typeText(h.quantity)
            numbers.element(boundBy: 1).tap()
            numbers.element(boundBy: 1).typeText(h.cost)
            if index == 0 { attach("dark-00b-manual-holding") }
            app.buttons["Add to Portfolio"].tap()
            let expected = index == 0 ? "1 holding added" : "\(index + 1) holdings added"
            XCTAssertTrue(app.staticTexts[expected].waitForExistence(timeout: 5), "Expected “\(expected)”")
        }
        tapContinue()
        step("Know when it moves")
        let notNow = app.buttons["onboarding.notifications.notNow"]
        if notNow.exists { notNow.tap() } else { tapContinue() }
        if app.staticTexts["Keep your portfolio private"].waitForExistence(timeout: 2) { app.buttons["Not now"].tap() }
        step("Save your setup")
        app.buttons["onboarding.account.skip"].tap()
        step("You're all set")
        app.buttons["onboarding.finish"].tap()
    }

    private func tab(_ name: String) {
        XCTAssertTrue(app.open(name), "\(name) tab")
    }

    private func closeDetail() {
        let close = app.buttons["detail.close"]
        if close.waitForExistence(timeout: 3) { close.tap() }
        _ = app.descendants(matching: .any)["detail.screen"].waitForNonExistence(timeout: 5)
    }

    /// Back to Settings from a pushed page (back button) or a sheet opened from it (its
    /// own Done / Close) — never the Settings sheet's own Done.
    private func goBack() {
        let back = app.navigationBars.buttons.matching(NSPredicate(format: "label == 'Settings' OR label == 'Back'")).firstMatch
        if back.exists && back.isHittable {
            back.tap()
        } else {
            let close = app.buttons.matching(NSPredicate(
                format: "(label IN {'Done', 'Close', 'Not now'} OR identifier == 'paywall.close') AND identifier != 'settings.done'")).firstMatch
            if close.exists && close.isHittable { close.tap() } else { app.swipeDown(velocity: .fast) }
        }
        _ = app.buttons["settings.done"].waitForExistence(timeout: 3)
        Thread.sleep(forTimeInterval: 0.8)
    }

    private func dismissSheets() {
        for label in ["Cancel", "Close", "Done"] where app.buttons[label].firstMatch.exists {
            app.buttons[label].firstMatch.tap()
            Thread.sleep(forTimeInterval: 0.8)
            return
        }
        app.swipeDown(velocity: .fast)
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

    private func reveal(_ element: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isHittable { return true }
            app.swipeUp(velocity: .slow)
            Thread.sleep(forTimeInterval: 0.5)
        }
        return element.exists
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
