//
//  APIService.swift
//  Stock Tracker
//
//  SECURITY: Rate-limited, timeout-configured, with input sanitization.
//

import Foundation
import OSLog

// MARK: - API Service
class APIService {
    static let shared = APIService()

    // MARK: - API Keys (loaded from Keychain via SecretsConfig)
    private var alpacaAPIKey: String { SecretsConfig.alpacaAPIKey }
    private var alpacaSecretKey: String { SecretsConfig.alpacaSecretKey }
    private var alphaVantageKey: String { SecretsConfig.alphaVantageKey }
    private var finnhubAPIKey: String { SecretsConfig.finnhubAPIKey }
    // Cursor for Finnhub news pagination (minId = fetch articles older than this id)
    private var finnhubNewsMinId: Int? = nil

    private let alpacaDataBaseURL = URL(string: "https://data.alpaca.markets")!

    // MARK: - Secure URLSession with timeouts
    private let secureSession: URLSession = SecureURLSessionFactory.makeSecureSession(timeoutInterval: 30)

    private init() {}

    // MARK: - API Status Checker

    func checkAPIStatus() async -> [String: Bool] {
        var status: [String: Bool] = [:]

        status["Alpaca"] = await checkEndpoint(
            url: URL(string: "https://data.alpaca.markets/v2/stocks/AAPL/quotes/latest")!,
            endpoint: "alpaca"
        )
        status["Alpha Vantage"] = await checkEndpoint(
            url: URL(string: "https://www.alphavantage.co/query?function=TIME_SERIES_INTRADAY&symbol=IBM&interval=5min&apikey=demo")!,
            endpoint: "alphaVantage"
        )
        status["Finnhub"] = await checkEndpoint(
            url: URL(string: "\(Constants.URLs.finnhub)/news?category=general&token=\(finnhubAPIKey)")!,
            endpoint: "finnhub"
        )

        return status
    }

    private func checkEndpoint(url: URL, endpoint: String) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"

        // Add auth headers per service
        if endpoint == "alpaca" {
            request.setValue(
                "Basic \(Data("\(alpacaAPIKey):\(alpacaSecretKey)".utf8).base64EncodedString())",
                forHTTPHeaderField: "Authorization"
            )
        }

        do {
            let (_, response) = try await secureSession.rateLimitedData(
                for: request,
                endpoint: endpoint,
                config: .default
            )
            if let httpResponse = response as? HTTPURLResponse {
                return (200...299).contains(httpResponse.statusCode)
            }
            return false
        } catch {
            return false
        }
    }

    // MARK: - Historical Bars

    func fetchBars(symbol: String, timeframe: String, multiplier: Int, range: TimeRange) async throws -> [AlpacaBar] {
        let sanitizedSymbol = InputSanitizer.sanitizeSymbol(symbol)

        var components = URLComponents(
            url: alpacaDataBaseURL.appendingPathComponent("/v2/stocks/\(sanitizedSymbol)/bars"),
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
            case .twoYears:
                return calendar.date(byAdding: .year, value: -2, to: end)!
            case .fiveYears:
                return calendar.date(byAdding: .year, value: -5, to: end)!
            case .tenYears:
                return calendar.date(byAdding: .year, value: -10, to: end)!
            case .all:
                return calendar.date(byAdding: .year, value: -20, to: end)!
            }
        }()

        components.queryItems = [
            URLQueryItem(name: "timeframe", value: "\(multiplier)\(timeframe)"),
            URLQueryItem(name: "start", value: ISO8601DateFormatter().string(from: start)),
            URLQueryItem(name: "end", value: ISO8601DateFormatter().string(from: end)),
            URLQueryItem(name: "limit", value: "1000"),
            URLQueryItem(name: "feed", value: "iex")
        ]

        guard let url = components.url else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // Alpaca bars requires native key headers (Basic auth returns 401 on this endpoint)
        request.setValue(alpacaAPIKey, forHTTPHeaderField: "APCA-API-KEY-ID")
        request.setValue(alpacaSecretKey, forHTTPHeaderField: "APCA-API-SECRET-KEY")

        let (data, response) = try await secureSession.rateLimitedData(
            for: request,
            endpoint: "alpaca",
            config: .alpaca
        )

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            if let httpResponse = response as? HTTPURLResponse {
                AppLogger.api.error("Alpaca bars returned HTTP \(httpResponse.statusCode) for \(sanitizedSymbol)")
                throw APIError.serverError(statusCode: httpResponse.statusCode)
            }
            throw APIError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(AlpacaBarsResponse.self, from: data)
        return decoded.bars
    }

    /// Fetch bars with explicit start/end dates (used for live candle updates).
    func fetchLatestBars(symbol: String, timeframe: String, multiplier: Int, start: Date, end: Date, limit: Int = 5) async throws -> [AlpacaBar] {
        let sanitizedSymbol = InputSanitizer.sanitizeSymbol(symbol)

        var components = URLComponents(
            url: alpacaDataBaseURL.appendingPathComponent("/v2/stocks/\(sanitizedSymbol)/bars"),
            resolvingAgainstBaseURL: true
        )!

        let formatter = ISO8601DateFormatter()
        components.queryItems = [
            URLQueryItem(name: "timeframe", value: "\(multiplier)\(timeframe)"),
            URLQueryItem(name: "start", value: formatter.string(from: start)),
            URLQueryItem(name: "end", value: formatter.string(from: end)),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "feed", value: "iex")
        ]

        guard let url = components.url else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(alpacaAPIKey, forHTTPHeaderField: "APCA-API-KEY-ID")
        request.setValue(alpacaSecretKey, forHTTPHeaderField: "APCA-API-SECRET-KEY")

        let (data, response) = try await secureSession.rateLimitedData(
            for: request,
            endpoint: "alpaca",
            config: .alpaca
        )

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            if let httpResponse = response as? HTTPURLResponse {
                AppLogger.api.error("Alpaca latest bars returned HTTP \(httpResponse.statusCode) for \(sanitizedSymbol)")
                throw APIError.serverError(statusCode: httpResponse.statusCode)
            }
            throw APIError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(AlpacaBarsResponse.self, from: data)
        return decoded.bars
    }
}

// MARK: - Public API Extension
extension APIService {

