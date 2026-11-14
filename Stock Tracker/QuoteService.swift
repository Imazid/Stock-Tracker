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
import TradingCore

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
    func quoteFailed(for asset: Asset) -> Bool
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

    private func isASXStock(_ asset: Asset) -> Bool { Self.isASX(asset) }

    /// Shared rule (quotes, history and trading hours must agree).
    nonisolated static func isASX(_ asset: Asset) -> Bool {
        asset.listedStock?.venue == .asx
    }

    private var failedListings: Set<String> = []

    func quoteFailed(for asset: Asset) -> Bool { failedListings.contains(asset.quoteIdentity) }

    private func isUSQuote(_ asset: Asset) -> Bool {
        asset.listedStock?.venue == .us || asset.isUnresolvedUSQuote
    }

    private func stockQuote(_ asset: Asset) async throws -> Asset {
        let quote = try await api.fetchStockQuote(symbol: asset.symbol)
        return quote.with(exchange: "US")
    }

    /// Refresh live quotes for every stock asset; keeps old metadata on failure.
    /// ASX and international listings use Yahoo; US stocks use Alpaca with a Yahoo fallback.
    func refreshStockQuotes(for stocks: [Asset]) async -> [Asset] {
        var updated = stocks
        for asset in stocks { failedListings.remove(asset.quoteIdentity) }

        // US: one batched Alpaca request instead of one per symbol (they ran one after
        // another: ten holdings = ten round trips before anything updated).
        let usIndices = updated.indices.filter { isUSQuote(updated[$0]) }
        var batch: [String: Asset] = [:]
        if usIndices.count > 1 {
            let symbols = Set(usIndices.map { updated[$0].symbol }).sorted()
            // The market-data proxy accepts at most 100 symbols per request.
            for start in stride(from: 0, to: symbols.count, by: 100) {
                let end = min(start + 100, symbols.count)
                if let quotes = try? await api.fetchStockQuotes(symbols: Array(symbols[start..<end])) {
                    batch.merge(quotes) { _, latest in latest }
                }
            }
            for index in usIndices {
                if let apiAsset = batch[updated[index].symbol.uppercased()] {
                    updated[index] = mergedAsset(old: updated[index], api: apiAsset)
                }
            }
        }

        // ASX (Yahoo), a lone US symbol, or the batch failing: one request each, concurrently.
        let singles = updated.indices.filter {
            !isUSQuote(updated[$0]) || batch[updated[$0].symbol.uppercased()] == nil
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
                        if let yahooSymbol = current.internationalQuoteSymbol {
                            return (index, try await self.api.fetchYahooQuote(symbol: yahooSymbol, name: current.name))
                        }
                        guard self.isUSQuote(current) else { return (index, nil) }
                        return (index, try await self.stockQuote(current))
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
                    failedListings.insert(updated[index].quoteIdentity)
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
        for asset in crypto { failedListings.remove(asset.quoteIdentity) }
        for asset in crypto where Self.coinGeckoIDMap[asset.symbol] == nil { failedListings.insert(asset.quoteIdentity) }
        guard !ids.isEmpty else { return crypto }

        do {
            let batchResults = try await api.fetchCryptoPricesBatch(ids: ids)
            var updated = crypto
            for index in updated.indices {
                guard let id = Self.coinGeckoIDMap[updated[index].symbol],
                      let apiAsset = batchResults[id] else {
                    failedListings.insert(updated[index].quoteIdentity)
                    continue
                }
                updated[index] = mergedAsset(old: updated[index], api: apiAsset)
            }
            return updated
        } catch {
            AppLogger.api.error("Crypto batch price fetch failed: \(error)")
            failedListings.formUnion(crypto.map(\.quoteIdentity))
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
            if let yahooSymbol = asset.internationalQuoteSymbol {
                return try await api.fetchYahooHistory(symbol: yahooSymbol, range: range)
            }
            guard isUSQuote(asset) else { throw APIError.noData }
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
        if let yahooSymbol = asset.internationalQuoteSymbol {
            return try await api.fetchYahooCandles(symbol: yahooSymbol, range: range)
        }
        guard isUSQuote(asset) else { throw APIError.noData }
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
        let lookup = Dictionary((stocks + crypto).map { ($0.quoteIdentity, $0) }, uniquingKeysWith: { first, _ in first })
        func apply(_ asset: Asset) -> Asset {
            let quote = lookup[asset.quoteIdentity] ?? (asset.isUnresolvedUSQuote ? lookup["us:\(asset.symbol.uppercased())"] : nil)
            return quote.map { mergedAsset(old: asset, api: $0) } ?? asset
        }
        let updatedPortfolio = portfolio.map { holding -> PortfolioHolding in
            var h = holding
            h.asset = apply(h.asset)
            return h
        }
        let updatedWatchlist = watchlist.map(apply)
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
            exchange: placeholderExchange && !api.exchange.isEmpty ? api.exchange : old.exchange,
            isETF: api.isETF ?? old.isETF
        )
    }
}
