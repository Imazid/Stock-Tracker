//
//  HoldingDetailView.swift
//  Stock Tracker
//
//  One holding, pushed from the Portfolio tab (after Public "Your position"
//  and Fidelity "Positions" on Mobbin): live header, real price chart, a
//  position ledger, and the transactions the position is built from — each
//  editable or deletable, with overselling blocked.
//
//  Reads the holding live from MarketData by id, so every change shows at once.
//

import SwiftUI

struct HoldingDetailView: View {
    let holdingID: UUID

    @EnvironmentObject private var marketData: MarketData
    @EnvironmentObject private var insightService: AIInsightService
    @EnvironmentObject private var subscriptionManager: SubscriptionManager
    @ObservedObject private var broker = SnapTradeViewModel.shared
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @AppStorage("portfolioValueHidden") private var valueHidden = false
    @AppStorage("holdingChartRange") private var rangeRaw = TimeRange.oneMonth.rawValue

    @State private var points: [PricePoint] = []
    @State private var phase: DSChartPhase = .loading
    @State private var scrubbed: DSChartPoint?
    @State private var txSheet: TransactionSheetItem?
    @State private var confirmRemove = false
    @State private var stockPage: Asset?
    @State private var alertText: String?
    @State private var insightText: String?
    @State private var insightLoading = false

    private var holding: PortfolioHolding? { marketData.portfolio.first { $0.id == holdingID } }
    private var range: TimeRange { TimeRange(rawValue: rangeRaw) ?? .oneMonth }

