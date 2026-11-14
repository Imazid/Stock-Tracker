import Foundation

// A strategy is data, not code: a small set of rules a person can read, an AI can draft
// and a validator can check. The same JSON runs in a backtest, on the phone and on the
// server. The shapes are deliberately flat (a `kind` plus optional fields) so the JSON
// stays readable and easy to produce.

public enum PriceField: String, Codable, CaseIterable, Sendable {
    case open, high, low, close
}

public enum OperandKind: String, Codable, CaseIterable, Sendable {
    case price, volume, volumeAverage
    case sma, ema, rsi
    case macdLine, macdSignal, macdHistogram
    case bollingerUpper, bollingerMiddle, bollingerLower
    case atr, highest, lowest, rateOfChange
    case constant
}

/// One side of a comparison: a price, an indicator or a fixed number.
public struct Operand: Codable, Hashable, Sendable {
    public var kind: OperandKind
    public var field: PriceField?
    public var period: Int?
    public var fast: Int?
    public var slow: Int?
    public var signal: Int?
    public var deviations: Double?
    public var value: Double?
    /// Multiplies the result (0.97 = "3% below"). nil = 1.
    public var factor: Double?

    public init(kind: OperandKind, field: PriceField? = nil, period: Int? = nil, fast: Int? = nil,
                slow: Int? = nil, signal: Int? = nil, deviations: Double? = nil, value: Double? = nil,
                factor: Double? = nil) {
        self.kind = kind
        self.field = field
        self.period = period
        self.fast = fast
        self.slow = slow
        self.signal = signal
        self.deviations = deviations
        self.value = value
        self.factor = factor
    }

    public static let close = Operand(kind: .price, field: .close)
    public static let volume = Operand(kind: .volume)
    public static func price(_ field: PriceField) -> Operand { Operand(kind: .price, field: field) }
    public static func sma(_ period: Int) -> Operand { Operand(kind: .sma, period: period) }
    public static func ema(_ period: Int) -> Operand { Operand(kind: .ema, period: period) }
    public static func rsi(_ period: Int = 14) -> Operand { Operand(kind: .rsi, period: period) }
    public static func atr(_ period: Int = 14) -> Operand { Operand(kind: .atr, period: period) }
    public static func highest(_ period: Int) -> Operand { Operand(kind: .highest, period: period) }
    public static func lowest(_ period: Int) -> Operand { Operand(kind: .lowest, period: period) }
    public static func rateOfChange(_ period: Int) -> Operand { Operand(kind: .rateOfChange, period: period) }
    public static func volumeAverage(_ period: Int) -> Operand { Operand(kind: .volumeAverage, period: period) }
    public static func constant(_ value: Double) -> Operand { Operand(kind: .constant, value: value) }
    public static func macdLine(fast: Int = 12, slow: Int = 26, signal: Int = 9) -> Operand {
        Operand(kind: .macdLine, fast: fast, slow: slow, signal: signal)
    }
    public static func macdSignal(fast: Int = 12, slow: Int = 26, signal: Int = 9) -> Operand {
        Operand(kind: .macdSignal, fast: fast, slow: slow, signal: signal)
    }
    public static func macdHistogram(fast: Int = 12, slow: Int = 26, signal: Int = 9) -> Operand {
        Operand(kind: .macdHistogram, fast: fast, slow: slow, signal: signal)
    }
    public static func bollingerUpper(_ period: Int = 20, deviations: Double = 2) -> Operand {
        Operand(kind: .bollingerUpper, period: period, deviations: deviations)
    }
    public static func bollingerMiddle(_ period: Int = 20) -> Operand {
        Operand(kind: .bollingerMiddle, period: period, deviations: 2)
    }
    public static func bollingerLower(_ period: Int = 20, deviations: Double = 2) -> Operand {
        Operand(kind: .bollingerLower, period: period, deviations: deviations)
    }

    public func scaled(by factor: Double) -> Operand {
        var copy = self
        copy.factor = (self.factor ?? 1) * factor
        return copy
    }

