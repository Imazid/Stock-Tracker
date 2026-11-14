import XCTest
@testable import TradingCore

final class BacktesterTests: XCTestCase {
    private let config = BacktestConfig(startingCash: 10_000, slippageBps: 5, maxPositionPct: 10, allowFixtureData: true)

    private func run(_ spec: StrategySpec, _ series: [BarSeries], benchmark: BarSeries? = nil,
                     config: BacktestConfig? = nil) throws -> BacktestResult {
        try Backtester.run(spec: spec, series: Dictionary(uniqueKeysWithValues: series.map { ($0.instrument.id, $0) }),
                           benchmark: benchmark, config: config ?? self.config, asOf: Fx.now)
    }

    /// A wave around 100 that produces several entries and exits.
    private func wave(_ count: Int = 240, phase: Double = 0) -> [Double] {
        (0..<count).map { index in
            let position = Double(index)
            let oscillation = sin(position / 9 + phase) * 14
            return 100 + oscillation + position * 0.03
        }
    }

    func testMonthlyInvestingUsesOneBudgetPerCalendarMonthAndRebalances() throws {
        let funds = [Instrument.usETF("VTI"), Instrument.usETF("BND")]
        let spec = AgentTemplates.monthlyInvesting(funds, amount: 150)
        var settings = config
        settings.slippageBps = 0
        settings.maxPositionPct = 100
        let days = Fx.usTradingDays(count: 31)
        let flat = Array(repeating: 100.0, count: days.count)
        let inputs = funds.map { Fx.series($0, closes: flat, days: days) }
        let result = try run(spec, inputs, config: settings)
        let months = Set(days.dropLast().map { MarketCalendar.standard.dayKey(.us, $0).prefix(7) }).count
        XCTAssertEqual(result.equityCurve.last?.cash ?? -1, 10_000 - Double(months) * 150, accuracy: 0.01)
        XCTAssertEqual(result.trades.map(\.entryTime), Array(repeating: days[1], count: 2))
        XCTAssertThrowsError(try run(spec, [inputs[0]], config: settings))
        let trending = Fx.series(funds[0], closes: flat.enumerated().map { index, value in value + Double(index) * 4 }, days: days)
        let withDrift = try run(spec, [trending, inputs[1]], config: settings)
        XCTAssertTrue(withDrift.trades.contains { $0.instrument.symbol == "VTI" && $0.exitReason == "rebalance" })
    }

    func testMonthlyPracticeAgentPersistsPeriodAndAvoidsDuplicateProposals() throws {
        let funds = [Instrument.usETF("VTI"), Instrument.usETF("BND")]
        let spec = AgentTemplates.monthlyInvesting(funds, amount: 150)
        var engine = Fx.engine()
        let agent = try engine.createAgent(AgentDraft(name: "Monthly", spec: spec, reviewEachPaperTrade: true), now: Fx.now)
        let flat = Array(repeating: 100.0, count: 60)
        let snapshot = Fx.snapshot(funds.map { ($0, flat, 100) })
        let run = engine.runAgent(id: agent.id, snapshot: snapshot, trigger: .manual, now: Fx.now)
        XCTAssertEqual(run?.proposalIDs.count, 2)
        XCTAssertEqual(engine.state.agents.first?.lastMonthlyInvestmentPeriod, "2026-11")
        for proposal in engine.state.proposals {
            XCTAssertEqual(proposal.status, .pending)
            XCTAssertEqual(proposal.notional, 75, accuracy: 0.01)
            _ = try engine.approveProposal(id: proposal.id, now: Fx.now)
        }
        XCTAssertEqual(engine.state.fills.count, 2)
        XCTAssertEqual(engine.runAgent(id: agent.id, snapshot: snapshot, trigger: .manual, now: Fx.now)?.proposalIDs.count, 0)
        let recovered = try JSONDecoder().decode(TradingAgent.self, from: JSONEncoder().encode(engine.state.agents[0]))
        XCTAssertEqual(recovered.lastMonthlyInvestmentPeriod, "2026-11")
    }

    func testMonthlyOrdersStayWithinBudgetAfterRounding() {
        let config = RebalanceConfig(targets: ["us:BND": 33.33, "us:VTI": 33.33, "us:VXUS": 33.34], driftThresholdPct: 5)
        for values in [[:], ["us:VTI": 200.01, "us:BND": 17.88, "us:VXUS": 40.08]] {
            let trades = StrategyEvaluator.monthlyRebalanceTrades(config: config, values: values, contribution: 100.01)
            let net = trades.reduce(0) { $0 + ($1.side == .buy ? $1.notional : -$1.notional) }
            XCTAssertGreaterThan(net, 99.97)
            XCTAssertLessThanOrEqual(Rounding.money(net), 100.01)
        }
    }

