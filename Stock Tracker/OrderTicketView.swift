//
//  OrderTicketView.swift
//  Stock Tracker
//
//  Placing a paper order by hand, and the Buy / Sell / Create agent actions on
//  an asset's page.
//
//  The ticket never places anything on the first tap: you enter the order, see
//  a review with the estimated cost, fees, cash left and every risk check, and
//  only "Place practice order" submits it. What comes back is shown as it is —
//  filled, working, or refused with the reason.
//

import SwiftUI
import TradingCore

private struct TicketHistoryChart: View {
    let asset: Asset
    @EnvironmentObject private var marketData: MarketData
    @State private var range: TimeRange = .oneDay
    @State private var loadedRange: TimeRange?
    @State private var points: [DSChartPoint] = []
    @State private var phase: DSChartPhase = .loading
    @State private var retry = 0

    var body: some View {
        VStack(spacing: DS.Space.s) {
            DSPriceChart(
                points: loadedRange == range ? points : [],
                phase: loadedRange == range ? phase : .loading,
                height: 144,
                valueText: marketData.formatPrice,
                dateText: { range.scrubLabel(for: $0) },
                onRetry: { retry += 1 },
                accessibilityID: "ticket.chart"
            )
            DSRangePicker(options: [.oneDay, .oneWeek, .oneMonth, .threeMonths], selection: $range)
            Text("Chart in \(marketData.preferredCurrency)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: "\(range.rawValue):\(retry)") { await load() }
    }

    private func load() async {
        let requested = range
        phase = .loading
        do {
            let history = try await PriceHistoryService.shared.history(for: asset, range: requested, forceRefresh: retry > 0)
            guard !Task.isCancelled, range == requested else { return }
            points = history.chartPoints
            loadedRange = requested
            phase = .loaded
        } catch {
            guard !Task.isCancelled, range == requested else { return }
            points = []
            loadedRange = requested
            phase = .failed("Prices for this period couldn't be loaded.")
        }
    }
}

private struct TicketOrderBook: View {
    let instrument: Instrument
    @EnvironmentObject private var trading: TradingStore
    @Environment(\.theme) private var theme
    @State private var book: CryptoOrderBook?
    @State private var isLoading = true
    @State private var request = 0

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack {
                Text("Crypto order book").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    request += 1
                } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Refresh order book")
                .disabled(isLoading)
            }
            if let book {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: DS.Space.l) {
                        levels("Bids", book.bids, tint: theme.positiveColor)
                        levels("Asks", book.asks, tint: theme.negativeColor)
                    }
                    VStack(spacing: DS.Space.l) {
                        levels("Bids", book.bids, tint: theme.positiveColor)
                        levels("Asks", book.asks, tint: theme.negativeColor)
                    }
                }
                Text("Alpaca US snapshot · \(TradingFormat.time(book.time))")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            } else if isLoading {
                VStack(spacing: 0) {
                    ForEach(0..<4) { _ in DataRowSkeleton() }
                }
                .loadingSkeleton("Loading order book")
            } else {
                Text("The order book is unavailable from Alpaca US.")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .dsCard()
        .task(id: request) { await load() }
        .accessibilityIdentifier("ticket.orderBook")
    }

    private func levels(_ title: LocalizedStringKey, _ values: [CryptoOrderBook.Level], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(tint)
            if values.isEmpty {
                Text("No levels").font(.caption).foregroundStyle(theme.secondaryText)
            } else {
                ForEach(Array(values.enumerated()), id: \.offset) { _, level in
                    HStack {
                        Text(TradingFormat.price(level.price, instrument.currency))
                        Spacer(minLength: DS.Space.xs)
                        Text(TradingFormat.units(level.size, instrument)).foregroundStyle(theme.secondaryText)
                    }
                    .font(.caption.monospacedDigit())
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func load() async {
        isLoading = true
        book = nil
        let latest = try? await trading.cryptoOrderBook(for: instrument)
        guard !Task.isCancelled else { return }
        book = latest
        isLoading = false
    }
}

// MARK: - Ticket

struct OrderTicketView: View {
    let instrument: Instrument
    var ledgerID: UUID?

    @EnvironmentObject private var trading: TradingStore
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    enum Entry: String, CaseIterable, Identifiable {
        case amount, units
        var id: String { rawValue }
    }

    enum Step: Hashable {
        case review
        case done
    }

    @AppStorage("orderTicketAdvanced") private var isAdvanced = false
    @State private var side: OrderSide
    @State private var type: OrderType = .market
    @State private var timeInForce: TimeInForce = .day
    @State private var entry: Entry = .amount
    @State private var amountText = ""
    @State private var limitText = ""
    @State private var stopText = ""
    @State private var selectedLedgerID: UUID?
    @State private var isLoadingPrice = true
    @State private var priceProblem: String?
    @State private var showTypes = false
    @State private var path: [Step] = []
    @State private var result: OrderResult?
    @State private var isPlacing = false
    @State private var placeProblem: String?
    /// One key per order attempt, so a double tap can never place two orders.
    @State private var orderKey = UUID().uuidString
    @FocusState private var amountFocused: Bool

    init(instrument: Instrument, side: OrderSide, ledgerID: UUID? = nil) {
        self.instrument = instrument
        self.ledgerID = ledgerID
        _side = State(initialValue: side)
        _selectedLedgerID = State(initialValue: ledgerID)
    }

    // MARK: Derived

    private var currency: String { instrument.currency }
    /// Numeric tickers ("7203", "0700") read better as the company name.
    private var displayName: String { instrument.symbol.allSatisfy(\.isNumber) ? instrument.name : instrument.symbol }
    private var rules: InstrumentRules { PaperBroker.rules(for: instrument) }
    private var portfolios: [Ledger] { trading.practicePortfolios.filter { $0.currency == currency } }
    private var ledger: Ledger? {
        if let id = selectedLedgerID, let chosen = trading.ledger(id), chosen.currency == currency { return chosen }
        return portfolios.first
    }

    private var recentInstrumentOrders: [Order] {
        Array(trading.orders.lazy.filter {
            $0.instrument.id == instrument.id && $0.mode == .paper && $0.ledgerID == ledger?.id
        }.prefix(3))
    }
    private var quote: Quote? { trading.quote(instrument) }
    private var held: Double { ledger?.position(instrument.id)?.quantity ?? 0 }
    private var unitName: String { instrument.assetClass == .crypto ? instrument.symbol : "shares" }

    private func number(_ text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        guard let value = Double(cleaned), value.isFinite, value > 0 else { return nil }
        return value
    }

    /// The price an amount is converted to units at: the order's own price, else the market.
    private var referencePrice: Double? {
        switch type {
        case .limit, .stopLimit: return number(limitText)
        case .stop: return number(stopText)
        case .market:
            guard let quote else { return nil }
            return PaperBroker.executionPrice(side: side, quote: quote, instrument: instrument, config: trading.state.paperConfig).price
        }
    }

    private var request: OrderRequest? {
        guard let ledger, let value = number(amountText) else { return nil }
        var quantity: Double?
        var notional: Double?
        switch entry {
        case .units:
            quantity = value
        case .amount:
            if type == .market {
                notional = value
            } else if let price = referencePrice {
                quantity = Rounding.floor(value / price, increment: rules.quantityIncrement)
            } else {
                return nil
            }
        }
        if type.needsLimitPrice, number(limitText) == nil { return nil }
        if type.needsStopPrice, number(stopText) == nil { return nil }
        return OrderRequest(clientOrderID: orderKey, ledgerID: ledger.id, instrument: instrument, side: side, type: type,
                            quantity: quantity, notional: notional,
                            limitPrice: type.needsLimitPrice ? number(limitText) : nil,
                            stopPrice: type.needsStopPrice ? number(stopText) : nil,
                            timeInForce: type == .market && entry == .amount ? .day : timeInForce,
                            source: .manual, mode: .paper)
    }

    private var preview: OrderPreview? { request.flatMap { trading.preview($0) } }

    // MARK: Body

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if ledger == nil {
                    PracticeSetupView(currency: currency) { selectedLedgerID = $0.id }
                } else {
                    entryScreen
                }
            }
            .dsScreenBackground()
            .navigationTitle("\(side == .buy ? "Buy" : "Sell") \(displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("ticket.cancel")
                }
                ToolbarItem(placement: .topBarTrailing) { PracticeChip() }
            }
            .navigationDestination(for: Step.self) { step in
                switch step {
                case .review: reviewScreen
                case .done: resultScreen
                }
            }
        }
        .task { await loadPrice() }
        .sheet(isPresented: $showTypes) { typeSheet }
        .accessibilityIdentifier("ticket.screen")
    }

    private func loadPrice() async {
        isLoadingPrice = true
        priceProblem = await trading.prepare(instrument)
        isLoadingPrice = false
    }

    // MARK: Entry

    private var entryScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                priceHeader

                Picker("Side", selection: $side) {
                    Text("Buy").tag(OrderSide.buy)
                    Text("Sell").tag(OrderSide.sell)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("ticket.side")

                Picker("Trading layout", selection: $isAdvanced) {
                    Text("Simple").tag(false)
                    Text("Advanced").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("ticket.layout")

                if isAdvanced { advancedMarketCard }
                if portfolios.count > 1 { portfolioPicker }

                amountCard

                if type != .market { priceFields }

                summaryCard

                if isAdvanced && instrument.venue == .crypto {
                    TicketOrderBook(instrument: instrument)
                }
            }
            .padding(.horizontal, DS.Space.gutter)
            .padding(.top, DS.Space.m)
            .padding(.bottom, 120)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: DS.Space.s) {
                Button("Review order") {
                    amountFocused = false
                    Haptics.tap()
                    path.append(.review)
                }
                .buttonStyle(PrimaryPillButtonStyle())
                .disabled(preview == nil || isLoadingPrice || entryProblem != nil)
                .accessibilityHint(reviewHint)
                .accessibilityIdentifier("ticket.review")
            }
            .padding(.horizontal, DS.Space.gutter)
            .padding(.vertical, DS.Space.m)
        }
    }

    private var reviewHint: String {
        if isLoadingPrice { return "Getting the price" }
        if let entryProblem { return entryProblem }
        if preview == nil { return "Enter an amount first" }
        return "Shows the cost and checks before anything is placed"
    }

    private var priceHeader: some View {
        HStack(alignment: .center, spacing: DS.Space.m) {
            InstrumentLabel(instrument: instrument, logoSize: 44)
            Spacer(minLength: DS.Space.s)
            VStack(alignment: .trailing, spacing: 2) {
                if let quote {
                    Text(TradingFormat.price(quote.last, currency))
                        .font(DS.money(22))
                        .contentTransition(.numericText())
                        .accessibilityIdentifier("ticket.price")
                    Text("\(quote.provenance.source) · \(TradingFormat.time(quote.time))")
                        .font(.caption2)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                } else if isLoadingPrice {
                    VStack(alignment: .trailing, spacing: 4) {
                        SkeletonBlock(width: 80, height: 23)
                        SkeletonBlock(width: 65, height: 10)
                    }
                    .loadingSkeleton("Loading price")
                } else {
                    Button("Try again") { Task { await loadPrice() } }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DS.accent)
                }
            }
        }
    }

    private var portfolioPicker: some View {
        Menu {
            ForEach(portfolios) { portfolio in
                Button {
                    selectedLedgerID = portfolio.id
                } label: {
                    Text("\(portfolio.name) · \(TradingFormat.money(portfolio.cash, currency)) cash")
                }
            }
        } label: {
            HStack {
                Text("Portfolio").foregroundStyle(theme.secondaryText)
                Spacer()
                Text(ledger?.name ?? "").foregroundStyle(theme.primaryText)
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(theme.secondaryText)
            }
            .font(.subheadline)
            .frame(minHeight: 44)
        }
        .accessibilityIdentifier("ticket.portfolio")
    }

    private var amountCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack {
                Button {
                    showTypes = true
                } label: {
                    HStack(spacing: 4) {
                        Text(type.displayName)
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, DS.Space.m)
                    .frame(minHeight: 36)
                    .background(Capsule().fill(theme.subtleFill))
                    .overlay(Capsule().strokeBorder(theme.cardBorder, lineWidth: 0.5))
                }
                .foregroundStyle(theme.primaryText)
                .accessibilityLabel("Order type: \(type.displayName)")
                .accessibilityIdentifier("ticket.type")

                Spacer()

                Picker("Enter as", selection: $entry) {
                    Text(TradingFormat.symbol(currency).trimmingCharacters(in: .whitespaces)).tag(Entry.amount)
                    Text(instrument.assetClass == .crypto ? instrument.symbol : "Shares").tag(Entry.units)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 170)
                .accessibilityIdentifier("ticket.entry")
            }

            // The amount, big and centred (Coinbase / Revolut): the number is the screen.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Spacer(minLength: 0)
                if entry == .amount {
                    Text(TradingFormat.symbol(currency).trimmingCharacters(in: .whitespaces))
                        .font(DS.money(28, weight: .semibold))
                        .foregroundStyle(theme.secondaryText)
                }
                TextField("0", text: $amountText)
                    .keyboardType(.decimalPad)
                    .font(DS.money(58, weight: .bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: true, vertical: false)
                    .minimumScaleFactor(0.5)
                    .focused($amountFocused)
                    .accessibilityLabel(entry == .amount ? "Amount" : "Quantity")
                    .accessibilityIdentifier("ticket.amount")
                if entry == .units {
                    Text(unitName).font(DS.money(22, weight: .semibold)).foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, DS.Space.s)
            .contentShape(Rectangle())
            .onTapGesture { amountFocused = true }

            Text(conversionLine)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(theme.secondaryText)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("ticket.conversion")

            // Problems you can fix here show next to the number, before Review — not after it.
            if let problem = entryProblem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(theme.negativeColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ticket.problem")
            }

            if !rules.fractionable {
                Text(rules.quantityIncrement > 1
                     ? "\(instrument.venue.displayName.capitalizedFirstLetter) shares trade in lots of \(Int(rules.quantityIncrement))."
                     : "Whole shares only on the \(instrument.venue.displayName).")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .accessibilityIdentifier("ticket.lotNote")
            }

            quickChips
        }
        .dsCard()
        .onChange(of: entry) { _, _ in amountText = "" }
        .onChange(of: side) { _, _ in newAttempt() }
    }

    private var conversionLine: String {
        guard let preview, preview.estimatedPrice > 0 else {
            return side == .buy ? "Cash available: \(TradingFormat.money(ledger?.cash ?? 0, currency))"
                : "You hold \(TradingFormat.units(held, instrument))"
        }
        switch entry {
        case .amount:
            return "≈ \(TradingFormat.units(preview.quantity, instrument)) at \(TradingFormat.price(preview.estimatedPrice, currency))"
        case .units:
            return "≈ \(TradingFormat.money(preview.estimatedValue, currency)) at \(TradingFormat.price(preview.estimatedPrice, currency))"
        }
    }

    @ViewBuilder
    private var quickChips: some View {
        HStack(spacing: DS.Space.s) {
            if side == .buy, entry == .amount {
                ForEach(Currencies.balanceChoices(currency).prefix(3).map { $0 / 10 }, id: \.self) { value in
                    chip(TradingFormat.money(value, currency).replacingOccurrences(of: ".00", with: "")) {
                        amountText = String(format: "%.0f", value)
                    }
                }
            }
            if side == .sell, held > 0 {
                chip("Sell all") {
                    entry = .units
                    // Set after the entry-mode change has cleared the field.
                    DispatchQueue.main.async { amountText = TradingFormat.quantity(held, instrument) }
                }
                .accessibilityIdentifier("ticket.sellAll")
            }
        }
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.select()
            action()
        } label: {
            Text(title)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, DS.Space.m)
                .frame(minHeight: 32)
                .background(Capsule().fill(theme.subtleFill))
                .overlay(Capsule().strokeBorder(theme.cardBorder, lineWidth: 0.5))
        }
        .foregroundStyle(theme.primaryText)
    }

    private var advancedMarketCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text("Market quotes and history")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let quote, quote.hasTwoSidedMarket, let bid = quote.bid, let ask = quote.ask {
                TradingRow(label: "Best bid", value: TradingFormat.price(bid, currency))
                TradingRow(label: "Best ask", value: TradingFormat.price(ask, currency))
                TradingRow(label: "Spread", value: TradingFormat.price(ask - bid, currency))
            } else if isLoadingPrice {
                VStack {
                    DataRowSkeleton()
                    DataRowSkeleton()
                }
                .loadingSkeleton("Loading bid and ask")
            } else {
                Text("Bid and ask are unavailable from this price source.")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
            }
            TicketHistoryChart(asset: instrument.asAsset)
            TradingRow(label: "Position", value: TradingFormat.units(held, instrument))
            if let ledger {
                TradingRow(label: "Cash balance", value: TradingFormat.money(ledger.cash, currency))
            }
            if !recentInstrumentOrders.isEmpty {
                Divider()
                DisclosureGroup("Recent orders") {
                    ForEach(recentInstrumentOrders) { order in
                        TradingRow(label: "\(TradingFormat.orderTitle(order.type, order.side))",
                                   value: order.status.displayName)
                    }
                }
                .font(.subheadline)
                .accessibilityIdentifier("ticket.advanced.orders")
            }
        }
        .dsCard()
        .accessibilityIdentifier("ticket.advanced.market")
    }

    private var priceFields: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            if type.needsStopPrice {
                priceField("Stop price", text: $stopText, id: "ticket.stop",
                           hint: side == .buy ? "Triggers when the price rises to this." : "Triggers when the price falls to this.")
            }
            if type.needsLimitPrice {
                priceField("Limit price", text: $limitText, id: "ticket.limit",
                           hint: side == .buy ? "The most you'll pay per unit." : "The least you'll accept per unit.")
            }
            if isAdvanced || timeInForce != .day {
                Divider()
                Picker("Good for", selection: $timeInForce) {
                    ForEach(TimeInForce.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .font(.subheadline)
                .accessibilityIdentifier("ticket.tif")
            }
        }
        .dsCard()
    }

    private func priceField(_ title: LocalizedStringKey, text: Binding<String>, id: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline).foregroundStyle(theme.secondaryText)
                Spacer()
                TextField("0.00", text: text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(.body.weight(.semibold).monospacedDigit())
                    .frame(maxWidth: 150)
                    .accessibilityIdentifier(id)
            }
            Text(hint).font(.caption).foregroundStyle(theme.secondaryText)
        }
    }

    private var summaryCard: some View {
        VStack(spacing: DS.Space.m) {
            TradingRow(label: side == .buy ? "Estimated cost" : "Estimated proceeds",
                       value: preview.map { TradingFormat.money($0.estimatedValue, currency) } ?? "—", emphasised: true)
            TradingRow(label: "Estimated fee", value: preview.map { TradingFormat.money($0.estimatedFee, currency) } ?? "—")
            TradingRow(label: "Cash after", value: preview.map { TradingFormat.money($0.cashAfter, currency) }
                       ?? TradingFormat.money(ledger?.cash ?? 0, currency))
        }
        .dsCard()
        .accessibilityIdentifier("ticket.summary")
    }

    /// The first thing wrong with the order as typed, shown before Review rather than after.
    private var entryProblem: String? {
        if let priceProblem, quote == nil { return priceProblem }
        guard let preview else { return nil }
        // Only problems the person can fix here; the full list is on the review step.
        let fixable: Set<RiskCheckID> = [.buyingPower, .holdings, .exchangeRules, .currency, .marketData, .quoteFreshness]
        return preview.risk.failures.first { fixable.contains($0.id) }?.detail
    }

    private func newAttempt() {
        orderKey = UUID().uuidString
        result = nil
    }

    // MARK: Order types

    private var typeSheet: some View {
        NavigationStack {
            List {
                ForEach(isAdvanced ? OrderType.allCases : OrderType.allCases.filter { $0 == .market || $0 == .limit || $0 == type }, id: \.self) { option in
                    Button {
                        type = option
                        if option != .market, limitText.isEmpty, let quote { limitText = String(format: "%.2f", quote.last) }
                        showTypes = false
                    } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.displayName).font(.body.weight(.semibold)).foregroundStyle(theme.primaryText)
                                Text(Self.definition(option))
                                    .font(.footnote)
                                    .foregroundStyle(theme.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            if option == type { Image(systemName: "checkmark").foregroundStyle(DS.accent) }
                        }
                        .padding(.vertical, 4)
                    }
                    .accessibilityIdentifier("ticket.type.\(option.rawValue)")
                }
            }
            .navigationTitle("Order type")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showTypes = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    static func definition(_ type: OrderType) -> String {
        switch type {
        case .market: return "Trades now at the best available price. You choose an amount or a quantity."
        case .limit: return "Trades only at your price or better. It may take time, or never fill."
        case .stop: return "Waits until the price reaches your stop, then trades at the market price."
        case .stopLimit: return "Waits until the price reaches your stop, then trades only at your limit or better."
        }
    }

    // MARK: Review

    private var reviewScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                if let preview, let ledger {
                    Text(sentence(preview))
                        .font(DS.display(.title2))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("ticket.review.sentence")

                    VStack(spacing: DS.Space.m) {
                        TradingRow(label: "Account", value: TradingFormat.accountName(ledger.name))
                        TradingRow(label: "Order type", value: type.displayName)
                        if type != .market { TradingRow(label: "Good for", value: timeInForce.displayName) }
                        TradingRow(label: "Estimated price", value: TradingFormat.price(preview.estimatedPrice, currency))
                        TradingRow(label: "Estimated quantity", value: TradingFormat.units(preview.quantity, instrument))
                        TradingRow(label: "Estimated fee", value: TradingFormat.money(preview.estimatedFee, currency))
                        Divider()
                        TradingRow(label: side == .buy ? "Estimated total" : "Estimated proceeds",
                                   value: TradingFormat.money(side == .buy ? preview.estimatedValue + preview.estimatedFee
                                                              : preview.estimatedValue - preview.estimatedFee, currency),
                                   emphasised: true)
                        TradingRow(label: "Cash after", value: TradingFormat.money(preview.cashAfter, currency))
                    }
                    .dsCard()

                    if preview.willQueueUntilOpen, instrument.venue != .crypto {
                        note("clock", "The \(instrument.venue.displayName) is closed. This order waits and trades when it opens"
                             + (preview.nextOpen.map { " (\(TradingFormat.time($0)))" } ?? "") + ".")
                    }
                    if let taxNote = PaperBroker.taxNote(for: instrument, side: side) {
                        note("building.columns", taxNote)
                    }
                    if preview.usesModelledSpread, type == .market {
                        note("arrow.left.and.right", "The price feed has no bid and ask right now, so the fill uses the last price plus a small assumed spread.")
                    }

                    TradingSection(title: "Risk checks") { RiskReportView(report: preview.risk) }

                    PracticeNote()
                } else {
                    Text("This order can't be previewed. Go back and check the amount.")
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .padding(.horizontal, DS.Space.gutter)
            .padding(.top, DS.Space.m)
            .padding(.bottom, 120)
        }
        .dsScreenBackground()
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: DS.Space.s) {
                if let placeProblem {
                    Label(placeProblem, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(theme.negativeColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ticket.placeProblem")
                }
                Button(isPlacing ? "Placing…" : (preview?.willQueueUntilOpen == true && instrument.venue != .crypto ? "Queue practice order" : "Place practice order")) {
                    place()
                }
                .buttonStyle(PrimaryPillButtonStyle())
                .disabled(preview?.canSubmit != true || isPlacing)
            .accessibilityHint(preview?.canSubmit == true ? "Places a simulated order with practice money" : "A risk check is blocking this order")
                .accessibilityIdentifier("ticket.place")
            }
            .padding(.horizontal, DS.Space.gutter)
            .padding(.vertical, DS.Space.m)
        }
        .task {
            // Judge the order against a fresh price, not the one from when the ticket opened.
            await loadPrice()
        }
    }

    private func sentence(_ preview: OrderPreview) -> String {
        let verb = side == .buy ? "Buy" : "Sell"
        let what = entry == .amount && type == .market
            ? "\(TradingFormat.money(number(amountText) ?? preview.estimatedValue, currency)) of \(instrument.name)"
            : "\(TradingFormat.units(preview.quantity, instrument))"
        switch type {
        case .market: return "\(verb) \(what) at the market price."
        case .limit: return "\(verb) \(what) at \(TradingFormat.price(number(limitText) ?? 0, currency)) or better."
        case .stop: return "\(verb) \(what) at the market once the price reaches \(TradingFormat.price(number(stopText) ?? 0, currency))."
        case .stopLimit:
            return "\(verb) \(what) at \(TradingFormat.price(number(limitText) ?? 0, currency)) or better, once the price reaches \(TradingFormat.price(number(stopText) ?? 0, currency))."
        }
    }

    private func note(_ systemImage: String, _ text: String) -> some View {
        Label {
            Text(text).font(.footnote).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).font(.footnote)
        }
        .foregroundStyle(theme.primaryText)
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous).strokeBorder(theme.cardBorder, lineWidth: 1))
    }

    private func place() {
        guard let request, !isPlacing else { return }
        isPlacing = true
        placeProblem = nil
        Task {
            do {
                let outcome = try await trading.submit(request)
                result = outcome
                if outcome.isAccepted { Haptics.success() } else { Haptics.warning() }
                path.append(.done)
            } catch {
                // Not sent, or the answer was lost: the order key stays the same, so trying
                // again can't place it twice.
                placeProblem = error.localizedDescription
                Haptics.warning()
            }
            isPlacing = false
        }
    }

    // MARK: Result

    private var resultScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                if let result {
                    let order = result.order.flatMap { trading.order($0.id) } ?? result.order
                    resultHeader(result, order)
                    if let order {
                        VStack(spacing: DS.Space.m) {
                            TradingRow(label: "Status", value: order.status.displayName)
                            if order.filledQuantity > 0 {
                                TradingRow(label: "Filled", value: TradingFormat.units(order.filledQuantity, instrument))
                                TradingRow(label: "Average price", value: TradingFormat.price(order.averageFillPrice, currency))
                                TradingRow(label: "Fees", value: TradingFormat.money(order.fees, currency))
                            }
                            if let note = order.statusNote { TradingRow(label: "Note", value: note) }
                            if let ledger { TradingRow(label: "Cash now", value: TradingFormat.money(trading.ledger(ledger.id)?.cash ?? ledger.cash, currency)) }
                        }
                        .dsCard()
                    }
                    if !result.isAccepted {
                        TradingSection(title: "Why it was refused") { RiskReportView(report: result.risk) }
                    }
                    PracticeNote()
                }
            }
            .padding(.horizontal, DS.Space.gutter)
            .padding(.top, DS.Space.xl)
            .padding(.bottom, 120)
        }
        .dsScreenBackground()
        .navigationBarBackButtonHidden(true)
        .navigationTitle("")
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: DS.Space.s) {
                Button("Done") { dismiss() }
                    .buttonStyle(PrimaryPillButtonStyle())
                    .accessibilityIdentifier("ticket.done")
                if result?.isAccepted == false {
                    Button("Change the order") {
                        newAttempt()
                        path.removeAll()
                    }
                    .buttonStyle(QuietTextButtonStyle())
                }
            }
            .padding(.horizontal, DS.Space.gutter)
            .padding(.vertical, DS.Space.m)
        }
    }

    private func resultHeader(_ result: OrderResult, _ order: Order?) -> some View {
        let status = order?.status
        let title: String
        let detail: String
        let glyph: String
        let tint: Color
        if !result.isAccepted {
            title = "Order not placed"
            detail = result.risk.summary
            glyph = "xmark.octagon.fill"
            tint = theme.negativeColor
        } else if status == .filled, let order {
            title = "Practice order filled"
            detail = "\(side == .buy ? "Bought" : "Sold") \(TradingFormat.units(order.filledQuantity, instrument)) at \(TradingFormat.price(order.averageFillPrice, currency))."
            glyph = "checkmark.circle.fill"
            tint = theme.positiveColor
        } else if status == .partiallyFilled {
            title = "Practice order partly filled"
            detail = "The rest is still working and will fill as prices update."
            glyph = "circle.lefthalf.filled"
            tint = theme.primaryText
        } else if status == .canceled {
            title = "Order cancelled"
            detail = order?.statusNote ?? "The order was cancelled before it could trade."
            glyph = "slash.circle"
            tint = theme.secondaryText
        } else {
            title = "Practice order placed"
            detail = order?.statusNote ?? "It is working and will trade when its price is available. Nothing has been bought or sold yet."
            glyph = "clock"
            tint = theme.primaryText
        }
        return VStack(spacing: DS.Space.m) {
            Group {
                if result.isAccepted && status == .filled {
                    CelebrationCheck(trigger: true, size: 72, foreground: theme.background, background: tint)
                } else {
                    Image(systemName: glyph)
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 72, height: 72)
                        .glassEffect(.regular.tint(tint.opacity(0.18)), in: .circle)
                }
            }
            .frame(height: 92)
            .padding(.bottom, DS.Space.s)
            .accessibilityHidden(true)
            Text(title).font(DS.display(.title)).multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("ticket.result.title")
            Text(detail).font(.body).foregroundStyle(theme.secondaryText).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ticket.result.detail")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Space.l)
    }
}