    /// Bars of history needed before this operand has a value.
    public var warmup: Int {
        switch kind {
        case .price, .volume, .constant: return 1
        case .sma, .ema, .bollingerUpper, .bollingerMiddle, .bollingerLower, .volumeAverage: return period ?? 1
        case .rsi, .atr, .highest, .lowest, .rateOfChange: return (period ?? 1) + 1
        case .macdLine: return slow ?? 26
        case .macdSignal, .macdHistogram: return (slow ?? 26) + (signal ?? 9) - 1
        }
    }

    /// "50-day average", "RSI (14)", "Close" — how the rule reads to a person.
    public func label(_ timeframe: Timeframe = .day) -> String {
        let unit = timeframe == .day ? "day" : "hour"
        let base: String
        switch kind {
        case .price: base = (field ?? .close).rawValue.capitalized
        case .volume: base = "Volume"
        case .volumeAverage: base = "\(period ?? 0)-\(unit) average volume"
        case .sma: base = "\(period ?? 0)-\(unit) average"
        case .ema: base = "\(period ?? 0)-\(unit) EMA"
        case .rsi: base = "RSI (\(period ?? 14))"
        case .macdLine: base = "MACD"
        case .macdSignal: base = "MACD signal"
        case .macdHistogram: base = "MACD histogram"
        case .bollingerUpper: base = "upper Bollinger band (\(period ?? 20))"
        case .bollingerMiddle: base = "middle Bollinger band (\(period ?? 20))"
        case .bollingerLower: base = "lower Bollinger band (\(period ?? 20))"
        case .atr: base = "ATR (\(period ?? 14))"
        case .highest: base = "prior \(period ?? 0)-\(unit) high"
        case .lowest: base = "prior \(period ?? 0)-\(unit) low"
        case .rateOfChange: base = "\(period ?? 0)-\(unit) change %"
        case .constant: base = Self.trim(value ?? 0)
        }
        guard let factor, factor != 1 else { return base }
        return "\(Self.trim(factor)) × \(base)"
    }

    /// "10" for 10.0, "2.50" for 2.5 — a number without pointless decimals.
    public static func trim(_ x: Double) -> String {
        x == x.rounded() ? String(format: "%.0f", x) : String(format: "%.2f", x)
    }
}

public enum ConditionOp: String, Codable, CaseIterable, Sendable {
    case above, below, crossesAbove, crossesBelow, all, any
}

/// A rule: either a comparison of two operands, or a group of rules.
public struct Condition: Codable, Hashable, Sendable {
    public var op: ConditionOp
    public var left: Operand?
    public var right: Operand?
    public var conditions: [Condition]?

    public init(op: ConditionOp, left: Operand? = nil, right: Operand? = nil, conditions: [Condition]? = nil) {
        self.op = op
        self.left = left
        self.right = right
        self.conditions = conditions
    }

    public static func above(_ l: Operand, _ r: Operand) -> Condition { Condition(op: .above, left: l, right: r) }
    public static func below(_ l: Operand, _ r: Operand) -> Condition { Condition(op: .below, left: l, right: r) }
    public static func crossesAbove(_ l: Operand, _ r: Operand) -> Condition { Condition(op: .crossesAbove, left: l, right: r) }
    public static func crossesBelow(_ l: Operand, _ r: Operand) -> Condition { Condition(op: .crossesBelow, left: l, right: r) }
    public static func all(_ c: [Condition]) -> Condition { Condition(op: .all, conditions: c) }
    public static func any(_ c: [Condition]) -> Condition { Condition(op: .any, conditions: c) }

    public var isGroup: Bool { op == .all || op == .any }

    /// The comparisons inside this rule, flattened.
    public var leaves: [Condition] {
        isGroup ? (conditions ?? []).flatMap(\.leaves) : [self]
    }

    public var warmup: Int {
        if isGroup { return (conditions ?? []).map(\.warmup).max() ?? 1 }
        let base = max(left?.warmup ?? 1, right?.warmup ?? 1)
        // A cross compares this bar with the one before it.
        return (op == .crossesAbove || op == .crossesBelow) ? base + 1 : base
    }