    // MARK: - Historical Data (for charts)
    func fetchHistoricalData(symbol: String, range: TimeRange) async throws -> [PricePoint] {
        let upper = InputSanitizer.sanitizeSymbol(symbol)

        let (timeframe, multiplier): (String, Int) = {
            switch range {
            case .oneDay:                          return ("Minute", 15)
            case .oneWeek:                         return ("Hour", 1)
            case .oneMonth, .threeMonths,
                 .sixMonths, .ytd, .oneYear:       return ("Day", 1)
            case .twoYears:                        return ("Day", 1)
            case .fiveYears, .tenYears, .all:      return ("Week", 1)
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

    /// Fetch price history for a crypto asset via CoinGecko market chart endpoint.
    func fetchCryptoHistory(id: String, range: TimeRange) async throws -> [PricePoint] {
        let days: String = {
            switch range {
            case .oneDay:      return "1"
            case .oneWeek:     return "7"
            case .oneMonth:    return "30"
            case .threeMonths: return "90"
            case .sixMonths:   return "180"
            case .ytd:
                let cal = Calendar.current
                let day = cal.ordinality(of: .day, in: .year, for: Date()) ?? 90
                return String(day)
            case .oneYear:     return "365"
            case .twoYears:    return "730"
            case .fiveYears:   return "1825"
            case .tenYears:    return "3650"
            case .all:         return "max"
            }
        }()

        var components = URLComponents(string: "https://api.coingecko.com/api/v3/coins/\(id)/market_chart")!
        components.queryItems = [
            URLQueryItem(name: "vs_currency", value: "usd"),
            URLQueryItem(name: "days", value: days)
        ]
        guard let url = components.url else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let demoKey = SecretsConfig.coinGeckoAPIKey
        if !demoKey.isEmpty {
            request.setValue(demoKey, forHTTPHeaderField: "x-cg-demo-api-key")
        }

        let (data, response) = try await secureSession.rateLimitedData(
            for: request,
            endpoint: "coinGecko",
            config: .coinGecko
        )

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            AppLogger.api.error("CoinGecko history HTTP \(http.statusCode) for \(id)")
            throw APIError.serverError(statusCode: http.statusCode)
        }

        struct CoinGeckoChartResponse: Decodable { let prices: [[Double]] }
        let decoded = try JSONDecoder().decode(CoinGeckoChartResponse.self, from: data)
        return decoded.prices.compactMap { pair in
            guard pair.count == 2 else { return nil }
            return PricePoint(date: Date(timeIntervalSince1970: pair[0] / 1000), price: pair[1])
        }
        .sorted { $0.date < $1.date }
    }

    // MARK: - News (Finnhub — paginated via minId)

    /// Fetch a page of financial news from Finnhub.
    /// Page 1 fetches the latest articles. Subsequent pages use `minId` to load older articles.
    func fetchNews(page: Int = 1, pageSize: Int = Constants.Pagination.newsPageSize) async throws -> [NewsArticle] {
        guard !finnhubAPIKey.isEmpty else {
            AppLogger.news.warning("Finnhub API key not configured — returning empty news")
            return []
        }

        // Reset pagination cursor on fresh fetch
        if page == 1 { finnhubNewsMinId = nil }

        var components = URLComponents(string: "\(Constants.URLs.finnhub)/news")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "category", value: "general"),
            URLQueryItem(name: "token", value: finnhubAPIKey)
        ]
        if let minId = finnhubNewsMinId {
            queryItems.append(URLQueryItem(name: "minId", value: "\(minId)"))
        }
        components.queryItems = queryItems

        guard let url = components.url else { throw APIError.invalidURL }

        let request = URLRequest(url: url)
        let (data, response) = try await secureSession.rateLimitedData(
            for: request,
            endpoint: "finnhub",
            config: .newsAPI
        )
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            if let httpResponse = response as? HTTPURLResponse {
                throw APIError.serverError(statusCode: httpResponse.statusCode)
            }
            throw APIError.invalidResponse
        }

        let items = try JSONDecoder().decode([FinnhubNewsItem].self, from: data)
        AppLogger.news.debug("Fetched Finnhub news page \(page): \(items.count) articles")

        // Store the minimum id for next-page pagination
        if let minId = items.map({ $0.id }).min() {
            finnhubNewsMinId = minId
        }

