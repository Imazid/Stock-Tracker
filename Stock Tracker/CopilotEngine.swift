//
//  CopilotEngine.swift
//  Stock Tracker
//
//  The copilot's brain: a fixed set of tools over the app's own data.
//
//  How a request is handled:
//    1. Fixed rules look for a known request ("show my pending trades", "why did
//       my agent stop", "reduce its allocation to 5%"). No model is involved, so
//       the common requests work offline and always behave the same way.
//    2. Otherwise a language model is asked either to pick one of the same tools
//       or to answer in words, given a small summary of the portfolio and agents.
//
//  Boundaries that hold either way:
//    - A tool can read, compute, or prepare a change. Nothing the copilot does
//      changes money, orders or limits by itself: a change is shown as a card
//      and only happens when the person confirms it, through the same store
//      methods (and the same risk engine) as every other screen.
//    - The model never sees credentials and has no tool that places an order.
//    - Numbers shown in cards come from the app's data, not from the model.
//      Model-written text is marked as AI-generated.
//

import Foundation
import Combine
import TradingCore

enum CopilotCard: Identifiable {
    case facts(id: UUID, title: String, facts: [Evidence], footnote: String)
    case orders(id: UUID, proposals: [UUID], orders: [UUID])
    case run(id: UUID, agentID: UUID, runID: UUID)
    case draft(id: UUID, parsed: ParsedAgentRequest)
    case limitChange(id: UUID, agentID: UUID, lines: [String], policy: RiskPolicy, loosens: Bool)
    case backtest(id: UUID, box: BacktestBox)
    case agentChoice(id: UUID, request: String, agentIDs: [UUID])
    case portfolioMovement(id: UUID, report: PortfolioMovementReport)
    case unifiedAllocation(id: UUID)
    case privateUpdates(id: UUID, response: PrivateUpdatesAnswer)
    case privateComparison(id: UUID, question: String)
    case privateScenario(id: UUID, question: PrivateScenarioQuestion)
    case pauseAll(id: UUID)

    var id: UUID {
        switch self {
        case .facts(let id, _, _, _), .orders(let id, _, _), .run(let id, _, _), .draft(let id, _),
             .limitChange(let id, _, _, _, _), .backtest(let id, _), .agentChoice(let id, _, _),
             .portfolioMovement(let id, _), .unifiedAllocation(let id), .privateUpdates(let id, _),
             .privateComparison(let id, _), .privateScenario(let id, _), .pauseAll(let id):
            return id
        }
    }
}

struct CopilotMessage: Identifiable {
    let id = UUID()
    var isUser: Bool
    var text: String
    var cards: [CopilotCard] = []
    /// True when the text was written by a language model rather than assembled from data.
    var aiGenerated = false
}

struct PrivateUpdatesAnswer {
    let owner: UUID
    let scope: PrivateUpdateScope
    let updates: [PrivateCompanyUpdate]
    let report: PrivateResearchReport?
    var notice: String?
}

@MainActor
final class CopilotEngine: ObservableObject {
    @Published private(set) var messages: [CopilotMessage] = []
    @Published private(set) var isWorking = false
    /// Card ids whose change has been confirmed or dismissed, so they can't be applied twice.
    @Published private(set) var resolvedCards: [UUID: String] = [:]

    private let trading: TradingStore
    private weak var marketData: MarketData?
    private let privateMarkets: PrivateMarketsStore
    private let auth: SupabaseAuthManager
    private let ai = AIAgentService()
    /// Whether free-form questions may be sent to a language model (plan and daily limit).
    var canUseModel: () -> Bool = { false }
    var didUseModel: () -> Void = {}

    static let portfolioMovementPrompt = "Why did my portfolio move?"
    static let concentrationPrompt = "Analyse my portfolio concentration"

    static let suggestions = [
        portfolioMovementPrompt,
        "Show me all my pending trades",
        concentrationPrompt,
        "Show my private investment exposure alongside my listed stocks",
        "Summarise recent updates from the startups I own",
        "Compare startup valuations and explain their assumptions",
        "Why did my agent stop trading?",
        "Create a paper-trading strategy for BTC and ETH",
        "Backtest my strategy over the last two years",
        "Reduce my agent's maximum allocation to 5%"
    ]