    func testSyntheticAndUnapprovedFixtureDataAreRefused() {
        let spec = Fx.aboveAverageSpec([Fx.aapl])
        let synthetic = Fx.series(Fx.aapl, closes: wave(), provenance: .synthetic)
        XCTAssertThrowsError(try run(spec, [synthetic])) { XCTAssertEqual($0 as? BacktestError, .notRealData("AAPL")) }

        var strict = config
        strict.allowFixtureData = false
        XCTAssertThrowsError(try run(spec, [Fx.series(Fx.aapl, closes: wave())], config: strict)) {
            XCTAssertEqual($0 as? BacktestError, .notRealData("AAPL"))
        }
        // Synthetic data is refused even where fixtures are allowed, including as the benchmark.
        XCTAssertThrowsError(try run(spec, [Fx.series(Fx.aapl, closes: wave())],
                                     benchmark: Fx.series(Fx.spy, closes: wave(), provenance: .synthetic)))
    }

    func testAResultSaysWhetherItsDataWasReal() throws {
        let spec = Fx.aboveAverageSpec([Fx.aapl])
        XCTAssertFalse(try run(spec, [Fx.series(Fx.aapl, closes: wave())]).usedRealMarketData)
        let real = try run(spec, [Fx.series(Fx.aapl, closes: wave(), provenance: .market("Alpaca (IEX)"))])
        XCTAssertTrue(real.usedRealMarketData)
        XCTAssertEqual(real.dataSources, ["Alpaca (IEX)"])
    }

    func testASignalOnOneBarTradesAtTheNextBarsOpen() throws {
        // Flat at 100 for 30 bars, then a jump: the first close above the average is bar 30.
        let closes = [Double](repeating: 100, count: 30) + [110, 111, 112, 113, 114, 115, 116, 117, 118, 119] + [Double](repeating: 119, count: 20)
        let series = Fx.series(Fx.aapl, closes: closes)
        let result = try run(Fx.aboveAverageSpec([Fx.aapl]), [series])
        let trade = try XCTUnwrap(result.trades.first)
        XCTAssertEqual(trade.entryTime, series.bars[31].time)                     // not bar 30, where the signal appeared
        XCTAssertEqual(trade.entryPrice, series.bars[31].open * 1.0005, accuracy: 1e-9)   // that bar's open plus slippage
        XCTAssertEqual(series.bars[31].open, 110)
        // Sized at 10% of equity at the signal bar's close.
        XCTAssertEqual(trade.quantity, Rounding.floor(1_000 / trade.entryPrice, increment: 0.000_001))
    }

    /// Cutting the data short must not change any trade that had already finished: the
    /// test of "no look-ahead" at the level of the whole backtest.
    func testTradesDoNotDependOnLaterData() throws {
        let closes = wave(240)
        let days = Fx.usTradingDays(count: closes.count)
        let spec = Fx.aboveAverageSpec([Fx.aapl])
        let full = try run(spec, [Fx.series(Fx.aapl, closes: closes, days: days)])
        let cut = 150
        let partial = try Backtester.run(spec: spec,
                                         series: [Fx.aapl.id: Fx.series(Fx.aapl, closes: Array(closes.prefix(cut)), days: Array(days.prefix(cut)))],
                                         config: config, asOf: Fx.now)
        let cutoff = days[cut - 1]
        let finishedInFull = full.trades.filter { ($0.exitTime ?? .distantFuture) <= cutoff }
        let finishedInPartial = partial.trades.filter { !$0.isOpen }
        XCTAssertGreaterThan(finishedInFull.count, 2)
        XCTAssertEqual(finishedInFull.count, finishedInPartial.count)
        for (a, b) in zip(finishedInFull, finishedInPartial) {
            XCTAssertEqual(a.entryTime, b.entryTime)
            XCTAssertEqual(a.entryPrice, b.entryPrice)
            XCTAssertEqual(a.exitTime, b.exitTime)
            XCTAssertEqual(a.exitPrice, b.exitPrice)
            XCTAssertEqual(a.pnl, b.pnl)
        }
        // And the equity curve up to the cut is identical.
        XCTAssertEqual(Array(full.equityCurve.prefix(cut)), partial.equityCurve)
    }

