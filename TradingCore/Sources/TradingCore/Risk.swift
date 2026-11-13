import Foundation

// MARK: - Policies

/// Limits for one ledger (one agent's budget, or one paper portfolio).
public struct RiskPolicy: Codable, Hashable, Sendable {
    /// Largest single order, in the ledger's currency.
    public var maxOrderNotional: Double
    /// Largest share of the ledger's equity one instrument may reach, in percent.
    public var maxPositionPct: Double
    /// Most that may be traded in one day.
    public var maxDailyNotional: Double
    /// New buys stop once today's realised loss reaches this percent of the day's starting equity.
    public var maxDailyLossPct: Double
    /// New buys stop once equity is this percent below its peak.
    public var maxDrawdownPct: Double
    public var maxOpenPositions: Int
    /// Widest bid/ask spread an order may trade through, in basis points.
    public var maxSpreadBps: Double
    /// Oldest quote an order may be checked against, in seconds.
    public var maxQuoteAgeSeconds: Double
    /// Smallest average daily traded value an instrument must have.
    public var minAverageDollarVolume: Double
    /// Highest daily volatility (percent) an instrument may have for new buys.
    public var maxDailyVolatilityPct: Double
    /// Seconds to wait after a fill before buying the same instrument again.
    public var cooldownSeconds: Double
    /// A waiting order is cancelled if the price has moved this far (percent) from where it was checked.
    public var maxPriceGapPct: Double
    /// Orders placed while the market is shut wait for the open. If false they are refused.
    public var allowQueueOutsideHours: Bool

    public init(maxOrderNotional: Double, maxPositionPct: Double, maxDailyNotional: Double,
                maxDailyLossPct: Double = 3, maxDrawdownPct: Double = 15, maxOpenPositions: Int = 10,
                maxSpreadBps: Double = 50, maxQuoteAgeSeconds: Double = 900,
                minAverageDollarVolume: Double = 1_000_000, maxDailyVolatilityPct: Double = 8,
                cooldownSeconds: Double = 300, maxPriceGapPct: Double = 5, allowQueueOutsideHours: Bool = true) {
        self.maxOrderNotional = maxOrderNotional
        self.maxPositionPct = maxPositionPct
        self.maxDailyNotional = maxDailyNotional
        self.maxDailyLossPct = maxDailyLossPct
        self.maxDrawdownPct = maxDrawdownPct
        self.maxOpenPositions = maxOpenPositions
        self.maxSpreadBps = maxSpreadBps
        self.maxQuoteAgeSeconds = maxQuoteAgeSeconds
        self.minAverageDollarVolume = minAverageDollarVolume
        self.maxDailyVolatilityPct = maxDailyVolatilityPct
        self.cooldownSeconds = cooldownSeconds
        self.maxPriceGapPct = maxPriceGapPct
        self.allowQueueOutsideHours = allowQueueOutsideHours
    }

    /// Sensible starting limits for a budget. Crypto gets wider spread, volatility and gap
    /// allowances because that market really is wider and jumpier.
    public static func standard(budget: Double, maxPositionPct: Double = 10, crypto: Bool = false) -> RiskPolicy {
        let position = min(max(maxPositionPct, 1), 100)
        return RiskPolicy(
            maxOrderNotional: Rounding.money(max(budget * position / 100, 1)),
            maxPositionPct: position,
            maxDailyNotional: Rounding.money(max(budget * 0.5, 1)),
            maxDailyLossPct: 3,
            maxDrawdownPct: 15,
            maxOpenPositions: 10,
            maxSpreadBps: crypto ? 100 : 50,
            maxQuoteAgeSeconds: crypto ? 300 : 900,
            minAverageDollarVolume: 1_000_000,
            maxDailyVolatilityPct: crypto ? 15 : 8,
            cooldownSeconds: 300,
            maxPriceGapPct: crypto ? 8 : 5,
            allowQueueOutsideHours: true
        )
    }