    var body: some View {
        Group {
            if let holding {
                content(holding)
            } else if let closed = marketData.closedPositions.first(where: { $0.id == holdingID }) {
                closedState(closed)
            } else {
                EmptyStateCard(systemImage: "checkmark.circle", title: "Holding removed",
                               message: "It's no longer in this portfolio.",
                               primaryTitle: "Back to portfolio", primaryAction: { dismiss() })
                    .padding(DS.Space.gutter)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .dsScreenBackground()
        .navigationTitle(holding?.asset.symbol ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let holding {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { txSheet = .add } label: { Label("Add transaction", systemImage: "plus") }
                        Button { stockPage = holding.asset } label: { Label("View stock page", systemImage: "chart.xyaxis.line") }
                        Divider()
                        Button(role: .destructive) { confirmRemove = true } label: { Label("Remove holding", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("More actions")
                    .accessibilityIdentifier("holding.more")
                }
            }
        }
        .sheet(item: $txSheet) { item in
            if let holding {
                TransactionFormSheet(holding: holding, editing: item.transaction)
            }
        }
        .sheet(item: $stockPage) { asset in
            AppleStocksDetailView(stock: detailedStock(from: asset), asset: asset, position: nil)
        }
        .confirmationDialog("Remove \(holding?.asset.symbol ?? "holding")?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove holding", role: .destructive) {
                if let holding {
                    marketData.removeFromPortfolio(holding)
                    Haptics.success()
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The holding and all its transactions are removed from this portfolio.")
        }
        .alert("Can't change that", isPresented: Binding(get: { alertText != nil }, set: { if !$0 { alertText = nil } })) {
            Button("OK", role: .cancel) { alertText = nil }
        } message: {
            Text(alertText ?? "")
        }
    }

    // MARK: Content

    private func content(_ h: PortfolioHolding) -> some View {
        List {
            header(h).portfolioRow(top: DS.Space.m, bottom: DS.Space.m)
            chartBlock(h).portfolioRow(bottom: DS.Space.l)
            positionCard(h).portfolioRow(bottom: DS.Space.l)

            transactionsHeader(h).portfolioRow(bottom: DS.Space.xs)
            if h.transactions.isEmpty {
                Text("No transactions recorded. Add one to keep your position and average cost accurate.")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .portfolioRow(bottom: DS.Space.s)
            } else {
                let realizedBySale = h.ledger.realizedBySale
                ForEach(h.transactions.sorted { $0.date > $1.date }) { tx in
                    Button { txSheet = .edit(tx) } label: {
                        TransactionRow(tx: tx, asset: h.asset, realized: realizedBySale[tx.id], hidesValues: valueHidden)
                    }
                        .buttonStyle(PressableButtonStyle(scale: 0.99))
                        .listRowInsets(EdgeInsets(top: 0, leading: DS.Space.l, bottom: 0, trailing: DS.Space.l))
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(theme.cardBorder.opacity(0.6))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { delete(tx, from: h) } label: { Label("Delete", systemImage: "trash") }
                        }
                        .accessibilityIdentifier("holding.tx.\(tx.id.uuidString.prefix(8))")
                        .accessibilityHint("Opens the transaction to edit")
                }
            }
            Button {
                Haptics.tap()
                txSheet = .add
            } label: {
                Label("Add transaction", systemImage: "plus")
            }
            .buttonStyle(SecondaryPillButtonStyle())
            .accessibilityIdentifier("holding.addTransaction")
            .portfolioRow(top: DS.Space.m, bottom: DS.Space.l)

            if subscriptionManager.currentTier != .free {
                insightCard(h).portfolioRow(bottom: DS.Space.l)
            }

            Button("Remove from portfolio", role: .destructive) { confirmRemove = true }
                .font(.body.weight(.medium))
                .foregroundStyle(theme.negativeColor)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("holding.remove")
                .portfolioRow(bottom: DS.Space.xxl)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .task(id: "\(rangeRaw)|\(h.asset.symbol)") { await loadChart(h.asset) }
    }

    private func header(_ h: PortfolioHolding) -> some View {
        let asset = h.asset
        let reference = range == .oneDay ? asset.price - asset.change : points.first?.price
        let shown = scrubbed?.value ?? asset.price
        let change = reference.map { shown - $0 } ?? asset.change
        let pct = (reference ?? 0) > 0 ? change / reference! * 100 : asset.changePercent
        let noLive = marketData.hasNoLivePrice(asset)

        return VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.m) {
                TickerLogo(symbol: asset.symbol, kind: asset.kind, exchange: asset.exchange, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(asset.name)
                        .font(.headline)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(asset.symbol)
                        Text("·")
                        Text(asset.marketLabel)
                    }
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                }
            }
            Text(marketData.formatPrice(shown))
                .font(DS.money(34, weight: .bold))
                .contentTransition(.numericText())
                .accessibilityIdentifier("holding.price")
            if noLive {
                Label("No live price — showing the last known price", systemImage: "exclamationmark.circle")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(theme.warningColor)
            } else {
                HStack(spacing: DS.Space.s) {
                    ChangePill(percent: pct, amount: marketData.signedMoney(change))
                    (scrubbed.map { Text(range.scrubLabel(for: $0.date)) } ?? Text(range.periodLabel))
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
    }

    private func chartBlock(_ h: PortfolioHolding) -> some View {
        VStack(spacing: DS.Space.m) {
            DSPriceChart(
                points: points.chartPoints,
                phase: phase,
                baseline: range == .oneDay && h.asset.price - h.asset.change > 0 ? h.asset.price - h.asset.change : nil,
                baselineLabel: range == .oneDay ? "Prev close" : nil,
                xMode: xMode(for: h.asset),
                height: 200,
                valueText: { marketData.formatPrice($0) },
                dateText: { range.scrubLabel(for: $0) },
                selection: $scrubbed,
                onRetry: { Task { await loadChart(h.asset, force: true) } },
                accessibilityID: "holding.chart"
            )
            .padding(.horizontal, -4)
            DSRangePicker(options: DSRangePicker.standard,
                          selection: Binding(get: { range }, set: { rangeRaw = $0.rawValue }))
        }
    }

    private func positionCard(_ h: PortfolioHolding) -> some View {
        let total = marketData.totalPortfolioValue
        let weight = total > 0 ? h.currentValue / total * 100 : 0
        let today = h.shares * h.asset.change
        let hasCost = h.costBasis > 0
        let hide = valueHidden
        let ledger = h.ledger
        let hasSales = ledger.sellCount > 0
        return VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("Your position")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                LedgerLine(label: "Market value", value: hide ? "••••" : marketData.formatPrice(h.currentValue))
                LedgerLine(label: h.asset.kind == .crypto ? "Quantity" : "Shares", value: formatQuantity(h.shares))
                LedgerLine(label: "Average cost",
                           value: hasCost ? marketData.formatPrice(h.avgCost) : "Not set",
                           detail: hasCost && h.asset.tradingCurrency != marketData.preferredCurrency
                                ? h.asset.formatTrading(h.asset.toTradingCurrency(h.avgCost)) : nil)
                    .accessibilityIdentifier("holding.avgCost")
                LedgerLine(label: "Total cost", value: hasCost ? (hide ? "••••" : marketData.formatPrice(h.costBasis)) : "—")
                LedgerLine(label: "Today",
                           value: (hide ? "" : marketData.signedMoney(today) + "  ") + formatPercent(h.asset.changePercent, signed: true),
                           tint: today >= 0 ? theme.positiveColor : theme.negativeColor)
                if hasSales {
                    // After Cash App "Unrealized + realized" and QuestMobile "Open / Closed P&L".
                    LedgerLine(label: "Unrealised return",
                               value: hasCost ? (hide ? "" : marketData.signedMoney(h.profitLoss) + "  ") + formatPercent(h.profitLossPercent, signed: true) : "Add what you paid",
                               tint: hasCost ? (h.profitLoss >= 0 ? theme.positiveColor : theme.negativeColor) : nil)
                        .accessibilityIdentifier("holding.unrealized")
                    LedgerLine(label: "Realised from sales",
                               value: ledger.costOfSold > 0 ? (hide ? "••••" : marketData.signedMoney(h.realizedGain)) : "—",
                               tint: ledger.costOfSold > 0 ? (h.realizedGain >= 0 ? theme.positiveColor : theme.negativeColor) : nil,
                               detail: ledger.unknownBasisSells > 0 ? "Some sales have no cost recorded" : nil)
                        .accessibilityIdentifier("holding.realized")
                    LedgerLine(label: "Total return",
                               value: hasCost ? (hide ? "" : marketData.signedMoney(h.totalReturn) + "  ") + formatPercent(h.totalReturnPercent, signed: true) : "Add what you paid",
                               tint: hasCost ? (h.totalReturn >= 0 ? theme.positiveColor : theme.negativeColor) : nil)
                        .accessibilityIdentifier("holding.totalReturn")
                } else {
                    LedgerLine(label: "Total return",
                               value: hasCost ? (hide ? "" : marketData.signedMoney(h.profitLoss) + "  ") + formatPercent(h.profitLossPercent, signed: true) : "Add what you paid",
                               tint: hasCost ? (h.profitLoss >= 0 ? theme.positiveColor : theme.negativeColor) : nil)
                        .accessibilityIdentifier("holding.totalReturn")
                }
                LedgerLine(label: "Share of portfolio", value: formatPercent(weight))
            }
        }
        .dsCard()
        // A container, so each line keeps its own identifier (holding.realized, …).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("holding.position")
    }

    /// Shown when the last shares were just sold: the holding moved to Closed positions.
    private func closedState(_ c: ClosedPosition) -> some View {
        let known = c.ledger.costOfSold > 0
        let gain = c.realizedGain
        return ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.largeTitle)
                        .foregroundStyle(DS.accent)
                    Text("Position closed")
                        .font(.title2.weight(.bold))
                    Text("You sold all your \(c.asset.symbol). It's kept under Closed positions, and its realised profit stays in your total return.")
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 0) {
                    LedgerLine(label: "Realised profit",
                               value: known ? (valueHidden ? "••••" : marketData.signedMoney(gain) + "  ") + (valueHidden ? "" : formatPercent(c.realizedPercent, signed: true)) : "—",
                               tint: known ? (gain >= 0 ? theme.positiveColor : theme.negativeColor) : nil)
                        .accessibilityIdentifier("holding.closed.realized")
                    LedgerLine(label: "Sales", value: "\(c.ledger.sellCount)")
                }
                .dsCard()
                Button("Back to portfolio") { dismiss() }
                    .buttonStyle(PrimaryPillButtonStyle())
                    .accessibilityIdentifier("holding.closed.back")
            }
            .padding(DS.Space.gutter)
        }
        .accessibilityIdentifier("holding.closed")
    }

    private func transactionsHeader(_ h: PortfolioHolding) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("Transactions")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if !h.transactions.isEmpty {
                    Text("\(h.transactions.count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(theme.secondaryText)
                }
            }
            // A sync replaces an imported holding's shares and average cost — say so before
            // someone edits transactions here and loses them on the next sync.
            if broker.isImported(h) {
                Label("Synced from \(broker.institution(for: h) ?? "your broker"). Shares and average cost update from your broker each time it syncs.",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("holding.syncedFrom")
            }
        }
    }

    private func insightCard(_ h: PortfolioHolding) -> some View {
        let tier = subscriptionManager.currentTier
        let key = "holding_insight_\(h.asset.symbol)"
        return AIInsightCard(
            title: "Holding insight",
            icon: "lightbulb",
            insightText: insightService.cached(key)?.text ?? insightText,
            isLoading: insightLoading,
            isLocked: tier == .free,
            tier: tier,
            onGenerate: { await loadInsight(h) },
            onRegenerate: { await loadInsight(h, force: true) }
        )
    }

    // MARK: Actions

    private func delete(_ tx: Transaction, from h: PortfolioHolding) {
        if h.transactions.count == 1 {
            alertText = "This is the only transaction. Remove the holding instead."
            return
        }
        switch marketData.deleteTransaction(holdingID: h.id, transactionID: tx.id) {
        case .ok: Haptics.success()
        case .invalid(let message): alertText = message
        case .limitReached: break
        }
    }

    private func loadChart(_ asset: Asset, force: Bool = false) async {
        phase = .loading
        scrubbed = nil
        do {
            let history = try await PriceHistoryService.shared.history(for: asset, range: range, forceRefresh: force)
            guard !Task.isCancelled else { return }
            points = PriceHistoryService.appendingLive(history, price: asset.price)
            phase = .loaded
        } catch {
            guard !Task.isCancelled else { return }
            points = []
            phase = .failed("Price history for \(asset.symbol) isn't available right now.")
        }
    }

    private func xMode(for asset: Asset) -> DSChartXMode {
        guard range == .oneDay, let first = points.first, let last = points.last,
              let hours = TradingHours.forAsset(asset),
              hours.session(containing: first.date).contains(last.date) else { return .ordinal }
        return .time(domain: hours.session(containing: first.date))
    }

    private func loadInsight(_ h: PortfolioHolding, force: Bool = false) async {
        insightLoading = true
        defer { insightLoading = false }
        let tier = subscriptionManager.currentTier
        let key = "holding_insight_\(h.asset.symbol)"
        var context = "\(h.asset.name) (\(h.asset.symbol), \(h.asset.marketLabel)): \(h.asset.unitsText(h.shares)), "
        context += "average cost \(marketData.formatPrice(h.avgCost)), now \(marketData.formatPrice(h.asset.price)). "
        if h.costBasis > 0 { context += String(format: "Return since bought %+.1f%%. ", h.profitLossPercent) }
        context += String(format: "Today %+.2f%%.", h.asset.changePercent)
        let system = "You are a portfolio analyst. Give a brief 2-3 sentence insight about this holding position. Comment on the cost basis vs current price, and whether the position sizing looks reasonable."
        let result = force
            ? await insightService.regenerateInsight(key: key, type: .holdingInsight, systemPrompt: system,
                                                     userPrompt: context, tier: tier, ttl: Constants.AI.holdingCacheTTL)
            : await insightService.generateInsight(key: key, type: .holdingInsight, systemPrompt: system,
                                                   userPrompt: context, tier: tier, ttl: Constants.AI.holdingCacheTTL)
        if let result { insightText = result }
    }
}