    func testFeesAndSlippageOnlyEverCost() throws {
        let series = Fx.series(Fx.btc, closes: wave(240).map { $0 * 600 })
        let spec = Fx.aboveAverageSpec([Fx.btc])
        var free = config
        free.slippageBps = 0
        free.cryptoFeeBps = 0
        let costless = try run(spec, [series], config: free)
        let costly = try run(spec, [series])
        XCTAssertEqual(costless.overall.feesPaid, 0)
        XCTAssertGreaterThan(costly.overall.feesPaid, 0)
        XCTAssertLessThan(costly.overall.endEquity, costless.overall.endEquity)
        XCTAssertEqual(costly.trades.count, costless.trades.count)
    }

    func testMetricsOnAKnownCurve() {
        let t0 = Fx.date("2025-01-01T00:00:00Z")
        let equities: [Double] = [100, 110, 99, 120]
        let curve = equities.enumerated().map { EquityPoint(time: t0.addingTimeInterval(Double($0.offset) * 86_400), equity: $0.element, cash: 0) }
        let metrics = Backtester.metrics(curve: curve[...], invested: [true, true, false, true][...], trades: [], fees: 0, config: config)
        XCTAssertEqual(metrics.totalReturnPct, 20, accuracy: 1e-9)
        XCTAssertEqual(metrics.maxDrawdownPct, 10, accuracy: 1e-9)          // 110 → 99
        XCTAssertEqual(metrics.exposurePct, 75)
        XCTAssertNil(metrics.cagrPct)                                       // three days is no basis for an annual rate
        XCTAssertNil(metrics.sharpe)
        XCTAssertNil(metrics.winRatePct)
    }

    func testTradeStatistics() throws {
        let result = try run(Fx.aboveAverageSpec([Fx.aapl]), [Fx.series(Fx.aapl, closes: wave(240))])
        let closed = result.trades.filter { !$0.isOpen }
        XCTAssertEqual(result.overall.closedTrades, closed.count)
        let wins = closed.filter { $0.pnl > 0 }
        XCTAssertEqual(try XCTUnwrap(result.overall.winRatePct), Double(wins.count) / Double(closed.count) * 100, accuracy: 1e-9)
        // What the trades made is what the account gained (open trades marked at the last close).
        let total = result.trades.reduce(0.0) { $0 + $1.pnl }
        XCTAssertEqual(result.overall.endEquity - 10_000, total, accuracy: 0.05)
        XCTAssertTrue(closed.allSatisfy { ($0.exitTime ?? .distantPast) > $0.entryTime })
        XCTAssertTrue(result.warnings.contains { $0.contains("too few to judge") })
        XCTAssertTrue(result.assumptions.contains { $0.contains("next bar's open") })
        XCTAssertTrue(result.assumptions.contains { $0.contains("do not predict future returns") })
    }

    func testOutOfSampleSplitAndWindowsCoverThePeriod() throws {
        let result = try run(Fx.aboveAverageSpec([Fx.aapl]), [Fx.series(Fx.aapl, closes: wave(240))])
        let inSample = try XCTUnwrap(result.inSample), outOfSample = try XCTUnwrap(result.outOfSample)
        XCTAssertEqual(inSample.start, result.overall.start)
        XCTAssertEqual(outOfSample.end, result.overall.end)
        XCTAssertEqual(inSample.end, result.splitTime)
        XCTAssertEqual(outOfSample.start, result.splitTime)
        XCTAssertEqual(inSample.bars + outOfSample.bars, result.overall.bars + 1)       // they share the split point
        XCTAssertEqual(inSample.closedTrades + outOfSample.closedTrades, result.overall.closedTrades)
        // Compounding the two parts gives the whole.
        let compounded = (1 + inSample.totalReturnPct / 100) * (1 + outOfSample.totalReturnPct / 100) - 1
        XCTAssertEqual(compounded * 100, result.overall.totalReturnPct, accuracy: 1e-6)
        XCTAssertEqual(result.windows.count, 4)
        XCTAssertEqual(result.windows.first?.metrics.start, result.overall.start)
        XCTAssertEqual(result.windows.last?.metrics.end, result.overall.end)
    }

    func testBenchmarkIsBuyAndHoldOverTheSameDates() throws {
        let closes = wave(240)
        let series = Fx.series(Fx.aapl, closes: closes)
        let result = try run(Fx.aboveAverageSpec([Fx.aapl]), [series], benchmark: Fx.series(Fx.spy, closes: closes))
        XCTAssertEqual(result.benchmarkCurve.count, result.equityCurve.count)
        XCTAssertEqual(result.benchmarkCurve.first?.equity, 10_000)
        XCTAssertEqual(try XCTUnwrap(result.benchmarkReturnPct), (closes.last! / closes.first! - 1) * 100, accuracy: 0.01)
        XCTAssertEqual(result.benchmarkName, "SPY buy and hold")
    }

