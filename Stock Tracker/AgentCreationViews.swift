//
//  AgentCreationViews.swift
//  Stock Tracker
//
//  Creating an agent: describe it in a sentence or pick a template, then review
//  and edit an ordinary summary of what it will do before it starts. Also the
//  limits editor and the backtest report.
//
//  The typed sentence is read by fixed rules (TradingCore's StrategyParser), so
//  it works offline and always gives the same draft for the same words. What it
//  understood and what it assumed are both shown. Nothing starts until the
//  draft passes validation and the person taps Start.
//

import SwiftUI
import TradingCore

// MARK: - Create

struct CreateAgentFlow: View {
    var prefill: Instrument? = nil
    var prompt: String? = nil

    @EnvironmentObject private var trading: TradingStore
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var parsed: ParsedAgentRequest?
    @State private var draft: DraftBox?
    @FocusState private var promptFocused: Bool

    private let examples = [
        "Watch technology stocks and trade moving-average crossovers with a $5,000 paper portfolio, 10% per position",
        "Buy $100 of SPY every week with a $5,000 budget",
        "Monitor BTC and ETH and ask me before each trade, with an 8% stop loss"
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        Text("What should this agent do?")
                            .font(DS.display(.title))
                            .accessibilityAddTraits(.isHeader)
                        TextField("Describe the assets, the strategy, the budget and any limits", text: $text, axis: .vertical)
                            .lineLimit(3...6)
                            .focused($promptFocused)
                            .padding(DS.Space.m)
                            .background(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous).fill(theme.subtleFill))
                            .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous).strokeBorder(theme.cardBorder, lineWidth: 0.5))
                            .accessibilityIdentifier("agent.new.prompt")
                        Button("Draft the agent") { draftFromText() }
                            .buttonStyle(PrimaryPillButtonStyle())
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).count < 4)
                            .accessibilityIdentifier("agent.new.draft")
                        Text("You'll see exactly what it understood and can change anything before it starts.")
                            .font(.footnote)
                            .foregroundStyle(theme.secondaryText)
                    }

                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        Text("Try one of these").font(.subheadline.weight(.semibold))
                        ForEach(examples, id: \.self) { example in
                            Button {
                                Haptics.select()
                                text = example
                            } label: {
                                Text(example)
                                    .font(.footnote)
                                    .multilineTextAlignment(.leading)
                                    .foregroundStyle(theme.primaryText)
                                    .padding(DS.Space.m)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous).strokeBorder(theme.cardBorder, lineWidth: 1))
                            }
                            .accessibilityHint("Fills the box. Nothing is created yet.")
                        }
                    }

                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        Text("Or start from a template").font(.subheadline.weight(.semibold))
                        ForEach(AgentTemplates.all) { template in
                            Button { start(from: template) } label: { templateRow(template) }
                                .buttonStyle(PressableButtonStyle())
                                .accessibilityIdentifier("agent.template.\(template.id)")
                        }
                    }

                    PracticeNote(text: "Agents trade practice money only. What they do is a simulation, not financial advice.")
                }
                .padding(.horizontal, DS.Space.gutter)
                .padding(.vertical, DS.Space.l)
            }
            .scrollDismissesKeyboard(.interactively)
            .dsScreenBackground()
            .navigationTitle("New agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("agent.new.cancel") } }
            .navigationDestination(item: $draft) { box in
                AgentDraftEditor(draft: box.draft, parsed: box.parsed) { dismiss() }
            }
        }
        .onAppear {
            if text.isEmpty, let prompt { text = prompt }
        }
        .accessibilityIdentifier("agent.new.screen")
    }

    private func templateRow(_ template: AgentTemplate) -> some View {
        HStack(spacing: DS.Space.m) {
            AgentAvatar(seed: template.id, systemImage: template.symbolName, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(template.name).font(.subheadline.weight(.semibold)).foregroundStyle(theme.primaryText)
                Text(template.tagline).font(.footnote).foregroundStyle(theme.secondaryText)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard(padding: DS.Space.m)
        .contentShape(Rectangle())
    }

    private func draftFromText() {
        promptFocused = false
        var result = StrategyParser.parse(InputSanitizer.sanitizeForAPI(text))
        // Opened from an asset's page: that asset is what the agent is for.
        if let prefill, !result.draft.spec.followsLedgerPositions, !result.draft.spec.universe.contains(prefill) {
            if result.understood.contains(where: { $0.hasPrefix("Assets:") }) == false {
                result.draft.spec.universe = [prefill]
                if result.draft.spec.kind == .rebalance { result.draft.spec = AgentTemplates.etfRebalancing([prefill]) }
                result.assumptions.removeAll { $0.hasPrefix("No assets were named") }
                result.understood.append("Assets: \(prefill.symbol)")
            }
        }
        parsed = result
        draft = DraftBox(draft: result.draft, parsed: result)
    }

    private func start(from template: AgentTemplate) {
        var universe = template.defaultUniverse
        if let prefill, !template.needsExistingPortfolio { universe = [prefill] }
        parsed = nil
        draft = DraftBox(draft: template.draft(universe: universe), parsed: nil)
    }
}

/// A draft on its way to the review screen.
struct DraftBox: Identifiable, Hashable {
    let id = UUID()
    let draft: AgentDraft
    /// What the typed sentence was understood as (nil for a template). Carried with the
    /// draft: the destination is built from this value, not from the parent's state.
    let parsed: ParsedAgentRequest?

    static func == (lhs: DraftBox, rhs: DraftBox) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A finished backtest on its way to the report screen.
struct BacktestBox: Identifiable {
    let id = UUID()
    let result: BacktestResult
}

// MARK: - Review and edit a draft

struct AgentDraftEditor: View {
    @State var draft: AgentDraft
    var parsed: ParsedAgentRequest?
    var onCreated: () -> Void

    @EnvironmentObject private var trading: TradingStore
    @Environment(\.theme) private var theme

    @State private var budgetText: String
    @State private var showPicker = false
    @State private var lockedMode: AgentMode?
    @State private var problem: String?
    @State private var isBacktesting = false
    @State private var backtest: BacktestBox?
    @State private var isCreating = false

    init(draft: AgentDraft, parsed: ParsedAgentRequest?, onCreated: @escaping () -> Void) {
        _draft = State(initialValue: draft)
        self.parsed = parsed
        self.onCreated = onCreated
        _budgetText = State(initialValue: String(format: "%.0f", draft.budget))
    }

    private var needsPortfolio: Bool { draft.spec.followsLedgerPositions }
    private var currency: String { draft.spec.universe.first?.currency ?? "USD" }

    /// Everything stopping this draft from starting, in plain words.
    private var problems: [String] {
        var out = StrategyValidator.validate(draft.spec).filter { $0.severity == .error }.map(\.message)
        out += resolved.resolvedPolicy.issues
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty { out.append("Give the agent a name.") }
        if draft.mode == .paper, !needsPortfolio, !TradingEngine.budgetRange.contains(resolved.budget) {
            out.append("The budget must be between 100 and 10,000,000.")
        }
        if draft.mode == .paper, needsPortfolio, draft.attachToLedgerID == nil {
            out.append(trading.practicePortfolios.isEmpty ? "Set up a practice portfolio first, then add this agent to guard it." : "Choose the portfolio this agent should guard.")
        }
        if draft.mode == .paper, draft.spec.kind == .research { out.append("A research strategy can't trade. Choose Research only.") }
        return out
    }

    /// The draft with the typed budget applied and the limits rebuilt around it.
    private var resolved: AgentDraft {
        var copy = draft
        let budget = Double(budgetText.replacingOccurrences(of: ",", with: "")) ?? 0
        copy.budget = budget
        if var policy = copy.riskPolicy {
            // Keep the limits the person set as percentages; re-derive the money limits from the budget.
            let standard = RiskPolicy.standard(budget: budget, maxPositionPct: copy.maxPositionPct, crypto: copy.isCryptoOnly)
            policy.maxOrderNotional = standard.maxOrderNotional
            policy.maxDailyNotional = standard.maxDailyNotional
            policy.maxPositionPct = copy.maxPositionPct
            copy.riskPolicy = policy
        }
        return copy
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                if let parsed { understoodCard(parsed) }

                TradingSection(title: "Name") {
                    TextField("Agent name", text: $draft.name)
                        .font(.body.weight(.semibold))
                        .accessibilityIdentifier("agent.draft.name")
                }

                TradingSection(title: "What it does") {
                    Text(draft.spec.summary).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    ForEach(draft.spec.ruleLines, id: \.self) { line in
                        Label {
                            Text(line).font(.footnote).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "arrow.turn.down.right").font(.caption)
                        }
                        .foregroundStyle(theme.secondaryText)
                    }
                    Text("Decisions use completed daily bars only.")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }

                if !needsPortfolio { assetsCard } else { guardCard }

                modeCard

                if draft.mode == .paper { moneyCard }

                if draft.spec.kind == .rules || draft.spec.kind == .dca { protectionsCard }

                TradingSection(title: "How often it checks") {
                    Picker("Schedule", selection: $draft.schedule.intervalMinutes) {
                        Text("Every 15 minutes").tag(15)
                        Text("Every hour").tag(60)
                        Text("Every 4 hours").tag(240)
                        Text("Once a day").tag(1_440)
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("agent.draft.schedule")
                    Text("It checks while the app is open, and when iOS allows in the background.")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }

                if !problems.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        ForEach(problems, id: \.self) { item in
                            Label(item, systemImage: "exclamationmark.circle")
                                .font(.footnote)
                                .foregroundStyle(theme.negativeColor)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityIdentifier("agent.draft.problems")
                }

                if draft.spec.kind != .research, !needsPortfolio {
                    Button {
                        runBacktest()
                    } label: {
                        HStack {
                            if isBacktesting { ProgressView().controlSize(.small) }
                            Text(isBacktesting ? "Testing on two years of real prices…" : "Backtest on the last two years")
                        }
                    }
                    .buttonStyle(SecondaryPillButtonStyle())
                    .disabled(isBacktesting || !problems.isEmpty)
                    .accessibilityIdentifier("agent.draft.backtest")
                }

                if let problem {
                    Text(problem).font(.footnote).foregroundStyle(theme.negativeColor).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("agent.draft.error")
                }

                PracticeNote(text: "Practice money only. A backtest or a paper result is not a prediction, and nothing here is financial advice.")
            }
            .padding(.horizontal, DS.Space.gutter)
            .padding(.top, DS.Space.m)
            .padding(.bottom, 120)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("agent.draft.screen")
        }
        .scrollDismissesKeyboard(.interactively)
        .dsScreenBackground()
        .navigationTitle("Review agent")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { if draft.mode == .paper { PracticeChip() } } }
        .safeAreaInset(edge: .bottom) {
            Button(isCreating ? "Starting…" : (draft.mode == .paper ? "Start in practice" : "Start agent")) { create() }
                .buttonStyle(PrimaryPillButtonStyle())
                .disabled(!problems.isEmpty || isCreating)
                .accessibilityIdentifier("agent.draft.start")
                .padding(.horizontal, DS.Space.gutter)
                .padding(.vertical, DS.Space.m)
        }
        .sheet(isPresented: $showPicker) {
            InstrumentPickerView(title: "Add an asset", currency: draft.spec.universe.isEmpty ? nil : currency,
                                 excluding: Set(draft.spec.universe.map(\.id))) { instrument in
                draft.spec.universe.append(instrument)
                rebuildTargetsIfNeeded()
                showPicker = false
            }
        }
        .sheet(item: $backtest) { box in
            NavigationStack { BacktestReportView(result: box.result, title: draft.name) }
        }
        .alert("Live trading isn't available", isPresented: Binding(get: { lockedMode != nil }, set: { if !$0 { lockedMode = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(trading.liveBlockers(for: lockedMode).joined(separator: " ") + " Agents can research, signal and trade practice money.")
        }
    }

    // MARK: Cards

    private func understoodCard(_ parsed: ParsedAgentRequest) -> some View {
        TradingSection(title: "What I understood") {
            ForEach(parsed.understood, id: \.self) { line in
                Label(line, systemImage: "checkmark").font(.subheadline)
            }
            ForEach(parsed.assumptions, id: \.self) { line in
                Label {
                    Text(line).font(.footnote).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle").font(.footnote)
                }
                .foregroundStyle(theme.secondaryText)
            }
            if !parsed.unrecognisedSymbols.isEmpty {
                Label("I don't know \(parsed.unrecognisedSymbols.joined(separator: ", ")). Add it under Assets if it's a real ticker.",
                      systemImage: "questionmark.circle")
                    .font(.footnote)
                    .foregroundStyle(theme.warningColor)
            }
        }
        .accessibilityIdentifier("agent.draft.understood")
    }

    private var assetsCard: some View {
        TradingSection(title: "Assets", trailing: "\(draft.spec.universe.count)") {
            FlowLayout(spacing: DS.Space.s) {
                ForEach(draft.spec.universe) { instrument in
                    HStack(spacing: 4) {
                        Text(instrument.symbol).font(.footnote.weight(.semibold))
                        Button {
                            draft.spec.universe.removeAll { $0.id == instrument.id }
                            rebuildTargetsIfNeeded()
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                .frame(width: 22, height: 22)
                        }
                        .accessibilityLabel("Remove \(instrument.symbol)")
                    }
                    .padding(.leading, DS.Space.m)
                    .padding(.trailing, 4)
                    .frame(minHeight: 32)
                    .background(Capsule().fill(theme.subtleFill))
                    .overlay(Capsule().strokeBorder(theme.cardBorder, lineWidth: 0.5))
                }
                Button {
                    showPicker = true
                } label: {
                    Label("Add", systemImage: "plus").font(.footnote.weight(.semibold))
                        .padding(.horizontal, DS.Space.m)
                        .frame(minHeight: 32)
                        .overlay(Capsule().strokeBorder(DS.accent, lineWidth: 1))
                }
                .foregroundStyle(DS.accent)
                .accessibilityIdentifier("agent.draft.addAsset")
            }
            if draft.spec.kind == .rebalance, let targets = draft.spec.rebalance?.targets {
                Text(targets.sorted { $0.value > $1.value }
                    .map { "\($0.key.split(separator: ":").last.map(String.init) ?? $0.key) \(Int($0.value.rounded()))%" }
                    .joined(separator: " · "))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    private var guardCard: some View {
        TradingSection(title: "Portfolio to guard") {
            if trading.practicePortfolios.isEmpty {
                Text("This agent protects positions in a practice portfolio. Set one up from the Portfolio tab first.")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
            } else {
                Picker("Portfolio", selection: $draft.attachToLedgerID) {
                    Text("Choose").tag(UUID?.none)
                    ForEach(trading.practicePortfolios) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("agent.draft.guardPortfolio")
            }
        }
    }

    private var modeCard: some View {
        TradingSection(title: "What it's allowed to do") {
            ForEach(AgentMode.allCases, id: \.self) { mode in
                Button {
                    if mode.isLive {
                        lockedMode = mode
                    } else {
                        Haptics.select()
                        draft.mode = mode
                    }
                } label: {
                    HStack(alignment: .top, spacing: DS.Space.m) {
                        Image(systemName: mode.isLive ? "lock" : (draft.mode == mode ? "largecircle.fill.circle" : "circle"))
                            .foregroundStyle(mode.isLive ? theme.secondaryText : (draft.mode == mode ? DS.accent : theme.secondaryText))
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.displayName).font(.subheadline.weight(.semibold))
                                .foregroundStyle(mode.isLive ? theme.secondaryText : theme.primaryText)
                            Text(mode.isLive ? "Not available: real-money trading is switched off." : mode.summary)
                                .font(.footnote)
                                .foregroundStyle(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityAddTraits(draft.mode == mode ? .isSelected : [])
                .accessibilityIdentifier("agent.draft.mode.\(mode.rawValue)")
            }
            if draft.mode == .paper {
                Divider()
                Toggle(isOn: $draft.reviewEachPaperTrade) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ask me before each trade").font(.subheadline.weight(.semibold))
                        Text("Each practice trade waits for your approval instead of executing straight away.")
                            .font(.footnote)
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                .accessibilityIdentifier("agent.draft.review")
            }
        }
    }

    private var moneyCard: some View {
        TradingSection(title: "Money and limits") {
            if !needsPortfolio {
                HStack {
                    Text("Practice budget").font(.subheadline).foregroundStyle(theme.secondaryText)
                    Spacer()
                    Text(TradingFormat.symbol(currency).trimmingCharacters(in: .whitespaces)).foregroundStyle(theme.secondaryText)
                    TextField("10000", text: $budgetText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .font(.body.weight(.semibold).monospacedDigit())
                        .frame(maxWidth: 120)
                        .accessibilityIdentifier("agent.draft.budget")
                }
            }
            stepper("Largest position", value: $draft.maxPositionPct, range: 1...100, step: 1, suffix: "% of the portfolio", id: "position")
            let policy = resolved.resolvedPolicy
            TradingRow(label: "Largest single order", value: TradingFormat.money(policy.maxOrderNotional, currency))
            TradingRow(label: "Most traded in a day", value: TradingFormat.money(policy.maxDailyNotional, currency))
            stepper("Stop buying after a daily loss of", value: policyBinding(\.maxDailyLossPct), range: 0.5...50, step: 0.5, suffix: "%", id: "dailyLoss")
            stepper("Pause at a drawdown of", value: policyBinding(\.maxDrawdownPct), range: 1...90, step: 1, suffix: "%", id: "drawdown")
            Text("These limits are checked on every order by fixed rules. An agent can't change or skip them.")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var protectionsCard: some View {
        TradingSection(title: draft.spec.kind == .dca ? "Buying" : "Protective exits") {
            if draft.spec.kind == .dca {
                stepper("Buy each time", value: Binding(get: { draft.spec.dca?.amountPerBuy ?? 100 },
                                                        set: { draft.spec.dca?.amountPerBuy = $0; draft.spec.sizing.value = $0 }),
                        range: 10...10_000_000, step: currency == "JPY" || currency == "KRW" ? 1_000 : 10,
                        prefix: TradingFormat.symbol(currency), suffix: "", id: "dcaAmount")
                stepper("Every", value: Binding(get: { Double(draft.spec.dca?.intervalBars ?? 5) },
                                                 set: { draft.spec.dca?.intervalBars = Int($0) }),
                        range: 1...60, step: 1, suffix: " trading days", id: "dcaInterval")
            } else {
                optionalStepper("Stop loss", value: $draft.spec.protections.stopLossPct, fallback: 8, range: 1...50, id: "stopLoss")
                optionalStepper("Trailing stop", value: $draft.spec.protections.trailingStopPct, fallback: 10, range: 1...50, id: "trailing")
                optionalStepper("Take profit", value: $draft.spec.protections.takeProfitPct, fallback: 20, range: 1...200, id: "takeProfit")
                Text("Stops are checked when each day's bar closes, so a sudden drop inside the day is acted on at the close.")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Controls

    private func policyBinding(_ keyPath: WritableKeyPath<RiskPolicy, Double>) -> Binding<Double> {
        Binding(
            get: { resolved.resolvedPolicy[keyPath: keyPath] },
            set: { value in
                var policy = resolved.resolvedPolicy
                policy[keyPath: keyPath] = value
                draft.riskPolicy = policy
            })
    }

    private func stepper(_ title: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                         prefix: String = "", suffix: String, id: String) -> some View {
        Stepper(value: value, in: range, step: step) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline).foregroundStyle(theme.secondaryText)
                Text("\(prefix)\(Operand.trim(value.wrappedValue))\(suffix)").font(.body.weight(.semibold).monospacedDigit())
            }
        }
        .accessibilityIdentifier("agent.draft.\(id)")
    }

    private func optionalStepper(_ title: String, value: Binding<Double?>, fallback: Double, range: ClosedRange<Double>, id: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Toggle(title, isOn: Binding(get: { value.wrappedValue != nil }, set: { value.wrappedValue = $0 ? fallback : nil }))
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("agent.draft.\(id).toggle")
            if value.wrappedValue != nil {
                Stepper(value: Binding(get: { value.wrappedValue ?? fallback }, set: { value.wrappedValue = $0 }), in: range, step: 1) {
                    Text("\(Operand.trim(value.wrappedValue ?? fallback))%").font(.body.weight(.semibold).monospacedDigit())
                }
                .accessibilityIdentifier("agent.draft.\(id)")
            }
        }
    }

    // MARK: Actions

    private func rebuildTargetsIfNeeded() {
        guard draft.spec.kind == .rebalance else { return }
        draft.spec.rebalance = AgentTemplates.etfRebalancing(draft.spec.universe).rebalance
    }

    private func create() {
        guard !isCreating else { return }
        isCreating = true
        problem = nil
        let draft = resolved
        Task {
            do {
                try await trading.createAgent(draft)
                Haptics.success()
                onCreated()
            } catch {
                problem = error.localizedDescription
                Haptics.warning()
            }
            isCreating = false
        }
    }

    private func runBacktest() {
        problem = nil
        isBacktesting = true
        let snapshot = resolved
        Task {
            do {
                backtest = BacktestBox(result: try await trading.backtest(snapshot, years: 2))
            } catch {
                problem = "The backtest couldn't run: \(error.localizedDescription)"
            }
            isBacktesting = false
        }
    }
}

// MARK: - Limits editor (existing agent)

struct AgentLimitsEditor: View {
    let agentID: UUID

    @EnvironmentObject private var trading: TradingStore
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var policy: RiskPolicy?
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                if let agent = trading.agent(agentID), let binding = Binding($policy) {
                    let currency = trading.ledger(agent.ledgerID)?.currency ?? "USD"
                    Section {
                        moneyRow("Largest single order", value: binding.maxOrderNotional, step: 50, currency: currency)
                        percentRow("Largest position", value: binding.maxPositionPct, range: 1...100)
                        moneyRow("Most traded in a day", value: binding.maxDailyNotional, step: 100, currency: currency)
                        Stepper("Open positions: \(binding.wrappedValue.maxOpenPositions)", value: binding.maxOpenPositions, in: 1...50)
                    } header: { Text("Size") }
                    Section {
                        percentRow("Stop buying after a daily loss of", value: binding.maxDailyLossPct, range: 0.5...50, step: 0.5)
                        percentRow("Pause at a drawdown of", value: binding.maxDrawdownPct, range: 1...90)
                    } header: { Text("Loss limits") } footer: {
                        Text("Exits are never blocked by these limits: an agent can always sell.")
                    }
                    Section {
                        Stepper("Widest spread: \(Int(binding.wrappedValue.maxSpreadBps)) bps", value: binding.maxSpreadBps, in: 5...500, step: 5)
                        Stepper("Wait after a trade: \(Int(binding.wrappedValue.cooldownSeconds / 60)) min",
                                value: binding.cooldownSeconds, in: 0...86_400, step: 300)
                        Toggle("Queue orders while the market is closed", isOn: binding.allowQueueOutsideHours)
                    } header: { Text("Market conditions") }
                    if let problem {
                        Section { Text(problem).foregroundStyle(theme.negativeColor).font(.footnote) }
                    }
                }
            }
            .navigationTitle("Risk limits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let policy else { return }
                        Task {
                            do {
                                try await trading.updateRiskPolicy(agentID: agentID, policy: policy)
                                dismiss()
                            } catch {
                                problem = error.localizedDescription
                            }
                        }
                    }
                    .accessibilityIdentifier("agent.limits.save")
                }
            }
        }
        .onAppear { if policy == nil { policy = trading.agent(agentID)?.riskPolicy } }
        .accessibilityIdentifier("agent.limits.screen")
    }

    private func moneyRow(_ title: String, value: Binding<Double>, step: Double, currency: String) -> some View {
        Stepper(value: value, in: 1...10_000_000, step: step) {
            VStack(alignment: .leading) {
                Text(title).font(.subheadline)
                Text(TradingFormat.money(value.wrappedValue, currency)).font(.body.weight(.semibold).monospacedDigit())
            }
        }
    }

    private func percentRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double = 1) -> some View {
        Stepper(value: value, in: range, step: step) {
            VStack(alignment: .leading) {
                Text(title).font(.subheadline)
                Text("\(Operand.trim(value.wrappedValue))%").font(.body.weight(.semibold).monospacedDigit())
            }
        }
    }
}

// MARK: - Backtest report

/// What a strategy would have done over past prices. Laid out so the caveats can't be
/// missed: "Simulated" is in the title, the assumptions are always open, and the benchmark
/// sits beside every headline number.
struct BacktestReportView: View {
    let result: BacktestResult
    var title: String

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    private var currency: String { result.trades.first?.instrument.currency ?? "USD" }

    var body: some View {
        let m = result.overall
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Simulated backtest")
                        .font(.caption.weight(.bold))
                        .textCase(.uppercase)
                        .foregroundStyle(theme.secondaryText)
                    Text(title).font(DS.display(.title))
                    Text("\(m.start.formatted(date: .abbreviated, time: .omitted)) to \(m.end.formatted(date: .abbreviated, time: .omitted)) · \(result.strategyTitle)")
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryText)
                    Text("Prices: \(result.dataSources.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }

                if !result.usedRealMarketData {
                    Label("This run used test data, not real market prices.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(theme.warningColor)
                        .accessibilityIdentifier("backtest.testData")
                }

                HStack(alignment: .top, spacing: DS.Space.l) {
                    headline("Strategy", value: m.totalReturnPct)
                    if let benchmark = result.benchmarkReturnPct {
                        headline(result.benchmarkName ?? "Benchmark", value: benchmark)
                    }
                }
                .accessibilityIdentifier("backtest.headline")

                VStack(alignment: .leading, spacing: DS.Space.s) {
                    EquityCurveChart(points: result.equityCurve, benchmark: result.benchmarkCurve,
                                     benchmarkName: result.benchmarkName, currency: currency, height: 200)
                    if !result.benchmarkCurve.isEmpty {
                        HStack(spacing: DS.Space.l) {
                            legend("Strategy", dashed: false)
                            legend(result.benchmarkName ?? "Benchmark", dashed: true)
                        }
                    }
                    Text("Simulated on past prices. It does not predict future returns.")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
                .dsCard()

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Space.m), count: typeSize.isAccessibilitySize ? 1 : 2),
                          spacing: DS.Space.m) {
                    metric("Total return", TradingFormat.percent(m.totalReturnPct))
                    metric("Worst fall from a peak", String(format: "−%.1f%%", m.maxDrawdownPct))
                    metric("Completed trades", "\(m.closedTrades)")
                    metric("Trades that made money", m.winRatePct.map { String(format: "%.0f%%", $0) } ?? "—")
                    metric("Yearly rate", m.cagrPct.map { TradingFormat.percent($0) } ?? "Too short to say")
                    metric("Return per unit of risk (Sharpe)", m.sharpe.map { String(format: "%.2f", $0) } ?? "—")
                    metric("Time in the market", String(format: "%.0f%%", m.exposurePct))
                    metric("Fees paid", TradingFormat.money(m.feesPaid, currency))
                }
                .accessibilityIdentifier("backtest.metrics")

                if let first = result.inSample, let last = result.outOfSample {
                    TradingSection(title: "Does it hold up over time?") {
                        Text("The rules weren't tuned on any of this data. Splitting the period shows whether the result came from one stretch of time.")
                            .font(.footnote)
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        TradingRow(label: "First 70% of the period", value: "\(TradingFormat.percent(first.totalReturnPct)) · fall \(String(format: "%.1f%%", first.maxDrawdownPct))")
                        TradingRow(label: "Last 30% of the period", value: "\(TradingFormat.percent(last.totalReturnPct)) · fall \(String(format: "%.1f%%", last.maxDrawdownPct))")
                        if !result.windows.isEmpty {
                            Divider()
                            ForEach(result.windows) { window in
                                TradingRow(label: LocalizedStringKey("Quarter \(window.index) of the period"),
                                           value: "\(TradingFormat.percent(window.metrics.totalReturnPct)) · \(window.metrics.closedTrades) trades")
                            }
                        }
                    }
                }

                if !result.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        ForEach(result.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .foregroundStyle(theme.warningColor)
                    .accessibilityIdentifier("backtest.warnings")
                }

                TradingSection(title: "Assumptions") {
                    ForEach(result.assumptions, id: \.self) { line in
                        Label {
                            Text(line).font(.footnote).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "circle.fill").font(.system(size: 4))
                        }
                        .foregroundStyle(theme.secondaryText)
                    }
                }
                .accessibilityIdentifier("backtest.assumptions")

                TradingSection(title: "Trades", trailing: "\(result.trades.count)") {
                    if result.trades.isEmpty {
                        Text("These rules never triggered in this period.").font(.subheadline).foregroundStyle(theme.secondaryText)
                    }
                    ForEach(result.trades.suffix(60).reversed()) { trade in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(trade.instrument.symbol) · \(trade.entryTime.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.subheadline.weight(.semibold))
                                Text(trade.isOpen ? "Still open at the end" : "Sold \(trade.exitTime?.formatted(date: .abbreviated, time: .omitted) ?? "") · \(Self.reason(trade.exitReason))")
                                    .font(.caption)
                                    .foregroundStyle(theme.secondaryText)
                            }
                            Spacer()
                            GainLossText(value: trade.pnl, text: "\(TradingFormat.signedMoney(trade.pnl, currency)) (\(TradingFormat.percent(trade.pnlPct)))",
                                         font: .footnote.weight(.semibold).monospacedDigit())
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if result.trades.count > 60 {
                        Text("Showing the latest 60 of \(result.trades.count).").font(.caption).foregroundStyle(theme.secondaryText)
                    }
                }
            }
            .padding(.horizontal, DS.Space.gutter)
            .padding(.vertical, DS.Space.l)
        }
        .dsScreenBackground()
        .navigationTitle("Backtest")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("backtest.done") } }
        .accessibilityIdentifier("backtest.screen")
    }

    private func headline(_ label: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(theme.secondaryText).lineLimit(1)
            GainLossText(value: value, text: TradingFormat.percent(value), font: DS.money(26))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func legend(_ label: String, dashed: Bool) -> some View {
        HStack(spacing: 6) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 4))
                path.addLine(to: CGPoint(x: 22, y: 4))
            }
            .stroke(dashed ? theme.secondaryText : theme.primaryText, style: StrokeStyle(lineWidth: 2, dash: dashed ? [4, 3] : []))
            .frame(width: 22, height: 8)
            Text(label).font(.caption).foregroundStyle(theme.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }

    private func metric(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(theme.secondaryText).fixedSize(horizontal: false, vertical: true)
            Text(value).font(.body.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .dsCard(padding: DS.Space.m)
        .accessibilityElement(children: .combine)
    }

    static func reason(_ raw: String?) -> String {
        switch raw {
        case "stopLoss": return "stop loss"
        case "takeProfit": return "take profit"
        case "trailingStop": return "trailing stop"
        case "timeLimit": return "time limit"
        case "rebalance": return "rebalance"
        case "rule", .none: return "sell rule"
        case .some(let other): return other
        }
    }
}

// MARK: - Flow layout

/// Lays chips out left to right, wrapping to new lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
