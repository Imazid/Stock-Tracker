import XCTest
@testable import TradingCore

/// End-to-end tests of the pipeline: market data → strategy → signal → risk check →
/// proposal → approval → simulated fill → ledger → audit trail.
final class EngineTests: XCTestCase {

    private func draft(review: Bool = false, mode: AgentMode = .paper, universe: [Instrument] = [Fx.aapl],
                       budget: Double = 5_000, policy: RiskPolicy? = nil) -> AgentDraft {
        AgentDraft(name: "Momo", mode: mode, spec: Fx.aboveAverageSpec(universe), budget: budget, maxPositionPct: 10,
                   riskPolicy: policy, reviewEachPaperTrade: review)
    }

    /// A snapshot in which AAPL closed well above its 20-day average.
    private func bullish(_ instrument: Instrument = Fx.aapl, now: Date = Fx.now) -> MarketSnapshot {
        let closes = Fx.risingCloses()
        var snapshot = MarketSnapshot()
        snapshot.series[instrument.id] = BarSeries(instrument: instrument, timeframe: .day,
                                                   bars: Fx.dailyBars(closes: closes, days: Fx.usTradingDays(count: closes.count, before: now)),
                                                   provenance: .fixture("test"), fetchedAt: now)
        snapshot.quotes[instrument.id] = Fx.quote(instrument, last: closes.last!, time: now)
        return snapshot
    }

    private func kinds(_ engine: TradingEngine) -> [AuditKind] { engine.state.audit.events.map(\.kind) }

    // MARK: The vertical slice

    func testSignalToApprovalToFillToLedgerToAudit() throws {
        var engine = Fx.engine()
        let agent = try engine.createAgent(draft(review: true), now: Fx.now)
        let ledgerID = try XCTUnwrap(agent.ledgerID)
        XCTAssertEqual(engine.state.ledger(ledgerID)?.cash, 5_000)

        // 1–4. Market data → signal → risk → proposal.
        let run = try XCTUnwrap(engine.runAgent(id: agent.id, snapshot: bullish(), trigger: .manual, now: Fx.now))
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.signalIDs.count, 1)
        XCTAssertEqual(run.steps.map(\.kind), [.signal, .sizing, .risk, .proposal])
        let signal = try XCTUnwrap(engine.state.signals.first)
        XCTAssertEqual(signal.action, .buy)
        XCTAssertEqual(signal.strategyVersion, 1)
        XCTAssertFalse(signal.evidence.isEmpty)

        let proposal = try XCTUnwrap(engine.state.proposals.first)
        XCTAssertEqual(proposal.status, .pending)
        XCTAssertEqual(proposal.side, .buy)
        XCTAssertEqual(proposal.mode, .paper)
        XCTAssertTrue(proposal.risk.isApproved)
        XCTAssertLessThanOrEqual(proposal.notional, 500)               // 10% of $5,000
        XCTAssertGreaterThan(proposal.notional, 499)
        // A proposal is not an order: nothing has been placed and no money has moved.
        XCTAssertTrue(engine.state.orders.isEmpty)
        XCTAssertEqual(engine.state.ledger(ledgerID)?.cash, 5_000)
        XCTAssertEqual(engine.drainNotices().map(\.kind), [.approvalNeeded])

        // 5–6. Approval → simulated execution.
        let result = try engine.approveProposal(id: proposal.id, now: Fx.now.addingTimeInterval(60))
        guard case .accepted(let order, let fills, _) = result else { return XCTFail("order was refused: \(result.risk.summary)") }
        XCTAssertEqual(order.status, .filled)
        XCTAssertEqual(order.mode, .paper)
        XCTAssertEqual(fills.count, 1)
        XCTAssertEqual(fills[0].price, engine.state.quotes[Fx.aapl.id]?.ask)

        // 7. Portfolio update.
        let ledger = try XCTUnwrap(engine.state.ledger(ledgerID))
        let position = try XCTUnwrap(ledger.position(Fx.aapl.id))
        XCTAssertEqual(position.quantity, proposal.quantity)
        XCTAssertEqual(ledger.cash, Rounding.money(5_000 - fills[0].gross))
        XCTAssertEqual(ledger.equity, ledger.cash + position.marketValue, accuracy: 1e-9)
        let stored = try XCTUnwrap(engine.state.proposals.first)
        XCTAssertEqual(stored.status, .submitted)
        XCTAssertEqual(stored.orderID, order.id)

        // 8. Audit record: every step, in order, in an unbroken chain.
        XCTAssertEqual(kinds(engine), [.agentCreated, .signalGenerated, .proposalCreated, .proposalApproved, .orderSubmitted, .orderFilled])
        XCTAssertTrue(engine.state.audit.verify().isIntact)
        let fillEvent = try XCTUnwrap(engine.state.audit.events.last)
        XCTAssertEqual(fillEvent.orderID, order.id)
        XCTAssertEqual(fillEvent.proposalID, proposal.id)
        XCTAssertEqual(fillEvent.agentID, agent.id)
        XCTAssertEqual(fillEvent.mode, .paper)
        XCTAssertEqual(engine.drainNotices().map(\.kind), [.orderFilled])

