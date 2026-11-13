//
//  CopilotView.swift
//  Stock Tracker
//
//  The investing copilot's screen. Answers arrive as plain text plus cards built
//  from the app's own data: facts with their sources, pending trades, an agent's
//  run with the rules it checked, a drafted agent, a backtest, or a proposed
//  limit change with Confirm and Cancel.
//
//  The copilot can prepare a change; only the person can make it. See
//  CopilotEngine for the tools and their boundaries.
//

import SwiftUI
import TradingCore

struct CopilotView: View {
    var initialPrompt: String? = nil

    @EnvironmentObject private var trading: TradingStore
    @EnvironmentObject private var marketData: MarketData
    @EnvironmentObject private var subscriptionManager: SubscriptionManager
    @EnvironmentObject private var insightService: AIInsightService
    @EnvironmentObject private var cloudAuth: SupabaseAuthManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        CopilotScreen(engine: CopilotEngine(trading: trading, marketData: marketData),
                      initialPrompt: initialPrompt,
                      canUseModel: { insightService.canQuery(tier: subscriptionManager.currentTier) },
                      didUseModel: { insightService.incrementQueryCount() },
                      onClose: { dismiss() })
        .id(cloudAuth.userId)
    }
}

private struct CopilotScreen: View {
    @StateObject private var engine: CopilotEngine
    let initialPrompt: String?
    let canUseModel: () -> Bool
    let didUseModel: () -> Void
    let onClose: () -> Void

    @EnvironmentObject private var trading: TradingStore
    @EnvironmentObject private var cloudAuth: SupabaseAuthManager
    @EnvironmentObject private var privateMarkets: PrivateMarketsStore
    @Environment(\.theme) private var theme
    @State private var input = ""
    @State private var draft: DraftSheet?
    @State private var report: BacktestBox?
    @State private var openedProposal: TradingRouter.Ref?
    @State private var openedOrder: TradingRouter.Ref?
    @State private var openedAgent: TradingRouter.Ref?
    @State private var showPauseAll = false
    @FocusState private var focused: Bool

    struct DraftSheet: Identifiable {
        let id = UUID()
        let parsed: ParsedAgentRequest
    }

