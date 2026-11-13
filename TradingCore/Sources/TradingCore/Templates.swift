import Foundation

/// Named groups of well-known, liquid instruments, used as starting lists for agents and to
/// recognise symbols in a typed request. People can change the list afterwards.
public enum UniverseCatalog {
    public static let technology: [Instrument] = [
        .usStock("AAPL", name: "Apple"), .usStock("MSFT", name: "Microsoft"), .usStock("NVDA", name: "NVIDIA"),
        .usStock("GOOGL", name: "Alphabet"), .usStock("AMZN", name: "Amazon"), .usStock("META", name: "Meta Platforms"),
        .usStock("AVGO", name: "Broadcom"), .usStock("AMD", name: "Advanced Micro Devices")
    ]
    public static let semiconductors: [Instrument] = [
        .usStock("NVDA", name: "NVIDIA"), .usStock("AMD", name: "Advanced Micro Devices"), .usStock("AVGO", name: "Broadcom"),
        .usStock("TSM", name: "Taiwan Semiconductor"), .usStock("QCOM", name: "Qualcomm"), .usStock("MU", name: "Micron")
    ]
    public static let financials: [Instrument] = [
        .usStock("JPM", name: "JPMorgan Chase"), .usStock("BAC", name: "Bank of America"), .usStock("GS", name: "Goldman Sachs"),
        .usStock("MS", name: "Morgan Stanley"), .usStock("V", name: "Visa"), .usStock("MA", name: "Mastercard")
    ]
    public static let healthcare: [Instrument] = [
        .usStock("LLY", name: "Eli Lilly"), .usStock("UNH", name: "UnitedHealth"), .usStock("JNJ", name: "Johnson & Johnson"),
        .usStock("ABBV", name: "AbbVie"), .usStock("MRK", name: "Merck")
    ]
    public static let energy: [Instrument] = [
        .usStock("XOM", name: "Exxon Mobil"), .usStock("CVX", name: "Chevron"), .usStock("COP", name: "ConocoPhillips")
    ]
    public static let otherUS: [Instrument] = [
        .usStock("TSLA", name: "Tesla"), .usStock("NFLX", name: "Netflix"), .usStock("COST", name: "Costco"),
        .usStock("WMT", name: "Walmart"), .usStock("DIS", name: "Disney"), .usStock("INTC", name: "Intel"),
        .usStock("CRM", name: "Salesforce"), .usStock("ORCL", name: "Oracle"), .usStock("PLTR", name: "Palantir"),
        .usStock("COIN", name: "Coinbase")
    ]
    public static let broadETFs: [Instrument] = [
        .usETF("SPY", name: "S&P 500 ETF"), .usETF("QQQ", name: "Nasdaq-100 ETF"),
        .usETF("VTI", name: "Total US Market ETF"), .usETF("IWM", name: "Russell 2000 ETF")
    ]
    public static let balancedETFs: [Instrument] = [
        .usETF("VTI", name: "Total US Market ETF"), .usETF("VXUS", name: "Total International ETF"),
        .usETF("BND", name: "Total Bond Market ETF")
    ]
    public static let otherETFs: [Instrument] = [
        .usETF("VOO", name: "S&P 500 ETF"), .usETF("DIA", name: "Dow Jones ETF"), .usETF("GLD", name: "Gold ETF"),
        .usETF("TLT", name: "20+ Year Treasury ETF"), .usETF("XLK", name: "Technology Sector ETF")
    ]
    public static let cryptoMajors: [Instrument] = [
        .crypto("BTC", name: "Bitcoin"), .crypto("ETH", name: "Ethereum"), .crypto("SOL", name: "Solana")
    ]
    public static let otherCrypto: [Instrument] = [
        .crypto("XRP", name: "XRP"), .crypto("ADA", name: "Cardano"), .crypto("DOGE", name: "Dogecoin"),
        .crypto("AVAX", name: "Avalanche"), .crypto("LINK", name: "Chainlink"), .crypto("LTC", name: "Litecoin"),
        .crypto("DOT", name: "Polkadot"), .crypto("UNI", name: "Uniswap")
    ]
    public static let asxBlueChips: [Instrument] = [
        .asxStock("BHP", name: "BHP Group"), .asxStock("CBA", name: "Commonwealth Bank"), .asxStock("CSL", name: "CSL"),
        .asxStock("NAB", name: "National Australia Bank"), .asxStock("WBC", name: "Westpac"), .asxStock("ANZ", name: "ANZ Group"),
        .asxStock("WES", name: "Wesfarmers"), .asxStock("MQG", name: "Macquarie Group")
    ]