// MARK: - Practice setup

/// The one-time explanation of practice money, and the choice of a starting balance.
struct PracticeSetupView: View {
    var onCreated: (Ledger) -> Void = { _ in }
    /// Offer a choice of currency (from the Portfolio tab). From an order ticket the currency
    /// is fixed by what is being bought.
    var allowsCurrencyChoice = false

    @EnvironmentObject private var trading: TradingStore
    @Environment(\.theme) private var theme
    @State private var currency: String
    @State private var chosenBalance: Double?
    @State private var problem: String?

    init(currency: String = "USD", allowsCurrencyChoice: Bool = false, onCreated: @escaping (Ledger) -> Void = { _ in }) {
        _currency = State(initialValue: currency)
        self.allowsCurrencyChoice = allowsCurrencyChoice
        self.onCreated = onCreated
    }

    private var choices: [Double] { Currencies.balanceChoices(currency) }
    private var balance: Double { chosenBalance.flatMap { choices.contains($0) ? $0 : nil } ?? choices[1] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    PracticeChip()
                    Text("Start with practice money")
                        .font(DS.display(.largeTitle))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(currency == "USD"
                         ? "Practice trading uses pretend money against real, live prices. No real order is ever sent, and nothing you do here touches a bank or a broker."
                         : "These shares trade in \(currency), so they're bought from a practice portfolio held in \(currency). Prices are real but delayed. No real order is ever sent.")
                        .font(.body)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if allowsCurrencyChoice {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        Text("Currency").font(.headline)
                        Picker("Currency", selection: $currency) {
                            ForEach(Currencies.supported, id: \.self) { code in
                                Text("\(code) · \(Self.markets(for: code))").tag(code)
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("practice.currency")
                        Text("A practice portfolio holds one currency and trades the markets that use it.")
                            .font(.footnote)
                            .foregroundStyle(theme.secondaryText)
                    }
                }

                VStack(alignment: .leading, spacing: DS.Space.m) {
                    Text(currency == "USD" ? "Starting balance" : "Starting balance in \(currency)").font(.headline)
                    ForEach(choices, id: \.self) { choice in
                        Button {
                            Haptics.select()
                            chosenBalance = choice
                        } label: {
                            HStack {
                                Text(TradingFormat.money(choice, currency)).font(DS.money(18))
                                Spacer()
                                Image(systemName: balance == choice ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(balance == choice ? DS.accent : theme.secondaryText)
                            }
                            .padding(.horizontal, DS.Space.l)
                            .frame(minHeight: 52)
                            .background(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous).fill(theme.subtleFill))
                            .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                                .strokeBorder(balance == choice ? DS.accent : theme.cardBorder, lineWidth: balance == choice ? 1.5 : 0.5))
                        }
                        .foregroundStyle(theme.primaryText)
                        .accessibilityAddTraits(balance == choice ? .isSelected : [])
                        .accessibilityIdentifier("practice.balance.\(Int(choice))")
                    }
                    Text("You can reset it or add another practice portfolio any time.")
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryText)
                }