    init(engine: @autoclosure @escaping () -> CopilotEngine, initialPrompt: String?,
         canUseModel: @escaping () -> Bool, didUseModel: @escaping () -> Void, onClose: @escaping () -> Void) {
        _engine = StateObject(wrappedValue: engine())
        self.initialPrompt = initialPrompt
        self.canUseModel = canUseModel
        self.didUseModel = didUseModel
        self.onClose = onClose
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.l) {
                        if engine.messages.isEmpty { intro }
                        ForEach(engine.messages) { message in
                            messageView(message).id(message.id)
                        }
                        if engine.isWorking {
                            TextSkeleton()
                                .padding(DS.Space.m)
                                .background(theme.intelligenceTint.opacity(0.08), in: RoundedRectangle(cornerRadius: DS.Radius.chip))
                                .loadingSkeleton("Copilot is preparing an answer")
                                .id("working")
                        }
                    }
                    .padding(.horizontal, DS.Space.gutter)
                    .padding(.vertical, DS.Space.l)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: engine.isWorking) { _, working in
                    if working { proxy.scrollTo("working", anchor: .bottom) }
                }
                .onChange(of: engine.messages.count) { _, _ in
                    if let last = engine.messages.last { dsAnimate { proxy.scrollTo(last.id, anchor: .top) } }
                }
            }
            .dsScreenBackground()
            .safeAreaInset(edge: .bottom) { inputBar }
            .navigationTitle("Copilot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close", action: onClose).accessibilityIdentifier("copilot.close") }
            }
        }
        .onAppear {
            engine.canUseModel = canUseModel
            engine.didUseModel = didUseModel
        }
        .task {
            if let initialPrompt, engine.messages.isEmpty {
                await engine.send(initialPrompt)
            }
        }
        .sheet(item: $draft) { sheet in
            NavigationStack {
                AgentDraftEditor(draft: sheet.parsed.draft, parsed: sheet.parsed) { draft = nil }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { draft = nil } } }
            }
        }
        .sheet(item: $report) { box in NavigationStack { BacktestReportView(result: box.result, title: box.result.strategyTitle) } }
        .sheet(item: $openedProposal) { ProposalReviewSheet(proposalID: $0.id) }
        .sheet(item: $openedOrder) { ref in NavigationStack { OrderDetailView(orderID: ref.id) } }
        .sheet(item: $openedAgent) { ref in NavigationStack { AgentDetailView(agentID: ref.id) } }
        .sheet(isPresented: $showPauseAll) { PauseAllSheet() }
        .accessibilityIdentifier("copilot.screen")
    }

    // MARK: Intro

    private var intro: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            Label {
                Text("Ask about your portfolio, orders and agents.")
                    .font(DS.display(.title, weight: .semibold))
            } icon: {
                Image(systemName: "sparkles").foregroundStyle(theme.intelligenceTint)
            }
                .fixedSize(horizontal: false, vertical: true)
            Text("Answers come from your own data in this app. I can draft an agent or a limit change for you to confirm, but I can't place, change or cancel an order.")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: DS.Space.s) {
                ForEach(CopilotEngine.suggestions, id: \.self) { suggestion in
                    Button {
                        send(suggestion)
                    } label: {
                        HStack {
                            Text(suggestion).font(.subheadline).multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(theme.primaryText)
                        .padding(DS.Space.m)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous).strokeBorder(theme.cardBorder, lineWidth: 1))
                    }
                    .accessibilityIdentifier("copilot.suggestion.\(suggestion.prefix(18))")
                }
            }
            Text("General information only, not financial advice.")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
        }
    }

    // MARK: Messages

    @ViewBuilder
    private func messageView(_ message: CopilotMessage) -> some View {
        if message.isUser {
            Text(message.text)
                .font(.body)
                .padding(.horizontal, DS.Space.l)
                .padding(.vertical, DS.Space.m)
                .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(theme.subtleFill))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel("You asked: \(message.text)")
                .accessibilityIdentifier("copilot.question")
        } else {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Text(message.text)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("copilot.reply")
                if message.aiGenerated {
                    Label("Written by an AI model. It can be wrong; check anything that matters.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .accessibilityIdentifier("copilot.aiGenerated")
                }
                ForEach(message.cards) { card in cardView(card) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func cardView(_ card: CopilotCard) -> some View {
        switch card {
        case .facts(_, let title, let facts, let footnote):
            TradingSection(title: LocalizedStringKey(title)) {
                ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                    TradingRow(label: LocalizedStringKey(fact.label), value: fact.value)
                }
                Text(footnote).font(.caption).foregroundStyle(theme.secondaryText).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("copilot.card.facts")

        case .orders(_, let proposalIDs, let orderIDs):
            TradingSection(title: "Pending") {
                ForEach(proposalIDs, id: \.self) { id in
                    if let proposal = trading.proposal(id) {
                        Button { openedProposal = TradingRouter.Ref(id: id) } label: { ProposalRowView(proposal: proposal) }
                            .buttonStyle(PressableButtonStyle())
                    }
                }
                ForEach(orderIDs, id: \.self) { id in
                    if let order = trading.order(id) {
                        Button { openedOrder = TradingRouter.Ref(id: id) } label: { OrderRowView(order: order) }
                            .buttonStyle(PressableButtonStyle())
                    }
                }
            }
            .accessibilityIdentifier("copilot.card.orders")

        case .run(_, let agentID, let runID):
            if let run = trading.runs(for: agentID).first(where: { $0.id == runID }) {
                TradingSection(title: "What it checked", trailing: TradingFormat.time(run.startedAt)) {
                    ForEach(run.steps.prefix(12)) { step in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(step.title).font(.footnote.weight(.semibold))
                            if !step.detail.isEmpty {
                                Text(step.detail).font(.footnote).foregroundStyle(theme.secondaryText).fixedSize(horizontal: false, vertical: true)
                            }
                            if !step.evidence.isEmpty { EvidenceList(evidence: step.evidence) }
                        }
                    }
                    Button("Open the agent") { openedAgent = TradingRouter.Ref(id: agentID) }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DS.accent)
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("copilot.card.run")
            }

        case .draft(_, let parsed):
            TradingSection(title: LocalizedStringKey(parsed.draft.name)) {
                ForEach(parsed.understood, id: \.self) { Label($0, systemImage: "checkmark").font(.footnote) }
                ForEach(parsed.assumptions, id: \.self) { line in
                    Label(line, systemImage: "info.circle").font(.footnote).foregroundStyle(theme.secondaryText)
                }
                Button("Review and start") { draft = DraftSheet(parsed: parsed) }
                    .buttonStyle(PrimaryPillButtonStyle())
                    .accessibilityIdentifier("copilot.draft.review")
            }
            .accessibilityIdentifier("copilot.card.draft")

        case .limitChange(let id, let agentID, let lines, let policy, let loosens):
            TradingSection(title: "Proposed change") {
                ForEach(lines, id: \.self) { Text($0).font(.subheadline.monospacedDigit()) }
                if loosens {
                    Label("This loosens a limit.", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(theme.warningColor)
                }
                if let resolution = engine.resolvedCards[id] {
                    StatusLabel(systemImage: resolution == "Applied" ? "checkmark.circle.fill" : "slash.circle", text: resolution)
                        .accessibilityIdentifier("copilot.limit.\(resolution)")
                } else {
                    HStack(spacing: DS.Space.m) {
                        Button("Cancel") { engine.dismiss(card: id) }
                            .buttonStyle(SecondaryPillButtonStyle())
                            .accessibilityIdentifier("copilot.limit.cancel")
                        Button("Confirm") {
                            Haptics.tap()
                            Task { await engine.confirmLimitChange(card: id, agentID: agentID, policy: policy) }
                        }
                        .buttonStyle(PrimaryPillButtonStyle())
                        .accessibilityIdentifier("copilot.limit.confirm")
                    }
                }
            }
            .accessibilityIdentifier("copilot.card.limitChange")

        case .backtest(_, let box):
            TradingSection(title: "Simulated backtest") {
                TradingRow(label: "Return", value: TradingFormat.percent(box.result.overall.totalReturnPct))
                if let benchmark = box.result.benchmarkReturnPct {
                    TradingRow(label: LocalizedStringKey(box.result.benchmarkName ?? "Benchmark"), value: TradingFormat.percent(benchmark))
                }
                TradingRow(label: "Worst fall from a peak", value: String(format: "−%.1f%%", box.result.overall.maxDrawdownPct))
                TradingRow(label: "Completed trades", value: "\(box.result.overall.closedTrades)")
                Button("Open the full report") { report = box }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.accent)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("copilot.backtest.open")
            }
            .accessibilityIdentifier("copilot.card.backtest")

        case .agentChoice(let id, let request, let agentIDs):
            if engine.resolvedCards[id] == nil {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    ForEach(agentIDs, id: \.self) { agentID in
                        if let agent = trading.agent(agentID) {
                            Button(agent.name) { Task { await engine.choose(agentID: agentID, for: request, card: id) } }
                                .buttonStyle(SecondaryPillButtonStyle())
                                .accessibilityIdentifier("copilot.choose.\(agent.name)")
                        }
                    }
                }
            }

        case .unifiedAllocation:
            VStack(alignment: .leading) {
                UnifiedPrivateAllocation()
                if privateMarkets.loadingProviderHoldings { ProgressView("Checking provider records") }
                if let error = privateMarkets.providerError { Text(error).font(.footnote).foregroundStyle(.secondary) }
            }
            .privatePanel()
            .task(id: cloudAuth.userId) {
                if let owner = cloudAuth.userId { await privateMarkets.refreshProviderHoldings(for: owner) }
            }

        case .pauseAll:
            Button(trading.isKillSwitchOn ? "Review pause-all" : "Open Pause all") { showPauseAll = true }
                .buttonStyle(SecondaryPillButtonStyle())
                .accessibilityIdentifier("copilot.pauseAll")
        }
    }

    // MARK: Input

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: DS.Space.s) {
            TextField("Ask a question", text: $input, axis: .vertical)
                .lineLimit(1...4)
                .focused($focused)
                .padding(.horizontal, DS.Space.l)
                .padding(.vertical, DS.Space.m)
                .background(Capsule().fill(theme.subtleFill))
                .accessibilityIdentifier("copilot.input")
            Button {
                send(input)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
                    .foregroundStyle(theme.invertedPrimaryText)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(theme.primaryText))
            }
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || engine.isWorking)
            .opacity(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.35 : 1)
            .accessibilityLabel("Send")
            .accessibilityIdentifier("copilot.send")
        }
        .padding(.horizontal, DS.Space.gutter)
        .padding(.vertical, DS.Space.s)
        .background(.bar)
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        input = ""
        focused = false
        Task { await engine.send(trimmed) }
    }
}
