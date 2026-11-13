import Foundation

/// The single place trading state changes. Every method takes the time and the market data
/// it needs as arguments and touches nothing outside `state`, so a test can replay any
/// sequence of events and get the same result every time.
///
/// Nothing here reaches a real broker. Orders are matched by the built-in simulator, and
/// the live paths refuse with the reason.
public struct TradingEngine: Sendable {
    public var state: TradingState
    public var calendar: MarketCalendar
    /// Things worth telling the person about since the last `drainNotices()`.
    public private(set) var notices: [EngineNotice] = []

    public init(state: TradingState = TradingState(), calendar: MarketCalendar = .standard) {
        self.state = state
        self.calendar = calendar
    }

    public mutating func drainNotices() -> [EngineNotice] {
        defer { notices = [] }
        return notices
    }

    mutating func notify(_ notice: EngineNotice) { notices.append(notice) }

    // MARK: - Paper portfolios

    public static let budgetRange: ClosedRange<Double> = 100...10_000_000

    @discardableResult
    public mutating func createPaperPortfolio(name: String, startingCash: Double, currency: String = "USD",
                                              now: Date) throws -> Ledger {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var problems: [String] = []
        if clean.isEmpty || clean.count > 40 { problems.append("Give the portfolio a name of up to 40 characters.") }
        if !(startingCash.isFinite && Self.budgetRange.contains(startingCash)) {
            problems.append("The starting balance must be between 100 and 10,000,000.")
        }
        if !["USD", "AUD"].contains(currency) { problems.append("Paper portfolios are held in USD or AUD.") }
        guard problems.isEmpty else { throw TradingError.invalid(problems) }
        let ledger = Ledger(name: clean, kind: .manualPaper, currency: currency, startingCash: startingCash, createdAt: now)
        state.ledgers.append(ledger)
        state.audit.append(time: now, actor: .user, kind: .portfolioCreated,
                           summary: "Paper portfolio \"\(clean)\" created with \(NumberText.money(ledger.startingCash, currency: currency)).",
                           mode: .paper, ledgerID: ledger.id,
                           details: ["startingCash": String(ledger.startingCash), "currency": currency])
        return ledger
    }

    /// Puts a paper portfolio back to its starting balance. Open orders are cancelled first.
    public mutating func resetPaperPortfolio(id: UUID, now: Date) throws {
        guard let index = state.ledgers.firstIndex(where: { $0.id == id }) else { throw TradingError.notFound("That portfolio") }
        let old = state.ledgers[index]
        for order in state.orders where order.ledgerID == id && order.status.isOpen {
            cancelOrder(id: order.id, actor: .system, note: "Portfolio reset.", now: now)
        }
        var fresh = Ledger(id: old.id, name: old.name, kind: old.kind, currency: old.currency,
                           agentID: old.agentID, startingCash: old.startingCash, createdAt: now)
        fresh.mode = old.mode
        state.ledgers[index] = fresh
        state.audit.append(time: now, actor: .user, kind: .portfolioReset,
                           summary: "\"\(old.name)\" reset to \(NumberText.money(old.startingCash, currency: old.currency)).",
                           mode: .paper, ledgerID: id,
                           details: ["equityBefore": String(Rounding.money(old.equity))])
    }

    public mutating func deletePaperPortfolio(id: UUID, now: Date) throws {
        guard let ledger = state.ledger(id) else { throw TradingError.notFound("That portfolio") }
        if let agent = state.agents.first(where: { $0.ledgerID == id }) {
            throw TradingError.notAllowed("\(agent.name) uses this portfolio. Delete the agent first.")
        }
        for order in state.orders where order.ledgerID == id && order.status.isOpen {
            cancelOrder(id: order.id, actor: .system, note: "Portfolio deleted.", now: now)
        }
        state.ledgers.removeAll { $0.id == id }
        state.audit.append(time: now, actor: .user, kind: .portfolioDeleted,
                           summary: "Paper portfolio \"\(ledger.name)\" deleted.", mode: .paper, ledgerID: id)
    }

    // MARK: - Live eligibility

    /// Why real-money trading can't be used in a given mode. Empty means it could be.
    public func liveBlockers(for mode: AgentMode?) -> [String] {
        var reasons: [String] = []
        let tradingConnection = state.connections.first { connection in
            connection.environment == .live && connection.canTrade
                && LiveVenues.all.contains { $0.adapterID == connection.adapterID && $0.isExecutionEnabled }
        }
        if tradingConnection == nil {
            if state.connections.contains(where: { $0.environment == .live && !$0.canTrade }) {
                reasons.append("Your broker connection is read-only, so it can't place orders.")
            } else {
                reasons.append("No trading account is connected.")
            }
        }
        let live = state.accountPolicy.live
        switch mode {
        case .some(.approvalRequired):
            if !live.approvalAgentsEnabled { reasons.append("Live trading for agents hasn't been switched on for this account.") }
        case .some(.autonomousLive):
            if !live.autonomousAgentsEnabled { reasons.append("Autonomous live trading hasn't been authorised for this account.") }
        default:
            if !live.manualOrdersEnabled { reasons.append("Live trading hasn't been switched on for this account.") }
        }
        return reasons
    }

