//
//  APIService.swift
//  Stock Tracker
//

import Foundation

// MARK: - API Service
class APIService {
    static let shared = APIService()
    
    // MARK: - API Keys & Base URL
    private let alpacaAPIKey = "PKZ4QQWBIYMMVFMAFWUQISEAN3"
    private let alpacaSecretKey = "HeDiacpbzaXc5jnyEV5winTTCZFXZnY1T7u8egj6toNL"
    private let alphaVantageKey = "SYFS9C88ZJNCR99S"
    private let newsAPIKey = "dd13a52efc424ea0951ec31374c3fddc"
    
    private let alpacaDataBaseURL = URL(string: "https://data.alpaca.markets")!
    
    private init() {}
    
    // MARK: - Historical Bars (now a proper instance method)
    func fetchBars(symbol: String, timeframe: String, multiplier: Int, range: TimeRange) async throws -> [AlpacaBar] {
        var components = URLComponents(
            url: alpacaDataBaseURL.appendingPathComponent("/v2/stocks/\(symbol)/bars"),
            resolvingAgainstBaseURL: true
        )!
        
        let calendar = Calendar.current
        let end = Date()
        let start: Date = {
            switch range {
            case .oneDay:
                return calendar.date(byAdding: .day, value: -2, to: end)!
            case .oneWeek:
                return calendar.date(byAdding: .weekOfYear, value: -1, to: end)!
            case .oneMonth:
                return calendar.date(byAdding: .month, value: -1, to: end)!
            case .threeMonths:
                return calendar.date(byAdding: .month, value: -3, to: end)!
            case .sixMonths:
                return calendar.date(byAdding: .month, value: -6, to: end)!
            case .ytd:
                let yearStart = calendar.date(from: calendar.dateComponents([.year], from: end))!
                return calendar.startOfDay(for: yearStart)
            case .oneYear:
                return calendar.date(byAdding: .year, value: -1, to: end)!
            default:
                return calendar.date(byAdding: .year, value: -1, to: end)!
            }
        }()
        
        components.queryItems = [
            URLQueryItem(name: "timeframe", value: "\(multiplier)\(timeframe)"),
            URLQueryItem(name: "start", value: ISO8601DateFormatter().string(from: start)),
            URLQueryItem(name: "end", value: ISO8601DateFormatter().string(from: end)),
            URLQueryItem(name: "limit", value: "1000")
        ]
        
        guard let url = components.url else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            "Basic \(Data("\(alpacaAPIKey):\(alpacaSecretKey)".utf8).base64EncodedString())",
            forHTTPHeaderField: "Authorization"
        )
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.invalidResponse
        }
        
        let decoded = try JSONDecoder().decode(AlpacaBarsResponse.self, from: data)
        return decoded.bars[symbol] ?? []
    }
}

// MARK: - Public API Extension
extension APIService {
    
    // MARK: - Historical Data (for charts)
    func fetchHistoricalData(symbol: String, range: TimeRange) async throws -> [PricePoint] {
        let upper = symbol.uppercased()
        
        let (timeframe, multiplier): (String, Int) = {
            switch range {
            case .oneDay:      return ("Minute", 15)
            case .oneWeek:     return ("Hour", 1)
            default:           return ("Day", 1)
            }
        }()
        
        let bars = try await fetchBars(
            symbol: upper,
            timeframe: timeframe,
            multiplier: multiplier,
            range: range
        )
        
        return bars.compactMap { bar in
            guard let date = ISO8601DateFormatter().date(from: bar.timestamp) else { return nil }
            return PricePoint(date: date, price: bar.close)
        }
        .sorted { $0.date < $1.date }
    }
    
