import Foundation

public struct BacktestConfig: Codable, Hashable, Sendable {
    public var startingCash: Double
    /// Price given up on every fill, in basis points (buys fill higher, sells lower).
    public var slippageBps: Double
    public var equityFeePerOrder: Double
    public var equityFeeBps: Double
    public var cryptoFeeBps: Double
    public var maxOrderNotional: Double
    public var maxPositionPct: Double
    public var maxOpenPositions: Int
    /// Share of the period, at the end, reported separately as an out-of-sample check.
    public var outOfSampleFraction: Double
    /// Annual risk-free rate used in the Sharpe and Sortino ratios, in percent.
    public var riskFreeRatePct: Double
    /// Lets test fixtures stand in for market data. Never set outside tests.
    public var allowFixtureData: Bool

    public init(startingCash: Double = 10_000, slippageBps: Double = 5, equityFeePerOrder: Double = 0,
                equityFeeBps: Double = 0, cryptoFeeBps: Double = 25, maxOrderNotional: Double? = nil,
                maxPositionPct: Double = 10, maxOpenPositions: Int = 10, outOfSampleFraction: Double = 0.3,
                riskFreeRatePct: Double = 0, allowFixtureData: Bool = false) {
        self.startingCash = startingCash
        self.slippageBps = slippageBps
        self.equityFeePerOrder = equityFeePerOrder
        self.equityFeeBps = equityFeeBps
        self.cryptoFeeBps = cryptoFeeBps
        self.maxOrderNotional = maxOrderNotional ?? startingCash
        self.maxPositionPct = maxPositionPct
        self.maxOpenPositions = maxOpenPositions
        self.outOfSampleFraction = outOfSampleFraction
        self.riskFreeRatePct = riskFreeRatePct
        self.allowFixtureData = allowFixtureData
    }

    /// The limits an agent would trade under, so a backtest and the live paper agent agree.
    public init(agent draft: AgentDraft, paper: PaperBrokerConfig = PaperBrokerConfig()) {
        let policy = draft.resolvedPolicy
        self.init(startingCash: draft.budget, slippageBps: 5, equityFeePerOrder: paper.equityFeePerOrder,
                  equityFeeBps: paper.equityFeeBps, cryptoFeeBps: paper.cryptoFeeBps,
                  maxOrderNotional: policy.maxOrderNotional, maxPositionPct: policy.maxPositionPct,
                  maxOpenPositions: policy.maxOpenPositions)
    }
}

public struct BacktestTrade: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var instrument: Instrument
    public var entryTime: Date
    public var entryPrice: Double
    public var quantity: Double
    public var exitTime: Date?
    public var exitPrice: Double?
    public var exitReason: String?
    /// Profit after fees. For a trade still open at the end, marked at the last close.
    public var pnl: Double
    public var pnlPct: Double
    public var barsHeld: Int
    public var isOpen: Bool
}

public struct BacktestMetrics: Codable, Hashable, Sendable {
    public var start: Date
    public var end: Date
    public var bars: Int
    public var startEquity: Double
    public var endEquity: Double
    public var totalReturnPct: Double
    /// Compound annual growth rate; nil for periods shorter than about three months.
    public var cagrPct: Double?
    public var maxDrawdownPct: Double
    /// Annualised standard deviation of returns, in percent.
    public var volatilityPct: Double
    public var sharpe: Double?
    public var sortino: Double?
    public var closedTrades: Int
    public var winRatePct: Double?
    /// Gross profit ÷ gross loss; nil when there were no losing trades.
    public var profitFactor: Double?
    public var averageWinPct: Double?
    public var averageLossPct: Double?
    /// Share of bars with money in the market, in percent.
    public var exposurePct: Double
    public var feesPaid: Double
}

public struct BacktestWindow: Codable, Hashable, Identifiable, Sendable {
    public var index: Int
    public var metrics: BacktestMetrics
    public var id: Int { index }
}