    /// Every instrument the catalog knows, US and crypto first.
    public static let all: [Instrument] = {
        var seen = Set<String>()
        var out: [Instrument] = []
        for list in [technology, semiconductors, financials, healthcare, energy, otherUS, broadETFs, balancedETFs,
                     otherETFs, cryptoMajors, otherCrypto, asxBlueChips] {
            for instrument in list where seen.insert(instrument.id).inserted { out.append(instrument) }
        }
        return out
    }()

    /// A known instrument by ticker. Where a ticker exists on two venues the US or crypto
    /// listing wins unless `preferring` says otherwise.
    public static func instrument(symbol: String, preferring venue: Venue? = nil) -> Instrument? {
        let upper = symbol.uppercased()
        let matches = all.filter { $0.symbol == upper }
        if let venue, let hit = matches.first(where: { $0.venue == venue }) { return hit }
        return matches.first
    }
}

/// A ready-made agent a person can start from and then change.
public struct AgentTemplate: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var tagline: String
    /// SF Symbol name for the template's icon.
    public var symbolName: String
    public var defaultMode: AgentMode
    public var defaultUniverse: [Instrument]
    public var schedule: AgentSchedule
    public var maxPositionPct: Double
    /// The agent watches an existing portfolio rather than getting its own.
    public var needsExistingPortfolio: Bool
    public var build: @Sendable ([Instrument]) -> StrategySpec

    public func draft(universe: [Instrument]? = nil, budget: Double = 10_000) -> AgentDraft {
        AgentDraft(name: name, templateID: id, mode: defaultMode, spec: build(universe ?? defaultUniverse),
                   budget: budget, maxPositionPct: maxPositionPct, schedule: schedule, author: .template)
    }
}

public enum AgentTemplates {

    public static func momentum(_ universe: [Instrument]) -> StrategySpec {
        StrategySpec(
            kind: .rules, title: "Momentum",
            summary: "Buys assets that are rising and above their 50-day average, and steps aside when the rise fades.",
            universe: universe,
            entry: .all([.above(.close, .sma(50)), .above(.rateOfChange(20), .constant(3)), .below(.rsi(14), .constant(75))]),
            exit: .any([.below(.close, .sma(50)), .below(.rateOfChange(20), .constant(-3))]),
            protections: Protections(stopLossPct: 8, trailingStopPct: 10),
            sizing: Sizing(mode: .percentOfEquity, value: 10), reentryCooldownBars: 3)
    }

    public static func trendFollowing(_ universe: [Instrument]) -> StrategySpec {
        StrategySpec(
            kind: .rules, title: "Trend following",
            summary: "Holds assets while their 20-day average is above their 50-day average.",
            universe: universe,
            entry: .all([.above(.sma(20), .sma(50)), .above(.close, .sma(20))]),
            exit: .below(.sma(20), .sma(50)),
            protections: Protections(stopLossPct: 10),
            sizing: Sizing(mode: .percentOfEquity, value: 10), reentryCooldownBars: 3)
    }

    /// Buys on the bar a fast average crosses above a slow one, and sells on the cross back.
    public static func movingAverageCrossover(_ universe: [Instrument], fast: Int = 20, slow: Int = 50,
                                              exponential: Bool = false) -> StrategySpec {
        let f: Operand = exponential ? .ema(fast) : .sma(fast)
        let s: Operand = exponential ? .ema(slow) : .sma(slow)
        return StrategySpec(
            kind: .rules, title: "Moving-average crossover",
            summary: "Buys when the \(fast)-day average crosses above the \(slow)-day average and sells when it crosses back below.",
            universe: universe,
            entry: .crossesAbove(f, s),
            exit: .crossesBelow(f, s),
            protections: Protections(stopLossPct: 10),
            sizing: Sizing(mode: .percentOfEquity, value: 10), reentryCooldownBars: 1)
    }

