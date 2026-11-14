import Foundation

public enum SignalAction: String, Codable, CaseIterable, Sendable {
    case buy, sell, hold
}

public enum ExitReason: String, Codable, Sendable {
    case rule, stopLoss, takeProfit, trailingStop, timeLimit, rebalance
}

/// One observed fact behind a decision, e.g. "Close is above 50-day average — 212.40 vs 204.11".
public struct Evidence: Codable, Hashable, Sendable {
    public var label: String
    public var value: String
    /// Whether the rule this fact belongs to was met; nil for plain observations.
    public var passed: Bool?

    public init(label: String, value: String, passed: Bool? = nil) {
        self.label = label
        self.value = value
        self.passed = passed
    }
}

/// The open position a strategy is managing, as far as its rules need to know.
public struct PositionContext: Sendable {
    public var quantity: Double
    public var averageCost: Double
    public var openedAt: Date

    public init(quantity: Double, averageCost: Double, openedAt: Date) {
        self.quantity = quantity
        self.averageCost = averageCost
        self.openedAt = openedAt
    }
}

public struct SignalDecision: Sendable {
    public var action: SignalAction
    public var headline: String
    public var evidence: [Evidence]
    /// The completed bar this decision was made on.
    public var barTime: Date
    public var close: Double
    public var exitReason: ExitReason?
    /// How far past their thresholds the met rules are, 0...1. It measures margin, not
    /// the chance of a profit.
    public var ruleMargin: Double?

    public init(action: SignalAction, headline: String, evidence: [Evidence], barTime: Date, close: Double,
                exitReason: ExitReason? = nil, ruleMargin: Double? = nil) {
        self.action = action
        self.headline = headline
        self.evidence = evidence
        self.barTime = barTime
        self.close = close
        self.exitReason = exitReason
        self.ruleMargin = ruleMargin
    }
}

/// Indicator values for one bar series, computed once and reused across rules and bars.
public final class PreparedSeries {
    public let bars: [Bar]
    private let closes: [Double]
    private var cache: [Operand: [Double?]] = [:]
    private var macdCache: [String: Indicators.MACD] = [:]
    private var bollingerCache: [String: Indicators.Bollinger] = [:]

    public init(bars: [Bar]) {
        self.bars = bars
        self.closes = bars.map(\.close)
    }

    public var count: Int { bars.count }

    /// The operand's value at bar `index`, using only bars up to and including it.
    public func value(_ operand: Operand, at index: Int) -> Double? {
        guard bars.indices.contains(index) else { return nil }
        var unscaled = operand
        unscaled.factor = nil
        let series: [Double?]
        if let hit = cache[unscaled] {
            series = hit
        } else {
            series = compute(unscaled)
            cache[unscaled] = series
        }
        guard let raw = series[index], raw.isFinite else { return nil }
        return raw * (operand.factor ?? 1)
    }

    private func compute(_ o: Operand) -> [Double?] {
        switch o.kind {
        case .price:
            switch o.field ?? .close {
            case .open: return bars.map { $0.open }
            case .high: return bars.map { $0.high }
            case .low: return bars.map { $0.low }
            case .close: return closes.map { $0 }
            }
        case .volume: return bars.map { $0.volume }
        case .volumeAverage: return Indicators.sma(bars.map(\.volume), period: o.period ?? 20)
        case .constant: return [Double?](repeating: o.value, count: bars.count)
        case .sma: return Indicators.sma(closes, period: o.period ?? 0)
        case .ema: return Indicators.ema(closes, period: o.period ?? 0)
        case .rsi: return Indicators.rsi(closes, period: o.period ?? 14)
        case .atr: return Indicators.atr(bars, period: o.period ?? 14)
        case .highest: return Indicators.priorHighest(bars.map(\.high), period: o.period ?? 0)
        case .lowest: return Indicators.priorLowest(bars.map(\.low), period: o.period ?? 0)
        case .rateOfChange: return Indicators.rateOfChange(closes, period: o.period ?? 0)
        case .macdLine, .macdSignal, .macdHistogram:
            let key = "\(o.fast ?? 12)-\(o.slow ?? 26)-\(o.signal ?? 9)"
            let macd = macdCache[key] ?? Indicators.macd(closes, fast: o.fast ?? 12, slow: o.slow ?? 26, signal: o.signal ?? 9)
            macdCache[key] = macd
            return o.kind == .macdLine ? macd.line : (o.kind == .macdSignal ? macd.signal : macd.histogram)
        case .bollingerUpper, .bollingerMiddle, .bollingerLower:
            let key = "\(o.period ?? 20)-\(o.deviations ?? 2)"
            let bands = bollingerCache[key] ?? Indicators.bollinger(closes, period: o.period ?? 20, deviations: o.deviations ?? 2)
            bollingerCache[key] = bands
            return o.kind == .bollingerUpper ? bands.upper : (o.kind == .bollingerLower ? bands.lower : bands.middle)
        }
    }

