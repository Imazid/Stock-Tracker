//
//  PortfolioAddFlow.swift
//  Stock Tracker
//
//  The one way to add a holding (after Origin / Monarch / Quicken on Mobbin):
//    search US + ASX stocks, ETFs and crypto → asset card with the latest price
//    → quantity, price paid (in the asset's own currency) and date → Add.
//  Footer rows lead to broker connect, CSV import (Black) and manual entry.
//
//  `HoldingFormView` is shared by the flow, `AddToPortfolioSheet` (watchlist,
//  stock pages) and `ManualPositionSheet` (onboarding, Home). It saves through
//  `MarketData.addHolding`, which enforces the plan limit and stores USD.
//

import SwiftUI

// MARK: - Search model

struct AddSearchItem: Identifiable, Hashable {
    let symbol: String
    let name: String
    let kind: AssetKind
    /// "ASX", "US" or "Crypto".
    let market: String
    /// CoinGecko id for crypto, ticker for stocks.
    let lookupID: String

    var id: String { "\(market)-\(symbol)-\(lookupID)" }
}

enum HoldingLookup {
    /// US + ASX stocks and ETFs from Yahoo (other markets can't be priced here). nil = search failed.
    static func searchStocks(_ query: String) async -> [AddSearchItem]? {
        guard let results = try? await APIService.shared.fetchSymbolSearch(query: query, kind: .stock) else { return nil }
        var seen = Set<String>()
        let items: [AddSearchItem] = results.compactMap { r in
            let isASX = r.exchange == "ASX"
            guard isASX || r.currency.uppercased() == "USD", !r.symbol.contains(".") else { return nil }
            let item = AddSearchItem(symbol: r.symbol.uppercased(), name: r.name, kind: .stock,
                                     market: isASX ? "ASX" : "US", lookupID: r.symbol.uppercased())
            return seen.insert(item.id).inserted ? item : nil
        }
        return rank(items, for: query)
    }

    /// Crypto is matched locally against the coins the app can price (the same list as
    /// the Search tab, `SymbolSearchModel.supportedCoins`). CoinGecko's keyless search
    /// rate-limits within a few calls and returns thousands of coins we can't quote, so
    /// it made the add flow say "Crypto search isn't available" for no good reason.
    static func searchCrypto(_ query: String) async -> [AddSearchItem]? {
        let q = query.lowercased()
        let items = SymbolSearchModel.supportedCoins
            .filter { $0.symbol.lowercased().hasPrefix(q) || $0.name.lowercased().hasPrefix(q) || $0.coinID.hasPrefix(q) }
            .map { AddSearchItem(symbol: $0.symbol, name: $0.name, kind: .crypto, market: "Crypto", lookupID: $0.coinID) }
        return rank(items, for: query)
    }

    /// Exact ticker matches first, otherwise the provider's order.
    nonisolated private static func rank(_ items: [AddSearchItem], for query: String) -> [AddSearchItem] {
        let upper = query.uppercased()
        return items.enumerated().sorted { a, b in
            let ea = a.element.symbol == upper, eb = b.element.symbol == upper
            return ea != eb ? ea : a.offset < b.offset
        }.map(\.element)
    }

    /// Live quote for a search result. Falls back to an unpriced asset (price 0)
    /// so the person can still add it; it shows "No live price" until a quote lands.
    static func resolve(_ item: AddSearchItem) async -> Asset {
        let api = APIService.shared
        switch item.kind {
        case .crypto:
            if let quote = try? await api.fetchCryptoPrice(id: item.lookupID) {
                return Asset(symbol: item.symbol, name: item.name, price: quote.price, change: quote.change,
                             changePercent: quote.changePercent, volume: quote.volume, kind: .crypto, exchange: "Crypto")
            }
        case .stock:
            if item.market == "ASX" {
                if let quote = try? await api.fetchYahooQuote(symbol: item.symbol + ".AX", name: item.name) {
                    return quote.with(name: item.name, exchange: "ASX")
                }
            } else if let quote = try? await api.fetchStockQuote(symbol: item.symbol) {
                return quote.with(name: item.name, exchange: "US")
            }
        }
        return Asset(symbol: item.symbol, name: item.name, price: 0, change: 0, changePercent: 0, volume: 0,
                     kind: item.kind, exchange: item.kind == .crypto ? "Crypto" : (item.market == "ASX" ? "ASX" : "US"))
    }
}