// MARK: - Transaction sheet

enum TransactionSheetItem: Identifiable {
    case add
    case edit(Transaction)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let tx): return tx.id.uuidString
        }
    }

    var transaction: Transaction? {
        if case .edit(let tx) = self { return tx }
        return nil
    }
}

/// Add or edit one buy/sell. Prices are typed in the asset's trading currency
/// (A$ for ASX, US$ otherwise) and stored in USD.
struct TransactionFormSheet: View {
    let holding: PortfolioHolding
    let editing: Transaction?

    @EnvironmentObject private var marketData: MarketData
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var type: TransactionType
    @State private var quantityText: String
    @State private var priceText: String
    @State private var feesText: String
    @State private var date: Date
    @State private var errorText: String?
    @State private var didAutofocus = false
    @FocusState private var focus: Field?

    enum Field { case quantity, price, fees }

    init(holding: PortfolioHolding, editing: Transaction?) {
        self.holding = holding
        self.editing = editing
        let asset = holding.asset
        _type = State(initialValue: editing?.type ?? .buy)
        _quantityText = State(initialValue: editing.map { formatQuantity($0.shares) } ?? "")
        let price = asset.toTradingCurrency(editing?.pricePerShare ?? asset.price)
        _priceText = State(initialValue: price > 0 ? String(format: price < 1 ? "%.6f" : "%.2f", price) : "")
        let fees = asset.toTradingCurrency(editing?.fees ?? 0)
        _feesText = State(initialValue: fees > 0 ? String(format: "%.2f", fees) : "")
        _date = State(initialValue: editing?.date ?? Date())
    }

