import Foundation

// The agent pipeline:
//
//   market data → strategy rules → signal → sizing → risk engine → proposal
//       → (approval) → order → simulated fill → ledger → audit trail
//
// Every stage is ordinary code. A language model can draft a strategy or explain a run,
// but it is never asked whether to trade and has no way to reach `submit`.

public extension TradingEngine {

    /// Runs one agent once against a market snapshot the caller has already gathered.
    /// Returns the trace of what it saw and did, or nil if the agent doesn't exist.
    @discardableResult
    mutating func runAgent(id: UUID, snapshot: MarketSnapshot, trigger: RunTrigger, now: Date) -> AgentRun? {
        guard let agentIndex = state.agents.firstIndex(where: { $0.id == id }) else { return nil }
        let agent = state.agents[agentIndex]
        var run = AgentRun(agentID: id, strategyVersion: agent.strategyVersion, trigger: trigger, startedAt: now)

        func skipped(_ reason: String) -> AgentRun {
            run.status = .skipped
            run.summary = reason
            run.steps.append(RunStep(kind: .note, outcome: .info, title: reason))
            return run
        }

        if state.accountPolicy.killSwitchEngaged {
            let result = skipped("The kill switch is on, so nothing ran.")
            state.runs.append(result)
            return result
        }
        guard agent.status == .active else {
            let result = skipped("\(agent.name) is \(agent.status.rawValue).")
            state.runs.append(result)
            return result
        }
        if agent.mode.isLive {
            let result = skipped("Live trading isn't available, so nothing ran.")
            state.runs.append(result)
            return result
        }

        // Take in what the snapshot learned about prices before deciding anything.
        var usable = snapshot
        usable.series = snapshot.series.filter { isUsable($0.value.provenance) }
        // An instrument whose liquidity can't be measured this time loses its old figure too.
        for instrumentID in usable.series.keys { state.stats[instrumentID] = nil }
        ingest(quotes: Array(snapshot.quotes.values), stats: usable.stats(calendar: calendar, now: now), now: now)

        let spec = agent.spec
        var instruments = spec.universe
        if spec.followsLedgerPositions, let ledger = state.ledger(agent.ledgerID) {
            instruments = ledger.positions.map(\.instrument)
        }
        if instruments.isEmpty {
            let result = skipped(spec.followsLedgerPositions ? "The portfolio has no positions to manage." : "There are no assets to watch.")
            finish(&run, agentIndex: agentIndex, dataFailures: 0, checked: 0, now: now, overrideRun: result)
            return state.runs.last
        }

        var dataFailures = 0
        var prepared: [(Instrument, [Bar], DataProvenance)] = []
        for instrument in instruments {
            switch usableBars(for: instrument, spec: spec, snapshot: snapshot, now: now) {
            case .success(let (bars, provenance)):
                prepared.append((instrument, bars, provenance))
            case .failure(let problem):
                dataFailures += 1
                run.steps.append(RunStep(kind: .data, outcome: .failed, instrumentID: instrument.id,
                                         title: "\(instrument.symbol): no usable price data", detail: problem.message))
            }
        }

        switch spec.kind {
        case .research:
            for (instrument, bars, _) in prepared {
                run.steps.append(RunStep(kind: .research, outcome: .ok, instrumentID: instrument.id,
                                         title: "\(instrument.symbol): market facts",
                                         detail: "From \(bars.count) completed \(spec.timeframe.barName) bars.",
                                         evidence: StrategyEvaluator.researchFacts(bars: bars, timeframe: spec.timeframe)))
            }
        case .rules:
            for (instrument, bars, provenance) in prepared {
                if agent.mode == .researchOnly {
                    run.steps.append(RunStep(kind: .research, outcome: .ok, instrumentID: instrument.id,
                                             title: "\(instrument.symbol): market facts",
                                             detail: "From \(bars.count) completed \(spec.timeframe.barName) bars.",
                                             evidence: StrategyEvaluator.researchFacts(bars: bars, timeframe: spec.timeframe)))
                    continue
                }
                let ledger = state.ledger(agent.ledgerID)
                let position = ledger?.position(instrument.id).map {
                    PositionContext(quantity: $0.quantity, averageCost: $0.averageCost, openedAt: $0.openedAt)
                }
                guard let decision = StrategyEvaluator.decide(spec: spec, bars: bars, position: position,
                                                              lastExitTime: ledger?.lastExitAt[instrument.id]) else { continue }
                handle(decision, instrument: instrument, provenance: provenance, targetNotional: nil,
                       agentIndex: agentIndex, run: &run, now: now)
            }
        case .dca:
            for (instrument, bars, provenance) in prepared {
                if agent.mode == .researchOnly { continue }
                let lastBuy = state.ledger(agent.ledgerID)?.lastBuyAt[instrument.id]
                guard let decision = StrategyEvaluator.decideDCA(spec: spec, bars: bars, lastBuyTime: lastBuy) else { continue }
                handle(decision, instrument: instrument, provenance: provenance, targetNotional: spec.dca?.amountPerBuy,
                       agentIndex: agentIndex, run: &run, now: now)
            }
        case .rebalance:
            if agent.mode != .researchOnly {
                rebalance(prepared: prepared, agentIndex: agentIndex, run: &run, now: now)
            }
        }

        finish(&run, agentIndex: agentIndex, dataFailures: dataFailures, checked: instruments.count, now: now, overrideRun: nil)
        return state.runs.last
    }

