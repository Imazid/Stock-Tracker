//
//  APIService.swift
//  Stock Tracker
//
//  Created by Ihtisham Mazid on 30/11/2025.
//

import Foundation

// MARK: - API Service
class APIService {
    static let shared = APIService()
    
    // MARK: - API Keys
    
    // Alpaca Market Data (STOCKS)
    // ⚠️ For production: move these out of source control (Info.plist / Keychain / .xcconfig).
    private let alpacaAPIKey: String = "PKZ4QQWBIYMMVFMAFWUQISEAN3"
    private let alpacaSecretKey: String = "HeDiacpbzaXc5jnyEV5winTTCZFXZnY1T7u8egj6toNL"
    
    // Alpha Vantage (only used for symbol SEARCH)
    private let alphaVantageKey = "SYFS9C88ZJNCR99S"
    
    // News API
    private let newsAPIKey = "dd13a52efc424ea0951ec31374c3fddc"
    
    // Base URLs
    private let alpacaDataBaseURL = URL(string: "https://data.alpaca.markets")!
    
    private init() {}
}

// MARK: - Public API

extension APIService {
    
    // MARK: - Fetch Stock Quote (Alpaca)
    
    /// Fetches the latest quote for a stock symbol using Alpaca Market Data.
    func fetchStockQuote(symbol: String) async throws -> Asset {
        let upper = symbol.uppercased()
        
        var components = URLComponents(
            url: alpacaDataBaseURL.appendingPathComponent("/v2/stocks/quotes/latest"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "symbols", value: upper),
            URLQueryItem(name: "feed", value: "iex") // free feed for dev
        ]
        
        guard let url = components?.url else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue(alpacaAPIKey, forHTTPHeaderField: "APCA-API-KEY-ID")
        request.setValue(alpacaSecretKey, forHTTPHeaderField: "APCA-API-SECRET-KEY")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response: response, data: data)
        
        let decoded = try JSONDecoder().decode(AlpacaLatestQuotesResponse.self, from: data)
        guard let quote = decoded.quotes[upper] else {
            throw APIError.noData
        }
        
        // Simple mid-price between bid and ask
        let mid = (quote.askPrice + quote.bidPrice) / 2.0
        
        // volume is not perfect here; we just approximate using bid/ask sizes
        let volDouble = Double(quote.bidSize + quote.askSize)
        