    init(trading: TradingStore, marketData: MarketData?, privateMarkets: PrivateMarketsStore, auth: SupabaseAuthManager) {
        self.trading = trading
        self.marketData = marketData
        self.privateMarkets = privateMarkets
        self.auth = auth
    }

    // MARK: - Entry

    func send(_ raw: String) async {
        let text = InputSanitizer.sanitizeForAPI(raw)
        guard !text.isEmpty, !isWorking else { return }
        messages.append(CopilotMessage(isUser: true, text: text))
        isWorking = true
        defer { isWorking = false }

        if let reply = await routeByRules(text) {
            messages.append(reply)
            return
        }
        messages.append(await routeByModel(text))
    }

    /// Runs a request again now that the person has said which agent they meant.
    func choose(agentID: UUID, for request: String, card: UUID) async {
        resolvedCards[card] = trading.agent(agentID)?.name ?? "Chosen"
        isWorking = true
        defer { isWorking = false }
        if let reply = await routeByRules(request, forcedAgent: agentID) { messages.append(reply) }
    }

    /// Applies a limit change the person confirmed. Goes through the store like any edit.
    func confirmLimitChange(card: UUID, agentID: UUID, policy: RiskPolicy) async {
        guard resolvedCards[card] == nil else { return }
        resolvedCards[card] = "Applying…"
        do {
            try await trading.updateRiskPolicy(agentID: agentID, policy: policy, actor: .copilot)
            resolvedCards[card] = "Applied"
            messages.append(CopilotMessage(isUser: false, text: "Done. The new limits apply from the agent's next order, and the change is in the audit trail."))
        } catch {
            resolvedCards[card] = "Not applied"
            messages.append(CopilotMessage(isUser: false, text: "That couldn't be applied: \(error.localizedDescription)"))
        }
    }

    func dismiss(card: UUID) { resolvedCards[card] = "Cancelled" }

    // MARK: - Rules