    // MARK: Data checks

    internal struct DataProblem: Error { let message: String }

    internal func isUsable(_ provenance: DataProvenance) -> Bool {
        provenance.isRealMarketData || (provenance.kind == .fixture && state.accountPolicy.allowFixtureData)
    }

    /// Completed, real, recent bars for an instrument — or the reason there aren't any.
    internal func usableBars(for instrument: Instrument, spec: StrategySpec, snapshot: MarketSnapshot,
                             now: Date) -> Result<([Bar], DataProvenance), DataProblem> {
        guard let series = snapshot.series[instrument.id] else {
            return .failure(DataProblem(message: snapshot.failures[instrument.id] ?? "No price history was returned."))
        }
        guard isUsable(series.provenance) else {
            return .failure(DataProblem(message: "The price history isn't real market data, so it can't be traded on."))
        }
        guard series.timeframe == spec.timeframe else {
            return .failure(DataProblem(message: "Expected \(spec.timeframe.barName) bars but got \(series.timeframe.barName) ones."))
        }
        let bars = calendar.completedBars(series, now: now)
        guard let last = bars.last else {
            return .failure(DataProblem(message: "There are no completed bars yet."))
        }
        let stale: Bool
        switch spec.timeframe {
        case .day:
            stale = calendar.tradingDays(instrument.venue, from: last.time, to: now) > 4
        case .hour:
            stale = instrument.venue == .crypto ? now.timeIntervalSince(last.time) > 6 * 3_600
                : calendar.tradingDays(instrument.venue, from: last.time, to: now) > 2
        }
        if stale {
            return .failure(DataProblem(message: "The price history is out of date: the last completed bar is from \(calendar.dayKey(instrument.venue, last.time))."))
        }
        return .success((bars, series.provenance))
    }

    // MARK: One decision

