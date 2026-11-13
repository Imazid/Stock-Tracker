//
//  TradingStore.swift
//  Stock Tracker
//
//  The app's one door to the trading engine. Screens read `state` and call the
//  methods here; nothing else changes trading state.
//
//  What this file adds on top of TradingCore: saving and loading, fetching real
//  market data before the engine decides anything, running agents that are due
//  while the app is open (and when iOS grants background time), and turning the
//  engine's notices into banners and notifications.
//
//  Everything here is paper trading. The engine refuses live orders, and there
//  is no code in the app that can send an order to a broker.
//

import Foundation
import Combine
import OSLog
import UIKit
import UserNotifications
import TradingCore

/// A market-data source that can also quote several instruments in one go.
nonisolated protocol TradingDataSource: MarketDataProviding {
    func quotes(for instruments: [Instrument]) async throws -> [String: Quote]
}

extension LiveMarketData: TradingDataSource {}
#if DEBUG
extension FixtureMarketData: TradingDataSource {}
#endif

@MainActor
final class TradingStore: ObservableObject {
    static let shared = TradingStore()

    /// Everything the trading screens show. Replaced whole after each change.
    @Published private(set) var state: TradingState
    @Published private(set) var runningAgentIDs: Set<UUID> = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshAt: Date?
    /// Set when the last price refresh failed; cleared by the next one that works.
    @Published private(set) var dataProblem: String?
    /// The most recent thing worth a banner inside the app.
    @Published var toast: EngineNotice?

    private var engine: TradingEngine
    private let data: any TradingDataSource
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?
    private var loop: Task<Void, Never>?
    private var isTicking = false

    /// True while UI tests drive the app with fixture prices.
    let usesFixtureData: Bool

    // MARK: - Setup

    private init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Trading", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("state.json")

        var fixture = false
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-UITestFreshInstall") { try? FileManager.default.removeItem(at: fileURL) }
        fixture = arguments.contains("-UITestTradingFixture")
        #endif
        usesFixtureData = fixture

