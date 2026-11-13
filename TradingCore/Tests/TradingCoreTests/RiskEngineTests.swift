import XCTest
@testable import TradingCore

/// One test per rule: start from an order that passes everything, break one thing, and
/// check that exactly that rule refuses it.
final class RiskEngineTests: XCTestCase {

    struct Setup {
        var ledger = Ledger(name: "Agent book", kind: .agentPaper, startingCash: 10_000, createdAt: Fx.now.addingTimeInterval(-86_400))
        var agent: TradingAgent? = TradingAgent(name: "Tester", mode: .paper, spec: Fx.aboveAverageSpec([Fx.aapl]),
                                                riskPolicy: .standard(budget: 10_000), budget: 10_000,
                                                createdAt: Fx.now.addingTimeInterval(-86_400))
        var policy = RiskPolicy.standard(budget: 10_000)       // $1,000 orders, 10% positions, $5,000 a day
        var account = AccountPolicy(allowFixtureData: true)
        var quote: Quote? = Fx.quote(Fx.aapl, last: 100)
        var instrument = Fx.aapl
        var marketOpen = true
        var stats: InstrumentStats? = InstrumentStats(averageDollarVolume: 500_000_000, dailyVolatilityPct: 2)
        var openOrders: [Order] = []
        var otherOpenOrders: [Order] = []
        var knownIDs: Set<String> = []
        var accountExposure: Double?
        var accountEquity: Double?
        var capabilities = PaperBroker.capabilities
        var granted: [BrokerPermission] = [.read, .trade]

        var context: RiskContext {
            RiskContext(now: Fx.now, policy: policy, accountPolicy: account, agent: agent.map(AgentRiskView.init), ledger: ledger,
                        openOrders: openOrders, otherOpenOrders: otherOpenOrders, knownClientOrderIDs: knownIDs,
                        accountExposure: accountExposure ?? (ledger.position(instrument.id)?.marketValue ?? 0),
                        accountEquity: accountEquity ?? ledger.equity, accountNotionalToday: ledger.notionalToday,
                        quote: quote, rules: PaperBroker.rules(for: instrument), capabilities: capabilities,
                        grantedPermissions: granted, marketOpen: marketOpen, stats: stats)
        }

        func intent(_ side: OrderSide = .buy, quantity: Double = 5, price: Double = 100, type: OrderType = .market,
                    tif: TimeInForce = .day, limit: Double? = nil, stop: Double? = nil, id: String = "order-1",
                    mode: ExecutionMode = .paper) -> OrderIntent {
            OrderIntent(clientOrderID: id, instrument: instrument, side: side, type: type, timeInForce: tif,
                        quantity: quantity, price: price, limitPrice: limit, stopPrice: stop, estimatedFee: 0,
                        source: agent.map { .agent($0.id) } ?? .manual, mode: mode)
        }

        mutating func hold(_ quantity: Double, at price: Double, instrument: Instrument? = nil) {
            let target = instrument ?? self.instrument
            ledger.apply(Fill(orderID: UUID(), ledgerID: ledger.id, instrument: target, side: .buy, quantity: quantity,
                              price: price, fee: 0, time: Fx.now.addingTimeInterval(-7_200), source: .manual, mode: .paper))
            ledger.notionalToday = 0
        }

        func openOrder(_ side: OrderSide, quantity: Double, agentID: UUID? = nil, instrument: Instrument? = nil) -> Order {
            Order(clientOrderID: UUID().uuidString, ledgerID: ledger.id, instrument: instrument ?? self.instrument, side: side,
                  type: .limit, quantity: quantity, limitPrice: 100, timeInForce: .gtc,
                  source: agentID.map { .agent($0) } ?? .manual, mode: .paper, status: .accepted,
                  referencePrice: 100, createdAt: Fx.now)
        }
    }

    private func evaluate(_ setup: Setup, _ intent: OrderIntent? = nil) -> RiskReport {
        RiskEngine.evaluate(intent ?? setup.intent(), context: setup.context)
    }

    private func assertOnlyFailure(_ report: RiskReport, _ id: RiskCheckID, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(report.isApproved, file: file, line: line)
        XCTAssertEqual(report.failures.map(\.id), [id], report.failures.map(\.detail).joined(separator: " | "), file: file, line: line)
    }