        let pageItems = Array(items.prefix(pageSize))
        return pageItems.map { item in
            let publishedAt = Date(timeIntervalSince1970: TimeInterval(item.datetime))
            return NewsArticle(
                title: item.headline,
                source: item.source,
                url: item.url,
                imageURL: item.image.isEmpty ? nil : item.image,
                publishedAt: publishedAt,
                summary: item.summary,
                relatedSymbols: item.related.isEmpty ? [] : [item.related]
            )
        }
    }

    // MARK: - Fiscal.ai Fundamentals

    /// Fetches company fundamentals (P/E, EPS, market cap, beta, etc.) from Fiscal.ai.
    /// Uses the company profile + ratios endpoints. Free tier: 250 calls/day.
    func fetchFiscalFundamentals(symbol: String, exchange: String = "") async throws -> FiscalFundamentals {
        let sanitized = InputSanitizer.sanitizeSymbol(symbol)
        let apiKey = SecretsConfig.fiscalAIAPIKey
        guard !apiKey.isEmpty else {
            AppLogger.api.warning("Fiscal.ai API key not configured")
            throw APIError.noData
        }

        // Only supported for free-tier symbols
        guard let companyKey = Self.fiscalFreeTierSymbols[sanitized] else {
            throw APIError.noData
        }

        // Fetch profile and ratios in parallel
        async let profileData = fetchFiscalEndpoint(
            path: "/v2/company/profile",
            companyKey: companyKey,
            apiKey: apiKey
        )
        async let ratiosData = fetchFiscalEndpoint(
            path: "/v1/company/ratios",
            companyKey: companyKey,
            apiKey: apiKey
        )

        let profile = try? JSONDecoder().decode(FiscalCompanyProfile.self, from: try await profileData)
        let ratiosResponse = try? JSONDecoder().decode(FiscalRatiosResponse.self, from: try await ratiosData)

        // Take the most recent ratio entry
        let latestRatios = ratiosResponse?.data?.first

        return FiscalFundamentals(
            marketCap: profile?.marketCap,
            peRatio: latestRatios?.peRatio,
            eps: latestRatios?.eps,
            beta: profile?.beta,
            dividend: latestRatios?.dividendYield,
            week52High: profile?.week52High,
            week52Low: profile?.week52Low,
            avgVolume: profile?.avgVolume,
            revenue: latestRatios?.revenue,
            profitMargin: latestRatios?.profitMargin,
            roe: latestRatios?.roe,
            debtToEquity: latestRatios?.debtToEquity,
            currentRatio: latestRatios?.currentRatio,
            sector: profile?.sector,
            industry: profile?.industry,
            description: profile?.description,
            employees: profile?.employees
        )
    }

    private func fetchFiscalEndpoint(path: String, companyKey: String, apiKey: String) async throws -> Data {
        var components = URLComponents(string: "\(Constants.URLs.fiscalAI)\(path)")!
        components.queryItems = [
            URLQueryItem(name: "companyKey", value: companyKey),
            URLQueryItem(name: "apiKey", value: apiKey)
        ]

        guard let url = components.url else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await secureSession.rateLimitedData(
            for: request,
            endpoint: "fiscalAI",
            config: .fiscalAI
        )

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            if let httpResponse = response as? HTTPURLResponse {
                AppLogger.api.error("Fiscal.ai returned HTTP \(httpResponse.statusCode) for \(companyKey)")
                throw APIError.serverError(statusCode: httpResponse.statusCode)
            }
            throw APIError.invalidResponse
        }

        return data
    }

    // Fiscal.ai free tier supported companies (companyKey → symbol)
    static let fiscalFreeTierSymbols: [String: String] = [
        "MSFT": "NASDAQ_MSFT", "NVDA": "NASDAQ_NVDA", "AMZN": "NASDAQ_AMZN",
        "GOOG": "NASDAQ_GOOG", "TSLA": "NASDAQ_TSLA", "AVGO": "NASDAQ_AVGO",
        "NFLX": "NASDAQ_NFLX", "AMGN": "NASDAQ_AMGN", "EQIX": "NASDAQ_EQIX",
        "ZM": "NASDAQ_ZM", "IBKR": "NASDAQ_IBKR", "FFIN": "NASDAQ_FFIN",
        "LLY": "NYSE_LLY", "V": "NYSE_V", "MA": "NYSE_MA",
        "PG": "NYSE_PG", "MCD": "NYSE_MCD", "CAT": "NYSE_CAT",
        "UBER": "NYSE_UBER", "MDT": "NYSE_MDT", "DUK": "NYSE_DUK",
        "BRO": "NYSE_BRO", "MKC": "NYSE_MKC", "RYAN": "NYSE_RYAN",
        "MOH": "NYSE_MOH", "LH": "NYSE_LH", "CRBG": "NYSE_CRBG",
        "CFG": "NYSE_CFG"
    ]

    /// Returns true if this symbol is in the Fiscal.ai free tier coverage.
    static func isFiscalSupported(symbol: String) -> Bool {
        fiscalFreeTierSymbols[symbol.uppercased()] != nil
    }

    // MARK: - Finnhub Earnings

    func fetchFinnhubEarnings(symbol: String) async throws -> [FinnhubEarningsItem] {
        let sanitized = InputSanitizer.sanitizeSymbol(symbol)
        guard !finnhubAPIKey.isEmpty else { return [] }

        var components = URLComponents(string: "\(Constants.URLs.finnhub)/stock/earnings")!
        components.queryItems = [
            URLQueryItem(name: "symbol", value: sanitized),
            URLQueryItem(name: "token", value: finnhubAPIKey)
        ]
        guard let url = components.url else { throw APIError.invalidURL }

        let (data, response) = try await secureSession.rateLimitedData(
            for: URLRequest(url: url),
            endpoint: "finnhub",
            config: .newsAPI
        )
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            if let http = response as? HTTPURLResponse {
                throw APIError.serverError(statusCode: http.statusCode)
            }
            throw APIError.invalidResponse
        }
        return try JSONDecoder().decode([FinnhubEarningsItem].self, from: data)
    }

    // MARK: - Finnhub Recommendations

    func fetchFinnhubRecommendations(symbol: String) async throws -> [FinnhubRecommendationItem] {
        let sanitized = InputSanitizer.sanitizeSymbol(symbol)
        guard !finnhubAPIKey.isEmpty else { return [] }

        var components = URLComponents(string: "\(Constants.URLs.finnhub)/stock/recommendation")!
        components.queryItems = [
            URLQueryItem(name: "symbol", value: sanitized),
            URLQueryItem(name: "token", value: finnhubAPIKey)
        ]
        guard let url = components.url else { throw APIError.invalidURL }

        let (data, response) = try await secureSession.rateLimitedData(
            for: URLRequest(url: url),
            endpoint: "finnhub",
            config: .newsAPI
        )
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            if let http = response as? HTTPURLResponse {
                throw APIError.serverError(statusCode: http.statusCode)
            }
            throw APIError.invalidResponse
        }
        return try JSONDecoder().decode([FinnhubRecommendationItem].self, from: data)
    }

    // MARK: - Finnhub Upgrade/Downgrade

    func fetchFinnhubUpgradeDowngrade(symbol: String, limit: Int = 10) async throws -> [FinnhubUpgradeDowngrade] {
        let sanitized = InputSanitizer.sanitizeSymbol(symbol)
        guard !finnhubAPIKey.isEmpty else { return [] }

        let calendar = Calendar.current
        let now = Date()
        let sixMonthsAgo = calendar.date(byAdding: .month, value: -6, to: now)!
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        dateFmt.locale = Locale(identifier: "en_US_POSIX")

        var components = URLComponents(string: "\(Constants.URLs.finnhub)/stock/upgrade-downgrade")!
        components.queryItems = [
            URLQueryItem(name: "symbol", value: sanitized),
            URLQueryItem(name: "from", value: dateFmt.string(from: sixMonthsAgo)),
            URLQueryItem(name: "to", value: dateFmt.string(from: now)),
            URLQueryItem(name: "token", value: finnhubAPIKey)
        ]
        guard let url = components.url else { throw APIError.invalidURL }

        let (data, response) = try await secureSession.rateLimitedData(
            for: URLRequest(url: url),
            endpoint: "finnhub",
            config: .newsAPI
        )
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            if let http = response as? HTTPURLResponse {
                throw APIError.serverError(statusCode: http.statusCode)
            }
            throw APIError.invalidResponse
        }
        let items = try JSONDecoder().decode([FinnhubUpgradeDowngrade].self, from: data)
        return Array(items.prefix(limit))
    }

    // MARK: - Finnhub Fund Ownership (13F filings)

    func fetchFinnhubFundOwnership(symbol: String) async throws -> FinnhubFundOwnership? {
        let sanitized = InputSanitizer.sanitizeSymbol(symbol)
        guard !finnhubAPIKey.isEmpty else { return nil }

        var components = URLComponents(string: "\(Constants.URLs.finnhub)/stock/fund-ownership")!
        components.queryItems = [
            URLQueryItem(name: "symbol", value: sanitized),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "token", value: finnhubAPIKey)
        ]
        guard let url = components.url else { throw APIError.invalidURL }

        let (data, response) = try await secureSession.rateLimitedData(
            for: URLRequest(url: url),
            endpoint: "finnhub",
            config: .newsAPI
        )
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            if let http = response as? HTTPURLResponse {
                throw APIError.serverError(statusCode: http.statusCode)
            }
            throw APIError.invalidResponse
        }
        return try JSONDecoder().decode(FinnhubFundOwnership.self, from: data)
    }

    // MARK: - Symbol Search
    func fetchSymbolSearch(query: String, kind: AssetKind) async throws -> [SearchResult] {
        let sanitizedQuery = InputSanitizer.sanitizeSearchQuery(query)
        guard !sanitizedQuery.isEmpty else { return [] }

        switch kind {
        case .stock:
            // Yahoo Finance returns ASX + international results; Alpha Vantage misses ASX entirely
            return try await searchYahooFinance(query: sanitizedQuery)
        case .crypto:
            return try await searchCoinGecko(query: sanitizedQuery)
        }
    }

    private func searchYahooFinance(query: String) async throws -> [SearchResult] {
        var components = URLComponents(string: "\(Constants.URLs.yahooFinance)/v1/finance/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "quotesCount", value: "15"),
            URLQueryItem(name: "newsCount", value: "0")
        ]
        guard let url = components.url else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await secureSession.rateLimitedData(
            for: request,
            endpoint: "yahoo",
            config: .yahoo
        )

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let quotes = json["quotes"] as? [[String: Any]] else { return [] }

        return quotes.compactMap { q -> SearchResult? in
            guard let symbol = q["symbol"] as? String,
                  let name = q["shortname"] as? String ?? q["longname"] as? String,
                  let quoteType = q["quoteType"] as? String,
                  quoteType == "EQUITY" else { return nil }

            let exchDisp = q["exchDisp"] as? String ?? ""
            let exchange: String
            if exchDisp.contains("Australian") || symbol.hasSuffix(".AX") {
                exchange = "ASX"
            } else {
                exchange = ""
            }

            // Use the display symbol (strip .AX for ASX stocks to match our convention)
            let displaySymbol = symbol.hasSuffix(".AX")
                ? String(symbol.dropLast(3))
                : symbol

            return SearchResult(
                symbol: displaySymbol,
                name: name,
                id: displaySymbol,
                exchange: exchange,
                region: exchDisp,
                currency: q["currency"] as? String ?? "USD"
            )
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

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, _) = try await secureSession.rateLimitedData(
            for: request,
            endpoint: "alphaVantage",
            config: .alphaVantage
        )

        let decoded = try JSONDecoder().decode(AlphaVantageSearchResponse.self, from: data)
        // bestMatches is absent when Alpha Vantage returns a rate-limit note or error message
        return (decoded.bestMatches ?? []).map {
            // Alpha Vantage returns ASX symbols with ".AX" suffix
            let exchange = $0.region.lowercased().contains("australia") ? "ASX" : ""
            return SearchResult(
                symbol: $0.symbol,
                name: $0.name,
                id: $0.symbol,
                exchange: exchange,
                region: $0.region,
                currency: $0.currency
            )
        }
    }

    private func searchCoinGecko(query: String) async throws -> [SearchResult] {
        // SECURITY: Use URLComponents for proper encoding instead of manual percent encoding
        var components = URLComponents(string: "https://api.coingecko.com/api/v3/search")!
        components.queryItems = [
            URLQueryItem(name: "query", value: query)
        ]

        guard let url = components.url else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, _) = try await secureSession.rateLimitedData(
            for: request,
            endpoint: "coinGecko",
            config: .coinGecko
        )
        let decoded = try JSONDecoder().decode(CoinGeckoSearchResponse.self, from: data)
        return decoded.coins.prefix(20).map {
            SearchResult(symbol: $0.symbol.uppercased(), name: $0.name, id: $0.id)
        }
    }

    // MARK: - Asset Details
    func fetchAssetDetails(identifier: String, kind: AssetKind, name: String, exchange: String = "") async throws -> Asset {
        switch kind {
        case .stock:
            let sanitized = InputSanitizer.sanitizeSymbol(identifier)
            // Route ASX stocks through Yahoo Finance
            if exchange == "ASX" || sanitized.hasSuffix(".AX")
                || QuoteService.popularASXSymbols.contains(sanitized.uppercased()) {
                let yahooSymbol = sanitized.hasSuffix(".AX") ? sanitized : "\(sanitized).AX"
                return try await fetchYahooQuote(symbol: yahooSymbol, name: name)
            }
            return try await fetchStockQuote(symbol: sanitized)
        case .crypto:
            return try await fetchCryptoPrice(id: identifier)
        }
    }

    // MARK: - Quotes

    /// Fetches latest trade price + daily change from Alpaca snapshot endpoint.
    func fetchStockQuote(symbol: String) async throws -> Asset {
        let sanitizedSymbol = InputSanitizer.sanitizeSymbol(symbol)

        // feed=iex uses the IEX free feed; without this, free-plan accounts receive 403
        guard let url = URL(string: "https://data.alpaca.markets/v2/stocks/\(sanitizedSymbol)/snapshot?feed=iex") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            "Basic \(Data("\(alpacaAPIKey):\(alpacaSecretKey)".utf8).base64EncodedString())",
            forHTTPHeaderField: "Authorization"
        )

        let (data, response) = try await secureSession.rateLimitedData(
            for: request,
            endpoint: "alpaca",
            config: .alpaca
        )

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            if let httpResponse = response as? HTTPURLResponse {
                AppLogger.api.error("Alpaca snapshot returned HTTP \(httpResponse.statusCode) for \(sanitizedSymbol)")
                throw APIError.serverError(statusCode: httpResponse.statusCode)
            }
            throw APIError.invalidResponse
        }

        let snapshot = try JSONDecoder().decode(AlpacaSnapshot.self, from: data)

        let price = snapshot.latestTrade?.price ?? snapshot.latestQuote?.askPrice ?? 0
        let prevClose = snapshot.prevDailyBar?.close ?? price
        let change = price - prevClose
        let changePercent = prevClose > 0 ? (change / prevClose) * 100 : 0
        let volume = snapshot.dailyBar?.volume ?? 0

        return Asset(
            id: UUID(),
            symbol: sanitizedSymbol,
            name: sanitizedSymbol,
            price: price,
            change: change,
            changePercent: changePercent,
            volume: volume,
            kind: .stock,
            exchange: "NYSE"
        )
    }

    /// Fetches current price + 24h change from CoinGecko simple price endpoint.
    func fetchCryptoPrice(id: String) async throws -> Asset {
        var components = URLComponents(string: "https://api.coingecko.com/api/v3/simple/price")!
        components.queryItems = [
            URLQueryItem(name: "ids", value: id),
            URLQueryItem(name: "vs_currencies", value: "usd"),
            URLQueryItem(name: "include_24hr_change", value: "true"),
            URLQueryItem(name: "include_24hr_vol", value: "true")
        ]

        guard let url = components.url else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let demoKey = SecretsConfig.coinGeckoAPIKey
        if !demoKey.isEmpty {
            request.setValue(demoKey, forHTTPHeaderField: "x-cg-demo-api-key")
        }

        let (data, _) = try await secureSession.rateLimitedData(
            for: request,
            endpoint: "coinGecko",
            config: .coinGecko
        )

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let coinData = json[id] as? [String: Double] else {
            throw APIError.noData
        }

        let price = coinData["usd"] ?? 0
        let changePercent = coinData["usd_24h_change"] ?? 0
        let change = price * changePercent / 100
        let volume = coinData["usd_24h_vol"] ?? 0
        let symbol = Self.cryptoSymbolMap[id] ?? id.uppercased()

        return Asset(
            id: UUID(),
            symbol: symbol,
            name: id.split(separator: "-").map { $0.capitalized }.joined(separator: " "),
            price: price,
            change: change,
            changePercent: changePercent,
            volume: volume,
            kind: .crypto,
            exchange: "CoinGecko"
        )
    }

    /// Fetch prices for multiple crypto IDs in a single CoinGecko request.
    /// Returns a dict of [coinGeckoId: Asset].
    func fetchCryptoPricesBatch(ids: [String]) async throws -> [String: Asset] {
        guard !ids.isEmpty else { return [:] }

        var components = URLComponents(string: "https://api.coingecko.com/api/v3/simple/price")!
        components.queryItems = [
            URLQueryItem(name: "ids", value: ids.joined(separator: ",")),
            URLQueryItem(name: "vs_currencies", value: "usd"),
            URLQueryItem(name: "include_24hr_change", value: "true"),
            URLQueryItem(name: "include_24hr_vol", value: "true")
        ]

        guard let url = components.url else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let demoKey = SecretsConfig.coinGeckoAPIKey
        if !demoKey.isEmpty {
            request.setValue(demoKey, forHTTPHeaderField: "x-cg-demo-api-key")
        }

        let (data, response) = try await secureSession.rateLimitedData(
            for: request,
            endpoint: "coinGecko",
            config: .coinGecko
        )

        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            AppLogger.api.error("CoinGecko batch returned HTTP \(httpResponse.statusCode)")
            throw APIError.serverError(statusCode: httpResponse.statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.noData
        }

        var result: [String: Asset] = [:]
        for id in ids {
            guard let coinData = json[id] as? [String: Double] else { continue }
            let price = coinData["usd"] ?? 0
            let changePercent = coinData["usd_24h_change"] ?? 0
            let change = price * changePercent / 100
            let volume = coinData["usd_24h_vol"] ?? 0
            let symbol = Self.cryptoSymbolMap[id] ?? id.uppercased()
            result[id] = Asset(
                id: UUID(),
                symbol: symbol,
                name: id.split(separator: "-").map { $0.capitalized }.joined(separator: " "),
                price: price,
                change: change,
                changePercent: changePercent,
                volume: volume,
                kind: .crypto,
                exchange: "CoinGecko"
            )
        }
        AppLogger.api.debug("CoinGecko batch: \(result.count)/\(ids.count) prices fetched")
        return result
    }

    // MARK: - Alpha Vantage Quote (ASX + international stocks)

    /// Fetches a live quote from Alpha Vantage GLOBAL_QUOTE. Used for ASX and other non-US exchanges.
    func fetchFinnhubQuote(symbol: String, name: String = "") async throws -> Asset {
        let sanitized = InputSanitizer.sanitizeSymbol(symbol)

        var components = URLComponents(string: "https://www.alphavantage.co/query")!
        components.queryItems = [
            URLQueryItem(name: "function", value: "GLOBAL_QUOTE"),
            URLQueryItem(name: "symbol", value: sanitized),
            URLQueryItem(name: "apikey", value: alphaVantageKey)
        ]
        guard let url = components.url else { throw APIError.invalidURL }

        let (data, response) = try await secureSession.rateLimitedData(
            for: URLRequest(url: url),
            endpoint: "alphaVantage",
            config: .alphaVantage
        )
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            if let http = response as? HTTPURLResponse {
                AppLogger.api.error("Alpha Vantage quote HTTP \(http.statusCode) for \(sanitized)")
                throw APIError.serverError(statusCode: http.statusCode)
            }
            throw APIError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(AlphaVantageGlobalQuote.self, from: data)
        guard let q = decoded.globalQuote, !q.price.isEmpty else {
            AppLogger.api.warning("Alpha Vantage returned empty quote for \(sanitized)")
            throw APIError.noData
        }

        let price = Double(q.price) ?? 0
        let change = Double(q.change) ?? 0
        let changePercent = Double(q.changePercent.replacingOccurrences(of: "%", with: "")) ?? 0
        let volume = Double(q.volume) ?? 0

        guard price > 0 else { throw APIError.noData }

        let displaySymbol = sanitized.replacingOccurrences(of: ".AX", with: "")
        let exchange = sanitized.hasSuffix(".AX") ? "ASX" : "International"
        let displayName = name.isEmpty ? displaySymbol : name

        return Asset(
            id: UUID(),
            symbol: displaySymbol,
            name: displayName,
            price: price,
            change: change,
            changePercent: changePercent,
            volume: volume,
            kind: .stock,
            exchange: exchange
        )
    }

    // MARK: - Yahoo Finance Quote (ASX & International)

    /// Fetches a real-time quote from Yahoo Finance chart endpoint.
    /// Works for ASX (e.g. "BHP.AX") and any Yahoo-supported exchange.
    func fetchYahooQuote(symbol: String, name: String = "") async throws -> Asset {
        let sanitized = InputSanitizer.sanitizeSymbol(symbol)

        guard let url = URL(string: "\(Constants.URLs.yahooFinance)/v8/finance/chart/\(sanitized)?interval=1d&range=5d") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await secureSession.rateLimitedData(
            for: request,
            endpoint: "yahoo",
            config: .yahoo
        )
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            if let http = response as? HTTPURLResponse {
                AppLogger.api.error("Yahoo Finance HTTP \(http.statusCode) for \(sanitized)")
                throw APIError.serverError(statusCode: http.statusCode)
            }
            throw APIError.invalidResponse
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let chart = json["chart"] as? [String: Any],
              let results = chart["result"] as? [[String: Any]],
              let meta = results.first?["meta"] as? [String: Any] else {
            AppLogger.api.warning("Yahoo Finance returned invalid structure for \(sanitized)")
            throw APIError.noData
        }

        let price = meta["regularMarketPrice"] as? Double ?? 0
        let prevClose = meta["chartPreviousClose"] as? Double ?? price
        let volume = meta["regularMarketVolume"] as? Int ?? 0
        let fiftyTwoWeekHigh = meta["fiftyTwoWeekHigh"] as? Double
        let fiftyTwoWeekLow = meta["fiftyTwoWeekLow"] as? Double

        guard price > 0 else {
            AppLogger.api.warning("Yahoo Finance returned price=0 for \(sanitized)")
            throw APIError.noData
        }

        let change = price - prevClose
        let changePercent = prevClose > 0 ? (change / prevClose) * 100 : 0

        let displaySymbol = sanitized.replacingOccurrences(of: ".AX", with: "")
        let exchange = sanitized.hasSuffix(".AX") ? "ASX" : "International"
        let displayName: String
        if !name.isEmpty {
            displayName = name
        } else if let longName = meta["longName"] as? String, !longName.isEmpty {
            displayName = longName
        } else {
            displayName = displaySymbol
        }

        return Asset(
            id: UUID(),
            symbol: displaySymbol,
            name: displayName,
            price: price,
            change: change,
            changePercent: changePercent,
            volume: Double(volume),
            kind: .stock,
            week52High: fiftyTwoWeekHigh,
            week52Low: fiftyTwoWeekLow,
            exchange: exchange
        )
    }

    // MARK: - Yahoo Finance Chart (history + candles)

    struct YahooChartMeta {
        let regularMarketPrice: Double
        let chartPreviousClose: Double
        let regularMarketVolume: Int
        let fiftyTwoWeekHigh: Double?
        let fiftyTwoWeekLow: Double?
        let longName: String?
    }

    struct YahooChartResult {
        let meta: YahooChartMeta
        let candles: [Candle]
        let pricePoints: [PricePoint]
    }

    /// Fetches OHLCV chart data from Yahoo Finance for any exchange.
    /// Returns meta (price, 52-week, etc.), candles, and price points in one call.
    func fetchYahooChart(symbol: String, range: TimeRange) async throws -> YahooChartResult {
        let sanitized = InputSanitizer.sanitizeSymbol(symbol)

        let (interval, yahooRange) = yahooChartParams(for: range)

        guard let url = URL(string: "\(Constants.URLs.yahooFinance)/v8/finance/chart/\(sanitized)?interval=\(interval)&range=\(yahooRange)") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await secureSession.rateLimitedData(
            for: request,
            endpoint: "yahoo",
            config: .yahoo
        )
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            if let http = response as? HTTPURLResponse {
                AppLogger.api.error("Yahoo chart HTTP \(http.statusCode) for \(sanitized)")
                throw APIError.serverError(statusCode: http.statusCode)
            }
            throw APIError.invalidResponse
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let chart = json["chart"] as? [String: Any],
              let results = chart["result"] as? [[String: Any]],
              let result = results.first,
              let metaDict = result["meta"] as? [String: Any] else {
            throw APIError.noData
        }

        let meta = YahooChartMeta(
            regularMarketPrice: metaDict["regularMarketPrice"] as? Double ?? 0,
            chartPreviousClose: metaDict["chartPreviousClose"] as? Double ?? 0,
            regularMarketVolume: metaDict["regularMarketVolume"] as? Int ?? 0,
            fiftyTwoWeekHigh: metaDict["fiftyTwoWeekHigh"] as? Double,
            fiftyTwoWeekLow: metaDict["fiftyTwoWeekLow"] as? Double,
            longName: metaDict["longName"] as? String
        )

        // Parse timestamps + OHLCV arrays
        guard let timestamps = result["timestamp"] as? [Int],
              let indicators = result["indicators"] as? [String: Any],
              let quoteArr = (indicators["quote"] as? [[String: Any]])?.first else {
            // Valid meta but no time series data (e.g. market closed with range=1d)
            return YahooChartResult(meta: meta, candles: [], pricePoints: [])
        }

        let opens   = quoteArr["open"]   as? [Double?] ?? []
        let highs   = quoteArr["high"]   as? [Double?] ?? []
        let lows    = quoteArr["low"]    as? [Double?] ?? []
        let closes  = quoteArr["close"]  as? [Double?] ?? []
        let volumes = quoteArr["volume"] as? [Double?] ?? []

        var candles: [Candle] = []
        var pricePoints: [PricePoint] = []

        for i in timestamps.indices {
            let date = Date(timeIntervalSince1970: TimeInterval(timestamps[i]))
            let close = closes[safe: i] ?? nil

            if let o = opens[safe: i] ?? nil,
               let h = highs[safe: i] ?? nil,
               let l = lows[safe: i] ?? nil,
               let c = close {
                let vol = volumes[safe: i] ?? nil
                candles.append(Candle(date: date, open: o, high: h, low: l, close: c, volume: vol))
            }

            if let c = close {
                pricePoints.append(PricePoint(date: date, price: c))
            }
        }

        return YahooChartResult(
            meta: meta,
            candles: candles.sorted { $0.date < $1.date },
            pricePoints: pricePoints.sorted { $0.date < $1.date }
        )
    }

    /// Returns (interval, range) query params for Yahoo chart API.
    private func yahooChartParams(for range: TimeRange) -> (String, String) {
        switch range {
        case .oneDay:       return ("5m",  "1d")
        case .oneWeek:      return ("15m", "5d")
        case .oneMonth:     return ("1d",  "1mo")
        case .threeMonths:  return ("1d",  "3mo")
        case .sixMonths:    return ("1d",  "6mo")
        case .ytd:          return ("1d",  "ytd")
        case .oneYear:      return ("1d",  "1y")
        case .twoYears:     return ("1wk", "2y")
        case .fiveYears:    return ("1wk", "5y")
        case .tenYears:     return ("1mo", "10y")
        case .all:          return ("1mo", "max")
        }
    }

    /// Convenience: fetch Yahoo price history as [PricePoint] for line charts.
    func fetchYahooHistory(symbol: String, range: TimeRange) async throws -> [PricePoint] {
        let result = try await fetchYahooChart(symbol: symbol, range: range)
        return result.pricePoints
    }

    /// Convenience: fetch Yahoo OHLCV candles for candlestick charts.
    func fetchYahooCandles(symbol: String, range: TimeRange) async throws -> [Candle] {
        let result = try await fetchYahooChart(symbol: symbol, range: range)
        return result.candles
    }

    // MARK: - Alpha Vantage Daily History (DEPRECATED — use fetchYahooHistory)

    @available(*, deprecated, message: "Use fetchYahooHistory() instead — unlimited, no API key needed")
    func fetchFinnhubCandles(symbol: String, range: TimeRange) async throws -> [PricePoint] {
        let sanitized = InputSanitizer.sanitizeSymbol(symbol)

        let outputSize = (range == .oneDay || range == .oneWeek || range == .oneMonth) ? "compact" : "full"

        var components = URLComponents(string: "https://www.alphavantage.co/query")!
        components.queryItems = [
            URLQueryItem(name: "function", value: "TIME_SERIES_DAILY"),
            URLQueryItem(name: "symbol", value: sanitized),
            URLQueryItem(name: "outputsize", value: outputSize),
            URLQueryItem(name: "apikey", value: alphaVantageKey)
        ]
        guard let url = components.url else { throw APIError.invalidURL }

        let (data, response) = try await secureSession.rateLimitedData(
            for: URLRequest(url: url),
            endpoint: "alphaVantage",
            config: .alphaVantage
        )
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            if let http = response as? HTTPURLResponse {
                AppLogger.api.error("Alpha Vantage daily HTTP \(http.statusCode) for \(sanitized)")
                throw APIError.serverError(statusCode: http.statusCode)
            }
            throw APIError.invalidResponse
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timeSeries = json["Time Series (Daily)"] as? [String: [String: String]] else {
            AppLogger.api.warning("Alpha Vantage returned no time series for \(sanitized)")
            return []
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        let calendar = Calendar.current
        let now = Date()
        let cutoff: Date = {
            switch range {
            case .oneDay:      return calendar.date(byAdding: .day, value: -2, to: now)!
            case .oneWeek:     return calendar.date(byAdding: .weekOfYear, value: -1, to: now)!
            case .oneMonth:    return calendar.date(byAdding: .month, value: -1, to: now)!
            case .threeMonths: return calendar.date(byAdding: .month, value: -3, to: now)!
            case .sixMonths:   return calendar.date(byAdding: .month, value: -6, to: now)!
            case .ytd:
                return calendar.date(from: calendar.dateComponents([.year], from: now))!
            case .oneYear:     return calendar.date(byAdding: .year, value: -1, to: now)!
            case .twoYears:    return calendar.date(byAdding: .year, value: -2, to: now)!
            case .fiveYears:   return calendar.date(byAdding: .year, value: -5, to: now)!
            case .tenYears:    return calendar.date(byAdding: .year, value: -10, to: now)!
            case .all:         return calendar.date(byAdding: .year, value: -30, to: now)!
            }
        }()

        var points: [PricePoint] = []
        for (dateStr, values) in timeSeries {
            guard let date = dateFormatter.date(from: dateStr),
                  date >= cutoff,
                  let closeStr = values["4. close"],
                  let close = Double(closeStr) else { continue }
            points.append(PricePoint(date: date, price: close))
        }

        return points.sorted { $0.date < $1.date }
    }

    private static let cryptoSymbolMap: [String: String] = [
        "bitcoin": "BTC",
        "ethereum": "ETH",
        "solana": "SOL",
        "cardano": "ADA",
        "ripple": "XRP",
        "dogecoin": "DOGE",
        "polkadot": "DOT",
        "avalanche-2": "AVAX",
        "chainlink": "LINK",
        "litecoin": "LTC",
        "bitcoin-cash": "BCH",
        "stellar": "XLM",
        "uniswap": "UNI",
        "cosmos": "ATOM"
    ]
}

