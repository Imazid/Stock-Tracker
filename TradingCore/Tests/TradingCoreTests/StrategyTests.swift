import XCTest
@testable import TradingCore

final class StrategyValidatorTests: XCTestCase {
    func testEveryTemplateIsValid() {
        for template in AgentTemplates.all {
            let spec = template.build(template.defaultUniverse)
            let errors = StrategyValidator.validate(spec).filter { $0.severity == .error }
            XCTAssertTrue(errors.isEmpty, "\(template.id): \(errors.map(\.message))")
        }
    }

    func testRejectsStrategiesThatCannotWork() {
        func errors(_ spec: StrategySpec) -> [String] {
            StrategyValidator.validate(spec).filter { $0.severity == .error }.map(\.message)
        }
        var spec = Fx.aboveAverageSpec([])
        XCTAssertTrue(errors(spec).contains { $0.contains("at least one asset") })

        spec = Fx.aboveAverageSpec([Fx.aapl, Fx.bhp])
        XCTAssertTrue(errors(spec).contains { $0.contains("one currency") })

        spec = Fx.aboveAverageSpec([Fx.aapl, Fx.aapl])
        XCTAssertTrue(errors(spec).contains { $0.contains("listed twice") })

        spec = Fx.aboveAverageSpec([Fx.aapl], stopLossPct: nil)
        spec.exit = nil
        XCTAssertTrue(errors(spec).contains { $0.contains("never sell") })

        spec = Fx.aboveAverageSpec([Fx.aapl])
        spec.entry = .above(.close, .sma(0))
        XCTAssertTrue(errors(spec).contains { $0.contains("between 1 and") })

        spec.entry = .above(.macdLine(fast: 26, slow: 12, signal: 9), .constant(0))
        XCTAssertTrue(errors(spec).contains { $0.contains("fast period must be shorter") })

        spec.entry = .above(.constant(1), .constant(2))
        XCTAssertTrue(errors(spec).contains { $0.contains("two fixed numbers") })

        spec.entry = .all([])
        XCTAssertTrue(errors(spec).contains { $0.contains("no rules in it") })

        var rebalance = AgentTemplates.etfRebalancing(UniverseCatalog.balancedETFs)
        rebalance.rebalance?.targets["us:VTI"] = 90
        XCTAssertTrue(errors(rebalance).contains { $0.contains("can't exceed 100%") })
        rebalance.rebalance?.targets = ["us:NOPE": 50]
        XCTAssertTrue(errors(rebalance).contains { $0.contains("isn't in the asset list") })
    }

    func testStrategyJSONRoundTrips() throws {
        let spec = AgentTemplates.breakout(UniverseCatalog.technology)
        let data = try JSONEncoder().encode(spec)
        XCTAssertEqual(try JSONDecoder().decode(StrategySpec.self, from: data), spec)
    }

