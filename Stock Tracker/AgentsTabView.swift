//
//  AgentsTabView.swift
//  Stock Tracker
//
//  The Agents tab: what is waiting for a decision, every agent and its state,
//  the page for one agent, and the sheet for approving or rejecting a proposal.
//
//  An agent here is a worker you can inspect, not a chatbot: its rules are
//  written out, every run leaves a trace of what it saw and which checks passed
//  or failed, and one tap pauses it.
//

import SwiftUI
import TradingCore

struct AgentsTabView: View {
    @EnvironmentObject private var trading: TradingStore
    @EnvironmentObject private var router: TradingRouter
    @Environment(\.theme) private var theme

    private var attention: [TradingAgent] { trading.agents.filter(\.needsAttention) }
    private var running: [TradingAgent] { trading.agents.filter { $0.status == .active } }
    private var paused: [TradingAgent] { trading.agents.filter { $0.status != .active && !$0.needsAttention } }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.l) {
                    TradingHomeBadge()
                    copilotEntry
                    PausedAllBanner { router.showPauseAll = true }

                    if !trading.pendingProposals.isEmpty {
                        VStack(alignment: .leading, spacing: DS.Space.m) {
                            SectionHeader(title: "Needs your decision")
                            ForEach(trading.pendingProposals) { proposal in
                                Button { router.proposal = TradingRouter.Ref(id: proposal.id) } label: { approvalCard(proposal) }
                                    .buttonStyle(PressableButtonStyle())
                                    .accessibilityIdentifier("agents.approval.\(proposal.instrument.symbol)")
                            }
                        }
                    }

                    if trading.agents.isEmpty {
                        EmptyStateCard(
                            systemImage: "gearshape.2",
                            title: "No agents yet",
                            message: "An agent watches the assets you choose, follows rules you can read, and trades practice money. You see every decision it makes and why.",
                            primaryTitle: "Create an agent",
                            primaryAction: { router.createAgent() }
                        )
                        .staggeredAppear(0)
                        .accessibilityIdentifier("agents.empty")
                    } else {
                        statusRow.staggeredAppear(0)
                        group("Needs attention", attention)
                        group("Running", running)
                        group("Paused", paused)
                    }

                    PracticeNote(text: "Agents trade practice money only. Signals, backtests and paper results are simulations, not financial advice.")
                        .padding(.top, DS.Space.s)
                }
                .padding(.horizontal, DS.Space.gutter)
                .padding(.top, DS.Space.s)
                .padding(.bottom, 60)
            }
            .refreshable { await trading.tick() }
            .dsScreenBackground(style: .agents)
            .navigationTitle("Agents")
            .toolbar {
                TradingToolbar()
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.tap()
                        router.createAgent()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New agent")
                    .accessibilityIdentifier("agents.new")
                }
            }
            .navigationDestination(for: UUID.self) { AgentDetailView(agentID: $0) }
        }
        .accessibilityIdentifier("agents.screen")
    }

    private var copilotEntry: some View {
        Button {
            Haptics.tap()
            router.askCopilot()
        } label: {
            HStack(spacing: DS.Space.m) {
                Image(systemName: "sparkles")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.intelligenceTint)
                    .frame(width: 38, height: 38)
                    .background(theme.intelligenceTint.opacity(0.13), in: RoundedRectangle(cornerRadius: DS.Radius.chip))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ask Copilot").font(.subheadline.weight(.semibold)).foregroundStyle(theme.primaryText)
                    Text("Research your portfolio, orders and agents")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: DS.Space.s)
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.intelligenceTint)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .dsCard(padding: DS.Space.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityIdentifier("agents.copilot")
    }

    private var statusRow: some View {
        HStack {
            StatusLabel(systemImage: running.isEmpty ? "pause.circle" : "play.circle.fill",
                        text: "\(running.count) of \(trading.agents.count) running")
            Spacer()
            if !trading.isKillSwitchOn {
                Button("Pause all") { router.showPauseAll = true }
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, DS.Space.m)
                    .frame(minHeight: 36)
                    .overlay(Capsule().strokeBorder(theme.primaryText.opacity(0.5), lineWidth: 1))
                    .foregroundStyle(theme.primaryText)
                    .disabled(running.isEmpty)
                    .opacity(running.isEmpty ? 0.4 : 1)
                    .accessibilityHint(running.isEmpty ? "No agents are running" : "Stops every agent at once")
                    .accessibilityIdentifier("agents.pauseAll")
            }
        }
    }

    @ViewBuilder
    private func group(_ title: LocalizedStringKey, _ agents: [TradingAgent]) -> some View {
        if !agents.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(theme.secondaryText)
                    .accessibilityAddTraits(.isHeader)
                ForEach(agents) { agent in
                    NavigationLink(value: agent.id) { AgentCard(agent: agent) }
                        .buttonStyle(PressableButtonStyle())
                        .accessibilityIdentifier("agents.card.\(agent.name)")
                }
            }
        }
    }

    private func approvalCard(_ proposal: TradeProposal) -> some View {
        let currency = proposal.instrument.currency
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(trading.agent(proposal.agentID)?.name ?? "An agent").font(.caption.weight(.semibold)).foregroundStyle(theme.secondaryText)
                PracticeChip(compact: true)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(theme.secondaryText)
            }
            Text("Wants to \(proposal.side.rawValue) \(TradingFormat.money(proposal.notional, currency)) of \(proposal.instrument.symbol)")
                .font(.body.weight(.semibold))
                .foregroundStyle(theme.primaryText)
            Text(proposal.headline).font(.footnote).foregroundStyle(theme.secondaryText).lineLimit(2)
            Text("Expires \(TradingFormat.relative(proposal.expiresAt))").font(.caption).foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the proposal to approve or reject")
    }
}

