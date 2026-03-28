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
    func generateMockSP500History() -> [PricePoint]
    func fetchPriceHistory(for asset: Asset, range: TimeRange) async -> [PricePoint]
    func generatePriceHistoryFallback(for asset: Asset, range: TimeRange) -> [PricePoint]
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
}

// MARK: - Implementation

@MainActor
final class QuoteService: QuoteServiceProtocol {

    private let api: APIService

    /// CoinGecko ID map for the most common crypto symbols.
    private static let coinGeckoIDMap: [String: String] = [
        "BTC":   "bitcoin",
        "ETH":   "ethereum",
        "SOL":   "solana",
        "ADA":   "cardano",
        "BNB":   "binancecoin",
        "XRP":   "ripple",
        "DOGE":  "dogecoin",
        "DOT":   "polkadot",
        "MATIC": "matic-network",
        "LINK":  "chainlink",
        "AVAX":  "avalanche-2",
        "UNI":   "uniswap",
        "LTC":   "litecoin",
        "ATOM":  "cosmos"
    ]

    /// Common ASX symbols and their display names.
    static let popularASXSymbols: [String] = [
        "BHP", "CBA", "CSL", "NAB", "WBC", "ANZ", "FMG", "WES", "MQG", "RIO"
    ]

    /// Converts a display symbol (e.g. "BHP") to Finnhub's ASX format ("BHP.AX").
    static func finnhubASXSymbol(for displaySymbol: String) -> String {
        let upper = displaySymbol.uppercased()
        return upper.hasSuffix(".AX") ? upper : "\(upper).AX"
    }

    init(api: APIService = .shared) {
        self.api = api
    }

    // MARK: - Stock Quotes

    /// Check if a stock should be routed to Finnhub (ASX/international) instead of Alpaca (US-only).
    private func isASXStock(_ asset: Asset) -> Bool {
        asset.exchange == "ASX"
            || asset.symbol.hasSuffix(".AX")
            || Self.popularASXSymbols.contains(asset.symbol.uppercased())
    }

    /// Refresh live quotes for every stock asset; keeps old metadata on failure.
    /// ASX stocks are routed through Finnhub; US stocks through Alpaca.
    func refreshStockQuotes(for stocks: [Asset]) async -> [Asset] {
        var updated = stocks
        for index in updated.indices {
            let current = updated[index]
            do {
                let apiAsset: Asset
                if isASXStock(current) {
                    let finnhubSymbol = Self.finnhubASXSymbol(for: current.symbol)
                    apiAsset = try await api.fetchYahooQuote(symbol: finnhubSymbol, name: current.name)
                } else {
                    apiAsset = try await api.fetchStockQuote(symbol: current.symbol)
                }
                updated[index] = mergedAsset(old: current, api: apiAsset)
            } catch {
                AppLogger.api.error("Stock quote failed for \(current.symbol): \(error)")
            }
        }
        return updated
    }

    // MARK: - Crypto Prices

    /// Refresh live prices for every crypto asset via a single batched CoinGecko request.
    func refreshCryptoPrices(for crypto: [Asset]) async -> [Asset] {
        // Collect all known CoinGecko IDs in one pass
        let ids = crypto.compactMap { Self.coinGeckoIDMap[$0.symbol] }
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

    /// Fetch live USD exchange rates for the given currency codes.
    func fetchExchangeRates(for currencies: [String]) async -> [String: Double] {
        let symbols = currencies.filter { $0 != "USD" }.joined(separator: ",")
        guard !symbols.isEmpty,
              let url = URL(string: "\(Constants.URLs.exchangeRate)?base=USD&symbols=\(symbols)") else {
            return [:]
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rates = json["rates"] as? [String: Double] {
                return rates
            }
        } catch {
            AppLogger.api.error("Exchange rate fetch failed: \(error)")
        }
        return [:]
    }

    // MARK: - S&P 500

    /// Fetch 1-year S&P 500 history; falls back to synthetic data on error.
    func fetchSP500History() async -> [PricePoint] {
        do {
            // Alpaca does not serve index data; SPY (S&P 500 ETF) is a supported proxy
        return try await api.fetchHistoricalData(symbol: "SPY", range: .oneYear)
        } catch {
            AppLogger.api.warning("S&P 500 history unavailable, using mock: \(error)")
            return generateMockSP500History()
        }
    }

    func generateMockSP500History() -> [PricePoint] {
        let calendar = Calendar.current
        let now = Date()
        var currentPrice = 4783.45
        var points: [PricePoint] = []
        for i in 0..<365 {
            guard let date = calendar.date(byAdding: .day, value: -i, to: now) else { continue }
            currentPrice = max(3000, currentPrice * (1 + Double.random(in: -0.02...0.02)))
            points.append(PricePoint(date: date, price: currentPrice))
        }
        return points.sorted { $0.date < $1.date }
    }

    // MARK: - Price History

    /// Fetch API price history for an asset; falls back to a synthetic random-walk on error.
    /// - Crypto: CoinGecko market chart
    /// - ASX/International: Yahoo Finance chart
    /// - US stock: Alpaca bars, Yahoo fallback on error
    func fetchPriceHistory(for asset: Asset, range: TimeRange) async -> [PricePoint] {
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
        } catch {
            AppLogger.api.warning("Price history unavailable for \(asset.symbol), using fallback: \(error)")
            return generatePriceHistoryFallback(for: asset, range: range)
        }
    }

    func generatePriceHistoryFallback(for asset: Asset, range: TimeRange) -> [PricePoint] {
        let calendar = Calendar.current
        let now = Date()
        let (numPoints, component): (Int, Calendar.Component) = {
            switch range {
            case .oneDay:       return (24, .hour)
            case .oneWeek:      return (7,  .day)
            case .oneMonth:     return (30, .day)
            case .threeMonths:  return (13, .weekOfYear)
            case .sixMonths:    return (26, .weekOfYear)
            case .ytd:          return (12, .month)
            case .oneYear:      return (12, .month)
            case .twoYears:     return (24, .month)
            case .fiveYears:    return (30, .month)
            case .tenYears:     return (40, .month)
            case .all:          return (60, .month)
            }
        }()
        let volatility = range.volatility
        var points: [PricePoint] = []
        var currentPrice = asset.price
        for i in 0..<numPoints {
            guard let date = calendar.date(byAdding: component, value: -i, to: now) else { continue }
            currentPrice = max(0.01, currentPrice * (1 + Double.random(in: (-volatility)...(volatility))))
            points.append(PricePoint(date: date, price: currentPrice))
        }
        return points.sorted { $0.date < $1.date }
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
        let lookup = Dictionary(uniqueKeysWithValues: (stocks + crypto).map { ($0.symbol, $0) })
        let updatedPortfolio = portfolio.map { holding -> PortfolioHolding in
            var h = holding
            if let updated = lookup[h.asset.symbol] { h.asset = updated }
            return h
        }
        let updatedWatchlist = watchlist.map { lookup[$0.symbol] ?? $0 }
        return (updatedPortfolio, updatedWatchlist)
    }

    // MARK: - Merge Helper

    /// Keep old metadata (id, name, fundamentals) but overwrite live fields from the API.
    /// 52-week data: prefer fresh API values, fall back to existing.
    func mergedAsset(old: Asset, api: Asset) -> Asset {
        Asset(
            id: old.id,
            symbol: old.symbol,
            name: old.name,
            price: api.price,
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
            exchange: old.exchange
        )
    }
}