    public func label(_ timeframe: Timeframe = .day) -> String {
        switch op {
        case .all, .any:
            let connector = op == .all ? " and " : " or "
            return (conditions ?? []).map { child in
                let text = child.label(timeframe)
                return child.isGroup && child.op != op ? "(\(text))" : text
            }.joined(separator: connector)
        case .above: return "\(left?.label(timeframe) ?? "?") is above \(right?.label(timeframe) ?? "?")"
        case .below: return "\(left?.label(timeframe) ?? "?") is below \(right?.label(timeframe) ?? "?")"
        case .crossesAbove: return "\(left?.label(timeframe) ?? "?") crosses above \(right?.label(timeframe) ?? "?")"
        case .crossesBelow: return "\(left?.label(timeframe) ?? "?") crosses below \(right?.label(timeframe) ?? "?")"
        }
    }
}

public enum StrategyKind: String, Codable, CaseIterable, Sendable {
    /// Entry and exit rules evaluated on each completed bar.
    case rules
    /// Buys a fixed amount on a schedule.
    case dca
    /// Keeps holdings at target weights.
    case rebalance
    /// Watches and reports; never produces an order.
    case research
}

/// Exits that protect an open position regardless of the exit rule.
public struct Protections: Codable, Hashable, Sendable {
    public var stopLossPct: Double?
    public var takeProfitPct: Double?
    public var trailingStopPct: Double?
    public var maxHoldingBars: Int?

    public init(stopLossPct: Double? = nil, takeProfitPct: Double? = nil,
                trailingStopPct: Double? = nil, maxHoldingBars: Int? = nil) {
        self.stopLossPct = stopLossPct
        self.takeProfitPct = takeProfitPct
        self.trailingStopPct = trailingStopPct
        self.maxHoldingBars = maxHoldingBars
    }

    public var isEmpty: Bool {
        stopLossPct == nil && takeProfitPct == nil && trailingStopPct == nil && maxHoldingBars == nil
    }
}

public enum SizingMode: String, Codable, CaseIterable, Sendable {
    case fixedNotional, percentOfEquity
}

public struct Sizing: Codable, Hashable, Sendable {
    public var mode: SizingMode
    /// Dollars for `fixedNotional`; percent (10 = 10%) for `percentOfEquity`.
    public var value: Double

    public init(mode: SizingMode, value: Double) {
        self.mode = mode
        self.value = value
    }
}

public struct DCAConfig: Codable, Hashable, Sendable {
    /// Bought in each instrument on each scheduled buy, in the ledger's currency.
    public var amountPerBuy: Double
    /// Bars between buys (5 daily bars = weekly).
    public var intervalBars: Int

    public init(amountPerBuy: Double, intervalBars: Int) {
        self.amountPerBuy = amountPerBuy
        self.intervalBars = intervalBars
    }
}

public struct RebalanceConfig: Codable, Hashable, Sendable {
    /// Instrument id → target share of the ledger's equity, in percent. Any remainder stays in cash.
    public var targets: [String: Double]
    /// A holding is traded back to target once it drifts this many percentage points away.
    public var driftThresholdPct: Double

    public init(targets: [String: Double], driftThresholdPct: Double) {
        self.targets = targets
        self.driftThresholdPct = driftThresholdPct
    }
}

/// Separate from the ordinary rebalance config so earlier engines safely skip it.
public struct MonthlyInvestment: Codable, Hashable, Sendable {
    public var amount: Double
    public var allocation: RebalanceConfig

    public init(amount: Double, allocation: RebalanceConfig) {
        self.amount = amount
        self.allocation = allocation
    }
}

public struct StrategySpec: Codable, Hashable, Sendable {
    public var kind: StrategyKind
    public var title: String
    public var summary: String
    public var timeframe: Timeframe
    public var universe: [Instrument]
    public var entry: Condition?
    public var exit: Condition?
    public var protections: Protections
    public var sizing: Sizing
    public var dca: DCAConfig?
    public var rebalance: RebalanceConfig?
    public var monthlyInvestment: MonthlyInvestment?
    /// Bars to wait after an exit before the same instrument can be bought again.
    public var reentryCooldownBars: Int
    /// Watch whatever the ledger holds instead of a fixed list (a risk-manager agent
    /// guarding a portfolio it doesn't choose).
    public var followsLedgerPositions: Bool