// MARK: - Add flow

struct AddHoldingFlow: View {
    var onAdded: (String) -> Void = { _ in }

    @EnvironmentObject private var marketData: MarketData
    @EnvironmentObject private var subscriptionManager: SubscriptionManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var query = ""
    @State private var stocks: [AddSearchItem] = []
    @State private var crypto: [AddSearchItem] = []
    @State private var stockState: SearchState = .idle
    @State private var cryptoState: SearchState = .idle
    @State private var resolving: String?
    @State private var path: [AddRoute] = []
    @State private var sub: SubSheet?
    @FocusState private var searchFocused: Bool

    enum AddRoute: Hashable { case asset(Asset), manual }
    enum SearchState { case idle, searching, done, failed }

    private var isSearching: Bool { stockState == .searching || cryptoState == .searching }
    enum SubSheet: String, Identifiable { case broker, csv, paywall; var id: String { rawValue } }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                searchField.portfolioRow(top: DS.Space.s, bottom: DS.Space.m)

                if trimmedQuery.isEmpty {
                    suggestions
                } else {
                    results
                }

                otherWays
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .dsScreenBackground()
            .navigationTitle("Add a holding")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .navigationDestination(for: AddRoute.self) { route in
                switch route {
                case .asset(let asset):
                    HoldingFormView(initialAsset: asset, onAdded: finish)
                        .navigationTitle("Add \(asset.symbol)")
                case .manual:
                    HoldingFormView(initialAsset: nil, onAdded: finish)
                        .navigationTitle("Enter manually")
                }
            }
            .task(id: trimmedQuery) { await search() }
            .onAppear { searchFocused = true }
        }
        .sheet(item: $sub) { item in
            switch item {
            case .broker:  SnapTradeConnectionView()
            case .csv:     CSVImportSheet()
            case .paywall: PaywallView(requiredTier: .black, featureName: "CSV import")
            }
        }
    }

    private func finish(_ symbol: String) {
        onAdded(symbol)
        dismiss()
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(theme.secondaryText)
            TextField("Search stocks, ETFs or crypto", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
                .accessibilityIdentifier("add.search")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, DS.Space.m)
        .frame(minHeight: 48)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.subtleFill))
    }

    private func search() async {
        let q = trimmedQuery
        guard !q.isEmpty else {
            stockState = .idle; cryptoState = .idle; stocks = []; crypto = []
            return
        }
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard !Task.isCancelled else { return }
        stockState = .searching
        cryptoState = .searching
        stocks = []
        crypto = []
        // Show each list as soon as it arrives.
        await withTaskGroup(of: (AssetKind, [AddSearchItem]?).self) { group in
            group.addTask { (.stock, await HoldingLookup.searchStocks(q)) }
            group.addTask { (.crypto, await HoldingLookup.searchCrypto(q)) }
            for await (kind, items) in group {
                guard !Task.isCancelled else { return }
                if kind == .stock {
                    stocks = items ?? []
                    stockState = items == nil ? .failed : .done
                } else {
                    crypto = items ?? []
                    cryptoState = items == nil ? .failed : .done
                }
            }
        }
    }

    @ViewBuilder
    private var suggestions: some View {
        let watch = marketData.watchlist.filter { $0.price > 0 }
        if !watch.isEmpty {
            sectionTitle("From your watchlist")
            ForEach(watch) { asset in
                Button {
                    Haptics.tap()
                    path.append(.asset(asset))
                } label: {
                    resultLabel(symbol: asset.symbol, name: asset.name, kind: asset.kind, market: asset.marketLabel,
                                trailing: marketData.formatPrice(asset.price), busy: false)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("add.watchlist.\(asset.symbol)")
                .addRowStyle(theme)
            }
        }
    }

    @ViewBuilder
    private var results: some View {
        if stockState == .failed && cryptoState == .failed {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text("Search isn't available right now.")
                    .font(.subheadline.weight(.semibold))
                Text("Check your connection, or enter the holding manually below.")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
                Button("Try again") { Task { await search() } }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.accent)
                    .frame(minHeight: 44)
            }
            .portfolioRow(bottom: DS.Space.m)
            .accessibilityIdentifier("add.search.failed")
        } else {
            if !stocks.isEmpty {
                sectionTitle("Stocks & ETFs")
                ForEach(stocks) { resultRow($0) }
            }
            if !crypto.isEmpty {
                sectionTitle("Crypto")
                ForEach(crypto) { resultRow($0) }
            }
            if isSearching || stockState == .idle {
                VStack(spacing: 0) {
                    ForEach(0..<(stocks.isEmpty && crypto.isEmpty ? 3 : 1)) { _ in SearchRowSkeleton() }
                }
                .loadingSkeleton("Searching for holdings")
                .portfolioRow()
            } else if stocks.isEmpty && crypto.isEmpty {
                Text("No matches for “\(trimmedQuery)”. Check the ticker, or enter it manually below.")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .portfolioRow(bottom: DS.Space.m)
                    .accessibilityIdentifier("add.search.empty")
            }
            if cryptoState == .failed && stockState != .failed {
                Text("Crypto search isn't available right now — try again in a minute.")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .portfolioRow(top: DS.Space.s)
            }
        }
    }

    private func resultRow(_ item: AddSearchItem) -> some View {
        let owned = marketData.portfolio.contains {
            $0.asset.symbol == item.symbol && $0.asset.kind == item.kind && $0.asset.marketLabel == item.market
        }
        return Button {
            guard resolving == nil else { return }
            Haptics.tap()
            resolving = item.id
            Task {
                let asset = await HoldingLookup.resolve(item)
                resolving = nil
                path.append(.asset(asset))
            }
        } label: {
            resultLabel(symbol: item.symbol, name: item.name, kind: item.kind, market: item.market,
                        trailing: owned ? "Owned" : nil, busy: resolving == item.id)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("add.result.\(item.market).\(item.symbol)")
        .addRowStyle(theme)
    }

    private func resultLabel(symbol: String, name: String, kind: AssetKind, market: String, trailing: String?, busy: Bool) -> some View {
        HStack(spacing: DS.Space.m) {
            TickerLogo(symbol: symbol, kind: kind, exchange: market == "ASX" ? "ASX" : "", size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(symbol)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                    MarketBadge(text: market)
                }
                Text(name)
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: DS.Space.s)
            if busy {
                SkeletonBlock(width: 56, height: 14)
                    .loadingSkeleton("Loading quote")
            } else if let trailing {
                Text(trailing)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.secondaryText.opacity(0.6))
        }
        .padding(.vertical, DS.Space.s)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    // MARK: Other ways

    @ViewBuilder
    private var otherWays: some View {
        sectionTitle("Other ways to add")
        wayRow(icon: "link", title: "Connect a broker or exchange", detail: "Read-only sync with CommSec, IBKR, Coinbase and more", id: "add.broker") {
            sub = .broker
        }
        wayRow(icon: "doc.text", title: "Import a CSV file",
               detail: subscriptionManager.currentTier == .black ? "Symbol, quantity and cost columns" : "Available on Black", id: "add.csv") {
            sub = subscriptionManager.currentTier == .black ? .csv : .paywall
        }
        wayRow(icon: "pencil", title: "Enter details manually", detail: "For anything search can't find", id: "add.manual") {
            path.append(.manual)
        }
        Color.clear.frame(height: DS.Space.xxl).portfolioRow()
    }

    private func wayRow(icon: String, title: String, detail: String, id: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: DS.Space.m) {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(DS.accent)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(DS.accent.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(theme.primaryText)
                    Text(detail).font(.footnote).foregroundStyle(theme.secondaryText).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.secondaryText.opacity(0.6))
            }
            .padding(.vertical, DS.Space.s)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .addRowStyle(theme)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(theme.secondaryText)
            .textCase(.uppercase)
            .accessibilityAddTraits(.isHeader)
            .portfolioRow(top: DS.Space.l, bottom: DS.Space.xs)
    }
}