// MARK: - Agent card

struct AgentCard: View {
    let agent: TradingAgent
    @EnvironmentObject private var trading: TradingStore
    @Environment(\.theme) private var theme

    var body: some View {
        let ledger = trading.ledger(agent.ledgerID)
        let ownsLedger = ledger?.kind == .agentPaper
        let trades = trading.state.fills.filter { $0.source.agentID == agent.id }.count
        let latestRun = trading.state.runs.lazy.filter { $0.agentID == agent.id }.max { $0.startedAt < $1.startedAt }
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(alignment: .center, spacing: DS.Space.m) {
                AgentAvatar(seed: agent.templateID ?? agent.id.uuidString,
                            systemImage: AgentTemplates.template(agent.templateID)?.symbolName ?? "sparkles")
                VStack(alignment: .leading, spacing: 3) {
                    Text(agent.name)
                        .font(.headline)
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        StatusLabel(systemImage: trading.runningAgentIDs.contains(agent.id) ? "arrow.triangle.2.circlepath" : agent.statusGlyph,
                                    text: trading.runningAgentIDs.contains(agent.id) ? "Checking now" : agent.statusText,
                                    tint: agent.needsAttention ? theme.warningColor : theme.secondaryText, compact: true)
                        if let last = agent.lastRunAt {
                            Text("· \(TradingFormat.relative(last))").font(.caption).foregroundStyle(theme.secondaryText).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: DS.Space.s)
                VStack(alignment: .trailing, spacing: 6) {
                    if agent.mode == .paper { PracticeChip(compact: true) }
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(theme.secondaryText)
                }
            }
            Text(agent.spec.summary)
                .font(.footnote)
                .foregroundStyle(theme.secondaryText)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if let latestRun {
                Text(latestRun.summary)
                    .font(.footnote)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(2)
            }
            if agent.status == .active, let nextRun = agent.nextRunAt, nextRun > Date() {
                Text("Next check \(TradingFormat.time(nextRun))")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }
            HStack(alignment: .firstTextBaseline) {
                Label(agent.mode.displayName, systemImage: agent.mode.glyph)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: DS.Space.s)
                if let ledger, ownsLedger {
                    GainLossText(value: ledger.totalReturn,
                                 text: "\(TradingFormat.signedMoney(ledger.totalReturn, ledger.currency)) (\(TradingFormat.percent(ledger.totalReturnPct)))",
                                 font: .footnote.weight(.semibold).monospacedDigit())
                    Text("· \(trades) trade\(trades == 1 ? "" : "s")").font(.caption.monospacedDigit()).foregroundStyle(theme.secondaryText)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - One agent

struct AgentDetailView: View {
    let agentID: UUID

    @EnvironmentObject private var trading: TradingStore
    @EnvironmentObject private var router: TradingRouter
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var showLimits = false
    @State private var confirmDelete = false
    @State private var lockedMode: AgentMode?
    @State private var problem: String?
    @State private var isBacktesting = false
    @State private var backtest: BacktestBox?
    @State private var expandedRun: UUID?
    @State private var accountRuns: [AgentActivityRow]?
    @State private var nextRunCursor: String?
    @State private var localRunLimit = 20
    @State private var runsLoading = false
    @State private var runsProblem: String?
    @State private var failedRunCursor: String?
    @State private var runDetail: AgentActivityDetail?
    @State private var detailProblem: String?
    @State private var detailRetry = 0
    @State private var openedProposal: TradingRouter.Ref?
    @State private var openedOrder: TradingRouter.Ref?
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        Group {
            if let agent = trading.agent(agentID) {
                content(agent)
            } else {
                ContentUnavailableView("Agent removed", systemImage: "gearshape.2", description: Text("This agent no longer exists."))
            }
        }
        .dsScreenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showLimits) { AgentLimitsEditor(agentID: agentID) }
        .sheet(item: $backtest) { box in
            NavigationStack {
                BacktestReportView(result: box.result, title: box.title,
                                   currency: box.currency, testedRuleLines: box.testedRuleLines)
            }
        }
        .sheet(item: $openedProposal) { ProposalReviewSheet(proposalID: $0.id) }
        .sheet(item: $openedOrder) { ref in NavigationStack { OrderDetailView(orderID: ref.id) } }
        .alert("That didn't work", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(problem ?? "") }
        .alert("Live trading isn't available", isPresented: Binding(get: { lockedMode != nil }, set: { if !$0 { lockedMode = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(trading.liveBlockers(for: lockedMode).joined(separator: " "))
        }
        .alert("Rename agent", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") { attempt { try await trading.renameAgent(agentID, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Runs a change and shows any refusal. Changes can go to the account's server, so
    /// they're asynchronous.
    private func attempt(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch { problem = error.localizedDescription }
        }
    }

    private func content(_ agent: TradingAgent) -> some View {
        let ledger = trading.ledger(agent.ledgerID)
        let pending = trading.proposals(for: agentID).filter { $0.status == .pending }
        return ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                statusCard(agent)

                if !pending.isEmpty {
                    TradingSection(title: "Needs your decision") {
                        ForEach(pending) { proposal in
                            Button { openedProposal = TradingRouter.Ref(id: proposal.id) } label: { ProposalRowView(proposal: proposal) }
                                .buttonStyle(PressableButtonStyle())
                        }
                    }
                }

                whatItDoes(agent, ledger: ledger)

                if let ledger, agent.mode == .paper { portfolioCard(agent, ledger: ledger) }

                timeline

                VStack(alignment: .leading, spacing: 0) {
                    if agent.spec.kind != .research, !agent.spec.followsLedgerPositions {
                        actionRow(isBacktesting ? "Testing on two years of prices…" : "Backtest this strategy", "chart.xyaxis.line", id: "backtest") { runBacktest(agent) }
                            .disabled(isBacktesting)
                    }
                    if agent.mode == .paper {
                        actionRow("Change risk limits", "slider.horizontal.3", id: "limits") { showLimits = true }
                    }
                    actionRow("Rename", "pencil", id: "rename") {
                        newName = agent.name
                        renaming = true
                    }
                    actionRow("Delete agent", "trash", id: "delete", destructive: true) { confirmDelete = true }
                }
                .dsCard(padding: DS.Space.s)
                .confirmationDialog("Delete \(agent.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Delete agent", role: .destructive) {
                        attempt { try await trading.deleteAgent(agentID) }
                        dismiss()
                    }
                } message: {
                    Text("Its open orders are cancelled and its practice portfolio is removed. What it did stays in the audit trail.")
                }

                PracticeNote(text: "Practice money only. Past paper results don't predict future returns, and nothing here is financial advice.")
            }
            .padding(.horizontal, DS.Space.gutter)
            .padding(.vertical, DS.Space.l)
        }
        .refreshable {
            await trading.refreshPrices()
            if trading.isAccount { await loadActivity() }
        }
        .task(id: trading.home) {
            accountRuns = nil
            nextRunCursor = nil
            runsProblem = nil
            runDetail = nil
            expandedRun = nil
            if trading.isAccount { await loadActivity() }
        }
        .onChange(of: trading.runs(for: agentID).first?.id) {
            if trading.isAccount { Task { await loadActivity() } }
        }
        .task(id: RunEvidenceSelection(run: expandedRun, lastSync: trading.lastSyncAt, auditSequence: trading.auditNewestFirst.first?.sequence, retry: detailRetry)) {
            guard let id = expandedRun else { return }
            detailProblem = nil
            do {
                let detail = try await trading.agentActivityDetail(runID: id)
                if !Task.isCancelled { runDetail = detail }
            } catch {
                if !Task.isCancelled { detailProblem = error.localizedDescription }
            }
        }
        .navigationTitle(agent.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { if agent.mode == .paper { PracticeChip() } }
        }
        .accessibilityIdentifier("agent.detail")
    }

    // MARK: Status

    private func statusCard(_ agent: TradingAgent) -> some View {
        let isChecking = trading.runningAgentIDs.contains(agent.id)
        return VStack(alignment: .leading, spacing: DS.Space.m) {
            StatusLabel(systemImage: agent.statusGlyph, text: agent.statusText,
                        tint: agent.needsAttention ? theme.warningColor : theme.primaryText)
                .accessibilityIdentifier("agent.status")
            Text(statusSentence(agent))
                .font(DS.display(.title3))
                .fixedSize(horizontal: false, vertical: true)
            if let error = agent.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(theme.warningColor)
            }
            if let reason = agent.pauseReason, agent.status == .paused, reason != .user {
                Text(reason.explanation).font(.footnote).foregroundStyle(theme.secondaryText)
            }
            HStack(spacing: DS.Space.m) {
                if agent.status == .active {
                    Button {
                        attempt { try await trading.pauseAgent(agentID) }
                        Haptics.tap()
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .buttonStyle(SecondaryPillButtonStyle())
                    .accessibilityIdentifier("agent.pause")
                } else {
                    Button {
                        attempt { try await trading.resumeAgent(agentID) }
                        Haptics.tap()
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryPillButtonStyle())
                    .disabled(trading.isKillSwitchOn)
                    .accessibilityHint(trading.isKillSwitchOn ? "Turn off pause-all first" : "")
                    .accessibilityIdentifier("agent.resume")
                }
                Button {
                    Task { await trading.run(agentID: agentID, trigger: .manual) }
                } label: {
                    HStack(spacing: 6) {
                        if isChecking { ProgressView().controlSize(.small) }
                        Text(isChecking ? "Checking…" : "Check now")
                    }
                }
                .buttonStyle(SecondaryPillButtonStyle())
                .disabled(isChecking || agent.status != .active || trading.isKillSwitchOn)
                .accessibilityIdentifier("agent.runNow")
            }
            if trading.isKillSwitchOn {
                Text("Pause-all is on. Turn it off to resume this agent.").font(.caption).foregroundStyle(theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    private func statusSentence(_ agent: TradingAgent) -> String {
        switch agent.status {
        case .active:
            if let next = agent.nextRunAt, next > Date() {
                return "Watching \(universeText(agent)). Next check \(TradingFormat.relative(next))."
            }
            return "Watching \(universeText(agent))."
        case .paused: return "Not checking the market or placing orders."
        case .stopped: return "Stopped."
        }
    }

    private func universeText(_ agent: TradingAgent) -> String {
        if agent.spec.followsLedgerPositions { return "the positions in \(trading.ledger(agent.ledgerID)?.name ?? "its portfolio")" }
        let symbols = agent.spec.universe.map(\.symbol)
        return symbols.count <= 3 ? symbols.joined(separator: ", ") : "\(symbols.prefix(3).joined(separator: ", ")) and \(symbols.count - 3) more"
    }

    // MARK: What it does

    private func whatItDoes(_ agent: TradingAgent, ledger: Ledger?) -> some View {
        let policy = agent.riskPolicy
        let currency = ledger?.currency ?? agent.spec.universe.first?.currency ?? "USD"
        return TradingSection(title: "What it does", trailing: "Version \(agent.strategyVersion)") {
            Text(agent.spec.summary).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            ForEach(agent.spec.ruleLines, id: \.self) { line in
                Label {
                    Text(line).font(.footnote).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "arrow.turn.down.right").font(.caption)
                }
                .foregroundStyle(theme.secondaryText)
            }
            if !agent.spec.universe.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(agent.spec.universe) { instrument in
                        Text(instrument.symbol)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .frame(minHeight: 26)
                            .background(Capsule().fill(theme.subtleFill))
                            .overlay(Capsule().strokeBorder(theme.cardBorder, lineWidth: 0.5))
                    }
                }
            }
            Divider()
            Menu {
                ForEach(AgentMode.allCases, id: \.self) { mode in
                    Button {
                        if mode.isLive { lockedMode = mode } else { attempt { try await trading.setMode(agentID: agentID, mode: mode) } }
                    } label: {
                        Label(mode.isLive ? "\(mode.displayName) (not available)" : mode.displayName,
                              systemImage: mode.isLive ? "lock" : (agent.mode == mode ? "checkmark" : mode.glyph))
                    }
                }
            } label: {
                HStack {
                    Text("Allowed to").font(.subheadline).foregroundStyle(theme.secondaryText)
                    Spacer()
                    Text(agent.mode.displayName).font(.subheadline.weight(.semibold)).foregroundStyle(theme.primaryText)
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(theme.secondaryText)
                }
                .frame(minHeight: 44)
            }
            .accessibilityIdentifier("agent.mode")
            if agent.mode == .paper {
                Toggle("Ask me before each trade", isOn: Binding(
                    get: { agent.reviewEachPaperTrade },
                    set: { value in attempt { try await trading.setReviewEachTrade(agentID: agentID, value) } }))
                    .font(.subheadline)
                    .accessibilityIdentifier("agent.review")
                TradingRow(label: "Largest single order", value: TradingFormat.money(policy.maxOrderNotional, currency))
                TradingRow(label: "Largest position", value: "\(Operand.trim(policy.maxPositionPct))% of the portfolio")
                TradingRow(label: "Most traded in a day", value: TradingFormat.money(policy.maxDailyNotional, currency))
                TradingRow(label: "Daily loss limit", value: "\(Operand.trim(policy.maxDailyLossPct))%")
                TradingRow(label: "Drawdown limit", value: "\(Operand.trim(policy.maxDrawdownPct))%")
            }
            TradingRow(label: "Checks", value: agent.schedule.displayName)
        }
    }

    // MARK: Portfolio

    private func portfolioCard(_ agent: TradingAgent, ledger: Ledger) -> some View {
        let sells = trading.fills(in: ledger.id).filter { $0.source.agentID == agent.id && $0.side == .sell }
        let wins = sells.filter { ($0.realizedPnL ?? 0) > 0 }.count
        var peak = ledger.startingCash
        var worst = 0.0
        for point in ledger.equityHistory {
            peak = max(peak, point.equity)
            if peak > 0 { worst = max(worst, (peak - point.equity) / peak * 100) }
        }
        let columns = Array(repeating: GridItem(.flexible(), spacing: DS.Space.m), count: typeSize.isAccessibilitySize ? 1 : 2)
        return TradingSection(title: ledger.kind == .agentPaper ? "Practice portfolio" : "Guarding \(ledger.name)") {
            Text(TradingFormat.money(ledger.equity, ledger.currency))
                .font(DS.money(30))
                .contentTransition(.numericText())
                .accessibilityIdentifier("agent.equity")
            GainLossText(value: ledger.totalReturn,
                         text: "\(TradingFormat.signedMoney(ledger.totalReturn, ledger.currency)) (\(TradingFormat.percent(ledger.totalReturnPct))) since start")
            EquityCurveChart(points: ledger.equityHistory, currency: ledger.currency, height: 140)
            LazyVGrid(columns: columns, spacing: DS.Space.m) {
                figure("Budget", TradingFormat.money(ledger.startingCash, ledger.currency))
                figure("Cash", TradingFormat.money(ledger.cash, ledger.currency))
                figure("Sales that made money", sells.isEmpty ? "—" : "\(wins) of \(sells.count)")
                figure("Worst fall from a peak", String(format: "%.1f%%", worst))
            }
            if !ledger.positions.isEmpty {
                Divider()
                Text("Open positions").font(.subheadline.weight(.semibold))
                ForEach(ledger.positions.sorted { $0.marketValue > $1.marketValue }) { position in
                    AdaptiveQuoteRow {
                        InstrumentLabel(instrument: position.instrument,
                                        subtitle: "\(TradingFormat.quantity(position.quantity, position.instrument)) at \(TradingFormat.price(position.averageCost, ledger.currency))",
                                        logoSize: 32)
                    } numbers: { _ in
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(TradingFormat.money(position.marketValue, ledger.currency)).font(.subheadline.weight(.semibold).monospacedDigit())
                            GainLossText(value: position.unrealizedPnL, text: TradingFormat.percent(position.unrealizedPct),
                                         font: .caption.weight(.semibold).monospacedDigit())
                        }
                    }
                    .accessibilityIdentifier("agent.position.\(position.instrument.symbol)")
                }
            }
            let open = trading.orders(for: agentID).filter { $0.status.isOpen }
            if !open.isEmpty {
                Divider()
                Text("Open orders").font(.subheadline.weight(.semibold))
                ForEach(open) { order in
                    Button { openedOrder = TradingRouter.Ref(id: order.id) } label: { OrderRowView(order: order) }
                        .buttonStyle(PressableButtonStyle())
                }
            }
        }
    }

    private func figure(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(theme.secondaryText)
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Timeline

    private struct RunEvidenceSelection: Equatable {
        var run: UUID?
        var lastSync: Date?
        var auditSequence: Int?
        var retry: Int
    }

    private func loadActivity(before: String? = nil) async {
        guard !runsLoading else { return }
        runsLoading = true
        runsProblem = nil
        defer { runsLoading = false }
        do {
            let page = try await trading.agentActivity(for: agentID, before: before)
            guard !Task.isCancelled, trading.isAccount else { return }
            if let current = accountRuns {
                let seen = Set(current.map(\.id))
                if before != nil {
                    accountRuns = current + page.runs.filter { !seen.contains($0.id) }
                    nextRunCursor = page.nextCursor
                } else if current.count > 20, page.runs.contains(where: { seen.contains($0.id) }) {
                    accountRuns = page.runs.filter { !seen.contains($0.id) } + current
                } else {
                    accountRuns = page.runs
                    nextRunCursor = page.nextCursor
                }
            } else {
                accountRuns = page.runs
                nextRunCursor = page.nextCursor
            }
        } catch {
            if !Task.isCancelled {
                failedRunCursor = before
                runsProblem = error.localizedDescription
            }
        }
    }

    private var timeline: some View {
        let saved = trading.runs(for: agentID)
        let runs = accountRuns ?? saved.prefix(localRunLimit).map { AgentActivityRow(run: $0) }
        return TradingSection(title: "Agent activity timeline") {
            if runsLoading && runs.isEmpty {
                ProgressView("Loading activity…")
            } else if runs.isEmpty && runsProblem == nil {
                Text(trading.runningAgentIDs.contains(agentID) ? "Looking at the market for the first time…"
                     : "Nothing yet. Tap Check now and its first look at the market appears here.")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityIdentifier("agent.timeline.empty")
            }
            ForEach(runs) { run in
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Button {
                        dsAnimate { expandedRun = expandedRun == run.id ? nil : run.id }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                            Image(systemName: runGlyph(run)).font(.footnote).frame(width: 18)
                                .foregroundStyle(run.status == .failed ? theme.warningColor : theme.primaryText)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(run.summary).font(.subheadline).foregroundStyle(theme.primaryText)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("\(TradingFormat.time(run.startedAt)) · \(run.trigger == .manual ? "you asked" : "scheduled") · version \(run.strategyVersion)")
                                    .font(.caption)
                                    .foregroundStyle(theme.secondaryText)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                                .rotationEffect(.degrees(expandedRun == run.id ? 180 : 0))
                                .foregroundStyle(theme.secondaryText)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .accessibilityHint("Shows what it looked at and which checks passed")
                    .accessibilityIdentifier("agent.run.\(run.status.rawValue)")
                    if expandedRun == run.id { expandedActivity(run.id) }
                }
                if run.id != runs.last?.id { Divider() }
            }
            if let runsProblem {
                Text(runsProblem).font(.footnote).foregroundStyle(theme.warningColor)
                Button("Retry activity") { Task { await loadActivity(before: failedRunCursor) } }
            } else if trading.isAccount ? nextRunCursor != nil : saved.count > localRunLimit {
                Button("Load older runs") {
                    if trading.isAccount { Task { await loadActivity(before: nextRunCursor) } }
                    else { localRunLimit += 20 }
                }
                .disabled(runsLoading)
                .accessibilityIdentifier("agent.timeline.older")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent.timeline")
    }

    @ViewBuilder private func expandedActivity(_ id: UUID) -> some View {
        if let detail = runDetail, detail.run.id == id {
            AgentRunEvidence(detail: detail)
        } else if let detailProblem {
            Text(detailProblem).font(.footnote).foregroundStyle(theme.warningColor)
            Button("Retry run details") { detailRetry += 1 }
        } else {
            ProgressView("Loading decision evidence…")
        }
    }

    private func runGlyph(_ run: AgentActivityRow) -> String {
        if run.status == .failed { return "exclamationmark.triangle" }
        if run.status == .skipped { return "forward.end" }
        return "checkmark.circle"
    }

    private func actionRow(_ title: String, _ systemImage: String, id: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage).font(.subheadline)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(theme.secondaryText)
            }
            .foregroundStyle(destructive ? theme.negativeColor : theme.primaryText)
            .padding(.horizontal, DS.Space.s)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("agent.action.\(id)")
    }

    private func runBacktest(_ agent: TradingAgent) {
        isBacktesting = true
        let draft = AgentDraft(name: agent.name, mode: agent.mode, spec: agent.spec,
                               budget: trading.ledger(agent.ledgerID)?.startingCash ?? agent.budget,
                               maxPositionPct: agent.riskPolicy.maxPositionPct, riskPolicy: agent.riskPolicy)
        Task {
            do {
                backtest = BacktestBox(result: try await trading.backtest(draft, years: 2, agentID: agent.id), title: agent.name,
                                       currency: draft.currency, testedRuleLines: draft.spec.ruleLines)
            } catch {
                problem = "The backtest couldn't run: \(error.localizedDescription)"
            }
            isBacktesting = false
        }
    }
}

struct AgentRunEvidence: View {
    let detail: AgentActivityDetail
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("Run ID \(detail.run.id.uuidString.lowercased())").font(.caption).foregroundStyle(theme.secondaryText)
                .textSelection(.enabled)
            ForEach(detail.run.steps) { stepRow($0) }
            ForEach(detail.signals) { signal in
                Text("\(signal.instrument.symbol) · \(signal.provenance.source) · Bar dated \(TradingFormat.time(signal.barTime)) · Close \(TradingFormat.money(signal.close, signal.instrument.currency))")
                    .font(.footnote).foregroundStyle(theme.secondaryText)
            }
            ForEach(detail.proposals) { proposal in
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("\(proposal.side.rawValue.capitalized) \(NumberText.number(proposal.quantity)) \(proposal.instrument.symbol) · \(proposal.status.displayName)")
                        .font(.footnote.weight(.semibold))
                    if let review = detail.reviews.first(where: { $0.proposalID == proposal.id }) {
                        Text("\(review.kind == .proposalApproved ? "You approved" : "You declined") · \(TradingFormat.time(review.time))")
                    } else if proposal.orderID != nil {
                        Text("Submitted under the agent’s practice permissions")
                    }
                    if let note = proposal.resolutionNote { Text(note) }
                    Text("Proposal ID \(proposal.id.uuidString.lowercased())").textSelection(.enabled)
                    DisclosureGroup("Risk checks · \(TradingFormat.time(proposal.risk.evaluatedAt))") {
                        RiskReportView(report: proposal.risk)
                    }
                }
                .font(.caption)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("agent.timeline.proposal")
            }
            ForEach(detail.orders) { order in
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Practice order · \(order.instrument.symbol) · \(order.status.displayName)").font(.footnote.weight(.semibold))
                    Text("Order ID \(order.id.uuidString.lowercased())").textSelection(.enabled)
                    if let note = order.statusNote { Text(note) }
                    ForEach(detail.fills.filter { $0.orderID == order.id }) { fill in
                        Text("\(NumberText.number(fill.quantity)) filled at \(TradingFormat.money(fill.price, fill.instrument.currency)) · Fee \(TradingFormat.money(fill.fee, fill.instrument.currency)) · \(TradingFormat.time(fill.time))")
                        Text("Fill ID \(fill.id.uuidString.lowercased())").textSelection(.enabled)
                    }
                }
                .font(.caption)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("agent.timeline.order")
            }
        }
    }

