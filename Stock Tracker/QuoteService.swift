//
//  QuoteService.swift
//  Stock Tracker
//
//  Domain service responsible for stock/crypto quote fetching,
//  price history, S&P 500 data, and exchange rates.
//  Conforms to QuoteServiceProtocol for dependency injection + testability.
//

import Foundation
import OSLog

// MARK: - Protocol (enables DI and unit testing)

@MainActor
protocol QuoteServiceProtocol: AnyObject {
    func refreshStockQuotes(for stocks: [Asset]) async -> [Asset]
    func refreshCryptoPrices(for crypto: [Asset]) async -> [Asset]
    func fetchExchangeRates(for currencies: [String]) async -> [String: Double]
    func fetchSP500History() async -> [PricePoint]
    func fetchPriceHistory(for asset: Asset, range: TimeRange) async -> [PricePoint]
    func fetchPriceHistoryOrThrow(for asset: Asset, range: TimeRange) async throws -> [PricePoint]
    func fetchHistoricalData(for asset: Asset, range: TimeRange) async throws -> [Candle]
    func fetchHistoricalData(symbol: String, range: TimeRange) async throws -> [Candle]
    func fetchLatestCandle(symbol: String, intervalMinutes: Int) async -> Candle?
    func syncCollections(
        portfolio: [PortfolioHolding],
        watchlist: [Asset],
        stocks: [Asset],
        crypto: [Asset]
    ) -> (portfolio: [PortfolioHolding], watchlist: [Asset])
    func mergedAsset(old: Asset, api: Asset) -> Asset
    /// Symbols whose most recent quote request failed (shown as "No live price").
    var lastFailedSymbols: Set<String> { get }
}

// MARK: - Implementation

@MainActor
final class QuoteService: QuoteServiceProtocol {

    private let api: APIService

    /// CoinGecko ID map for the most common crypto symbols.
    /// CoinGecko id for a coin symbol ("BTC" → "bitcoin"), or nil if unsupported.
    nonisolated static func coinGeckoID(for symbol: String) -> String? { coinGeckoIDMap[symbol.uppercased()] }

    nonisolated private static let coinGeckoIDMap: [String: String] = [
        "BTC":   "bitcoin",
        "ETH":   "ethereum",
        "SOL":   "solana",
        "ADA":   "cardano",
        "BNB":   "binancecoin",
        "XRP":   "ripple",
        "DOGE":  "dogecoin",
        "DOT":   "polkadot",
        // MATIC migrated 1:1 to POL; CoinGecko's "matic-network" price has been frozen
        // since Feb 2026 (last_updated_at 1770083820), so both map to the live POL id.
        "MATIC": "polygon-ecosystem-token",
        "POL":   "polygon-ecosystem-token",
        "LINK":  "chainlink",
        "AVAX":  "avalanche-2",
        "UNI":   "uniswap",
        "LTC":   "litecoin",
        "ATOM":  "cosmos"
    ]

    /// Common ASX symbols and their display names.
    nonisolated static let popularASXSymbols: [String] = [
        "BHP", "CBA", "CSL", "NAB", "WBC", "ANZ", "FMG", "WES", "MQG", "RIO"
    ]

    /// Converts a display symbol (e.g. "BHP") to Finnhub's ASX format ("BHP.AX").
    static func finnhubASXSymbol(for displaySymbol: String) -> String {
        let upper = displaySymbol.uppercased()
        return upper.hasSuffix(".AX") ? upper : "\(upper).AX"
    }

    init(api: APIService? = nil) {
        self.api = api ?? .shared
    }

    // MARK: - Stock Quotes

    nonisolated private static let usExchanges: Set<String> = ["NYSE", "NASDAQ", "US", "AMEX", "ARCA", "NYSEARCA", "BATS", "NYSE AMERICAN", "OTC"]

    /// Whether a stock trades on the ASX. The asset's own exchange wins; the
    /// popular-ticker list is only a fallback for assets with no exchange
    /// (otherwise Telstra "TLS" was priced as Telos and BHP's NYSE ADR as BHP.AX).
    private func isASXStock(_ asset: Asset) -> Bool { Self.isASX(asset) }