private extension View {
    func addRowStyle(_ theme: Theme) -> some View {
        self
            .listRowInsets(EdgeInsets(top: 0, leading: DS.Space.l, bottom: 0, trailing: DS.Space.l))
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(theme.cardBorder.opacity(0.6))
            .alignmentGuide(.listRowSeparatorLeading) { _ in 48 }
    }
}

// MARK: - Holding form

/// Quantity, price paid (in the asset's trading currency) and purchase date.
/// With `initialAsset` nil it also asks for type, market, ticker and name.
struct HoldingFormView: View {
    let initialAsset: Asset?
    var onAdded: (String) -> Void

    @EnvironmentObject private var marketData: MarketData
    @EnvironmentObject private var subscriptionManager: SubscriptionManager
    @Environment(\.theme) private var theme

    @State private var kind: AssetKind
    @State private var market: Market = .us
    @State private var symbol: String
    @State private var name: String
    @State private var quantityText = ""
    @State private var costText: String
    @State private var feesText = ""
    @State private var date = Date()
    @State private var errorText: String?
    @State private var showPaywall = false
    @State private var didAutofocus = false
    @FocusState private var focus: Field?

    enum Market: String, CaseIterable { case us, asx }
    enum Field { case symbol, name, quantity, cost, fees }

    init(initialAsset: Asset?, initialKind: AssetKind = .stock, onAdded: @escaping (String) -> Void) {
        self.initialAsset = initialAsset
        self.onAdded = onAdded
        _kind = State(initialValue: initialAsset?.kind ?? initialKind)
        _symbol = State(initialValue: initialAsset?.symbol ?? "")
        _name = State(initialValue: initialAsset?.name ?? "")
        if let a = initialAsset, a.price > 0 {
            let p = a.toTradingCurrency(a.price)
            _costText = State(initialValue: String(format: p < 1 ? "%.6f" : "%.2f", p))
        } else {
            _costText = State(initialValue: "")
        }
    }

