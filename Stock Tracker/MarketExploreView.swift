import SwiftUI
import TradingCore

private struct MarketExploreFeed: Decodable {
    struct Mover: Decodable, Identifiable {
        let instrument: Instrument
        let price: Double
        let changePct: Double

        var id: String { instrument.id }
    }

    struct Movers: Decodable {
        let source: String
        let scope: String
        let observedAt: Date
        let gainers: [Mover]
        let losers: [Mover]
    }

    struct Trending: Decodable {
        let checkedAt: Date
        let instruments: [Instrument]
    }

    struct Response: Decodable {
        let data: MarketExploreFeed
    }

    let us: Movers?
    let asx: Movers?
    let trending: Trending?
    let mostWatched: [Instrument]?

    static func load(owner: UUID) async throws -> Self {
        let data = try await SecureBackend.invoke("market-workspace", body: ["action": "explore"], expectedUserID: owner)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { value in
            let container = try value.singleValueContainer()
            let text = try container.decode(String.self)
            let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            guard let date = try? format.parse(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ranking date")
            }
            return date
        }
        return try decoder.decode(Response.self, from: data).data
    }
}

struct MarketExploreView: View {
    @EnvironmentObject private var router: TradingRouter
    @EnvironmentObject private var auth: SupabaseAuthManager
    @EnvironmentObject private var marketData: MarketData
    @Environment(\.theme) private var theme

    @State private var feed: MarketExploreFeed?
    @State private var loadedFor: UUID?
    @State private var loading = false
    @State private var market: StockExchangeMarket = .us
    @State private var side: Side = .gainers
    @State private var topic: Topic = .technology
    @State private var selected: Asset?

    private enum Side: String, CaseIterable {
        case gainers = "Gainers"
        case losers = "Losers"
    }

    private enum Topic: String, CaseIterable {
        case technology = "AI & semiconductors"
        case financials = "Financials"
        case healthcare = "Healthcare"
        case energy = "Energy"
        case dividend = "Dividend ETFs"
        case funds = "Broad market ETFs"
        case networks = "Blockchain networks"
        case defi = "DeFi protocols"

        var instruments: [Instrument] {
            switch self {
            case .technology: UniverseCatalog.semiconductors
            case .financials: UniverseCatalog.financials
            case .healthcare: UniverseCatalog.healthcare
            case .energy: UniverseCatalog.energy
            case .dividend: [
                .usETF("VYM", name: "Vanguard High Dividend Yield ETF"),
                .usETF("SCHD", name: "Schwab U.S. Dividend Equity ETF"),
                .listed("VHY", name: "Vanguard Australian Shares High Yield ETF", on: .asx, etf: true),
            ]
            case .funds: UniverseCatalog.broadETFs
            case .networks: UniverseCatalog.cryptoMajors
            case .defi: UniverseCatalog.otherCrypto.filter { ["LINK", "UNI"].contains($0.symbol) }
            }
        }
    }

    private var currentFeed: MarketExploreFeed? { loadedFor == auth.userId ? feed : nil }
    private var movers: MarketExploreFeed.Movers? { market == .us ? currentFeed?.us : currentFeed?.asx }