    /// Records a decision and, where the agent's mode allows, takes it through sizing,
    /// risk and execution.
    internal mutating func handle(_ decision: SignalDecision, instrument: Instrument, provenance: DataProvenance,
                                  targetNotional: Double?, agentIndex: Int, run: inout AgentRun, now: Date) {
        let agent = state.agents[agentIndex]
        let title = "\(instrument.symbol): \(decision.action.rawValue.capitalized)"
        run.steps.append(RunStep(kind: .signal, outcome: decision.action == .hold ? .info : .ok, instrumentID: instrument.id,
                                 title: title, detail: decision.headline, evidence: decision.evidence))
        guard decision.action != .hold else { return }

        // One signal per bar per direction: re-running on the same bar doesn't repeat it.
        let signal: TradingSignal
        if let existing = state.signals.last(where: {
            $0.agentID == agent.id && $0.instrument.id == instrument.id && $0.barTime == decision.barTime
                && $0.action == decision.action && $0.strategyVersion == agent.strategyVersion
        }) {
            signal = existing
        } else {
            signal = TradingSignal(agentID: agent.id, strategyVersion: agent.strategyVersion, instrument: instrument,
                                   decision: decision, createdAt: now, provenance: provenance)
            state.signals.append(signal)
            state.audit.append(time: now, actor: .agent, kind: .signalGenerated,
                               summary: "\(agent.name): \(decision.action.rawValue) signal for \(instrument.symbol). \(decision.headline)",
                               agentID: agent.id, instrumentID: instrument.id,
                               details: ["strategyVersion": String(agent.strategyVersion),
                                         "barTime": String(Int(decision.barTime.timeIntervalSince1970)),
                                         "close": String(decision.close), "dataSource": provenance.source])
        }
        run.signalIDs.append(signal.id)

        guard agent.mode == .paper else { return }
        guard let ledger = state.ledger(agent.ledgerID) else {
            run.steps.append(RunStep(kind: .sizing, outcome: .failed, instrumentID: instrument.id,
                                     title: "\(instrument.symbol): no portfolio", detail: "This agent has no paper portfolio to trade."))
            return
        }
        let side: OrderSide = decision.action == .buy ? .buy : .sell

        // Don't act twice on one bar, and don't stack proposals or orders.
        if state.fills.contains(where: { $0.source.agentID == agent.id && $0.instrument.id == instrument.id && $0.side == side && $0.signalBarTime == decision.barTime }) {
            run.steps.append(RunStep(kind: .note, outcome: .info, instrumentID: instrument.id,
                                     title: "\(instrument.symbol): already traded this signal",
                                     detail: "This bar's \(side.rawValue) signal has already been acted on."))
            return
        }
        if state.proposals.contains(where: { $0.agentID == agent.id && $0.instrument.id == instrument.id && $0.side == side && $0.status == .pending }) {
            run.steps.append(RunStep(kind: .note, outcome: .info, instrumentID: instrument.id,
                                     title: "\(instrument.symbol): waiting for your approval",
                                     detail: "A \(side.rawValue) proposal for \(instrument.symbol) is already waiting."))
            return
        }
        if state.orders.contains(where: { $0.source.agentID == agent.id && $0.instrument.id == instrument.id && $0.side == side && $0.status.isOpen }) {
            run.steps.append(RunStep(kind: .note, outcome: .info, instrumentID: instrument.id,
                                     title: "\(instrument.symbol): order already working",
                                     detail: "A \(side.rawValue) order for \(instrument.symbol) is already open."))
            return
        }

        guard let quote = state.quotes[instrument.id], quote.last > 0 else {
            run.steps.append(RunStep(kind: .sizing, outcome: .failed, instrumentID: instrument.id,
                                     title: "\(instrument.symbol): no live quote",
                                     detail: "Without a live quote the order can't be sized, so nothing was proposed."))
            return
        }

        // Size the order inside the agent's limits.
        let rules = PaperBroker.rules(for: instrument)
        let price = PaperBroker.executionPrice(side: side, quote: quote, instrument: instrument, config: state.paperConfig).price
        var quantity = 0.0
        var notes: [String] = []
        switch side {
        case .buy:
            let equity = ledger.equity
            var notional = targetNotional ?? (agent.spec.sizing.mode == .fixedNotional
                ? agent.spec.sizing.value : equity * agent.spec.sizing.value / 100)
            let wanted = notional
            if notional > agent.riskPolicy.maxOrderNotional {
                notional = agent.riskPolicy.maxOrderNotional
                notes.append("cut to the \(NumberText.money(notional, currency: ledger.currency)) order limit")
            }
            let room = equity * agent.riskPolicy.maxPositionPct / 100 - (ledger.position(instrument.id)?.marketValue ?? 0)
            if notional > room {
                notional = max(room, 0)
                notes.append("cut to stay inside the \(Operand.trim(agent.riskPolicy.maxPositionPct))% position limit")
            }
            let reserved = state.orders.filter { $0.ledgerID == ledger.id && $0.status.isOpen && $0.side == .buy }
                .reduce(0.0) { $0 + $1.remainingQuantity * ($1.limitPrice ?? $1.referencePrice) }
            let feeRate = instrument.assetClass == .crypto ? state.paperConfig.cryptoFeeBps / 10_000 : state.paperConfig.equityFeeBps / 10_000
            let flatFee = instrument.assetClass == .crypto ? 0 : state.paperConfig.equityFeePerOrder
            let spendable = max((ledger.cash - reserved - flatFee) / (1 + feeRate), 0)
            if notional > spendable {
                notional = spendable
                notes.append("cut to the cash available")
            }
            quantity = price > 0 ? Rounding.floor(notional / price, increment: rules.quantityIncrement) : 0
            if !notes.isEmpty {
                notes.insert("Wanted \(NumberText.money(wanted, currency: ledger.currency))", at: 0)
            }
        case .sell:
            let reserved = state.orders.filter { $0.ledgerID == ledger.id && $0.status.isOpen && $0.side == .sell && $0.instrument.id == instrument.id }
                .reduce(0.0) { $0 + $1.remainingQuantity }
            let held = max((ledger.position(instrument.id)?.quantity ?? 0) - reserved, 0)
            if let targetNotional, price > 0 {
                quantity = min(held, Rounding.floor(targetNotional / price, increment: rules.quantityIncrement))
            } else {
                quantity = held
            }
        }
        let sizingNote = notes.isEmpty ? nil : notes.joined(separator: "; ") + "."

        guard quantity >= rules.minQuantity, quantity * price >= rules.minNotional else {
            let reason = side == .sell ? "There is nothing available to sell."
                : "After the agent's limits and available cash, the order would be below the \(NumberText.money(rules.minNotional, currency: ledger.currency)) minimum."
            run.steps.append(RunStep(kind: .sizing, outcome: .warning, instrumentID: instrument.id,
                                     title: "\(instrument.symbol): order too small", detail: [reason, sizingNote].compactMap { $0 }.joined(separator: " ")))
            return
        }
        run.steps.append(RunStep(kind: .sizing, outcome: .ok, instrumentID: instrument.id,
                                 title: "\(instrument.symbol): sized \(side.rawValue) of \(RiskEngine.quantityText(quantity, rules))",
                                 detail: "About \(NumberText.money(quantity * price, currency: ledger.currency)) at \(NumberText.money(price, currency: ledger.currency)). \(sizingNote ?? "")"))

        // Risk engine: the same gate a manual order passes.
        var proposal = TradeProposal(agentID: agent.id, signalID: signal.id, strategyVersion: agent.strategyVersion,
                                     ledgerID: ledger.id, instrument: instrument, side: side, quantity: quantity,
                                     referencePrice: price, estimatedFee: 0, mode: .paper, status: .pending,
                                     risk: RiskReport(checks: [], evaluatedAt: now), headline: decision.headline,
                                     sizingNote: sizingNote, signalBarTime: decision.barTime, createdAt: now,
                                     expiresAt: now.addingTimeInterval(agent.spec.timeframe == .day ? 86_400 : 2 * 3_600))
        let request = orderRequest(for: proposal)
        let sized = size(request)
        proposal.estimatedFee = sized.fee
        let report = RiskEngine.evaluate(intent(for: request, sized: sized),
                                         context: riskContext(ledger: ledger, source: request.source, instrument: instrument, now: now))
        proposal.risk = report
        let passed = report.checks.filter { $0.status == .passed }.count

        guard report.isApproved else {
            proposal.status = .blocked
            proposal.resolvedAt = now
            proposal.resolutionNote = report.summary
            state.proposals.append(proposal)
            run.proposalIDs.append(proposal.id)
            run.steps.append(RunStep(kind: .risk, outcome: .blocked, instrumentID: instrument.id,
                                     title: "\(instrument.symbol): blocked by risk rules", detail: report.summary,
                                     evidence: report.failures.map { Evidence(label: $0.id.title, value: $0.detail, passed: false) }))
            state.audit.append(time: now, actor: .system, kind: .proposalBlocked,
                               summary: "\(agent.name): \(side.rawValue) \(instrument.symbol) blocked. \(report.summary)",
                               mode: .paper, agentID: agent.id, ledgerID: ledger.id, proposalID: proposal.id,
                               instrumentID: instrument.id,
                               details: ["failedChecks": report.failures.map(\.id.rawValue).joined(separator: ","),
                                         "quantity": String(quantity), "price": String(price)])
            notify(EngineNotice(kind: .proposalBlocked, title: "\(agent.name): trade blocked",
                                body: "\(side.rawValue.capitalized) \(instrument.symbol): \(report.summary)",
                                agentID: agent.id, proposalID: proposal.id, instrumentID: instrument.id))
            return
        }
        run.steps.append(RunStep(kind: .risk, outcome: report.warnings.isEmpty ? .ok : .warning, instrumentID: instrument.id,
                                 title: "\(instrument.symbol): passed \(passed) risk checks", detail: report.summary,
                                 evidence: report.warnings.map { Evidence(label: $0.id.title, value: $0.detail, passed: nil) }))

        state.proposals.append(proposal)
        run.proposalIDs.append(proposal.id)
        let text = "\(side.rawValue.capitalized) \(RiskEngine.quantityText(quantity, rules)) \(instrument.symbol) (about \(NumberText.money(proposal.notional, currency: ledger.currency)))"
        state.audit.append(time: now, actor: .agent, kind: .proposalCreated,
                           summary: "\(agent.name) proposed: \(text).", mode: .paper, agentID: agent.id,
                           ledgerID: ledger.id, proposalID: proposal.id, instrumentID: instrument.id,
                           details: ["quantity": String(quantity), "referencePrice": String(price),
                                     "strategyVersion": String(agent.strategyVersion), "signalID": signal.id.uuidString])

        if agent.reviewEachPaperTrade {
            run.steps.append(RunStep(kind: .proposal, outcome: .info, instrumentID: instrument.id,
                                     title: "\(instrument.symbol): waiting for your approval", detail: text + "."))
            notify(EngineNotice(kind: .approvalNeeded, title: "\(agent.name) wants to trade",
                                body: "Paper: \(text). Review it to approve or reject.",
                                agentID: agent.id, proposalID: proposal.id, instrumentID: instrument.id))
            return
        }
        execute(proposalID: proposal.id, approvedBy: .agent, run: &run, now: now)
    }

