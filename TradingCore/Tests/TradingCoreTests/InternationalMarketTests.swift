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
        XCTAssertEqual(PaperBroker.rules(for: .listed("D05", on: .sgx)).minQuantity, 1)          // price-tiered since Oct 2026
        XCTAssertEqual(PaperBroker.rules(for: .listed("1306", on: .tse, etf: true)).quantityIncrement, 1)   // funds set their own units
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

final class TransactionTaxTests: XCTestCase {
    let config = PaperBrokerConfig()

    func testDefiniteTaxesByVenueAndSide() {
        let shell = Instrument.listed("SHEL", on: .lse)
        XCTAssertEqual(PaperBroker.fee(for: shell, side: .buy, notional: 1_000, isFirstFillOfOrder: true, config: config), 5)
        XCTAssertEqual(PaperBroker.fee(for: shell, side: .sell, notional: 1_000, isFirstFillOfOrder: true, config: config), 0)
        XCTAssertEqual(PaperBroker.fee(for: .listed("ISF", on: .lse, etf: true), side: .buy, notional: 1_000, isFirstFillOfOrder: true, config: config), 0)
        XCTAssertEqual(PaperBroker.tax(for: .listed("MC", on: .euronextParis), side: .buy, notional: 10_000), 40)
        XCTAssertEqual(PaperBroker.tax(for: .listed("ASML", on: .euronextAmsterdam), side: .buy, notional: 10_000), 0)
        // Hong Kong: 0.1% each side, rounded up to the next dollar.
        XCTAssertEqual(PaperBroker.tax(for: .listed("0700", on: .hkex), side: .buy, notional: 39_040), 40)
        XCTAssertEqual(PaperBroker.tax(for: .listed("0700", on: .hkex), side: .sell, notional: 39_000), 39)
        XCTAssertEqual(PaperBroker.tax(for: .listed("005930", on: .krx), side: .sell, notional: 1_000_000), 2_000)
        XCTAssertEqual(PaperBroker.tax(for: .listed("005930", on: .krx), side: .buy, notional: 1_000_000), 0)
        XCTAssertEqual(PaperBroker.tax(for: .listed("TCS", on: .nse), side: .buy, notional: 100_000), 100)
        // US, ASX and crypto are unchanged: no tax.
        XCTAssertEqual(PaperBroker.tax(for: Fx.aapl, side: .buy, notional: 1_000), 0)
        XCTAssertEqual(PaperBroker.tax(for: Fx.bhp, side: .buy, notional: 1_000), 0)
        XCTAssertNotNil(PaperBroker.taxNote(for: shell, side: .buy))
        XCTAssertNil(PaperBroker.taxNote(for: shell, side: .sell))
    }

    func testStampDutyReachesTheLedgerAndBuyingPower() throws {
        let shell = Instrument.listed("SHEL", name: "Shell", on: .lse)
        let londonNow = Fx.date("2026-11-10T11:00:00Z")
        var engine = Fx.engine()
        let ledger = try engine.createPaperPortfolio(name: "UK", startingCash: 1_000, currency: "GBP", now: londonNow)
        engine.ingest(quotes: [Fx.quote(shell, last: 25, spreadBps: nil, time: londonNow)], now: londonNow)
        // 40 shares cost about £1,000.20 plus £5.00 duty: more than the cash.
        XCTAssertEqual(engine.submit(OrderRequest(ledgerID: ledger.id, instrument: shell, side: .buy, quantity: 40), now: londonNow).risk.failures.map(\.id),
                       [.buyingPower])
        let result = engine.submit(OrderRequest(ledgerID: ledger.id, instrument: shell, side: .buy, quantity: 39), now: londonNow)
        XCTAssertEqual(result.order?.status, .filled)
        let fill = try XCTUnwrap(engine.state.fills.first)
        XCTAssertEqual(fill.fee, Rounding.money(fill.gross * 0.005))
        XCTAssertEqual(engine.state.ledger(ledger.id)?.cash, Rounding.money(1_000 - fill.gross - fill.fee))
    }
}

/// Issues found while porting the engine to the server.
final class PortingFindingsTests: XCTestCase {
    func testARejectedOrdersKeyCannotBeReused() throws {
        var engine = Fx.engine()
        let ledger = try engine.createPaperPortfolio(name: "P", startingCash: 1_000, now: Fx.now)
        engine.ingest(quotes: [Fx.quote(Fx.aapl, last: 100)], now: Fx.now)
        let first = engine.submit(OrderRequest(clientOrderID: "k1", ledgerID: ledger.id, instrument: Fx.aapl, side: .buy, quantity: 50), now: Fx.now)
        XCTAssertEqual(first.order?.status, .rejected)               // not enough cash
        let retry = engine.submit(OrderRequest(clientOrderID: "k1", ledgerID: ledger.id, instrument: Fx.aapl, side: .buy, quantity: 1), now: Fx.now)
        XCTAssertFalse(retry.isAccepted)
        XCTAssertEqual(retry.risk.failures.map(\.id), [.duplicate])
        XCTAssertEqual(engine.state.orders.count, 1)
    }

    func testNoNegativeZeroInRiskText() {
        XCTAssertEqual(RiskEngine.percentText(max(0, -0.0)), "0.0%")
    }

    func testAnOversellIsCutToTheHolding() {
        var ledger = Ledger(name: "L", kind: .manualPaper, startingCash: 1_000, createdAt: Fx.now)
        ledger.apply(Fill(orderID: UUID(), ledgerID: ledger.id, instrument: Fx.aapl, side: .buy, quantity: 2, price: 100,
                          fee: 0, time: Fx.now, source: .manual, mode: .paper))
        let sold = ledger.apply(Fill(orderID: UUID(), ledgerID: ledger.id, instrument: Fx.aapl, side: .sell, quantity: 5, price: 110,
                                     fee: 0, time: Fx.now, source: .manual, mode: .paper))
        XCTAssertEqual(sold.quantity, 2)
        XCTAssertEqual(ledger.cash, 1_020)                           // 800 + 2 × 110, not 5 × 110
        XCTAssertEqual(sold.realizedPnL, 20)
        XCTAssertNil(ledger.position(Fx.aapl.id))
    }

    func testRebalanceErrorsComeInAFixedOrder() {
        var spec = AgentTemplates.etfRebalancing(UniverseCatalog.balancedETFs)
        spec.rebalance?.targets = ["us:ZZZ": 50, "us:AAA": 50, "us:MMM": 150]
        let first = StrategyValidator.validate(spec).map(\.message)
        for _ in 0..<5 { XCTAssertEqual(StrategyValidator.validate(spec).map(\.message), first) }
    }
}