    private func stepRow(_ step: RunStep) -> some View {
        let glyph: String
        let tint: Color
        switch step.outcome {
        case .ok: glyph = "checkmark"; tint = theme.positiveColor
        case .info: glyph = "circle.fill"; tint = theme.secondaryText
        case .warning: glyph = "exclamationmark.triangle"; tint = theme.warningColor
        case .blocked: glyph = "shield.slash"; tint = theme.negativeColor
        case .failed: glyph = "xmark"; tint = theme.negativeColor
        }
        return HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Image(systemName: glyph).font(.system(size: step.outcome == .info ? 5 : 11, weight: .bold))
                .foregroundStyle(tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(step.title).font(.footnote.weight(.semibold))
                if !step.detail.isEmpty {
                    Text(step.detail).font(.footnote).foregroundStyle(theme.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
                if !step.evidence.isEmpty { EvidenceList(evidence: step.evidence) }
            }
        }
        .padding(.leading, DS.Space.l)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent.step.\(step.kind.rawValue).\(step.outcome.rawValue)")
    }

}

// MARK: - Proposal review

/// A proposal with everything needed to decide: what it would do, why the agent wants it,
/// what it does to the portfolio, and the risk engine's checks. Approve and Reject are told
/// apart by word, icon and fill — not by colour.
struct ProposalReviewSheet: View {
    let proposalID: UUID

