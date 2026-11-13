//
//  TradingAgentCore.swift
//  Stock Tracker
//
//  Offline, rules-based paper trading domain. No network calls or live brokerage orders.
//

import Foundation

enum TradingStrategy: String, CaseIterable, Codable, Identifiable {
    case trend = "Trend Following"
    case dip = "Buy the Dip"

    var id: String { rawValue }

    var details: String {
        switch self {
        case .trend: return "Compare five-day and twenty-day price averages."
        case .dip: return "Look for a price at least 3% below its twenty-day average."
        }
    }
}

enum TradingSide: String, Codable {
    case buy = "Buy"
    case sell = "Sell"
}

enum TradingProposalStatus: String, Codable {
    case pending, rejected, filled, expired
}

struct TradingAgent: Identifiable, Codable {
    let id: UUID
    var name: String
    var strategy: TradingStrategy
    var symbols: [String]
    var maxOrderUSD: Double
    var maxDailyNotionalUSD: Double
    var maxPositionFraction: Double
    var isPaused: Bool

    init(
        id: UUID = UUID(),
        name: String,
        strategy: TradingStrategy,
        symbols: [String],
        maxOrderUSD: Double = 500,
        maxDailyNotionalUSD: Double = 1_500,
        maxPositionFraction: Double = 0.25,
        isPaused: Bool = false
    ) {
        self.id = id
        self.name = name
        self.strategy = strategy
        self.symbols = symbols
        self.maxOrderUSD = maxOrderUSD
        self.maxDailyNotionalUSD = maxDailyNotionalUSD
        self.maxPositionFraction = maxPositionFraction
        self.isPaused = isPaused
    }
}

struct TradingProposal: Identifiable, Codable {
    let id: UUID
    let agentID: UUID
    let symbol: String
    let side: TradingSide
    let shares: Int
    let referencePriceUSD: Double
    let marketDataDate: Date
    let rationale: String
    let createdAt: Date
    var status: TradingProposalStatus
    var resolvedAt: Date?

    var notionalUSD: Double { Double(shares) * referencePriceUSD }

    init(
        id: UUID = UUID(), agentID: UUID, symbol: String, side: TradingSide,
        shares: Int, referencePriceUSD: Double, marketDataDate: Date,
        rationale: String = "", createdAt: Date = Date(),
        status: TradingProposalStatus = .pending, resolvedAt: Date? = nil
    ) {
        self.id = id
        self.agentID = agentID
        self.symbol = symbol
        self.side = side
        self.shares = shares
        self.referencePriceUSD = referencePriceUSD
        self.marketDataDate = marketDataDate
        self.rationale = rationale
        self.createdAt = createdAt
        self.status = status
        self.resolvedAt = resolvedAt
    }
}

struct PaperTradingPosition: Identifiable, Codable {
    var symbol: String
    var shares: Int
    var averageCostUSD: Double
    var lastMarkedPriceUSD: Double

    var id: String { symbol }
    var marketValueUSD: Double { Double(shares) * lastMarkedPriceUSD }
    var unrealisedPnLUSD: Double { Double(shares) * (lastMarkedPriceUSD - averageCostUSD) }
}

struct PaperTradingFill: Identifiable, Codable {
    let id: UUID
    let proposalID: UUID
    let agentID: UUID
    let symbol: String
    let side: TradingSide
    let shares: Int
    let simulatedPriceUSD: Double
    let filledAt: Date

    var notionalUSD: Double { Double(shares) * simulatedPriceUSD }
}

struct TradingSignal {
    let side: TradingSide
    let details: String
}

enum TradingSignalEngine {
    /// Historical closes must be real, chronologically ordered daily market data.
    /// This does not take synthetic chart fallbacks as input.
    static func evaluate(strategy: TradingStrategy, prices: [Double]) -> TradingSignal? {
        guard prices.count >= 25,
              prices.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }

        let latest = prices[prices.count - 1]
        let shortMean = prices.suffix(5).reduce(0, +) / 5
        let longMean = prices.suffix(20).reduce(0, +) / 20

        switch strategy {
        case .trend:
            if shortMean >= longMean * 1.005 && latest >= shortMean {
                return TradingSignal(
                    side: .buy,
                    details: "Uptrend: 5-day average $\(shortMean.usd2) is above 20-day average $\(longMean.usd2); last close $\(latest.usd2)."
                )
            }
            if shortMean <= longMean * 0.995 && latest <= shortMean {
                return TradingSignal(
                    side: .sell,
                    details: "Downtrend: 5-day average $\(shortMean.usd2) is below 20-day average $\(longMean.usd2); last close $\(latest.usd2)."
                )
            }
        case .dip:
            if latest <= longMean * 0.97 {
                return TradingSignal(
                    side: .buy,
                    details: "Dip: last close $\(latest.usd2) is at least 3% below its 20-day average of $\(longMean.usd2)."
                )
            }
            if latest >= longMean * 1.03 {
                return TradingSignal(
                    side: .sell,
                    details: "Recovery: last close $\(latest.usd2) is at least 3% above its 20-day average of $\(longMean.usd2)."
                )
            }
        }
        return nil
    }
}

enum PaperTradingError: LocalizedError {
    case tradingHalted
    case agentPaused
    case agentMissing
    case proposalMissing
    case proposalNotPending
    case proposalStale
    case dataStale
    case invalidOrder
    case outsideUniverse
    case excessiveOrder
    case dailyLimit
    case insufficientCash
    case positionLimit
    case insufficientShares

