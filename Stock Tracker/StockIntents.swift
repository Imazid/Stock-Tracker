//
//  StockIntents.swift
//  Stock Tracker
//
//  Siri, Shortcuts, Spotlight and the Action button:
//    "What's Apple at in Stock Tracker?"  → live price card (CheckPriceIntent)
//    "Open Apple in Stock Tracker"         → the stock's page (OpenStockIntent)
//  Stocks offered are the ones you follow or hold, plus anything Siri/Shortcuts
//  searches for. Prices are live quotes in your display currency — never cached
//  numbers presented as current.
//

import AppIntents
import Auth
import SwiftUI
import Supabase

// MARK: - Entity

struct StockEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Stock"
    static let defaultQuery = StockEntityQuery()

    /// The app's symbol ("AAPL", "BHP" for ASX with `exchange == "ASX"`, "BTC").
    var id: String
    var name: String
    var kindRaw: String
    var exchange: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(id)\(exchange == "ASX" ? " · ASX" : "")")
    }

    @MainActor
    var asset: Asset {
        Asset(symbol: id, name: name, price: 0, change: 0, changePercent: 0, volume: 0,
              kind: AssetKind(rawValue: kindRaw) ?? .stock, exchange: exchange)
    }

    @MainActor
    init(asset: Asset) {
        id = asset.symbol
        name = asset.name.isEmpty ? asset.symbol : asset.name
        kindRaw = asset.kind.rawValue
        exchange = asset.exchange
    }
}

struct StockEntityQuery: EntityStringQuery {
    /// Watchlist + holdings, as saved on this iPhone.
    @MainActor
    private func followed() -> [StockEntity] {
        let persist = DataPersistenceManager.shared
        var seen = Set<String>()
        let lists = WatchlistSync.shared.cached(owner: SupabaseManager.auth.currentUser?.id)
        return (lists.groups.flatMap(\.assets) + persist.loadPortfolio().map(\.asset))
            .filter { !$0.symbol.hasPrefix("^") && seen.insert($0.symbol).inserted }
            .map(StockEntity.init(asset:))
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [StockEntity] {
        let known = followed()
        var result: [StockEntity] = []
        for id in identifiers {
            if let match = known.first(where: { $0.id == id }) {
                result.append(match)
            } else {
                let isCoin = SymbolSearchModel.supportedCoins.contains { $0.symbol == id }
                result.append(StockEntity(asset: Asset(symbol: id, name: id, price: 0, change: 0, changePercent: 0,
                                                       volume: 0, kind: isCoin ? .crypto : .stock, exchange: "")))
            }
        }
        return result
    }

    @MainActor
    func suggestedEntities() async throws -> [StockEntity] {
        followed()
    }

    /// Followed stocks first, then a live search (US stocks/ETFs, ASX, priceable coins).
    @MainActor
    func entities(matching string: String) async throws -> [StockEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return try await suggestedEntities() }
        let lower = query.lowercased()
        let local = followed().filter { $0.id.lowercased().hasPrefix(lower) || $0.name.lowercased().contains(lower) }
        let coins = SymbolSearchModel.supportedCoins
            .filter { $0.symbol.lowercased().hasPrefix(lower) || $0.name.lowercased().hasPrefix(lower) }
            .map { StockEntity(asset: Asset(symbol: $0.symbol, name: $0.name, price: 0, change: 0, changePercent: 0,
                                            volume: 0, kind: .crypto, exchange: "")) }
        var remote: [StockEntity] = []
        if let results = try? await APIService.shared.fetchSymbolSearch(query: query, kind: .stock) {
            remote = results.prefix(8).compactMap { r in
                if r.exchange == "ASX" {
                    return StockEntity(asset: Asset(symbol: r.symbol, name: r.name, price: 0, change: 0,
                                                    changePercent: 0, volume: 0, kind: .stock, exchange: "ASX"))
                }
                guard r.currency.uppercased() == "USD", !r.symbol.contains(".") else { return nil }
                return StockEntity(asset: Asset(symbol: r.symbol, name: r.name, price: 0, change: 0,
                                                changePercent: 0, volume: 0, kind: .stock, exchange: "US"))
            }
        }
        var seen = Set<String>()
        return (local + coins + remote).filter { seen.insert($0.id + $0.exchange).inserted }
    }
}