// MARK: - Supporting Types
enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case noData
    case rateLimited(retryAfter: TimeInterval)
    case serverError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid request URL"
        case .invalidResponse:
            return "Invalid server response"
        case .noData:
            return "No data received"
        case .rateLimited(let retryAfter):
            return "Rate limited. Retry after \(Int(retryAfter))s"
        case .serverError(let code):
            return "Server error (\(code))"
        }
    }
}

struct SearchResult {
    let symbol: String
    let name: String
    let id: String
    let exchange: String
    let region: String
    let currency: String

    init(symbol: String, name: String, id: String, exchange: String = "", region: String = "", currency: String = "USD") {
        self.symbol = symbol
        self.name = name
        self.id = id
        self.exchange = exchange
        self.region = region
        self.currency = currency
    }

    /// Whether this result represents an Australian Securities Exchange listing.
    var isASX: Bool {
        region.lowercased().contains("australia")
        || exchange.uppercased().contains("ASX")
        || exchange.uppercased().contains("AX")
        || symbol.hasSuffix(".AX")
    }
}

struct AlphaVantageSearchResponse: Codable {
    let bestMatches: [AlphaMatch]?   // nil when rate-limited (returns {"Note":"..."} instead)

    struct AlphaMatch: Codable {
        let symbol: String
        let name: String
        let type: String
        let region: String
        let currency: String