                if let problem {
                    Text(problem).font(.footnote).foregroundStyle(theme.negativeColor)
                }

                Button("Start practising") {
                    let name = trading.practicePortfolios.isEmpty ? "Practice" : "Practice \(trading.practicePortfolios.count + 1)"
                    Task {
                        do {
                            let ledger = try await trading.createPortfolio(name: currency == "USD" ? name : "\(name) (\(currency))",
                                                                           startingCash: balance, currency: currency)
                            Haptics.success()
                            onCreated(ledger)
                        } catch {
                            problem = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(PrimaryPillButtonStyle())
                .accessibilityIdentifier("practice.start")
            }
            .padding(.horizontal, DS.Space.gutter)
            .padding(.vertical, DS.Space.xl)
        }
        .dsScreenBackground()
        .accessibilityIdentifier("practice.setup")
    }
}

extension PracticeSetupView {
    /// "London", "Frankfurt, Paris, Amsterdam" — the markets a currency trades on here.
    static func markets(for currency: String) -> String {
        let names = Venue.allCases.filter { $0.currency == currency && $0 != .crypto }.map(\.country)
        if currency == "USD" { return "US stocks and crypto" }
        return names.isEmpty ? currency : names.joined(separator: ", ")
    }
}

// MARK: - Asset page actions