    private func routeByRules(_ text: String, forcedAgent: UUID? = nil) async -> CopilotMessage? {
        let lower = text.lowercased()
        func has(_ words: String...) -> Bool { words.contains { lower.contains($0) } }

        if has("private market", "private investment", "private asset", "private holding", "private equity") &&
            has("exposure", "allocation", "concentration", "alongside") &&
            !has("reduce", "set ", "change", "lower", "raise", "increase") {
            return CopilotMessage(isUser: false, text: "Here’s the allocation across your tracked listed and private holdings.",
                                  cards: [.unifiedAllocation(id: UUID())])
        }
        if has("pause all", "pause everything", "stop everything", "stop all", "kill switch", "emergency") {
            return CopilotMessage(isUser: false, text: trading.isKillSwitchOn
                                  ? "Pause-all is already on. No agent can place orders."
                                  : "I can't pause agents for you, but this opens the control. It shows exactly what stops before you confirm.",
                                  cards: [.pauseAll(id: UUID())])
        }
        if has("compare", " vs ", " versus ") &&
            (has("funding round", "financing round") || has("valuation", "raised") && has("startup", "private", "seed", "series ")) {
            return .init(isUser: false, text: "Select the published rounds you want to compare.",
                         cards: [.privateComparison(id: UUID(), question: String(text.prefix(700)))])
        }
        if let question = PrivateScenarioQuestion(text) {
            let reply: String
            if question.calculatesDilution {
                reply = "In a priced round, new investors take the fraction raised divided by the post-money valuation. Existing holders keep the remaining fraction of their previous stake when they don’t participate."
            } else {
                reply = "Ownership in a priced round is the investment amount divided by the post-money valuation."
            }
            return CopilotMessage(isUser: false, text: reply, cards: [.privateScenario(id: UUID(), question: question)])
        }
        if has("update", "announcement", "news", "funding round", "what changed") &&
            has("startup", "private compan", "portfolio compan", "private market", "private investment") &&
            has("my ", "i own", "i hold", "i invested in", "i follow", "portfolio compan", "watchlist", "companies i") &&
            !has("draft ", "email ", "write ", "send ", "turn off", "turn on") {
            let scope: PrivateUpdateScope
            if has("i own", "i hold", "i invested in", "my holding", "my startup", "portfolio compan") { scope = .owned }
            else if has("i follow", "watchlist", "followed compan") { scope = .followed }
            else { scope = .tracked }
            return await privateUpdates(scope: scope, summarise: has("summaris", "summariz", "summary", "recap", "what changed"))
        }
        if has("pending", "waiting for", "open order", "awaiting", "need my approval", "needs approval") {
            return pendingTrades()
        }
        if has("portfolio", "my holdings", "my investments") &&
            has("moved", " move", "went up", "went down", "price change", "price contribution", "what drove") {
            return portfolioMovement()
        }
        if has("concentration", "allocation", "diversif", "exposure", "how concentrated") && !has("reduce", "set ", "change", "lower", "raise", "increase") {
            return concentration()
        }
        if has("create", "make ", "build", "set up", "start a", "new agent", "new strategy") && has("agent", "strategy", "bot") {
            let parsed = StrategyParser.parse(text)
            return CopilotMessage(isUser: false,
                                  text: "Here's a draft. Nothing is running yet: review it, change anything, and start it when you're happy.",
                                  cards: [.draft(id: UUID(), parsed: parsed)])
        }
        if has("compare") || lower.contains(" vs ") || lower.contains(" versus ") {
            let instruments = StrategyParser.instruments(in: text)
            if instruments.count >= 2 { return await compare(Array(instruments.prefix(3))) }
        }

        // The rest are about one agent.
        let needsAgent = has("why", "explain", "backtest", "reduce", "increase", "lower", "raise", "set ", "change", "stopped", "stop trading", "paused")
            && has("agent", "strategy", "bot", "it ", "its ") || has("backtest")
        guard needsAgent else { return nil }
        guard !trading.agents.isEmpty else {
            return CopilotMessage(isUser: false, text: "You don't have any agents yet. Tell me what you'd like one to do, for example: \"Create a momentum agent for NVDA and AMD with $5,000\".")
        }
        guard let agent = forcedAgent.flatMap(trading.agent) ?? resolveAgent(lower) else {
            return CopilotMessage(isUser: false, text: "Which agent do you mean?",
                                  cards: [.agentChoice(id: UUID(), request: text, agentIDs: trading.agents.map(\.id))])
        }

        if has("backtest") { return await backtest(agent, text: lower) }
        if has("why", "explain") && has("stop", "paused", "not trading", "isn't trading", "nothing") { return whyStopped(agent) }
        if has("reduce", "increase", "lower", "raise", "set ", "change") && has("allocation", "position", "limit", "loss", "drawdown", "order size", "per order") {
            return limitChange(agent, text: lower)
        }
        if has("why", "explain") { return explainDecision(agent) }
        return nil
    }