        return Asset(
            id: UUID(),
            symbol: upper,
            name: upper,           // you could later fetch /v2/assets for full company name
            price: mid,
            change: 0,             // no day-change directly in this endpoint
            changePercent: 0,
            volume: volDouble,
            kind: .stock
        )
    }
    
    // MARK: - Fetch Crypto Price (CoinGecko - Free, no key needed!)
    
    func fetchCryptoPrice(id: String) async throws -> Asset {
        // CoinGecko uses IDs like: bitcoin, ethereum, solana, cardano, etc.
        let urlString =
        "https://api.coingecko.com/api/v3/simple/price" +
        "?ids=\(id)" +
        "&vs_currencies=usd" +
        "&include_24hr_change=true" +
        "&include_24hr_vol=true"
        
        guard let url = URL(string: urlString) else {
            throw APIError.invalidURL
        }
        
        let (data, response) = try await URLSession.shared.data(from: url)
        try Self.validate(response: response, data: data)
        
        let decoded = try JSONDecoder().decode([String: CoinGeckoPrice].self, from: data)
        
        guard let crypto = decoded[id] else {
            throw APIError.noData
        }
        
        // 24h change %
        let pct = crypto.usd24hChange ?? 0
        // absolute change in USD
        let change = crypto.usd * pct / 100.0
        
        return Asset(
            id: UUID(),
            symbol: id.uppercased(),
            name: id.capitalized,
            price: crypto.usd,
            change: change,
            changePercent: pct,
            volume: crypto.usd24hVol ?? 0,
            kind: .crypto
        )
    }
    
    // MARK: - Search Stocks (Alpha Vantage)
    
    func searchStocks(query: String) async throws -> [StockSearchResult] {
        let urlString =
        "https://www.alphavantage.co/query?function=SYMBOL_SEARCH&keywords=\(query)&apikey=\(alphaVantageKey)"
        
        guard let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: encoded) else {
            throw APIError.invalidURL
        }
        
        let (data, response) = try await URLSession.shared.data(from: url)
        try Self.validate(response: response, data: data)
        
        let decoded = try JSONDecoder().decode(AlphaVantageSearchResponse.self, from: data)
        return decoded.bestMatches ?? []
    }
    
    // MARK: - Fetch News (NewsAPI.org)
    
    func fetchNews(for symbols: [String]) async throws -> [NewsArticle] {
        let joined = symbols.joined(separator: " OR ")
        let urlString =
        "https://newsapi.org/v2/everything?q=\(joined)&language=en&sortBy=publishedAt&pageSize=20&apiKey=\(newsAPIKey)"
        
        guard let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: encoded) else {
            throw APIError.invalidURL
        }
        
        let (data, response) = try await URLSession.shared.data(from: url)
        try Self.validate(response: response, data: data)
        
        let decoded = try JSONDecoder().decode(NewsAPIResponse.self, from: data)
        
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]
        
        return decoded.articles.map { article in
            let publishedDate =
            isoFormatter.date(from: article.publishedAt) ??
            fallbackFormatter.date(from: article.publishedAt) ??
            Date()
            
            return NewsArticle(
                title: article.title,
                source: article.source.name,
                url: article.url,
                imageURL: article.urlToImage,
                publishedAt: publishedDate,
                summary: article.description ?? "",
                relatedSymbols: symbols
            )
        }
    }
    
    // MARK: - Fetch Historical Data (Alpaca)
    
    func fetchHistoricalData(symbol: String, range: TimeRange) async throws -> [PricePoint] {
        let upper = symbol.uppercased()
        
        let (start, end, timeframe) = dateWindow(for: range)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        
        var components = URLComponents(
            url: alpacaDataBaseURL.appendingPathComponent("/v2/stocks/bars"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "symbols", value: upper),
            URLQueryItem(name: "timeframe", value: timeframe),
            URLQueryItem(name: "start", value: iso.string(from: start)),
            URLQueryItem(name: "end", value: iso.string(from: end)),
            URLQueryItem(name: "limit", value: "1000"),
            URLQueryItem(name: "feed", value: "iex")
        ]
        
        guard let url = components?.url else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue(alpacaAPIKey, forHTTPHeaderField: "APCA-API-KEY-ID")
        request.setValue(alpacaSecretKey, forHTTPHeaderField: "APCA-API-SECRET-KEY")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response: response, data: data)
        
        let decoded = try JSONDecoder().decode(AlpacaBarsResponse.self, from: data)
        guard let bars = decoded.bars[upper], !bars.isEmpty else {
            throw APIError.noData
        }
        
        let points: [PricePoint] = bars.compactMap { bar in
            guard let date = iso.date(from: bar.timestamp) else { return nil }
            return PricePoint(date: date, price: bar.close)
        }
        .sorted { $0.date < $1.date }
        
        // Your existing UI further trims based on TimeRange, so here we just return all.
        return points
    }
}

// MARK: - Helpers

private extension APIService {
    
    static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.decodingError
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            if http.statusCode == 401 {
                throw APIError.apiKeyInvalid
            } else if http.statusCode == 429 {
                throw APIError.rateLimitExceeded
            } else {
                throw APIError.decodingError
            }
        }
        guard !data.isEmpty else {
            throw APIError.noData
        }
    }
    
    /// Maps your `TimeRange` to (start, end, timeframe string) for Alpaca bars.
    func dateWindow(for range: TimeRange) -> (Date, Date, String) {
        let now = Date()
        let cal = Calendar.current
        
        func daysAgo(_ days: Int) -> Date {
            cal.date(byAdding: .day, value: -days, to: now) ?? now
        }
        
        switch range {
        case .oneDay:
            return (daysAgo(1), now, "5Min")
        case .oneWeek:
            return (daysAgo(7), now, "15Min")
        case .oneMonth:
            return (daysAgo(30), now, "1Hour")
        case .threeMonths:
            return (daysAgo(90), now, "1Day")
        case .sixMonths:
            return (daysAgo(180), now, "1Day")
        case .ytd:
            let startOfYear = cal.date(from: cal.dateComponents([.year], from: now)) ?? daysAgo(365)
            return (startOfYear, now, "1Day")
        case .oneYear:
            return (daysAgo(365), now, "1Day")
        case .twoYears:
            return (daysAgo(365 * 2), now, "1Day")
        case .fiveYears:
            return (daysAgo(365 * 5), now, "1Week")
        case .tenYears:
            return (daysAgo(365 * 10), now, "1Month")
        case .all:
            return (daysAgo(365 * 15), now, "1Month")
        }
    }
}

