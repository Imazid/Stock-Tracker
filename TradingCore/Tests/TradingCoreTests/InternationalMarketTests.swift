import XCTest
@testable import TradingCore

/// UK, European and Asian listings: their hours, currencies, lots and how they flow
/// through agents and orders.
final class InternationalMarketTests: XCTestCase {
    let calendar = MarketCalendar.standard

    func testVenueBasics() {
        XCTAssertEqual(Venue.lse.currency, "GBP")
        XCTAssertEqual(Venue.xetra.currency, "EUR")
        XCTAssertEqual(Venue.tse.currency, "JPY")
        XCTAssertEqual(Venue.hkex.currency, "HKD")
        XCTAssertEqual(Instrument.listed("VOD", on: .lse).yahooSymbol, "VOD.L")
        XCTAssertEqual(Instrument.listed("0700", on: .hkex).yahooSymbol, "0700.HK")
        XCTAssertEqual(Venue.parse(yahooSymbol: "7203.T")?.venue, .tse)
        XCTAssertEqual(Venue.parse(yahooSymbol: "7203.T")?.symbol, "7203")
        XCTAssertEqual(Venue.parse(yahooSymbol: "sap.de")?.venue, .xetra)
        XCTAssertNil(Venue.parse(yahooSymbol: "AAPL"))
        XCTAssertEqual(Set(Venue.allCases.compactMap(\.yahooSuffix)).count, Venue.allCases.count - 2)   // every suffix unique
    }

    func testEuropeanSessionsFollowLocalTime() {
        // Tuesday 10 November 2026 (winter time): London opens 08:00 GMT, Frankfurt 09:00 CET = 08:00 UTC.
        XCTAssertTrue(calendar.isOpen(.lse, at: Fx.date("2026-11-10T08:01:00Z")))
        XCTAssertFalse(calendar.isOpen(.lse, at: Fx.date("2026-11-10T07:59:00Z")))
        XCTAssertTrue(calendar.isOpen(.xetra, at: Fx.date("2026-11-10T08:01:00Z")))
        XCTAssertFalse(calendar.isOpen(.xetra, at: Fx.date("2026-11-10T16:40:00Z")))   // 17:40 CET
        // In July London is on BST: 08:00 local is 07:00 UTC.
        XCTAssertTrue(calendar.isOpen(.lse, at: Fx.date("2026-07-14T07:01:00Z")))
        XCTAssertFalse(calendar.isOpen(.six, at: Fx.date("2026-11-14T10:00:00Z")))     // Saturday
    }

    func testAsianLunchBreaks() {
        // Tokyo: 09:00–11:30 and 12:30–15:30 JST (UTC+9).
        XCTAssertTrue(calendar.isOpen(.tse, at: Fx.date("2026-11-10T01:00:00Z")))      // 10:00
        XCTAssertFalse(calendar.isOpen(.tse, at: Fx.date("2026-11-10T03:00:00Z")))     // 12:00, lunch
        XCTAssertTrue(calendar.isOpen(.tse, at: Fx.date("2026-11-10T04:00:00Z")))      // 13:00
        XCTAssertFalse(calendar.isOpen(.tse, at: Fx.date("2026-11-10T06:40:00Z")))     // 15:40
        XCTAssertTrue(calendar.hasLunchBreak(.tse))
        XCTAssertFalse(calendar.hasLunchBreak(.lse))
        // During lunch the next open is the afternoon session, not tomorrow.
        XCTAssertEqual(calendar.nextOpen(.tse, after: Fx.date("2026-11-10T03:00:00Z")), Fx.date("2026-11-10T03:30:00Z"))
        // A day order placed at lunch lasts until the afternoon close.
        XCTAssertEqual(calendar.nextClose(.tse, after: Fx.date("2026-11-10T03:00:00Z")), Fx.date("2026-11-10T06:30:00Z"))
        // Hong Kong lunch 12:00–13:00 HKT (UTC+8).
        XCTAssertFalse(calendar.isOpen(.hkex, at: Fx.date("2026-11-10T04:30:00Z")))
        XCTAssertTrue(calendar.isOpen(.hkex, at: Fx.date("2026-11-10T05:30:00Z")))
        // The daily bar is complete only after the afternoon close.
        let bar = Bar(time: Fx.date("2026-11-10T00:00:00Z"), open: 1, high: 1, low: 1, close: 1, volume: 1)
        XCTAssertFalse(calendar.isBarComplete(bar, timeframe: .day, venue: .tse, now: Fx.date("2026-11-10T03:00:00Z")))
        XCTAssertTrue(calendar.isBarComplete(bar, timeframe: .day, venue: .tse, now: Fx.date("2026-11-10T06:31:00Z")))
    }