    func testAnOrdinaryOrderPassesEveryCheck() {
        let report = evaluate(Setup())
        XCTAssertTrue(report.isApproved, report.summary)
        XCTAssertTrue(report.warnings.isEmpty)
        XCTAssertEqual(Set(report.checks.map(\.id)), Set(RiskCheckID.allCases))       // every rule reported
    }

    func testKillSwitchStopsAgentsButNotThePerson() {
        var setup = Setup()
        setup.account.killSwitchEngaged = true
        assertOnlyFailure(evaluate(setup), .killSwitch)
        setup.agent = nil
        let manual = evaluate(setup)
        XCTAssertTrue(manual.isApproved)
        XCTAssertEqual(manual.status(.killSwitch), .warning)
    }

    func testOnlyOrderPlacingModesMayOrder() {
        var setup = Setup()
        setup.agent?.mode = .signals
        assertOnlyFailure(evaluate(setup), .authorization)
        setup.agent?.mode = .researchOnly
        assertOnlyFailure(evaluate(setup), .authorization)
        setup.agent?.mode = .autonomousLive                    // a live agent can't slip a paper order through
        assertOnlyFailure(evaluate(setup), .authorization)
    }

    func testLiveOrdersAreRefusedWhileLiveTradingIsOff() {
        var setup = Setup()
        setup.agent = nil
        XCTAssertEqual(evaluate(setup, setup.intent(mode: .live)).status(.authorization), .failed)
        setup.ledger.mode = .live
        XCTAssertEqual(evaluate(setup, setup.intent(mode: .live)).status(.authorization), .failed)   // flag still off
    }

    func testAPausedAgentCannotOrder() {
        var setup = Setup()
        setup.agent?.status = .paused
        assertOnlyFailure(evaluate(setup), .agentStatus)
    }

    func testReadOnlyConnectionsCanNeverTrade() {
        var setup = Setup()
        setup.granted = [.read]
        assertOnlyFailure(evaluate(setup), .brokerPermission)
        XCTAssertTrue(evaluate(setup).check(.brokerPermission)!.detail.contains("read-only"))

        setup = Setup()
        setup.capabilities = LiveVenues.snapTrade
        assertOnlyFailure(evaluate(setup), .brokerPermission)

        setup = Setup()
        setup.capabilities.orderTypes = [.market]
        assertOnlyFailure(evaluate(setup, setup.intent(type: .limit, limit: 100)), .brokerPermission)
    }

    func testAgentsStayInsideTheirApprovedAssets() {
        var setup = Setup()
        setup.instrument = Fx.msft
        setup.quote = Fx.quote(Fx.msft, last: 100)
        assertOnlyFailure(evaluate(setup), .universe)
    }

    func testARiskManagerAgentMayOnlySell() {
        var setup = Setup()
        setup.agent = TradingAgent(name: "Guard", mode: .paper, spec: AgentTemplates.riskManager(),
                                   riskPolicy: .standard(budget: 10_000), budget: 10_000, createdAt: Fx.now)
        assertOnlyFailure(evaluate(setup), .universe)
        setup.hold(5, at: 100)
        XCTAssertTrue(evaluate(setup, setup.intent(.sell)).isApproved)
    }

    func testCurrencyMustMatchThePortfolio() {
        var setup = Setup()
        setup.agent = nil
        setup.instrument = Fx.bhp
        setup.quote = Fx.quote(Fx.bhp, last: 45)
        setup.marketOpen = false
        let report = evaluate(setup, setup.intent(quantity: 10, price: 45))
        XCTAssertEqual(report.status(.currency), .failed)
    }

    func testOnlyRealMarketDataCanBeTradedOn() {
        var setup = Setup()
        setup.quote = nil
        XCTAssertEqual(evaluate(setup).status(.marketData), .failed)

        setup.quote = Fx.quote(Fx.aapl, last: 100, provenance: .synthetic)
        XCTAssertEqual(evaluate(setup).status(.marketData), .failed)
        XCTAssertTrue(evaluate(setup).check(.marketData)!.detail.contains("not real market data"))

        setup.quote = Fx.quote(Fx.aapl, last: 100)
        setup.account.allowFixtureData = false             // production setting: fixtures refused
        XCTAssertEqual(evaluate(setup).status(.marketData), .failed)

        setup.quote = Fx.quote(Fx.aapl, last: 100, provenance: .market("Alpaca (IEX)"))
        XCTAssertTrue(evaluate(setup).isApproved)
    }

