//
//  PracticePortfolioViews.swift
//  Stock Tracker
//
//  Practice (paper) portfolios: the section inside the Portfolio tab, the page
//  for one portfolio, and the picker for choosing what to trade.
//
//  Practice money is kept apart from real holdings. It never mixes into the
//  real portfolio's totals, charts or allocation, and it is labelled Practice
//  everywhere it appears.
//

import SwiftUI
import TradingCore

// MARK: - Section in the Portfolio tab

struct PracticePortfolioSection: View {
    @EnvironmentObject private var trading: TradingStore
    @EnvironmentObject private var router: TradingRouter
    @Environment(\.theme) private var theme
    @State private var showSetup = false
    @State private var opened: TradingRouter.Ref?

    private var agentBooks: [Ledger] { trading.state.ledgers.filter { $0.kind == .agentPaper } }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.s) {
                Text("Practice").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                PracticeChip(compact: true)
                Spacer()
                if !trading.practicePortfolios.isEmpty {
                    Button {
                        showSetup = true
                    } label: {
                        Image(systemName: "plus").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Add a practice portfolio")
                    .accessibilityIdentifier("practice.add")
                }
            }

            if trading.practicePortfolios.isEmpty {
                EmptyStateCard(
                    systemImage: "graduationcap",
                    title: "Try it with practice money",
                    message: "Buy and sell stocks and crypto at live prices with pretend money. Nothing real is ever ordered.",
                    primaryTitle: "Set up practice money",
                    primaryAction: { showSetup = true }
                )
                .accessibilityIdentifier("practice.empty")
            } else {
                ForEach(trading.practicePortfolios) { ledger in
                    Button {
                        opened = TradingRouter.Ref(id: ledger.id)
                    } label: {
                        PracticePortfolioCard(ledger: ledger)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityIdentifier("practice.portfolio.\(ledger.name)")
                }
            }

            if !agentBooks.isEmpty {
                let total = agentBooks.filter { $0.currency == "USD" }.reduce(0.0) { $0 + $1.equity }
                Button {
                    router.requestedTab = .agents
                } label: {
                    HStack {
                        Label("\(agentBooks.count) agent portfolio\(agentBooks.count == 1 ? "" : "s")", systemImage: "gearshape.2")
                        Spacer()
                        Text(TradingFormat.money(total, "USD")).monospacedDigit()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                    .font(.subheadline)
                    .foregroundStyle(theme.primaryText)
                    .frame(minHeight: 44)
                }
                .accessibilityHint("Opens the Agents tab")
            }
        }
        .sheet(isPresented: $showSetup) {
            NavigationStack {
                PracticeSetupView { _ in showSetup = false }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showSetup = false } } }
            }
        }
        .sheet(item: $opened) { ref in
            NavigationStack { PracticePortfolioDetailView(ledgerID: ref.id) }
        }
    }
}