    /// Problems that would make a policy meaningless or unsafe.
    public var issues: [String] {
        var out: [String] = []
        if !(maxOrderNotional.isFinite && maxOrderNotional > 0) { out.append("The largest order must be above zero.") }
        if !(maxPositionPct.isFinite && maxPositionPct > 0 && maxPositionPct <= 100) { out.append("The position limit must be between 0 and 100%.") }
        if !(maxDailyNotional.isFinite && maxDailyNotional > 0) { out.append("The daily trading limit must be above zero.") }
        if !(maxDailyLossPct.isFinite && maxDailyLossPct > 0 && maxDailyLossPct <= 100) { out.append("The daily loss limit must be between 0 and 100%.") }
        if !(maxDrawdownPct.isFinite && maxDrawdownPct > 0 && maxDrawdownPct <= 100) { out.append("The drawdown limit must be between 0 and 100%.") }
        if !(1...100).contains(maxOpenPositions) { out.append("Open positions must be between 1 and 100.") }
        if !(maxSpreadBps.isFinite && maxSpreadBps > 0) { out.append("The spread limit must be above zero.") }
        if !(maxQuoteAgeSeconds.isFinite && maxQuoteAgeSeconds >= 5) { out.append("Quotes can't be required to be newer than 5 seconds.") }
        if !(cooldownSeconds.isFinite && cooldownSeconds >= 0) { out.append("The cooldown can't be negative.") }
        if !(maxPriceGapPct.isFinite && maxPriceGapPct > 0 && maxPriceGapPct <= 50) { out.append("The price-gap limit must be between 0 and 50%.") }
        return out
    }
}

/// What real-money trading is switched on. Everything is off in this build, and nothing in
/// the app can turn it on: these flags are set by the server after its own checks.
public struct LiveAuthorization: Codable, Hashable, Sendable {
    public var manualOrdersEnabled: Bool
    public var approvalAgentsEnabled: Bool
    public var autonomousAgentsEnabled: Bool

    public init(manualOrdersEnabled: Bool = false, approvalAgentsEnabled: Bool = false, autonomousAgentsEnabled: Bool = false) {
        self.manualOrdersEnabled = manualOrdersEnabled
        self.approvalAgentsEnabled = approvalAgentsEnabled
        self.autonomousAgentsEnabled = autonomousAgentsEnabled
    }

    public static let disabled = LiveAuthorization()
}

/// Limits across everything a person runs, whichever agent or portfolio an order comes from.
public struct AccountPolicy: Codable, Hashable, Sendable {
    public var killSwitchEngaged: Bool
    public var killSwitchAt: Date?
    /// Largest share of all equity (every ledger of the same mode) one instrument may reach, in percent.
    public var maxSymbolExposurePct: Double
    /// Most that may be traded in one day across every ledger.
    public var maxTotalDailyNotional: Double
    public var live: LiveAuthorization
    /// Lets test fixtures stand in for market data. Never set outside tests.
    public var allowFixtureData: Bool

    public init(killSwitchEngaged: Bool = false, killSwitchAt: Date? = nil, maxSymbolExposurePct: Double = 35,
                maxTotalDailyNotional: Double = 250_000, live: LiveAuthorization = .disabled,
                allowFixtureData: Bool = false) {
        self.killSwitchEngaged = killSwitchEngaged
        self.killSwitchAt = killSwitchAt
        self.maxSymbolExposurePct = maxSymbolExposurePct
        self.maxTotalDailyNotional = maxTotalDailyNotional
        self.live = live
        self.allowFixtureData = allowFixtureData
    }
}

// MARK: - Report

public enum RiskCheckID: String, Codable, CaseIterable, Sendable {
    case killSwitch, authorization, agentStatus, brokerPermission, universe, currency
    case marketData, quoteFreshness, marketHours, exchangeRules
    case orderValue, buyingPower, holdings, positionLimit, concentration, openPositions
    case dailyNotional, dailyLoss, drawdown, spread, liquidity, volatility, duplicate, cooldown

    public var title: String {
        switch self {
        case .killSwitch: return "Kill switch"
        case .authorization: return "Trading mode"
        case .agentStatus: return "Agent status"
        case .brokerPermission: return "Broker permission"
        case .universe: return "Approved assets"
        case .currency: return "Currency"
        case .marketData: return "Market data"
        case .quoteFreshness: return "Quote freshness"
        case .marketHours: return "Market hours"
        case .exchangeRules: return "Exchange rules"
        case .orderValue: return "Order size"
        case .buyingPower: return "Buying power"
        case .holdings: return "Holdings"
        case .positionLimit: return "Position limit"
        case .concentration: return "Concentration"
        case .openPositions: return "Open positions"
        case .dailyNotional: return "Daily trading limit"
        case .dailyLoss: return "Daily loss limit"
        case .drawdown: return "Drawdown limit"
        case .spread: return "Spread"
        case .liquidity: return "Liquidity"
        case .volatility: return "Volatility"
        case .duplicate: return "Duplicate orders"
        case .cooldown: return "Cooldown"
        }
    }
}

public enum RiskCheckStatus: String, Codable, Sendable {
    case passed, warning, failed, notApplicable
}

public struct RiskCheck: Codable, Hashable, Identifiable, Sendable {
    public var id: RiskCheckID
    public var status: RiskCheckStatus
    public var detail: String