    func testStaleQuotesAreRefusedAndDelayedFeedsGetTheirDelayAllowed() {
        var setup = Setup()
        setup.quote = Fx.quote(Fx.aapl, last: 100, time: Fx.now.addingTimeInterval(-3_600))
        assertOnlyFailure(evaluate(setup), .quoteFreshness)

        // A 20-minute-delayed feed with a 25-minute-old quote is as fresh as that feed gets.
        setup.quote = Fx.quote(Fx.aapl, last: 100, time: Fx.now.addingTimeInterval(-1_500), provenance: .fixture("delayed"))
        setup.quote?.provenance.delaySeconds = 1_200
        XCTAssertEqual(evaluate(setup).status(.quoteFreshness), .passed)

        setup.quote = Fx.quote(Fx.aapl, last: 100, time: Fx.now.addingTimeInterval(600))
        XCTAssertEqual(evaluate(setup).status(.quoteFreshness), .failed)             // dated in the future
    }

    func testClosedMarketQueuesOrRefuses() {
        var setup = Setup()
        setup.marketOpen = false
        let queued = evaluate(setup)
        XCTAssertTrue(queued.isApproved)
        XCTAssertEqual(queued.status(.marketHours), .warning)
        XCTAssertEqual(queued.status(.quoteFreshness), .notApplicable)

        assertOnlyFailure(evaluate(setup, setup.intent(tif: .ioc)), .marketHours)
        setup.policy.allowQueueOutsideHours = false
        XCTAssertEqual(evaluate(setup).status(.marketHours), .failed)

        setup = Setup()
        setup.agent?.versions[0].spec = Fx.aboveAverageSpec([Fx.btc])
        setup.instrument = Fx.btc
        setup.quote = Fx.quote(Fx.btc, last: 60_000)
        setup.marketOpen = false                           // ignored: crypto never closes
        XCTAssertEqual(evaluate(setup, setup.intent(quantity: 0.01, price: 60_000)).status(.marketHours), .passed)
    }

    func testExchangeRulesForPrecisionMinimumsAndTicks() {
        var setup = Setup()
        setup.agent?.versions[0].spec = Fx.aboveAverageSpec([Fx.btc])
        setup.instrument = Fx.btc
        setup.quote = Fx.quote(Fx.btc, last: 60_000)
        assertOnlyFailure(evaluate(setup, setup.intent(quantity: 0.012_345_678_9, price: 60_000)), .exchangeRules)   // 10 decimals
        XCTAssertTrue(evaluate(setup, setup.intent(quantity: 0.012_345_67, price: 60_000)).isApproved)
        assertOnlyFailure(evaluate(setup, setup.intent(quantity: 0.000_000_01, price: 60_000)), .exchangeRules)      // worth $0.0006

        setup = Setup()
        assertOnlyFailure(evaluate(setup, setup.intent(type: .limit, limit: 100.005)), .exchangeRules)               // off the cent tick
        assertOnlyFailure(evaluate(setup, setup.intent(type: .limit)), .exchangeRules)                               // no limit price
        assertOnlyFailure(evaluate(setup, setup.intent(type: .stop)), .exchangeRules)
        assertOnlyFailure(evaluate(setup, setup.intent(quantity: 0)), .exchangeRules)

        var asx = Setup()
        asx.agent = nil
        asx.ledger = Ledger(name: "AUD", kind: .manualPaper, currency: "AUD", startingCash: 10_000, createdAt: Fx.now)
        asx.instrument = Fx.bhp
        asx.quote = Fx.quote(Fx.bhp, last: 45)
        assertOnlyFailure(evaluate(asx, asx.intent(quantity: 1.5, price: 45)), .exchangeRules)                       // ASX: whole shares
        XCTAssertTrue(evaluate(asx, asx.intent(quantity: 2, price: 45)).isApproved)
    }

    func testOrderSizeLimit() {
        var setup = Setup()
        setup.policy.maxPositionPct = 50                       // so only the order-size rule is in play
        assertOnlyFailure(evaluate(setup, setup.intent(quantity: 10.5)), .orderValue)       // $1,050 against a $1,000 limit
        XCTAssertEqual(evaluate(setup, setup.intent(quantity: 10)).status(.orderValue), .passed)
    }