    var errorDescription: String? {
        switch self {
        case .tradingHalted: return "Paper trading is paused by the kill switch."
        case .agentPaused: return "This agent is paused."
        case .agentMissing: return "The trading agent no longer exists."
        case .proposalMissing: return "The proposal was not found."
        case .proposalNotPending: return "The proposal has already been resolved."
        case .proposalStale: return "The proposal expired. Run a fresh market scan."
        case .dataStale: return "The market data is too old. Run a fresh market scan."
        case .invalidOrder: return "The simulated order is invalid."
        case .outsideUniverse: return "The symbol is not permitted for this agent."
        case .excessiveOrder: return "This order exceeds the agent's maximum order value."
        case .dailyLimit: return "The agent's daily simulated trading limit would be exceeded."
        case .insufficientCash: return "Not enough simulated cash is available."
        case .positionLimit: return "The position would exceed the agent's allocation limit."
        case .insufficientShares: return "Insufficient simulated shares. Short selling is disabled."
        }
    }
}

struct PaperTradingLedger: Codable {
    var startingCashUSD: Double = 10_000
    var cashUSD: Double = 10_000
    var tradingEnabled = true
    var agents: [TradingAgent] = [
        TradingAgent(name: "Trend Scout", strategy: .trend, symbols: ["AAPL", "MSFT", "NVDA"]),
        TradingAgent(name: "Dip Watcher", strategy: .dip, symbols: ["SPY", "QQQ"])
    ]
    var proposals: [TradingProposal] = []
    var positions: [PaperTradingPosition] = []
    var fills: [PaperTradingFill] = []

    var totalEquityUSD: Double {
        cashUSD + positions.reduce(0) { $0 + $1.marketValueUSD }
    }

    func validate(_ proposal: TradingProposal, now: Date = Date()) throws {
        guard tradingEnabled else { throw PaperTradingError.tradingHalted }
        guard let agent = agents.first(where: { $0.id == proposal.agentID }) else {
            throw PaperTradingError.agentMissing
        }
        guard !agent.isPaused else { throw PaperTradingError.agentPaused }
        guard proposal.status == .pending else { throw PaperTradingError.proposalNotPending }
        guard proposal.createdAt <= now,
              now.timeIntervalSince(proposal.createdAt) <= 86_400 else {
            throw PaperTradingError.proposalStale
        }
        guard proposal.marketDataDate <= now,
              now.timeIntervalSince(proposal.marketDataDate) <= 7 * 86_400 else {
            throw PaperTradingError.dataStale
        }
        guard proposal.shares > 0, proposal.referencePriceUSD.isFinite,
              proposal.referencePriceUSD > 0, proposal.notionalUSD.isFinite else {
            throw PaperTradingError.invalidOrder
        }
        guard agent.symbols.contains(proposal.symbol) else { throw PaperTradingError.outsideUniverse }
        guard proposal.notionalUSD <= agent.maxOrderUSD + 0.001 else {
            throw PaperTradingError.excessiveOrder
        }
        let spentToday = fills.filter {
            $0.agentID == agent.id && Calendar.current.isDate($0.filledAt, inSameDayAs: now)
        }.reduce(0) { $0 + $1.notionalUSD }
        guard spentToday + proposal.notionalUSD <= agent.maxDailyNotionalUSD + 0.001 else {
            throw PaperTradingError.dailyLimit
        }

        let existing = positions.first(where: { $0.symbol == proposal.symbol })
        switch proposal.side {
        case .buy:
            guard cashUSD >= proposal.notionalUSD else { throw PaperTradingError.insufficientCash }
            // One position per symbol; no uncontrolled accumulation from repeated scans.
            guard existing == nil else { throw PaperTradingError.positionLimit }
            let projectedEquity = totalEquityUSD
            guard projectedEquity > 0,
                  proposal.notionalUSD / projectedEquity <= agent.maxPositionFraction + 0.0001 else {
                throw PaperTradingError.positionLimit
            }
        case .sell:
            guard let existing, existing.shares >= proposal.shares else {
                throw PaperTradingError.insufficientShares
            }
        }
    }

    /// Fills at the historical reference price. This is a local simulation, not an exchange order.
    @discardableResult
    mutating func executePaperOrder(proposalID: UUID, now: Date = Date()) throws -> PaperTradingFill {
        guard let index = proposals.firstIndex(where: { $0.id == proposalID }) else {
            throw PaperTradingError.proposalMissing
        }
        let proposal = proposals[index]
        try validate(proposal, now: now)

        let amount = proposal.notionalUSD
        switch proposal.side {
        case .buy:
            cashUSD -= amount
            positions.append(PaperTradingPosition(
                symbol: proposal.symbol,
                shares: proposal.shares,
                averageCostUSD: proposal.referencePriceUSD,
                lastMarkedPriceUSD: proposal.referencePriceUSD
            ))
        case .sell:
            guard let positionIndex = positions.firstIndex(where: { $0.symbol == proposal.symbol }) else {
                throw PaperTradingError.insufficientShares
            }
            cashUSD += amount
            positions[positionIndex].shares -= proposal.shares
            positions[positionIndex].lastMarkedPriceUSD = proposal.referencePriceUSD
            if positions[positionIndex].shares == 0 { positions.remove(at: positionIndex) }
        }

        proposals[index].status = .filled
        proposals[index].resolvedAt = now
        let fill = PaperTradingFill(
            id: UUID(), proposalID: proposal.id, agentID: proposal.agentID,
            symbol: proposal.symbol, side: proposal.side, shares: proposal.shares,
            simulatedPriceUSD: proposal.referencePriceUSD, filledAt: now
        )
        fills.insert(fill, at: 0)
        return fill
    }
}

private extension Double {
    var usd2: String { String(format: "%.2f", self) }
}