struct PracticePortfolioCard: View {
    let ledger: Ledger
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text(ledger.name).font(.headline).foregroundStyle(theme.primaryText)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(theme.secondaryText)
            }
            Text(TradingFormat.money(ledger.equity, ledger.currency))
                .font(DS.money(28))
                .foregroundStyle(theme.primaryText)
                .contentTransition(.numericText())
            HStack(spacing: DS.Space.m) {
                GainLossText(value: ledger.totalReturn,
                             text: "\(TradingFormat.signedMoney(ledger.totalReturn, ledger.currency)) (\(TradingFormat.percent(ledger.totalReturnPct)))")
                Spacer()
                Text("\(TradingFormat.money(ledger.cash, ledger.currency)) cash")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - One practice portfolio

struct PracticePortfolioDetailView: View {
    let ledgerID: UUID

    @EnvironmentObject private var trading: TradingStore
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var ticket: TradingRouter.Ticket?
    @State private var showPicker = false
    @State private var showGuard = false
    @State private var confirmReset = false
    @State private var confirmDelete = false
    @State private var problem: String?
    @State private var openedOrder: TradingRouter.Ref?

    var body: some View {
        Group {
            if let ledger = trading.ledger(ledgerID) {
                content(ledger)
            } else {
                ContentUnavailableView("Portfolio removed", systemImage: "tray", description: Text("This practice portfolio no longer exists."))
            }
        }
        .background(theme.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Text(trading.ledger(ledgerID)?.name ?? "Practice").font(.headline)
                    PracticeChip(compact: true)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Reset to starting balance", systemImage: "arrow.counterclockwise") { confirmReset = true }
                    Button("Delete portfolio", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Portfolio options")
                .accessibilityIdentifier("practice.options")
            }
        }
        .sheet(item: $ticket) { OrderTicketView(instrument: $0.instrument, side: $0.side, ledgerID: $0.ledgerID) }
        .sheet(isPresented: $showPicker) {
            InstrumentPickerView(title: "What do you want to buy?", currency: trading.ledger(ledgerID)?.currency) { instrument in
                showPicker = false
                // Let the picker finish closing before the ticket opens.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    ticket = TradingRouter.Ticket(instrument: instrument, side: .buy, ledgerID: ledgerID)
                }
            }
        }
        .sheet(item: $openedOrder) { ref in NavigationStack { OrderDetailView(orderID: ref.id) } }
        .confirmationDialog("Reset this portfolio?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { attempt { try trading.resetPortfolio(ledgerID) } }
        } message: {
            Text("Positions and open orders are cleared and the cash goes back to the starting balance. The history stays in the audit trail.")
        }
        .confirmationDialog("Delete this portfolio?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                attempt { try trading.deletePortfolio(ledgerID) }
                if problem == nil { dismiss() }
            }
        } message: {
            Text("Its practice positions and cash are removed. The history stays in the audit trail.")
        }
        .alert("That didn't work", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
        .task { await trading.refreshPrices() }
    }

    private func attempt(_ work: () throws -> Void) {
        do { try work() } catch { problem = error.localizedDescription }
    }

    private func content(_ ledger: Ledger) -> some View {
        let openOrders = trading.orders(in: ledgerID).filter { $0.status.isOpen }
        let recent = Array(trading.orders(in: ledgerID).filter { !$0.status.isOpen }.prefix(8))
        return ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Text(TradingFormat.money(ledger.equity, ledger.currency))
                        .font(DS.money(36))
                        .contentTransition(.numericText())
                        .accessibilityIdentifier("practice.equity")
                    GainLossText(value: ledger.totalReturn,
                                 text: "\(TradingFormat.signedMoney(ledger.totalReturn, ledger.currency)) (\(TradingFormat.percent(ledger.totalReturnPct))) since start")
                    EquityCurveChart(points: ledger.equityHistory, currency: ledger.currency, height: 150)
                        .padding(.top, DS.Space.s)
                }

                VStack(spacing: DS.Space.m) {
                    TradingRow(label: "Cash", value: TradingFormat.money(ledger.cash, ledger.currency))
                    TradingRow(label: "Invested", value: TradingFormat.money(ledger.positionsValue, ledger.currency))
                    TradingRow(label: "Realised profit", value: TradingFormat.signedMoney(ledger.realizedPnL, ledger.currency))
                    TradingRow(label: "Fees paid", value: TradingFormat.money(ledger.feesPaid, ledger.currency))
                }
                .dsCard()

                Button("Buy something") { showPicker = true }
                    .buttonStyle(PrimaryPillButtonStyle())
                    .accessibilityIdentifier("practice.buy")

                TradingSection(title: "Positions", trailing: ledger.positions.isEmpty ? nil : "\(ledger.positions.count)") {
                    if ledger.positions.isEmpty {
                        Text("Nothing held yet. Buy something to open your first practice position.")
                            .font(.subheadline)
                            .foregroundStyle(theme.secondaryText)
                    } else {
                        ForEach(ledger.positions.sorted { $0.marketValue > $1.marketValue }) { position in
                            positionRow(position, ledger: ledger)
                            if position.id != ledger.positions.sorted(by: { $0.marketValue > $1.marketValue }).last?.id { Divider() }
                        }
                    }
                }

                if !openOrders.isEmpty {
                    TradingSection(title: "Open orders", trailing: "\(openOrders.count)") {
                        ForEach(openOrders) { order in
                            Button { openedOrder = TradingRouter.Ref(id: order.id) } label: { OrderRowView(order: order) }
                                .buttonStyle(PressableButtonStyle())
                        }
                    }
                }

                if !recent.isEmpty {
                    TradingSection(title: "Recent orders") {
                        ForEach(recent) { order in
                            Button { openedOrder = TradingRouter.Ref(id: order.id) } label: { OrderRowView(order: order) }
                                .buttonStyle(PressableButtonStyle())
                        }
                    }
                }

                guardCard(ledger)

                PracticeNote()
            }
            .padding(.horizontal, DS.Space.gutter)
            .padding(.vertical, DS.Space.l)
        }
        .refreshable { await trading.refreshPrices() }
        .accessibilityIdentifier("practice.detail")
    }

    private func positionRow(_ position: Position, ledger: Ledger) -> some View {
        Menu {
            Button("Buy more", systemImage: "plus.circle") {
                ticket = TradingRouter.Ticket(instrument: position.instrument, side: .buy, ledgerID: ledgerID)
            }
            Button("Sell", systemImage: "minus.circle") {
                ticket = TradingRouter.Ticket(instrument: position.instrument, side: .sell, ledgerID: ledgerID)
            }
        } label: {
            AdaptiveQuoteRow {
                InstrumentLabel(instrument: position.instrument,
                                subtitle: "\(TradingFormat.quantity(position.quantity, position.instrument)) at \(TradingFormat.price(position.averageCost, ledger.currency))")
            } numbers: { _ in
                VStack(alignment: .trailing, spacing: 3) {
                    Text(TradingFormat.money(position.marketValue, ledger.currency))
                        .font(.body.weight(.semibold).monospacedDigit())
                        .foregroundStyle(theme.primaryText)
                    GainLossText(value: position.unrealizedPnL,
                                 text: "\(TradingFormat.signedMoney(position.unrealizedPnL, ledger.currency)) (\(TradingFormat.percent(position.unrealizedPct)))",
                                 font: .caption.weight(.semibold).monospacedDigit())
                }
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("practice.position.\(position.instrument.symbol)")
    }

    @ViewBuilder
    private func guardCard(_ ledger: Ledger) -> some View {
        if let agent = trading.guardian(of: ledger.id) {
            TradingSection(title: "Guarded by an agent") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.name).font(.subheadline.weight(.semibold))
                        Text(agent.spec.ruleLines.joined(separator: " "))
                            .font(.footnote)
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    StatusLabel(systemImage: agent.statusGlyph, text: agent.statusText, compact: true)
                }
            }
        } else if !ledger.positions.isEmpty {
            Button {
                showGuard = true
            } label: {
                Label("Add a risk manager with stops", systemImage: "shield.lefthalf.filled")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(DS.accent)
                    .frame(minHeight: 44)
            }
            .accessibilityIdentifier("practice.addGuard")
            .confirmationDialog("Guard this portfolio?", isPresented: $showGuard, titleVisibility: .visible) {
                Button("Add risk manager") {
                    attempt {
                        var draft = AgentDraft(name: "Guard for \(ledger.name)".prefix(40).description, templateID: "riskManager",
                                               mode: .paper, spec: AgentTemplates.riskManager(), budget: ledger.equity,
                                               maxPositionPct: 100, author: .template)
                        draft.attachToLedgerID = ledger.id
                        try trading.createAgent(draft)
                    }
                }
            } message: {
                Text("An agent will watch these positions and sell one if it closes 8% below its cost, or 12% below its highest close. It never buys. These are practice orders.")
            }
        }
    }
}