    /// Shared rule (quotes, history and trading hours must agree).
    nonisolated static func isASX(_ asset: Asset) -> Bool {
        guard asset.kind == .stock else { return false }
        let exchange = asset.exchange.uppercased()
        if exchange == "ASX" || asset.symbol.hasSuffix(".AX") { return true }
        if Self.usExchanges.contains(exchange) || exchange == "INTERNATIONAL" { return false }
        return Self.popularASXSymbols.contains(asset.symbol.uppercased())
    }

    private(set) var lastFailedSymbols: Set<String> = []

    /// Refresh live quotes for every stock asset; keeps old metadata on failure.
    /// ASX stocks are routed through Finnhub; US stocks through Alpaca.
    func refreshStockQuotes(for stocks: [Asset]) async -> [Asset] {
        var updated = stocks
        for symbol in stocks.map(\.symbol) { lastFailedSymbols.remove(symbol) }

        // US: one batched Alpaca request instead of one per symbol (they ran one after
        // another: ten holdings = ten round trips before anything updated).
        let usIndices = updated.indices.filter { !isASXStock(updated[$0]) && updated[$0].exchange != "International" }
        var batch: [String: Asset]?
        if usIndices.count > 1 {
            batch = try? await api.fetchStockQuotes(symbols: usIndices.map { updated[$0].symbol })
        }
        if let batch {
            for index in usIndices {
                if let apiAsset = batch[updated[index].symbol.uppercased()] {
                    updated[index] = mergedAsset(old: updated[index], api: apiAsset)
                } else {
                    AppLogger.api.error("Stock quote failed for \(updated[index].symbol): not in Alpaca snapshot batch")
                    lastFailedSymbols.insert(updated[index].symbol)
                }
            }
        }

        // ASX (Yahoo), a lone US symbol, or the batch failing: one request each, concurrently.
        let singles = updated.indices.filter {
            batch == nil || isASXStock(updated[$0]) || updated[$0].exchange == "International"
        }
        await withTaskGroup(of: (Int, Asset?).self) { group in
            for index in singles {
                let current = updated[index]
                group.addTask { @MainActor in
                    do {
                        if self.isASXStock(current) {
                            let yahooSymbol = Self.finnhubASXSymbol(for: current.symbol)
                            return (index, try await self.api.fetchYahooQuote(symbol: yahooSymbol, name: current.name))
                        }
                        // London, Frankfurt, Tokyo… are priced by Yahoo under their suffixed symbol.
                        if current.exchange == "International" {
                            return (index, try await self.api.fetchYahooQuote(symbol: current.symbol, name: current.name))
                        }
                        return (index, try await self.api.fetchStockQuote(symbol: current.symbol))
                    } catch {
                        AppLogger.api.error("Stock quote failed for \(current.symbol): \(error)")
                        return (index, nil)
                    }
                }
            }
            for await (index, apiAsset) in group {
                if let apiAsset {
                    updated[index] = mergedAsset(old: updated[index], api: apiAsset)
                } else {
                    lastFailedSymbols.insert(updated[index].symbol)
                }
            }
        }
        return updated
    }

    // MARK: - Crypto Prices

    /// Refresh live prices for every crypto asset via a single batched CoinGecko request.
    func refreshCryptoPrices(for crypto: [Asset]) async -> [Asset] {
        // Collect all known CoinGecko IDs in one pass
        let ids = crypto.compactMap { Self.coinGeckoIDMap[$0.symbol] }
        // Coins we can't map to CoinGecko never get a price — say so instead of showing a stale one.
        for asset in crypto { lastFailedSymbols.remove(asset.symbol) }
        for asset in crypto where Self.coinGeckoIDMap[asset.symbol] == nil { lastFailedSymbols.insert(asset.symbol) }
        guard !ids.isEmpty else { return crypto }

        do {
            let batchResults = try await api.fetchCryptoPricesBatch(ids: ids)
            var updated = crypto
            for index in updated.indices {
                guard let id = Self.coinGeckoIDMap[updated[index].symbol],
                      let apiAsset = batchResults[id] else { continue }
                updated[index] = mergedAsset(old: updated[index], api: apiAsset)
            }
            return updated
        } catch {
            AppLogger.api.error("Crypto batch price fetch failed: \(error)")
            return crypto
        }
    }

    // MARK: - Exchange Rates