    func testLotsAndWholeShares() {
        XCTAssertEqual(PaperBroker.rules(for: .listed("7203", on: .tse)).quantityIncrement, 100)
        XCTAssertEqual(PaperBroker.rules(for: .listed("D05", on: .sgx)).minQuantity, 100)
        XCTAssertFalse(PaperBroker.rules(for: .listed("VOD", on: .lse)).fractionable)
        XCTAssertTrue(PaperBroker.capabilities.venues.contains(.nse))
    }

    func testCurrencyFacts() {
        XCTAssertEqual(NumberText.money(1234.5, currency: "GBP"), "£1234.50")
        XCTAssertEqual(NumberText.money(1234.5, currency: "JPY"), "¥1235")
        XCTAssertEqual(NumberText.money(1000, currency: "USD"), "$1000.00")          // unchanged
        XCTAssertEqual(Currencies.budgetRange("JPY"), 10_000...1_000_000_000)
        XCTAssertEqual(Currencies.liquidityFloor("USD"), 1_000_000)
        XCTAssertEqual(Currencies.liquidityFloor("JPY"), 200_000_000)               // ~US$1M, rounded
        XCTAssertEqual(Ledger.dayKey(for: Fx.date("2026-11-10T16:00:00Z"), currency: "JPY"), "2026-11-11")   // 01:00 in Tokyo
        XCTAssertEqual(Ledger.dayKey(for: Fx.date("2026-11-10T16:00:00Z"), currency: "GBP"), "2026-11-10")
    }

    func testTokyoOrdersRespectTheHundredShareUnit() throws {
        let toyota = Instrument.listed("7203", name: "Toyota Motor", on: .tse)
        let tokyoNow = Fx.date("2026-11-10T01:00:00Z")      // 10:00 JST
        var engine = Fx.engine()
        let ledger = try engine.createPaperPortfolio(name: "Japan", startingCash: 5_000_000, currency: "JPY", now: tokyoNow)
        engine.ingest(quotes: [Fx.quote(toyota, last: 2_800, time: tokyoNow)],
                      stats: [toyota.id: InstrumentStats(averageDollarVolume: 1e11, dailyVolatilityPct: 1.5)], now: tokyoNow)
        let odd = engine.submit(OrderRequest(ledgerID: ledger.id, instrument: toyota, side: .buy, quantity: 150), now: tokyoNow)
        XCTAssertEqual(odd.risk.failures.map(\.id), [.exchangeRules])
        XCTAssertTrue(odd.risk.check(.exchangeRules)?.detail.contains("lots of 100") == true)
        // An amount is rounded down to whole lots.
        let byAmount = engine.submit(OrderRequest(ledgerID: ledger.id, instrument: toyota, side: .buy, notional: 700_000), now: tokyoNow)
        XCTAssertEqual(byAmount.order?.status, .filled)
        XCTAssertEqual(byAmount.order?.filledQuantity, 200)
        XCTAssertEqual(engine.state.ledger(ledger.id)?.position(toyota.id)?.quantity, 200)
        // Lunch: the order waits for the afternoon session.
        let lunch = Fx.date("2026-11-10T03:00:00Z")
        engine.ingest(quotes: [Fx.quote(toyota, last: 2_810, time: lunch)], now: lunch)
        let waiting = engine.submit(OrderRequest(ledgerID: ledger.id, instrument: toyota, side: .buy, quantity: 100), now: lunch)
        XCTAssertEqual(waiting.order?.status, .accepted)
        XCTAssertEqual(waiting.order?.statusNote, "Waiting for the market to open.")
        let afternoon = Fx.date("2026-11-10T03:31:00Z")
        engine.ingest(quotes: [Fx.quote(toyota, last: 2_815, time: afternoon)], now: afternoon)
        XCTAssertEqual(engine.state.ledger(ledger.id)?.position(toyota.id)?.quantity, 300)
    }