    public init(_ id: RiskCheckID, _ status: RiskCheckStatus, _ detail: String) {
        self.id = id
        self.status = status
        self.detail = detail
    }
}

public struct RiskReport: Codable, Hashable, Sendable {
    public var checks: [RiskCheck]
    public var evaluatedAt: Date

    public init(checks: [RiskCheck], evaluatedAt: Date) {
        self.checks = checks
        self.evaluatedAt = evaluatedAt
    }

    public var failures: [RiskCheck] { checks.filter { $0.status == .failed } }
    public var warnings: [RiskCheck] { checks.filter { $0.status == .warning } }
    /// An order goes ahead only when no check failed.
    public var isApproved: Bool { failures.isEmpty }

    public var summary: String {
        if let first = failures.first {
            return failures.count == 1 ? first.detail : "\(first.detail) (+\(failures.count - 1) more)"
        }
        let passed = checks.filter { $0.status == .passed }.count
        return warnings.isEmpty ? "All \(passed) checks passed." : "\(passed) checks passed, \(warnings.count) with a warning."
    }

    public func check(_ id: RiskCheckID) -> RiskCheck? { checks.first { $0.id == id } }
}

// MARK: - Inputs

/// An order after sizing, ready to be judged.
public struct OrderIntent: Sendable {
    public var clientOrderID: String
    public var instrument: Instrument
    public var side: OrderSide
    public var type: OrderType
    public var timeInForce: TimeInForce
    public var quantity: Double
    /// The price the value checks use: the worst price this order could trade at right now.
    public var price: Double
    public var limitPrice: Double?
    public var stopPrice: Double?
    public var estimatedFee: Double
    public var source: OrderSource
    public var mode: ExecutionMode

    public init(clientOrderID: String, instrument: Instrument, side: OrderSide, type: OrderType,
                timeInForce: TimeInForce, quantity: Double, price: Double, limitPrice: Double? = nil,
                stopPrice: Double? = nil, estimatedFee: Double, source: OrderSource, mode: ExecutionMode) {
        self.clientOrderID = clientOrderID
        self.instrument = instrument
        self.side = side
        self.type = type
        self.timeInForce = timeInForce
        self.quantity = quantity
        self.price = price
        self.limitPrice = limitPrice
        self.stopPrice = stopPrice
        self.estimatedFee = estimatedFee
        self.source = source
        self.mode = mode
    }

    public var notional: Double { Rounding.money(quantity * price) }
}

/// The agent behind an order, as far as the risk engine cares.
public struct AgentRiskView: Sendable {
    public var id: UUID
    public var name: String
    public var mode: AgentMode
    public var status: AgentStatus
    public var universe: Set<String>
    public var followsLedgerPositions: Bool

    public init(_ agent: TradingAgent) {
        self.id = agent.id
        self.name = agent.name
        self.mode = agent.mode
        self.status = agent.status
        self.universe = Set(agent.spec.universe.map(\.id))
        self.followsLedgerPositions = agent.spec.followsLedgerPositions
    }
}

/// Everything the risk engine reads. The engine fetches nothing itself, so the same
/// inputs always give the same verdict.
public struct RiskContext: Sendable {
    public var now: Date
    public var policy: RiskPolicy
    public var accountPolicy: AccountPolicy
    public var agent: AgentRiskView?
    public var ledger: Ledger
    /// Open orders in this ledger.
    public var openOrders: [Order]
    /// Open orders from other ledgers in the same instrument (to catch agents trading against each other).
    public var otherOpenOrders: [Order]
    /// Every client order id seen so far.
    public var knownClientOrderIDs: Set<String>
    /// Market value held in this instrument across every ledger of the same mode, this ledger included.
    public var accountExposure: Double
    /// Equity across every ledger of the same mode.
    public var accountEquity: Double
    /// Traded today across every ledger of the same mode.
    public var accountNotionalToday: Double
    public var quote: Quote?
    public var rules: InstrumentRules
    public var capabilities: BrokerCapabilities
    /// What the connection being used was actually granted.
    public var grantedPermissions: [BrokerPermission]
    public var marketOpen: Bool
    public var stats: InstrumentStats?