// MARK: - Order row (shared with Activity)

/// One order in a list: what, status as a glyph and a word, who placed it, and the money.
struct OrderRowView: View {
    let order: Order
    @EnvironmentObject private var trading: TradingStore
    @Environment(\.theme) private var theme

    private var currency: String { order.instrument.currency }
    private var placedBy: String { trading.agent(order.source.agentID)?.name ?? (order.source.isAgent ? "An agent" : "You") }

    private var statusText: String {
        if order.status == .partiallyFilled, order.quantity > 0 {
            return "Partly filled \(Int((order.filledQuantity / order.quantity * 100).rounded()))%"
        }
        return order.status.displayName
    }

    private var tint: Color {
        switch order.status {
        case .rejected: return theme.negativeColor
        case .filled: return theme.positiveColor
        default: return theme.secondaryText
        }
    }

    var body: some View {
        let value = order.filledQuantity > 0 ? order.filledNotional : order.quantity * order.referencePrice
        AdaptiveQuoteRow {
            HStack(spacing: DS.Space.m) {
                TickerLogo(symbol: order.instrument.symbol, kind: order.instrument.assetClass == .crypto ? .crypto : .stock,
                           exchange: order.instrument.venue == .asx ? "ASX" : "", size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(order.side == .buy ? "Buy" : "Sell") \(order.instrument.symbol) · \(order.type.displayName)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        StatusLabel(systemImage: order.status.glyph, text: statusText, tint: tint, compact: true)
                        Text("· \(TradingFormat.time(order.updatedAt)) · \(placedBy)")
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                    }
                }
            }
        } numbers: { _ in
            VStack(alignment: .trailing, spacing: 3) {
                Text(TradingFormat.money(value, currency))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .strikethrough(order.status == .canceled || order.status == .rejected || order.status == .expired)
                    .foregroundStyle(order.status.isOpen || order.status == .filled ? theme.primaryText : theme.secondaryText)
                Text(TradingFormat.units(order.filledQuantity > 0 ? order.filledQuantity : order.quantity, order.instrument))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(order.side == .buy ? "Buy" : "Sell") \(order.instrument.name), \(order.type.displayName), \(statusText), \(TradingFormat.money(value, currency)), placed by \(placedBy), \(TradingFormat.time(order.updatedAt)), practice")
        .accessibilityIdentifier("order.row.\(order.instrument.symbol).\(order.status.rawValue)")
    }
}

// MARK: - Choosing an instrument

/// Pick something to trade or to add to an agent: what you follow first, then well-known
/// stocks, funds and coins. A ticker that isn't listed can be typed in; it is only accepted
/// once real prices come back for it.
struct InstrumentPickerView: View {
    var title: String = "Choose an asset"
    /// When set, only instruments that trade in this currency are offered.
    var currency: String? = nil
    var excluding: Set<String> = []
    let onPick: (Instrument) -> Void