    /// Index of the bar containing `date` (the last bar that starts at or before it).
    public func index(containing date: Date) -> Int? {
        guard let first = bars.first, first.time <= date else { return nil }
        var lo = 0, hi = bars.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if bars[mid].time <= date { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}

public enum StrategyEvaluator {

    // MARK: Rules

    /// The decision a rules strategy makes on the last bar of `bars`.
    /// `bars` must hold completed bars only (see `MarketCalendar.completedBars`).
    public static func decide(spec: StrategySpec, bars: [Bar], position: PositionContext?,
                              lastExitTime: Date? = nil) -> SignalDecision? {
        guard !bars.isEmpty else { return nil }
        return decide(spec: spec, prepared: PreparedSeries(bars: bars), index: bars.count - 1,
                      position: position, lastExitTime: lastExitTime)
    }

    /// The decision on bar `index`, reading nothing after it.
    public static func decide(spec: StrategySpec, prepared: PreparedSeries, index: Int,
                              position: PositionContext?, lastExitTime: Date? = nil) -> SignalDecision {
        let bar = prepared.bars[index]
        let tf = spec.timeframe
        func hold(_ headline: String, _ evidence: [Evidence] = []) -> SignalDecision {
            SignalDecision(action: .hold, headline: headline, evidence: evidence, barTime: bar.time, close: bar.close)
        }

        if index + 1 < spec.warmupBars {
            return hold("Not enough history yet: the rules need \(spec.warmupBars) \(tf.barName) bars and \(index + 1) are available.")
        }

        if let position, position.quantity > 0 {
            let entryIndex = prepared.index(containing: position.openedAt) ?? 0
            var evidence: [Evidence] = []
            let cost = position.averageCost
            if cost > 0 {
                let changePct = (bar.close / cost - 1) * 100
                evidence.append(Evidence(label: "Position", value: "Close \(NumberText.price(bar.close)), cost \(NumberText.price(cost)) (\(NumberText.signedPercent(changePct)))"))
            }
            let p = spec.protections
            if let stop = p.stopLossPct, cost > 0 {
                let level = cost * (1 - stop / 100)
                let hit = bar.close <= level
                evidence.append(Evidence(label: "Stop loss \(Operand.trim(stop))%", value: "Close \(NumberText.price(bar.close)) vs stop \(NumberText.price(level))", passed: hit))
                if hit {
                    return SignalDecision(action: .sell, headline: "Stop loss: the close is \(Operand.trim(stop))% or more below cost.",
                                          evidence: evidence, barTime: bar.time, close: bar.close, exitReason: .stopLoss)
                }
            }
            if let target = p.takeProfitPct, cost > 0 {
                let level = cost * (1 + target / 100)
                let hit = bar.close >= level
                evidence.append(Evidence(label: "Take profit \(Operand.trim(target))%", value: "Close \(NumberText.price(bar.close)) vs target \(NumberText.price(level))", passed: hit))
                if hit {
                    return SignalDecision(action: .sell, headline: "Take profit: the close is \(Operand.trim(target))% or more above cost.",
                                          evidence: evidence, barTime: bar.time, close: bar.close, exitReason: .takeProfit)
                }
            }
            if let trail = p.trailingStopPct {
                let highest = prepared.bars[min(entryIndex, index)...index].map(\.close).max() ?? bar.close
                let level = highest * (1 - trail / 100)
                let hit = bar.close <= level
                evidence.append(Evidence(label: "Trailing stop \(Operand.trim(trail))%", value: "Close \(NumberText.price(bar.close)) vs \(NumberText.price(level)) (high \(NumberText.price(highest)))", passed: hit))
                if hit {
                    return SignalDecision(action: .sell, headline: "Trailing stop: the close is \(Operand.trim(trail))% below its highest close since entry.",
                                          evidence: evidence, barTime: bar.time, close: bar.close, exitReason: .trailingStop)
                }
            }
            if let limit = p.maxHoldingBars {
                let held = index - entryIndex
                let hit = held >= limit
                evidence.append(Evidence(label: "Time limit", value: "Held \(held) of \(limit) bars", passed: hit))
                if hit {
                    return SignalDecision(action: .sell, headline: "Time limit: held for \(held) bars.",
                                          evidence: evidence, barTime: bar.time, close: bar.close, exitReason: .timeLimit)
                }
            }
            if let exit = spec.exit {
                let result = evaluate(exit, prepared: prepared, index: index, timeframe: tf)
                evidence.append(contentsOf: result.evidence)
                if result.met == true {
                    return SignalDecision(action: .sell, headline: "Sell rule met: \(exit.label(tf)).",
                                          evidence: evidence, barTime: bar.time, close: bar.close,
                                          exitReason: .rule, ruleMargin: marginScore(result.margins))
                }
            }
            return hold("Holding: no sell rule or protective exit was met.", evidence)
        }

        if let lastExitTime, spec.reentryCooldownBars > 0, let exitIndex = prepared.index(containing: lastExitTime) {
            let since = index - exitIndex
            if since < spec.reentryCooldownBars {
                return hold("Waiting \(spec.reentryCooldownBars - since) more bar(s) after the last exit before buying again.")
            }
        }

        guard let entry = spec.entry else {
            return hold("Nothing to do: this strategy only manages positions that are already open.")
        }
        let result = evaluate(entry, prepared: prepared, index: index, timeframe: tf)
        switch result.met {
        case .some(true):
            return SignalDecision(action: .buy, headline: "Buy rule met: \(entry.label(tf)).",
                                  evidence: result.evidence, barTime: bar.time, close: bar.close,
                                  ruleMargin: marginScore(result.margins))
        case .some(false):
            return hold("No buy: the buy rule isn't met.", result.evidence)
        case .none:
            return hold("Not enough history to evaluate the buy rule.", result.evidence)
        }
    }

    struct ConditionResult {
        var met: Bool?
        var evidence: [Evidence]
        var margins: [Double]
    }

    static func evaluate(_ condition: Condition, prepared: PreparedSeries, index: Int, timeframe: Timeframe) -> ConditionResult {
        if condition.isGroup {
            let results = (condition.conditions ?? []).map { evaluate($0, prepared: prepared, index: index, timeframe: timeframe) }
            let evidence = results.flatMap(\.evidence)
            let margins = results.filter { $0.met == true }.flatMap(\.margins)
            let met: Bool?
            if condition.op == .all {
                if results.contains(where: { $0.met == false }) { met = false }
                else if results.contains(where: { $0.met == nil }) { met = nil }
                else { met = !results.isEmpty }
            } else {
                if results.contains(where: { $0.met == true }) { met = true }
                else if results.contains(where: { $0.met == nil }) { met = nil }
                else { met = false }
            }
            return ConditionResult(met: met, evidence: evidence, margins: margins)
        }

        let label = condition.label(timeframe)
        guard let leftOperand = condition.left, let rightOperand = condition.right,
              let l = prepared.value(leftOperand, at: index), let r = prepared.value(rightOperand, at: index) else {
            return ConditionResult(met: nil, evidence: [Evidence(label: label, value: "Not enough history", passed: nil)], margins: [])
        }
        var met: Bool?
        switch condition.op {
        case .above: met = l > r
        case .below: met = l < r
        case .crossesAbove, .crossesBelow:
            if index >= 1, let pl = prepared.value(leftOperand, at: index - 1), let pr = prepared.value(rightOperand, at: index - 1) {
                met = condition.op == .crossesAbove ? (pl <= pr && l > r) : (pl >= pr && l < r)
            } else {
                met = nil
            }
        case .all, .any: met = nil
        }
        let value = "\(NumberText.number(l)) vs \(NumberText.number(r))"
        let margin = abs(r) > 1e-9 ? abs(l - r) / abs(r) : 0
        return ConditionResult(met: met, evidence: [Evidence(label: label, value: value, passed: met)],
                               margins: met == true ? [margin] : [])
    }

    /// Average distance past the thresholds, where 5% or more counts as full margin.
    static func marginScore(_ margins: [Double]) -> Double? {
        guard !margins.isEmpty else { return nil }
        let mean = margins.reduce(0, +) / Double(margins.count)
        return min(max(mean / 0.05, 0), 1)
    }

    // MARK: Scheduled buys

    /// Whether a scheduled-buy strategy is due on the last bar.
    public static func decideDCA(spec: StrategySpec, bars: [Bar], lastBuyTime: Date?) -> SignalDecision? {
        guard let dca = spec.dca, let bar = bars.last else { return nil }
        let prepared = PreparedSeries(bars: bars)
        guard let lastBuyTime, let lastIndex = prepared.index(containing: lastBuyTime) else {
            return SignalDecision(action: .buy, headline: "Scheduled buy: first purchase.",
                                  evidence: [Evidence(label: "Schedule", value: "Every \(dca.intervalBars) bar(s)", passed: true)],
                                  barTime: bar.time, close: bar.close)
        }
        let since = bars.count - 1 - lastIndex
        let due = since >= dca.intervalBars
        let evidence = [Evidence(label: "Schedule", value: "\(since) of \(dca.intervalBars) bar(s) since the last buy", passed: due)]
        if due {
            return SignalDecision(action: .buy, headline: "Scheduled buy: \(since) bars since the last purchase.",
                                  evidence: evidence, barTime: bar.time, close: bar.close)
        }
        return SignalDecision(action: .hold, headline: "Next scheduled buy in \(dca.intervalBars - since) bar(s).",
                              evidence: evidence, barTime: bar.time, close: bar.close)
    }

    // MARK: Rebalancing

    public struct RebalanceTrade: Sendable, Equatable {
        public var instrumentID: String
        public var side: OrderSide
        public var notional: Double
        public var currentPct: Double
        public var targetPct: Double
    }

    /// Allocate a single monthly budget by weight, then measure drift against
    /// the invested portion. One net order per ETF prevents a buy and sell on
    /// the same decision bar. Unused practice cash stays uninvested.
    public static func monthlyRebalanceTrades(config: RebalanceConfig, values: [String: Double],
                                               contribution: Double) -> [RebalanceTrade] {
        let ids = config.targets.keys.sorted()
        let invested = ids.reduce(0.0) { $0 + (values[$1] ?? 0) }
        let total = invested + contribution
        guard total > 0 else { return [] }
        // Once a weight breaches the threshold, restore the full allocation,
        // including smaller counterpart trades that fund the breached weight.
        let triggered = ids.contains { id in
            invested > 0 && abs((values[id] ?? 0) / invested * 100 - (config.targets[id] ?? 0))
                >= config.driftThresholdPct
        }
        if triggered {
            let rebalance = RebalanceConfig(targets: config.targets, driftThresholdPct: 0)
            return rebalanceTrades(config: rebalance, values: values, equity: total).filter { $0.notional > 0 }
        }
        return ids.compactMap { id in
            let target = config.targets[id] ?? 0
            let amount = Rounding.money(contribution * target / 100)
            guard amount > 0 else { return nil }
            return RebalanceTrade(instrumentID: id, side: .buy, notional: amount,
                                  currentPct: invested > 0 ? (values[id] ?? 0) / invested * 100 : 0,
                                  targetPct: target)
        }
    }

    /// Trades that bring holdings back to target. Sells come first so their proceeds fund the buys.
    /// `values` is the market value of each holding by instrument id.
    public static func rebalanceTrades(config: RebalanceConfig, values: [String: Double], equity: Double) -> [RebalanceTrade] {
        guard equity > 0 else { return [] }
        var trades: [RebalanceTrade] = []
        for (id, targetPct) in config.targets.sorted(by: { $0.key < $1.key }) {
            let current = values[id] ?? 0
            let currentPct = current / equity * 100
            let drift = currentPct - targetPct
            guard abs(drift) >= config.driftThresholdPct else { continue }
            let delta = equity * targetPct / 100 - current
            trades.append(RebalanceTrade(instrumentID: id, side: delta >= 0 ? .buy : .sell,
                                         notional: Rounding.money(abs(delta)), currentPct: currentPct, targetPct: targetPct))
        }
        return trades.sorted { a, b in
            if a.side != b.side { return a.side == .sell }
            return a.instrumentID < b.instrumentID
        }
    }

    // MARK: Research

    /// Plain facts about a series, for research-only agents and the copilot. No opinion, no order.
    public static func researchFacts(bars: [Bar], timeframe: Timeframe = .day) -> [Evidence] {
        guard let last = bars.last else { return [] }
        let prepared = PreparedSeries(bars: bars)
        let i = bars.count - 1
        let unit = timeframe == .day ? "day" : "hour"
        var facts = [Evidence(label: "Last close", value: NumberText.price(last.close))]
        for period in [1, 5, 20] {
            if let change = prepared.value(.rateOfChange(period), at: i) {
                facts.append(Evidence(label: "\(period)-\(unit) change", value: NumberText.signedPercent(change)))
            }
        }
        for period in [50, 200] {
            if let average = prepared.value(.sma(period), at: i), average > 0 {
                let gap = (last.close / average - 1) * 100
                facts.append(Evidence(label: "vs \(period)-\(unit) average", value: "\(NumberText.signedPercent(gap)) (\(NumberText.price(average)))"))
            }
        }
        if let rsi = prepared.value(.rsi(14), at: i) {
            facts.append(Evidence(label: "RSI (14)", value: String(format: "%.0f", rsi)))
        }
        if let stats = InstrumentStats.measure(bars), timeframe == .day {
            facts.append(Evidence(label: "Daily volatility (20-day)", value: String(format: "%.1f%%", stats.dailyVolatilityPct)))
        }
        let window = bars.suffix(252)
        if window.count >= 20, let high = window.map(\.high).max(), high > 0 {
            facts.append(Evidence(label: "Below \(window.count)-bar high", value: NumberText.signedPercent((last.close / high - 1) * 100)))
        }
        return facts
    }
}

/// Number formatting for evidence text. Display code in the app formats money itself;
/// this is only for the explanations the core writes.
public enum NumberText {
    public static func price(_ x: Double) -> String {
        if abs(x) >= 100 { return String(format: "%.2f", x) }
        if abs(x) >= 1 { return String(format: "%.2f", x) }
        return String(format: "%.4f", x)
    }

    public static func number(_ x: Double) -> String {
        if abs(x) >= 1_000_000 { return String(format: "%.0f", x) }
        if abs(x) >= 1 { return String(format: "%.2f", x) }
        return String(format: "%.4f", x)
    }

    public static func signedPercent(_ x: Double) -> String {
        String(format: "%+.1f%%", x)
    }

    public static func money(_ x: Double, currency: String = "USD") -> String {
        let sign = x < 0 ? "-" : ""
        let places = Currencies.decimals(currency)
        return sign + Currencies.symbol(currency) + String(format: "%.\(places)f", Rounding.round(abs(x), places: places))
    }

    /// "$1.2M", "¥150M".
    public static func compactMoney(_ x: Double, currency: String) -> String {
        let symbol = Currencies.symbol(currency)
        switch abs(x) {
        case 1e12...: return symbol + String(format: "%.1fT", x / 1e12)
        case 1e9...: return symbol + String(format: "%.1fB", x / 1e9)
        case 1e6...: return symbol + String(format: "%.1fM", x / 1e6)
        case 1e3...: return symbol + String(format: "%.0fK", x / 1e3)
        default: return symbol + String(format: "%.0f", x)
        }
    }
}