    public init(now: Date, policy: RiskPolicy, accountPolicy: AccountPolicy, agent: AgentRiskView?, ledger: Ledger,
                openOrders: [Order], otherOpenOrders: [Order] = [], knownClientOrderIDs: Set<String>,
                accountExposure: Double, accountEquity: Double, accountNotionalToday: Double, quote: Quote?,
                rules: InstrumentRules, capabilities: BrokerCapabilities, grantedPermissions: [BrokerPermission],
                marketOpen: Bool, stats: InstrumentStats?) {
        self.now = now
        self.policy = policy
        self.accountPolicy = accountPolicy
        self.agent = agent
        self.ledger = ledger
        self.openOrders = openOrders
        self.otherOpenOrders = otherOpenOrders
        self.knownClientOrderIDs = knownClientOrderIDs
        self.accountExposure = accountExposure
        self.accountEquity = accountEquity
        self.accountNotionalToday = accountNotionalToday
        self.quote = quote
        self.rules = rules
        self.capabilities = capabilities
        self.grantedPermissions = grantedPermissions
        self.marketOpen = marketOpen
        self.stats = stats
    }
}

// MARK: - Engine

/// The one gate every order passes, whoever or whatever asked for it. It is plain,
/// deterministic code: no model output is consulted and nothing can skip it.
///
/// Every check runs and reports, so a person sees the whole picture rather than only the
/// first thing that failed. Sells only ever reduce risk here (there is no short selling),
/// so limits that exist to stop risk growing don't block them.
public enum RiskEngine {