    // MARK: - Agents

    @discardableResult
    public mutating func createAgent(_ draft: AgentDraft, now: Date) throws -> TradingAgent {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var problems: [String] = []
        if name.isEmpty || name.count > 40 { problems.append("Give the agent a name of up to 40 characters.") }
        problems += StrategyValidator.validate(draft.spec).filter { $0.severity == .error }.map(\.message)
        let policy = draft.resolvedPolicy
        problems += policy.issues
        if draft.mode == .paper && draft.spec.kind == .research {
            problems.append("A research strategy can't trade. Choose Research only, or pick a trading strategy.")
        }
        if !(5...10_080).contains(draft.schedule.intervalMinutes) {
            problems.append("An agent can run between every 5 minutes and once a week.")
        }
        if draft.mode == .paper, draft.attachToLedgerID == nil,
           !(draft.budget.isFinite && Self.budgetRange.contains(draft.budget)) {
            problems.append("The budget must be between 100 and 10,000,000.")
        }
        if draft.spec.followsLedgerPositions && draft.attachToLedgerID == nil && draft.mode == .paper {
            problems.append("Choose the portfolio this agent should watch.")
        }
        guard problems.isEmpty else { throw TradingError.invalid(problems) }

        if draft.mode.isLive {
            let reasons = liveBlockers(for: draft.mode)
            state.audit.append(time: now, actor: .user, kind: .liveRequestRefused,
                               summary: "Refused to create \"\(name)\" in \(draft.mode.displayName) mode.",
                               details: ["reasons": reasons.joined(separator: " ")])
            throw TradingError.liveNotAvailable(reasons.isEmpty ? ["Live trading isn't available in this version."] : reasons)
        }

        var agent = TradingAgent(name: name, templateID: draft.templateID, mode: draft.mode, spec: draft.spec,
                                 riskPolicy: policy, budget: Rounding.money(draft.budget),
                                 reviewEachPaperTrade: draft.reviewEachPaperTrade, schedule: draft.schedule,
                                 createdAt: now, author: draft.author)
        if draft.mode == .paper {
            if let attach = draft.attachToLedgerID {
                guard let ledger = state.ledger(attach) else { throw TradingError.notFound("That portfolio") }
                let currencies = Set(draft.spec.universe.map(\.currency))
                if let currency = currencies.first, currency != ledger.currency {
                    throw TradingError.invalid(["This portfolio holds \(ledger.currency) but the strategy trades \(currency)."])
                }
                agent.ledgerID = attach
                agent.budget = Rounding.money(ledger.equity)
            } else {
                agent.ledgerID = makeAgentLedger(for: agent, now: now)
            }
        }
        state.agents.append(agent)
        state.audit.append(time: now, actor: draft.author == .copilot ? .copilot : .user, kind: .agentCreated,
                           summary: "\(name) created in \(agent.mode.displayName) mode: \(agent.spec.title).",
                           mode: agent.mode.placesOrders ? .paper : nil, agentID: agent.id, ledgerID: agent.ledgerID,
                           details: ["mode": agent.mode.rawValue, "strategyVersion": "1",
                                     "budget": String(agent.budget), "assets": agent.spec.universe.map(\.symbol).joined(separator: ",")])
        return agent
    }

    private mutating func makeAgentLedger(for agent: TradingAgent, now: Date) -> UUID {
        let currency = agent.spec.universe.first?.currency ?? "USD"
        let ledger = Ledger(name: agent.name, kind: .agentPaper, currency: currency, agentID: agent.id,
                            startingCash: agent.budget, createdAt: now)
        state.ledgers.append(ledger)
        return ledger.id
    }

    func agentIndex(_ id: UUID) throws -> Int {
        guard let index = state.agents.firstIndex(where: { $0.id == id }) else { throw TradingError.notFound("That agent") }
        return index
    }

    /// Saves a new strategy version. Old versions are kept so past trades stay explainable.
    public mutating func updateStrategy(agentID: UUID, spec: StrategySpec, note: String,
                                        author: ChangeAuthor = .user, now: Date) throws {
        let index = try agentIndex(agentID)
        let problems = StrategyValidator.validate(spec).filter { $0.severity == .error }.map(\.message)
        guard problems.isEmpty else { throw TradingError.invalid(problems) }
        let agent = state.agents[index]
        if let ledger = state.ledger(agent.ledgerID), let currency = spec.universe.first?.currency, currency != ledger.currency {
            throw TradingError.invalid(["This agent's portfolio holds \(ledger.currency); the new assets trade in \(currency)."])
        }
        if agent.mode == .paper && spec.kind == .research {
            throw TradingError.invalid(["A research strategy can't trade. Switch the agent to Research only first."])
        }
        guard spec != agent.spec else { return }
        let version = agent.strategyVersion + 1
        state.agents[index].versions.append(StrategyVersion(version: version, spec: spec, createdAt: now,
                                                            note: note.isEmpty ? "Updated" : note, author: author))
        // Proposals made under the old rules shouldn't be approved under the new ones.
        expirePendingProposals(agentID: agentID, note: "The strategy changed.", now: now)
        state.audit.append(time: now, actor: author == .copilot ? .copilot : .user, kind: .strategyChanged,
                           summary: "\(agent.name): strategy updated to version \(version). \(note)",
                           agentID: agentID, details: ["strategyVersion": String(version)])
    }

