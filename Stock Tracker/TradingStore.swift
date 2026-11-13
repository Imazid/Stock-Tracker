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
    /// Where practice money and agents live right now.
    @Published private(set) var home: Home = .device
    @Published private(set) var isSwitching = false
    @Published private(set) var lastSyncAt: Date?
    /// Set when the account's trading server couldn't be reached or refused a refresh.
    @Published private(set) var syncProblem: String?

    private var engine: TradingEngine
    private let data: any TradingDataSource
    private let server: TradingServerClient?
    /// The phone's own practice data, kept aside while an account is in use.
    private var deviceState: TradingState?
    /// Signed in, so the account should be used once its server answers.
    private var wantsAccount = false
    private var lastAccountAttempt: Date?
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

        server = TradingServerClient(supabaseURL: SecretsConfig.supabaseURL, anonKey: SecretsConfig.supabaseAnonKey,
                                     fixture: fixture ? "ui-test" : nil)

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

    // MARK: - Where the data lives

    /// Practice money and agents live either on this phone (signed out) or in the person's
    /// account on the trading server (signed in), where agents keep running while the app
    /// is closed. The screens read `state` the same way in both.
    enum Home: Equatable {
        case device
        case account
    }

    var isAccount: Bool { home == .account }

    /// One line for the screens: where this lives and when agents run.
    var homeDescription: String {
        switch home {
        case .device: return "On this phone · agents run while the app is open"
        case .account: return "In your account · agents keep running when the app is closed"
        }
    }

    /// Moves to the signed-in person's account, if their trading server answers. If it
    /// doesn't, the phone's own practice data stays in use and the reason is shown.
    func useAccount() async {
        wantsAccount = true
        guard home == .device, !isSwitching else { return }
        guard let server else {
            syncProblem = TradingServerError.notConfigured.errorDescription
            return
        }
        isSwitching = true
        defer { isSwitching = false }
        lastAccountAttempt = Date()
        do {
            let remote = try await server.state()
            guard wantsAccount else { return }    // signed out while this was loading
            saveNow()                             // the phone's own data, kept for when they sign out
            deviceState = engine.state
            home = .account
            adopt(remote, announce: false)
            syncProblem = nil
            AppLogger.sync.info("Trading now uses the account")
        } catch {
            syncProblem = "Your account's trading server couldn't be reached, so practice stays on this phone for now. \(error.localizedDescription)"
            AppLogger.sync.error("Trading account unavailable: \(error.localizedDescription)")
        }
    }

    /// Back to the phone's own practice data (on sign-out).
    func useDevice() {
        wantsAccount = false
        syncProblem = nil
        guard home == .account else { return }
        home = .device
        let restored = deviceState ?? loadDeviceState()
        deviceState = nil
        engine = TradingEngine(state: restored)
        state = restored
    }

    /// Takes the server's state as the truth, keeping only newer quotes this phone fetched
    /// (they feed order previews; the server checks every order again when it is placed).
    ///
    /// Replies can arrive out of order (a refresh that started before an order was placed can
    /// land after it). Every change appends to the audit trail, so a reply whose trail is
    /// shorter than what is shown is older and is ignored.
    private func adopt(_ remote: TradingState, announce: Bool = true) {
        let shownHead = engine.state.audit.nextSequence
        if home == .account, announce, remote.audit.nextSequence < shownHead { return }
        if announce { deliver(Self.notices(from: engine.state, to: remote)) }
        var next = remote
        for (id, quote) in engine.state.quotes where (next.quotes[id]?.time ?? .distantPast) < quote.time {
            next.quotes[id] = quote
        }
        next.accountPolicy.allowFixtureData = usesFixtureData
        next.accountPolicy.live = .disabled
        engine = TradingEngine(state: next)
        state = next
        lastSyncAt = Date()
    }

    /// What agents did on the server since the last state shown: new proposals waiting for
    /// approval, agent trades, and agents that paused themselves. The phone's own engine makes
    /// these notices when it runs agents itself; in an account the server ran them.
    static func notices(from old: TradingState, to new: TradingState) -> [EngineNotice] {
        var out: [EngineNotice] = []
        let names = Dictionary(new.agents.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let knownProposals = Set(old.proposals.map(\.id))
        for proposal in new.proposals where proposal.status == .pending && !knownProposals.contains(proposal.id) {
            let name = names[proposal.agentID] ?? "An agent"
            out.append(EngineNotice(kind: .approvalNeeded, title: "\(name) wants to trade", body: proposal.headline,
                                    agentID: proposal.agentID, proposalID: proposal.id, instrumentID: proposal.instrument.id))
        }
        let knownFills = Set(old.fills.map(\.id))
        for fill in new.fills where !knownFills.contains(fill.id) {
            guard let agentID = fill.source.agentID else { continue }
            let name = names[agentID] ?? "An agent"
            let verb = fill.side == .buy ? "bought" : "sold"
            out.append(EngineNotice(kind: .orderFilled, title: "\(name) \(verb) \(fill.instrument.symbol)",
                                    body: "\(NumberText.number(fill.quantity)) at \(NumberText.money(fill.price, currency: fill.instrument.currency)) (practice).",
                                    agentID: agentID, orderID: fill.orderID, instrumentID: fill.instrument.id))
        }
        let wasActive = Set(old.agents.filter { $0.status == .active }.map(\.id))
        for agent in new.agents where agent.status == .paused && wasActive.contains(agent.id) && agent.pauseReason != .user {
            out.append(EngineNotice(kind: .agentPaused, title: "\(agent.name) paused",
                                    body: agent.pauseReason?.explanation ?? "Paused.", agentID: agent.id))
        }
        return out
    }

    /// Fetches the account's state again (agents may have run on the server meanwhile).
    func syncFromAccount() async {
        guard home == .account, let server else { return }
        do {
            adopt(try await server.state())
            syncProblem = nil
        } catch {
            syncProblem = "Couldn't refresh from your account. Showing what was last loaded. \(error.localizedDescription)"
        }
    }

    /// Runs one server action and adopts the state it returns.
    @discardableResult
    private func remote(_ action: String, _ body: [String: Any] = [:], idempotencyKey: String = UUID().uuidString) async throws -> TradingServerReply {
        guard let server else { throw TradingServerError.notConfigured }
        let reply = try await server.call(action, body, includeState: true, idempotencyKey: idempotencyKey)
        if let next = reply.state { adopt(next) } else { await syncFromAccount() }
        return reply
    }

    // MARK: - Changing things

    /// Applies a change to the phone's engine, then publishes, saves and delivers any notices.
    @discardableResult
    private func mutate<T>(_ body: (inout TradingEngine) throws -> T) rethrows -> T {
        let result = try body(&engine)
        commit()
        return result
    }

    private func commit() {
        state = engine.state
        deliver(engine.drainNotices())
        if home == .device { scheduleSave() }
    }

    @discardableResult
    func createPortfolio(name: String, startingCash: Double, currency: String = "USD") async throws -> Ledger {
        if isAccount {
            let reply = try await remote("createPortfolio", ["name": name, "startingCash": startingCash, "currency": currency])
            return try reply.decode(Ledger.self, at: "ledger")
        }
        return try mutate { try $0.createPaperPortfolio(name: name, startingCash: startingCash, currency: currency, now: Date()) }
    }

    func resetPortfolio(_ id: UUID) async throws {
        if isAccount { try await remote("resetPortfolio", ["ledgerID": id.uuidString]); return }
        try mutate { try $0.resetPaperPortfolio(id: id, now: Date()) }
    }

    func deletePortfolio(_ id: UUID) async throws {
        if isAccount { try await remote("deletePortfolio", ["ledgerID": id.uuidString]); return }
        try mutate { try $0.deletePaperPortfolio(id: id, now: Date()) }
    }

    /// Creates an agent and gives it its first look at the market straight away.
    @discardableResult
    func createAgent(_ draft: AgentDraft) async throws -> TradingAgent {
        requestNotificationPermissionIfNeeded()
        if isAccount {
            let reply = try await remote("createAgent", ["draft": try TradingServerClient.json(draft)])
            let agent = try reply.decode(TradingAgent.self, at: "agent")
            Task { await run(agentID: agent.id, trigger: .manual) }
            return agent
        }
        let agent = try mutate { try $0.createAgent(draft, now: Date()) }
        Task { await run(agentID: agent.id, trigger: .manual) }
        return agent
    }

    func updateStrategy(agentID: UUID, spec: StrategySpec, note: String, author: ChangeAuthor = .user) async throws {
        if isAccount {
            try await remote("updateStrategy", ["agentID": agentID.uuidString, "spec": try TradingServerClient.json(spec),
                                                "note": note, "author": author.rawValue])
            return
        }
        try mutate { try $0.updateStrategy(agentID: agentID, spec: spec, note: note, author: author, now: Date()) }
    }

    func updateRiskPolicy(agentID: UUID, policy: RiskPolicy, actor: AuditActor = .user) async throws {
        if isAccount {
            try await remote("updateRiskPolicy", ["agentID": agentID.uuidString, "policy": try TradingServerClient.json(policy)])
            return
        }
        try mutate { try $0.updateRiskPolicy(agentID: agentID, policy: policy, actor: actor, now: Date()) }
    }

    func setMode(agentID: UUID, mode: AgentMode) async throws {
        if isAccount { try await remote("setMode", ["agentID": agentID.uuidString, "mode": mode.rawValue]); return }
        try mutate { try $0.setMode(agentID: agentID, mode: mode, now: Date()) }
    }

    func setReviewEachTrade(agentID: UUID, _ review: Bool) async throws {
        if isAccount { try await remote("setReviewEachPaperTrade", ["agentID": agentID.uuidString, "review": review]); return }
        try mutate { try $0.setReviewEachPaperTrade(agentID: agentID, review, now: Date()) }
    }

    func setSchedule(agentID: UUID, _ schedule: AgentSchedule) async throws {
        if isAccount { try await remote("setSchedule", ["agentID": agentID.uuidString, "intervalMinutes": schedule.intervalMinutes]); return }
        try mutate { try $0.setSchedule(agentID: agentID, schedule, now: Date()) }
    }

    func renameAgent(_ id: UUID, to name: String) async throws {
        if isAccount { try await remote("renameAgent", ["agentID": id.uuidString, "name": name]); return }
        try mutate { try $0.renameAgent(id: id, name: name, now: Date()) }
    }

    func pauseAgent(_ id: UUID) async throws {
        if isAccount { try await remote("pauseAgent", ["agentID": id.uuidString]); return }
        try mutate { try $0.pauseAgent(id: id, reason: .user, now: Date()) }
    }

    func resumeAgent(_ id: UUID) async throws {
        if isAccount { try await remote("resumeAgent", ["agentID": id.uuidString]); return }
        try mutate { try $0.resumeAgent(id: id, now: Date()) }
    }

    func deleteAgent(_ id: UUID) async throws {
        if isAccount { try await remote("deleteAgent", ["agentID": id.uuidString]); return }
        try mutate { try $0.deleteAgent(id: id, now: Date()) }
    }

    /// Stops every agent now. Returns how many open orders were cancelled.
    @discardableResult
    func engageKillSwitch() async throws -> Int {
        if isAccount {
            let reply = try await remote("engageKillSwitch")
            return (reply.data["ordersCancelled"] as? Int) ?? 0
        }
        return mutate { $0.engageKillSwitch(now: Date()) }
    }

    /// Turns the kill switch off. Agents stay paused until each is resumed.
    func releaseKillSwitch() async throws {
        if isAccount { try await remote("releaseKillSwitch"); return }
        mutate { $0.releaseKillSwitch(now: Date()) }
    }

    func rejectProposal(_ id: UUID) async throws {
        if isAccount { try await remote("rejectProposal", ["proposalID": id.uuidString]); return }
        try mutate { try $0.rejectProposal(id: id, now: Date()) }
    }

    @discardableResult
    func cancelOrder(_ id: UUID) async throws -> Bool {
        if isAccount {
            try await remote("cancelOrder", ["orderID": id.uuidString])
            return order(id)?.status == .canceled
        }
        return mutate { $0.cancelOrder(id: id, now: Date()) }
    }

    // MARK: - Orders

    /// Loads a fresh quote and recent history for an instrument so an order can be previewed
    /// and checked. Returns a message when prices couldn't be loaded.
    @discardableResult
    func prepare(_ instrument: Instrument) async -> String? {
        let snapshot = await data.snapshot(for: [instrument], timeframe: .day, barCount: 60)
        let now = Date()
        if isAccount {
            // Prices only: matching orders and moving money is the server's job.
            for quote in snapshot.quotes.values where quote.last > 0 { engine.state.quotes[quote.instrumentID] = quote }
            for (id, stats) in snapshot.stats(now: now) { engine.state.stats[id] = stats }
            state = engine.state
        } else {
            mutate { $0.ingest(quotes: Array(snapshot.quotes.values), stats: snapshot.stats(now: now), now: now) }
        }
        if snapshot.quotes[instrument.id] == nil {
            return snapshot.failures[instrument.id] ?? "A live price for \(instrument.symbol) isn't available right now."
        }
        return nil
    }

    /// What would happen if this order were placed now. Changes nothing. In an account it is
    /// worked out on the phone with the same engine; the server checks the order again.
    func preview(_ request: OrderRequest) -> OrderPreview? { engine.preview(request, now: Date()) }

    /// Places a paper order. The result says plainly whether it was accepted or refused.
    @discardableResult
    func submit(_ request: OrderRequest) async throws -> OrderResult {
        if isAccount {
            let reply = try await remote("placeOrder", ["order": try TradingServerClient.json(request)],
                                         idempotencyKey: request.clientOrderID)
            return try orderResult(from: reply)
        }
        return mutate { $0.submit(request, now: Date()) }
    }

    /// Approves a waiting proposal. Prices are refreshed first so the risk checks judge the
    /// order against the market as it is now, not as it was when the agent proposed it.
    @discardableResult
    func approveProposal(_ id: UUID) async throws -> OrderResult {
        guard let proposal = proposal(id) else { throw TradingError.notFound("That proposal") }
        if isAccount {
            // The server fetches its own prices for the re-check.
            let reply = try await remote("approveProposal", ["proposalID": id.uuidString])
            return try orderResult(from: reply)
        }
        await prepare(proposal.instrument)
        return try mutate { try $0.approveProposal(id: id, now: Date()) }
    }

    /// Reads `{accepted, risk, order?, fills?}` from an order reply.
    private func orderResult(from reply: TradingServerReply) throws -> OrderResult {
        let risk = try reply.decode(RiskReport.self, at: "risk")
        let order = reply.data["order"] == nil ? nil : try reply.decode(Order.self, at: "order")
        if reply.data["accepted"] as? Bool == true, let order {
            let fills = reply.data["fills"] == nil ? [] : try reply.decode([Fill].self, at: "fills")
            return .accepted(order: order, fills: fills, risk: risk)
        }
        return .rejected(order: order, risk: risk)
    }

    // MARK: - Running agents

    /// Runs one agent now. On the phone it fetches market data and runs here; in an account
    /// the server fetches its own data and runs it there.
    @discardableResult
    func run(agentID: UUID, trigger: RunTrigger) async -> AgentRun? {
        guard let agent = agent(agentID), !runningAgentIDs.contains(agentID) else { return nil }
        runningAgentIDs.insert(agentID)
        defer { runningAgentIDs.remove(agentID) }
        if isAccount {
            do {
                let reply = try await remote("runAgent", ["agentID": agentID.uuidString])
                return try? reply.decode(AgentRun.self, at: "run")
            } catch {
                syncProblem = "\(agent.name) couldn't run on the server. \(error.localizedDescription)"
                return nil
            }
        }
        var instruments = agent.spec.universe
        if agent.spec.followsLedgerPositions { instruments = ledger(agent.ledgerID)?.positions.map(\.instrument) ?? [] }
        let snapshot = instruments.isEmpty ? MarketSnapshot()
            : await data.snapshot(for: instruments, timeframe: agent.spec.timeframe, barCount: agent.spec.barsToFetch)
        return mutate { $0.runAgent(id: agentID, snapshot: snapshot, trigger: trigger, now: Date()) }
    }

    /// One round of housekeeping. On the phone: fresh prices, then every agent whose time has
    /// come. In an account the server's scheduler does that; the phone just catches up.
    func tick() async {
        guard !isTicking else { return }
        isTicking = true
        defer { isTicking = false }
        if isAccount {
            await syncFromAccount()
            return
        }
        // Signed in, but the account couldn't be reached earlier: try again every few minutes.
        if wantsAccount, Date().timeIntervalSince(lastAccountAttempt ?? .distantPast) > 180 {
            await useAccount()
            if isAccount { return }
        }
        await refreshPrices()
        for agent in engine.dueAgents(at: Date()) {
            await run(agentID: agent.id, trigger: .schedule)
        }
    }

    /// Fetches quotes for open orders, positions and waiting proposals. On the phone this also
    /// lets waiting orders trade and reprices every practice portfolio.
    func refreshPrices() async {
        if isAccount {
            await syncFromAccount()
            return
        }
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
                if UIApplication.shared.applicationState == .active, let self, self.hasAnything || self.wantsAccount {
                    await self.tick()
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Called from background refresh, when iOS allows it. In an account the server already
    /// runs agents; on the phone this is a best-effort extra.
    func backgroundTick() async {
        guard hasAnything || isAccount else { return }
        await tick()
        if home == .device { saveNow() }
    }

    // MARK: - Research

    /// Plain facts about an instrument from real daily bars, with where they came from.
    /// nil when the prices couldn't be loaded — never a guess.
    func marketFacts(for instrument: Instrument) async -> (facts: [Evidence], source: String, asOf: Date)? {
        guard let series = try? await data.bars(for: instrument, timeframe: .day, count: 260),
              series.provenance.isRealMarketData || usesFixtureData else { return nil }
        let bars = MarketCalendar.standard.completedBars(series, now: Date())
        guard let last = bars.last else { return nil }
        return (StrategyEvaluator.researchFacts(bars: bars), series.provenance.source, last.time)
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
            : Self.benchmark(for: spec.universe.first?.venue ?? .us)
        let benchmark = try? await data.bars(for: benchmarkInstrument, timeframe: spec.timeframe, count: count)
        var config = BacktestConfig(agent: draft, paper: state.paperConfig)
        config.allowFixtureData = usesFixtureData
        let series = snapshot.series
        let now = Date()
        let result = try await Task.detached(priority: .userInitiated) {
            try Backtester.run(spec: spec, series: series, benchmark: benchmark, config: config, asOf: now)
        }.value
        // On the phone the audit trail records that a backtest was run. (A backtest changes
        // nothing in an account, so it isn't sent to the server.)
        if home == .device { mutate {
            $0.noteBacktest(title: spec.title,
                            summary: String(format: "%+.1f%% over %d bars, %d trades, max drawdown %.1f%%.",
                                            result.overall.totalReturnPct, result.overall.bars,
                                            result.overall.closedTrades, result.overall.maxDrawdownPct),
                            agentID: agentID,
                            details: ["dataSources": result.dataSources.joined(separator: ", "),
                                      "realMarketData": String(result.usedRealMarketData)],
                            now: Date())
        } }
        return result
    }

    /// A broad index fund on the same exchange, so a strategy is compared with simply
    /// holding that market. If it can't be loaded the report just has no benchmark.
    static func benchmark(for venue: Venue) -> Instrument {
        switch venue {
        case .us, .crypto: return .usETF("SPY", name: "S&P 500 ETF")
        case .asx: return .listed("STW", name: "ASX 200 ETF", on: .asx, etf: true)
        case .lse: return .listed("ISF", name: "FTSE 100 ETF", on: .lse, etf: true)
        case .xetra: return .listed("EXS1", name: "DAX ETF", on: .xetra, etf: true)
        case .euronextParis: return .listed("CAC", name: "CAC 40 ETF", on: .euronextParis, etf: true)
        case .euronextAmsterdam: return .listed("IAEX", name: "AEX ETF", on: .euronextAmsterdam, etf: true)
        case .six: return .listed("CSSMI", name: "SMI ETF", on: .six, etf: true)
        case .tse: return .listed("1306", name: "TOPIX ETF", on: .tse, etf: true)
        case .hkex: return .listed("2800", name: "Tracker Fund (Hang Seng)", on: .hkex, etf: true)
        case .sgx: return .listed("ES3", name: "STI ETF", on: .sgx, etf: true)
        case .krx: return .listed("069500", name: "KOSPI 200 ETF", on: .krx, etf: true)
        case .nse: return .listed("NIFTYBEES", name: "Nifty 50 ETF", on: .nse, etf: true)
        }
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

    /// The phone's own saved practice data.
    private func loadDeviceState() -> TradingState {
        guard let bytes = try? Data(contentsOf: fileURL),
              var loaded = try? TradingCodec.decoder().decode(TradingState.self, from: bytes) else { return TradingState() }
        loaded.accountPolicy.allowFixtureData = usesFixtureData
        loaded.accountPolicy.live = .disabled
        return loaded
    }

    private func saveNow() {
        saveTask?.cancel()
        // Only the phone's own data is saved here; an account's lives on the server.
        guard home == .device else { return }
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