// MARK: - API Errors (unchanged from your original file)

enum APIError: Error, LocalizedError {
    case invalidURL
    case noData
    case decodingError
    case rateLimitExceeded
    case apiKeyInvalid
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .noData: return "No data received"
        case .decodingError: return "Failed to decode response"
        case .rateLimitExceeded: return "API rate limit exceeded"
        case .apiKeyInvalid: return "Invalid API key"
        }
    }
}

// MARK: - Alpha Vantage Search DTOs

struct AlphaVantageQuoteResponse: Codable {
    let globalQuote: GlobalQuote?
    
    enum CodingKeys: String, CodingKey {
        case globalQuote = "Global Quote"
    }
}

struct GlobalQuote: Codable {
    let symbol: String
    let price: String
    let change: String
    let changePercent: String
    let volume: String
    
    enum CodingKeys: String, CodingKey {
        case symbol = "01. symbol"
        case price = "05. price"
        case change = "09. change"
        case changePercent = "10. change percent"
        case volume = "06. volume"
    }
}

struct AlphaVantageSearchResponse: Codable {
    let bestMatches: [StockSearchResult]?
    
    enum CodingKeys: String, CodingKey {
        case bestMatches = "bestMatches"
    }
}

struct StockSearchResult: Identifiable, Codable {
    let id = UUID()
    let symbol: String
    let name: String
    let type: String
    let region: String
    
    enum CodingKeys: String, CodingKey {
        case symbol = "1. symbol"
        case name = "2. name"
        case type = "3. type"
        case region = "4. region"
    }
}

// MARK: - Alpaca DTOs

struct AlpacaLatestQuotesResponse: Codable {
    let quotes: [String: AlpacaQuote]
}

struct AlpacaQuote: Codable {
    let askPrice: Double      // ap
    let askSize: Int          // as
    let bidPrice: Double      // bp
    let bidSize: Int          // bs
    let timestamp: String     // t
    
    enum CodingKeys: String, CodingKey {
        case askPrice = "ap"
        case askSize = "as"
        case bidPrice = "bp"
        case bidSize = "bs"
        case timestamp = "t"
    }
}

struct AlpacaBarsResponse: Codable {
    let bars: [String: [AlpacaBar]]
}

struct AlpacaBar: Codable {
    let timestamp: String // t
    let open: Double      // o
    let high: Double      // h
    let low: Double       // l
    let close: Double     // c
    let volume: Int       // v
    
    enum CodingKeys: String, CodingKey {
        case timestamp = "t"
        case open = "o"
        case high = "h"
        case low = "l"
        case close = "c"
        case volume = "v"
    }
}

// MARK: - CoinGecko DTO

struct CoinGeckoPrice: Codable {
    let usd: Double
    let usd24hChange: Double?
    let usd24hVol: Double?
    
    enum CodingKeys: String, CodingKey {
        case usd
        case usd24hChange = "usd_24h_change"
        case usd24hVol = "usd_24h_vol"
    }
}

// MARK: - NewsAPI DTOs

struct NewsAPIResponse: Codable {
    let articles: [NewsAPIArticle]
}

struct NewsAPIArticle: Codable {
    let source: NewsSource
    let title: String
    let description: String?
    let url: String
    let urlToImage: String?
    let publishedAt: String
}

struct NewsSource: Codable {
    let name: String
}