    // MARK: Draft

    private var draftKind: AssetKind { initialAsset?.kind ?? kind }

    private var draftSymbol: String {
        var s = (initialAsset?.symbol ?? symbol).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasSuffix(".AX") { s.removeLast(3) }
        return s
    }

    private var draftIsASX: Bool {
        if let a = initialAsset { return a.isASX }
        return kind == .stock && (market == .asx || symbol.uppercased().hasSuffix(".AX"))
    }

    private var currencySymbol: String { draftIsASX ? "A$" : "US$" }
    private var currency: String { draftIsASX ? "AUD" : "USD" }
    private var quantity: Double? { parseDecimal(quantityText) }
    private var cost: Double? { parseDecimal(costText) }
    private var fees: Double? { feesText.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : parseDecimal(feesText) }
    private var livePrice: Double? { (initialAsset?.price ?? 0) > 0 ? initialAsset!.price : nil }
    private var unit: String { draftKind == .crypto ? "coin" : "share" }

    private var canAddMore: Bool { marketData.canAddHolding(symbol: draftSymbol, kind: draftKind) }

    private var canSubmit: Bool {
        !draftSymbol.isEmpty && (quantity ?? 0) > 0 && (costText.isEmpty || (cost ?? -1) >= 0) && (fees ?? -1) >= 0
    }