    public init(kind: StrategyKind, title: String, summary: String, timeframe: Timeframe = .day,
                universe: [Instrument], entry: Condition? = nil, exit: Condition? = nil,
                protections: Protections = Protections(),
                sizing: Sizing = Sizing(mode: .percentOfEquity, value: 10),
                dca: DCAConfig? = nil, rebalance: RebalanceConfig? = nil, monthlyInvestment: MonthlyInvestment? = nil,
                reentryCooldownBars: Int = 1, followsLedgerPositions: Bool = false) {
        self.kind = kind
        self.title = title
        self.summary = summary
        self.timeframe = timeframe
        self.universe = universe
        self.entry = entry
        self.exit = exit
        self.protections = protections
        self.sizing = sizing
        self.dca = dca
        self.rebalance = rebalance
        self.monthlyInvestment = monthlyInvestment
        self.reentryCooldownBars = reentryCooldownBars
        self.followsLedgerPositions = followsLedgerPositions
    }

    public var allocation: RebalanceConfig? { monthlyInvestment?.allocation ?? rebalance }

    /// Completed bars needed before any rule can be evaluated.
    public var warmupBars: Int {
        max(entry?.warmup ?? 1, exit?.warmup ?? 1, 2)
    }

    /// Bars to request from the data provider: the warm-up plus room for exits and stats.
    public var barsToFetch: Int { max(warmupBars + 60, 120) }

    /// Plain-English lines describing what the strategy does, for review screens.
    public var ruleLines: [String] {
        var lines: [String] = []
        switch kind {
        case .rules:
            if let entry { lines.append("Buy when \(entry.label(timeframe)).") }
            if let exit { lines.append("Sell when \(exit.label(timeframe)).") }
        case .dca:
            if let dca {
                let every = dca.intervalBars == 1 ? "every \(timeframe == .day ? "trading day" : "hour")"
                    : "every \(dca.intervalBars) \(timeframe == .day ? "trading days" : "hours")"
                lines.append("Buy \(Operand.trim(dca.amountPerBuy)) of each asset \(every).")
            }
        case .rebalance:
            if let amount = monthlyInvestment?.amount, amount > 0 {
                let currency = universe.first?.currency ?? "USD"
                lines.append("Invest \(NumberText.money(amount, currency: currency)) of available practice cash each month, split by target weight.")
            }
            if let rebalance = allocation {
                let parts = rebalance.targets.sorted { $0.value > $1.value }.map { id, weight in
                    "\(id.split(separator: ":").last.map(String.init) ?? id) \(Operand.trim(weight))%"
                }
                lines.append("Hold \(parts.joined(separator: ", ")).")
                let scope = monthlyInvestment != nil ? " of invested value" : ""
                lines.append("Trade back to target when a holding drifts \(Operand.trim(rebalance.driftThresholdPct)) percentage points\(scope).")
            }
        case .research:
            lines.append("Watch and report. This strategy never places orders.")
        }
        if let v = protections.stopLossPct { lines.append("Stop loss: sell if a position closes \(Operand.trim(v))% below its cost.") }
        if let v = protections.takeProfitPct { lines.append("Take profit: sell if a position closes \(Operand.trim(v))% above its cost.") }
        if let v = protections.trailingStopPct { lines.append("Trailing stop: sell if a position closes \(Operand.trim(v))% below its highest close since entry.") }
        if let v = protections.maxHoldingBars { lines.append("Time limit: sell after \(v) \(timeframe == .day ? "trading days" : "hours").") }
        return lines
    }
}

// MARK: - Validation

public struct StrategyIssue: Codable, Hashable, Sendable {
    public enum Severity: String, Codable, Sendable { case error, warning }
    public var severity: Severity
    public var message: String

    public init(_ severity: Severity, _ message: String) {
        self.severity = severity
        self.message = message
    }
}

/// Checks a strategy before it can run — whoever wrote it. An AI-drafted strategy gets no
/// special trust: it passes this or it doesn't run.
public enum StrategyValidator {
    public static let maxUniverse = 25
    public static let maxPeriod = 400