    func testBuyingPowerCountsCashAlreadyCommitted() {
        var setup = Setup()
        setup.ledger = Ledger(name: "Small", kind: .agentPaper, startingCash: 300, createdAt: Fx.now)
        setup.policy.maxPositionPct = 100
        setup.account.maxSymbolExposurePct = 100
        XCTAssertEqual(evaluate(setup).status(.buyingPower), .failed)                        // needs $500, has $300

        setup = Setup()
        setup.ledger = Ledger(name: "Committed", kind: .agentPaper, startingCash: 1_000, createdAt: Fx.now)
        setup.policy.maxPositionPct = 100
        setup.account.maxSymbolExposurePct = 100
        XCTAssertEqual(evaluate(setup).status(.buyingPower), .passed)
        setup.openOrders = [setup.openOrder(.buy, quantity: 6, instrument: Fx.msft)]        // $600 already promised
        XCTAssertEqual(evaluate(setup).status(.buyingPower), .failed)
    }

    func testFeesCountTowardsBuyingPower() {
        var setup = Setup()
        setup.ledger = Ledger(name: "Exact", kind: .agentPaper, startingCash: 500, createdAt: Fx.now)
        setup.policy.maxPositionPct = 100
        setup.account.maxSymbolExposurePct = 100
        var intent = setup.intent()
        XCTAssertEqual(evaluate(setup, intent).status(.buyingPower), .passed)
        intent.estimatedFee = 1.25
        XCTAssertEqual(evaluate(setup, intent).status(.buyingPower), .failed)
    }

    func testShortSellingIsImpossible() {
        var setup = Setup()
        let none = evaluate(setup, setup.intent(.sell))
        assertOnlyFailure(none, .holdings)
        XCTAssertTrue(none.check(.holdings)!.detail.contains("Short selling is not allowed"))

        setup.hold(3, at: 100)
        assertOnlyFailure(evaluate(setup, setup.intent(.sell, quantity: 5)), .holdings)
        XCTAssertTrue(evaluate(setup, setup.intent(.sell, quantity: 3)).isApproved)

        // Units already promised to another sell order can't be sold twice.
        setup.openOrders = [setup.openOrder(.sell, quantity: 2)]
        assertOnlyFailure(evaluate(setup, setup.intent(.sell, quantity: 3)), .holdings)
    }

    func testPositionLimit() {
        var setup = Setup()
        setup.hold(8, at: 100)                                // $800 held; +$500 would be 13% of $10,000
        assertOnlyFailure(evaluate(setup), .positionLimit)
        XCTAssertEqual(evaluate(setup, setup.intent(quantity: 2)).status(.positionLimit), .passed)
    }

    func testConcentrationAcrossEveryPortfolio() {
        var setup = Setup()
        setup.accountExposure = 3_400                         // other agents already hold $3,400 of AAPL
        setup.accountEquity = 10_000
        assertOnlyFailure(evaluate(setup), .concentration)    // 39% against a 35% limit
        setup.agent = nil                                     // a person is warned, not stopped
        XCTAssertEqual(evaluate(setup).status(.concentration), .warning)
    }

    func testOpenPositionLimitOnlyCountsNewPositions() {
        var setup = Setup()
        setup.policy.maxOpenPositions = 1
        setup.hold(1, at: 50, instrument: Fx.msft)
        assertOnlyFailure(evaluate(setup), .openPositions)
        setup.hold(1, at: 100)                                // adding to AAPL isn't a new position
        XCTAssertEqual(evaluate(setup).status(.openPositions), .notApplicable)
    }

    func testDailyTradingLimit() {
        var setup = Setup()
        setup.ledger.notionalToday = 4_800
        assertOnlyFailure(evaluate(setup), .dailyNotional)    // $5,300 against $5,000

        setup = Setup()
        setup.account.maxTotalDailyNotional = 400             // across all portfolios
        assertOnlyFailure(evaluate(setup), .dailyNotional)
    }

    func testDailyLossAndDrawdownStopNewBuysButNeverExits() {
        var setup = Setup()
        setup.hold(5, at: 100)
        setup.ledger.realizedToday = -400                     // 4% of the day's $10,000 start
        assertOnlyFailure(evaluate(setup, setup.intent(quantity: 1)), .dailyLoss)

        var drawdown = Setup()
        drawdown.hold(5, at: 100)
        drawdown.ledger.peakEquity = 12_000                   // 16.7% below peak
        assertOnlyFailure(evaluate(drawdown, drawdown.intent(quantity: 1)), .drawdown)

        // Getting out is always allowed, however bad the day.
        setup.ledger.peakEquity = 20_000
        setup.ledger.notionalToday = 1_000_000
        let exit = evaluate(setup, setup.intent(.sell, quantity: 5))
        XCTAssertTrue(exit.isApproved, exit.summary)
    }