    func testAPoundPortfolioCannotBuyAYenShare() throws {
        var engine = Fx.engine()
        let pounds = try engine.createPaperPortfolio(name: "UK", startingCash: 10_000, currency: "GBP", now: Fx.now)
        let sony = Instrument.listed("6758", on: .tse)
        engine.ingest(quotes: [Fx.quote(sony, last: 3_500)], now: Fx.now)
        let result = engine.submit(OrderRequest(ledgerID: pounds.id, instrument: sony, side: .buy, quantity: 100), now: Fx.now)
        XCTAssertTrue(result.risk.failures.map(\.id).contains(.currency))
        XCTAssertThrowsError(try engine.createPaperPortfolio(name: "Bad", startingCash: 10_000, currency: "XYZ", now: Fx.now))
        XCTAssertThrowsError(try engine.createPaperPortfolio(name: "Tiny", startingCash: 500, currency: "JPY", now: Fx.now))
    }

    func testAUKAgentRunsEndToEndInPounds() throws {
        var engine = Fx.engine()
        let shell = Instrument.listed("SHEL", name: "Shell", on: .lse)
        let londonNow = Fx.date("2026-11-10T11:00:00Z")
        var draft = AgentDraft(name: "UK trend", mode: .paper, spec: Fx.aboveAverageSpec([shell]), budget: 10_000, maxPositionPct: 10)
        draft.reviewEachPaperTrade = false
        let agent = try engine.createAgent(draft, now: londonNow)
        XCTAssertEqual(engine.state.ledger(agent.ledgerID)?.currency, "GBP")
        XCTAssertEqual(agent.riskPolicy.minAverageDollarVolume, Currencies.liquidityFloor("GBP"))

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London")!
        var days: [Date] = []
        var day = cal.startOfDay(for: londonNow)
        while days.count < 60 {
            day = cal.date(byAdding: .day, value: -1, to: day)!
            if calendar.isTradingDay(.lse, day) { days.append(day.addingTimeInterval(8 * 3_600)) }   // Yahoo stamps the open
        }
        let closes = Fx.risingCloses().map { $0 * 0.27 }
        var snapshot = MarketSnapshot()
        snapshot.series[shell.id] = Fx.series(shell, closes: closes, days: days.reversed())
        snapshot.quotes[shell.id] = Fx.quote(shell, last: closes.last!, time: londonNow)
        let run = try XCTUnwrap(engine.runAgent(id: agent.id, snapshot: snapshot, trigger: .manual, now: londonNow))
        XCTAssertEqual(run.orderIDs.count, 1, run.steps.map { "\($0.title): \($0.detail)" }.joined(separator: "\n"))
        let fill = try XCTUnwrap(engine.state.fills.first)
        XCTAssertEqual(fill.quantity, fill.quantity.rounded())          // whole shares
        XCTAssertEqual(fill.instrument.currency, "GBP")
        XCTAssertLessThanOrEqual(fill.gross, 1_000)                     // 10% of £10,000
        XCTAssertTrue(engine.state.audit.events.last?.summary.contains("£") == true)
    }

    func testRequestsForInternationalMarkets() {
        let uk = StrategyParser.parse("Momentum agent on UK stocks with £20,000")
        XCTAssertEqual(Set(uk.draft.spec.universe.map(\.venue)), [.lse])
        XCTAssertEqual(uk.draft.currency, "GBP")
        XCTAssertTrue(uk.assumptions.contains { $0.contains("held in GBP") })

        let japan = StrategyParser.parse("Trend following on Japanese stocks")
        XCTAssertEqual(Set(japan.draft.spec.universe.map(\.venue)), [.tse])
        XCTAssertEqual(japan.draft.budget, Currencies.defaultBudget("JPY"))
        XCTAssertTrue(StrategyValidator.isValid(japan.draft.spec))

        let named = StrategyParser.parse("Trade Toyota and Sony on breakouts")
        XCTAssertEqual(named.draft.spec.universe.map(\.yahooSymbol), ["6758.T", "7203.T"])

        let europe = StrategyParser.parse("Mean reversion across European blue chips")
        XCTAssertEqual(Set(europe.draft.spec.universe.map(\.currency)), ["EUR"])

        // Every international template draft is valid and starts in its own currency.
        for list in [UniverseCatalog.ukBlueChips, UniverseCatalog.swissBlueChips, UniverseCatalog.hongKongBlueChips,
                     UniverseCatalog.koreaBlueChips, UniverseCatalog.indiaBlueChips, UniverseCatalog.singaporeBlueChips] {
            let draft = AgentTemplates.all[0].draft(universe: list)
            XCTAssertTrue(StrategyValidator.isValid(draft.spec))
            XCTAssertTrue(Currencies.budgetRange(draft.currency).contains(draft.budget), draft.currency)
        }
    }
}
