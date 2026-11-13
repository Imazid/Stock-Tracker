//
//  TradingAgentStore.swift
//  Stock Tracker
//
//  Runs market scans on explicit user request. All execution remains local paper trading.
//

import Foundation
import Combine

@MainActor
final class TradingAgentStore: ObservableObject {
    @Published private(set) var ledger: PaperTradingLedger
    @Published private(set) var isScanning = false
    @Published var statusMessage: String?

    private let storageKey = "agent_paper_workspace_v1"

    init() {
        if let data = KeychainManager.shared.retrieveData(key: storageKey),
           let saved = try? JSONDecoder().decode(PaperTradingLedger.self, from: data),
           saved.cashUSD.isFinite, saved.cashUSD >= 0 {
            ledger = saved
        } else {
            ledger = PaperTradingLedger()
        }
        expireOldProposals()
    }

    func setTradingEnabled(_ enabled: Bool) {
        ledger.tradingEnabled = enabled
        persist()
    }

    func toggleAgent(_ id: UUID) {
        guard let index = ledger.agents.firstIndex(where: { $0.id == id }) else { return }
        ledger.agents[index].isPaused.toggle()
        persist()
    }

    @discardableResult
    func createAgent(name: String, strategy: TradingStrategy, symbolsText: String, orderBudgetUSD: Double) -> Bool {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = symbolsText.uppercased()
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map(String.init)
        var symbols: [String] = []
        for symbol in candidates where !symbols.contains(symbol) {
            symbols.append(symbol)
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")

        guard !cleanName.isEmpty, cleanName.count <= 40,
              (1...10).contains(symbols.count),
              symbols.allSatisfy({
                  (1...12).contains($0.count) && $0.unicodeScalars.allSatisfy(allowed.contains)
              }),
              orderBudgetUSD.isFinite, (25...2_000).contains(orderBudgetUSD) else {
            statusMessage = "Enter a name, up to 10 valid US tickers and a $25–$2,000 paper order budget."
            return false
        }

        let agent = TradingAgent(
            name: cleanName,
            strategy: strategy,
            symbols: symbols,
            maxOrderUSD: orderBudgetUSD,
            maxDailyNotionalUSD: max(500, 3 * orderBudgetUSD)
        )
        ledger.agents.append(agent)
        persist()
        statusMessage = "Agent created. Run Scan to generate paper trade proposals."
        return true
    }

    func rejectProposal(_ id: UUID) {
        guard let index = ledger.proposals.firstIndex(where: { $0.id == id && $0.status == .pending }) else {
            return
        }
        ledger.proposals[index].status = .rejected
        ledger.proposals[index].resolvedAt = Date()
        persist()
        statusMessage = "Paper trade proposal rejected."
    }

    func approvePaperTrade(_ id: UUID) {
        expireOldProposals()
        do {
            let fill = try ledger.executePaperOrder(proposalID: id)
            persist()
            statusMessage = "Simulated \(fill.side.rawValue.lowercased()) of \(fill.shares) \(fill.symbol) shares recorded. No broker order was sent."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func scanAgent(_ id: UUID) async {
        guard !isScanning else { return }
        guard ledger.tradingEnabled else {
            statusMessage = "Paper trading is halted. Turn it on to run a scan."
            return
        }
        guard let agent = ledger.agents.first(where: { $0.id == id }), !agent.isPaused else {
            statusMessage = "Agent unavailable or paused."
            return
        }

        isScanning = true
        statusMessage = "Scanning real historical daily prices."
        defer { isScanning = false }

        expireOldProposals()
        var proposed = 0
        var noSignal = 0
        var unavailable = 0

        for symbol in agent.symbols {
            do {
                // Uses the existing Alpaca US market-data service directly. Unlike chart
                // helpers, this throws on API failure: no synthetic prices enter trading.
                let history = try await APIService.shared.fetchHistoricalData(
                    symbol: symbol, range: .threeMonths
                )
                let sorted = history.sorted { $0.date < $1.date }
                    .filter { $0.price.isFinite && $0.price >= 0.01 }
                guard let last = sorted.last, sorted.count >= 25,
                      last.date <= Date(),
                      Date().timeIntervalSince(last.date) <= 7 * 86_400 else {
                    unavailable += 1
                    continue
                }

                if let index = ledger.positions.firstIndex(where: { $0.symbol == symbol }) {
                    ledger.positions[index].lastMarkedPriceUSD = last.price
                }
                guard let signal = TradingSignalEngine.evaluate(
                    strategy: agent.strategy, prices: sorted.map(\.price)
                ) else {
                    noSignal += 1
                    continue
                }

                // Do not create overlapping proposals or trade repeatedly on a stale signal.
                let existingPending = ledger.proposals.contains {
                    $0.symbol == symbol && $0.status == .pending
                }
                let recentlyFilled = ledger.fills.contains {
                    $0.symbol == symbol && Date().timeIntervalSince($0.filledAt) < 86_400
                }
                guard !existingPending && !recentlyFilled else {
                    noSignal += 1
                    continue
                }

                let heldShares = ledger.positions.first(where: { $0.symbol == symbol })?.shares ?? 0
                let affordableShares = Int(floor(min(agent.maxOrderUSD, ledger.cashUSD) / last.price))
                let maxOrderShares = Int(floor(agent.maxOrderUSD / last.price))
                let shares: Int
                switch signal.side {
                case .buy:
                    guard heldShares == 0 else { noSignal += 1; continue }
                    shares = max(0, affordableShares)
                case .sell:
                    guard heldShares > 0 else { noSignal += 1; continue }
                    shares = min(heldShares, max(0, maxOrderShares))
                }
                guard shares > 0 else { noSignal += 1; continue }

                let candidate = TradingProposal(
                    agentID: agent.id,
                    symbol: symbol,
                    side: signal.side,
                    shares: shares,
                    referencePriceUSD: last.price,
                    marketDataDate: last.date,
                    rationale: signal.details
                )
                do {
                    try ledger.validate(candidate)
                    ledger.proposals.insert(candidate, at: 0)
                    proposed += 1
                } catch {
                    noSignal += 1 // Risk gate has rejected this candidate; no proposal.
                }
            } catch {
                unavailable += 1 // No trading from missing market data.
            }
        }

        persist()
        statusMessage = "Scan complete: \(proposed) paper proposals, \(noSignal) without an eligible signal, \(unavailable) unavailable price histories."
    }

    private func expireOldProposals() {
        let now = Date()
        for index in ledger.proposals.indices {
            if ledger.proposals[index].status == .pending &&
                now.timeIntervalSince(ledger.proposals[index].createdAt) > 86_400 {
                ledger.proposals[index].status = .expired
                ledger.proposals[index].resolvedAt = now
            }
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(ledger) else {
            statusMessage = "Paper workspace could not be encoded."
            return
        }
        if !KeychainManager.shared.saveData(key: storageKey, value: data) {
            statusMessage = "Could not save paper trading data securely."
        }
    }
}