    private var asset: Asset { holding.asset }
    private var quantity: Double? { parseDecimal(quantityText) }
    private var price: Double? { parseDecimal(priceText) }
    /// Blank = no fees.
    private var fees: Double? { feesText.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : parseDecimal(feesText) }
    private var usdFactor: Double { FXRates.shared.toUSDFactor(from: asset.tradingCurrency) ?? 1 }

    /// What this sale would bank, in USD: (price − average cost) × quantity − fees.
    private var estimatedRealized: Double? {
        guard type == .sell, editing == nil, holding.avgCost > 0,
              let q = quantity, let p = price, let f = fees, q > 0 else { return nil }
        return (p * usdFactor - holding.avgCost) * q - f * usdFactor
    }

    private var validationMessage: String? {
        guard let q = quantity, q > 0 else { return nil }
        if type == .sell && editing == nil && q > holding.shares + 1e-9 {
            return "You hold \(asset.unitsText(holding.shares)) — you can't sell more than that."
        }
        return nil
    }

    private var canSave: Bool {
        (quantity ?? 0) > 0 && (price ?? -1) >= 0 && (fees ?? -1) >= 0 && validationMessage == nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    HStack(spacing: DS.Space.m) {
                        TickerLogo(symbol: asset.symbol, kind: asset.kind, exchange: asset.exchange, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(asset.symbol).font(.headline)
                            Text("You hold \(asset.unitsText(holding.shares))")
                                .font(.subheadline)
                                .foregroundStyle(theme.secondaryText)
                        }
                    }

                    DSSegmentBar(options: [TransactionType.buy, .sell], selection: $type,
                                 title: { $0 == .buy ? "Buy" : "Sell" },
                                 identifier: { "tx.type.\($0.rawValue.lowercased())" })

                    FormField(label: asset.kind == .crypto ? "Quantity" : "Number of shares") {
                        TextField("0.00", text: $quantityText)
                            .keyboardType(.decimalPad)
                            .focused($focus, equals: .quantity)
                    }

                    FormField(label: "Price per \(asset.kind == .crypto ? "coin" : "share") (\(asset.tradingCurrencySymbol))",
                              trailing: asset.price > 0 ? AnyView(
                                Button("Use current") {
                                    let p = asset.toTradingCurrency(asset.price)
                                    priceText = String(format: p < 1 ? "%.6f" : "%.2f", p)
                                }
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(DS.accent)) : nil) {
                        HStack(spacing: 4) {
                            Text(asset.tradingCurrencySymbol).foregroundStyle(theme.secondaryText)
                            TextField("0.00", text: $priceText)
                                .keyboardType(.decimalPad)
                                .focused($focus, equals: .price)
                        }
                    }

                    FormField(label: "Brokerage fees (\(asset.tradingCurrencySymbol), optional)") {
                        HStack(spacing: 4) {
                            Text(asset.tradingCurrencySymbol).foregroundStyle(theme.secondaryText)
                            TextField("0.00", text: $feesText)
                                .keyboardType(.decimalPad)
                                .focused($focus, equals: .fees)
                                .accessibilityIdentifier("tx.fees")
                        }
                    }

                    DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: .date)
                        .font(.subheadline)
                        .frame(minHeight: 44)

