//
//  PortfolioView.swift
//  Stock Tracker
//
//  The Portfolio tab. One calm, ledger-like scroll (after Yahoo Finance,
//  Origin, Public and Quicken on Mobbin):
//    hero (value, period + today, real-history chart, ranges)
//    → summary strip (total return, invested, holdings)
//    → Holdings | Allocation | Performance | Income
//  The title is the portfolio switcher; "+" opens the single add flow.
//

import SwiftUI

// MARK: - Segments & sorting

enum PortfolioSegment: String, CaseIterable {
    case holdings, allocation, performance, income

    var title: String {
        switch self {
        case .holdings:    return "Holdings"
        case .allocation:  return "Allocation"
        case .performance: return "Performance"
        case .income:      return "Income"
        }
    }
}

enum HoldingSort: String, CaseIterable {
    case value, today, total, name

    var title: String {
        switch self {
        case .value: return "Value"
        case .today: return "Today's change"
        case .total: return "Total return"
        case .name:  return "Name"
        }
    }
}

private enum PortfolioSheet: Identifiable, Equatable {
    case add, broker, newPortfolio
    case paywall(feature: String, tier: SubscriptionTier)

    var id: String {
        switch self {
        case .add: return "add"
        case .broker: return "broker"
        case .newPortfolio: return "new"
        case .paywall(let feature, _): return "paywall-\(feature)"
        }
    }
}

// MARK: - PortfolioView

struct PortfolioView: View {
    @EnvironmentObject private var cloudAuth: SupabaseAuthManager
    @EnvironmentObject private var marketData: MarketData
    @EnvironmentObject private var subscriptionManager: SubscriptionManager
    @EnvironmentObject private var insightService: AIInsightService
    @Environment(\.theme) private var theme
    @ObservedObject private var broker = SnapTradeViewModel.shared

    @AppStorage("portfolioSegment") private var segmentRaw = PortfolioSegment.holdings.rawValue
    @AppStorage("portfolioChartRange") private var rangeRaw = TimeRange.oneDay.rawValue
    @AppStorage("portfolioHoldingSort") private var sortRaw = HoldingSort.value.rawValue
    @AppStorage("portfolioHoldingMetric") private var metricRaw = HoldingMetric.today.rawValue
    @AppStorage("portfolioValueHidden") private var valueHidden = false

    @State private var path: [UUID] = []
    @State private var filter: AssetKind?
    @State private var sheet: PortfolioSheet?
    @State private var holdingToRemove: PortfolioHolding?
    @State private var closedSheet: ClosedPosition?
    @State private var renameIndex: Int?
    @State private var renameText = ""
    @State private var deleteIndex: Int?
    @State private var toast: String?

    @State private var healthText: String?
    @State private var healthLoading = false

    // MARK: Derived

    private var segment: PortfolioSegment { PortfolioSegment(rawValue: segmentRaw) ?? .holdings }
    private var segmentBinding: Binding<PortfolioSegment> {
        Binding(get: { segment }, set: { segmentRaw = $0.rawValue })
    }
    private var rangeBinding: Binding<TimeRange> {
        Binding(get: { TimeRange(rawValue: rangeRaw) ?? .oneDay }, set: { rangeRaw = $0.rawValue })
    }
    private var sort: HoldingSort { HoldingSort(rawValue: sortRaw) ?? .value }
    private var metric: HoldingMetric { HoldingMetric(rawValue: metricRaw) ?? .today }

    private var activeName: String {
        let i = marketData.activePortfolioIndex
        return marketData.portfolioGroups.indices.contains(i) ? marketData.portfolioGroups[i].name : "Portfolio"
    }

    private var hasBothKinds: Bool {
        let kinds = Set(marketData.portfolio.map(\.asset.kind))
        return kinds.count > 1
    }

    private var visibleHoldings: [PortfolioHolding] {
        let base = marketData.portfolio.filter { filter == nil || $0.asset.kind == filter }
        switch sort {
        case .value: return base.sorted { $0.currentValue > $1.currentValue }
        case .today: return base.sorted { $0.asset.changePercent > $1.asset.changePercent }
        case .total: return base.sorted { $0.totalReturnPercent > $1.totalReturnPercent }
        case .name:  return base.sorted { $0.asset.symbol.localizedStandardCompare($1.asset.symbol) == .orderedAscending }
        }
    }

    private func weight(of holding: PortfolioHolding) -> Double {
        let total = marketData.totalPortfolioValue
        return total > 0 ? holding.currentValue / total * 100 : 0
    }