    func testSpreadLiquidityAndVolatility() {
        var setup = Setup()
        setup.quote = Fx.quote(Fx.aapl, last: 100, spreadBps: 80)
        assertOnlyFailure(evaluate(setup), .spread)
        setup.hold(5, at: 100)
        XCTAssertEqual(evaluate(setup, setup.intent(.sell)).status(.spread), .warning)      // an exit is warned, not blocked

        setup = Setup()
        setup.quote = Fx.quote(Fx.aapl, last: 100, spreadBps: nil)
        XCTAssertEqual(evaluate(setup).status(.spread), .warning)                            // can't be measured

        setup = Setup()
        setup.stats = InstrumentStats(averageDollarVolume: 100_000, dailyVolatilityPct: 2)
        assertOnlyFailure(evaluate(setup), .liquidity)
        setup.stats = InstrumentStats(averageDollarVolume: 500_000_000, dailyVolatilityPct: 12)
        assertOnlyFailure(evaluate(setup), .volatility)

        // With no history an agent may not buy; a person is warned.
        setup.stats = nil
        XCTAssertEqual(Set(evaluate(setup).failures.map(\.id)), [.liquidity, .volatility])
        setup.agent = nil
        XCTAssertTrue(evaluate(setup).isApproved)
        XCTAssertEqual(evaluate(setup).status(.liquidity), .warning)
    }

    func testDuplicateAndConflictingOrders() {
        var setup = Setup()
        setup.knownIDs = ["order-1"]
        assertOnlyFailure(evaluate(setup), .duplicate)                                       // same idempotency key

        setup = Setup()
        setup.openOrders = [setup.openOrder(.buy, quantity: 1, agentID: setup.agent?.id)]
        assertOnlyFailure(evaluate(setup, setup.intent(quantity: 1)), .duplicate)            // already working the same order

        setup = Setup()
        var opposing = setup.openOrder(.sell, quantity: 1, agentID: UUID())
        opposing.ledgerID = UUID()
        setup.otherOpenOrders = [opposing]
        let conflict = evaluate(setup)
        assertOnlyFailure(conflict, .duplicate)
        XCTAssertTrue(conflict.check(.duplicate)!.detail.contains("can't trade against each other"))
    }

    func testCooldownAfterAFill() {
        var setup = Setup()
        setup.ledger.lastFillAt[Fx.aapl.id] = Fx.now.addingTimeInterval(-60)
        assertOnlyFailure(evaluate(setup), .cooldown)
        setup.ledger.lastFillAt[Fx.aapl.id] = Fx.now.addingTimeInterval(-400)
        XCTAssertEqual(evaluate(setup).status(.cooldown), .passed)
    }

    func testAPersonIsNotBoundByAnAgentsSizingLimits() {
        var setup = Setup()
        setup.agent = nil
        setup.policy = TradingEngine.manualPolicy(equity: 10_000)
        let report = evaluate(setup, setup.intent(quantity: 60))        // $6,000: far over any agent limit
        XCTAssertTrue(report.isApproved, report.summary)
        XCTAssertEqual(report.status(.orderValue), .notApplicable)
        XCTAssertEqual(report.status(.positionLimit), .notApplicable)
        // The hard rules still hold.
        assertOnlyFailure(evaluate(setup, setup.intent(quantity: 150)), .buyingPower)
        assertOnlyFailure(evaluate(setup, setup.intent(.sell, quantity: 1)), .holdings)
    }

    func testStandardPolicyScalesWithTheBudget() {
        let policy = RiskPolicy.standard(budget: 5_000, maxPositionPct: 10)
        XCTAssertEqual(policy.maxOrderNotional, 500)
        XCTAssertEqual(policy.maxDailyNotional, 2_500)
        XCTAssertTrue(policy.issues.isEmpty)
        XCTAssertGreaterThan(RiskPolicy.standard(budget: 5_000, crypto: true).maxDailyVolatilityPct, policy.maxDailyVolatilityPct)
        var bad = policy
        bad.maxPositionPct = 0
        bad.maxDrawdownPct = 150
        XCTAssertEqual(bad.issues.count, 2)
    }
}