public struct BacktestResult: Codable, Sendable {
    public var strategyTitle: String
    public var config: BacktestConfig
    /// Where the prices came from, e.g. ["Alpaca (IEX)"].
    public var dataSources: [String]
    /// True only when every price series was real market data.
    public var usedRealMarketData: Bool
    public var equityCurve: [EquityPoint]
    public var benchmarkCurve: [EquityPoint]
    public var benchmarkName: String?
    public var benchmarkReturnPct: Double?
    public var trades: [BacktestTrade]
    public var overall: BacktestMetrics
    /// The earlier part of the period.
    public var inSample: BacktestMetrics?
    /// The final part of the period, reported by itself.
    public var outOfSample: BacktestMetrics?
    public var splitTime: Date?
    /// The period cut into equal consecutive windows, to show whether results depended on one stretch.
    public var windows: [BacktestWindow]
    public var assumptions: [String]
    public var warnings: [String]
}

public enum BacktestError: LocalizedError, Equatable {
    case notRealData(String)
    case noData
    case insufficientHistory(needed: Int, available: Int)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .notRealData(let symbol): return "The price history for \(symbol) isn't real market data, so it can't be backtested."
        case .noData: return "There is no price history to test on."
        case .insufficientHistory(let needed, let available):
            return "This strategy needs at least \(needed) bars of history and only \(available) are available."
        case .unsupported(let why): return why
        }
    }
}

/// Replays a strategy over past bars.
///
/// The one rule that matters: a decision made on a bar's close can only trade on the
/// *next* bar's open. Nothing reads a price before it would have existed. Prices must be
/// real market data — a fixture is accepted only when a test asks for it, and synthetic
/// data is never accepted.
public enum Backtester {

    private struct Holding {
        var quantity: Double
        var costBasis: Double
        var entryTime: Date
        var entryPrice: Double
        var entryIndex: Int
    }

    private struct Pending {
        var side: OrderSide
        var notional: Double?      // buys, and partial (rebalance) sells
        var reason: String
    }