    public mutating func updateRiskPolicy(agentID: UUID, policy: RiskPolicy, actor: AuditActor = .user, now: Date) throws {
        let index = try agentIndex(agentID)
        guard policy.issues.isEmpty else { throw TradingError.invalid(policy.issues) }
        let old = state.agents[index].riskPolicy
        guard old != policy else { return }
        state.agents[index].riskPolicy = policy
        expirePendingProposals(agentID: agentID, note: "The risk limits changed.", now: now)
        state.audit.append(time: now, actor: actor, kind: .riskPolicyChanged,
                           summary: "\(state.agents[index].name): risk limits changed.", agentID: agentID,
                           details: ["maxOrderNotional": "\(old.maxOrderNotional) → \(policy.maxOrderNotional)",
                                     "maxPositionPct": "\(old.maxPositionPct) → \(policy.maxPositionPct)",
                                     "maxDailyNotional": "\(old.maxDailyNotional) → \(policy.maxDailyNotional)",
                                     "maxDailyLossPct": "\(old.maxDailyLossPct) → \(policy.maxDailyLossPct)",
                                     "maxDrawdownPct": "\(old.maxDrawdownPct) → \(policy.maxDrawdownPct)"])
    }

    public mutating func setMode(agentID: UUID, mode: AgentMode, now: Date) throws {
        let index = try agentIndex(agentID)
        let agent = state.agents[index]
        guard agent.mode != mode else { return }
        if mode.isLive {
            let reasons = liveBlockers(for: mode)
            state.audit.append(time: now, actor: .user, kind: .liveRequestRefused,
                               summary: "\(agent.name): refused to switch to \(mode.displayName).",
                               agentID: agentID, details: ["reasons": reasons.joined(separator: " ")])
            throw TradingError.liveNotAvailable(reasons.isEmpty ? ["Live trading isn't available in this version."] : reasons)
        }
        if mode == .paper && agent.spec.kind == .research {
            throw TradingError.invalid(["A research strategy can't trade. Change the strategy first."])
        }
        if !mode.placesOrders {
            // Leaving paper trading: nothing may be left waiting to trade.
            expirePendingProposals(agentID: agentID, note: "The agent no longer places orders.", now: now)
            for order in state.orders where order.source.agentID == agentID && order.status.isOpen {
                cancelOrder(id: order.id, actor: .system, note: "The agent no longer places orders.", now: now)
            }
        }
        state.agents[index].mode = mode
        if mode == .paper && state.agents[index].ledgerID == nil {
            state.agents[index].ledgerID = makeAgentLedger(for: state.agents[index], now: now)
        }
        state.audit.append(time: now, actor: .user, kind: .modeChanged,
                           summary: "\(agent.name): mode changed from \(agent.mode.displayName) to \(mode.displayName).",
                           agentID: agentID, details: ["from": agent.mode.rawValue, "to": mode.rawValue])
    }

    public mutating func setReviewEachPaperTrade(agentID: UUID, _ review: Bool, now: Date) throws {
        let index = try agentIndex(agentID)
        guard state.agents[index].reviewEachPaperTrade != review else { return }
        state.agents[index].reviewEachPaperTrade = review
        state.audit.append(time: now, actor: .user, kind: .modeChanged,
                           summary: "\(state.agents[index].name): paper trades now \(review ? "wait for your approval" : "execute automatically").",
                           agentID: agentID, details: ["reviewEachPaperTrade": String(review)])
    }

    public mutating func setSchedule(agentID: UUID, _ schedule: AgentSchedule, now: Date) throws {
        let index = try agentIndex(agentID)
        guard (5...10_080).contains(schedule.intervalMinutes) else {
            throw TradingError.invalid(["An agent can run between every 5 minutes and once a week."])
        }
        state.agents[index].schedule = schedule
        state.agents[index].nextRunAt = (state.agents[index].lastRunAt ?? now).addingTimeInterval(Double(schedule.intervalMinutes) * 60)
    }

    public mutating func renameAgent(id: UUID, name: String, now: Date) throws {
        let index = try agentIndex(id)
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 40 else { throw TradingError.invalid(["Give the agent a name of up to 40 characters."]) }
        let old = state.agents[index].name
        guard old != clean else { return }
        state.agents[index].name = clean
        if let ledgerIndex = state.ledgers.firstIndex(where: { $0.agentID == id && $0.kind == .agentPaper }) {
            state.ledgers[ledgerIndex].name = clean
        }
        state.audit.append(time: now, actor: .user, kind: .agentRenamed, summary: "\(old) renamed to \(clean).", agentID: id)
    }