        // The same proposal can't be approved twice.
        XCTAssertThrowsError(try engine.approveProposal(id: proposal.id, now: Fx.now.addingTimeInterval(90)))
        XCTAssertEqual(engine.state.orders.count, 1)
    }

    func testAutoPaperAgentTradesWithoutApprovalAndHoldsOnTheNextRun() throws {
        var engine = Fx.engine()
        let agent = try engine.createAgent(draft(), now: Fx.now)
        let run = try XCTUnwrap(engine.runAgent(id: agent.id, snapshot: bullish(), trigger: .schedule, now: Fx.now))
        XCTAssertEqual(run.orderIDs.count, 1)
        XCTAssertEqual(engine.state.orders.first?.status, .filled)
        XCTAssertEqual(engine.state.proposals.first?.status, .submitted)
        XCTAssertEqual(run.steps.last?.kind, .execution)

        // Same bar, an hour later: it already holds the position, so nothing new happens.
        let later = Fx.now.addingTimeInterval(3_600)
        let second = try XCTUnwrap(engine.runAgent(id: agent.id, snapshot: bullish(now: later), trigger: .schedule, now: later))
        XCTAssertTrue(second.orderIDs.isEmpty)
        XCTAssertEqual(engine.state.orders.count, 1)
        XCTAssertEqual(engine.state.signals.count, 1)
        XCTAssertEqual(engine.state.agent(agent.id)?.nextRunAt, later.addingTimeInterval(3_600))
    }

    func testAWaitingProposalIsNotDuplicatedByALaterRun() throws {
        var engine = Fx.engine()
        let agent = try engine.createAgent(draft(review: true), now: Fx.now)
        engine.runAgent(id: agent.id, snapshot: bullish(), trigger: .schedule, now: Fx.now)
        let later = Fx.now.addingTimeInterval(1_800)
        let second = try XCTUnwrap(engine.runAgent(id: agent.id, snapshot: bullish(now: later), trigger: .schedule, now: later))
        XCTAssertEqual(engine.state.pendingProposals.count, 1)
        XCTAssertEqual(engine.state.signals.count, 1)
        XCTAssertTrue(second.steps.contains { $0.title.contains("waiting for your approval") })
    }

    func testStopLossExitSellsThePositionAndBooksTheLoss() throws {
        var engine = Fx.engine()
        let agent = try engine.createAgent(draft(), now: Fx.now)
        engine.runAgent(id: agent.id, snapshot: bullish(), trigger: .schedule, now: Fx.now)
        let entry = try XCTUnwrap(engine.state.fills.first)

        // Next day: yesterday's bar closed 14% lower.
        let tomorrow = Fx.now.addingTimeInterval(86_400)
        let closes = Fx.risingCloses() + [105]
        var snapshot = MarketSnapshot()
        snapshot.series[Fx.aapl.id] = BarSeries(instrument: Fx.aapl, timeframe: .day,
                                                bars: Fx.dailyBars(closes: closes, days: Fx.usTradingDays(count: closes.count, before: tomorrow)),
                                                provenance: .fixture("test"), fetchedAt: tomorrow)
        snapshot.quotes[Fx.aapl.id] = Fx.quote(Fx.aapl, last: 105, time: tomorrow)
        let run = try XCTUnwrap(engine.runAgent(id: agent.id, snapshot: snapshot, trigger: .schedule, now: tomorrow))

        XCTAssertEqual(engine.state.signals.last?.exitReason, .stopLoss)
        XCTAssertEqual(run.orderIDs.count, 1)
        let exit = try XCTUnwrap(engine.state.fills.last)
        XCTAssertEqual(exit.side, .sell)
        XCTAssertEqual(exit.quantity, entry.quantity)
        let ledger = try XCTUnwrap(engine.state.ledger(agent.ledgerID))
        XCTAssertTrue(ledger.positions.isEmpty)
        XCTAssertEqual(exit.realizedPnL, Rounding.money(exit.gross - entry.gross))
        XCTAssertEqual(ledger.realizedPnL, exit.realizedPnL)
        XCTAssertEqual(ledger.cash, Rounding.money(5_000 + (exit.realizedPnL ?? 0)))
        XCTAssertLessThan(ledger.realizedPnL, 0)
        XCTAssertTrue(engine.state.audit.verify().isIntact)
    }

    func testARiskBlockedTradeIsRecordedAndNeverBecomesAnOrder() throws {
        var engine = Fx.engine()
        var policy = RiskPolicy.standard(budget: 5_000)
        policy.maxDailyNotional = 100                          // the $500 buy can't fit
        let agent = try engine.createAgent(draft(policy: policy), now: Fx.now)
        let run = try XCTUnwrap(engine.runAgent(id: agent.id, snapshot: bullish(), trigger: .schedule, now: Fx.now))
        let proposal = try XCTUnwrap(engine.state.proposals.first)
        XCTAssertEqual(proposal.status, .blocked)
        XCTAssertEqual(proposal.risk.failures.map(\.id), [.dailyNotional])
        XCTAssertTrue(engine.state.orders.isEmpty)
        XCTAssertEqual(engine.state.ledger(agent.ledgerID)?.cash, 5_000)
        XCTAssertTrue(run.steps.contains { $0.outcome == .blocked })
        XCTAssertTrue(kinds(engine).contains(.proposalBlocked))
        XCTAssertFalse(kinds(engine).contains(.orderSubmitted))
        XCTAssertEqual(engine.drainNotices().map(\.kind), [.proposalBlocked])
        XCTAssertThrowsError(try engine.approveProposal(id: proposal.id, now: Fx.now))    // blocked can't be approved
    }

    // MARK: Modes

    func testResearchAndSignalModesNeverCreateOrders() throws {
        var engine = Fx.engine()
        let research = try engine.createAgent(draft(mode: .researchOnly), now: Fx.now)
        XCTAssertNil(research.ledgerID)
        let researchRun = try XCTUnwrap(engine.runAgent(id: research.id, snapshot: bullish(), trigger: .manual, now: Fx.now))
        XCTAssertEqual(researchRun.steps.map(\.kind), [.research])
        XCTAssertTrue(engine.state.signals.isEmpty)

        let signals = try engine.createAgent(draft(mode: .signals), now: Fx.now)
        let signalRun = try XCTUnwrap(engine.runAgent(id: signals.id, snapshot: bullish(), trigger: .manual, now: Fx.now))
        XCTAssertEqual(signalRun.signalIDs.count, 1)
        XCTAssertEqual(engine.state.signals.first?.action, .buy)
        XCTAssertTrue(engine.state.proposals.isEmpty)
        XCTAssertTrue(engine.state.orders.isEmpty)
        XCTAssertTrue(engine.state.ledgers.isEmpty)
    }

    func testLiveModesAreRefusedEverywhere() throws {
        var engine = Fx.engine()
        // Creating a live agent.
        XCTAssertThrowsError(try engine.createAgent(draft(mode: .approvalRequired), now: Fx.now)) { error in
            guard case TradingError.liveNotAvailable(let reasons) = error else { return XCTFail("wrong error \(error)") }
            XCTAssertTrue(reasons.contains("No trading account is connected."))
        }
        XCTAssertTrue(engine.state.agents.isEmpty)

        // Promoting a paper agent.
        let agent = try engine.createAgent(draft(), now: Fx.now)
        XCTAssertThrowsError(try engine.setMode(agentID: agent.id, mode: .autonomousLive, now: Fx.now))
        XCTAssertEqual(engine.state.agent(agent.id)?.mode, .paper)
        XCTAssertEqual(kinds(engine).filter { $0 == .liveRequestRefused }.count, 2)

        // A read-only broker connection changes the reason, not the answer.
        engine.state.connections.append(BrokerConnection(adapterID: "snaptrade", name: "CommSec", environment: .live,
                                                         permissions: [.read], createdAt: Fx.now))
        XCTAssertTrue(engine.liveBlockers(for: nil).contains { $0.contains("read-only") })

        // A live order request is rejected, recorded as rejected, and moves no money.
        let portfolio = try engine.createPaperPortfolio(name: "Mine", startingCash: 10_000, now: Fx.now)
        engine.ingest(quotes: [Fx.quote(Fx.aapl, last: 100)], now: Fx.now)
        let request = OrderRequest(ledgerID: portfolio.id, instrument: Fx.aapl, side: .buy, quantity: 1, mode: .live)
        XCTAssertEqual(engine.preview(request, now: Fx.now)?.canSubmit, false)
        let result = engine.submit(request, now: Fx.now)
        XCTAssertFalse(result.isAccepted)
        XCTAssertEqual(result.order?.status, .rejected)
        XCTAssertEqual(result.risk.failures.map(\.id), [.authorization])
        XCTAssertTrue(engine.state.fills.isEmpty)
        XCTAssertEqual(engine.state.ledger(portfolio.id)?.cash, 10_000)
    }

    func testSwitchingAwayFromPaperCancelsWhatWasWaiting() throws {
        var engine = Fx.engine()
        let agent = try engine.createAgent(draft(review: true), now: Fx.now)
        engine.runAgent(id: agent.id, snapshot: bullish(), trigger: .manual, now: Fx.now)
        XCTAssertEqual(engine.state.pendingProposals.count, 1)
        try engine.setMode(agentID: agent.id, mode: .signals, now: Fx.now)
        XCTAssertTrue(engine.state.pendingProposals.isEmpty)
        XCTAssertEqual(engine.state.proposals.first?.status, .expired)
    }

    // MARK: Data honesty

    func testNoTradingOnMissingSyntheticStaleOrUnapprovedData() throws {
        // Missing data.
        var engine = Fx.engine()
        var agent = try engine.createAgent(draft(), now: Fx.now)
        var run = try XCTUnwrap(engine.runAgent(id: agent.id, snapshot: MarketSnapshot(failures: [Fx.aapl.id: "HTTP 500"]), trigger: .schedule, now: Fx.now))
        XCTAssertEqual(run.status, .failed)
        XCTAssertTrue(run.steps.first?.detail.contains("HTTP 500") == true)
        XCTAssertTrue(engine.state.signals.isEmpty && engine.state.orders.isEmpty)
        XCTAssertEqual(engine.drainNotices().map(\.kind), [.dataUnavailable])

        // Synthetic data.
        engine = Fx.engine()
        agent = try engine.createAgent(draft(), now: Fx.now)
        var snapshot = bullish()
        snapshot.series[Fx.aapl.id]?.provenance = .synthetic
        run = try XCTUnwrap(engine.runAgent(id: agent.id, snapshot: snapshot, trigger: .schedule, now: Fx.now))
        XCTAssertEqual(run.status, .failed)
        XCTAssertTrue(run.steps.first?.detail.contains("isn't real market data") == true)
        XCTAssertTrue(engine.state.signals.isEmpty)

        // Fixture data with the production setting.
        engine = TradingEngine()
        agent = try engine.createAgent(draft(), now: Fx.now)
        run = try XCTUnwrap(engine.runAgent(id: agent.id, snapshot: bullish(), trigger: .schedule, now: Fx.now))
        XCTAssertEqual(run.status, .failed)
        XCTAssertTrue(engine.state.quotes.isEmpty)                 // the fixture quote wasn't even stored

        // Stale history: the newest bar is three weeks old.
        engine = Fx.engine()
        agent = try engine.createAgent(draft(), now: Fx.now)
        let old = Fx.now.addingTimeInterval(-21 * 86_400)
        var stale = bullish(now: old)
        stale.quotes[Fx.aapl.id] = Fx.quote(Fx.aapl, last: 122.5)
        run = try XCTUnwrap(engine.runAgent(id: agent.id, snapshot: stale, trigger: .schedule, now: Fx.now))
        XCTAssertEqual(run.status, .failed)
        XCTAssertTrue(run.steps.first?.detail.contains("out of date") == true)
    }

    func testASignalWithoutALiveQuoteProposesNothing() throws {
        var engine = Fx.engine()
        let agent = try engine.createAgent(draft(), now: Fx.now)
        var snapshot = bullish()
        snapshot.quotes = [:]
        let run = try XCTUnwrap(engine.runAgent(id: agent.id, snapshot: snapshot, trigger: .schedule, now: Fx.now))
        XCTAssertEqual(run.signalIDs.count, 1)
        XCTAssertTrue(engine.state.proposals.isEmpty)
        XCTAssertTrue(run.steps.contains { $0.title.contains("no live quote") })
    }

    func testTodaysUnfinishedBarIsIgnored() throws {
        var engine = Fx.engine()
        let agent = try engine.createAgent(draft(), now: Fx.now)
        // History is flat (no signal). Only today's still-forming bar is far above the average.
        var days = Fx.usTradingDays(count: 40)
        days.append(Fx.date("2026-11-10T05:00:00Z"))
        let closes = [Double](repeating: 100, count: 40) + [150]
        var snapshot = MarketSnapshot()
        snapshot.series[Fx.aapl.id] = Fx.series(Fx.aapl, closes: closes, days: days)
        snapshot.quotes[Fx.aapl.id] = Fx.quote(Fx.aapl, last: 150)
        let run = try XCTUnwrap(engine.runAgent(id: agent.id, snapshot: snapshot, trigger: .schedule, now: Fx.now))
        XCTAssertTrue(run.signalIDs.isEmpty)
        XCTAssertTrue(engine.state.orders.isEmpty)
    }

    func testRepeatedDataFailuresPauseTheAgent() throws {
        var engine = Fx.engine()
        let agent = try engine.createAgent(draft(), now: Fx.now)
        for i in 0..<5 {
            engine.runAgent(id: agent.id, snapshot: MarketSnapshot(), trigger: .schedule, now: Fx.now.addingTimeInterval(Double(i) * 3_600))
        }
        XCTAssertEqual(engine.state.agent(agent.id)?.status, .paused)
        XCTAssertEqual(engine.state.agent(agent.id)?.pauseReason, .repeatedErrors)
        XCTAssertEqual(engine.drainNotices().map(\.kind), [.dataUnavailable, .agentPaused])
    }

    // MARK: Kill switch and pausing

    func testKillSwitchStopsEverythingUntilReleasedAndResumed() throws {
        var engine = Fx.engine()
        let saturday = Fx.date("2026-11-14T16:00:00Z")
        let a = try engine.createAgent(draft(), now: saturday)
        var second = draft(universe: [Fx.msft])
        second.name = "Second"
        let b = try engine.createAgent(second, now: saturday)
        // Market closed: A's order is accepted and waits for Monday's open.
        engine.runAgent(id: a.id, snapshot: bullish(now: saturday), trigger: .manual, now: saturday)
        XCTAssertEqual(engine.state.openOrders.count, 1)
        XCTAssertEqual(engine.state.openOrders.first?.statusNote, "Waiting for the market to open.")

        let cancelled = engine.engageKillSwitch(now: saturday)
        XCTAssertEqual(cancelled, 1)
        XCTAssertTrue(engine.state.openOrders.isEmpty)
        XCTAssertEqual(engine.state.orders.first?.status, .canceled)
        XCTAssertTrue(engine.state.agents.allSatisfy { $0.status == .paused && $0.pauseReason == .killSwitch })
        XCTAssertTrue(engine.dueAgents(at: saturday.addingTimeInterval(86_400)).isEmpty)

        let blockedRun = try XCTUnwrap(engine.runAgent(id: b.id, snapshot: bullish(Fx.msft, now: saturday), trigger: .manual, now: saturday))
        XCTAssertEqual(blockedRun.status, .skipped)
        XCTAssertThrowsError(try engine.resumeAgent(id: a.id, now: saturday))        // not while the switch is on

        engine.releaseKillSwitch(now: saturday)
        XCTAssertTrue(engine.state.agents.allSatisfy { $0.status == .paused })       // release does not restart anything
        try engine.resumeAgent(id: a.id, now: saturday)
        XCTAssertEqual(engine.state.agent(a.id)?.status, .active)
        XCTAssertEqual(engine.state.agent(b.id)?.status, .paused)
        XCTAssertTrue(kinds(engine).contains(.killSwitchEngaged) && kinds(engine).contains(.killSwitchReleased))
        XCTAssertTrue(engine.state.audit.verify().isIntact)
    }

    func testDrawdownLimitPausesTheAgent() throws {
        var engine = Fx.engine()
        engine.state.accountPolicy.maxSymbolExposurePct = 100
        var big = draft()
        big.spec.sizing = Sizing(mode: .percentOfEquity, value: 90)
        big.riskPolicy = RiskPolicy(maxOrderNotional: 5_000, maxPositionPct: 100, maxDailyNotional: 10_000)
        let agent = try engine.createAgent(big, now: Fx.now)
        engine.runAgent(id: agent.id, snapshot: bullish(), trigger: .schedule, now: Fx.now)
        XCTAssertEqual(engine.state.ledger(agent.ledgerID)?.positions.count, 1)
        _ = engine.drainNotices()

        // The price falls 20%: equity is about 18% below its peak, past the 15% limit.
        engine.ingest(quotes: [Fx.quote(Fx.aapl, last: 98, time: Fx.now.addingTimeInterval(600))], now: Fx.now.addingTimeInterval(600))
        XCTAssertEqual(engine.state.agent(agent.id)?.status, .paused)
        XCTAssertEqual(engine.state.agent(agent.id)?.pauseReason, .drawdownLimit)
        let notice = try XCTUnwrap(engine.drainNotices().first)
        XCTAssertEqual(notice.kind, .agentPaused)
        XCTAssertTrue(notice.body.contains("still holds 1 position"))
    }

    // MARK: Manual orders

    private func portfolio(_ engine: inout TradingEngine, cash: Double = 10_000, last: Double = 100, dayVolume: Double? = nil) throws -> Ledger {
        let ledger = try engine.createPaperPortfolio(name: "Practice", startingCash: cash, now: Fx.now)
        engine.ingest(quotes: [Fx.quote(Fx.aapl, last: last, dayVolume: dayVolume)],
                      stats: [Fx.aapl.id: InstrumentStats(averageDollarVolume: 1e9, dailyVolatilityPct: 2)], now: Fx.now)
        return ledger
    }

    func testManualMarketOrderPreviewAndFill() throws {
        var engine = Fx.engine()
        let ledger = try portfolio(&engine)
        let request = OrderRequest(ledgerID: ledger.id, instrument: Fx.aapl, side: .buy, notional: 1_000)
        let preview = try XCTUnwrap(engine.preview(request, now: Fx.now))
        XCTAssertTrue(preview.canSubmit)
        XCTAssertEqual(preview.estimatedPrice, 100.01)
        XCTAssertEqual(preview.quantity, 9.999)                      // $1,000 ÷ 100.01, floored to six decimals
        XCTAssertEqual(preview.cashAfter, Rounding.money(10_000 - preview.estimatedValue))
        XCTAssertEqual(preview.mode, .paper)
        XCTAssertFalse(preview.willQueueUntilOpen)
        XCTAssertTrue(engine.state.orders.isEmpty)                   // a preview places nothing

        let result = engine.submit(request, now: Fx.now)
        XCTAssertEqual(result.order?.status, .filled)
        XCTAssertEqual(engine.state.ledger(ledger.id)?.position(Fx.aapl.id)?.quantity, 9.999)
        XCTAssertEqual(kinds(engine).suffix(2), [.orderSubmitted, .orderFilled])
    }

    func testRefusedOrdersAreRecordedAsRejectedAndMoveNoMoney() throws {
        var engine = Fx.engine()
        let ledger = try portfolio(&engine, cash: 1_000)
        let tooBig = engine.submit(OrderRequest(ledgerID: ledger.id, instrument: Fx.aapl, side: .buy, quantity: 20), now: Fx.now)
        XCTAssertFalse(tooBig.isAccepted)
        XCTAssertEqual(tooBig.order?.status, .rejected)
        XCTAssertEqual(tooBig.risk.failures.map(\.id), [.buyingPower])
        XCTAssertTrue(tooBig.order?.statusNote?.contains("only $1000.00 is available") == true)

        let short = engine.submit(OrderRequest(ledgerID: ledger.id, instrument: Fx.aapl, side: .sell, quantity: 1), now: Fx.now)
        XCTAssertEqual(short.risk.failures.map(\.id), [.holdings])

        XCTAssertTrue(engine.state.fills.isEmpty)
        XCTAssertEqual(engine.state.ledger(ledger.id)?.cash, 1_000)
        XCTAssertEqual(engine.state.orders.map(\.status), [.rejected, .rejected])
        XCTAssertEqual(kinds(engine).filter { $0 == .orderRejected }.count, 2)
        XCTAssertEqual(engine.drainNotices().map(\.kind), [.orderRejected, .orderRejected])
    }

    func testTheSameOrderIsNeverPlacedTwice() throws {
        var engine = Fx.engine()
        let ledger = try portfolio(&engine)
        let request = OrderRequest(clientOrderID: "tap-1", ledgerID: ledger.id, instrument: Fx.aapl, side: .buy, quantity: 2)
        XCTAssertTrue(engine.submit(request, now: Fx.now).isAccepted)
        let again = engine.submit(request, now: Fx.now.addingTimeInterval(1))
        XCTAssertFalse(again.isAccepted)
        XCTAssertEqual(again.risk.failures.map(\.id), [.duplicate])
        XCTAssertNil(again.order)                                     // no second record
        XCTAssertEqual(engine.state.orders.count, 1)
        XCTAssertEqual(engine.state.ledger(ledger.id)?.position(Fx.aapl.id)?.quantity, 2)
    }

    func testLimitOrderRestsThenFillsThenCannotBeCancelled() throws {
        var engine = Fx.engine()
        let ledger = try portfolio(&engine)
        let result = engine.submit(OrderRequest(ledgerID: ledger.id, instrument: Fx.aapl, side: .buy, type: .limit,
                                                quantity: 5, limitPrice: 95, timeInForce: .gtc), now: Fx.now)
        let order = try XCTUnwrap(result.order)
        XCTAssertEqual(order.status, .accepted)
        XCTAssertTrue(engine.state.fills.isEmpty)

        engine.ingest(quotes: [Fx.quote(Fx.aapl, last: 97, time: Fx.now.addingTimeInterval(60))], now: Fx.now.addingTimeInterval(60))
        XCTAssertTrue(engine.state.fills.isEmpty)
        engine.ingest(quotes: [Fx.quote(Fx.aapl, last: 94.9, time: Fx.now.addingTimeInterval(120))], now: Fx.now.addingTimeInterval(120))
        XCTAssertEqual(engine.state.orders.first?.status, .filled)
        XCTAssertLessThanOrEqual(try XCTUnwrap(engine.state.fills.first).price, 95)
        XCTAssertFalse(engine.cancelOrder(id: order.id, now: Fx.now.addingTimeInterval(180)))
    }

    func testAnOpenOrderCanBeCancelledAndADayOrderExpires() throws {
        var engine = Fx.engine()
        let ledger = try portfolio(&engine)
        let first = try XCTUnwrap(engine.submit(OrderRequest(ledgerID: ledger.id, instrument: Fx.aapl, side: .buy, type: .limit,
                                                             quantity: 1, limitPrice: 90), now: Fx.now).order)
        XCTAssertTrue(engine.cancelOrder(id: first.id, now: Fx.now))
        XCTAssertEqual(engine.state.orders.first?.status, .canceled)

        let second = try XCTUnwrap(engine.submit(OrderRequest(ledgerID: ledger.id, instrument: Fx.aapl, side: .buy, type: .limit,
                                                              quantity: 1, limitPrice: 90), now: Fx.now).order)
        XCTAssertEqual(second.expiresAt, Fx.date("2026-11-10T21:00:00Z"))
        let afterClose = Fx.date("2026-11-10T21:05:00Z")
        engine.ingest(quotes: [], now: afterClose)
        XCTAssertEqual(engine.state.orders.last?.status, .expired)
        XCTAssertTrue(kinds(engine).contains(.orderExpired))
    }

    func testALargeOrderFillsInPartsAndIsTrackedAcrossThem() throws {
        var engine = Fx.engine()
        let ledger = try portfolio(&engine, cash: 100_000, dayVolume: 10_000)        // 100 shares per match
        let order = try XCTUnwrap(engine.submit(OrderRequest(ledgerID: ledger.id, instrument: Fx.aapl, side: .buy, quantity: 250,
                                                             timeInForce: .gtc), now: Fx.now).order)
        XCTAssertEqual(order.status, .partiallyFilled)
        XCTAssertEqual(order.filledQuantity, 100)
        for minute in 1...2 {
            let time = Fx.now.addingTimeInterval(Double(minute) * 60)
            engine.ingest(quotes: [Fx.quote(Fx.aapl, last: 100 + Double(minute), time: time, dayVolume: 10_000)], now: time)
        }
        let done = try XCTUnwrap(engine.state.orders.first)
        XCTAssertEqual(done.status, .filled)
        XCTAssertEqual(done.filledQuantity, 250)
        XCTAssertEqual(engine.state.fills.map(\.quantity), [100, 100, 50])
        let expectedAverage = engine.state.fills.reduce(0.0) { $0 + $1.price * $1.quantity } / 250
        XCTAssertEqual(done.averageFillPrice, expectedAverage, accuracy: 1e-9)
        XCTAssertEqual(engine.state.ledger(ledger.id)?.position(Fx.aapl.id)?.quantity, 250)
        XCTAssertEqual(kinds(engine).filter { $0 == .orderPartiallyFilled }.count, 2)
        XCTAssertEqual(kinds(engine).filter { $0 == .orderFilled }.count, 1)
    }

    func testAnOrderPlacedWhileShutWaitsForTheOpenAndIsCancelledOnAGap() throws {
        let saturday = Fx.date("2026-11-14T16:00:00Z")
        let mondayOpen = Fx.date("2026-11-16T14:31:00Z")

        var engine = Fx.engine()
        var ledger = try engine.createPaperPortfolio(name: "Practice", startingCash: 10_000, now: saturday)
        engine.ingest(quotes: [Fx.quote(Fx.aapl, last: 100, time: saturday)], now: saturday)
        let request = OrderRequest(ledgerID: ledger.id, instrument: Fx.aapl, side: .buy, quantity: 10)
        XCTAssertEqual(engine.preview(request, now: saturday)?.willQueueUntilOpen, true)
        XCTAssertEqual(engine.preview(request, now: saturday)?.nextOpen, Fx.date("2026-11-16T14:30:00Z"))
        XCTAssertEqual(engine.submit(request, now: saturday).order?.status, .accepted)
        XCTAssertTrue(engine.state.fills.isEmpty)
        engine.ingest(quotes: [Fx.quote(Fx.aapl, last: 101, time: mondayOpen)], now: mondayOpen)
        XCTAssertEqual(engine.state.orders.first?.status, .filled)
        XCTAssertEqual(engine.state.fills.first?.price, engine.state.quotes[Fx.aapl.id]?.ask)

        // Same again, but Monday opens 15% higher: the order is cancelled, not filled.
        engine = Fx.engine()
        ledger = try engine.createPaperPortfolio(name: "Practice", startingCash: 10_000, now: saturday)
        engine.ingest(quotes: [Fx.quote(Fx.aapl, last: 100, time: saturday)], now: saturday)
        engine.submit(OrderRequest(ledgerID: ledger.id, instrument: Fx.aapl, side: .buy, quantity: 10), now: saturday)
        engine.ingest(quotes: [Fx.quote(Fx.aapl, last: 115, time: mondayOpen)], now: mondayOpen)
        XCTAssertEqual(engine.state.orders.first?.status, .canceled)
        XCTAssertTrue(engine.state.orders.first?.statusNote?.contains("price moved") == true)
        XCTAssertTrue(engine.state.fills.isEmpty)
        XCTAssertEqual(engine.state.ledger(ledger.id)?.cash, 10_000)
    }

    func testCryptoTradesOnASaturdayInFractionsWithAFee() throws {
        var engine = Fx.engine()
        let saturday = Fx.date("2026-11-14T16:00:00Z")
        let ledger = try engine.createPaperPortfolio(name: "Crypto practice", startingCash: 5_000, now: saturday)
        engine.ingest(quotes: [Fx.quote(Fx.btc, last: 64_000, spreadBps: 4, time: saturday)], now: saturday)
        let result = engine.submit(OrderRequest(ledgerID: ledger.id, instrument: Fx.btc, side: .buy, notional: 1_000), now: saturday)
        let order = try XCTUnwrap(result.order)
        XCTAssertEqual(order.status, .filled)
        let fill = try XCTUnwrap(engine.state.fills.first)
        XCTAssertEqual(fill.fee, Rounding.money(fill.gross * 0.0025))
        XCTAssertTrue(Rounding.isMultiple(fill.quantity, of: 0.000_000_01))
        XCTAssertEqual(engine.state.ledger(ledger.id)?.cash, Rounding.money(5_000 - fill.gross - fill.fee))
    }

    // MARK: Housekeeping

    func testStrategyChangesAreVersionedAndVoidOldProposals() throws {
        var engine = Fx.engine()
        let agent = try engine.createAgent(draft(review: true), now: Fx.now)
        engine.runAgent(id: agent.id, snapshot: bullish(), trigger: .manual, now: Fx.now)
        let proposal = try XCTUnwrap(engine.state.pendingProposals.first)

        var spec = agent.spec
        spec.protections.stopLossPct = 5
        try engine.updateStrategy(agentID: agent.id, spec: spec, note: "Tighter stop", author: .copilot, now: Fx.now)
        let updated = try XCTUnwrap(engine.state.agent(agent.id))
        XCTAssertEqual(updated.strategyVersion, 2)
        XCTAssertEqual(updated.versions.map(\.version), [1, 2])
        XCTAssertEqual(updated.versions[0].spec.protections.stopLossPct, 8)        // history is kept
        XCTAssertEqual(updated.versions[1].author, .copilot)
        XCTAssertEqual(engine.state.proposals.first?.status, .expired)
        XCTAssertThrowsError(try engine.approveProposal(id: proposal.id, now: Fx.now))

        // An invalid strategy is refused and changes nothing.
        spec.exit = nil
        spec.protections = Protections()
        XCTAssertThrowsError(try engine.updateStrategy(agentID: agent.id, spec: spec, note: "", now: Fx.now))
        XCTAssertEqual(engine.state.agent(agent.id)?.strategyVersion, 2)
        XCTAssertEqual(engine.state.audit.events.last?.actor, .copilot)
    }

    func testProposalsExpireWhenNobodyDecides() throws {
        var engine = Fx.engine()
        let agent = try engine.createAgent(draft(review: true), now: Fx.now)
        engine.runAgent(id: agent.id, snapshot: bullish(), trigger: .manual, now: Fx.now)
        let proposal = try XCTUnwrap(engine.state.pendingProposals.first)
        let later = Fx.now.addingTimeInterval(86_400 + 60)
        XCTAssertThrowsError(try engine.approveProposal(id: proposal.id, now: later))
        XCTAssertEqual(engine.state.proposals.first?.status, .expired)
        XCTAssertTrue(engine.state.orders.isEmpty)
    }

    func testRejectingAProposalPlacesNothing() throws {
        var engine = Fx.engine()
        let agent = try engine.createAgent(draft(review: true), now: Fx.now)
        engine.runAgent(id: agent.id, snapshot: bullish(), trigger: .manual, now: Fx.now)
        let proposal = try XCTUnwrap(engine.state.pendingProposals.first)
        try engine.rejectProposal(id: proposal.id, now: Fx.now)
        XCTAssertEqual(engine.state.proposals.first?.status, .rejected)
        XCTAssertTrue(engine.state.orders.isEmpty)
        XCTAssertEqual(kinds(engine).last, .proposalRejected)
    }

    func testCreationValidatesEverything() {
        var engine = Fx.engine()
        var bad = draft()
        bad.name = " "
        bad.budget = 5
        bad.spec.universe = []
        XCTAssertThrowsError(try engine.createAgent(bad, now: Fx.now)) { error in
            guard case TradingError.invalid(let problems) = error else { return XCTFail() }
            XCTAssertEqual(problems.count, 3)
        }
        XCTAssertThrowsError(try engine.createPaperPortfolio(name: "x", startingCash: 1, now: Fx.now))
        XCTAssertThrowsError(try engine.createPaperPortfolio(name: "x", startingCash: 1_000, currency: "EUR", now: Fx.now))
        XCTAssertTrue(engine.state.agents.isEmpty && engine.state.ledgers.isEmpty)
        XCTAssertTrue(engine.state.audit.events.isEmpty)
    }

    func testResetAndDeletePortfolio() throws {
        var engine = Fx.engine()
        let ledger = try portfolio(&engine)
        engine.submit(OrderRequest(ledgerID: ledger.id, instrument: Fx.aapl, side: .buy, quantity: 10), now: Fx.now)
        engine.submit(OrderRequest(ledgerID: ledger.id, instrument: Fx.aapl, side: .buy, type: .limit, quantity: 1, limitPrice: 80, timeInForce: .gtc), now: Fx.now)
        try engine.resetPaperPortfolio(id: ledger.id, now: Fx.now)
        let reset = try XCTUnwrap(engine.state.ledger(ledger.id))
        XCTAssertEqual(reset.cash, 10_000)
        XCTAssertTrue(reset.positions.isEmpty)
        XCTAssertTrue(engine.state.openOrders.isEmpty)

        let agent = try engine.createAgent(draft(), now: Fx.now)
        XCTAssertThrowsError(try engine.deletePaperPortfolio(id: try XCTUnwrap(agent.ledgerID), now: Fx.now))
        try engine.deleteAgent(id: agent.id, now: Fx.now)
        XCTAssertEqual(engine.state.ledgers.map(\.id), [ledger.id])
        try engine.deletePaperPortfolio(id: ledger.id, now: Fx.now)
        XCTAssertTrue(engine.state.ledgers.isEmpty)
        XCTAssertTrue(engine.state.audit.verify().isIntact)            // deleting things never deletes history
    }

    func testStateSurvivesSaveAndLoadWithItsAuditChainIntact() throws {
        var engine = Fx.engine()
        let agent = try engine.createAgent(draft(), now: Fx.now)
        engine.runAgent(id: agent.id, snapshot: bullish(), trigger: .schedule, now: Fx.now)
        let data = try TradingCodec.encoder().encode(engine.state)
        let loaded = try TradingCodec.decoder().decode(TradingState.self, from: data)
        XCTAssertEqual(loaded.agents.first?.spec, agent.spec)
        XCTAssertEqual(loaded.orders, engine.state.orders)
        XCTAssertEqual(loaded.fills, engine.state.fills)
        XCTAssertEqual(loaded.ledger(agent.ledgerID)?.cash, engine.state.ledger(agent.ledgerID)?.cash)
        XCTAssertEqual(loaded.audit.events.count, engine.state.audit.events.count)
        XCTAssertTrue(loaded.audit.verify().isIntact)
        // Reloaded state keeps working: the same order key is still refused.
        var resumed = TradingEngine(state: loaded)
        let key = try XCTUnwrap(loaded.orders.first?.clientOrderID)
        let repeated = resumed.submit(OrderRequest(clientOrderID: key, ledgerID: try XCTUnwrap(agent.ledgerID), instrument: Fx.aapl,
                                                   side: .buy, quantity: 1, source: .agent(agent.id)), now: Fx.now.addingTimeInterval(600))
        XCTAssertFalse(repeated.isAccepted)
    }

    func testScheduledBuyAndRebalanceAgents() throws {
        var engine = Fx.engine()
        // Dollar-cost averaging: $100 of SPY, then nothing until five bars have passed.
        let dca = AgentDraft(name: "DCA", mode: .paper, spec: AgentTemplates.dollarCostAveraging([Fx.spy]), budget: 5_000, maxPositionPct: 60)
        let dcaAgent = try engine.createAgent(dca, now: Fx.now)
        let flat = [Double](repeating: 400, count: 60)
        engine.runAgent(id: dcaAgent.id, snapshot: Fx.snapshot([(Fx.spy, flat, 400)]), trigger: .schedule, now: Fx.now)
        XCTAssertEqual(engine.state.fills.count, 1)
        XCTAssertEqual(try XCTUnwrap(engine.state.fills.first).gross, 100, accuracy: 0.05)
        let later = Fx.now.addingTimeInterval(3_600)
        var again = Fx.snapshot([(Fx.spy, flat, 400)])
        again.quotes[Fx.spy.id] = Fx.quote(Fx.spy, last: 400, time: later)
        let second = try XCTUnwrap(engine.runAgent(id: dcaAgent.id, snapshot: again, trigger: .schedule, now: later))
        XCTAssertEqual(engine.state.fills.count, 1)
        XCTAssertTrue(second.steps.contains { $0.detail.contains("Next scheduled buy") })

        // Rebalancing from cash: buys each fund up to its target.
        engine = Fx.engine()
        engine.state.accountPolicy.maxSymbolExposurePct = 100
        let funds = UniverseCatalog.balancedETFs
        var rebalance = AgentDraft(name: "Mix", mode: .paper, spec: AgentTemplates.etfRebalancing(funds), budget: 10_000, maxPositionPct: 70)
        rebalance.riskPolicy = RiskPolicy(maxOrderNotional: 10_000, maxPositionPct: 70, maxDailyNotional: 20_000)
        let mix = try engine.createAgent(rebalance, now: Fx.now)
        let snapshot = Fx.snapshot(funds.map { ($0, [Double](repeating: 100, count: 60), 100) })
        engine.runAgent(id: mix.id, snapshot: snapshot, trigger: .schedule, now: Fx.now)
        let ledger = try XCTUnwrap(engine.state.ledger(mix.ledgerID))
        func weight(_ symbol: String) -> Double { (ledger.position("us:\(symbol)")?.marketValue ?? 0) / ledger.equity * 100 }
        XCTAssertEqual(weight("VTI"), 60, accuracy: 0.5)
        XCTAssertEqual(weight("VXUS"), 20, accuracy: 0.5)
        XCTAssertEqual(weight("BND"), 20, accuracy: 0.5)
        // On target now: the next run trades nothing.
        let before = engine.state.fills.count
        var onTarget = snapshot
        for fund in funds { onTarget.quotes[fund.id] = Fx.quote(fund, last: 100, time: later) }
        let quiet = try XCTUnwrap(engine.runAgent(id: mix.id, snapshot: onTarget, trigger: .schedule, now: later))
        XCTAssertEqual(engine.state.fills.count, before)
        XCTAssertTrue(quiet.steps.contains { $0.title == "Holdings are on target" })
    }

    func testARiskManagerGuardsAManualPortfolio() throws {
        var engine = Fx.engine()
        let ledger = try portfolio(&engine)
        engine.submit(OrderRequest(ledgerID: ledger.id, instrument: Fx.aapl, side: .buy, quantity: 10), now: Fx.now)
        var guardDraft = AgentDraft(name: "Guard", mode: .paper, spec: AgentTemplates.riskManager(), budget: 10_000, maxPositionPct: 100)
        guardDraft.attachToLedgerID = ledger.id
        let agent = try engine.createAgent(guardDraft, now: Fx.now)
        XCTAssertEqual(agent.ledgerID, ledger.id)
        XCTAssertEqual(engine.state.ledgers.count, 1)                  // it got no portfolio of its own

        // The next day's bar closes 12% under the cost: the 8% stop sells.
        let tomorrow = Fx.now.addingTimeInterval(86_400)
        let closes = [Double](repeating: 100, count: 40) + [88]
        var snapshot = MarketSnapshot()
        snapshot.series[Fx.aapl.id] = Fx.series(Fx.aapl, closes: closes, days: Fx.usTradingDays(count: closes.count, before: tomorrow))
        snapshot.quotes[Fx.aapl.id] = Fx.quote(Fx.aapl, last: 88, time: tomorrow)
        engine.runAgent(id: agent.id, snapshot: snapshot, trigger: .schedule, now: tomorrow)
        XCTAssertEqual(engine.state.signals.last?.exitReason, .stopLoss)
        XCTAssertTrue(try XCTUnwrap(engine.state.ledger(ledger.id)).positions.isEmpty)
        XCTAssertEqual(engine.state.fills.last?.source.agentID, agent.id)
    }
}