    public static func run(spec: StrategySpec, series: [String: BarSeries], benchmark: BarSeries? = nil,
                           config: BacktestConfig, asOf now: Date, calendar: MarketCalendar = .standard) throws -> BacktestResult {
        guard spec.kind != .research else { throw BacktestError.unsupported("A research strategy never trades, so there is nothing to backtest.") }
        guard !spec.followsLedgerPositions else { throw BacktestError.unsupported("A risk manager guards positions someone else opens, so it can't be backtested by itself.") }
        let problems = StrategyValidator.validate(spec).filter { $0.severity == .error }
        if let first = problems.first { throw BacktestError.unsupported(first.message) }

        func accept(_ s: BarSeries) throws {
            switch s.provenance.kind {
            case .market: return
            case .fixture where config.allowFixtureData: return
            case .fixture, .synthetic: throw BacktestError.notRealData(s.instrument.symbol)
            }
        }

        var bars: [String: [Bar]] = [:]
        var sources = Set<String>()
        var allReal = true
        for instrument in spec.universe {
            guard let s = series[instrument.id] else { continue }
            try accept(s)
            guard s.timeframe == spec.timeframe else { continue }
            let completed = calendar.completedBars(s, now: now)
            if !completed.isEmpty { bars[instrument.id] = completed }
            sources.insert(s.provenance.source)
            if !s.provenance.isRealMarketData { allReal = false }
        }
        guard !bars.isEmpty else { throw BacktestError.noData }
        let longest = bars.values.map(\.count).max() ?? 0
        let needed = spec.kind == .rules ? spec.warmupBars + 20 : 20
        guard longest >= needed else { throw BacktestError.insufficientHistory(needed: needed, available: longest) }

        var warnings: [String] = []
        let missing = spec.universe.filter { bars[$0.id] == nil }.map(\.symbol)
        if !missing.isEmpty { warnings.append("No history for \(missing.joined(separator: ", ")); tested without \(missing.count == 1 ? "it" : "them").") }
        if spec.kind == .rebalance, !missing.isEmpty {
            throw BacktestError.unsupported("Rebalancing needs history for every fund. Missing: \(missing.joined(separator: ", ")).")
        }

        let instruments = Dictionary(uniqueKeysWithValues: spec.universe.map { ($0.id, $0) })
        let prepared = bars.mapValues { PreparedSeries(bars: $0) }
        var cursor = bars.mapValues { _ in 0 }      // next bar index per instrument
        let timeline = Array(Set(bars.values.flatMap { $0.map(\.time) })).sorted()

        var cash = Rounding.money(config.startingCash)
        var holdings: [String: Holding] = [:]
        var pending: [String: Pending] = [:]
        var lastClose: [String: Double] = [:]
        var lastExit: [String: Date] = [:]
        var lastBuyIndex: [String: Int] = [:]
        var trades: [BacktestTrade] = []
        var curve: [EquityPoint] = []
        var invested: [Bool] = []
        var fees = 0.0
        let slip = config.slippageBps / 10_000

        func fee(_ instrument: Instrument, _ notional: Double) -> Double {
            instrument.assetClass == .crypto
                ? Rounding.money(notional * config.cryptoFeeBps / 10_000)
                : Rounding.money(config.equityFeePerOrder + notional * config.equityFeeBps / 10_000)
        }
        func equity() -> Double {
            cash + holdings.reduce(0.0) { $0 + $1.value.quantity * (lastClose[$1.key] ?? $1.value.entryPrice) }
        }

        for time in timeline {
            // Which instruments print a bar at this moment.
            var active: [(id: String, index: Int)] = []
            for (id, list) in bars {
                let i = cursor[id] ?? 0
                if i < list.count, list[i].time == time { active.append((id, i)) }
            }
            active.sort { $0.id < $1.id }

            // 1. Orders decided on the previous bar trade at this bar's open. Sells first,
            //    so their cash is there for the buys.
            let executions = active.filter { pending[$0.id] != nil }
                .sorted { (pending[$0.id]?.side == .sell ? 0 : 1, $0.id) < (pending[$1.id]?.side == .sell ? 0 : 1, $1.id) }
            for (id, index) in executions {
                guard let order = pending.removeValue(forKey: id), let instrument = instruments[id], let list = bars[id] else { continue }
                let rules = PaperBroker.rules(for: instrument)
                let open = list[index].open
                switch order.side {
                case .buy:
                    let price = open * (1 + slip)
                    var notional = min(order.notional ?? 0, config.maxOrderNotional)
                    let feeRate = instrument.assetClass == .crypto ? config.cryptoFeeBps / 10_000 : config.equityFeeBps / 10_000
                    let flat = instrument.assetClass == .crypto ? 0 : config.equityFeePerOrder
                    notional = min(notional, max((cash - flat) / (1 + feeRate), 0))
                    let quantity = Rounding.floor(notional / price, increment: rules.quantityIncrement)
                    let gross = Rounding.money(quantity * price)
                    guard quantity >= rules.minQuantity, gross >= rules.minNotional else { continue }
                    let cost = fee(instrument, gross)
                    cash = Rounding.money(cash - gross - cost)
                    fees += cost
                    if var held = holdings[id] {
                        held.quantity = Rounding.round(held.quantity + quantity, places: 9)
                        held.costBasis = Rounding.money(held.costBasis + gross + cost)
                        holdings[id] = held
                    } else {
                        holdings[id] = Holding(quantity: quantity, costBasis: Rounding.money(gross + cost),
                                               entryTime: list[index].time, entryPrice: price, entryIndex: index)
                    }
                    lastBuyIndex[id] = index
                case .sell:
                    guard var held = holdings[id] else { continue }
                    let price = open * (1 - slip)
                    var quantity = held.quantity
                    if let notional = order.notional {
                        quantity = min(held.quantity, Rounding.floor(notional / price, increment: rules.quantityIncrement))
                    }
                    guard quantity > 0 else { continue }
                    let closing = held.quantity - quantity <= 1e-9
                    let gross = Rounding.money(quantity * price)
                    let cost = fee(instrument, gross)
                    let costRemoved = closing ? held.costBasis : Rounding.money(held.costBasis / held.quantity * quantity)
                    cash = Rounding.money(cash + gross - cost)
                    fees += cost
                    let pnl = Rounding.money(gross - cost - costRemoved)
                    trades.append(BacktestTrade(id: UUID(), instrument: instrument, entryTime: held.entryTime,
                                                entryPrice: held.entryPrice, quantity: quantity, exitTime: list[index].time,
                                                exitPrice: price, exitReason: order.reason, pnl: pnl,
                                                pnlPct: costRemoved > 0 ? pnl / costRemoved * 100 : 0,
                                                barsHeld: index - held.entryIndex, isOpen: false))
                    if closing {
                        holdings[id] = nil
                        lastExit[id] = list[index].time
                    } else {
                        held.quantity = Rounding.round(held.quantity - quantity, places: 9)
                        held.costBasis = Rounding.money(held.costBasis - costRemoved)
                        holdings[id] = held
                    }
                }
            }

            // 2. The bar closes.
            for (id, index) in active { lastClose[id] = bars[id]?[index].close }
            let equityNow = equity()

            // 3. Decisions on this close, to trade on the next open.
            switch spec.kind {
            case .rules:
                var openOrQueued = holdings.count + pending.values.filter { $0.side == .buy }.count
                for (id, index) in active where pending[id] == nil {
                    guard let series = prepared[id] else { continue }
                    let position = holdings[id].map {
                        PositionContext(quantity: $0.quantity, averageCost: $0.costBasis / $0.quantity, openedAt: $0.entryTime)
                    }
                    let decision = StrategyEvaluator.decide(spec: spec, prepared: series, index: index,
                                                            position: position, lastExitTime: lastExit[id])
                    switch decision.action {
                    case .buy where position == nil:
                        guard openOrQueued < config.maxOpenPositions else { continue }
                        var notional = spec.sizing.mode == .fixedNotional ? spec.sizing.value : equityNow * spec.sizing.value / 100
                        notional = min(notional, config.maxOrderNotional, equityNow * config.maxPositionPct / 100)
                        guard notional > 0 else { continue }
                        pending[id] = Pending(side: .buy, notional: notional, reason: "entry")
                        openOrQueued += 1
                    case .sell where position != nil:
                        pending[id] = Pending(side: .sell, notional: nil, reason: decision.exitReason?.rawValue ?? "rule")
                    default: break
                    }
                }
            case .dca:
                guard let dca = spec.dca else { break }
                for (id, index) in active where pending[id] == nil {
                    let due = lastBuyIndex[id].map { index + 1 - $0 >= dca.intervalBars } ?? true
                    if due { pending[id] = Pending(side: .buy, notional: dca.amountPerBuy, reason: "scheduled") }
                }
            case .rebalance:
                guard let rebalance = spec.rebalance, pending.isEmpty,
                      rebalance.targets.keys.allSatisfy({ lastClose[$0] != nil }) else { break }
                var values: [String: Double] = [:]
                for id in rebalance.targets.keys { values[id] = (holdings[id]?.quantity ?? 0) * (lastClose[id] ?? 0) }
                for trade in StrategyEvaluator.rebalanceTrades(config: rebalance, values: values, equity: equityNow) {
                    pending[trade.instrumentID] = Pending(side: trade.side, notional: trade.notional, reason: "rebalance")
                }
            case .research:
                break
            }

            for (id, index) in active { cursor[id] = index + 1 }
            curve.append(EquityPoint(time: time, equity: Rounding.money(equityNow), cash: cash))
            invested.append(!holdings.isEmpty)
        }

        // Positions still open at the end are marked at the last close and reported as open.
        for (id, held) in holdings.sorted(by: { $0.key < $1.key }) {
            guard let instrument = instruments[id], let price = lastClose[id], let list = bars[id] else { continue }
            let value = Rounding.money(held.quantity * price)
            trades.append(BacktestTrade(id: UUID(), instrument: instrument, entryTime: held.entryTime, entryPrice: held.entryPrice,
                                        quantity: held.quantity, exitTime: nil, exitPrice: nil, exitReason: nil,
                                        pnl: Rounding.money(value - held.costBasis),
                                        pnlPct: held.costBasis > 0 ? (value - held.costBasis) / held.costBasis * 100 : 0,
                                        barsHeld: list.count - 1 - held.entryIndex, isOpen: true))
        }
        trades.sort { $0.entryTime < $1.entryTime }

        guard curve.count >= 2 else { throw BacktestError.noData }
        let overall = metrics(curve: curve[...], invested: invested[...], trades: trades, fees: fees, config: config)

        var inSample: BacktestMetrics?
        var outOfSample: BacktestMetrics?
        var splitTime: Date?
        if config.outOfSampleFraction > 0, config.outOfSampleFraction < 1, curve.count >= 40 {
            let split = Int((Double(curve.count) * (1 - config.outOfSampleFraction)).rounded(.down))
            if split >= 10, curve.count - split >= 10 {
                splitTime = curve[split].time
                inSample = metrics(curve: curve[..<(split + 1)], invested: invested[..<(split + 1)], trades: trades, fees: 0, config: config)
                outOfSample = metrics(curve: curve[split...], invested: invested[split...], trades: trades, fees: 0, config: config)
            }
        }

        var windows: [BacktestWindow] = []
        let windowCount = 4
        if curve.count >= windowCount * 20 {
            let size = curve.count / windowCount
            for w in 0..<windowCount {
                let lower = w * size
                let upper = w == windowCount - 1 ? curve.count - 1 : (w + 1) * size
                windows.append(BacktestWindow(index: w + 1,
                                              metrics: metrics(curve: curve[lower...upper], invested: invested[lower...upper],
                                                               trades: trades, fees: 0, config: config)))
            }
        }

        // Buy-and-hold benchmark over the same dates.
        var benchmarkCurve: [EquityPoint] = []
        var benchmarkReturn: Double?
        if let benchmark {
            try accept(benchmark)
            let benchBars = calendar.completedBars(benchmark, now: now)
            if let startTime = curve.first?.time, let base = benchBars.last(where: { $0.time <= startTime })?.close ?? benchBars.first?.close, base > 0 {
                var j = 0
                var last = base
                for point in curve {
                    while j < benchBars.count, benchBars[j].time <= point.time { last = benchBars[j].close; j += 1 }
                    benchmarkCurve.append(EquityPoint(time: point.time, equity: Rounding.money(config.startingCash * last / base), cash: 0))
                }
                if let end = benchmarkCurve.last?.equity { benchmarkReturn = (end / config.startingCash - 1) * 100 }
            }
            if !benchmark.provenance.isRealMarketData { allReal = false }
        }

        if overall.closedTrades < 20 {
            warnings.append("Only \(overall.closedTrades) completed trade\(overall.closedTrades == 1 ? "" : "s"): too few to judge the strategy by.")
        }
        if let years = yearsBetween(curve.first?.time, curve.last?.time), years < 1 {
            warnings.append("Less than a year of history was tested, so one market mood dominates the result.")
        }

        let barName = spec.timeframe.barName
        let assumptions = [
            "Signals use completed \(barName) bars only. An order decided on one bar's close trades at the next bar's open.",
            String(format: "Every fill gives up %.0f bps of price as slippage.", config.slippageBps),
            String(format: "Fees: equities %@ per order plus %.0f bps; crypto %.0f bps.",
                   NumberText.money(config.equityFeePerOrder), config.equityFeeBps, config.cryptoFeeBps),
            "Orders are assumed to fill in full at the open. Real orders can fill at worse prices, in parts, or not at all.",
            "Stops are checked on bar closes, not inside the bar, so a real stop could trigger earlier or later.",
            spec.universe.contains { $0.assetClass != .crypto }
                ? "Share prices are adjusted for splits; dividends are not paid out as cash. Stocks that were delisted are not in the test, which flatters results."
                : "Crypto trades every day, including weekends.",
            "Cash earns no interest. Tax is not included.",
            "The rules were not tuned on this data. Past results do not predict future returns."
        ]

        return BacktestResult(strategyTitle: spec.title, config: config, dataSources: sources.sorted(),
                              usedRealMarketData: allReal, equityCurve: curve, benchmarkCurve: benchmarkCurve,
                              benchmarkName: benchmark.map { "\($0.instrument.symbol) buy and hold" },
                              benchmarkReturnPct: benchmarkReturn, trades: trades, overall: overall,
                              inSample: inSample, outOfSample: outOfSample, splitTime: splitTime,
                              windows: windows, assumptions: assumptions, warnings: warnings)
    }