    internal func orderRequest(for proposal: TradeProposal) -> OrderRequest {
        OrderRequest(clientOrderID: proposal.clientOrderID, ledgerID: proposal.ledgerID, instrument: proposal.instrument,
                     side: proposal.side, type: .market, quantity: proposal.quantity, timeInForce: .day,
                     source: .agent(proposal.agentID, proposal: proposal.id), mode: proposal.mode,
                     signalBarTime: proposal.signalBarTime)
    }

    /// Submits the order for a proposal. The order goes through `submit`, so the risk engine
    /// judges it again against the prices of this moment.
    @discardableResult
    internal mutating func execute(proposalID: UUID, approvedBy actor: AuditActor, run: inout AgentRun, now: Date) -> OrderResult? {
        guard let index = state.proposals.firstIndex(where: { $0.id == proposalID }) else { return nil }
        let proposal = state.proposals[index]
        let result = submit(orderRequest(for: proposal), now: now)
        state.proposals[index].resolvedAt = now
        state.proposals[index].risk = result.risk
        state.proposals[index].orderID = result.order?.id
        if let order = result.order { run.orderIDs.append(order.id) }
        switch result {
        case .accepted(let order, let fills, _):
            state.proposals[index].status = .submitted
            let detail: String
            if order.status == .filled, let fill = fills.last {
                detail = "Filled at \(NumberText.money(fill.price))."
            } else if order.status == .partiallyFilled {
                detail = "Partly filled; the rest is still working."
            } else {
                detail = order.statusNote ?? "The order is working."
            }
            state.proposals[index].resolutionNote = detail
            run.steps.append(RunStep(kind: .execution, outcome: .ok, instrumentID: proposal.instrument.id,
                                     title: "\(proposal.instrument.symbol): paper order \(order.status.displayName.lowercased())", detail: detail))
        case .rejected(_, let risk):
            state.proposals[index].status = .failed
            state.proposals[index].resolutionNote = risk.summary
            run.steps.append(RunStep(kind: .execution, outcome: .failed, instrumentID: proposal.instrument.id,
                                     title: "\(proposal.instrument.symbol): order refused", detail: risk.summary))
            state.audit.append(time: now, actor: .system, kind: .proposalFailed,
                               summary: "\(proposal.side.rawValue.capitalized) \(proposal.instrument.symbol) could not be placed: \(risk.summary)",
                               mode: proposal.mode, agentID: proposal.agentID, ledgerID: proposal.ledgerID,
                               proposalID: proposal.id, instrumentID: proposal.instrument.id)
        }
        return result
    }