    public static func validate(_ spec: StrategySpec) -> [StrategyIssue] {
        var issues: [StrategyIssue] = []
        func error(_ m: String) { issues.append(StrategyIssue(.error, m)) }
        func warn(_ m: String) { issues.append(StrategyIssue(.warning, m)) }

        if spec.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { error("The strategy needs a name.") }

        if spec.followsLedgerPositions {
            if spec.kind != .rules { error("Only a rules strategy can follow a portfolio's positions.") }
        } else if spec.universe.isEmpty {
            error("Choose at least one asset to watch.")
        }
        if spec.universe.count > maxUniverse { error("A strategy can watch at most \(maxUniverse) assets.") }
        if Set(spec.universe.map(\.id)).count != spec.universe.count { error("The same asset is listed twice.") }
        let currencies = Set(spec.universe.map(\.currency))
        if currencies.count > 1 {
            error("All assets must trade in one currency (found \(currencies.sorted().joined(separator: " and "))).")
        }
        for instrument in spec.universe where !isValidSymbol(instrument.symbol) {
            error("\"\(instrument.symbol)\" isn't a valid symbol.")
        }

        switch spec.kind {
        case .rules:
            if spec.entry == nil && !spec.followsLedgerPositions { error("A rules strategy needs a buy rule.") }
            if spec.entry == nil && spec.exit == nil && spec.protections.isEmpty {
                error("Add a sell rule or a protective exit.")
            }
            if spec.entry != nil && spec.exit == nil && spec.protections.isEmpty {
                error("This strategy can buy but never sell. Add a sell rule or a stop.")
            }
            if let entry = spec.entry { validate(entry, name: "Buy rule", into: &issues) }
            if let exit = spec.exit { validate(exit, name: "Sell rule", into: &issues) }
        case .dca:
            guard let dca = spec.dca else { error("A scheduled-buy strategy needs an amount and an interval."); break }
            if !(dca.amountPerBuy.isFinite && dca.amountPerBuy > 0) { error("The amount per buy must be above zero.") }
            if !(1...250).contains(dca.intervalBars) { error("The buy interval must be between 1 and 250 bars.") }
        case .rebalance:
            guard let rebalance = spec.allocation else { error("A rebalancing strategy needs target weights."); break }
            let ids = Set(spec.universe.map(\.id))
            if rebalance.targets.isEmpty { error("Add at least one target weight.") }
            for (id, weight) in rebalance.targets.sorted(by: { $0.key < $1.key }) {
                if !ids.contains(id) { error("Target \(id) isn't in the asset list.") }
                if !(weight.isFinite && weight > 0 && weight <= 100) { error("Each target weight must be between 0 and 100%.") }
            }
            // Summed in key order so the total never depends on dictionary order.
            let total = rebalance.targets.sorted(by: { $0.key < $1.key }).reduce(0) { $0 + $1.value }
            if total > 100.0001 { error("Target weights add up to \(Operand.trim(total))% — they can't exceed 100%.") }
            if spec.monthlyInvestment != nil {
                if spec.rebalance != nil { error("Use one allocation configuration for monthly investing.") }
                if spec.timeframe != .day { error("Monthly investing needs daily bars.") }
                if Set(spec.universe.map(\.venue)).count > 1 { error("Monthly investing needs assets traded on the same market.") }
                if spec.universe.contains(where: { $0.assetClass != .etf }) { error("Choose ETFs for monthly investing and rebalancing.") }
                if Set(rebalance.targets.keys) != ids || abs(total - 100) > 0.0001 {
                    error("Set a target for every ETF. The weights must add up to 100%.")
                }
                if spec.monthlyInvestment.map({ $0.amount.isFinite && $0.amount > 0 }) != true {
                    error("Enter a monthly investment above zero.")
                }
                if !spec.protections.isEmpty { error("This strategy supports allocation drift exits. Remove the separate price-based exits.") }
            }
            if !(rebalance.driftThresholdPct.isFinite && rebalance.driftThresholdPct >= 0.5 && rebalance.driftThresholdPct <= 50) {
                error("The drift threshold must be between 0.5 and 50 points.")
            }
        case .research:
            if spec.entry != nil || spec.exit != nil { warn("Research strategies ignore buy and sell rules.") }
        }

        if spec.monthlyInvestment != nil && spec.kind != .rebalance { error("Monthly investing requires a rebalancing strategy.") }
        let p = spec.protections
        if let v = p.stopLossPct, !(v.isFinite && v > 0 && v < 100) { error("Stop loss must be between 0 and 100%.") }
        if let v = p.takeProfitPct, !(v.isFinite && v > 0 && v <= 1_000) { error("Take profit must be between 0 and 1000%.") }
        if let v = p.trailingStopPct, !(v.isFinite && v > 0 && v < 100) { error("Trailing stop must be between 0 and 100%.") }
        if let v = p.maxHoldingBars, !(1...2_000).contains(v) { error("The holding time limit must be between 1 and 2000 bars.") }

        switch spec.sizing.mode {
        case .fixedNotional:
            if !(spec.sizing.value.isFinite && spec.sizing.value > 0) { error("The order size must be above zero.") }
        case .percentOfEquity:
            if !(spec.sizing.value.isFinite && spec.sizing.value > 0 && spec.sizing.value <= 100) {
                error("The order size must be between 0 and 100% of the portfolio.")
            }
        }
        if !(0...500).contains(spec.reentryCooldownBars) { error("The re-entry wait must be between 0 and 500 bars.") }
        return issues
    }