    /// Frankfurter (ECB reference rates, updated each working day): free, no key, covers
    /// AUD/EUR/GBP/JPY/CAD and ~25 more. Replaces api.exchangerate.host, which now
    /// requires an access key and answered HTTP 200 `{"success":false,…}` — so the app
    /// silently kept its hard-coded fallback rates.
    private static let exchangeRateURL = "https://api.frankfurter.dev/v1/latest"

    /// Fetch live USD exchange rates for the given currency codes.
    func fetchExchangeRates(for currencies: [String]) async -> [String: Double] {
        let symbols = currencies.filter { $0 != "USD" }.joined(separator: ",")
        guard !symbols.isEmpty,
              var components = URLComponents(string: Self.exchangeRateURL) else {
            return [:]
        }
        components.queryItems = [
            URLQueryItem(name: "base", value: "USD"),
            URLQueryItem(name: "symbols", value: symbols)
        ]
        guard let url = components.url else { return [:] }
        do {
            NetRequestLog.record(endpoint: "fx", url: url)
            let (data, response) = try await URLSession.shared.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                AppLogger.api.error("Exchange rate fetch HTTP \(status) — keeping previous rates")
                return [:]
            }
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rates = json["rates"] as? [String: Double], !rates.isEmpty {
                return rates
            }
            AppLogger.api.error("Exchange rate response had no rates — keeping previous rates")
        } catch {
            AppLogger.api.error("Exchange rate fetch failed: \(error)")
        }
        return [:]
    }

    // MARK: - S&P 500

    /// 1-year S&P 500 history via SPY (Alpaca serves no index data). Empty on
    /// failure — benchmark views show "unavailable" rather than an invented index.
    func fetchSP500History() async -> [PricePoint] {
        do {
            return try await api.fetchHistoricalData(symbol: "SPY", range: .oneYear)
        } catch {
            AppLogger.api.warning("S&P 500 history unavailable: \(error)")
            return []
        }
    }

    // MARK: - Price History

    /// Price history for an asset, or an empty array if every source fails.
    /// Never synthetic: an empty result makes charts show "unavailable".
    func fetchPriceHistory(for asset: Asset, range: TimeRange) async -> [PricePoint] {
        do {
            return try await fetchPriceHistoryOrThrow(for: asset, range: range)
        } catch {
            AppLogger.api.warning("Price history unavailable for \(asset.symbol) \(range.rawValue): \(error)")
            return []
        }
    }

    /// Price history for an asset (USD), throwing when no source can supply it.
    /// - Crypto: CoinGecko market chart (Alpaca for > 1Y)
    /// - ASX/International: Yahoo Finance chart (converted to USD)
    /// - US stock: Alpaca bars, Yahoo fallback on error
    func fetchPriceHistoryOrThrow(for asset: Asset, range: TimeRange) async throws -> [PricePoint] {
        do {
            if asset.kind == .crypto,
               let cgId = Self.coinGeckoIDMap[asset.symbol.uppercased()] {
                return try await api.fetchCryptoHistory(id: cgId, range: range)
            }
            if isASXStock(asset) {
                let yahooSymbol = Self.finnhubASXSymbol(for: asset.symbol)
                return try await api.fetchYahooHistory(symbol: yahooSymbol, range: range)
            }
            if asset.exchange == "International" {
                return try await api.fetchYahooHistory(symbol: asset.symbol, range: range)
            }
            // US stock: Alpaca primary, Yahoo fallback
            do {
                return try await api.fetchHistoricalData(symbol: asset.symbol, range: range)
            } catch {
                AppLogger.api.info("Alpaca history failed for \(asset.symbol), trying Yahoo: \(error)")
                return try await api.fetchYahooHistory(symbol: asset.symbol, range: range)
            }
        }
    }

    // MARK: - OHLCV Candles

    /// Fetch OHLCV candle data for an asset, routing ASX/international to Yahoo, US to Alpaca with Yahoo fallback.
    func fetchHistoricalData(for asset: Asset, range: TimeRange) async throws -> [Candle] {
        if asset.kind == .crypto {
            // Crypto doesn't have OHLCV via CoinGecko — fall through to symbol-based
            return try await fetchHistoricalData(symbol: asset.symbol, range: range)
        }
        if isASXStock(asset) {
            let yahooSymbol = Self.finnhubASXSymbol(for: asset.symbol)
            return try await api.fetchYahooCandles(symbol: yahooSymbol, range: range)
        }
        if asset.exchange == "International" {
            return try await api.fetchYahooCandles(symbol: asset.symbol, range: range)
        }
        // US stock: Alpaca primary, Yahoo fallback
        do {
            return try await fetchHistoricalData(symbol: asset.symbol, range: range)
        } catch {
            AppLogger.api.info("Alpaca candles failed for \(asset.symbol), trying Yahoo: \(error)")
            return try await api.fetchYahooCandles(symbol: asset.symbol, range: range)
        }
    }

    /// Fetch OHLCV candle data from Alpaca by symbol.
    func fetchHistoricalData(symbol: String, range: TimeRange) async throws -> [Candle] {
        let upper = symbol.uppercased()
        let (timeframe, multiplier): (String, Int) = {
            switch range {
            case .oneDay:  return ("Minute", 5)
            case .oneWeek: return ("Minute", 30)
            default:       return ("Day", 1)
            }
        }()
        let bars = try await api.fetchBars(
            symbol: upper,
            timeframe: timeframe,
            multiplier: multiplier,
            range: range
        )
        return bars.map {
            Candle(date: $0.date, open: $0.open, high: $0.high, low: $0.low, close: $0.close, volume: $0.volume)
        }
    }

    /// Fetch only the latest candle for live updates (minimal API call).
    func fetchLatestCandle(symbol: String, intervalMinutes: Int) async -> Candle? {
        let upper = symbol.uppercased()
        let end = Date()
        let start = Calendar.current.date(byAdding: .minute, value: -intervalMinutes * 3, to: end)!
        do {
            let bars = try await api.fetchLatestBars(
                symbol: upper,
                timeframe: "Minute",
                multiplier: intervalMinutes,
                start: start,
                end: end,
                limit: 3
            )
            guard let last = bars.last else { return nil }
            return Candle(date: last.date, open: last.open, high: last.high, low: last.low, close: last.close, volume: last.volume)
        } catch {
            AppLogger.api.error("fetchLatestCandle failed for \(upper): \(error)")
            return nil
        }
    }

    // MARK: - Collection Sync

    /// Propagate fresh asset prices into portfolio holdings and watchlist entries.
    func syncCollections(
        portfolio: [PortfolioHolding],
        watchlist: [Asset],
        stocks: [Asset],
        crypto: [Asset]
    ) -> (portfolio: [PortfolioHolding], watchlist: [Asset]) {
        // Keyed by kind + symbol: a stock and a coin can share a ticker (LINK, ATOM),
        // which used to crash `uniqueKeysWithValues`.
        func key(_ a: Asset) -> String { "\(a.kind.rawValue):\(a.symbol)" }
        let lookup = Dictionary((stocks + crypto).map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        let updatedPortfolio = portfolio.map { holding -> PortfolioHolding in
            var h = holding
            if let updated = lookup[key(h.asset)] { h.asset = updated }
            return h
        }
        let updatedWatchlist = watchlist.map { lookup[key($0)] ?? $0 }
        return (updatedPortfolio, updatedWatchlist)
    }

    // MARK: - Merge Helper

    /// Keep old metadata (id, name, fundamentals) but overwrite live fields from the API.
    /// 52-week data: prefer fresh API values, fall back to existing.
    func mergedAsset(old: Asset, api: Asset) -> Asset {
        let resolvedPrice = api.price > 0 ? api.price : old.price
        // Placeholders ("Manual"/empty exchange, ticker-as-name) give way to real data.
        let placeholderExchange = old.exchange.isEmpty || old.exchange == "Manual"
        let name = (old.name == old.symbol || old.name.isEmpty) && !api.name.isEmpty ? api.name : old.name
        return Asset(
            id: old.id,
            symbol: old.symbol,
            name: name,
            price: resolvedPrice,
            change: api.change,
            changePercent: api.changePercent,
            volume: api.volume,
            kind: old.kind,
            marketCap: old.marketCap,
            peRatio: old.peRatio,
            eps: old.eps,
            week52High: api.week52High ?? old.week52High,
            week52Low: api.week52Low ?? old.week52Low,
            avgVolume: old.avgVolume,
            dividend: old.dividend,
            beta: old.beta,
            exchange: placeholderExchange && !api.exchange.isEmpty ? api.exchange : old.exchange
        )
    }
}