    public static func meanReversion(_ universe: [Instrument]) -> StrategySpec {
        StrategySpec(
            kind: .rules, title: "Mean reversion",
            summary: "Buys sharp dips (RSI under 30 and below the lower Bollinger band) and sells when price recovers to its average.",
            universe: universe,
            entry: .all([.below(.rsi(14), .constant(30)), .below(.close, .bollingerLower(20, deviations: 2))]),
            exit: .any([.above(.rsi(14), .constant(55)), .above(.close, .bollingerMiddle(20))]),
            protections: Protections(stopLossPct: 6, maxHoldingBars: 15),
            sizing: Sizing(mode: .percentOfEquity, value: 10), reentryCooldownBars: 2)
    }

    public static func breakout(_ universe: [Instrument]) -> StrategySpec {
        StrategySpec(
            kind: .rules, title: "Breakout",
            summary: "Buys a close above the prior 20-day high on above-average volume, and sells a close below the prior 10-day low.",
            universe: universe,
            entry: .all([.above(.close, .highest(20)), .above(.volume, .volumeAverage(20).scaled(by: 1.2))]),
            exit: .below(.close, .lowest(10)),
            protections: Protections(stopLossPct: 7),
            sizing: Sizing(mode: .percentOfEquity, value: 10), reentryCooldownBars: 3)
    }

    public static func dollarCostAveraging(_ universe: [Instrument], amountPerBuy: Double = 100, intervalBars: Int = 5) -> StrategySpec {
        StrategySpec(
            kind: .dca, title: "Dollar-cost averaging",
            summary: "Buys a fixed amount of each asset on a regular schedule, whatever the price.",
            universe: universe,
            sizing: Sizing(mode: .fixedNotional, value: amountPerBuy),
            dca: DCAConfig(amountPerBuy: amountPerBuy, intervalBars: intervalBars), reentryCooldownBars: 0)
    }

    public static func etfRebalancing(_ universe: [Instrument]) -> StrategySpec {
        // Default mix for the three balanced ETFs; any other list is split evenly.
        var targets: [String: Double] = [:]
        if universe.map(\.symbol) == ["VTI", "VXUS", "BND"] {
            targets = ["us:VTI": 60, "us:VXUS": 20, "us:BND": 20]
        } else if !universe.isEmpty {
            let each = Rounding.round(100 / Double(universe.count), places: 2)
            for instrument in universe { targets[instrument.id] = min(each, 100) }
            // Keep the total at or under 100 after rounding.
            let total = targets.values.reduce(0, +)
            if total > 100, let first = universe.first { targets[first.id] = each - (total - 100) }
        }
        return StrategySpec(
            kind: .rebalance, title: "ETF rebalancing",
            summary: "Keeps a fixed mix of funds, trading back to target when one drifts.",
            universe: universe,
            sizing: Sizing(mode: .percentOfEquity, value: 100),
            rebalance: RebalanceConfig(targets: targets, driftThresholdPct: 5), reentryCooldownBars: 0)
    }

    public static func cryptoMonitor(_ universe: [Instrument]) -> StrategySpec {
        StrategySpec(
            kind: .rules, title: "Crypto trend monitor",
            summary: "Watches crypto around the clock and signals when price is above a rising 21-day average.",
            universe: universe,
            entry: .all([.above(.close, .ema(21)), .above(.ema(21), .ema(55))]),
            exit: .below(.close, .ema(55)),
            protections: Protections(stopLossPct: 10, trailingStopPct: 15),
            sizing: Sizing(mode: .percentOfEquity, value: 20), reentryCooldownBars: 2)
    }

    public static func riskManager() -> StrategySpec {
        StrategySpec(
            kind: .rules, title: "Risk manager",
            summary: "Guards a portfolio's open positions with a stop loss and a trailing stop. It never opens a position.",
            universe: [],
            protections: Protections(stopLossPct: 8, trailingStopPct: 12),
            sizing: Sizing(mode: .percentOfEquity, value: 10), reentryCooldownBars: 0,
            followsLedgerPositions: true)
    }