    /// Stops an agent acting. Its open orders are cancelled; its positions are left alone.
    public mutating func pauseAgent(id: UUID, reason: PauseReason = .user, now: Date) throws {
        let index = try agentIndex(id)
        guard state.agents[index].status == .active else { return }
        state.agents[index].status = .paused
        state.agents[index].pauseReason = reason
        var cancelled = 0
        for order in state.orders where order.source.agentID == id && order.status.isOpen {
            if cancelOrder(id: order.id, actor: .system, note: "The agent was paused.", now: now) { cancelled += 1 }
        }
        let agent = state.agents[index]
        let openPositions = state.ledger(agent.ledgerID).map { $0.kind == .agentPaper ? $0.positions.count : 0 } ?? 0
        state.audit.append(time: now, actor: reason == .user ? .user : .system, kind: .agentPaused,
                           summary: "\(agent.name) paused. \(reason.explanation)", agentID: id,
                           details: ["reason": reason.rawValue, "ordersCancelled": String(cancelled),
                                     "openPositions": String(openPositions)])
        if reason != .user && reason != .killSwitch {
            let tail = openPositions > 0 ? " It still holds \(openPositions) position\(openPositions == 1 ? "" : "s")." : ""
            notify(EngineNotice(kind: .agentPaused, title: "\(agent.name) paused",
                                body: reason.explanation + tail, agentID: id))
        }
    }

    public mutating func resumeAgent(id: UUID, now: Date) throws {
        let index = try agentIndex(id)
        guard state.agents[index].status == .paused else { return }
        if state.accountPolicy.killSwitchEngaged {
            throw TradingError.notAllowed("The kill switch is on. Turn it off before resuming an agent.")
        }
        state.agents[index].status = .active
        state.agents[index].pauseReason = nil
        state.agents[index].consecutiveErrors = 0
        state.agents[index].nextRunAt = now
        state.audit.append(time: now, actor: .user, kind: .agentResumed,
                           summary: "\(state.agents[index].name) resumed.", agentID: id)
    }

    /// Removes an agent. Its paper portfolio goes with it; the audit trail does not.
    public mutating func deleteAgent(id: UUID, now: Date) throws {
        let index = try agentIndex(id)
        let agent = state.agents[index]
        for order in state.orders where order.source.agentID == id && order.status.isOpen {
            cancelOrder(id: order.id, actor: .system, note: "The agent was deleted.", now: now)
        }
        expirePendingProposals(agentID: id, note: "The agent was deleted.", now: now)
        state.agents.remove(at: index)
        state.ledgers.removeAll { $0.agentID == id && $0.kind == .agentPaper }
        state.audit.append(time: now, actor: .user, kind: .agentDeleted, summary: "\(agent.name) deleted.", agentID: id)
    }

    // MARK: - Kill switch

    /// Stops every agent at once: pauses them, cancels their open orders and expires their
    /// pending proposals. Positions are not sold — closing them is the person's call.
    /// Returns how many orders were cancelled.
    @discardableResult
    public mutating func engageKillSwitch(now: Date) -> Int {
        guard !state.accountPolicy.killSwitchEngaged else { return 0 }
        state.accountPolicy.killSwitchEngaged = true
        state.accountPolicy.killSwitchAt = now
        var cancelled = 0
        for order in state.orders where order.source.isAgent && order.status.isOpen {
            if cancelOrder(id: order.id, actor: .system, note: "Kill switch.", now: now) { cancelled += 1 }
        }
        var paused = 0
        for agent in state.agents where agent.status == .active {
            try? pauseAgent(id: agent.id, reason: .killSwitch, now: now)
            expirePendingProposals(agentID: agent.id, note: "Kill switch.", now: now)
            paused += 1
        }
        state.audit.append(time: now, actor: .user, kind: .killSwitchEngaged,
                           summary: "Kill switch turned on: \(paused) agent\(paused == 1 ? "" : "s") paused, \(cancelled) order\(cancelled == 1 ? "" : "s") cancelled.",
                           details: ["agentsPaused": String(paused), "ordersCancelled": String(cancelled)])
        return cancelled
    }

    /// Turns the kill switch off. Agents stay paused until each one is resumed by hand.
    public mutating func releaseKillSwitch(now: Date) {
        guard state.accountPolicy.killSwitchEngaged else { return }
        state.accountPolicy.killSwitchEngaged = false
        state.accountPolicy.killSwitchAt = nil
        state.audit.append(time: now, actor: .user, kind: .killSwitchReleased,
                           summary: "Kill switch turned off. Agents stay paused until you resume them.")
    }

    // MARK: - Orders

    /// Limits for an order a person places by hand in a paper portfolio: the hard rules
    /// (funds, holdings, exchange rules, real fresh data) still apply; the sizing limits
    /// that exist to bound an agent do not.
    public static func manualPolicy(equity: Double) -> RiskPolicy {
        RiskPolicy(maxOrderNotional: max(equity, 1) * 10, maxPositionPct: 100, maxDailyNotional: max(equity, 1) * 100,
                   maxDailyLossPct: 100, maxDrawdownPct: 100, maxOpenPositions: 100, maxSpreadBps: 500,
                   maxQuoteAgeSeconds: 900, minAverageDollarVolume: 0, maxDailyVolatilityPct: 1_000,
                   cooldownSeconds: 0, maxPriceGapPct: 10, allowQueueOutsideHours: true)
    }