    // MARK: Rebalancing

    internal mutating func rebalance(prepared: [(Instrument, [Bar], DataProvenance)], agentIndex: Int,
                                     run: inout AgentRun, now: Date) {
        let agent = state.agents[agentIndex]
        guard let config = agent.spec.rebalance else { return }
        guard agent.mode == .paper, let ledger = state.ledger(agent.ledgerID) else {
            run.steps.append(RunStep(kind: .note, outcome: .info, title: "Rebalancing needs a paper portfolio",
                                     detail: "Switch this agent to Paper trading to see its rebalancing trades."))
            return
        }
        let available = Dictionary(uniqueKeysWithValues: prepared.map { ($0.0.id, $0) })
        // Every target needs real data, or the weights would be worked out on a partial picture.
        let missing = config.targets.keys.filter { available[$0] == nil || state.quotes[$0] == nil }
        guard missing.isEmpty else {
            run.steps.append(RunStep(kind: .data, outcome: .failed, title: "Rebalance skipped",
                                     detail: "Prices are missing for \(missing.sorted().joined(separator: ", ")), so no trades were worked out."))
            return
        }
        var values: [String: Double] = [:]
        for id in config.targets.keys { values[id] = ledger.position(id)?.marketValue ?? 0 }
        let trades = StrategyEvaluator.rebalanceTrades(config: config, values: values, equity: ledger.equity)
        if trades.isEmpty {
            run.steps.append(RunStep(kind: .signal, outcome: .info, title: "Holdings are on target",
                                     detail: "Nothing has drifted more than \(Operand.trim(config.driftThresholdPct)) points from its target.",
                                     evidence: config.targets.sorted { $0.key < $1.key }.map { id, target in
                                         Evidence(label: id.split(separator: ":").last.map(String.init) ?? id,
                                                  value: String(format: "%.1f%% (target %.1f%%)", (values[id] ?? 0) / max(ledger.equity, 0.01) * 100, target))
                                     }))
            return
        }
        for trade in trades {
            guard let (instrument, bars, provenance) = available[trade.instrumentID], let last = bars.last else { continue }
            let decision = SignalDecision(
                action: trade.side == .buy ? .buy : .sell,
                headline: String(format: "Rebalance: %@ is %.1f%% of the portfolio; the target is %.1f%%.", instrument.symbol, trade.currentPct, trade.targetPct),
                evidence: [Evidence(label: "Current weight", value: String(format: "%.1f%%", trade.currentPct)),
                           Evidence(label: "Target weight", value: String(format: "%.1f%%", trade.targetPct)),
                           Evidence(label: "Trade", value: "\(trade.side.rawValue.capitalized) \(NumberText.money(trade.notional, currency: ledger.currency))")],
                barTime: last.time, close: last.close, exitReason: trade.side == .sell ? .rebalance : nil)
            handle(decision, instrument: instrument, provenance: provenance, targetNotional: trade.notional,
                   agentIndex: agentIndex, run: &run, now: now)
        }
    }