    private var nextTier: SubscriptionTier { subscriptionManager.currentTier == .free ? .pro : .black }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                if !canAddMore {
                    Label("You're at your plan's holding limit. You can still add to holdings you already own.",
                          systemImage: "lock")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(theme.secondaryText)
                        .accessibilityIdentifier("holding.form.limit")
                }
                if let asset = initialAsset {
                    assetCard(asset)
                } else {
                    manualFields
                }

                FormField(label: draftKind == .crypto ? "Quantity" : "Number of shares") {
                    TextField("0.00", text: $quantityText)
                        .keyboardType(.decimalPad)
                        .focused($focus, equals: .quantity)
                }

                VStack(alignment: .leading, spacing: 6) {
                    FormField(label: "Price paid per \(unit) (\(currencySymbol))",
                              trailing: livePrice != nil ? AnyView(
                                Button("Use latest") {
                                    if let a = initialAsset {
                                        let p = a.toTradingCurrency(a.price)
                                        costText = String(format: p < 1 ? "%.6f" : "%.2f", p)
                                    }
                                }
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(DS.accent)) : nil) {
                        HStack(spacing: 4) {
                            Text(currencySymbol).foregroundStyle(theme.secondaryText)
                            TextField("0.00", text: $costText)
                                .keyboardType(.decimalPad)
                                .focused($focus, equals: .cost)
                        }
                    }
                    Text("Your average price per \(unit), as on your broker statement. Leave it blank if you're not sure — total return won't be shown for this holding.")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                FormField(label: "Brokerage fees (\(currencySymbol), optional)") {
                    TextField("0.00", text: $feesText)
                        .keyboardType(.decimalPad)
                        .focused($focus, equals: .fees)
                        .accessibilityIdentifier("holding.form.fees")
                }

                DatePicker("Purchase date", selection: $date, in: ...Date(), displayedComponents: .date)
                    .font(.subheadline)
                    .frame(minHeight: 44)

                summary

                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.circle")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(theme.negativeColor)
                }