    func policy(for source: OrderSource, ledger: Ledger) -> RiskPolicy {
        if let agent = state.agent(source.agentID) { return agent.riskPolicy }
        return Self.manualPolicy(equity: ledger.equity)
    }

    struct Sized {
        var quantity: Double
        var price: Double
        var fee: Double
        var modelledSpread: Bool
    }

    /// Turns a request into a quantity and the worst price it could trade at right now.
    func size(_ request: OrderRequest) -> Sized {
        let rules = PaperBroker.rules(for: request.instrument)
        let quote = state.quotes[request.instrument.id]
        var price = 0.0
        var modelled = false
        if let quote, quote.last > 0 {
            let market = PaperBroker.executionPrice(side: request.side, quote: quote, instrument: request.instrument, config: state.paperConfig)
            price = market.price
            modelled = market.modelled
        }
        switch request.type {
        case .market: break
        case .limit, .stopLimit: if let limit = request.limitPrice, limit > 0 { price = limit }
        case .stop: if let stop = request.stopPrice, stop > 0 { price = request.side == .buy ? max(price, stop) : stop }
        }
        var quantity = request.quantity ?? 0
        if request.quantity == nil, let notional = request.notional, price > 0 {
            quantity = Rounding.floor(notional / price, increment: rules.quantityIncrement)
        }
        let fee = PaperBroker.fee(for: request.instrument, notional: Rounding.money(quantity * price),
                                  isFirstFillOfOrder: true, config: state.paperConfig)
        return Sized(quantity: quantity, price: price, fee: fee, modelledSpread: modelled)
    }

    func riskContext(ledger: Ledger, source: OrderSource, instrument: Instrument, now: Date) -> RiskContext {
        let id = instrument.id
        let peers = state.ledgers.filter { $0.mode == ledger.mode && $0.currency == ledger.currency }
        let exposure = peers.reduce(0.0) { $0 + ($1.position(id)?.marketValue ?? 0) }
        let equity = peers.reduce(0.0) { $0 + $1.equity }
        let today = Ledger.dayKey(for: now, currency: ledger.currency)
        let notionalToday = peers.reduce(0.0) { $0 + ($1.dayKey == today ? $1.notionalToday : 0) }
        var current = ledger
        current.rollDayIfNeeded(now: now)
        return RiskContext(
            now: now,
            policy: policy(for: source, ledger: ledger),
            accountPolicy: state.accountPolicy,
            agent: state.agent(source.agentID).map(AgentRiskView.init),
            ledger: current,
            openOrders: state.orders.filter { $0.ledgerID == ledger.id && $0.status.isOpen },
            otherOpenOrders: state.orders.filter { $0.ledgerID != ledger.id && $0.status.isOpen && $0.instrument.id == id && $0.mode == ledger.mode },
            knownClientOrderIDs: state.knownClientOrderIDs,
            accountExposure: exposure,
            accountEquity: equity,
            accountNotionalToday: notionalToday,
            quote: state.quotes[id],
            rules: PaperBroker.rules(for: instrument),
            capabilities: PaperBroker.capabilities,
            grantedPermissions: [.read, .trade],
            marketOpen: calendar.isOpen(instrument.venue, at: now),
            stats: state.stats[id]
        )
    }

    func intent(for request: OrderRequest, sized: Sized) -> OrderIntent {
        OrderIntent(clientOrderID: request.clientOrderID, instrument: request.instrument, side: request.side,
                    type: request.type, timeInForce: request.timeInForce, quantity: sized.quantity, price: sized.price,
                    limitPrice: request.limitPrice, stopPrice: request.stopPrice, estimatedFee: sized.fee,
                    source: request.source, mode: request.mode)
    }

    /// The report a live request gets: refused, with the reasons, without touching a ledger.
    func liveRefusal(_ request: OrderRequest, now: Date) -> RiskReport {
        let reasons = liveBlockers(for: state.agent(request.source.agentID)?.mode)
        let detail = (reasons.isEmpty ? ["Live trading isn't available in this version."] : reasons).joined(separator: " ")
        return RiskReport(checks: [RiskCheck(.authorization, .failed, detail)], evaluatedAt: now)
    }