        var loaded = TradingState()
        if let bytes = try? Data(contentsOf: fileURL) {
            do {
                loaded = try TradingCodec.decoder().decode(TradingState.self, from: bytes)
            } catch {
                // Never overwrite a file we couldn't read: set it aside and say so.
                let aside = directory.appendingPathComponent("state-unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: fileURL, to: aside)
                AppLogger.general.error("Trading state could not be read and was set aside: \(error.localizedDescription)")
            }
        }
        // Fixture prices are a test-only switch; a saved file can never turn it on.
        loaded.accountPolicy.allowFixtureData = fixture
        // Live trading flags are owned by the server. Whatever a file says, they are off here.
        loaded.accountPolicy.live = .disabled
        engine = TradingEngine(state: loaded)
        state = loaded

        #if DEBUG
        if fixture {
            data = FixtureMarketData()
        } else {
            data = LiveMarketData(alpacaKey: SecretsConfig.alpacaAPIKey, alpacaSecret: SecretsConfig.alpacaSecretKey)
        }
        #else
        data = LiveMarketData(alpacaKey: SecretsConfig.alpacaAPIKey, alpacaSecret: SecretsConfig.alpacaSecretKey)
        #endif

        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.saveNow() }
        }
    }

    // MARK: - Reading

    var agents: [TradingAgent] { state.agents }
    var practicePortfolios: [Ledger] { state.manualLedgers }
    var pendingProposals: [TradeProposal] { state.pendingProposals.sorted { $0.createdAt > $1.createdAt } }
    var openOrders: [Order] { state.openOrders.sorted { $0.createdAt > $1.createdAt } }
    var orders: [Order] { state.orders.sorted { $0.createdAt > $1.createdAt } }
    var isKillSwitchOn: Bool { state.accountPolicy.killSwitchEngaged }
    var activeAgentCount: Int { state.agents.filter { $0.status == .active }.count }
    var hasAnything: Bool { !state.agents.isEmpty || !state.ledgers.isEmpty }

    func agent(_ id: UUID?) -> TradingAgent? { state.agent(id) }
    func ledger(_ id: UUID?) -> Ledger? { state.ledger(id) }
    func order(_ id: UUID?) -> Order? { id.flatMap { id in state.orders.first { $0.id == id } } }
    func proposal(_ id: UUID?) -> TradeProposal? { id.flatMap { id in state.proposals.first { $0.id == id } } }
    func signal(_ id: UUID?) -> TradingSignal? { id.flatMap { id in state.signals.first { $0.id == id } } }
    func quote(_ instrument: Instrument) -> Quote? { state.quotes[instrument.id] }

    func runs(for agentID: UUID) -> [AgentRun] {
        state.runs.filter { $0.agentID == agentID }.sorted { $0.startedAt > $1.startedAt }
    }

    func proposals(for agentID: UUID) -> [TradeProposal] {
        state.proposals.filter { $0.agentID == agentID }.sorted { $0.createdAt > $1.createdAt }
    }

    func orders(for agentID: UUID) -> [Order] {
        state.orders.filter { $0.source.agentID == agentID }.sorted { $0.createdAt > $1.createdAt }
    }

    func orders(in ledgerID: UUID) -> [Order] {
        state.orders.filter { $0.ledgerID == ledgerID }.sorted { $0.createdAt > $1.createdAt }
    }

    func fills(for orderID: UUID) -> [Fill] {
        state.fills.filter { $0.orderID == orderID }.sorted { $0.time < $1.time }
    }

    func fills(in ledgerID: UUID) -> [Fill] {
        state.fills.filter { $0.ledgerID == ledgerID }.sorted { $0.time > $1.time }
    }

    func signals(for agentID: UUID) -> [TradingSignal] {
        state.signals.filter { $0.agentID == agentID }.sorted { $0.createdAt > $1.createdAt }
    }

    func audit(for agentID: UUID) -> [AuditEvent] {
        state.audit.events.filter { $0.agentID == agentID }.reversed()
    }

    var auditNewestFirst: [AuditEvent] { state.audit.events.reversed() }

    /// Whether the saved audit trail is complete and unaltered.
    func verifyAudit() -> AuditVerification { state.audit.verify() }

    /// Total value of all practice money in one currency (agents' portfolios included).
    func practiceEquity(currency: String = "USD") -> Double { state.paperEquity(currency: currency) }

    /// The agent, if any, that manages a portfolio it doesn't own (a risk manager).
    func guardian(of ledgerID: UUID) -> TradingAgent? {
        state.agents.first { $0.ledgerID == ledgerID && $0.spec.followsLedgerPositions }
    }

    /// Why real-money trading can't be used. Never empty in this version.
    func liveBlockers(for mode: AgentMode? = nil) -> [String] {
        let reasons = engine.liveBlockers(for: mode)
        return reasons.isEmpty ? ["Live trading isn't available in this version."] : reasons
    }

    // MARK: - Changing things

    /// Applies a change to the engine, then publishes, saves and delivers any notices.
    @discardableResult
    private func mutate<T>(_ body: (inout TradingEngine) throws -> T) rethrows -> T {
        let result = try body(&engine)
        commit()
        return result
    }

    private func commit() {
        state = engine.state
        deliver(engine.drainNotices())
        scheduleSave()
    }

    @discardableResult
    func createPortfolio(name: String, startingCash: Double, currency: String = "USD") throws -> Ledger {
        try mutate { try $0.createPaperPortfolio(name: name, startingCash: startingCash, currency: currency, now: Date()) }
    }

    func resetPortfolio(_ id: UUID) throws { try mutate { try $0.resetPaperPortfolio(id: id, now: Date()) } }
    func deletePortfolio(_ id: UUID) throws { try mutate { try $0.deletePaperPortfolio(id: id, now: Date()) } }

    /// Creates an agent and gives it its first look at the market straight away.
    @discardableResult
    func createAgent(_ draft: AgentDraft) throws -> TradingAgent {
        let agent = try mutate { try $0.createAgent(draft, now: Date()) }
        requestNotificationPermissionIfNeeded()
        Task { await run(agentID: agent.id, trigger: .manual) }
        return agent
    }

    func updateStrategy(agentID: UUID, spec: StrategySpec, note: String, author: ChangeAuthor = .user) throws {
        try mutate { try $0.updateStrategy(agentID: agentID, spec: spec, note: note, author: author, now: Date()) }
    }

    func updateRiskPolicy(agentID: UUID, policy: RiskPolicy, actor: AuditActor = .user) throws {
        try mutate { try $0.updateRiskPolicy(agentID: agentID, policy: policy, actor: actor, now: Date()) }
    }

    func setMode(agentID: UUID, mode: AgentMode) throws { try mutate { try $0.setMode(agentID: agentID, mode: mode, now: Date()) } }
    func setReviewEachTrade(agentID: UUID, _ review: Bool) throws { try mutate { try $0.setReviewEachPaperTrade(agentID: agentID, review, now: Date()) } }
    func setSchedule(agentID: UUID, _ schedule: AgentSchedule) throws { try mutate { try $0.setSchedule(agentID: agentID, schedule, now: Date()) } }
    func renameAgent(_ id: UUID, to name: String) throws { try mutate { try $0.renameAgent(id: id, name: name, now: Date()) } }
    func pauseAgent(_ id: UUID) throws { try mutate { try $0.pauseAgent(id: id, reason: .user, now: Date()) } }
    func resumeAgent(_ id: UUID) throws { try mutate { try $0.resumeAgent(id: id, now: Date()) } }
    func deleteAgent(_ id: UUID) throws { try mutate { try $0.deleteAgent(id: id, now: Date()) } }

    /// Stops every agent now. Returns how many open orders were cancelled.
    @discardableResult
    func engageKillSwitch() -> Int { mutate { $0.engageKillSwitch(now: Date()) } }

    /// Turns the kill switch off. Agents stay paused until each is resumed.
    func releaseKillSwitch() { mutate { $0.releaseKillSwitch(now: Date()) } }

    func rejectProposal(_ id: UUID) throws { try mutate { try $0.rejectProposal(id: id, now: Date()) } }

    @discardableResult
    func cancelOrder(_ id: UUID) -> Bool { mutate { $0.cancelOrder(id: id, now: Date()) } }

    // MARK: - Orders

    /// Loads a fresh quote and recent history for an instrument so an order can be previewed
    /// and checked. Returns a message when prices couldn't be loaded.
    @discardableResult
    func prepare(_ instrument: Instrument) async -> String? {
        let snapshot = await data.snapshot(for: [instrument], timeframe: .day, barCount: 60)
        let now = Date()
        mutate { $0.ingest(quotes: Array(snapshot.quotes.values), stats: snapshot.stats(now: now), now: now) }
        if snapshot.quotes[instrument.id] == nil {
            return snapshot.failures[instrument.id] ?? "A live price for \(instrument.symbol) isn't available right now."
        }
        return nil
    }

    /// What would happen if this order were placed now. Changes nothing.
    func preview(_ request: OrderRequest) -> OrderPreview? { engine.preview(request, now: Date()) }

    /// Places a paper order. The result says plainly whether it was accepted or refused.
    @discardableResult
    func submit(_ request: OrderRequest) -> OrderResult { mutate { $0.submit(request, now: Date()) } }

    /// Approves a waiting proposal. Prices are refreshed first so the risk checks judge the
    /// order against the market as it is now, not as it was when the agent proposed it.
    @discardableResult
    func approveProposal(_ id: UUID) async throws -> OrderResult {
        guard let proposal = proposal(id) else { throw TradingError.notFound("That proposal") }
        await prepare(proposal.instrument)
        return try mutate { try $0.approveProposal(id: id, now: Date()) }
    }

    // MARK: - Running agents

    /// Runs one agent now against freshly fetched market data.
    @discardableResult
    func run(agentID: UUID, trigger: RunTrigger) async -> AgentRun? {
        guard let agent = agent(agentID), !runningAgentIDs.contains(agentID) else { return nil }
        runningAgentIDs.insert(agentID)
        defer { runningAgentIDs.remove(agentID) }
        var instruments = agent.spec.universe
        if agent.spec.followsLedgerPositions { instruments = ledger(agent.ledgerID)?.positions.map(\.instrument) ?? [] }
        let snapshot = instruments.isEmpty ? MarketSnapshot()
            : await data.snapshot(for: instruments, timeframe: agent.spec.timeframe, barCount: agent.spec.barsToFetch)
        return mutate { $0.runAgent(id: agentID, snapshot: snapshot, trigger: trigger, now: Date()) }
    }

    /// One round of housekeeping: fresh prices for anything open or held, then every agent
    /// whose time has come.
    func tick() async {
        guard !isTicking else { return }
        isTicking = true
        defer { isTicking = false }
        await refreshPrices()
        for agent in engine.dueAgents(at: Date()) {
            await run(agentID: agent.id, trigger: .schedule)
        }
    }

    /// Fetches quotes for open orders, positions and waiting proposals, lets waiting orders
    /// trade and reprices every practice portfolio.
    func refreshPrices() async {
        let needed = engine.instrumentsNeedingQuotes()
        guard !needed.isEmpty else {
            mutate { $0.ingest(quotes: [], now: Date()) }
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let quotes = try await data.quotes(for: needed)
            mutate { $0.ingest(quotes: Array(quotes.values), now: Date()) }
            lastRefreshAt = Date()
            dataProblem = nil
        } catch {
            dataProblem = "Prices couldn't be refreshed. Open orders are waiting and nothing was traded."
            AppLogger.api.error("Trading price refresh failed: \(error.localizedDescription)")
        }
    }

    /// Keeps agents and open orders moving while the app is on screen.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                if UIApplication.shared.applicationState == .active, self?.hasAnything == true {
                    await self?.tick()
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Called from background refresh, when iOS allows it. The server-side scheduler is
    /// what keeps agents running when the app is closed; this is a best-effort extra.
    func backgroundTick() async {
        guard hasAnything else { return }
        await tick()
        saveNow()
    }

    // MARK: - Backtests

    /// Replays a strategy over real history. Throws when prices can't be loaded or aren't real.
    func backtest(_ draft: AgentDraft, years: Int, agentID: UUID? = nil) async throws -> BacktestResult {
        let spec = draft.spec
        let allCrypto = !spec.universe.isEmpty && spec.universe.allSatisfy { $0.assetClass == .crypto }
        let count = years * (allCrypto ? 365 : 252) + spec.warmupBars + 10
        let snapshot = await data.snapshot(for: spec.universe, timeframe: spec.timeframe, barCount: count)
        guard !snapshot.series.isEmpty else {
            throw TradingDataError.empty(snapshot.failures.values.first ?? spec.universe.map(\.symbol).joined(separator: ", "))
        }
        let benchmarkInstrument: Instrument = allCrypto ? .crypto("BTC", name: "Bitcoin")
            : (spec.universe.first?.venue == .asx ? .asxStock("STW", name: "ASX 200 ETF") : .usETF("SPY", name: "S&P 500 ETF"))
        let benchmark = try? await data.bars(for: benchmarkInstrument, timeframe: spec.timeframe, count: count)
        var config = BacktestConfig(agent: draft, paper: state.paperConfig)
        config.allowFixtureData = usesFixtureData
        let series = snapshot.series
        let now = Date()
        let result = try await Task.detached(priority: .userInitiated) {
            try Backtester.run(spec: spec, series: series, benchmark: benchmark, config: config, asOf: now)
        }.value
        mutate {
            $0.noteBacktest(title: spec.title,
                            summary: String(format: "%+.1f%% over %d bars, %d trades, max drawdown %.1f%%.",
                                            result.overall.totalReturnPct, result.overall.bars,
                                            result.overall.closedTrades, result.overall.maxDrawdownPct),
                            agentID: agentID,
                            details: ["dataSources": result.dataSources.joined(separator: ", "),
                                      "realMarketData": String(result.usedRealMarketData)],
                            now: Date())
        }
        return result
    }

    // MARK: - Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        saveTask?.cancel()
        let snapshot = engine.state
        let url = fileURL
        Task.detached(priority: .utility) {
            do {
                let bytes = try TradingCodec.encoder().encode(snapshot)
                try bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                AppLogger.general.error("Trading state could not be saved: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Notices

    private func deliver(_ notices: [EngineNotice]) {
        guard let latest = notices.last else { return }
        toast = latest
        // Things an agent did while you weren't looking go to Notification Centre too.
        // Orders you just placed by hand don't: you were there.
        guard UIApplication.shared.applicationState != .active else { return }
        for notice in notices where notice.agentID != nil {
            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.body = notice.body
            content.sound = notice.kind == .approvalNeeded || notice.kind == .agentPaused ? .default : nil
            content.threadIdentifier = "trading"
            var info: [String: String] = ["tradingRoute": notice.kind == .approvalNeeded ? "approvals" : "activity"]
            if let id = notice.agentID { info["agentID"] = id.uuidString }
            if let id = notice.proposalID { info["proposalID"] = id.uuidString }
            if let id = notice.orderID { info["orderID"] = id.uuidString }
            content.userInfo = info
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notice.id.uuidString, content: content, trigger: nil))
        }
    }

    /// Asked the first time an agent is created — the moment a notification becomes useful.
    private func requestNotificationPermissionIfNeeded() {
        #if DEBUG
        // UI tests must not leave a system alert pinned over the app.
        if ProcessInfo.processInfo.arguments.contains("-UITestFreshInstall") { return }
        #endif
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            guard settings.authorizationStatus == .notDetermined else { return }
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        }
    }
}