    private var recentlySaved: [Asset] {
        let entries = marketData.watchlistGroups.flatMap { list in
            list.assets.compactMap { asset in
                list.savedDates?[asset.id.uuidString].map { (asset, $0) }
            }
        }.sorted { $0.1 > $1.1 }
        var seen = Set<String>()
        return Array(entries.map(\.0).filter { seen.insert($0.quoteIdentity).inserted }.prefix(4))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                Text("Explore")
                    .font(DS.display(.title))
                    .accessibilityAddTraits(.isHeader)
                section("Market indexes") { LiveIndicesWithGlow(includeBitcoin: false) }
                section("Biggest movers") { moversContent }
                section("Trending crypto") { trendingContent }
                if let instruments = currentFeed?.mostWatched, !instruments.isEmpty {
                    section("Most watched") {
                        Text("Ranked by distinct Stock Tracker accounts")
                            .font(.footnote).foregroundStyle(theme.secondaryText)
                        ForEach(instruments) { instrument in instrumentRow(instrument) }
                    }
                }
                section("Sectors & themes") {
                    Picker("Market theme", selection: $topic) {
                        ForEach(Topic.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("explore.theme")
                    ForEach(topic.instruments) { instrument in instrumentRow(instrument) }
                }
                if !recentlySaved.isEmpty {
                    section("Recently added") {
                        Text("From your watchlists").font(.footnote).foregroundStyle(theme.secondaryText)
                        ForEach(recentlySaved) { asset in
                            Button { selected = asset } label: {
                                Label(asset.symbol + " · " + asset.name, systemImage: "clock")
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                section("Your watchlists") {
                    ForEach(Array(marketData.watchlistGroups.enumerated()), id: \.element.id) { index, list in
                        Button {
                            marketData.switchToWatchlist(index: index)
                            router.marketsSection = .watchlist
                        } label: {
                            HStack {
                                Text(list.name)
                                Spacer(minLength: DS.Space.m)
                                Text(list.assets.count, format: .number).foregroundStyle(theme.secondaryText)
                                Image(systemName: "chevron.right").foregroundStyle(theme.secondaryText)
                            }
                            .padding(.vertical, DS.Space.s)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("explore.watchlist.\(list.name)")
                    }
                }
            }
            .padding(.horizontal, DS.Space.gutter)
            .padding(.bottom, DS.Space.l)
        }
        .accessibilityIdentifier("explore.scroll")
        .task(id: auth.userId) { await refresh() }
        .refreshable { await refresh() }
        .sheet(item: $selected) { asset in
            AppleStocksDetailView(stock: detailedStock(from: asset), asset: asset)
        }
    }

    @ViewBuilder private var moversContent: some View {
        Picker("Movers market", selection: $market) {
            Text("US").tag(StockExchangeMarket.us)
            Text("ASX").tag(StockExchangeMarket.asx)
        }
        .pickerStyle(.segmented)
        Picker("Direction", selection: $side) {
            ForEach(Side.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("explore.moverDirection")
        if let movers {
            Text(movers.scope).font(.footnote).foregroundStyle(theme.secondaryText)
            let rows = side == .gainers ? movers.gainers : movers.losers
            if rows.isEmpty {
                Text(side == .gainers ? "No gainers in this group" : "No losers in this group")
                    .font(.subheadline).foregroundStyle(theme.secondaryText)
            } else {
                ForEach(rows) { row in
                    instrumentRow(row.instrument, price: row.price, change: row.changePct)
                }
            }
            Text("\(movers.source) · \(movers.observedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(theme.secondaryText)
        } else {
            feedStatus("Movers are unavailable.")
        }
    }

    @ViewBuilder private var trendingContent: some View {
        if let trending = currentFeed?.trending {
            Text("Supported coins trending in CoinGecko searches over 24 hours")
                .font(.footnote).foregroundStyle(theme.secondaryText)
            if trending.instruments.isEmpty {
                Text("No supported coins in the current ranking.")
                    .font(.subheadline).foregroundStyle(theme.secondaryText)
            } else {
                ForEach(trending.instruments) { instrumentRow($0) }
            }
            Text("CoinGecko · checked \(trending.checkedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(theme.secondaryText)
        } else {
            feedStatus("Crypto trends are unavailable.")
        }
    }

    @ViewBuilder private func feedStatus(_ message: String) -> some View {
        if auth.userId == nil {
            Text("Sign in to see market rankings.").font(.subheadline).foregroundStyle(theme.secondaryText)
        } else if loading {
            ProgressView("Loading market rankings")
        } else {
            InlineRetryNote(text: LocalizedStringKey(message)) { Task { await refresh() } }
        }
    }

    private func section<Content: View>(_ name: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(name)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func instrumentRow(_ instrument: Instrument, price: Double? = nil, change: Double? = nil) -> some View {
        Button {
            let kind: AssetKind = instrument.assetClass == .crypto ? .crypto : .stock
            selected = Asset(symbol: instrument.symbol, name: instrument.name, price: 0, change: 0,
                             changePercent: 0, volume: 0, kind: kind, exchange: instrument.venue.shortName,
                             isETF: instrument.assetClass == .etf)
        } label: {
            HStack(spacing: DS.Space.s) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(instrument.symbol).font(.subheadline.weight(.semibold))
                    Text(instrument.name).font(.caption).foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: DS.Space.s)
                if let price, let change {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(price, format: .currency(code: instrument.currency))
                            .font(.subheadline.monospacedDigit())
                        ChangePill(percent: change, compact: true)
                    }
                } else {
                    Text(instrument.venue.shortName).font(.caption).foregroundStyle(theme.secondaryText)
                }
            }
            .padding(.vertical, DS.Space.s)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("explore.row.\(instrument.id)")
    }

    private func refresh() async {
        guard let owner = auth.userId, !loading || loadedFor != owner else { return }
        if loadedFor != owner { feed = nil }
        loadedFor = owner
        loading = true
        defer { if loadedFor == owner { loading = false } }
        do {
            let result = try await MarketExploreFeed.load(owner: owner)
            guard !Task.isCancelled, auth.userId == owner else { return }
            feed = result
        } catch {
            if auth.userId == owner, !Task.isCancelled { feed = nil }
        }
    }
}