    /// What would happen if this order were placed now. Changes nothing.
    public func preview(_ request: OrderRequest, now: Date) -> OrderPreview? {
        guard let ledger = state.ledger(request.ledgerID) else { return nil }
        let sized = size(request)
        let risk = request.mode == .live
            ? liveRefusal(request, now: now)
            : RiskEngine.evaluate(intent(for: request, sized: sized),
                                  context: riskContext(ledger: ledger, source: request.source, instrument: request.instrument, now: now))
        let value = Rounding.money(sized.quantity * sized.price)
        let quote = state.quotes[request.instrument.id]
        let open = calendar.isOpen(request.instrument.venue, at: now)
        let cashAfter = request.side == .buy ? ledger.cash - value - sized.fee : ledger.cash + value - sized.fee
        return OrderPreview(instrument: request.instrument, side: request.side, type: request.type,
                            timeInForce: request.timeInForce, quantity: sized.quantity, estimatedPrice: sized.price,
                            estimatedValue: value, estimatedFee: sized.fee, cashAfter: Rounding.money(cashAfter),
                            currency: ledger.currency, ledgerName: ledger.name, mode: request.mode, quote: quote,
                            spreadBps: quote?.spreadBps, usesModelledSpread: sized.modelledSpread,
                            willQueueUntilOpen: !open, nextOpen: open ? nil : calendar.nextOpen(request.instrument.venue, after: now),
                            risk: risk)
    }

    /// Checks and places an order. A refused order is recorded as rejected — never dropped
    /// silently and never reported as placed.
    @discardableResult
    public mutating func submit(_ request: OrderRequest, now: Date) -> OrderResult {
        guard let ledger = state.ledger(request.ledgerID) else {
            return .rejected(order: nil, risk: RiskReport(checks: [RiskCheck(.authorization, .failed, "That portfolio no longer exists.")], evaluatedAt: now))
        }
        let sized = size(request)
        let actor: AuditActor = request.source.isAgent ? .agent : .user
        let symbol = request.instrument.symbol

        func makeOrder(status: OrderStatus, note: String?) -> Order {
            Order(clientOrderID: request.clientOrderID, ledgerID: ledger.id, instrument: request.instrument,
                  side: request.side, type: request.type, quantity: sized.quantity, limitPrice: request.limitPrice,
                  stopPrice: request.stopPrice, timeInForce: request.timeInForce, source: request.source,
                  mode: request.mode, status: status, referencePrice: sized.price, createdAt: now,
                  expiresAt: PaperBroker.expiry(for: request.timeInForce, venue: request.instrument.venue, placedAt: now, calendar: calendar),
                  statusNote: note, signalBarTime: request.signalBarTime)
        }

        let risk = request.mode == .live
            ? liveRefusal(request, now: now)
            : RiskEngine.evaluate(intent(for: request, sized: sized),
                                  context: riskContext(ledger: ledger, source: request.source, instrument: request.instrument, now: now))

        guard risk.isApproved else {
            // A repeat of an order we already hold is refused without a second record.
            if state.knownClientOrderIDs.contains(request.clientOrderID) {
                return .rejected(order: nil, risk: risk)
            }
            let order = makeOrder(status: .rejected, note: risk.summary)
            state.orders.append(order)
            state.audit.append(time: now, actor: actor, kind: .orderRejected,
                               summary: "\(request.side.rawValue.capitalized) \(symbol) rejected: \(risk.summary)",
                               mode: request.mode, agentID: request.source.agentID, ledgerID: ledger.id, orderID: order.id,
                               proposalID: request.source.proposalID, instrumentID: request.instrument.id,
                               details: ["failedChecks": risk.failures.map(\.id.rawValue).joined(separator: ","),
                                         "quantity": String(sized.quantity), "price": String(sized.price)])
            notify(EngineNotice(kind: .orderRejected, title: "\(symbol) order rejected", body: risk.summary,
                                mode: request.mode, agentID: request.source.agentID, orderID: order.id,
                                instrumentID: request.instrument.id))
            return .rejected(order: order, risk: risk)
        }

        var order = makeOrder(status: .accepted, note: nil)
        let open = calendar.isOpen(request.instrument.venue, at: now)
        if !open { order.statusNote = "Waiting for the market to open." }
        state.knownClientOrderIDs.insert(request.clientOrderID)
        state.orders.append(order)
        state.audit.append(time: now, actor: actor, kind: .orderSubmitted,
                           summary: "Paper \(request.type.displayName.lowercased()) order: \(request.side.rawValue) \(RiskEngine.quantityText(sized.quantity, PaperBroker.rules(for: request.instrument))) \(symbol).",
                           mode: request.mode, agentID: request.source.agentID, ledgerID: ledger.id, orderID: order.id,
                           proposalID: request.source.proposalID, instrumentID: request.instrument.id,
                           details: ["type": request.type.rawValue, "timeInForce": request.timeInForce.rawValue,
                                     "quantity": String(sized.quantity), "referencePrice": String(sized.price),
                                     "clientOrderID": request.clientOrderID])
        let fills = matchOrder(id: order.id, now: now)
        let current = state.orders.first { $0.id == order.id } ?? order
        return .accepted(order: current, fills: fills, risk: risk)
    }