// MARK: - Live price answer (shared by the intent and its DEBUG probe)

struct PriceAnswer: Sendable {
    let name: String
    let symbol: String
    let priceText: String
    let changeText: String
    let isUp: Bool

    var dialog: String {
        "\(name) is at \(priceText), \(isUp ? "up" : "down") \(changeText) today."
    }

    /// Fetches a live quote and formats it in the display currency the app uses.
    @MainActor
    static func make(for asset: Asset) async -> PriceAnswer? {
        let service = QuoteService()
        let fresh: Asset? = asset.kind == .crypto
            ? await service.refreshCryptoPrices(for: [asset]).first
            : await service.refreshStockQuotes(for: [asset]).first
        guard let quote = fresh, quote.price > 0 else { return nil }
        let shared = UserDefaults(suiteName: Constants.Widget.appGroup)
        let currency = shared?.string(forKey: "displayCurrency") ?? "USD"
        let rate = shared?.double(forKey: "displayRate") ?? 0
        let rates = currency == "USD" ? [:] : [currency: rate > 0 ? rate : (FXRates.shared.rate(for: currency) ?? 1)]
        return PriceAnswer(
            name: asset.name.isEmpty || asset.name == asset.symbol ? quote.name : asset.name,
            symbol: quote.symbol,
            priceText: quote.price.formattedPrice(in: currency, rates: rates),
            changeText: String(format: "%.2f%%", abs(quote.changePercent)),
            isUp: quote.changePercent >= 0)
    }
}

// MARK: - Intents

struct CheckPriceIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Stock Price"
    static let description = IntentDescription("Gets the live price of a stock or coin and how it's moved today.")

    @Parameter(title: "Stock", requestValueDialog: "Which stock?")
    var stock: StockEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Check the price of \(\.$stock)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        guard let answer = await PriceAnswer.make(for: stock.asset) else {
            return .result(dialog: "I couldn't get a live price for \(stock.name) right now. Try again in a moment.",
                           view: PriceSnippet(answer: nil, fallbackName: stock.name))
        }
        return .result(dialog: "\(answer.dialog)", view: PriceSnippet(answer: answer, fallbackName: stock.name))
    }
}

struct OpenStockIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Stock"
    static let description = IntentDescription("Opens a stock's page in Stock Tracker.")
    static let openAppWhenRun = true

    @Parameter(title: "Stock")
    var stock: StockEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let path = stock.exchange == "ASX" ? "\(stock.id).AX" : stock.id
        if let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            QuickActionRouter.shared.pending = URL(string: "stocktracker://asset/\(encoded)")
        }
        return .result()
    }
}

struct StockTrackerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CheckPriceIntent(),
            phrases: [
                "What's \(\.$stock) at in \(.applicationName)",
                "Check \(\.$stock) in \(.applicationName)",
                "\(.applicationName) price of \(\.$stock)"
            ],
            shortTitle: "Check Price",
            systemImageName: "chart.line.uptrend.xyaxis")
        AppShortcut(
            intent: OpenStockIntent(),
            phrases: ["Open \(\.$stock) in \(.applicationName)"],
            shortTitle: "Open Stock",
            systemImageName: "doc.text.magnifyingglass")
    }
}

// MARK: - Snippet

private struct PriceSnippet: View {
    let answer: PriceAnswer?
    let fallbackName: String

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(answer?.name ?? fallbackName).font(.headline).lineLimit(1)
                Text(answer?.symbol ?? "").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let answer {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(answer.priceText).font(.title3.weight(.semibold).monospacedDigit())
                    Text("\(answer.isUp ? "▲" : "▼") \(answer.changeText) today")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(answer.isUp ? Color.green : Color.red)
                }
            } else {
                Text("No live price").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}