    public static func evaluate(_ intent: OrderIntent, context c: RiskContext) -> RiskReport {
        var checks: [RiskCheck] = []
        func add(_ id: RiskCheckID, _ status: RiskCheckStatus, _ detail: String) { checks.append(RiskCheck(id, status, detail)) }

        let isBuy = intent.side == .buy
        // Sizing limits bound what an agent may do. A person trading their own paper
        // portfolio by hand is bound by the hard rules only: funds, holdings, exchange
        // rules, real and fresh prices, and permission.
        let byAgent = intent.source.isAgent
        let manualNote = "An agent's limits don't apply to orders you place yourself."
        let id = intent.instrument.id
        let currency = c.ledger.currency
        func money(_ x: Double) -> String { NumberText.money(x, currency: currency) }

        // 1. Kill switch — stops everything an agent does. A person can still trade by hand.
        if c.accountPolicy.killSwitchEngaged && intent.source.isAgent {
            add(.killSwitch, .failed, "The kill switch is on. No agent can place orders until you turn it off.")
        } else if c.accountPolicy.killSwitchEngaged {
            add(.killSwitch, .warning, "The kill switch is on. Agents are stopped; this manual order is still allowed.")
        } else {
            add(.killSwitch, .passed, "The kill switch is off.")
        }

        // 2. Trading mode and authorisation.
        switch intent.mode {
        case .paper:
            if let agent = c.agent, !agent.mode.placesOrders {
                add(.authorization, .failed, "\(agent.mode.displayName) mode never places orders.")
            } else if let agent = c.agent, agent.mode.isLive {
                add(.authorization, .failed, "A live-mode agent can't send paper orders.")
            } else if c.ledger.mode != .paper {
                add(.authorization, .failed, "A paper order can't be booked to a live account.")
            } else {
                add(.authorization, .passed, "Paper order. No real money is involved.")
            }
        case .live:
            let live = c.accountPolicy.live
            if c.ledger.mode != .live {
                add(.authorization, .failed, "A live order can't be booked to a paper portfolio.")
            } else if let agent = c.agent {
                switch agent.mode {
                case .approvalRequired where live.approvalAgentsEnabled:
                    add(.authorization, .passed, "Live order approved by you.")
                case .autonomousLive where live.autonomousAgentsEnabled:
                    add(.authorization, .passed, "Autonomous live trading is authorised for this agent.")
                default:
                    add(.authorization, .failed, "Live trading isn't enabled for agents in \(agent.mode.displayName) mode.")
                }
            } else if live.manualOrdersEnabled {
                add(.authorization, .passed, "Live order placed by you.")
            } else {
                add(.authorization, .failed, "Live trading isn't enabled.")
            }
        }

        // 3. Agent status.
        if let agent = c.agent {
            if agent.status == .active {
                add(.agentStatus, .passed, "\(agent.name) is running.")
            } else {
                add(.agentStatus, .failed, "\(agent.name) is \(agent.status.rawValue) and can't place orders.")
            }
        } else {
            add(.agentStatus, .notApplicable, "Placed by you, not an agent.")
        }

        // 4. Broker permission and capability.
        let caps = c.capabilities
        if !caps.isExecutionEnabled {
            add(.brokerPermission, .failed, caps.disabledReason ?? "\(caps.displayName) can't place orders.")
        } else if !caps.permissions.contains(.trade) || !c.grantedPermissions.contains(.trade) {
            add(.brokerPermission, .failed, "This connection is read-only. It was never given permission to trade.")
        } else if !caps.supports(intent.instrument) {
            add(.brokerPermission, .failed, "\(caps.displayName) doesn't trade \(intent.instrument.symbol).")
        } else if !caps.orderTypes.contains(intent.type) {
            add(.brokerPermission, .failed, "\(caps.displayName) doesn't accept \(intent.type.displayName.lowercased()) orders.")
        } else if !caps.timeInForce.contains(intent.timeInForce) {
            add(.brokerPermission, .failed, "\(caps.displayName) doesn't accept \"\(intent.timeInForce.displayName)\" orders.")
        } else {
            add(.brokerPermission, .passed, "\(caps.displayName) can trade this order.")
        }

        // 5. Approved universe.
        if let agent = c.agent {
            if agent.followsLedgerPositions {
                if isBuy {
                    add(.universe, .failed, "This agent only manages existing positions and can't open new ones.")
                } else {
                    add(.universe, .passed, "\(intent.instrument.symbol) is a position this agent manages.")
                }
            } else if agent.universe.contains(id) {
                add(.universe, .passed, "\(intent.instrument.symbol) is on this agent's approved list.")
            } else {
                add(.universe, .failed, "\(intent.instrument.symbol) isn't on this agent's approved list.")
            }
        } else {
            add(.universe, .notApplicable, "Manual orders aren't limited to a list.")
        }

        // 6. Currency.
        if intent.instrument.currency == currency {
            add(.currency, .passed, "\(intent.instrument.symbol) trades in \(currency), the same as this portfolio.")
        } else {
            add(.currency, .failed, "\(intent.instrument.symbol) trades in \(intent.instrument.currency) but this portfolio holds \(currency).")
        }

        // 7. Market data must be real.
        var usableQuote: Quote?
        if let quote = c.quote, quote.last > 0, quote.last.isFinite {
            switch quote.provenance.kind {
            case .market:
                usableQuote = quote
                add(.marketData, .passed, "Live quote from \(quote.provenance.source).")
            case .fixture where c.accountPolicy.allowFixtureData:
                usableQuote = quote
                add(.marketData, .passed, "Test fixture quote.")
            case .fixture:
                add(.marketData, .failed, "Test data can't be traded on.")
            case .synthetic:
                add(.marketData, .failed, "This price is not real market data and can't be traded on.")
            }
        } else {
            add(.marketData, .failed, "There is no live quote for \(intent.instrument.symbol).")
        }

        // 8. Market hours.
        var queued = false
        if intent.instrument.venue == .crypto {
            add(.marketHours, .passed, "Crypto trades around the clock.")
        } else if c.marketOpen {
            add(.marketHours, .passed, "The \(intent.instrument.venue.displayName) is open.")
        } else if intent.timeInForce == .ioc || intent.timeInForce == .fok {
            add(.marketHours, .failed, "The \(intent.instrument.venue.displayName) is closed, so an immediate order can't trade.")
        } else if c.policy.allowQueueOutsideHours {
            queued = true
            add(.marketHours, .warning, "The \(intent.instrument.venue.displayName) is closed. The order will wait for the open.")
        } else {
            add(.marketHours, .failed, "The \(intent.instrument.venue.displayName) is closed.")
        }

        // 9. Quote freshness.
        if let quote = usableQuote {
            let age = quote.age(at: c.now)
            let allowed = c.policy.maxQuoteAgeSeconds + Double(quote.provenance.delaySeconds)
            if queued {
                add(.quoteFreshness, .notApplicable, "Market closed: the price is checked again when the order can trade.")
            } else if age < -120 {
                add(.quoteFreshness, .failed, "The quote is dated in the future, so it can't be trusted.")
            } else if age <= allowed {
                add(.quoteFreshness, .passed, "Quote is \(durationText(max(age, 0))) old (limit \(durationText(allowed))).")
            } else {
                add(.quoteFreshness, .failed, "The quote is \(durationText(age)) old; the limit is \(durationText(allowed)).")
            }
        } else {
            add(.quoteFreshness, .failed, "No quote to check.")
        }

        // 10. Exchange rules: precision, minimums, price ticks.
        let r = c.rules
        var ruleProblems: [String] = []
        if !(intent.quantity.isFinite && intent.quantity > 0) { ruleProblems.append("The quantity must be above zero.") }
        if !(intent.price.isFinite && intent.price > 0) { ruleProblems.append("The price must be above zero.") }
        if ruleProblems.isEmpty {
            if !r.fractionable && intent.quantity != intent.quantity.rounded() {
                ruleProblems.append("\(intent.instrument.symbol) trades in whole units only.")
            } else if !Rounding.isMultiple(intent.quantity, of: r.quantityIncrement) {
                ruleProblems.append("The quantity has more decimal places than \(intent.instrument.symbol) allows (step \(Rounding.string(r.quantityIncrement, increment: r.quantityIncrement))).")
            }
            if intent.quantity + 1e-12 < r.minQuantity { ruleProblems.append("The quantity is below the minimum of \(Rounding.string(r.minQuantity, increment: r.quantityIncrement)).") }
            if intent.notional + 1e-9 < r.minNotional { ruleProblems.append("The order is worth \(money(intent.notional)); the minimum is \(money(r.minNotional)).") }
            if intent.type.needsLimitPrice {
                if let limit = intent.limitPrice, limit > 0 {
                    if !Rounding.isMultiple(limit, of: r.priceIncrement) { ruleProblems.append("The limit price must be a multiple of \(Rounding.string(r.priceIncrement, increment: r.priceIncrement)).") }
                } else { ruleProblems.append("A limit price is required.") }
            }
            if intent.type.needsStopPrice {
                if let stop = intent.stopPrice, stop > 0 {
                    if !Rounding.isMultiple(stop, of: r.priceIncrement) { ruleProblems.append("The stop price must be a multiple of \(Rounding.string(r.priceIncrement, increment: r.priceIncrement)).") }
                } else { ruleProblems.append("A stop price is required.") }
            }
        }
        if ruleProblems.isEmpty {
            add(.exchangeRules, .passed, "Quantity and price fit the exchange's rules.")
        } else {
            add(.exchangeRules, .failed, ruleProblems.joined(separator: " "))
        }

        let notional = intent.notional
        let equity = c.ledger.equity
        let held = c.ledger.position(id)
        let reservedCash = c.openOrders.filter { $0.side == .buy }
            .reduce(0.0) { $0 + $1.remainingQuantity * ($1.limitPrice ?? $1.referencePrice) }
        let reservedUnits = c.openOrders.filter { $0.side == .sell && $0.instrument.id == id }
            .reduce(0.0) { $0 + $1.remainingQuantity }

        // 11. Order size.
        if !isBuy {
            add(.orderValue, .notApplicable, "Sells reduce risk and aren't capped by order size.")
        } else if !byAgent {
            add(.orderValue, .notApplicable, manualNote)
        } else if notional <= c.policy.maxOrderNotional + 0.005 {
            add(.orderValue, .passed, "\(money(notional)) is within the \(money(c.policy.maxOrderNotional)) order limit.")
        } else {
            add(.orderValue, .failed, "\(money(notional)) is over the \(money(c.policy.maxOrderNotional)) order limit.")
        }

        // 12. Buying power / 13. holdings. No borrowing and no short selling.
        if isBuy {
            let available = c.ledger.cash - reservedCash
            let needed = notional + intent.estimatedFee
            if needed <= available + 0.005 {
                add(.buyingPower, .passed, "Needs \(money(needed)); \(money(max(available, 0))) is available.")
            } else {
                add(.buyingPower, .failed, "Needs \(money(needed)) but only \(money(max(available, 0))) is available.")
            }
            add(.holdings, .notApplicable, "Not a sell.")
        } else {
            add(.buyingPower, .notApplicable, "Not a buy.")
            let available = (held?.quantity ?? 0) - reservedUnits
            if intent.quantity <= available + r.quantityIncrement * 1e-3 {
                add(.holdings, .passed, "Selling \(quantityText(intent.quantity, r)) of \(quantityText(max(available, 0), r)) held.")
            } else if available <= 0 {
                add(.holdings, .failed, "There is no \(intent.instrument.symbol) available to sell. Short selling is not allowed.")
            } else {
                add(.holdings, .failed, "Only \(quantityText(available, r)) \(intent.instrument.symbol) is available to sell. Short selling is not allowed.")
            }
        }

        // 14. Position limit.
        if isBuy && !byAgent {
            add(.positionLimit, .notApplicable, manualNote)
        } else if isBuy {
            let after = (held?.marketValue ?? 0) + notional
            let pct = equity > 0 ? after / equity * 100 : 100
            if pct <= c.policy.maxPositionPct + 0.01 {
                add(.positionLimit, .passed, "\(intent.instrument.symbol) would be \(percentText(pct)) of this portfolio (limit \(percentText(c.policy.maxPositionPct))).")
            } else {
                add(.positionLimit, .failed, "\(intent.instrument.symbol) would be \(percentText(pct)) of this portfolio; the limit is \(percentText(c.policy.maxPositionPct)).")
            }
        } else {
            add(.positionLimit, .notApplicable, "Sells reduce the position.")
        }

        // 15. Concentration across every portfolio and agent.
        if isBuy {
            let after = c.accountExposure + notional
            let pct = c.accountEquity > 0 ? after / c.accountEquity * 100 : 100
            if pct <= c.accountPolicy.maxSymbolExposurePct + 0.01 {
                add(.concentration, .passed, "Across all portfolios \(intent.instrument.symbol) would be \(percentText(pct)) (limit \(percentText(c.accountPolicy.maxSymbolExposurePct))).")
            } else {
                add(.concentration, byAgent ? .failed : .warning, "Across all portfolios \(intent.instrument.symbol) would be \(percentText(pct)); the limit is \(percentText(c.accountPolicy.maxSymbolExposurePct)).")
            }
        } else {
            add(.concentration, .notApplicable, "Sells reduce concentration.")
        }

        // 16. Open positions.
        if isBuy && !byAgent {
            add(.openPositions, .notApplicable, manualNote)
        } else if isBuy, held == nil {
            let count = c.ledger.positions.count
            if count < c.policy.maxOpenPositions {
                add(.openPositions, .passed, "\(count) of \(c.policy.maxOpenPositions) positions are open.")
            } else {
                add(.openPositions, .failed, "\(count) positions are already open; the limit is \(c.policy.maxOpenPositions).")
            }
        } else {
            add(.openPositions, .notApplicable, isBuy ? "Adds to an existing position." : "Sells don't open positions.")
        }

        // 17. Daily trading limits.
        if isBuy && !byAgent {
            add(.dailyNotional, .notApplicable, manualNote)
        } else if isBuy {
            let ledgerAfter = c.ledger.notionalToday + notional
            let accountAfter = c.accountNotionalToday + notional
            if ledgerAfter > c.policy.maxDailyNotional + 0.005 {
                add(.dailyNotional, .failed, "This would bring today's trading to \(money(ledgerAfter)); the daily limit is \(money(c.policy.maxDailyNotional)).")
            } else if accountAfter > c.accountPolicy.maxTotalDailyNotional + 0.005 {
                add(.dailyNotional, .failed, "This would bring today's trading across all portfolios to \(money(accountAfter)); the limit is \(money(c.accountPolicy.maxTotalDailyNotional)).")
            } else {
                add(.dailyNotional, .passed, "Today's trading would be \(money(ledgerAfter)) of \(money(c.policy.maxDailyNotional)).")
            }
        } else {
            add(.dailyNotional, .notApplicable, "Sells aren't held back by the daily limit.")
        }

        // 18. Daily loss.
        if isBuy && !byAgent {
            add(.dailyLoss, .notApplicable, manualNote)
        } else if isBuy {
            let lossPct = c.ledger.dayStartEquity > 0 ? max(0, -c.ledger.realizedToday) / c.ledger.dayStartEquity * 100 : 0
            if lossPct < c.policy.maxDailyLossPct {
                add(.dailyLoss, .passed, "Today's realised loss is \(percentText(lossPct)) (limit \(percentText(c.policy.maxDailyLossPct))).")
            } else {
                add(.dailyLoss, .failed, "Today's realised loss is \(percentText(lossPct)), at the \(percentText(c.policy.maxDailyLossPct)) daily limit. No new buys today.")
            }
        } else {
            add(.dailyLoss, .notApplicable, "Sells are always allowed.")
        }

        // 19. Drawdown.
        if isBuy && !byAgent {
            add(.drawdown, .notApplicable, manualNote)
        } else if isBuy {
            let drawdown = c.ledger.drawdownPct
            if drawdown < c.policy.maxDrawdownPct {
                add(.drawdown, .passed, "The portfolio is \(percentText(drawdown)) below its peak (limit \(percentText(c.policy.maxDrawdownPct))).")
            } else {
                add(.drawdown, .failed, "The portfolio is \(percentText(drawdown)) below its peak, at the \(percentText(c.policy.maxDrawdownPct)) limit. No new buys.")
            }
        } else {
            add(.drawdown, .notApplicable, "Sells are always allowed.")
        }

        // 20. Spread.
        if let quote = usableQuote {
            if queued {
                add(.spread, .notApplicable, "Market closed: there is no live spread to check.")
            } else if let spread = quote.spreadBps {
                if spread <= c.policy.maxSpreadBps {
                    add(.spread, .passed, String(format: "The spread is %.0f bps (limit %.0f).", spread, c.policy.maxSpreadBps))
                } else {
                    add(.spread, isBuy ? .failed : .warning, String(format: "The spread is %.0f bps, wider than the %.0f bps limit.", spread, c.policy.maxSpreadBps))
                }
            } else {
                add(.spread, .warning, "The feed has no bid and ask, so the spread can't be measured. A modelled spread is used.")
            }
        } else {
            add(.spread, .notApplicable, "No quote.")
        }

        // 21. Liquidity / 22. volatility, from real daily bars.
        if let stats = c.stats {
            if stats.averageDollarVolume >= c.policy.minAverageDollarVolume {
                add(.liquidity, .passed, "About \(compactText(stats.averageDollarVolume)) trades a day.")
            } else {
                add(.liquidity, isBuy && byAgent ? .failed : .warning, "Only about \(compactText(stats.averageDollarVolume)) trades a day; the minimum is \(compactText(c.policy.minAverageDollarVolume)).")
            }
            if !isBuy {
                add(.volatility, .notApplicable, "Sells are always allowed.")
            } else if stats.dailyVolatilityPct <= c.policy.maxDailyVolatilityPct {
                add(.volatility, .passed, String(format: "Daily volatility is %.1f%% (limit %.1f%%).", stats.dailyVolatilityPct, c.policy.maxDailyVolatilityPct))
            } else {
                add(.volatility, byAgent ? .failed : .warning, String(format: "Daily volatility is %.1f%%, above the %.1f%% limit.", stats.dailyVolatilityPct, c.policy.maxDailyVolatilityPct))
            }
        } else {
            let status: RiskCheckStatus = byAgent && isBuy ? .failed : .warning
            add(.liquidity, status, "Liquidity couldn't be measured for \(intent.instrument.symbol).")
            add(.volatility, status, "Volatility couldn't be measured for \(intent.instrument.symbol).")
        }

        // 23. Duplicates and agents trading against each other.
        if c.knownClientOrderIDs.contains(intent.clientOrderID) {
            add(.duplicate, .failed, "This order was already submitted.")
        } else if intent.source.isAgent,
                  c.openOrders.contains(where: { $0.instrument.id == id && $0.side == intent.side && $0.source.agentID == intent.source.agentID }) {
            add(.duplicate, .failed, "This agent already has an open \(intent.side.rawValue) order for \(intent.instrument.symbol).")
        } else if intent.source.isAgent,
                  let other = c.otherOpenOrders.first(where: { $0.instrument.id == id && $0.side != intent.side && $0.source.isAgent }) {
            add(.duplicate, .failed, "Another agent has an open \(other.side.rawValue) order for \(intent.instrument.symbol). Two agents can't trade against each other.")
        } else {
            add(.duplicate, .passed, "No duplicate or conflicting order.")
        }

        // 24. Cooldown.
        if isBuy, intent.source.isAgent, c.policy.cooldownSeconds > 0, let last = c.ledger.lastFillAt[id] {
            let since = c.now.timeIntervalSince(last)
            if since >= c.policy.cooldownSeconds {
                add(.cooldown, .passed, "Last traded \(durationText(since)) ago.")
            } else {
                add(.cooldown, .failed, "\(intent.instrument.symbol) traded \(durationText(max(since, 0))) ago. Wait \(durationText(c.policy.cooldownSeconds - since)) more.")
            }
        } else {
            add(.cooldown, .notApplicable, isBuy ? "No recent trade in this asset." : "Sells are always allowed.")
        }

        return RiskReport(checks: checks, evaluatedAt: c.now)
    }

    // MARK: Text

    static func percentText(_ x: Double) -> String { String(format: "%.1f%%", x) }

    static func quantityText(_ x: Double, _ rules: InstrumentRules) -> String {
        let text = Rounding.string(x, increment: rules.quantityIncrement)
        guard text.contains(".") else { return text }
        var trimmed = text
        while trimmed.hasSuffix("0") { trimmed.removeLast() }
        if trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed
    }

    static func durationText(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 90 { return "\(s)s" }
        if s < 5_400 { return "\(Int((Double(s) / 60).rounded())) min" }
        if s < 172_800 { return "\(Int((Double(s) / 3_600).rounded())) h" }
        return "\(Int((Double(s) / 86_400).rounded())) days"
    }

    static func compactText(_ x: Double) -> String {
        if x >= 1_000_000_000 { return String(format: "%.1fB", x / 1_000_000_000) }
        if x >= 1_000_000 { return String(format: "%.1fM", x / 1_000_000) }
        if x >= 1_000 { return String(format: "%.0fK", x / 1_000) }
        return String(format: "%.0f", x)
    }
}