    /// Cancels an open order. Returns false when it had already finished.
    @discardableResult
    public mutating func cancelOrder(id: UUID, actor: AuditActor = .user, note: String = "Cancelled by you.", now: Date) -> Bool {
        guard let index = state.orders.firstIndex(where: { $0.id == id }) else { return false }
        guard state.orders[index].transition(to: .canceled, at: now, note: note) else { return false }
        let order = state.orders[index]
        state.audit.append(time: now, actor: actor, kind: .orderCanceled,
                           summary: "\(order.side.rawValue.capitalized) \(order.instrument.symbol) order cancelled. \(note)",
                           mode: order.mode, agentID: order.source.agentID, ledgerID: order.ledgerID, orderID: order.id,
                           instrumentID: order.instrument.id,
                           details: ["filledQuantity": String(order.filledQuantity)])
        return true
    }

    /// Tries to trade one open order against the latest quote. Returns the fills it made.
    @discardableResult
    mutating func matchOrder(id: UUID, now: Date) -> [Fill] {
        guard let index = state.orders.firstIndex(where: { $0.id == id }), state.orders[index].status.isOpen,
              state.orders[index].mode == .paper,
              let ledgerIndex = state.ledgers.firstIndex(where: { $0.id == state.orders[index].ledgerID }),
              let quote = state.quotes[state.orders[index].instrument.id] else { return [] }
        let order = state.orders[index]
        let open = calendar.isOpen(order.instrument.venue, at: now)
        guard var match = PaperBroker.match(order: order, quote: quote, marketOpen: open, now: now, config: state.paperConfig) else {
            return []
        }
        if match.stopTriggered { state.orders[index].stopTriggeredAt = now }

        // A market order that waited (overnight, or for a fresh quote) is not filled at a
        // price far from the one it was checked against.
        if match.fillQuantity > 0, order.type == .market, order.referencePrice > 0 {
            let gapLimit = policy(for: order.source, ledger: state.ledgers[ledgerIndex]).maxPriceGapPct
            let gap = abs(match.fillPrice / order.referencePrice - 1) * 100
            if gap > gapLimit {
                cancelOrder(id: id, actor: .system,
                            note: String(format: "The price moved %.1f%% from where the order was checked (limit %.1f%%).", gap, gapLimit), now: now)
                notify(EngineNotice(kind: .orderCanceled, title: "\(order.instrument.symbol) order cancelled",
                                    body: String(format: "The price moved %.1f%% before it could trade.", gap),
                                    mode: order.mode, agentID: order.source.agentID, orderID: id, instrumentID: order.instrument.id))
                return []
            }
        }

        // The ledger can never go negative or short, whatever happened since the order was checked.
        if match.fillQuantity > 0 {
            let rules = PaperBroker.rules(for: order.instrument)
            if order.side == .buy {
                let cost = Rounding.money(match.fillQuantity * match.fillPrice) + match.fee
                if cost > state.ledgers[ledgerIndex].cash + 0.005 {
                    cancelOrder(id: id, actor: .system, note: "Not enough cash when the order came to trade.", now: now)
                    return []
                }
            } else {
                let held = state.ledgers[ledgerIndex].position(order.instrument.id)?.quantity ?? 0
                if match.fillQuantity > held + rules.quantityIncrement * 1e-3 {
                    if held <= 0 {
                        cancelOrder(id: id, actor: .system, note: "Nothing left to sell when the order came to trade.", now: now)
                        return []
                    }
                    match.fillQuantity = held
                    match.newStatus = .filled
                }
            }
        }

        guard match.fillQuantity > 0 else {
            if match.newStatus == .canceled {
                cancelOrder(id: id, actor: .system, note: match.note ?? "Cancelled.", now: now)
            } else if let note = match.note {
                state.orders[index].statusNote = note
                state.orders[index].updatedAt = now
            }
            return []
        }

        let fill = state.ledgers[ledgerIndex].apply(
            Fill(orderID: order.id, ledgerID: order.ledgerID, instrument: order.instrument, side: order.side,
                 quantity: match.fillQuantity, price: match.fillPrice, fee: match.fee, time: now,
                 source: order.source, mode: order.mode, signalBarTime: order.signalBarTime))
        state.fills.append(fill)

        let previous = state.orders[index].filledQuantity
        let total = previous + fill.quantity
        state.orders[index].averageFillPrice = total > 0
            ? (state.orders[index].averageFillPrice * previous + fill.price * fill.quantity) / total : 0
        state.orders[index].filledQuantity = Rounding.round(total, places: 9)
        state.orders[index].fees = Rounding.money(state.orders[index].fees + fill.fee)
        state.orders[index].transition(to: match.newStatus, at: now, note: match.note)
        if match.newStatus == .filled { state.orders[index].statusNote = match.note }

        let rules = PaperBroker.rules(for: order.instrument)
        let currency = state.ledgers[ledgerIndex].currency
        let complete = match.newStatus == .filled
        let text = "\(order.side == .buy ? "Bought" : "Sold") \(RiskEngine.quantityText(fill.quantity, rules)) \(order.instrument.symbol) at \(NumberText.money(fill.price, currency: currency))"
        var details: [String: String] = ["quantity": String(fill.quantity), "price": String(fill.price), "fee": String(fill.fee),
                                         "orderStatus": match.newStatus.rawValue, "quoteSource": quote.provenance.source]
        if let realized = fill.realizedPnL { details["realizedPnL"] = String(realized) }
        state.audit.append(time: now, actor: .system, kind: complete ? .orderFilled : .orderPartiallyFilled,
                           summary: "Paper fill: \(text).", mode: order.mode, agentID: order.source.agentID,
                           ledgerID: order.ledgerID, orderID: order.id, proposalID: order.source.proposalID,
                           instrumentID: order.instrument.id, details: details)
        notify(EngineNotice(kind: complete ? .orderFilled : .orderPartiallyFilled,
                            title: complete ? "Paper order filled" : "Paper order partly filled",
                            body: text + ".", mode: order.mode, agentID: order.source.agentID, orderID: order.id,
                            instrumentID: order.instrument.id))
        if match.newStatus == .canceled {
            // An immediate-or-cancel order that filled in part: the rest is gone.
            state.audit.append(time: now, actor: .system, kind: .orderCanceled,
                               summary: "The unfilled part of the \(order.instrument.symbol) order was cancelled.",
                               mode: order.mode, agentID: order.source.agentID, ledgerID: order.ledgerID, orderID: order.id,
                               instrumentID: order.instrument.id)
        }
        return [fill]
    }