        enum CodingKeys: String, CodingKey {
            case symbol   = "1. symbol"
            case name     = "2. name"
            case type     = "3. type"
            case region   = "4. region"
            case currency = "8. currency"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.symbol   = try container.decode(String.self, forKey: .symbol)
            self.name     = try container.decode(String.self, forKey: .name)
            self.type     = (try? container.decode(String.self, forKey: .type)) ?? ""
            self.region   = (try? container.decode(String.self, forKey: .region)) ?? ""
            self.currency = (try? container.decode(String.self, forKey: .currency)) ?? "USD"
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

// MARK: - Finnhub Earnings Response

struct FinnhubEarningsItem: Decodable {
    let actual: Double?
    let estimate: Double?
    let period: String?        // "2024-03-31"
    let quarter: Int?          // 1–4
    let surprise: Double?
    let surprisePercent: Double?
    let symbol: String?
    let year: Int?
}

// MARK: - Finnhub Recommendation Response

struct FinnhubRecommendationItem: Decodable {
    let buy: Int
    let hold: Int
    let period: String        // "2025-03-01"
    let sell: Int
    let strongBuy: Int
    let strongSell: Int
    let symbol: String
}

// MARK: - Finnhub Upgrade/Downgrade Response

struct FinnhubUpgradeDowngrade: Decodable {
    let symbol: String?
    let company: String?       // analyst firm
    let fromGrade: String?
    let toGrade: String?
    let action: String?        // "upgrade", "downgrade", "init", "main", "reit"
    let gradeTime: Int?        // UNIX timestamp
}

// MARK: - Finnhub Fund Ownership (13F filings)

struct FinnhubFundOwnership: Decodable {
    let symbol: String?
    let ownership: [FinnhubFundHolder]?
}

struct FinnhubFundHolder: Decodable {
    let name: String?
    let share: Int?          // number of shares held
    let change: Int?         // quarter-over-quarter share change
    let filingDate: String?  // "2024-03-31"
    let portfolioPercent: Double?
}

// MARK: - Alpha Vantage Global Quote Response

struct AlphaVantageGlobalQuote: Decodable {
    let globalQuote: AVQuoteData?