    // MARK: - Metrics

    static func yearsBetween(_ start: Date?, _ end: Date?) -> Double? {
        guard let start, let end, end > start else { return nil }
        return end.timeIntervalSince(start) / (365.25 * 86_400)
    }

    static func metrics(curve: ArraySlice<EquityPoint>, invested: ArraySlice<Bool>, trades: [BacktestTrade],
                        fees: Double, config: BacktestConfig) -> BacktestMetrics {
        let points = Array(curve)
        let first = points.first ?? EquityPoint(time: Date(timeIntervalSince1970: 0), equity: config.startingCash, cash: config.startingCash)
        let last = points.last ?? first
        let years = yearsBetween(first.time, last.time) ?? 0

        var returns: [Double] = []
        var peak = first.equity
        var maxDrawdown = 0.0
        for i in points.indices {
            if i > 0, points[i - 1].equity > 0 { returns.append(points[i].equity / points[i - 1].equity - 1) }
            peak = max(peak, points[i].equity)
            if peak > 0 { maxDrawdown = max(maxDrawdown, (peak - points[i].equity) / peak * 100) }
        }

        let periodsPerYear = years > 0 ? Double(returns.count) / years : 252
        let mean = returns.isEmpty ? 0 : returns.reduce(0, +) / Double(returns.count)
        let variance = returns.count > 1 ? returns.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(returns.count - 1) : 0
        let stdev = variance.squareRoot()
        let riskFreePerPeriod = config.riskFreeRatePct / 100 / periodsPerYear
        let downside = returns.map { min($0 - riskFreePerPeriod, 0) }
        let downsideDeviation = returns.isEmpty ? 0 : (downside.map { $0 * $0 }.reduce(0, +) / Double(returns.count)).squareRoot()
        let enough = returns.count >= 20
        let sharpe = enough && stdev > 1e-12 ? (mean - riskFreePerPeriod) / stdev * periodsPerYear.squareRoot() : nil
        let sortino = enough && downsideDeviation > 1e-12 ? (mean - riskFreePerPeriod) / downsideDeviation * periodsPerYear.squareRoot() : nil

        let totalReturn = first.equity > 0 ? (last.equity / first.equity - 1) * 100 : 0
        let cagr: Double? = years >= 0.25 && first.equity > 0 && last.equity > 0
            ? (pow(last.equity / first.equity, 1 / years) - 1) * 100 : nil

        let closed = trades.filter { trade in
            guard !trade.isOpen, let exit = trade.exitTime else { return false }
            return exit > first.time && exit <= last.time
        }
        let wins = closed.filter { $0.pnl > 0 }
        let losses = closed.filter { $0.pnl < 0 }
        let grossProfit = wins.reduce(0.0) { $0 + $1.pnl }
        let grossLoss = -losses.reduce(0.0) { $0 + $1.pnl }
        let investedCount = invested.filter { $0 }.count

        return BacktestMetrics(
            start: first.time, end: last.time, bars: points.count, startEquity: first.equity, endEquity: last.equity,
            totalReturnPct: totalReturn, cagrPct: cagr, maxDrawdownPct: maxDrawdown,
            volatilityPct: stdev * periodsPerYear.squareRoot() * 100, sharpe: sharpe, sortino: sortino,
            closedTrades: closed.count,
            winRatePct: closed.isEmpty ? nil : Double(wins.count) / Double(closed.count) * 100,
            profitFactor: grossLoss > 0 ? grossProfit / grossLoss : nil,
            averageWinPct: wins.isEmpty ? nil : wins.reduce(0.0) { $0 + $1.pnlPct } / Double(wins.count),
            averageLossPct: losses.isEmpty ? nil : losses.reduce(0.0) { $0 + $1.pnlPct } / Double(losses.count),
            exposurePct: invested.isEmpty ? 0 : Double(investedCount) / Double(invested.count) * 100,
            feesPaid: Rounding.money(fees))
    }
}