    public static func portfolioResearch(_ universe: [Instrument]) -> StrategySpec {
        StrategySpec(
            kind: .research, title: "Portfolio research",
            summary: "Reports trend, momentum and volatility facts for the assets you follow. It never trades.",
            universe: universe,
            sizing: Sizing(mode: .percentOfEquity, value: 10), reentryCooldownBars: 0)
    }

    public static let all: [AgentTemplate] = [
        AgentTemplate(id: "momentum", name: "Momentum Agent", tagline: "Rides assets that are already rising",
                      symbolName: "arrow.up.right", defaultMode: .paper, defaultUniverse: UniverseCatalog.technology,
                      schedule: .hourly, maxPositionPct: 10, needsExistingPortfolio: false, build: { momentum($0) }),
        AgentTemplate(id: "trend", name: "Trend Following Agent", tagline: "Holds while the trend is up",
                      symbolName: "chart.line.uptrend.xyaxis", defaultMode: .paper, defaultUniverse: UniverseCatalog.broadETFs,
                      schedule: .hourly, maxPositionPct: 25, needsExistingPortfolio: false, build: { trendFollowing($0) }),
        AgentTemplate(id: "meanReversion", name: "Mean Reversion Agent", tagline: "Buys sharp dips, sells the recovery",
                      symbolName: "arrow.uturn.up", defaultMode: .paper, defaultUniverse: UniverseCatalog.technology,
                      schedule: .hourly, maxPositionPct: 10, needsExistingPortfolio: false, build: { meanReversion($0) }),
        AgentTemplate(id: "dca", name: "Dollar-Cost Averaging Agent", tagline: "Buys a fixed amount on a schedule",
                      symbolName: "calendar.badge.plus", defaultMode: .paper,
                      defaultUniverse: [.usETF("SPY", name: "S&P 500 ETF"), .usETF("QQQ", name: "Nasdaq-100 ETF")],
                      schedule: AgentSchedule(intervalMinutes: 1_440), maxPositionPct: 60, needsExistingPortfolio: false,
                      build: { dollarCostAveraging($0) }),
        AgentTemplate(id: "breakout", name: "Breakout Agent", tagline: "Buys new highs on strong volume",
                      symbolName: "bolt", defaultMode: .paper, defaultUniverse: UniverseCatalog.technology,
                      schedule: .hourly, maxPositionPct: 10, needsExistingPortfolio: false, build: { breakout($0) }),
        AgentTemplate(id: "etfRebalance", name: "ETF Rebalancing Agent", tagline: "Keeps a fixed mix of funds",
                      symbolName: "chart.pie", defaultMode: .paper, defaultUniverse: UniverseCatalog.balancedETFs,
                      schedule: AgentSchedule(intervalMinutes: 1_440), maxPositionPct: 70, needsExistingPortfolio: false,
                      build: { etfRebalancing($0) }),
        AgentTemplate(id: "cryptoMonitor", name: "Crypto Market Monitoring Agent", tagline: "Watches crypto around the clock",
                      symbolName: "bitcoinsign.circle", defaultMode: .signals, defaultUniverse: UniverseCatalog.cryptoMajors,
                      schedule: .hourly, maxPositionPct: 35, needsExistingPortfolio: false, build: { cryptoMonitor($0) }),
        AgentTemplate(id: "riskManager", name: "Risk Management Agent", tagline: "Guards a portfolio with stops",
                      symbolName: "shield.lefthalf.filled", defaultMode: .paper, defaultUniverse: [],
                      schedule: .hourly, maxPositionPct: 100, needsExistingPortfolio: true, build: { _ in riskManager() }),
        AgentTemplate(id: "research", name: "Portfolio Research Agent", tagline: "Reports facts, never trades",
                      symbolName: "doc.text.magnifyingglass", defaultMode: .researchOnly, defaultUniverse: UniverseCatalog.technology,
                      schedule: AgentSchedule(intervalMinutes: 1_440), maxPositionPct: 10, needsExistingPortfolio: false,
                      build: { portfolioResearch($0) })
    ]

    public static func template(_ id: String?) -> AgentTemplate? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }
}