    @EnvironmentObject private var marketData: MarketData
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var query = ""

    private var followed: [Instrument] {
        var seen = Set<String>()
        return (marketData.portfolio.map(\.asset) + marketData.watchlist)
            .compactMap(Instrument.init(asset:))
            .filter { seen.insert($0.id).inserted }
    }

    private func allowed(_ instrument: Instrument) -> Bool {
        (currency == nil || instrument.currency == currency) && !excluding.contains(instrument.id)
    }

    private func matches(_ instrument: Instrument) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || instrument.symbol.lowercased().hasPrefix(q) || instrument.name.lowercased().contains(q)
    }

    private var typedTicker: Instrument? {
        let symbol = query.trimmingCharacters(in: .whitespaces).uppercased()
        guard (1...6).contains(symbol.count), symbol.allSatisfy({ $0.isLetter || $0 == "." }),
              currency != "AUD" else { return nil }
        let known = (followed + UniverseCatalog.all).contains { $0.symbol == symbol }
        return known ? nil : .usStock(symbol)
    }

    var body: some View {
        let mine = followed.filter { allowed($0) && matches($0) }
        let mineIDs = Set(mine.map(\.id))
        let catalog = UniverseCatalog.all.filter { allowed($0) && matches($0) && !mineIDs.contains($0.id) }
        NavigationStack {
            List {
                if !mine.isEmpty {
                    Section("You follow") { ForEach(mine) { row($0) } }
                }
                if !catalog.isEmpty {
                    Section("Stocks, funds and crypto") { ForEach(catalog) { row($0) } }
                }
                if let typedTicker {
                    Section {
                        Button {
                            onPick(typedTicker)
                        } label: {
                            Label("Use \(typedTicker.symbol) as a US stock", systemImage: "plus.circle")
                        }
                        .accessibilityIdentifier("picker.typed")
                    } footer: {
                        Text("It's only used if real prices come back for it.")
                    }
                }
                if mine.isEmpty && catalog.isEmpty && typedTicker == nil {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name or ticker")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.characters)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .accessibilityIdentifier("instrument.picker")
    }

    private func row(_ instrument: Instrument) -> some View {
        Button {
            Haptics.select()
            onPick(instrument)
        } label: {
            HStack {
                InstrumentLabel(instrument: instrument)
                Spacer()
                Text(instrument.venue == .asx ? "ASX" : (instrument.assetClass == .crypto ? "Crypto" : (instrument.assetClass == .etf ? "ETF" : "US")))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .accessibilityIdentifier("picker.\(instrument.symbol)")
    }
}