    // MARK: - News
    func fetchNews() async throws -> [NewsArticle] {
        var components = URLComponents(string: "https://newsapi.org/v2/everything")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "apple OR tesla OR bitcoin OR stock market"),
            URLQueryItem(name: "language", value: "en"),
            URLQueryItem(name: "sortBy", value: "publishedAt"),
            URLQueryItem(name: "pageSize", value: "50"),
            URLQueryItem(name: "apiKey", value: newsAPIKey)
        ]
        
        guard let url = components.url else { throw APIError.invalidURL }
        
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw APIError.invalidResponse
        }
        
        let decoded = try JSONDecoder().decode(NewsAPIResponse.self, from: data)
        
        return decoded.articles.compactMap { article in
            guard let publishedAt = ISO8601DateFormatter().date(from: article.publishedAt) else { return nil }
            
            let text = (article.title + " " + (article.description ?? "")).uppercased()
            let symbolRegex = try? NSRegularExpression(pattern: "\\b[A-Z]{1,5}\\b")
            let matches = symbolRegex?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
            let symbols = matches.compactMap { match in
                String(text[Range(match.range, in: text)!])
            }
            
            return NewsArticle(
                title: article.title,
                source: article.source.name,
                url: article.url,
                imageURL: article.urlToImage,
                publishedAt: publishedAt,
                summary: article.description ?? "",
                relatedSymbols: Array(Set(symbols)).filter { $0.count >= 1 && $0.count <= 5 }
            )
        }
    }
    
    // MARK: - Symbol Search
    func fetchSymbolSearch(query: String, kind: AssetKind) async throws -> [SearchResult] {
        switch kind {
        case .stock:
            return try await searchAlphaVantage(query: query)
        case .crypto:
            return try await searchCoinGecko(query: query)
        }
    }
    
    private func searchAlphaVantage(query: String) async throws -> [SearchResult] {
        var components = URLComponents(string: "https://www.alphavantage.co/query")!
        components.queryItems = [
            URLQueryItem(name: "function", value: "SYMBOL_SEARCH"),
            URLQueryItem(name: "keywords", value: query),
            URLQueryItem(name: "apikey", value: alphaVantageKey)
        ]
        
        guard let url = components.url else { throw APIError.invalidURL }
        let (data, _) = try await URLSession.shared.data(from: url)
        
        let decoded = try JSONDecoder().decode(AlphaVantageSearchResponse.self, from: data)
        return decoded.bestMatches.map {
            SearchResult(symbol: $0.symbol, name: $0.name, id: $0.symbol)
        }
    }
    
    private func searchCoinGecko(query: String) async throws -> [SearchResult] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://api.coingecko.com/api/v3/search?query=\(encoded)") else {
            throw APIError.invalidURL
        }
        
        let (data, _) = try await URLSession.shared.data(from: url)
        let decoded = try JSONDecoder().decode(CoinGeckoSearchResponse.self, from: data)
        return decoded.coins.prefix(20).map {
            SearchResult(symbol: $0.symbol.uppercased(), name: $0.name, id: $0.id)
        }
    }
    
    // MARK: - Asset Details
    func fetchAssetDetails(identifier: String, kind: AssetKind, name: String) async throws -> Asset {
        switch kind {
        case .stock:
            return try await fetchStockQuote(symbol: identifier.uppercased())
        case .crypto:
            return try await fetchCryptoPrice(id: identifier)
        }
    }
    
    // MARK: - Mock Quotes (replace with real API later)
    func fetchStockQuote(symbol: String) async throws -> Asset {
        Asset(
            id: UUID(),
            symbol: symbol,
            name: symbol,
            price: 150.0 + Double.random(in: -20...20),
            change: Double.random(in: -5...5),
            changePercent: Double.random(in: -5...5),
            volume: 1_000_000,
            kind: .stock,
            exchange: "NYSE"
        )
    }
    
    func fetchCryptoPrice(id: String) async throws -> Asset {
        Asset(
            id: UUID(),
            symbol: id.uppercased(),
            name: id.capitalized,
            price: 60000.0 + Double.random(in: -5000...5000),
            change: Double.random(in: -5...5),
            changePercent: Double.random(in: -5...5),
            volume: 1000.0,
            kind: .crypto,
            exchange: "Binance"
        )
    }
}

// MARK: - Supporting Types (keep these if not defined elsewhere)
enum APIError: Error {
    case invalidURL
    case invalidResponse
    case noData
}

struct SearchResult {
    let symbol: String
    let name: String
    let id: String
}

struct AlphaVantageSearchResponse: Codable {
    let bestMatches: [AlphaMatch]
    
    struct AlphaMatch: Codable {
        let symbol: String
        let name: String
        
        enum CodingKeys: String, CodingKey {
            case symbol = "1. symbol"
            case name = "2. name"
        }
    }
}

struct CoinGeckoSearchResponse: Codable {
    let coins: [Coin]
    
    struct Coin: Codable {
        let id: String
        let symbol: String
        let name: String
    }
}

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
    
    struct NewsSource: Codable {
        let name: String
    }
}

struct AlpacaBarsResponse: Codable {
    let bars: [String: [AlpacaBar]]
}

struct AlpacaBar: Codable {
    let timestamp: String
        let date: Date        // Parsed timestamp
        let open: Double
        let high: Double
        let low: Double
        let close: Double
        let volume: Double    // Changed from Int to Double (API returns Double)
        
        enum CodingKeys: String, CodingKey {
            case timestamp = "t"
            case date = "d"
            case open = "o"
            case high = "h"
            case low = "l"
            case close = "c"
            case volume = "v"
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            
            // Parse timestamp string to Date
            let timestampString = try container.decode(String.self, forKey: .timestamp)
            self.timestamp = timestampString
            guard let parsedDate = ISO8601DateFormatter().date(from: timestampString) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [CodingKeys.date], debugDescription: "Invalid date format"))
            }
            self.date = parsedDate
            
            self.open = try container.decode(Double.self, forKey: .open)
            self.high = try container.decode(Double.self, forKey: .high)
            self.low = try container.decode(Double.self, forKey: .low)
            self.close = try container.decode(Double.self, forKey: .close)
            self.volume = try container.decode(Double.self, forKey: .volume)  // API returns Double
        }
    }