    enum CodingKeys: String, CodingKey {
        case globalQuote = "Global Quote"
    }
}

struct AVQuoteData: Decodable {
    let symbol: String
    let price: String
    let change: String
    let changePercent: String
    let volume: String

    enum CodingKeys: String, CodingKey {
        case symbol        = "01. symbol"
        case price         = "05. price"
        case change        = "09. change"
        case changePercent = "10. change percent"
        case volume        = "06. volume"
    }
}

// MARK: - Finnhub News Response

struct FinnhubNewsItem: Codable {
    let id: Int
    let datetime: Int          // Unix timestamp
    let headline: String
    let summary: String
    let source: String
    let url: String
    let image: String
    let related: String        // Ticker symbol(s) e.g. "AAPL" or ""
    let category: String
}

struct AlpacaBarsResponse: Codable {
    let bars: [AlpacaBar]
    let nextPageToken: String?

    enum CodingKeys: String, CodingKey {
        case bars
        case nextPageToken = "next_page_token"
    }
}

// MARK: - Alpaca Snapshot Models

struct AlpacaSnapshot: Codable {
    let latestTrade: AlpacaLatestTrade?
    let latestQuote: AlpacaLatestQuote?
    let dailyBar: AlpacaSnapshotBar?
    let prevDailyBar: AlpacaSnapshotBar?
}

struct AlpacaLatestTrade: Codable {
    let price: Double