                    if let q = quantity, let p = price, q > 0 {
                        let f = fees ?? 0
                        VStack(spacing: 0) {
                            LedgerLine(label: type == .buy ? "Total cost" : "You receive",
                                       value: asset.formatTrading(type == .buy ? q * p + f : max(q * p - f, 0)))
                            if let realized = estimatedRealized {
                                LedgerLine(label: "Realised profit",
                                           value: marketData.signedMoney(realized),
                                           tint: realized >= 0 ? theme.positiveColor : theme.negativeColor,
                                           detail: "vs your average cost of \(marketData.formatPrice(holding.avgCost))")
                                    .accessibilityIdentifier("tx.realized")
                            }
                        }
                        .padding(.horizontal, DS.Space.l)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.subtleFill))
                    }

                    if let message = validationMessage ?? errorText {
                        Label(message, systemImage: "exclamationmark.circle")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(theme.negativeColor)
                            .accessibilityIdentifier("tx.error")
                    }

                    Button(editing == nil ? (type == .buy ? "Add buy" : "Add sell") : "Save changes", action: save)
                        .buttonStyle(PrimaryPillButtonStyle())
                        .disabled(!canSave)
                        .accessibilityIdentifier("tx.save")
                }
                .padding(DS.Space.gutter)
            }
            .dsScreenBackground()
            .navigationTitle(editing == nil ? "Add transaction" : "Edit transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                // The decimal pad has no return key: a Done in the bar puts the keyboard away.
                ToolbarItem(placement: .confirmationAction) {
                    if focus != nil {
                        Button("Done") { focus = nil }
                            .accessibilityIdentifier("keyboard.done")
                    }
                }
            }
            .task {
                guard editing == nil, !didAutofocus else { return }
                didAutofocus = true
                try? await Task.sleep(nanoseconds: 350_000_000)
                if focus == nil { focus = .quantity }
            }
        }
    }

    private func save() {
        guard let q = quantity, let p = price, let f = fees else { return }
        errorText = nil
        let result: MarketData.HoldingChange
        if let editing {
            let updated = Transaction(id: editing.id, date: date, shares: q, pricePerShare: p * usdFactor, type: type,
                                      fees: f * usdFactor, avgCostAtSale: editing.avgCostAtSale)
            let list = holding.transactions.map { $0.id == editing.id ? updated : $0 }
            result = marketData.replaceTransactions(holdingID: holding.id, with: list)
        } else {
            result = marketData.recordTransaction(holdingID: holding.id, type: type, shares: q,
                                                  pricePerUnit: p, priceCurrency: asset.tradingCurrency, fees: f, date: date)
        }
        switch result {
        case .ok:
            Haptics.success()
            dismiss()
        case .invalid(let message):
            Haptics.warning()
            errorText = message
        case .limitReached:
            errorText = "Your plan's holding limit has been reached."
        }
    }
}

// MARK: - Form field

/// Label above a rounded input, 52pt tall.
struct FormField<Content: View>: View {
    let label: String
    var trailing: AnyView? = nil
    @ViewBuilder let content: () -> Content
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(theme.secondaryText)
                Spacer()
                if let trailing { trailing }
            }
            content()
                .font(.title3.weight(.medium).monospacedDigit())
                .padding(.horizontal, DS.Space.l)
                .frame(minHeight: 52)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.subtleFill))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.cardBorder.opacity(0.6), lineWidth: 0.5))
        }
    }
}