    // MARK: Finishing a run

    internal mutating func finish(_ run: inout AgentRun, agentIndex: Int, dataFailures: Int, checked: Int, now: Date,
                                  overrideRun: AgentRun?) {
        if let overrideRun { run = overrideRun }
        let agentID = state.agents[agentIndex].id
        run.finishedAt = now
        if overrideRun == nil {
            let signals = run.signalIDs.count
            let orders = run.orderIDs.count
            let blocked = run.steps.filter { $0.outcome == .blocked }.count
            let waiting = state.proposals.filter { run.proposalIDs.contains($0.id) && $0.status == .pending }.count
            var parts = ["Checked \(checked) asset\(checked == 1 ? "" : "s")"]
            if signals > 0 { parts.append("\(signals) signal\(signals == 1 ? "" : "s")") }
            if orders > 0 { parts.append("\(orders) order\(orders == 1 ? "" : "s")") }
            if waiting > 0 { parts.append("\(waiting) waiting for approval") }
            if blocked > 0 { parts.append("\(blocked) blocked") }
            if dataFailures > 0 { parts.append("\(dataFailures) without data") }
            if signals == 0 && orders == 0 && blocked == 0 && dataFailures == 0 { parts.append("nothing to do") }
            run.summary = parts.joined(separator: " · ")
            run.status = checked > 0 && dataFailures == checked ? .failed : .completed
        }

        // The agent may have been paused by a circuit breaker during the run.
        if let index = state.agents.firstIndex(where: { $0.id == agentID }) {
            state.agents[index].lastRunAt = now
            state.agents[index].nextRunAt = now.addingTimeInterval(Double(state.agents[index].schedule.intervalMinutes) * 60)
            if run.status == .failed {
                state.agents[index].consecutiveErrors += 1
                state.agents[index].lastError = "No usable market data for any asset."
                if state.agents[index].consecutiveErrors == 1 {
                    notify(EngineNotice(kind: .dataUnavailable, title: "\(state.agents[index].name): market data unavailable",
                                        body: "No usable prices came back, so nothing was traded. It will try again.",
                                        agentID: agentID))
                }
                if state.agents[index].consecutiveErrors >= 5 {
                    try? pauseAgent(id: agentID, reason: .repeatedErrors, now: now)
                }
            } else if run.status == .completed {
                state.agents[index].consecutiveErrors = 0
                state.agents[index].lastError = nil
            }
        }
        state.runs.append(run)
        // Keep each agent's trace list short; orders and the audit trail hold the long record.
        let mine = state.runs.enumerated().filter { $0.element.agentID == agentID }
        if mine.count > 120 {
            let drop = Set(mine.prefix(mine.count - 100).map(\.element.id))
            state.runs.removeAll { drop.contains($0.id) }
        }
    }