/// Buy, Sell and Create agent for one asset. The asset's page is itself a sheet, so this
/// presents its own sheets rather than asking the root.
struct AssetTradeBar: View {
    let asset: Asset

    @ObservedObject private var trading = TradingStore.shared
    @Environment(\.theme) private var theme
    @State private var ticketSide: OrderSide?
    @State private var showNewAgent = false

    private var instrument: Instrument? { Instrument(asset: asset) }

    var body: some View {
        if let instrument {
            let held = trading.practicePortfolios.reduce(0.0) { $0 + ($1.position(instrument.id)?.quantity ?? 0) }
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(spacing: DS.Space.s) {
                    Text("Practice trading").font(.subheadline.weight(.semibold))
                    PracticeChip(compact: true)
                    Spacer()
                    if held > 0 {
                        Text("You hold \(TradingFormat.units(held, instrument))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                HStack(spacing: DS.Space.m) {
                    Button("Buy") { ticketSide = .buy }
                        .buttonStyle(PrimaryPillButtonStyle())
                        .accessibilityIdentifier("detail.trade.buy")
                    Button("Sell") { ticketSide = .sell }
                        .buttonStyle(SecondaryPillButtonStyle())
                        .disabled(held <= 0)
                        .opacity(held <= 0 ? 0.45 : 1)
                        .accessibilityHint(held <= 0 ? "You don't hold any in a practice portfolio" : "")
                        .accessibilityIdentifier("detail.trade.sell")
                }
                Button {
                    showNewAgent = true
                } label: {
                    Label("Create an agent for \(instrument.symbol)", systemImage: "gearshape.2")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(DS.accent)
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("detail.trade.createAgent")
            }
            .dsCard()
            .accessibilityIdentifier("detail.tradeBar")
            .sheet(item: Binding(get: { ticketSide.map(SideBox.init) }, set: { ticketSide = $0?.side })) { box in
                OrderTicketView(instrument: instrument, side: box.side)
                    .environmentObject(trading)
                    .environmentObject(TradingRouter.shared)
            }
            .sheet(isPresented: $showNewAgent) {
                CreateAgentFlow(prefill: instrument)
                    .environmentObject(trading)
                    .environmentObject(TradingRouter.shared)
            }
        }
    }

    private struct SideBox: Identifiable {
        let side: OrderSide
        var id: String { side.rawValue }
    }
}

private extension String {
    var capitalizedFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}