    // MARK: - Market updates

    /// Takes in fresh quotes and stats, lets waiting orders trade, expires what has run out
    /// of time and reprices every portfolio. Call this whenever prices refresh.
    public mutating func ingest(quotes: [Quote], stats: [String: InstrumentStats] = [:], now: Date) {
        for quote in quotes where quote.last > 0 {
            let acceptable = quote.provenance.isRealMarketData
                || (quote.provenance.kind == .fixture && state.accountPolicy.allowFixtureData)
            guard acceptable else { continue }
            // Never replace a quote with an older one.
            if let existing = state.quotes[quote.instrumentID], existing.time > quote.time { continue }
            state.quotes[quote.instrumentID] = quote
        }
        for (id, value) in stats { state.stats[id] = value }

        for order in state.orders where order.status.isOpen && order.mode == .paper {
            if let expiry = order.expiresAt, now >= expiry {
                if let index = state.orders.firstIndex(where: { $0.id == order.id }),
                   state.orders[index].transition(to: .expired, at: now, note: "The order ran out of time.") {
                    state.audit.append(time: now, actor: .system, kind: .orderExpired,
                                       summary: "\(order.side.rawValue.capitalized) \(order.instrument.symbol) order expired.",
                                       mode: order.mode, agentID: order.source.agentID, ledgerID: order.ledgerID,
                                       orderID: order.id, instrumentID: order.instrument.id)
                }
                continue
            }
            matchOrder(id: order.id, now: now)
        }

        expireStaleProposals(now: now)
        for index in state.ledgers.indices {
            state.ledgers[index].mark(quotes: state.quotes, now: now)
        }
        applyCircuitBreakers(now: now)
        trim()
    }

    /// Pauses an agent whose portfolio has hit its drawdown limit, and says so once when a
    /// daily loss limit is reached (the risk engine is already refusing its buys).
    mutating func applyCircuitBreakers(now: Date) {
        for agent in state.agents where agent.status == .active && agent.mode == .paper {
            guard let ledger = state.ledger(agent.ledgerID), ledger.kind == .agentPaper else { continue }
            if ledger.drawdownPct >= agent.riskPolicy.maxDrawdownPct {
                try? pauseAgent(id: agent.id, reason: .drawdownLimit, now: now)
                continue
            }
            let lossPct = ledger.dayStartEquity > 0 ? max(0, -ledger.realizedToday) / ledger.dayStartEquity * 100 : 0
            if lossPct >= agent.riskPolicy.maxDailyLossPct, state.dailyLossNotified[agent.id.uuidString] != ledger.dayKey {
                state.dailyLossNotified[agent.id.uuidString] = ledger.dayKey
                notify(EngineNotice(kind: .dailyLossReached, title: "\(agent.name): daily loss limit reached",
                                    body: String(format: "Today's realised loss is %.1f%%. No new buys until tomorrow; exits still run.", lossPct),
                                    agentID: agent.id))
            }
        }
    }

    /// Keeps history bounded. Orders, fills and the audit trail are kept far longer than runs.
    mutating func trim() {
        if state.signals.count > 600 { state.signals.removeFirst(state.signals.count - 500) }
        if state.runs.count > 1_200 { state.runs.removeFirst(state.runs.count - 1_000) }
        if state.proposals.count > 1_200 {
            let resolved = state.proposals.filter(\.status.isResolved)
            let drop = Set(resolved.prefix(state.proposals.count - 1_000).map(\.id))
            state.proposals.removeAll { drop.contains($0.id) }
        }
        if state.orders.count > 6_000 {
            let finished = state.orders.filter(\.status.isTerminal)
            let drop = Set(finished.prefix(state.orders.count - 5_000).map(\.id))
            state.orders.removeAll { drop.contains($0.id) }
        }
        if state.fills.count > 12_000 { state.fills.removeFirst(state.fills.count - 10_000) }
        state.audit.archive(keepingLast: 8_000)
    }
}