    // MARK: - Proposals

    /// A person approves a waiting proposal. The order is checked again against current
    /// prices before it is placed, and the proposal says plainly whether an order went in.
    @discardableResult
    mutating func approveProposal(id: UUID, now: Date) throws -> OrderResult {
        guard let index = state.proposals.firstIndex(where: { $0.id == id }) else { throw TradingError.notFound("That proposal") }
        let proposal = state.proposals[index]
        guard proposal.status == .pending else {
            throw TradingError.notAllowed("This proposal is already \(proposal.status.displayName.lowercased()).")
        }
        guard now < proposal.expiresAt else {
            expireStaleProposals(now: now)
            throw TradingError.notAllowed("This proposal has expired. The agent will look again on its next run.")
        }
        guard let agent = state.agent(proposal.agentID) else { throw TradingError.notFound("That agent") }
        guard agent.strategyVersion == proposal.strategyVersion else {
            throw TradingError.notAllowed("The strategy changed after this was proposed.")
        }
        state.audit.append(time: now, actor: .user, kind: .proposalApproved,
                           summary: "You approved: \(proposal.side.rawValue) \(proposal.instrument.symbol) for \(agent.name).",
                           mode: proposal.mode, agentID: agent.id, ledgerID: proposal.ledgerID, proposalID: id,
                           instrumentID: proposal.instrument.id)
        var scratch = AgentRun(agentID: agent.id, strategyVersion: agent.strategyVersion, trigger: .manual, startedAt: now)
        guard let result = execute(proposalID: id, approvedBy: .user, run: &scratch, now: now) else {
            throw TradingError.notFound("That proposal")
        }
        return result
    }