    @EnvironmentObject private var trading: TradingStore
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var isApproving = false
    @State private var outcome: OrderResult?
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Group {
                if let proposal = trading.proposal(proposalID) {
                    content(proposal)
                } else {
                    ContentUnavailableView("Proposal not found", systemImage: "hand.raised",
                                           description: Text("It may have been cleared from the history."))
                }
            }
            .dsScreenBackground()
            .navigationTitle("Proposed trade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.accessibilityIdentifier("proposal.close") }
                ToolbarItem(placement: .topBarTrailing) { PracticeChip() }
            }
        }
        .accessibilityIdentifier("proposal.sheet")
    }

    private func content(_ proposal: TradeProposal) -> some View {
        let currency = proposal.instrument.currency
        let ledger = trading.ledger(proposal.ledgerID)
        let agent = trading.agent(proposal.agentID)
        let signal = trading.signal(proposal.signalID)
        let order = trading.order(proposal.orderID)
        let positionAfter = (ledger?.position(proposal.instrument.id)?.marketValue ?? 0) + (proposal.side == .buy ? proposal.notional : -proposal.notional)
        let cashAfter = (ledger?.cash ?? 0) + (proposal.side == .buy ? -(proposal.notional + proposal.estimatedFee) : proposal.notional - proposal.estimatedFee)
        return ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Text(agent?.name ?? "An agent").font(.subheadline.weight(.semibold)).foregroundStyle(theme.secondaryText)
                    Text("\(proposal.side == .buy ? "Buy" : "Sell") \(TradingFormat.units(proposal.quantity, proposal.instrument)) for about \(TradingFormat.money(proposal.notional, currency)).")
                        .font(DS.display(.title2))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("proposal.sentence")
                    StatusLabel(systemImage: proposal.status.glyph, text: proposal.status.displayName)
                        .accessibilityIdentifier("proposal.status.\(proposal.status.rawValue)")
                    if proposal.status == .pending {
                        Text("If you do nothing it expires \(TradingFormat.relative(proposal.expiresAt)) and nothing is traded.")
                            .font(.footnote)
                            .foregroundStyle(theme.secondaryText)
                    } else if let note = proposal.resolutionNote {
                        Text(note).font(.footnote).foregroundStyle(theme.secondaryText).fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let outcome { outcomeCard(outcome, currency: currency) }

                TradingSection(title: "Why") {
                    Text(proposal.headline).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    if let signal, !signal.evidence.isEmpty { EvidenceList(evidence: signal.evidence) }
                    Text("From the daily bar of \(proposal.signalBarTime.formatted(date: .abbreviated, time: .omitted))\(signal.map { " · prices from \($0.provenance.source)" } ?? "") · strategy version \(proposal.strategyVersion)")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }

                TradingSection(title: "What it would do") {
                    TradingRow(label: "Account", value: TradingFormat.accountName(ledger?.name))
                    TradingRow(label: "Price when proposed", value: TradingFormat.price(proposal.referencePrice, currency))
                    TradingRow(label: proposal.side == .buy ? "Estimated cost" : "Estimated proceeds", value: TradingFormat.money(proposal.notional, currency), emphasised: true)
                    TradingRow(label: "Estimated fee", value: TradingFormat.money(proposal.estimatedFee, currency))
                    if proposal.status == .pending, let ledger {
                        TradingRow(label: "Cash after", value: TradingFormat.money(cashAfter, currency))
                        TradingRow(label: "\(proposal.instrument.symbol) after",
                                   value: String(format: "%.1f%% of the portfolio", ledger.equity > 0 ? max(positionAfter, 0) / ledger.equity * 100 : 0))
                    }
                    if let note = proposal.sizingNote {
                        Text(note).font(.caption).foregroundStyle(theme.secondaryText).fixedSize(horizontal: false, vertical: true)
                    }
                }

                TradingSection(title: "Risk checks") { RiskReportView(report: proposal.risk) }

                if let order {
                    TradingSection(title: "The order") {
                        OrderRowView(order: order)
                        Text("An order was placed for this proposal. Its status above says whether it has traded.")
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                    }
                }

                if let problem {
                    Text(problem).font(.footnote).foregroundStyle(theme.negativeColor).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("proposal.error")
                }

                PracticeNote()
            }
            .padding(.horizontal, DS.Space.gutter)
            .padding(.top, DS.Space.m)
            .padding(.bottom, 130)
        }
        .safeAreaInset(edge: .bottom) {
            if proposal.status == .pending, outcome == nil {
                HStack(spacing: DS.Space.m) {
                    Button {
                        Task {
                            do {
                                try await trading.rejectProposal(proposalID)
                                Haptics.tap()
                                dismiss()
                            } catch {
                                problem = error.localizedDescription
                            }
                        }
                    } label: {
                        Label("Reject", systemImage: "xmark")
                    }
                    .buttonStyle(SecondaryPillButtonStyle())
                    .disabled(isApproving)
                    .accessibilityIdentifier("proposal.reject")

                    Button {
                        approve()
                    } label: {
                        HStack(spacing: 6) {
                            if isApproving { ProgressView().controlSize(.small).tint(DS.primaryLabel) }
                            else { Image(systemName: "checkmark") }
                            Text(isApproving ? "Checking price…" : "Approve")
                        }
                    }
                    .buttonStyle(PrimaryPillButtonStyle())
                    .disabled(isApproving)
                    .accessibilityHint("Checks the order against the current price, then places a practice order")
                    .accessibilityIdentifier("proposal.approve")
                }
                .padding(.horizontal, DS.Space.gutter)
                .padding(.vertical, DS.Space.m)
            } else {
                Button("Done") { dismiss() }
                    .buttonStyle(PrimaryPillButtonStyle())
                    .accessibilityIdentifier("proposal.done")
                    .padding(.horizontal, DS.Space.gutter)
                    .padding(.vertical, DS.Space.m)
            }
        }
    }

    private func outcomeCard(_ outcome: OrderResult, currency: String) -> some View {
        let order = outcome.order.flatMap { trading.order($0.id) } ?? outcome.order
        let text: String
        if !outcome.isAccepted {
            text = "The order was not placed. \(outcome.risk.summary)"
        } else if let order, order.status == .filled {
            text = "Practice order filled: \(TradingFormat.units(order.filledQuantity, order.instrument)) at \(TradingFormat.price(order.averageFillPrice, currency))."
        } else {
            text = "Practice order placed. \(order?.statusNote ?? "It will trade when its price is available.")"
        }
        return Label {
            Text(text).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: outcome.isAccepted ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(outcome.isAccepted ? theme.positiveColor : theme.negativeColor)
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous).strokeBorder(theme.cardBorder, lineWidth: 1))
        .accessibilityIdentifier(outcome.isAccepted ? "proposal.outcome.placed" : "proposal.outcome.refused")
    }

    private func approve() {
        isApproving = true
        problem = nil
        Task {
            do {
                let result = try await trading.approveProposal(proposalID)
                outcome = result
                if result.isAccepted { Haptics.success() } else { Haptics.warning() }
            } catch {
                problem = error.localizedDescription
                Haptics.warning()
            }
            isApproving = false
        }
    }
}