    public static func isValid(_ spec: StrategySpec) -> Bool {
        !validate(spec).contains { $0.severity == .error }
    }

    static func isValidSymbol(_ symbol: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        return (1...12).contains(symbol.count) && symbol.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func validate(_ condition: Condition, name: String, depth: Int = 0, into issues: inout [StrategyIssue]) {
        func error(_ m: String) { issues.append(StrategyIssue(.error, "\(name): \(m)")) }
        guard depth <= 4 else { error("rules are nested too deeply."); return }
        if condition.isGroup {
            guard let children = condition.conditions, !children.isEmpty else { error("a group has no rules in it."); return }
            if children.count > 8 { error("a group can hold at most 8 rules.") }
            for child in children { validate(child, name: name, depth: depth + 1, into: &issues) }
            return
        }
        guard let left = condition.left, let right = condition.right else {
            error("a comparison needs two sides.")
            return
        }
        if left.kind == .constant && right.kind == .constant { error("comparing two fixed numbers does nothing.") }
        for operand in [left, right] { validate(operand, name: name, into: &issues) }
    }

    private static func validate(_ operand: Operand, name: String, into issues: inout [StrategyIssue]) {
        func error(_ m: String) { issues.append(StrategyIssue(.error, "\(name): \(m)")) }
        func checkPeriod(_ value: Int?, _ label: String) {
            guard let value else { error("\(operand.kind.rawValue) needs a \(label)."); return }
            if !(1...maxPeriod).contains(value) { error("\(label) must be between 1 and \(maxPeriod).") }
        }
        if let factor = operand.factor, !(factor.isFinite && factor > 0 && factor <= 10) {
            error("a multiplier must be between 0 and 10.")
        }
        switch operand.kind {
        case .price, .volume: break
        case .constant:
            if let v = operand.value { if !v.isFinite { error("a fixed number must be finite.") } }
            else { error("a fixed number is missing its value.") }
        case .sma, .ema, .rsi, .atr, .highest, .lowest, .rateOfChange, .volumeAverage, .bollingerMiddle:
            checkPeriod(operand.period, "period")
        case .bollingerUpper, .bollingerLower:
            checkPeriod(operand.period, "period")
            if let d = operand.deviations { if !(d.isFinite && d > 0 && d <= 5) { error("band width must be between 0 and 5 deviations.") } }
            else { error("a Bollinger band needs a width.") }
        case .macdLine, .macdSignal, .macdHistogram:
            checkPeriod(operand.fast, "fast period")
            checkPeriod(operand.slow, "slow period")
            checkPeriod(operand.signal, "signal period")
            if let f = operand.fast, let s = operand.slow, f >= s { error("the MACD fast period must be shorter than the slow one.") }
        }
    }
}