    mutating func rejectProposal(id: UUID, now: Date) throws {
        guard let index = state.proposals.firstIndex(where: { $0.id == id }) else { throw TradingError.notFound("That proposal") }
        guard state.proposals[index].status == .pending else { return }
        state.proposals[index].status = .rejected
        state.proposals[index].resolvedAt = now
        state.proposals[index].resolutionNote = "Rejected by you."
        let proposal = state.proposals[index]
        state.audit.append(time: now, actor: .user, kind: .proposalRejected,
                           summary: "You rejected: \(proposal.side.rawValue) \(proposal.instrument.symbol).",
                           mode: proposal.mode, agentID: proposal.agentID, ledgerID: proposal.ledgerID, proposalID: id,
                           instrumentID: proposal.instrument.id)
    }

    internal mutating func expirePendingProposals(agentID: UUID, note: String, now: Date) {
        for index in state.proposals.indices where state.proposals[index].agentID == agentID && state.proposals[index].status == .pending {
            expire(proposalAt: index, note: note, now: now)
        }
    }

    internal mutating func expireStaleProposals(now: Date) {
        for index in state.proposals.indices where state.proposals[index].status == .pending && now >= state.proposals[index].expiresAt {
            expire(proposalAt: index, note: "Nobody approved it in time.", now: now)
        }
    }

    private mutating func expire(proposalAt index: Int, note: String, now: Date) {
        state.proposals[index].status = .expired
        state.proposals[index].resolvedAt = now
        state.proposals[index].resolutionNote = note
        let proposal = state.proposals[index]
        state.audit.append(time: now, actor: .system, kind: .proposalExpired,
                           summary: "Proposal to \(proposal.side.rawValue) \(proposal.instrument.symbol) expired. \(note)",
                           mode: proposal.mode, agentID: proposal.agentID, ledgerID: proposal.ledgerID,
                           proposalID: proposal.id, instrumentID: proposal.instrument.id)
    }

    // MARK: - Scheduling

    /// Agents whose next run time has arrived.
    func dueAgents(at now: Date) -> [TradingAgent] {
        guard !state.accountPolicy.killSwitchEngaged else { return [] }
        return state.agents.filter { $0.isDue(at: now) && !$0.mode.isLive }
    }

    /// Every instrument that needs a fresh quote: open orders, positions and pending proposals.
    func instrumentsNeedingQuotes() -> [Instrument] {
        var seen = Set<String>()
        var out: [Instrument] = []
        func add(_ instrument: Instrument) {
            if seen.insert(instrument.id).inserted { out.append(instrument) }
        }
        for order in state.orders where order.status.isOpen { add(order.instrument) }
        for ledger in state.ledgers { for position in ledger.positions { add(position.instrument) } }
        for proposal in state.proposals where proposal.status == .pending { add(proposal.instrument) }
        return out
    }
}