                submitSection
            }
            .padding(DS.Space.gutter)
        }
        .dsScreenBackground()
        .toolbar {
            // The decimal pad has no return key: a Done in the bar puts the keyboard away.
            ToolbarItem(placement: .confirmationAction) {
                if focus != nil {
                    Button("Done") { focus = nil }
                        .accessibilityIdentifier("keyboard.done")
                }
            }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(requiredTier: nextTier, featureName: "More holdings")
        }
        .task {
            // Autofocus the ticker once, and never steal focus from a field the person chose.
            guard initialAsset == nil, !didAutofocus else { return }
            didAutofocus = true
            try? await Task.sleep(nanoseconds: 350_000_000)
            if focus == nil { focus = .symbol }
        }
    }

    @ViewBuilder
    private var submitSection: some View {
        VStack(spacing: DS.Space.s) {
            if canAddMore {
                Button("Add to Portfolio", action: submit)
                    .buttonStyle(PrimaryPillButtonStyle())
                    .disabled(!canSubmit)
            } else {
                Text("Your \(subscriptionManager.currentTier.rawValue) plan includes \(FeatureGate.maxPortfolioHoldings(for: subscriptionManager.currentTier) ?? marketData.portfolio.count) holdings. Upgrade to track more.")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                Button("See plans") { showPaywall = true }
                    .buttonStyle(PrimaryPillButtonStyle())
                    .accessibilityIdentifier("holding.form.upgrade")
            }
        }
        .padding(.top, DS.Space.s)
    }

    private func assetCard(_ asset: Asset) -> some View {
        HStack(spacing: DS.Space.m) {
            TickerLogo(symbol: asset.symbol, kind: asset.kind, exchange: asset.exchange, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(asset.symbol).font(.headline)
                    MarketBadge(text: asset.marketLabel)
                }
                Text(asset.name)
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if asset.price > 0 {
                    Text(asset.formatTrading(asset.toTradingCurrency(asset.price)))
                        .font(.headline.monospacedDigit())
                    Text("Latest price")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                } else {
                    Text("No live price")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(theme.warningColor)
                }
            }
        }
        .dsCard()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("holding.form.asset")
    }

    private var manualFields: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            DSSegmentBar(options: [AssetKind.stock, .crypto], selection: $kind,
                         title: { $0 == .stock ? "Stock / ETF" : "Crypto" },
                         identifier: { "holding.kind.\($0.rawValue.lowercased())" })
            if kind == .stock {
                DSSegmentBar(options: Market.allCases, selection: $market,
                             title: { $0 == .us ? "US market" : "ASX" },
                             identifier: { "holding.market.\($0.rawValue)" })
            }
            FormField(label: "Ticker") {
                TextField(kind == .crypto ? "BTC" : "AAPL", text: $symbol)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .symbol)
            }
            FormField(label: "Name (optional)") {
                TextField(kind == .crypto ? "Bitcoin" : "Apple Inc.", text: $name)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .name)
            }
        }
    }

    @ViewBuilder
    private var summary: some View {
        if let q = quantity, q > 0 {
            let tradingLive = livePrice.map { initialAsset!.toTradingCurrency($0) }
            let paid = cost.map { $0 * q + (fees ?? 0) }
            VStack(spacing: 0) {
                if let tradingLive {
                    LedgerLine(label: "Worth today", value: formatTradingAmount(tradingLive * q))
                }
                if let paid {
                    LedgerLine(label: "Total paid", value: formatTradingAmount(paid))
                }
                if let tradingLive, let paid, paid > 0 {
                    let gain = tradingLive * q - paid
                    LedgerLine(label: "Return so far",
                               value: "\(gain >= 0 ? "+" : "−")\(formatTradingAmount(abs(gain))) (\(formatPercent(gain / paid * 100, signed: true)))",
                               tint: gain >= 0 ? theme.positiveColor : theme.negativeColor)
                }
            }
            .padding(.horizontal, DS.Space.l)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.subtleFill))
            .accessibilityIdentifier("holding.form.summary")
        }
    }

    private func formatTradingAmount(_ amount: Double) -> String {
        currencySymbol + amount.formatted(.number.precision(.fractionLength(2)))
    }

    // MARK: Submit

    private func submit() {
        guard canSubmit, let q = quantity else { return }
        errorText = nil
        let costPerUnit = cost ?? 0
        let asset: Asset
        if let initialAsset {
            asset = initialAsset
        } else {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let usdCost = costPerUnit * (FXRates.shared.toUSDFactor(from: currency) ?? 1)
            // Until the live quote lands (it's fetched right after adding) the holding is valued at cost.
            asset = Asset(symbol: draftSymbol, name: trimmedName.isEmpty ? draftSymbol : trimmedName,
                          price: usdCost, change: 0, changePercent: 0, volume: 0, kind: draftKind,
                          exchange: draftKind == .crypto ? "Crypto" : (draftIsASX ? "ASX" : "US"))
        }
        let enteredFees = feesText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : fees
        switch marketData.addHolding(asset: asset, shares: q, costPerUnit: costPerUnit, costCurrency: currency, date: date,
                                     sourceCostKnown: cost != nil, fees: enteredFees) {
        case .ok:
            Haptics.success()
            onAdded(asset.symbol)
        case .limitReached:
            Haptics.warning()
            showPaywall = true
        case .invalid(let message):
            Haptics.warning()
            errorText = message
        }
    }
}

// MARK: - Sheets used elsewhere

/// Add a known asset (from the watchlist or a stock page).
struct AddToPortfolioSheet: View {
    let asset: Asset
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HoldingFormView(initialAsset: asset) { _ in dismiss() }
                .navigationTitle("Add \(asset.symbol)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
        }
    }
}

/// Manual entry (onboarding, Home). With an asset it behaves like AddToPortfolioSheet.
struct ManualPositionSheet: View {
    var asset: Asset? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HoldingFormView(initialAsset: asset) { _ in dismiss() }
                .navigationTitle(asset.map { "Add \($0.symbol)" } ?? "Add a holding")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
        }
    }
}