    enum CodingKeys: String, CodingKey {
        case price = "p"
    }
}

struct AlpacaLatestQuote: Codable {
    let askPrice: Double

    enum CodingKeys: String, CodingKey {
        case askPrice = "ap"
    }
}

struct AlpacaSnapshotBar: Codable {
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Double

    enum CodingKeys: String, CodingKey {
        case open = "o"
        case high = "h"
        case low = "l"
        case close = "c"
        case volume = "v"
    }
}

struct AlpacaBar: Codable {
    let timestamp: String
        let date: Date
        let open: Double
        let high: Double
        let low: Double
        let close: Double
        let volume: Double

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
            self.volume = try container.decode(Double.self, forKey: .volume)
        }
    }

// MARK: - Fiscal.ai Response Models

struct FiscalFundamentals {
    let marketCap: Double?
    let peRatio: Double?
    let eps: Double?
    let beta: Double?
    let dividend: Double?
    let week52High: Double?
    let week52Low: Double?
    let avgVolume: Double?
    let revenue: Double?
    let profitMargin: Double?
    let roe: Double?
    let debtToEquity: Double?
    let currentRatio: Double?
    let sector: String?
    let industry: String?
    let description: String?
    let employees: Int?
}

struct FiscalCompanyProfile: Decodable {
    let marketCap: Double?
    let beta: Double?
    let week52High: Double?
    let week52Low: Double?
    let avgVolume: Double?
    let sector: String?
    let industry: String?
    let description: String?
    let employees: Int?