    // MARK: Body

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
            List {
                if marketData.portfolio.isEmpty {
                    emptyState
                    closedSection
                    if cloudAuth.authState == .signedIn, let userId = cloudAuth.userId {
                        PortfolioPerformanceLedger(userId: userId)
                            .id(userId)
                            .portfolioRow(bottom: DS.Space.l)
                    }
                } else {
                    PortfolioPerformanceChart(
                        range: rangeBinding,
                        hidesValues: valueHidden,
                        accessibilityID: "portfolio.chart"
                    )
                    .portfolioRow(top: DS.Space.s, bottom: DS.Space.l)

                    summaryStrip
                        .portfolioRow(bottom: DS.Space.l)

                    PortfolioAccountsCard(hidesValues: valueHidden, onManageBrokers: { sheet = .broker })
                        .portfolioRow(bottom: DS.Space.l)

                    DSSegmentBar(options: PortfolioSegment.allCases, selection: segmentBinding,
                                 title: { $0.title }, identifier: { "portfolio.segment.\($0.rawValue)" })
                        .portfolioRow(bottom: DS.Space.m)
                        .id("portfolio.segments")

                    switch segment {
                    case .holdings:    holdingsSection
                    case .allocation:  PortfolioAllocationTab().portfolioRow(bottom: DS.Space.xxl)
                    case .performance: PortfolioPerformanceTab(onUpgrade: { sheet = .paywall(feature: "Benchmark comparison", tier: .black) })
                                           .portfolioRow(bottom: DS.Space.xxl)
                    case .income:      PortfolioIncomeTab().portfolioRow(bottom: DS.Space.xxl)
                    }
                }
                // Practice (paper) portfolios sit apart from real holdings, always labelled.
                PracticePortfolioSection()
                    .portfolioRow(bottom: DS.Space.xxl)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .dsScreenBackground(style: .portfolio)
            .refreshable { await marketData.refreshFromAPI() }
            .onChange(of: segmentRaw) { _, _ in
                // The segment's content starts below the hero — bring it into view.
                dsAnimate { proxy.scrollTo("portfolio.segments", anchor: .top) }
            }
            .onChange(of: broker.lastImport) { _, summary in
                guard let added = summary?.added, added > 0 else { return }
                showToast(added == 1 ? "1 holding added from your broker" : "\(added) holdings added from your broker")
            }
            }
            .navigationTitle(activeName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarTitleMenu { portfolioMenu }
            .toolbar { toolbarContent }
            .navigationDestination(for: UUID.self) { HoldingDetailView(holdingID: $0) }
            .overlay(alignment: .bottom) { toastView }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .add:
                AddHoldingFlow(onAdded: { symbol in showToast("Added \(symbol)") })
            case .broker:
                SnapTradeConnectionView()
            case .newPortfolio:
                CreatePortfolioSheet()
            case .paywall(let feature, let tier):
                PaywallView(requiredTier: tier, featureName: feature)
            }
        }
        .sheet(item: $closedSheet) { ClosedPositionSheet(positionID: $0.id) }
        .alert("Remove holding?", isPresented: Binding(get: { holdingToRemove != nil }, set: { if !$0 { holdingToRemove = nil } })) {
            Button("Remove", role: .destructive) {
                if let h = holdingToRemove {
                    dsAnimate { marketData.removeFromPortfolio(h) }
                    Haptics.success()
                }
                holdingToRemove = nil
            }
            Button("Cancel", role: .cancel) { holdingToRemove = nil }
        } message: {
            if let h = holdingToRemove {
                Text("\(h.asset.unitsText(h.shares)) of \(h.asset.symbol) and its transactions will be removed from \(activeName).")
            }
        }
        .alert("Rename portfolio", isPresented: Binding(get: { renameIndex != nil }, set: { if !$0 { renameIndex = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let i = renameIndex, !trimmed.isEmpty { marketData.renamePortfolio(at: i, to: trimmed) }
                renameIndex = nil
            }
            Button("Cancel", role: .cancel) { renameIndex = nil }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { deleteIndex != nil }, set: { if !$0 { deleteIndex = nil } }), titleVisibility: .visible) {
            Button("Delete portfolio", role: .destructive) {
                if let i = deleteIndex { dsAnimate { marketData.deletePortfolio(at: i) } }
                deleteIndex = nil
            }
            Button("Cancel", role: .cancel) { deleteIndex = nil }
        } message: {
            Text("Its holdings and transactions are deleted from this iPhone. This can't be undone.")
        }
    }

    private var deleteTitle: String {
        guard let i = deleteIndex, marketData.portfolioGroups.indices.contains(i) else { return "Delete portfolio?" }
        return "Delete “\(marketData.portfolioGroups[i].name)”?"
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if !marketData.portfolio.isEmpty {
                Button {
                    Haptics.tap()
                    dsAnimate(DS.quick) { valueHidden.toggle() }
                } label: {
                    Image(systemName: valueHidden ? "eye.slash" : "eye")
                }
                .accessibilityLabel(valueHidden ? "Show balances" : "Hide balances")
                .accessibilityIdentifier("portfolio.privacy")
            }

            Button {
                Haptics.tap()
                sheet = .add
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add holding")
            .accessibilityIdentifier("portfolio.add")
        }
    }

    @ViewBuilder
    private var portfolioMenu: some View {
        ForEach(Array(marketData.portfolioGroups.enumerated()), id: \.element.id) { index, group in
            Button {
                Haptics.select()
                dsAnimate { marketData.switchToPortfolio(index: index) }
            } label: {
                if index == marketData.activePortfolioIndex {
                    Label(group.name, systemImage: "checkmark")
                } else {
                    Text(group.name)
                }
            }
        }
        Divider()
        Button {
            if subscriptionManager.canAddPortfolio(currentCount: marketData.portfolioGroups.count) {
                sheet = .newPortfolio
            } else {
                sheet = .paywall(feature: "More portfolios", tier: .black)
            }
        } label: {
            Label("New portfolio…", systemImage: "plus")
        }
        Button {
            renameText = activeName
            renameIndex = marketData.activePortfolioIndex
        } label: {
            Label("Rename…", systemImage: "pencil")
        }
        if marketData.portfolioGroups.count > 1 {
            Button(role: .destructive) {
                deleteIndex = marketData.activePortfolioIndex
            } label: {
                Label("Delete…", systemImage: "trash")
            }
        }
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: DS.Space.l) {
            EmptyStateCard(
                systemImage: "briefcase",
                title: "Start your portfolio",
                message: "Add what you own — stocks, ETFs or crypto, US or ASX — or connect a broker for read-only syncing. Your value, today's move and returns will show here.",
                primaryTitle: "Add a holding",
                primaryAction: { sheet = .add },
                secondaryTitle: "Connect a broker",
                secondaryAction: { sheet = .broker }
            )
            .accessibilityIdentifier("portfolio.empty")
        }
        .portfolioRow(top: DS.Space.l, bottom: DS.Space.xxl)
    }

    // MARK: Summary strip

    private var summaryStrip: some View {
        let priced = marketData.portfolio.filter { $0.costBasis > 0 }
        let missingCost = marketData.portfolio.count - priced.count
        let invested = priced.reduce(0) { $0 + $1.costBasis }
        let unrealised = priced.reduce(0) { $0 + $1.currentValue } - invested
        let realised = marketData.totalRealizedGain
        let hasSales = marketData.portfolio.contains { $0.ledger.sellCount > 0 } || !marketData.closedPositions.isEmpty
        // Total return = what's held (unrealised) + what was sold (realised), over everything paid.
        let gain = marketData.totalReturn
        let gainPct = marketData.totalReturnPercent
        let tint = gain >= 0 ? theme.positiveColor : theme.negativeColor

        return VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .top, spacing: DS.Space.m) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Total return")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                    if invested > 0 || hasSales {
                        if !valueHidden {
                            Text(marketData.signedMoney(gain))
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(tint)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        Text(formatPercent(gainPct, signed: true))
                            .font((valueHidden ? Font.subheadline : .caption).weight(.semibold).monospacedDigit())
                            .foregroundStyle(tint)
                    } else {
                        Text("—").font(.subheadline.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                LedgerStat(label: "Invested", value: valueHidden ? "••••" : (invested > 0 ? marketData.formatPrice(invested) : "—"))
                LedgerStat(label: "Holdings", value: "\(marketData.portfolio.count)", alignment: .trailing)
            }
            if hasSales {
                HStack(spacing: DS.Space.s) {
                    Text(valueHidden ? "Unrealised" : "Unrealised \(marketData.signedMoney(unrealised))")
                    Text("·")
                    Text(valueHidden ? "Realised" : "Realised \(marketData.signedMoney(realised))")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("portfolio.summary.breakdown")
            }
            if missingCost > 0 {
                Text(missingCost == 1
                     ? "1 holding has no cost, so it's left out of total return."
                     : "\(missingCost) holdings have no cost, so they're left out of total return.")
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .dsCard(padding: DS.Space.l)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("portfolio.summary")
    }

    // MARK: Holdings

    @ViewBuilder
    private var holdingsSection: some View {
        holdingsHeader
            .portfolioRow(bottom: hasBothKinds ? DS.Space.s : 0)

        if hasBothKinds {
            filterChips.portfolioRow(bottom: DS.Space.xs)
        }

        if marketData.isOverPortfolioLimit {
            overLimitBanner.portfolioRow(top: DS.Space.s, bottom: DS.Space.s)
        }

        ForEach(visibleHoldings) { holding in
            Button {
                Haptics.tap()
                path.append(holding.id)
            } label: {
                PortfolioHoldingRow(holding: holding, metric: metric, weight: weight(of: holding), hidesValues: valueHidden,
                                    source: broker.institution(for: holding))
            }
            .buttonStyle(PressableButtonStyle(scale: 0.99))
            .accessibilityIdentifier("portfolio.holding.\(holding.asset.symbol)")
            .listRowInsets(EdgeInsets(top: 0, leading: DS.Space.l, bottom: 0, trailing: DS.Space.l))
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(theme.cardBorder.opacity(0.6))
            .alignmentGuide(.listRowSeparatorLeading) { _ in 52 }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    holdingToRemove = holding
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
            .contextMenu {
                Button { path.append(holding.id) } label: { Label("View details", systemImage: "list.bullet.rectangle") }
                Button(role: .destructive) { holdingToRemove = holding } label: { Label("Remove", systemImage: "trash") }
            }
        }

        closedSection

        if subscriptionManager.currentTier != .free {
            healthCard.portfolioRow(top: DS.Space.l, bottom: DS.Space.s)
        }

        Color.clear.frame(height: DS.Space.xxl).portfolioRow()
    }

    /// Holdings sold down to zero — their realised profit is part of Total return.
    @ViewBuilder
    private var closedSection: some View {
        let closed = marketData.closedPositions.filter { filter == nil || $0.asset.kind == filter }
        if !closed.isEmpty {
            let realised = closed.reduce(0) { $0 + $1.realizedGain }
            HStack(alignment: .firstTextBaseline) {
                Text("Closed positions")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if !valueHidden {
                    Text("Realised \(marketData.signedMoney(realised))")
                        .font(.subheadline.weight(.medium).monospacedDigit())
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .portfolioRow(top: DS.Space.xl, bottom: DS.Space.xs)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("portfolio.closed.header")

            ForEach(closed) { position in
                Button {
                    Haptics.tap()
                    closedSheet = position
                } label: {
                    ClosedPositionRow(position: position, hidesValues: valueHidden)
                }
                .buttonStyle(PressableButtonStyle(scale: 0.99))
                .accessibilityIdentifier("portfolio.closed.\(position.asset.symbol)")
                .listRowInsets(EdgeInsets(top: 0, leading: DS.Space.l, bottom: 0, trailing: DS.Space.l))
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(theme.cardBorder.opacity(0.6))
                .alignmentGuide(.listRowSeparatorLeading) { _ in 52 }
            }
        }
    }

    private var holdingsHeader: some View {
        HStack(alignment: .center, spacing: DS.Space.s) {
            Text("Holdings")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button {
                Haptics.select()
                metricRaw = (metric == .today ? HoldingMetric.total : .today).rawValue
            } label: {
                HStack(spacing: 4) {
                    Text(metric.title)
                    Image(systemName: "arrow.left.arrow.right").font(.caption2.weight(.bold))
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(DS.accent)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Showing \(metric.title). Switch to \(metric == .today ? HoldingMetric.total.title : HoldingMetric.today.title)")
            .accessibilityIdentifier("portfolio.metric")

            Menu {
                Picker("Sort by", selection: $sortRaw) {
                    ForEach(HoldingSort.allCases, id: \.self) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Sort holdings, currently by \(sort.title)")
            .accessibilityIdentifier("portfolio.sort")
        }
    }

    private var filterChips: some View {
        let stocks = marketData.portfolio.filter { $0.asset.kind == .stock }.count
        let crypto = marketData.portfolio.count - stocks
        return HStack(spacing: DS.Space.s) {
            chip("All", isOn: filter == nil) { filter = nil }
            chip("Stocks \(stocks)", isOn: filter == .stock) { filter = .stock }
            chip("Crypto \(crypto)", isOn: filter == .crypto) { filter = .crypto }
            Spacer()
        }
    }

    private func chip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.select()
            dsAnimate(DS.quick, action)
        } label: {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(isOn ? theme.primaryText : theme.secondaryText)
                .padding(.horizontal, 14)
                .frame(minHeight: 34)
                .background(Capsule().fill(isOn ? theme.cardBackground : theme.subtleFill))
                .overlay(Capsule().strokeBorder(theme.cardBorder.opacity(isOn ? 0.8 : 0.4), lineWidth: 0.5))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var overLimitBanner: some View {
        let limit = FeatureGate.maxPortfolioHoldings(for: subscriptionManager.currentTier) ?? marketData.portfolio.count
        let over = max(marketData.portfolio.count - limit, 0)
        return HStack(alignment: .top, spacing: DS.Space.m) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(theme.warningColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("Your plan includes \(limit) holdings")
                    .font(.subheadline.weight(.semibold))
                Text("You have \(over) more than that. Remove \(over == 1 ? "one" : "some") or upgrade to keep tracking them all.")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
                Button("See plans") { sheet = .paywall(feature: "More holdings", tier: .pro) }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.accent)
                    .frame(minHeight: 44)
            }
            Spacer(minLength: 0)
        }
        .dsCard()
    }

    // MARK: AI health (Pro / Black)

    private var healthCard: some View {
        let tier = subscriptionManager.currentTier
        let cacheKey = "portfolio_health_\(insightService.todayString)"
        return AIInsightCard(
            title: "Portfolio health",
            icon: "heart.text.square",
            insightText: insightService.cached(cacheKey)?.text ?? healthText,
            isLoading: healthLoading,
            isLocked: tier == .free,
            tier: tier,
            onGenerate: { await loadHealth() },
            onRegenerate: { await loadHealth(force: true) }
        )
    }

    private func loadHealth(force: Bool = false) async {
        healthLoading = true
        defer { healthLoading = false }
        let total = marketData.totalPortfolioValue
        guard total > 0 else { return }
        let tier = subscriptionManager.currentTier
        let cacheKey = "portfolio_health_\(insightService.todayString)"
        let holdings = marketData.portfolio.map { h in
            "\(h.asset.symbol) (\(h.asset.marketLabel)): \(Int((h.currentValue / total * 100).rounded()))% of portfolio, "
            + (h.costBasis > 0 ? String(format: "%+.1f%% since bought", h.profitLossPercent) : "cost unknown")
        }.joined(separator: "; ")
        let crypto = marketData.portfolio.filter { $0.asset.kind == .crypto }.reduce(0) { $0 + $1.currentValue } / total * 100
        let system = "You are a portfolio risk advisor. Identify 1-2 key risks or opportunities. Be specific about which holdings. 2-3 bullet points max. No buy/sell advice."
        let user = "Portfolio worth \(marketData.formatPrice(total)), \(Int(crypto.rounded()))% crypto. Holdings: \(holdings)."
        let result = force
            ? await insightService.regenerateInsight(key: cacheKey, type: .portfolioHealth, systemPrompt: system,
                                                     userPrompt: user, tier: tier, ttl: Constants.AI.dailyCacheTTL)
            : await insightService.generateInsight(key: cacheKey, type: .portfolioHealth, systemPrompt: system,
                                                   userPrompt: user, tier: tier, ttl: Constants.AI.dailyCacheTTL)
        if let result { healthText = result }
    }

    // MARK: Toast

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Label(toast, systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.primaryText)
                .padding(.horizontal, DS.Space.l)
                .frame(minHeight: 44)
                .background(Capsule().fill(theme.cardBackground))
                .overlay(Capsule().strokeBorder(theme.cardBorder.opacity(0.6), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                .padding(.bottom, 96)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityIdentifier("portfolio.toast")
        }
    }

    private func showToast(_ text: String) {
        dsAnimate { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            dsAnimate { if toast == text { toast = nil } }
        }
    }
}

// MARK: - Create portfolio

struct CreatePortfolioSheet: View {
    @EnvironmentObject private var marketData: MarketData
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var name = ""
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                Text("Keep separate goals or accounts apart — each portfolio has its own holdings and chart.")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                TextField("Portfolio name", text: $name)
                    .font(.title3)
                    .padding(.horizontal, DS.Space.l)
                    .frame(minHeight: 52)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.subtleFill))
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(create)
                    .accessibilityIdentifier("portfolio.new.name")
                Spacer()
                Button("Create portfolio", action: create)
                    .buttonStyle(PrimaryPillButtonStyle())
                    .disabled(trimmed.isEmpty)
            }
            .padding(DS.Space.gutter)
            .dsScreenBackground()
            .navigationTitle("New portfolio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }

    private func create() {
        guard !trimmed.isEmpty else { return }
        if marketData.createPortfolio(name: trimmed) {
            Haptics.success()
            dismiss()
        }
    }
}