    func testInstrumentDecodesFromJustASymbol() throws {
        let decoded = try JSONDecoder().decode([Instrument].self, from: Data(#"[{"symbol":"btc"},{"symbol":"nvda"},{"symbol":"ZZZ","assetClass":"etf"}]"#.utf8))
        XCTAssertEqual(decoded[0], Fx.btc)
        XCTAssertEqual(decoded[1].venue, .us)
        XCTAssertEqual(decoded[1].name, "NVIDIA")
        XCTAssertEqual(decoded[2].assetClass, .etf)
        XCTAssertEqual(decoded[2].currency, "USD")
    }
}

final class StrategyEvaluatorTests: XCTestCase {
    private func crossoverSpec() -> StrategySpec {
        StrategySpec(kind: .rules, title: "Cross", summary: "", universe: [Fx.aapl],
                     entry: .crossesAbove(.sma(5), .sma(20)), exit: .crossesBelow(.sma(5), .sma(20)),
                     protections: Protections(stopLossPct: 8), reentryCooldownBars: 0)
    }

    func testCrossoverBuysOnlyOnTheBarOfTheCross() {
        let closes = [Double](repeating: 100, count: 30) + [102, 104, 106]
        let prepared = PreparedSeries(bars: Fx.dailyBars(closes: closes))
        let spec = crossoverSpec()
        XCTAssertEqual(StrategyEvaluator.decide(spec: spec, prepared: prepared, index: 29, position: nil).action, .hold)
        let cross = StrategyEvaluator.decide(spec: spec, prepared: prepared, index: 30, position: nil)
        XCTAssertEqual(cross.action, .buy)
        XCTAssertEqual(cross.evidence.first?.passed, true)
        XCTAssertEqual(cross.barTime, prepared.bars[30].time)
        // The averages are still apart on the next bar, but the cross has already happened.
        XCTAssertEqual(StrategyEvaluator.decide(spec: spec, prepared: prepared, index: 31, position: nil).action, .hold)
    }

    func testNotEnoughHistoryHolds() {
        let prepared = PreparedSeries(bars: Fx.dailyBars(closes: [Double](repeating: 100, count: 10)))
        let decision = StrategyEvaluator.decide(spec: crossoverSpec(), prepared: prepared, index: 9, position: nil)
        XCTAssertEqual(decision.action, .hold)
        XCTAssertTrue(decision.headline.contains("Not enough history"))
    }

    func testDecisionAtABarIgnoresLaterBars() {
        let closes = (0..<90).map { 100 + sin(Double($0) / 6) * 12 }
        let bars = Fx.dailyBars(closes: closes)
        let spec = Fx.aboveAverageSpec([Fx.aapl])
        let full = PreparedSeries(bars: bars)
        for index in stride(from: 25, to: 85, by: 7) {
            let truncated = PreparedSeries(bars: Array(bars.prefix(index + 1)))
            let a = StrategyEvaluator.decide(spec: spec, prepared: full, index: index, position: nil)
            let b = StrategyEvaluator.decide(spec: spec, prepared: truncated, index: index, position: nil)
            XCTAssertEqual(a.action, b.action)
            XCTAssertEqual(a.evidence, b.evidence)
        }
    }

    func testStopLossTakeProfitAndTrailingStop() {
        var closes = [Double](repeating: 100, count: 30)
        closes += [100, 110, 120, 107]
        let bars = Fx.dailyBars(closes: closes)
        let prepared = PreparedSeries(bars: bars)
        let position = PositionContext(quantity: 10, averageCost: 100, openedAt: bars[30].time)

        var spec = Fx.aboveAverageSpec([Fx.aapl], stopLossPct: nil)
        spec.exit = nil
        spec.protections = Protections(trailingStopPct: 10)
        // Highest close since entry is 120; 107 is more than 10% below it.
        let trailing = StrategyEvaluator.decide(spec: spec, prepared: prepared, index: 33, position: position)
        XCTAssertEqual(trailing.action, .sell)
        XCTAssertEqual(trailing.exitReason, .trailingStop)
        // One bar earlier (close 120) nothing triggers.
        XCTAssertEqual(StrategyEvaluator.decide(spec: spec, prepared: prepared, index: 32, position: position).action, .hold)

        spec.protections = Protections(takeProfitPct: 15)
        XCTAssertEqual(StrategyEvaluator.decide(spec: spec, prepared: prepared, index: 32, position: position).exitReason, .takeProfit)
        XCTAssertEqual(StrategyEvaluator.decide(spec: spec, prepared: prepared, index: 31, position: position).action, .hold)

        spec.protections = Protections(stopLossPct: 8)
        let costly = PositionContext(quantity: 10, averageCost: 118, openedAt: bars[32].time)
        let stop = StrategyEvaluator.decide(spec: spec, prepared: prepared, index: 33, position: costly)
        XCTAssertEqual(stop.exitReason, .stopLoss)        // 107 is 9.3% below 118
        XCTAssertEqual(StrategyEvaluator.decide(spec: spec, prepared: prepared, index: 33, position: position).action, .hold)
    }

    func testTimeLimitCountsBarsSinceEntry() {
        let bars = Fx.dailyBars(closes: [Double](repeating: 100, count: 40))
        var spec = Fx.aboveAverageSpec([Fx.aapl], stopLossPct: nil)
        spec.exit = nil
        spec.protections = Protections(maxHoldingBars: 5)
        // Bought during the session of bar 30 (its bar starts before the fill).
        let position = PositionContext(quantity: 1, averageCost: 100, openedAt: bars[30].time.addingTimeInterval(36_000))
        let prepared = PreparedSeries(bars: bars)
        XCTAssertEqual(StrategyEvaluator.decide(spec: spec, prepared: prepared, index: 34, position: position).action, .hold)
        XCTAssertEqual(StrategyEvaluator.decide(spec: spec, prepared: prepared, index: 35, position: position).exitReason, .timeLimit)
    }

    func testReentryWaitsOutTheCooldown() {
        let closes = [Double](repeating: 100, count: 30) + [110, 111, 112, 113]
        let bars = Fx.dailyBars(closes: closes)
        var spec = Fx.aboveAverageSpec([Fx.aapl])
        spec.reentryCooldownBars = 3
        let prepared = PreparedSeries(bars: bars)
        let exit = bars[31].time
        XCTAssertEqual(StrategyEvaluator.decide(spec: spec, prepared: prepared, index: 32, position: nil, lastExitTime: exit).action, .hold)
        XCTAssertEqual(StrategyEvaluator.decide(spec: spec, prepared: prepared, index: 33, position: nil, lastExitTime: exit).action, .hold)
        XCTAssertEqual(StrategyEvaluator.decide(spec: spec, prepared: prepared, index: 33, position: nil, lastExitTime: bars[30].time).action, .buy)
    }

    func testScheduledBuysFollowTheInterval() {
        let bars = Fx.dailyBars(closes: [Double](repeating: 50, count: 12))
        let spec = AgentTemplates.dollarCostAveraging([Fx.spy], amountPerBuy: 100, intervalBars: 5)
        XCTAssertEqual(StrategyEvaluator.decideDCA(spec: spec, bars: bars, lastBuyTime: nil)?.action, .buy)
        XCTAssertEqual(StrategyEvaluator.decideDCA(spec: spec, bars: bars, lastBuyTime: bars[8].time)?.action, .hold)   // 3 bars ago
        XCTAssertEqual(StrategyEvaluator.decideDCA(spec: spec, bars: bars, lastBuyTime: bars[6].time)?.action, .buy)    // 5 bars ago
    }

    func testRebalanceSellsWinnersBeforeBuyingLaggards() {
        let config = RebalanceConfig(targets: ["us:A": 60, "us:B": 40], driftThresholdPct: 5)
        let trades = StrategyEvaluator.rebalanceTrades(config: config, values: ["us:A": 7_000, "us:B": 3_000], equity: 10_000)
        XCTAssertEqual(trades.map(\.side), [.sell, .buy])
        XCTAssertEqual(trades.map(\.instrumentID), ["us:A", "us:B"])
        XCTAssertEqual(trades.map(\.notional), [1_000, 1_000])
        let none = StrategyEvaluator.rebalanceTrades(config: RebalanceConfig(targets: ["us:A": 60, "us:B": 40], driftThresholdPct: 15),
                                                     values: ["us:A": 7_000, "us:B": 3_000], equity: 10_000)
        XCTAssertTrue(none.isEmpty)
        // Starting from cash, everything is a buy.
        let initial = StrategyEvaluator.rebalanceTrades(config: config, values: [:], equity: 10_000)
        XCTAssertEqual(initial.map(\.notional), [6_000, 4_000])
        XCTAssertTrue(initial.allSatisfy { $0.side == .buy })
    }

    func testResearchFactsAreObservationsOnly() {
        let facts = StrategyEvaluator.researchFacts(bars: Fx.dailyBars(closes: Fx.risingCloses(count: 260)))
        XCTAssertTrue(facts.contains { $0.label == "Last close" })
        XCTAssertTrue(facts.contains { $0.label == "RSI (14)" })
        XCTAssertTrue(facts.contains { $0.label.contains("200-day average") })
        XCTAssertTrue(facts.allSatisfy { $0.passed == nil })
    }
}

final class StrategyParserTests: XCTestCase {
    func testTheExampleRequestBecomesAValidatedDraft() {
        let parsed = StrategyParser.parse("Create an agent that monitors technology stocks, identifies momentum opportunities and proposes trades based on moving-average crossovers. Give it a $5,000 paper portfolio and limit each position to 10%.")
        let draft = parsed.draft
        XCTAssertEqual(draft.name, "Momentum Agent")
        XCTAssertEqual(draft.mode, .paper)
        XCTAssertEqual(draft.budget, 5_000)
        XCTAssertEqual(draft.maxPositionPct, 10)
        XCTAssertEqual(draft.resolvedPolicy.maxPositionPct, 10)
        XCTAssertEqual(draft.resolvedPolicy.maxOrderNotional, 500)
        XCTAssertEqual(draft.spec.universe.map(\.symbol), UniverseCatalog.technology.map(\.symbol))
        XCTAssertEqual(draft.spec.entry, .crossesAbove(.sma(20), .sma(50)))
        XCTAssertEqual(draft.spec.exit, .crossesBelow(.sma(20), .sma(50)))
        XCTAssertTrue(StrategyValidator.isValid(draft.spec))
        XCTAssertTrue(parsed.understood.contains("Budget: $5,000"))
        XCTAssertTrue(parsed.understood.contains("Position limit: 10% each"))
        XCTAssertTrue(parsed.assumptions.contains { $0.contains("20-day and 50-day") })
    }

    func testCryptoRequestAndExplicitPeriods() {
        let crypto = StrategyParser.parse("Create a paper-trading strategy for BTC and ETH")
        XCTAssertEqual(crypto.draft.spec.universe, [Fx.btc, .crypto("ETH", name: "Ethereum")])
        XCTAssertEqual(crypto.draft.mode, .paper)
        XCTAssertEqual(crypto.draft.resolvedPolicy.maxSpreadBps, 100)        // crypto limits

        let periods = StrategyParser.parse("Trade NVDA and AMD when the 10-day EMA crosses the 30-day EMA")
        XCTAssertEqual(periods.draft.spec.entry, .crossesAbove(.ema(10), .ema(30)))
        XCTAssertEqual(periods.draft.spec.universe.map(\.symbol), ["NVDA", "AMD"])
    }

    func testPercentagesAreReadFromEitherSideOfTheirName() {
        let a = StrategyParser.parse("Momentum agent on NVDA with an 8% stop loss and 12% trailing stop, ask me before each trade")
        XCTAssertEqual(a.draft.spec.protections.stopLossPct, 8)
        XCTAssertEqual(a.draft.spec.protections.trailingStopPct, 12)
        XCTAssertTrue(a.draft.reviewEachPaperTrade)

        let b = StrategyParser.parse("Trend agent for SPY, stop loss of 6% and trailing stop of 9%, max drawdown of 20%, 25% per position")
        XCTAssertEqual(b.draft.spec.protections.stopLossPct, 6)
        XCTAssertEqual(b.draft.spec.protections.trailingStopPct, 9)
        XCTAssertEqual(b.draft.resolvedPolicy.maxDrawdownPct, 20)
        XCTAssertEqual(b.draft.maxPositionPct, 25)

        let c = StrategyParser.parse("Breakout agent on AAPL with an 8% stop loss and 10% per position")
        XCTAssertEqual(c.draft.spec.protections.stopLossPct, 8)
        XCTAssertEqual(c.draft.maxPositionPct, 10)
    }

    func testScheduledBuysSeparateTheBudgetFromTheAmount() {
        let parsed = StrategyParser.parse("Buy $100 of SPY every week with a $5,000 budget")
        XCTAssertEqual(parsed.draft.spec.kind, .dca)
        XCTAssertEqual(parsed.draft.spec.dca, DCAConfig(amountPerBuy: 100, intervalBars: 5))
        XCTAssertEqual(parsed.draft.budget, 5_000)
        XCTAssertEqual(parsed.draft.spec.universe.map(\.symbol), ["SPY"])
    }

    func testLiveRequestsAreSetUpAsPaper() {
        let parsed = StrategyParser.parse("Trend following on AAPL, trade live with real money")
        XCTAssertEqual(parsed.draft.mode, .paper)
        XCTAssertTrue(parsed.assumptions.contains { $0.contains("Live trading isn't available") })
    }

    func testUnknownTickersAreReportedNotInvented() {
        let parsed = StrategyParser.parse("Momentum on $ZZZZ and $AAPL")
        XCTAssertEqual(parsed.unrecognisedSymbols, ["ZZZZ"])
        XCTAssertEqual(parsed.draft.spec.universe.map(\.symbol), ["AAPL"])
        // Ordinary capitalised words are not mistaken for tickers.
        XCTAssertTrue(StrategyParser.parse("I WANT TO BUY THE DIP IN AAPL").draft.spec.universe.map(\.symbol) == ["AAPL"])
    }

    func testMixedCurrenciesKeepOneCurrency() {
        let parsed = StrategyParser.parse("Trend agent on AAPL, MSFT and BHP")
        XCTAssertEqual(Set(parsed.draft.spec.universe.map(\.currency)), ["USD"])
        XCTAssertTrue(StrategyValidator.isValid(parsed.draft.spec))
    }

    func testDollarAmounts() {
        XCTAssertEqual(StrategyParser.dollarAmounts(in: "$5,000 and $2.5k and 300 dollars and A$1m"), [5_000, 2_500, 300, 1_000_000])
        XCTAssertEqual(StrategyParser.dollarAmounts(in: "the 50-day average"), [])
    }

    func testModelDraftsAreDecodedStrictlyAndNeverLive() throws {
        let json = """
        Here is the strategy:
        {"name":"RSI dip buyer","mode":"autonomousLive","budget":2500,"maxPositionPct":20,
         "spec":{"kind":"rules","title":"RSI dips","summary":"Buys oversold tech","timeframe":"day",
                 "universe":[{"symbol":"AAPL"},{"symbol":"MSFT"}],
                 "entry":{"op":"below","left":{"kind":"rsi","period":14},"right":{"kind":"constant","value":30}},
                 "exit":{"op":"above","left":{"kind":"rsi","period":14},"right":{"kind":"constant","value":55}},
                 "protections":{"stopLossPct":7},"sizing":{"mode":"percentOfEquity","value":20},
                 "reentryCooldownBars":1,"followsLedgerPositions":false}}
        """
        let parsed = try StrategyParser.decodeDraft(json: json)
        XCTAssertEqual(parsed.draft.mode, .paper)                      // a model can't ask for live
        XCTAssertEqual(parsed.draft.author, .copilot)
        XCTAssertEqual(parsed.draft.budget, 2_500)
        XCTAssertEqual(parsed.draft.spec.entry, .below(.rsi(14), .constant(30)))
        XCTAssertTrue(parsed.assumptions.contains { $0.contains("Live trading") })

        let broken = json.replacingOccurrences(of: #""exit":{"op":"above","left":{"kind":"rsi","period":14},"right":{"kind":"constant","value":55}},"#, with: "")
            .replacingOccurrences(of: #""protections":{"stopLossPct":7}"#, with: #""protections":{}"#)
        XCTAssertThrowsError(try StrategyParser.decodeDraft(json: broken))    // buys but can never sell
        XCTAssertThrowsError(try StrategyParser.decodeDraft(json: "Sure! I'd buy NVDA."))
        XCTAssertThrowsError(try StrategyParser.decodeDraft(json: #"{"name":"x","spec":{"kind":"wire-money"}}"#))
    }
}