    enum CodingKeys: String, CodingKey {
        case marketCap = "marketCapitalization"
        case beta
        case week52High = "fiftyTwoWeekHigh"
        case week52Low = "fiftyTwoWeekLow"
        case avgVolume = "averageVolume"
        case sector
        case industry
        case description = "companyDescription"
        case employees = "fullTimeEmployees"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        marketCap = try? container.decode(Double.self, forKey: .marketCap)
        beta = try? container.decode(Double.self, forKey: .beta)
        week52High = try? container.decode(Double.self, forKey: .week52High)
        week52Low = try? container.decode(Double.self, forKey: .week52Low)
        avgVolume = try? container.decode(Double.self, forKey: .avgVolume)
        sector = try? container.decode(String.self, forKey: .sector)
        industry = try? container.decode(String.self, forKey: .industry)
        description = try? container.decode(String.self, forKey: .description)
        employees = try? container.decode(Int.self, forKey: .employees)
    }
}

struct FiscalRatiosResponse: Decodable {
    let data: [FiscalRatioEntry]?
}

struct FiscalRatioEntry: Decodable {
    let peRatio: Double?
    let eps: Double?
    let dividendYield: Double?
    let revenue: Double?
    let profitMargin: Double?
    let roe: Double?
    let debtToEquity: Double?
    let currentRatio: Double?

    enum CodingKeys: String, CodingKey {
        case peRatio = "peRatio"
        case eps = "earningsPerShare"
        case dividendYield = "dividendYield"
        case revenue = "totalRevenue"
        case profitMargin = "netProfitMargin"
        case roe = "returnOnEquity"
        case debtToEquity = "debtToEquity"
        case currentRatio = "currentRatio"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        peRatio = try? container.decode(Double.self, forKey: .peRatio)
        eps = try? container.decode(Double.self, forKey: .eps)
        dividendYield = try? container.decode(Double.self, forKey: .dividendYield)
        revenue = try? container.decode(Double.self, forKey: .revenue)
        profitMargin = try? container.decode(Double.self, forKey: .profitMargin)
        roe = try? container.decode(Double.self, forKey: .roe)
        debtToEquity = try? container.decode(Double.self, forKey: .debtToEquity)
        currentRatio = try? container.decode(Double.self, forKey: .currentRatio)
    }
}

// MARK: - Safe Array Subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