    func testPositionLimitsHoldInABacktest() throws {
        let universe = [Fx.aapl, Fx.msft, Fx.spy]
        let series = universe.enumerated().map { Fx.series($0.element, closes: wave(160, phase: Double($0.offset) * 0.1)) }
        var limited = config
        limited.maxOpenPositions = 2
        limited.maxPositionPct = 25
        var spec = Fx.aboveAverageSpec(universe)
        spec.sizing = Sizing(mode: .percentOfEquity, value: 25)
        let result = try run(spec, series, config: limited)
        // Never more than two positions open at any moment.
        let events = result.trades.flatMap { [($0.entryTime, 1), ($0.exitTime ?? Date.distantFuture, -1)] }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
        var open = 0, peak = 0
        for (_, change) in events { open += change; peak = max(peak, open) }
        XCTAssertEqual(peak, 2)
        // Cash never goes negative.
        XCTAssertTrue(result.equityCurve.allSatisfy { $0.cash >= -0.005 })
        XCTAssertTrue(result.trades.allSatisfy { $0.quantity * $0.entryPrice <= 10_000 * 0.25 * 1.5 })
    }

    func testScheduledBuysRunOnTheirInterval() throws {
        let series = Fx.series(Fx.spy, closes: [Double](repeating: 400, count: 30))
        var free = config
        free.slippageBps = 0
        free.maxPositionPct = 100
        let result = try run(AgentTemplates.dollarCostAveraging([Fx.spy], amountPerBuy: 100, intervalBars: 5), [series], config: free)
        // Buys on bars 1, 6, 11, 16, 21 and 26: six purchases of $100.
        XCTAssertEqual(try XCTUnwrap(result.equityCurve.last).cash, 9_400, accuracy: 0.05)
        XCTAssertEqual(result.trades.count, 1)
        XCTAssertTrue(result.trades[0].isOpen)
        XCTAssertEqual(result.overall.endEquity, 10_000, accuracy: 0.05)          // flat prices, no costs
    }

    func testRebalancingSellsWhatRoseAndBuysWhatDidNot() throws {
        let rising = (0..<120).map { 100 + Double($0) * 1.2 }
        let flat = [Double](repeating: 100, count: 120)
        let a = Instrument.usETF("VTI"), b = Instrument.usETF("BND")
        var spec = AgentTemplates.etfRebalancing([a, b])
        spec.rebalance = RebalanceConfig(targets: [a.id: 50, b.id: 50], driftThresholdPct: 5)
        var loose = config
        loose.maxPositionPct = 100
        let result = try run(spec, [Fx.series(a, closes: rising), Fx.series(b, closes: flat)], config: loose)
        let sells = result.trades.filter { !$0.isOpen }
        XCTAssertFalse(sells.isEmpty)
        XCTAssertTrue(sells.allSatisfy { $0.instrument.id == a.id && $0.exitReason == "rebalance" && $0.pnl > 0 })
        XCTAssertGreaterThan(result.overall.totalReturnPct, 0)
        XCTAssertLessThan(result.overall.totalReturnPct, (rising.last! / rising.first! - 1) * 100)
    }

    func testThingsThatCannotBeBacktestedSaySo() {
        XCTAssertThrowsError(try run(AgentTemplates.portfolioResearch([Fx.aapl]), [Fx.series(Fx.aapl, closes: wave())]))
        XCTAssertThrowsError(try run(AgentTemplates.riskManager(), []))
        XCTAssertThrowsError(try run(Fx.aboveAverageSpec([Fx.aapl]), [Fx.series(Fx.aapl, closes: wave(30))])) {
            XCTAssertEqual($0 as? BacktestError, .insufficientHistory(needed: 40, available: 30))
        }
        XCTAssertThrowsError(try run(Fx.aboveAverageSpec([Fx.aapl]), [])) { XCTAssertEqual($0 as? BacktestError, .noData) }
    }

    func testBacktestLimitsComeFromTheAgentsOwnPolicy() {
        let draft = AgentDraft(name: "A", spec: Fx.aboveAverageSpec([Fx.btc]), budget: 5_000, maxPositionPct: 20)
        let config = BacktestConfig(agent: draft)
        XCTAssertEqual(config.startingCash, 5_000)
        XCTAssertEqual(config.maxPositionPct, 20)
        XCTAssertEqual(config.maxOrderNotional, 1_000)
        XCTAssertEqual(config.cryptoFeeBps, PaperBrokerConfig().cryptoFeeBps)
        XCTAssertFalse(config.allowFixtureData)
    }
}