    private func privateUpdates(scope: PrivateUpdateScope, summarise: Bool) async -> CopilotMessage {
        guard let owner = auth.userId else {
            return .init(isUser: false, text: "Sign in from Account to see published updates for your private companies.")
        }
        do {
            if scope != .followed { await privateMarkets.refreshProviderHoldings(for: owner) }
            let now = Date.now
            let recent = now.addingTimeInterval(-30 * 86_400)
            let updates = try await privateMarkets.checkUpdates(for: owner, companyScope: scope, deliverNotifications: false)
                .filter { $0.isResearchSource && $0.activityAt >= recent && $0.activityAt <= now }
            let selected = Array(updates.prefix(3))
            guard auth.userId == owner, !Task.isCancelled else { throw CancellationError() }
            var report: PrivateResearchReport?
            var notices: [String] = []
            if scope != .followed, privateMarkets.providerError != nil {
                notices.append("Some provider holdings could not be refreshed.")
            }
            if summarise && !selected.isEmpty {
                do {
                    let summary: PrivateResearchReport = try await PrivateMarketsAPI.request("research", [
                        "mode": "question", "question": "Summarise these public company disclosures. Explain what changed and identify uncertainties in the sources.",
                        "document_ids": [], "opportunity_ids": [], "announcement_ids": selected.map { $0.id.uuidString }
                    ], expectedUserID: owner)
                    if summary.findings.first?.evidence.isEmpty == false {
                        report = summary
                    } else {
                        notices.append("The AI summary returned no citations. You can still read the published sources.")
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    notices.append("The AI summary is unavailable. You can still read the published sources.")
                }
            }
            guard auth.userId == owner, !Task.isCancelled else { throw CancellationError() }
            return .init(isUser: false, text: selected.isEmpty ? "I found no published updates in the last 30 days." :
                "Here are the latest published updates from the last 30 days.",
                cards: [.privateUpdates(id: UUID(), response: .init(owner: owner, scope: scope, updates: selected, report: report,
                                                                  notice: notices.isEmpty ? nil : notices.joined(separator: " ")))])
        } catch is CancellationError {
            return .init(isUser: false, text: "The company update request ended.")
        } catch {
            return .init(isUser: false, text: "Company updates could not be loaded. \(error.localizedDescription)")
        }
    }

    private func resolveAgent(_ lower: String) -> TradingAgent? {
        let agents = trading.agents
        if agents.count == 1 { return agents[0] }
        let ignored: Set<String> = ["agent", "the", "my", "for", "and", "trading"]
        let scored = agents.map { agent -> (TradingAgent, Int) in
            let words = agent.name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                .filter { $0.count >= 3 && !ignored.contains($0) }
            var score = words.filter { lower.contains($0) }.count * 2
            if lower.contains("crypto"), agent.spec.universe.contains(where: { $0.assetClass == .crypto }) { score += 1 }
            return (agent, score)
        }
        let best = scored.max { $0.1 < $1.1 }
        guard let best, best.1 > 0, scored.filter({ $0.1 == best.1 }).count == 1 else { return nil }
        return best.0
    }

    // MARK: - Tools

    private func pendingTrades() -> CopilotMessage {
        let proposals = trading.pendingProposals
        let orders = trading.openOrders
        if proposals.isEmpty && orders.isEmpty {
            return CopilotMessage(isUser: false, text: "Nothing is pending. No proposals are waiting for you and no orders are open.")
        }
        var parts: [String] = []
        if !proposals.isEmpty { parts.append("\(proposals.count) proposal\(proposals.count == 1 ? " is" : "s are") waiting for your decision") }
        if !orders.isEmpty { parts.append("\(orders.count) order\(orders.count == 1 ? " is" : "s are") open and not yet filled") }
        return CopilotMessage(isUser: false, text: parts.joined(separator: " and ").capitalizedFirst + ". A proposal is only a suggestion until you approve it.",
                              cards: [.orders(id: UUID(), proposals: proposals.map(\.id), orders: orders.map(\.id))])
    }

    private func portfolioMovement() -> CopilotMessage {
        guard let report = marketData?.portfolioMovement(), report.positionCount > 0 else {
            return CopilotMessage(isUser: false, text: "Add holdings to this portfolio to see how their prices contributed.")
        }
        let text = report.coveredCount == 0
            ? "Recent prices and reference prices are unavailable for these holdings. Refresh the Portfolio tab to check for new quotes."
            : "Here’s how recent price changes affected the holdings in your active portfolio."
        return CopilotMessage(isUser: false, text: text, cards: [.portfolioMovement(id: UUID(), report: report)])
    }

    private func concentration() -> CopilotMessage {
        var cards: [CopilotCard] = []
        var sentences: [String] = []

        // Practice money, across every practice and agent portfolio (USD).
        let ledgers = trading.state.ledgers.filter { $0.currency == "USD" }
        let equity = ledgers.reduce(0.0) { $0 + $1.equity }
        if equity > 0 {
            var byAsset: [String: Double] = [:]
            for ledger in ledgers { for position in ledger.positions { byAsset[position.instrument.symbol, default: 0] += position.marketValue } }
            let cash = ledgers.reduce(0.0) { $0 + $1.cash }
            var facts = byAsset.sorted { $0.value > $1.value }.prefix(6).map {
                Evidence(label: $0.key, value: String(format: "%.1f%%", $0.value / equity * 100))
            }
            facts.append(Evidence(label: "Cash", value: String(format: "%.1f%%", cash / equity * 100)))
            cards.append(.facts(id: UUID(), title: "Practice money", facts: facts,
                                footnote: "Share of \(TradingFormat.money(equity, "USD")) across \(ledgers.count) practice portfolio\(ledgers.count == 1 ? "" : "s"), at the latest prices."))
            if let top = byAsset.max(by: { $0.value < $1.value }) {
                sentences.append(String(format: "In practice money, the largest holding is %@ at %.0f%%.", top.key, top.value / equity * 100))
            } else {
                sentences.append("Your practice money is all in cash.")
            }
        }

        if let report = marketData?.portfolioConcentration, report.openPositions > 0 {
            let facts = report.listings.prefix(6).map { listing in
                Evidence(label: report.label(for: listing), value: formatPercent(report.share(of: listing.value)))
            }
            cards.append(.facts(id: UUID(), title: "Your tracked portfolio", facts: Array(facts),
                                footnote: "\(report.coverage). Percentages use priced positions and combine the same listing across accounts."))
            if let largest = report.listings.first {
                let weight = formatPercent(report.share(of: largest.value))
                sentences.append("\(report.label(for: largest)) makes up the largest share of your priced holdings at \(weight).")
                if report.listings.count > 3 {
                    sentences.append("The three largest listings make up \(formatPercent(report.topThreeShare)).")
                }
            } else {
                sentences.append("The tracked portfolio’s concentration is unavailable until prices load.")
            }
        }

        if cards.isEmpty {
            return CopilotMessage(isUser: false, text: "Add holdings to your portfolio or set up practice money to see concentration.")
        }
        return CopilotMessage(isUser: false, text: sentences.joined(separator: " "), cards: cards)
    }

    private func explainDecision(_ agent: TradingAgent) -> CopilotMessage {
        let runs = trading.runs(for: agent.id)
        guard let run = runs.first(where: { !$0.signalIDs.isEmpty || !$0.proposalIDs.isEmpty }) ?? runs.first else {
            return CopilotMessage(isUser: false, text: "\(agent.name) hasn't checked the market yet, so there's no decision to explain.")
        }
        var text = "\(agent.name)'s latest decision, from \(TradingFormat.time(run.startedAt)): \(run.summary)."
        if let proposal = trading.proposals(for: agent.id).first(where: { run.proposalIDs.contains($0.id) }) {
            text += " It proposed to \(proposal.side.rawValue) \(TradingFormat.units(proposal.quantity, proposal.instrument)) because: \(proposal.headline)"
            text += " The risk checks: \(proposal.risk.summary) Status: \(proposal.status.displayName.lowercased())."
        } else if run.signalIDs.isEmpty {
            text += " No rule was met, so it proposed nothing."
        }
        text += " Every rule it checked and the numbers it compared are below."
        return CopilotMessage(isUser: false, text: text, cards: [.run(id: UUID(), agentID: agent.id, runID: run.id)])
    }

    private func whyStopped(_ agent: TradingAgent) -> CopilotMessage {
        let runs = trading.runs(for: agent.id)
        var text: String
        if agent.status != .active {
            let since = trading.audit(for: agent.id).first { $0.kind == .agentPaused }?.time
            text = "\(agent.name) is paused\(since.map { " since \(TradingFormat.time($0))" } ?? ""). \((agent.pauseReason ?? .user).explanation)"
            if let error = agent.lastError { text += " Last problem: \(error)" }
            text += trading.isKillSwitchOn ? " Pause-all is on; turn it off, then resume the agent." : " Resume it from its page when you're ready."
        } else if trading.isKillSwitchOn {
            text = "Pause-all is on, so no agent can place orders."
        } else if !agent.mode.placesOrders {
            text = "\(agent.name) is in \(agent.mode.displayName) mode, which never places orders. \(agent.mode.summary)"
        } else {
            let blocked = trading.proposals(for: agent.id).first { $0.status == .blocked }
            let lastTrade = trading.orders(for: agent.id).first { $0.filledQuantity > 0 }
            text = "\(agent.name) is running. "
            text += lastTrade.map { "Its last trade was \(TradingFormat.relative($0.updatedAt)). " } ?? "It hasn't traded yet. "
            if let blocked, blocked.createdAt > (lastTrade?.updatedAt ?? .distantPast) {
                text += "Its most recent proposal was blocked by the risk rules: \(blocked.risk.summary) "
            }
            if let run = runs.first { text += "Its latest check found: \(run.summary)." }
        }
        let card = runs.first.map { [CopilotCard.run(id: UUID(), agentID: agent.id, runID: $0.id)] } ?? []
        return CopilotMessage(isUser: false, text: text, cards: card)
    }

    private func limitChange(_ agent: TradingAgent, text lower: String) -> CopilotMessage {
        guard agent.mode == .paper else {
            return CopilotMessage(isUser: false, text: "\(agent.name) is in \(agent.mode.displayName) mode and has no trading limits to change.")
        }
        var policy = agent.riskPolicy
        var lines: [String] = []
        var loosens = false
        let percent = firstNumber(in: lower, pattern: #"(\d{1,3}(?:\.\d+)?)\s*(?:%|percent)"#)
        let dollars = firstNumber(in: lower, pattern: #"\$\s?([\d,]+(?:\.\d+)?)"#)
        let currency = trading.ledger(agent.ledgerID)?.currency ?? "USD"

        if lower.contains("drawdown"), let percent {
            lines.append("Drawdown limit: \(Operand.trim(policy.maxDrawdownPct))% → \(Operand.trim(percent))%")
            loosens = percent > policy.maxDrawdownPct
            policy.maxDrawdownPct = percent
        } else if lower.contains("daily loss") || lower.contains("loss"), let percent {
            lines.append("Daily loss limit: \(Operand.trim(policy.maxDailyLossPct))% → \(Operand.trim(percent))%")
            loosens = percent > policy.maxDailyLossPct
            policy.maxDailyLossPct = percent
        } else if lower.contains("order"), let dollars {
            lines.append("Largest single order: \(TradingFormat.money(policy.maxOrderNotional, currency)) → \(TradingFormat.money(dollars, currency))")
            loosens = dollars > policy.maxOrderNotional
            policy.maxOrderNotional = dollars
        } else if let percent {
            lines.append("Largest position: \(Operand.trim(policy.maxPositionPct))% → \(Operand.trim(percent))% of the portfolio")
            loosens = percent > policy.maxPositionPct
            policy.maxPositionPct = percent
            let budget = trading.ledger(agent.ledgerID)?.startingCash ?? agent.budget
            let order = Rounding.money(max(budget * percent / 100, 1))
            if order != policy.maxOrderNotional {
                lines.append("Largest single order: \(TradingFormat.money(policy.maxOrderNotional, currency)) → \(TradingFormat.money(order, currency))")
                policy.maxOrderNotional = order
            }
        } else {
            return CopilotMessage(isUser: false, text: "Tell me which limit and the new value, for example \"set \(agent.name)'s maximum allocation to 5%\" or \"lower its daily loss limit to 2%\".")
        }
        if !policy.issues.isEmpty {
            return CopilotMessage(isUser: false, text: "That value isn't allowed. \(policy.issues.joined(separator: " "))")
        }
        guard policy != agent.riskPolicy else {
            return CopilotMessage(isUser: false, text: "\(agent.name) already has that limit.")
        }
        return CopilotMessage(isUser: false,
                              text: "Here's the change for \(agent.name). Nothing has changed yet." + (loosens ? " This loosens a limit, so the agent could take more risk." : ""),
                              cards: [.limitChange(id: UUID(), agentID: agent.id, lines: lines, policy: policy, loosens: loosens)])
    }

    private func backtest(_ agent: TradingAgent, text lower: String) async -> CopilotMessage {
        guard agent.spec.kind != .research, !agent.spec.followsLedgerPositions else {
            return CopilotMessage(isUser: false, text: "\(agent.name) doesn't open trades of its own, so there's nothing to backtest.")
        }
        var years = 2
        if let value = firstNumber(in: lower, pattern: #"(\d)\s*-?\s*year"#) { years = min(max(Int(value), 1), 5) }
        else if lower.contains("five year") { years = 5 } else if lower.contains("three year") { years = 3 }
        else if lower.contains("one year") || lower.contains("last year") { years = 1 }
        let draft = AgentDraft(name: agent.name, mode: agent.mode, spec: agent.spec,
                               budget: trading.ledger(agent.ledgerID)?.startingCash ?? agent.budget,
                               maxPositionPct: agent.riskPolicy.maxPositionPct, riskPolicy: agent.riskPolicy)
        do {
            let result = try await trading.backtest(draft, years: years, agentID: agent.id)
            let m = result.overall
            var text = String(format: "Simulated over about %d year%@ of %@ prices, %@'s rules returned %@ with a worst fall of %.1f%% and %d completed trade%@.",
                              years, years == 1 ? "" : "s", result.usedRealMarketData ? "real" : "test", agent.name,
                              TradingFormat.percent(m.totalReturnPct), m.maxDrawdownPct, m.closedTrades, m.closedTrades == 1 ? "" : "s")
            if let benchmark = result.benchmarkReturnPct, let name = result.benchmarkName {
                text += " \(name) returned \(TradingFormat.percent(benchmark)) over the same dates."
            }
            text += " A backtest is a simulation of the past; it does not predict what happens next."
            let box = BacktestBox(result: result, title: result.strategyTitle,
                                  currency: draft.currency, testedRuleLines: draft.spec.ruleLines)
            return CopilotMessage(isUser: false, text: text, cards: [.backtest(id: UUID(), box: box)])
        } catch {
            return CopilotMessage(isUser: false, text: "The backtest couldn't run: \(error.localizedDescription) Nothing was estimated in its place.")
        }
    }

    private func compare(_ instruments: [Instrument]) async -> CopilotMessage {
        var cards: [CopilotCard] = []
        var missing: [String] = []
        for instrument in instruments {
            guard let market = await trading.marketFacts(for: instrument) else {
                missing.append(instrument.symbol)
                continue
            }
            var facts = market.facts
            var sources = [market.source]
            if instrument.venue == .us, instrument.assetClass == .equity,
               let f = try? await APIService.shared.fetchFinnhubFundamentals(symbol: instrument.symbol) {
                if let v = f.marketCapUSD { facts.append(Evidence(label: "Market value", value: Self.compactUSD(v))) }
                if let v = f.peTTM { facts.append(Evidence(label: "Price to earnings (12 months)", value: String(format: "%.1f", v))) }
                if let v = f.revenueGrowthYoY { facts.append(Evidence(label: "Revenue growth (year on year)", value: String(format: "%+.1f%%", v * 100))) }
                if let v = f.netMargin { facts.append(Evidence(label: "Net profit margin", value: String(format: "%.1f%%", v * 100))) }
                if let v = f.debtToEquity { facts.append(Evidence(label: "Debt to equity", value: String(format: "%.2f", v))) }
                sources.append("Finnhub")
            }
            cards.append(.facts(id: UUID(), title: "\(instrument.name) (\(instrument.symbol))", facts: facts,
                                footnote: "Sources: \(sources.joined(separator: ", ")). Prices to the close of \(market.asOf.formatted(date: .abbreviated, time: .omitted)); fundamentals as last reported."))
        }
        if cards.isEmpty {
            return CopilotMessage(isUser: false, text: "I couldn't load prices for \(missing.joined(separator: " or ")) just now, so there's nothing to compare. I won't guess the numbers.")
        }
        var text = "Here are the same facts for each, side by side. They describe the past and the present; they aren't a forecast or a recommendation."
        if !missing.isEmpty { text += " Prices for \(missing.joined(separator: ", ")) couldn't be loaded." }
        return CopilotMessage(isUser: false, text: text, cards: cards)
    }

    // MARK: - Model

    private struct ToolChoice: Decodable {
        let tool: String
        let agent: String?
        let request: String?
    }

    private func routeByModel(_ text: String) async -> CopilotMessage {
        guard canUseModel() else {
            return CopilotMessage(isUser: false, text: "I can help with your pending trades, portfolio concentration, why an agent did or didn't trade, creating an agent, backtests and limit changes. Free-form questions use an AI model, which needs a Pro plan and has a daily limit.")
        }
        didUseModel()
        let includeContext = UserDefaults.standard.bool(forKey: "aiPortfolioContextEnabled")
        let agents = includeContext ? trading.agents.map { "\($0.name) (\($0.mode.displayName), \($0.statusText))" }.joined(separator: "; ") : ""
        let watch = includeContext ? marketData?.watchlist.prefix(20).map(\.symbol).joined(separator: ", ") ?? "" : ""
        let system = """
        You are the copilot inside an investing app with practice (paper) trading and rule-based trading agents. \
        You cannot place, change or cancel orders, and you must never claim that you did. \
        The user's agents: \(agents.isEmpty ? "none" : agents). Watchlist: \(watch.isEmpty ? "none" : watch).
        If the request matches one of these tools, reply with JSON only and nothing else: \
        {"tool":"pending_trades"} | {"tool":"portfolio_movement"} | {"tool":"concentration"} | {"tool":"explain_decision","agent":"<name>"} | \
        {"tool":"why_stopped","agent":"<name>"} | {"tool":"backtest","agent":"<name>","request":"<the user's words>"} | \
        {"tool":"change_limit","agent":"<name>","request":"<the user's words>"} | {"tool":"create_agent","request":"<the user's words>"}.
        Otherwise answer in plain text, in under 120 words. Give general information only: no personal financial advice, \
        no price predictions, no guarantees. Say when you don't know. Do not invent prices, holdings or performance figures.
        """
        do {
            let reply = try await ai.sendMessage(messages: [ChatMessage(text: system, isUser: false, role: "system"),
                                                            ChatMessage(text: text, isUser: true)])
            if let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
               let choice = try? JSONDecoder().decode(ToolChoice.self, from: Data(reply[start...end].utf8)),
               let routed = await run(choice, original: text) {
                return routed
            }
            return CopilotMessage(isUser: false, text: reply, aiGenerated: true)
        } catch {
            return CopilotMessage(isUser: false, text: "The AI model isn't reachable right now. I can still show your pending trades, concentration, agent decisions, backtests and limit changes.")
        }
    }

    /// Runs a tool the model picked. The model chooses which tool; it never supplies the
    /// data, and the tools are the same read-or-prepare ones the rules use.
    private func run(_ choice: ToolChoice, original: String) async -> CopilotMessage? {
        let named = choice.agent.flatMap { name in trading.agents.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
        func agent() -> TradingAgent? { named ?? resolveAgent(original.lowercased()) }
        switch choice.tool {
        case "pending_trades": return pendingTrades()
        case "portfolio_movement": return portfolioMovement()
        case "concentration": return concentration()
        case "explain_decision": return agent().map(explainDecision)
        case "why_stopped": return agent().map(whyStopped)
        case "backtest":
            guard let agent = agent() else { return nil }
            return await backtest(agent, text: original.lowercased())
        case "change_limit": return agent().map { limitChange($0, text: original.lowercased()) }
        case "create_agent":
            return CopilotMessage(isUser: false, text: "Here's a draft. Nothing is running yet: review it and start it when you're happy.",
                                  cards: [.draft(id: UUID(), parsed: StrategyParser.parse(original))])
        default: return nil
        }
    }

    // MARK: - Helpers

    /// "US$3.2T", "US$410B", "US$12M".
    private static func compactUSD(_ value: Double) -> String {
        switch abs(value) {
        case 1e12...: return String(format: "US$%.2fT", value / 1e12)
        case 1e9...: return String(format: "US$%.1fB", value / 1e9)
        case 1e6...: return String(format: "US$%.0fM", value / 1e6)
        default: return String(format: "US$%.0f", value)
        }
    }

    private func firstNumber(in text: String, pattern: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)), match.numberOfRanges > 1 else { return nil }
        return Double(ns.substring(with: match.range(at: 1)).replacingOccurrences(of: ",", with: ""))
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
