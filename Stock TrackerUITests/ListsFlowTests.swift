//
//  ListsFlowTests.swift
//  Stock TrackerUITests
//
//  Watchlist, Search, News, Alerts and Settings, driven from a true first launch
//  (`-UITestFreshInstall`). Uses live data, so waits are generous.
//

import XCTest

final class ListsFlowTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestFreshInstall"]
    }

    // MARK: Watchlist

    /// Add from the watchlist's own + button, remove by swipe, reorder and multi-remove in Edit.
    func testWatchlistAddRemoveReorder() {
        launchAndOnboard(picks: ["AAPL", "NVDA", "BHP"])
        tab("Watchlist")
        for symbol in ["AAPL", "NVDA", "BHP"] {
            XCTAssertTrue(app.buttons["watchlist.row.\(symbol)"].waitForExistence(timeout: 20), "\(symbol) should be on the list")
        }
        attach("watchlist")

        // Add MSFT from the + button.
        app.buttons["watchlist.add"].tap()
        let field = searchField(placeholder: "Add a stock, ETF or crypto")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Add sheet should open with search")
        field.tap()
        field.typeText("MSFT")
        let add = app.buttons["search.result.us.MSFT.toggle"]
        require(add, timeout: 20, "MSFT should come back from search")
        add.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Added MSFT'")).firstMatch.waitForExistence(timeout: 3),
                      "Adding should confirm")
        attach("add-sheet")
        let done = app.buttons["addSymbols.done"]
        if !done.exists { closeSearch() }
        done.tap()
        let msft = app.buttons["watchlist.row.MSFT"]
        XCTAssertTrue(msft.waitForExistence(timeout: 5), "MSFT should be on the list after adding")

        // Swipe to remove.
        msft.swipeLeft()
        let remove = app.buttons["Remove"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 3), "Swipe should reveal Remove")
        remove.tap()
        XCTAssertTrue(msft.waitForNonExistence(timeout: 5), "MSFT should be removed")

        // Reorder: drag BHP to the top.
        app.buttons["watchlist.edit"].tap()
        let handles = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder'"))
        XCTAssertTrue(handles.firstMatch.waitForExistence(timeout: 3), "Edit mode should show reorder handles")
        attach("edit")
        let bhpHandle = handles.matching(NSPredicate(format: "label CONTAINS 'BHP'")).firstMatch
        let aaplHandle = handles.matching(NSPredicate(format: "label CONTAINS 'AAPL'")).firstMatch
        XCTAssertTrue(bhpHandle.exists && aaplHandle.exists, "Each row should have a reorder handle")
        let start = bhpHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = aaplHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -0.2))
        start.press(forDuration: 0.6, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.6)
        Thread.sleep(forTimeInterval: 1)
        app.buttons["watchlist.done"].tap()
        let bhpY = app.buttons["watchlist.row.BHP"].frame.minY
        let aaplY = app.buttons["watchlist.row.AAPL"].frame.minY
        XCTAssertLessThan(bhpY, aaplY, "BHP should now be above AAPL")

        // Multi-select remove.
        app.buttons["watchlist.edit"].tap()
        app.buttons["watchlist.row.NVDA"].tap()
        let removeSelected = app.buttons["watchlist.deleteSelected"]
        XCTAssertTrue(removeSelected.isEnabled, "Selecting a row should enable Remove")
        removeSelected.tap()
        app.buttons["watchlist.done"].tap()
        XCTAssertTrue(app.buttons["watchlist.row.NVDA"].waitForNonExistence(timeout: 5), "NVDA should be removed")
        XCTAssertTrue(app.buttons["watchlist.row.AAPL"].exists)
    }

    // MARK: Search

    /// US, ASX and crypto searches rank sensibly and end in results or "no matches", never a spinner.
    func testSearchUSASXCryptoAndNoResults() {
        launchAndOnboard(picks: ["AAPL"])
        tab("Search")
        XCTAssertTrue(app.buttons["search.popular.us.NVDA"].waitForExistence(timeout: 5)
                      || app.buttons["search.popular.asx.BHP"].exists, "Idle search should show popular listings")
        attach("search-idle")

        let field = searchField(placeholder: "Stocks, ETFs and crypto")
        field.tap()
        field.typeText("apple")
        let aapl = app.buttons["search.result.us.AAPL"]
        XCTAssertTrue(aapl.waitForExistence(timeout: 20), "Apple should be found")
        let aple = app.buttons["search.result.us.APLE"]
        if aple.exists {
            XCTAssertLessThan(aapl.frame.minY, aple.frame.minY, "Apple Inc. should rank above Apple Hospitality")
        }
        XCTAssertTrue(aapl.label.contains("Apple"), "Results keep the company name, not just the ticker")
        attach("search-apple")

        replace(field, with: "BHP")
        require(app.buttons["search.result.asx.BHP"], timeout: 20, "BHP on the ASX should be found")
        attach("search-bhp")

        replace(field, with: "VAS")
        require(app.buttons["search.result.asx.VAS"], timeout: 20, "ETFs (VAS) should be searchable")

        replace(field, with: "bitcoin")
        let btc = app.buttons["search.result.crypto.BTC"]
        require(btc, timeout: 25, "Bitcoin should be found")
        let bitcoinETF = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search.result.us.'")).firstMatch
        if bitcoinETF.exists {
            XCTAssertLessThan(btc.frame.minY, bitcoinETF.frame.minY, "Bitcoin itself should rank above Bitcoin funds")
        }
        app.buttons["search.result.crypto.BTC.toggle"].tap()
        attach("search-bitcoin")

        replace(field, with: "qqzzxq")
        let noResults = app.descendants(matching: .any)["search.noResults"]
        let failed = app.descendants(matching: .any)["search.failed"]
        XCTAssertTrue(noResults.waitForExistence(timeout: 20) || failed.exists, "Nonsense should end in 'no matches'")
        XCTAssertFalse(app.descendants(matching: .any)["search.searching"].exists, "No endless spinner")
        attach("search-none")

        // The coin added from search is on the watchlist.
        closeSearch()
        tab("Watchlist")
        XCTAssertTrue(app.buttons["watchlist.row.BTC"].waitForExistence(timeout: 10), "BTC added from search should be on the list")
    }

    // MARK: News

    func testNewsArticleOpensAndFiltersExplainThemselves() {
        launchAndOnboard(picks: ["AAPL", "NVDA"])
        tab("News")
        let article = app.buttons["news.article"].firstMatch
        XCTAssertTrue(article.waitForExistence(timeout: 30), "Articles should load")
        attach("news")
        article.tap()
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10), "The article should open in Safari View")
        Thread.sleep(forTimeInterval: 2)
        attach("news-article")
        close.tap()
        XCTAssertTrue(article.waitForExistence(timeout: 5))

        app.buttons["news.filter.portfolio"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["news.empty.holdings"].waitForExistence(timeout: 5),
                      "Holdings filter with no holdings should explain itself")
        app.buttons["news.filter.watchlist"].tap()
        let watchNews = app.buttons["news.article"].firstMatch
        let explained = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'news.empty'")).firstMatch
        XCTAssertTrue(watchNews.waitForExistence(timeout: 20) || explained.exists, "Watchlist filter shows news or explains why not")
        attach("news-watchlist")
    }

    // MARK: Alerts

    /// An alert set in A$ is stored in USD and shows back as the same A$ price.
    func testCreateAlertInAUDRoundTrips() {
        launchAndOnboard(picks: ["AAPL"])
        setCurrency("AUD")
        tab("Watchlist")
        let row = app.buttons["watchlist.row.AAPL"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        XCTAssertTrue(waitForLoadedPrice(row), "AAPL should have a live price")

        row.swipeRight()
        let alertAction = app.buttons["Alert"].firstMatch
        XCTAssertTrue(alertAction.waitForExistence(timeout: 3), "Swipe right should offer Alert")
        alertAction.tap()

        let price = app.textFields["alert.price"]
        XCTAssertTrue(price.waitForExistence(timeout: 5), "Alert sheet should open")
        XCTAssertTrue(price.label.contains("AUD"), "Input is in the person's currency: \(price.label)")
        app.buttons["alert.quick.5"].tap()
        let typed = (price.value as? String) ?? ""
        XCTAssertFalse(typed.isEmpty)
        XCTAssertTrue(app.staticTexts["alert.relation"].label.contains("above"), "+5% is above the current price")
        attach("alert-create")
        app.buttons["alert.create"].tap()
        declineNotificationsIfAsked()

        app.buttons["watchlist.alerts"].tap()
        let alertRow = app.descendants(matching: .any)["alerts.row.AAPL"]
        XCTAssertTrue(alertRow.waitForExistence(timeout: 5), "The alert should be listed")
        XCTAssertTrue(alertRow.label.contains(typed), "Stored target should round-trip to \(typed): \(alertRow.label)")
        XCTAssertTrue(alertRow.label.contains("rises to"))
        attach("alerts-list")

        alertRow.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["alerts.empty"].waitForExistence(timeout: 5), "Empty state after delete")
        app.buttons["alerts.done"].tap()
    }

    // MARK: Settings

    /// "Every time" alert: create it, see it fire (Triggered · re-arms below …) and re-arm.
    /// Prices for the fire / re-arm steps come from the DEBUG `-UITestAlertPrices` hook;
    /// everything else (the alert, its stored USD target, the list) is the real path.
    func testRepeatingAlertFiresAndReArms() {
        launchAndOnboard(picks: ["AAPL"])
        setCurrency("AUD")
        tab("Watchlist")
        let row = app.buttons["watchlist.row.AAPL"]
        require(row, timeout: 20, "AAPL should be on the watchlist")
        XCTAssertTrue(waitForLoadedPrice(row), "AAPL should have a live price")

        row.swipeRight()
        let alertAction = app.buttons["Alert"].firstMatch
        XCTAssertTrue(alertAction.waitForExistence(timeout: 3), "Swipe right should offer Alert")
        alertAction.tap()
        XCTAssertTrue(app.textFields["alert.price"].waitForExistence(timeout: 5), "Alert sheet should open")
        app.buttons["alert.quick.5"].tap()

        let explainer = app.staticTexts["alert.repeat.explainer"]
        XCTAssertTrue(explainer.label.contains("Once"), "Once is the default: \(explainer.label)")
        app.buttons["Every time"].firstMatch.tap()
        XCTAssertTrue(explainer.label.contains("Repeats"), "Every time explains itself: \(explainer.label)")
        XCTAssertTrue(app.staticTexts["alert.preview"].label.contains("every time")
                      || app.descendants(matching: .any)["alert.preview"].label.contains("every time"),
                      "The preview line says it repeats")
        attach("alert-repeat-create")
        app.buttons["alert.create"].tap()
        declineNotificationsIfAsked()

        app.buttons["watchlist.alerts"].tap()
        let alertRow = app.descendants(matching: .any)["alerts.row.AAPL"]
        require(alertRow, timeout: 5, "The alert should be listed")
        XCTAssertTrue(alertRow.label.contains("every time"), "Row marks the alert as repeating: \(alertRow.label)")
        XCTAssertTrue(alertRow.label.contains("to go"), "Armed alert shows the distance: \(alertRow.label)")
        attach("alerts-repeat-armed")

        // The price jumps past the target: it fires, stays listed, and waits to re-arm.
        relaunch(alertPrices: "AAPL=100000")
        let fired = expectation(for: NSPredicate(format: "label CONTAINS 'Triggered' AND label CONTAINS 're-arms below A$'"),
                                evaluatedWith: alertRow)
        if XCTWaiter.wait(for: [fired], timeout: 60) != .completed {
            attach("failure")
            XCTFail("A repeating alert should fire and wait to re-arm: \(alertRow.label)")
        }
        attach("alerts-repeat-triggered")

        // The price falls back well below: it re-arms and shows the distance again.
        relaunch(alertPrices: "AAPL=1")
        let rearmed = expectation(for: NSPredicate(format: "NOT (label CONTAINS 'Triggered') AND label CONTAINS 'to go'"),
                                  evaluatedWith: alertRow)
        if XCTWaiter.wait(for: [rearmed], timeout: 60) != .completed {
            attach("failure")
            XCTFail("The alert should re-arm after the price moved back: \(alertRow.label)")
        }
        attach("alerts-repeat-rearmed")

        alertRow.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["alerts.empty"].waitForExistence(timeout: 5), "Empty state after delete")
        app.buttons["alerts.done"].tap()
    }

    /// An alert set from a stock page for something you don't track (MSFT, opened from
    /// Search) must still be checked. Before, only watchlist/portfolio symbols were priced
    /// for alerts, so these never fired — in the app or in the background.
    func testAlertOnUntrackedStockFiresInBackgroundAndInApp() {
        launchAndOnboard(picks: ["AAPL"])
        tab("Search")
        let field = searchField(placeholder: "Stocks, ETFs and crypto")
        field.tap()
        field.typeText("MSFT")
        let msft = app.buttons["search.result.us.MSFT"]
        XCTAssertTrue(msft.waitForExistence(timeout: 20), "MSFT from Search")
        msft.tap()
        XCTAssertTrue(app.descendants(matching: .any)["detail.screen"].waitForExistence(timeout: 10), "Stock page")
        let bell = app.buttons["detail.alert"]
        XCTAssertTrue(bell.waitForExistence(timeout: 10))
        bell.tap()
        XCTAssertTrue(app.textFields["alert.price"].waitForExistence(timeout: 5), "Alert sheet should open")
        app.buttons["alert.quick.5"].tap()
        app.buttons["Every time"].firstMatch.tap()
        app.buttons["alert.create"].tap()
        declineNotificationsIfAsked()
        XCTAssertFalse(app.buttons["detail.watchlist"].isSelected, "MSFT stays off the watchlist")

        // Background refresh alone (in-app checks off) prices MSFT and fires the alert.
        app.terminate()
        app.launchArguments = ["-UITestAlertPrices", "MSFT=100000", "-UITestBackgroundOnly"]
        app.launch()
        tab("Watchlist")
        XCTAssertFalse(app.buttons["watchlist.row.MSFT"].exists, "Not on the watchlist")
        let alerts = app.buttons["watchlist.alerts"]
        XCTAssertTrue(alerts.waitForExistence(timeout: 15))
        alerts.tap()
        let row = app.descendants(matching: .any)["alerts.row.MSFT"]
        require(row, timeout: 5, "The MSFT alert should be listed")
        let fired = expectation(for: NSPredicate(format: "label CONTAINS 'Triggered'"), evaluatedWith: row)
        if XCTWaiter.wait(for: [fired], timeout: 60) != .completed {
            attach("failure")
            XCTFail("The background check should fire an alert on an untracked stock: \(row.label)")
        }
        attach("alert-untracked-background-fired")

        // The normal in-app refresh also checks it: the price falls back and it re-arms.
        relaunch(alertPrices: "MSFT=1")
        let rearmed = expectation(for: NSPredicate(format: "NOT (label CONTAINS 'Triggered')"), evaluatedWith: row)
        if XCTWaiter.wait(for: [rearmed], timeout: 60) != .completed {
            attach("failure")
            XCTFail("The in-app check should re-arm it: \(row.label)")
        }
        attach("alert-untracked-inapp-rearmed")
    }

    /// The account service is down (its host stopped resolving): onboarding, Account and
    /// Refer a friend must each say so, offer a way on, and never spin or show a fake code.
    /// If the service comes back, the same screens offer sign-in instead — also fine.
    func testAccountAndReferralsSayWhenServiceIsDown() {
        launchAndOnboard(picks: ["AAPL"]) { [self] in
            let down = app.descendants(matching: .any)["account.unavailable"]
            let apple = app.buttons["onboarding.account.apple"]
            XCTAssertTrue(down.waitForExistence(timeout: 10) || apple.exists, "Account step settles on sign-in or 'unavailable'")
            if down.exists {
                XCTAssertEqual(app.buttons["onboarding.account.skip"].label, "Continue without an account")
                XCTAssertFalse(apple.exists, "No sign-in buttons while accounts can't work")
                attach("onboarding-account-unavailable")
            }
        }

        openSettings()
        let referrals = app.buttons["settings.referrals"]
        scrollTo(referrals, row: "settings.referrals")
        XCTAssertTrue(referrals.exists, "Refer a friend is listed for signed-out people too")
        referrals.tap()
        let unavailable = app.descendants(matching: .any)["referrals.unavailable"]
        let signIn = app.descendants(matching: .any)["referrals.signin"]
        XCTAssertTrue(unavailable.waitForExistence(timeout: 15) || signIn.exists, "Refer a friend settles; it never spins forever")
        XCTAssertFalse(app.descendants(matching: .any)["referrals.code"].exists, "No invite code without a working account")
        XCTAssertFalse(app.descendants(matching: .any)["referrals.loading"].exists)
        attach("referrals-unavailable")
        if unavailable.exists {
            XCTAssertTrue(unavailable.label.contains("Referrals are unavailable right now")
                          || app.staticTexts["Referrals are unavailable right now"].exists)
            app.buttons["Try again"].firstMatch.tap()
            let settledAgain = expectation(for: NSPredicate(format: "exists == true"), evaluatedWith: unavailable)
            XCTAssertEqual(XCTWaiter.wait(for: [settledAgain], timeout: 15), .completed, "Retry settles again")
        }
        goBack()

        let account = app.buttons["settings.account"]
        scrollTo(account, row: "settings.account")
        account.tap()
        let accountDown = app.descendants(matching: .any)["account.unavailable"]
        let appleButton = app.descendants(matching: .any)["account.apple"]
        XCTAssertTrue(accountDown.waitForExistence(timeout: 10) || appleButton.exists, "Account settles on sign-in or 'unavailable'")
        attach("account-unavailable")
        if accountDown.exists {
            XCTAssertFalse(appleButton.exists, "No Sign in with Apple while accounts can't work")
            let carryOn = app.buttons["Continue without an account"]
            XCTAssertTrue(carryOn.exists)
            carryOn.tap()
            XCTAssertTrue(app.buttons["settings.done"].waitForExistence(timeout: 5), "Continue closes the account sheet")
        } else {
            app.buttons["Done"].firstMatch.tap()
        }
        app.buttons["settings.done"].tap()
    }

    func testPrivateMarketsDisclosuresOpenFromSettings() {
        launchAndOnboard(picks: ["AAPL"])
        openSettings()

        open("settings.terms", expect: "the licensed provider manages the application")
        open("settings.privacyPolicy", expect: "saved AngelList statements stay on this iPhone")
    }

    func testSettingsRowsAllDoSomething() {
        launchAndOnboard(picks: ["AAPL"])
        openSettings()
        attach("settings")

        open("settings.dataSources", expect: "Alpaca Markets (IEX)")
        open("settings.privacy", expect: "Alpaca Markets")
        open("settings.terms", expect: "1. Acceptance of Terms")
        open("settings.privacyPolicy", expect: "Advertising & Tracking")
        open("settings.subscription", expect: "Restore purchases")

        let alerts = app.buttons["settings.priceAlerts"]
        scrollTo(alerts, row: "settings.priceAlerts")
        alerts.tap()
        XCTAssertTrue(app.descendants(matching: .any)["alerts.empty"].waitForExistence(timeout: 5), "Price alerts opens")
        app.buttons["alerts.done"].tap()

        let refresh = app.buttons["settings.refresh"]
        scrollTo(refresh, row: "settings.refresh")
        refresh.tap()
        // A full refresh can be slow when providers rate-limit; it must either finish with a
        // real timestamp or still be visibly refreshing (button disabled, spinner).
        let updated = expectation(for: NSPredicate(format: "label CONTAINS 'Updated'"), evaluatedWith: refresh)
        if XCTWaiter.wait(for: [updated], timeout: 60) != .completed {
            XCTAssertFalse(refresh.isEnabled, "Refresh should show progress or a last-updated time: \(refresh.label)")
        }

        let rate = app.buttons["settings.rate"]
        scrollTo(rate, row: "settings.rate")
        rate.tap()
        XCTAssertEqual(app.state, .runningForeground)
        app.buttons["settings.done"].tap()
    }

    // MARK: Screens in light and dark

    func testScreenshotsLightAndDark() {
        for mode in ["Light", "Dark"] {
            app = XCUIApplication()
            app.launchArguments = ["-UITestFreshInstall", "-app_theme_mode", mode]
            launchAndOnboard(picks: ["BHP", "CBA", "AAPL", "NVDA", "BTC"]) { [self] in
                if mode == "Dark" {
                    Thread.sleep(forTimeInterval: 1.5)
                    attach("onboarding-account")
                }
            }
            tab("Watchlist")
            XCTAssertTrue(app.buttons["watchlist.row.AAPL"].waitForExistence(timeout: 20))
            Thread.sleep(forTimeInterval: 6)
            attach("\(mode)-watchlist")
            app.buttons["watchlist.listMenu"].tap()
            Thread.sleep(forTimeInterval: 0.6)
            attach("\(mode)-watchlist-menu")
            // Choosing the current list closes the menu without changing anything.
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'My Watchlist ·'")).firstMatch.tap()
            Thread.sleep(forTimeInterval: 0.8)

            tab("Search")
            Thread.sleep(forTimeInterval: 1)
            attach("\(mode)-search-idle")
            let field = searchField(placeholder: "Stocks, ETFs and crypto")
            field.tap()
            field.typeText("BHP")
            _ = app.buttons["search.result.asx.BHP"].waitForExistence(timeout: 20)
            Thread.sleep(forTimeInterval: 3)
            attach("\(mode)-search-results")
            closeSearch()

            tab("News")
            _ = app.buttons["news.article"].firstMatch.waitForExistence(timeout: 30)
            Thread.sleep(forTimeInterval: 2)
            attach("\(mode)-news")
            // Company news often comes without pictures — those rows get the publisher tile.
            app.buttons["news.filter.watchlist"].tap()
            _ = app.buttons["news.article"].firstMatch.waitForExistence(timeout: 30)
            Thread.sleep(forTimeInterval: 3)
            attach("\(mode)-news-watchlist")
            app.swipeUp(velocity: .slow)
            Thread.sleep(forTimeInterval: 2)
            attach("\(mode)-news-watchlist-2")
            app.buttons["news.filter.all"].firstMatch.tap()

            tab("Watchlist")
            app.buttons["watchlist.alerts"].tap()
            Thread.sleep(forTimeInterval: 1)
            attach("\(mode)-alerts")
            app.buttons["alerts.new"].tap()
            let pick = app.buttons["alerts.pick.AAPL"]
            if pick.waitForExistence(timeout: 3) {
                pick.tap()
                if app.buttons["alert.quick.-5"].waitForExistence(timeout: 3) { app.buttons["alert.quick.-5"].tap() }
                app.buttons["Every time"].firstMatch.tap()
                attach("\(mode)-alert-create")
                app.buttons["alert.create"].tap()
                declineNotificationsIfAsked()
                Thread.sleep(forTimeInterval: 1)
                attach("\(mode)-alerts-list")
            }
            if app.buttons["alerts.done"].waitForExistence(timeout: 2) { app.buttons["alerts.done"].tap() }

            openSettings()
            attach("\(mode)-settings")
            app.swipeUp()
            attach("\(mode)-settings-2")
            let referrals = app.buttons["settings.referrals"]
            scrollTo(referrals, row: "settings.referrals")
            referrals.tap()
            _ = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN {'referrals.unavailable','referrals.signin','referrals.code'}"))
                .firstMatch.waitForExistence(timeout: 15)
            Thread.sleep(forTimeInterval: 0.8)
            attach("\(mode)-referrals")
            goBack()
            let account = app.buttons["settings.account"]
            scrollTo(account, row: "settings.account")
            account.tap()
            _ = app.descendants(matching: .any)["account.unavailable"].waitForExistence(timeout: 10)
            Thread.sleep(forTimeInterval: 0.8)
            attach("\(mode)-account")
            if app.buttons["Continue without an account"].exists {
                app.buttons["Continue without an account"].tap()
            } else {
                app.buttons["Done"].firstMatch.tap()
            }
            if app.buttons["settings.done"].waitForExistence(timeout: 5) { app.buttons["settings.done"].tap() }
            app.terminate()
        }
    }

    // MARK: Helpers

    private func launchAndOnboard(picks: [String], atAccountStep: (() -> Void)? = nil) {
        app.launch()
        let getStarted = app.buttons["onboarding.getStarted"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 20), "Welcome should show on first launch")
        getStarted.tap()
        waitForStep("What do you want to track?")
        for market in ["asx", "us", "crypto"] {
            let row = app.buttons["onboarding.market.\(market)"]
            if row.exists && !row.isSelected { row.tap() }
        }
        tapContinue()
        waitForStep("Pick a few to follow")
        for symbol in picks {
            let row = app.buttons["onboarding.pick.\(symbol)"]
            var tries = 0
            while !(row.exists && row.isHittable) && tries < 6 {
                app.swipeUp(velocity: .slow)
                tries += 1
            }
            if row.exists { row.tap() }
        }
        tapContinue()
        waitForStep("Add what you already own")
        tapContinue()
        waitForStep("Know when it moves")
        // If notifications were already allowed on this simulator, the step offers Continue instead.
        let notNow = app.buttons["onboarding.notifications.notNow"]
        if notNow.exists { notNow.tap() } else { tapContinue() }
        if app.staticTexts["Keep your portfolio private"].waitForExistence(timeout: 2) { app.buttons["Not now"].tap() }
        waitForStep("Save your setup")
        atAccountStep?()
        app.buttons["onboarding.account.skip"].tap()
        waitForStep("You're all set")
        app.buttons["onboarding.finish"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15), "Home should appear")
    }

    /// Relaunches with saved data (no fresh install), optionally feeding alert checks a price.
    private func relaunch(alertPrices: String) {
        app.terminate()
        app.launchArguments = ["-UITestAlertPrices", alertPrices]
        app.launch()
        tab("Watchlist")
        let bell = app.buttons["watchlist.alerts"]
        XCTAssertTrue(bell.waitForExistence(timeout: 15), "Watchlist after relaunch")
        bell.tap()
    }

    private func waitForStep(_ title: String) {
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10), "Expected step “\(title)”")
        let settled = expectation(for: NSPredicate(format: "count == 1"),
                                  evaluatedWith: app.staticTexts.matching(identifier: title))
        wait(for: [settled], timeout: 3)
        Thread.sleep(forTimeInterval: 0.4)
    }

    private func tapContinue() {
        app.buttons.matching(identifier: "onboarding.continue").firstMatch.tap()
    }

    private func tab(_ name: String) {
        XCTAssertTrue(app.open(name, timeout: 5), "\(name) tab")
    }

    private func openSettings() {
        tab("Home")
        let gear = app.buttons["Settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 5))
        gear.tap()
        XCTAssertTrue(app.buttons["settings.done"].waitForExistence(timeout: 5), "Settings should open")
    }

    private func setCurrency(_ code: String) {
        openSettings()
        let picker = app.buttons["settings.currency"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        if !picker.label.contains(code) {
            picker.tap()
            let option = app.buttons[code].firstMatch
            XCTAssertTrue(option.waitForExistence(timeout: 3))
            option.tap()
        }
        XCTAssertTrue(picker.label.contains(code), "Currency should be \(code)")
        app.buttons["settings.done"].tap()
    }

    private func open(_ identifier: String, expect text: String) {
        let row = app.buttons[identifier]
        scrollTo(row, row: identifier)
        XCTAssertTrue(row.exists, "\(identifier) should exist")
        row.tap()
        let target = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5), "\(identifier) should show “\(text)”")
        goBack()
        XCTAssertTrue(app.buttons["settings.done"].waitForExistence(timeout: 3), "Back on Settings after \(identifier)")
    }

    /// Pops one screen. Never taps "Done": mid-transition both navigation bars are in
    /// the tree, and `buttons.element(boundBy: 0)` could be the sheet's Done — which
    /// closed Settings and failed the next step.
    private func goBack() {
        let bar = app.navigationBars.buttons
        let back = bar["BackButton"].exists
            ? bar["BackButton"]
            : bar.matching(NSPredicate(format: "label != 'Done' AND identifier != 'settings.done'")).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 3), "A back button")
        back.tap()
        Thread.sleep(forTimeInterval: 0.6)
    }

    /// Settings rows, top to bottom. It's a lazy List: rows far off screen don't exist yet,
    /// so "not found" alone can't say which way to scroll.
    private static let settingsRows = [
        "settings.account", "settings.subscription", "settings.appearance", "settings.currency",
        "settings.market", "settings.priceAlerts", "settings.dailySummary", "settings.refresh",
        "settings.dataSources", "settings.privacy", "settings.referrals", "settings.rate",
        "settings.terms", "settings.privacyPolicy"
    ]

    /// Scrolls Settings *towards* a row, and never down past the top: blind swipes (up from
    /// the bottom, then down past the top) dismissed the Settings sheet, and the next tap
    /// landed on Home.
    private func scrollTo(_ element: XCUIElement, row id: String) {
        for _ in 0..<14 {
            if element.exists && element.isHittable { return }
            if rowIsAbove(element, id: id) {
                guard !app.buttons["settings.account"].isHittable else { return }   // already at the top
                app.swipeDown(velocity: .slow)
            } else {
                app.swipeUp(velocity: .slow)
            }
        }
    }

    private func rowIsAbove(_ element: XCUIElement, id: String) -> Bool {
        if element.exists { return element.frame.maxY < app.windows.firstMatch.frame.midY }
        guard let target = Self.settingsRows.firstIndex(of: id) else { return false }
        let loaded = Self.settingsRows.indices.filter { app.buttons[Self.settingsRows[$0]].exists }
        guard let firstLoaded = loaded.min() else { return false }
        return target < firstLoaded
    }

    private func replace(_ field: XCUIElement, with text: String) {
        field.tap()
        let clear = field.buttons["Clear text"]
        if clear.exists {
            clear.tap()
        } else if let value = field.value as? String, !value.isEmpty, value != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        field.typeText(text)
    }

    private func waitForLoadedPrice(_ row: XCUIElement) -> Bool {
        let loaded = expectation(for: NSPredicate(format: "label CONTAINS 'A$' OR label CONTAINS 'US$' OR label CONTAINS '$'"),
                                 evaluatedWith: row)
        return XCTWaiter.wait(for: [loaded], timeout: 20) == .completed
    }

    /// Declines the system prompt so the simulator stays in a state other tests expect.
    private func declineNotificationsIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let decline = springboard.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Don'")).firstMatch
        if decline.waitForExistence(timeout: 3) { decline.tap() }
    }

    /// Leaves an active search (iOS 26 shows a Close button; older versions Cancel).
    private func closeSearch() {
        for label in ["Close", "Cancel"] {
            let button = app.buttons[label].firstMatch
            if button.exists && button.isHittable {
                button.tap()
                Thread.sleep(forTimeInterval: 0.5)
                return
            }
        }
    }

    private func searchField(placeholder: String) -> XCUIElement {
        let match = app.searchFields.matching(NSPredicate(format: "placeholderValue == %@", placeholder)).firstMatch
        return match.waitForExistence(timeout: 5) ? match : app.searchFields.firstMatch
    }

    /// Waits for an element; on failure attaches a screenshot and the UI tree before failing.
    private func require(_ element: XCUIElement, timeout: TimeInterval, _ message: String,
                         file: StaticString = #filePath, line: UInt = #line) {
        if element.waitForExistence(timeout: timeout) { return }
        attach("failure")
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "failure-tree"
        tree.lifetime = .keepAlways
        add(tree)
        XCTFail(message, file: file, line: line)
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
