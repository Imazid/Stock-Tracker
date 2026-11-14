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
    private var alphaVantageKey: String { SecretsConfig.alphaVantageKey }
    private var finnhubAPIKey: String { SecretsConfig.finnhubAPIKey }
    // Cursor for Finnhub news pagination (minId = fetch articles older than this id)
    private var finnhubNewsMinId: Int? = nil

    private let alpacaDataBaseURL = URL(string: "https://data.alpaca.markets")!

    /// Endpoints that answered 401/403 "You don't have access to this resource" (plan-gated).
    /// Skipped for the rest of the session so each detail screen doesn't burn quota on them.
    private let planGatedLock = NSLock()
    private var planGatedEndpoints: Set<String> = []

    func isPlanGated(_ endpoint: String) -> Bool {
        planGatedLock.lock(); defer { planGatedLock.unlock() }
        return planGatedEndpoints.contains(endpoint)
    }

    func markPlanGated(_ endpoint: String, status: Int) {
        planGatedLock.lock()
        let inserted = planGatedEndpoints.insert(endpoint).inserted
        planGatedLock.unlock()
        if inserted {
            AppLogger.api.warning("\(endpoint) returned HTTP \(status) — not included in the current plan; skipping for this session")
        }
    }

    // MARK: - Secure URLSession with timeouts
    // 15s idle (45s total): a hung request becomes an honest "unavailable · Retry" quickly.
    private let secureSession: URLSession = SecureURLSessionFactory.makeSecureSession(timeoutInterval: 15)

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
        // GET, not HEAD: Alpaca's data API answers HEAD with 405 Method Not Allowed,
        // which made this checker report a working Alpaca key as down.
        request.httpMethod = "GET"

        do {
            let response: URLResponse
            switch endpoint {
            case "alpaca":
                (_, response) = try await MarketDataProxy.data(for: url, using: secureSession)
            case "finnhub":
                (_, response) = try await MarketDataProxy.data(for: url, using: secureSession, provider: "finnhub", direct: request, config: .newsAPI)
            default:
                (_, response) = try await secureSession.rateLimitedData(for: request, endpoint: endpoint, config: .default)
            }
            if let httpResponse = response as? HTTPURLResponse {
                return (200...299).contains(httpResponse.statusCode)
            }
            return false
        } catch {
            return false
        }
    }

    // MARK: - Historical Bars

    /// Builds an Alpaca `timeframe` value. Alpaca accepts `Min`/`T`, `Hour`/`H`, `Day`/`D`,
    /// `Week`/`W`, `Month`/`M` — but NOT `Minute`. Callers pass "Minute", which produced
    /// "15Minute"/"5Minute" and a 400 "invalid timeframe" on every intraday request
    /// (1D charts, 1D/1W candles and live candle updates silently fell back to Yahoo).
    static func alpacaTimeframe(multiplier: Int, unit: String) -> String {
        let normalized: String
        switch unit.lowercased() {
        case "minute", "minutes", "min", "t": normalized = "Min"
        case "hour", "hours", "h":            normalized = "Hour"
        case "day", "days", "d":              normalized = "Day"
        case "week", "weeks", "w":            normalized = "Week"
        case "month", "months", "m":          normalized = "Month"
        default:                              normalized = unit
        }
        return "\(multiplier)\(normalized)"
    }

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
            URLQueryItem(name: "timeframe", value: Self.alpacaTimeframe(multiplier: multiplier, unit: timeframe)),
            URLQueryItem(name: "start", value: ISO8601DateFormatter().string(from: start)),
            URLQueryItem(name: "end", value: ISO8601DateFormatter().string(from: end)),
            URLQueryItem(name: "limit", value: "1000"),
            URLQueryItem(name: "feed", value: "iex"),
            // Split- and dividend-adjusted, so long ranges don't show splits as crashes
            // (AAPL's 2020 4:1 split drew as a −75% cliff).
            URLQueryItem(name: "adjustment", value: "all")
        ]

        guard let url = components.url else {
            throw APIError.invalidURL
        }

        let (data, response) = try await MarketDataProxy.data(for: url, using: secureSession)

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
            URLQueryItem(name: "timeframe", value: Self.alpacaTimeframe(multiplier: multiplier, unit: timeframe)),
            URLQueryItem(name: "start", value: formatter.string(from: start)),
            URLQueryItem(name: "end", value: formatter.string(from: end)),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "feed", value: "iex"),
            // Split- and dividend-adjusted, so long ranges don't show splits as crashes
            // (AAPL's 2020 4:1 split drew as a −75% cliff).
            URLQueryItem(name: "adjustment", value: "all")
        ]

        guard let url = components.url else {
            throw APIError.invalidURL
        }

        let (data, response) = try await MarketDataProxy.data(for: url, using: secureSession)

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

    /// Fetch price history for a crypto asset.
    /// - Up to 1 year: CoinGecko market chart.
    /// - Longer ranges: CoinGecko's public and free Demo plans reject anything older than
    ///   365 days (HTTP 401, error_code 10012), which used to drop 2Y/5Y/10Y/All charts onto
    ///   synthetic data. Those ranges now come from Alpaca crypto bars (same Alpaca key as stocks,
    ///   history from Dec 2020), falling back to CoinGecko's last 365 days if Alpaca lacks the coin.
    func fetchCryptoHistory(id: String, range: TimeRange) async throws -> [PricePoint] {
        switch range {
        case .twoYears, .fiveYears, .tenYears, .all:
            if let symbol = Self.cryptoSymbolMap[id] {
                do {
                    let points = try await fetchAlpacaCryptoHistory(symbol: symbol, range: range)
                    // Only use Alpaca when it actually has more than a year of history for this coin.
                    if let first = points.first?.date,
                       first < Date().addingTimeInterval(-400 * 86_400) {
                        return points
                    }
                    AppLogger.api.info("Alpaca crypto history too short for \(symbol); using CoinGecko 365d")
                } catch {
                    AppLogger.api.warning("Alpaca crypto history failed for \(symbol): \(error.localizedDescription)")
                }
            }
            return try await fetchCoinGeckoHistory(id: id, days: "365")
        default:
            break
        }
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
            // >365 days is handled above (CoinGecko public/Demo caps history at 365 days).
            case .oneYear, .twoYears, .fiveYears, .tenYears, .all:
                return "365"
            }
        }()
        do {
            return try await fetchCoinGeckoHistory(id: id, days: days)
        } catch {
            // CoinGecko's keyless tier rate-limits hard (429); Alpaca serves the same coins.
            guard let symbol = Self.cryptoSymbolMap[id] else { throw error }
            AppLogger.api.info("CoinGecko history failed for \(id) (\(error.localizedDescription)); using Alpaca")
            return try await fetchAlpacaCryptoHistory(symbol: symbol, range: range)
        }
    }

    private func fetchCoinGeckoHistory(id: String, days: String) async throws -> [PricePoint] {
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
            let body = String(data: data, encoding: .utf8) ?? ""
            AppLogger.api.error("CoinGecko history HTTP \(http.statusCode) for \(id) days=\(days): \(body.prefix(200))")
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

    /// Crypto history from Alpaca (`/v1beta3/crypto/us/bars`, e.g. "BTC/USD") for any
    /// range — timeframes chosen to stay under the 1,000-bar page.
    private func fetchAlpacaCryptoHistory(symbol: String, range: TimeRange) async throws -> [PricePoint] {
        let calendar = Calendar.current
        let end = Date()
        let (start, unit, multiplier): (Date, String, Int) = {
            switch range {
            case .oneDay:      return (end.addingTimeInterval(-24 * 3600), "Minute", 15)
            case .oneWeek:     return (calendar.date(byAdding: .day, value: -7, to: end)!, "Hour", 1)
            case .oneMonth:    return (calendar.date(byAdding: .month, value: -1, to: end)!, "Hour", 4)
            case .threeMonths: return (calendar.date(byAdding: .month, value: -3, to: end)!, "Day", 1)
            case .sixMonths:   return (calendar.date(byAdding: .month, value: -6, to: end)!, "Day", 1)
            case .ytd:         return (calendar.date(from: calendar.dateComponents([.year], from: end))!, "Day", 1)
            case .oneYear:     return (calendar.date(byAdding: .year, value: -1, to: end)!, "Day", 1)
            case .twoYears:    return (calendar.date(byAdding: .year, value: -2, to: end)!, "Day", 1)
            case .fiveYears:   return (calendar.date(byAdding: .year, value: -5, to: end)!, "Week", 1)
            case .tenYears, .all: return (calendar.date(byAdding: .year, value: -20, to: end)!, "Week", 1)
            }
        }()

        var components = URLComponents(url: alpacaDataBaseURL.appendingPathComponent("/v1beta3/crypto/us/bars"),
                                       resolvingAgainstBaseURL: true)!
        components.queryItems = [
            URLQueryItem(name: "symbols", value: "\(symbol)/USD"),
            URLQueryItem(name: "timeframe", value: Self.alpacaTimeframe(multiplier: multiplier, unit: unit)),
            URLQueryItem(name: "start", value: ISO8601DateFormatter().string(from: start)),
            URLQueryItem(name: "limit", value: "1000")
        ]
        guard let url = components.url else { throw APIError.invalidURL }

        let (data, response) = try await MarketDataProxy.data(for: url, using: secureSession)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            AppLogger.api.error("Alpaca crypto bars HTTP \(code) for \(symbol)")
            throw APIError.serverError(statusCode: code)
        }
        let decoded = try JSONDecoder().decode(AlpacaCryptoBarsResponse.self, from: data)
        return (decoded.bars["\(symbol)/USD"] ?? [])
            .map { PricePoint(date: $0.date, price: $0.close) }
            .sorted { $0.date < $1.date }
    }

    // MARK: - News (Finnhub — paginated via minId)

    /// Fetch a page of financial news from Finnhub.
    /// Page 1 fetches the latest articles. Subsequent pages use `minId` to load older articles.
    func fetchNews(page: Int = 1, pageSize: Int? = nil) async throws -> [NewsArticle] {
        let pageSize = pageSize ?? Constants.Pagination.newsPageSize
        guard MarketDataProxy.available(debugKey: finnhubAPIKey) else {
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
        let (data, response) = try await MarketDataProxy.data(for: url, using: secureSession, provider: "finnhub",
                                                direct: request, config: .newsAPI)
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

    // MARK: - Company News (Finnhub — per symbol)

    /// Recent news for one US-listed symbol (`/company-news`, free tier; ASX symbols → 403).
    /// General news (`/news`) never fills `related`, so this is what makes the
    /// Watchlist/Portfolio news filters return anything.
    func fetchCompanyNews(symbol: String, days: Int = 7, limit: Int = 10, requiresCoverage: Bool = false) async throws -> [NewsArticle] {
        let sanitized = InputSanitizer.sanitizeSymbol(symbol)
        guard MarketDataProxy.available(debugKey: finnhubAPIKey), !isPlanGated("Finnhub company-news") else {
            if requiresCoverage { throw APIError.noData }
            return []
        }

        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        dateFmt.locale = Locale(identifier: "en_US_POSIX")
        let now = Date()
        let from = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now

        var components = URLComponents(string: "\(Constants.URLs.finnhub)/company-news")!
        components.queryItems = [
            URLQueryItem(name: "symbol", value: sanitized),
            URLQueryItem(name: "from", value: dateFmt.string(from: from)),
            URLQueryItem(name: "to", value: dateFmt.string(from: now)),
            URLQueryItem(name: "token", value: finnhubAPIKey)
        ]
        guard let url = components.url else { throw APIError.invalidURL }

        let (data, response) = try await MarketDataProxy.data(for: url, using: secureSession, provider: "finnhub",
                                                direct: URLRequest(url: url), config: .newsAPI)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            AppLogger.news.error("Finnhub company-news HTTP \(code) for \(sanitized)")
            throw APIError.serverError(statusCode: code)
        }

        let items = try JSONDecoder().decode([FinnhubNewsItem].self, from: data)
        return items.prefix(limit).map { item in
            NewsArticle(
                title: item.headline,
                source: item.source,
                url: item.url,
                imageURL: item.image.isEmpty ? nil : item.image,
                publishedAt: Date(timeIntervalSince1970: TimeInterval(item.datetime)),
                summary: item.summary,
                relatedSymbols: [sanitized]
            )
        }
    }

    // MARK: - Fiscal.ai Fundamentals

    /// Fetches company fundamentals (P/E, EPS, market cap, beta, etc.) from Fiscal.ai.
    /// Uses the company profile + ratios endpoints. Free tier: 250 calls/day.
    func fetchFiscalFundamentals(symbol: String, exchange: String = "") async throws -> FiscalFundamentals {
        let sanitized = InputSanitizer.sanitizeSymbol(symbol)
        let apiKey = SecretsConfig.fiscalAIAPIKey
        guard MarketDataProxy.available(debugKey: apiKey) else {
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

        let profile: FiscalCompanyProfile?
        do {
            profile = try JSONDecoder().decode(FiscalCompanyProfile.self, from: try await profileData)
        } catch {
            AppLogger.api.error("Fiscal.ai profile decode failed for \(companyKey): \(error)")
            profile = nil
        }
        let ratiosResponse: FiscalRatiosResponse?
        do {
            ratiosResponse = try JSONDecoder().decode(FiscalRatiosResponse.self, from: try await ratiosData)
        } catch {
            AppLogger.api.error("Fiscal.ai ratios decode failed for \(companyKey): \(error)")
            ratiosResponse = nil
        }

        // Ratios come back as one entry per fiscal period; use the most recent report.
        let latest = ratiosResponse?.data?.max { ($0.reportDate ?? "") < ($1.reportDate ?? "") }
        let mv = latest?.metricValues ?? [:]
        let revenue: Double? = {
            guard let rps = mv["ratio_revenue_per_share"], let shares = mv["market_data_total_shares_outstanding"] else { return nil }
            return rps * shares
        }()

        let result = FiscalFundamentals(
            marketCap: mv["calculated_market_cap"],
            peRatio: mv["ratio_price_to_earnings"],
            eps: mv["ratio_diluted_eps"] ?? mv["ratio_basic_eps"],
            beta: nil,          // not provided by Fiscal.ai profile/ratios
            dividend: mv["calculated_dividend_yield"],
            week52High: nil,
            week52Low: nil,
            avgVolume: nil,
            revenue: revenue,
            profitMargin: mv["ratio_net_profit_margin"],
            roe: mv["ratio_return_on_equity"],
            debtToEquity: mv["ratio_debt_to_equity"],
            currentRatio: mv["ratio_current_ratio"],
            sector: profile?.sector,
            industry: profile?.industry,
            description: profile?.description,
            employees: nil
        )

        // If nothing numeric decoded, throw so the caller falls back to FMP instead of
        // rendering an all-blank "Fiscal.ai" card.
        guard result.marketCap != nil || result.peRatio != nil || result.eps != nil else {
            AppLogger.api.warning("Fiscal.ai returned no usable metrics for \(companyKey)")
            throw APIError.noData
        }
        return result
    }

    private func fetchFiscalEndpoint(path: String, companyKey: String, apiKey: String) async throws -> Data {
        var components = URLComponents(string: "\(Constants.URLs.fiscalAI)\(path)")!
        components.queryItems = [
            URLQueryItem(name: "companyKey", value: companyKey)
        ]

        guard let url = components.url else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // Header auth keeps the key out of URLs (and any URL logging); verified working.
        request.setValue(apiKey, forHTTPHeaderField: "X-API-KEY")

        let (data, response) = try await MarketDataProxy.data(for: url, using: secureSession, provider: "fiscal",
                                                direct: request, config: .fiscalAI)

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
        guard MarketDataProxy.available(debugKey: finnhubAPIKey) else { return [] }

        var components = URLComponents(string: "\(Constants.URLs.finnhub)/stock/earnings")!
        components.queryItems = [
            URLQueryItem(name: "symbol", value: sanitized),
            URLQueryItem(name: "token", value: finnhubAPIKey)
        ]
        guard let url = components.url else { throw APIError.invalidURL }

        let (data, response) = try await MarketDataProxy.data(for: url, using: secureSession, provider: "finnhub",
                                                direct: URLRequest(url: url), config: .newsAPI)
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
        guard MarketDataProxy.available(debugKey: finnhubAPIKey) else { return [] }

        var components = URLComponents(string: "\(Constants.URLs.finnhub)/stock/recommendation")!
        components.queryItems = [
            URLQueryItem(name: "symbol", value: sanitized),
            URLQueryItem(name: "token", value: finnhubAPIKey)
        ]
        guard let url = components.url else { throw APIError.invalidURL }

        let (data, response) = try await MarketDataProxy.data(for: url, using: secureSession, provider: "finnhub",
                                                direct: URLRequest(url: url), config: .newsAPI)
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
        // /stock/upgrade-downgrade is a Finnhub premium endpoint (free keys get 403).
        guard MarketDataProxy.available(debugKey: finnhubAPIKey), !isPlanGated("Finnhub upgrade-downgrade") else { return [] }

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

        let (data, response) = try await MarketDataProxy.data(for: url, using: secureSession, provider: "finnhub",
                                                direct: URLRequest(url: url), config: .newsAPI)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 401 || http.statusCode == 403 {
                    markPlanGated("Finnhub upgrade-downgrade", status: http.statusCode)
                }
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
        // /stock/fund-ownership is a Finnhub premium endpoint (free keys get 403).
        guard MarketDataProxy.available(debugKey: finnhubAPIKey), !isPlanGated("Finnhub fund-ownership") else { return nil }

        var components = URLComponents(string: "\(Constants.URLs.finnhub)/stock/fund-ownership")!
        components.queryItems = [
            URLQueryItem(name: "symbol", value: sanitized),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "token", value: finnhubAPIKey)
        ]
        guard let url = components.url else { throw APIError.invalidURL }

        let (data, response) = try await MarketDataProxy.data(for: url, using: secureSession, provider: "finnhub",
                                                direct: URLRequest(url: url), config: .newsAPI)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 401 || http.statusCode == 403 {
                    markPlanGated("Finnhub fund-ownership", status: http.statusCode)
                }
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
            // Yahoo Finance returns ASX + international results; Alpha Vantage misses ASX entirely.
            // Yahoo now and then answers a real ticker with nothing (MSFT showed "No matches"
            // once in a long test run, then passed 3/3), so ask its second host before saying
            // "No matches". A different host is a different URL, so the coalescer's 10 s reuse
            // can't hand back the same empty answer.
            let first = try await searchYahooFinance(query: sanitizedQuery, host: Constants.URLs.yahooFinance)
            guard first.isEmpty else { return first }
            return (try? await searchYahooFinance(query: sanitizedQuery, host: "https://query2.finance.yahoo.com")) ?? first
        case .crypto:
            return try await searchCoinGecko(query: sanitizedQuery)
        }
    }

    private func searchYahooFinance(query: String, host: String) async throws -> [SearchResult] {
        var components = URLComponents(string: "\(host)/v1/finance/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "quotesCount", value: "15"),
            URLQueryItem(name: "newsCount", value: "0")
        ]
        guard let url = components.url else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await secureSession.rateLimitedData(
            for: request,
            // Its own bucket: an interactive search must not queue behind background
            // chart/quote fetches (searches timed out as "No matches" at launch).
            endpoint: "yahooSearch",
            config: .yahoo
        )
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            AppLogger.api.error("Yahoo search HTTP \(http.statusCode) for '\(query)'")
            throw APIError.serverError(statusCode: http.statusCode)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        // A real no-match is `"quotes": []`. A body without the key (throttled or error
        // page) is a failure, not "No matches" (NVDA showed "No matches" while Yahoo throttled).
        guard let quotes = json["quotes"] as? [[String: Any]] else {
            AppLogger.api.warning("Yahoo search returned no quotes key for '\(query)'")
            throw APIError.noData
        }

        return quotes.compactMap { q -> SearchResult? in
            // Stocks and ETFs (VAS, VOO…); funds, futures, options and indices aren't quotable here.
            guard let symbol = q["symbol"] as? String,
                  let name = q["longname"] as? String ?? q["shortname"] as? String,
                  let quoteType = q["quoteType"] as? String,
                  quoteType == "EQUITY" || quoteType == "ETF" else { return nil }

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
                currency: q["currency"] as? String ?? "USD",
                isETF: quoteType == "ETF"
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

        let (data, _) = try await MarketDataProxy.data(for: url, using: secureSession, provider: "alpha",
                                                direct: request, config: .alphaVantage)

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

        let (data, response) = try await secureSession.rateLimitedData(
            for: request,
            endpoint: "coinGecko",
            config: .coinGecko
        )
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            AppLogger.api.error("CoinGecko search HTTP \(http.statusCode) — add a free CoinGeckoAPIKey (Demo) to raise the public rate limit")
            throw APIError.serverError(statusCode: http.statusCode)
        }
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
            let quote = try await fetchStockQuote(symbol: sanitized)
            // Alpaca snapshots carry no company name; keep the one the caller knows.
            guard !name.isEmpty, name != quote.symbol else { return quote }
            return Asset(id: quote.id, symbol: quote.symbol, name: name, price: quote.price, change: quote.change,
                         changePercent: quote.changePercent, volume: quote.volume, kind: quote.kind,
                         week52High: quote.week52High, week52Low: quote.week52Low, exchange: quote.exchange,
                         isETF: quote.isETF, priceMove: quote.priceMove)
        case .crypto:
            return try await fetchCryptoPrice(id: identifier)
        }
    }

    // MARK: - Quotes

    /// Fetches latest trade price + daily change from Alpaca snapshot endpoint.
    func fetchStockQuote(symbol: String) async throws -> Asset {
        do {
            return try await fetchAlpacaStockQuote(symbol: symbol)
        } catch {
            try Task.checkCancellation()
            return try await fetchYahooQuote(symbol: InputSanitizer.sanitizeSymbol(symbol))
        }
    }

    private func fetchAlpacaStockQuote(symbol: String) async throws -> Asset {
        let sanitizedSymbol = InputSanitizer.sanitizeSymbol(symbol)

        // feed=iex uses the IEX free feed; without this, free-plan accounts receive 403
        guard let url = URL(string: "https://data.alpaca.markets/v2/stocks/\(sanitizedSymbol)/snapshot?feed=iex") else {
            throw APIError.invalidURL
        }

        let (data, response) = try await MarketDataProxy.data(for: url, using: secureSession)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            if let httpResponse = response as? HTTPURLResponse {
                AppLogger.api.error("Alpaca snapshot returned HTTP \(httpResponse.statusCode) for \(sanitizedSymbol)")
                throw APIError.serverError(statusCode: httpResponse.statusCode)
            }
            throw APIError.invalidResponse
        }

        let snapshot = try JSONDecoder().decode(AlpacaSnapshot.self, from: data)
        guard let asset = Self.quoteAsset(from: snapshot, symbol: sanitizedSymbol) else {
            AppLogger.api.warning("Alpaca snapshot returned price=0 for \(sanitizedSymbol)")
            throw APIError.noData
        }
        return asset
    }

    /// Many US quotes in one request (`/v2/stocks/snapshots`); symbols Alpaca doesn't
    /// know are simply absent from the result. One call per refresh instead of one each.
    func fetchStockQuotes(symbols: [String]) async throws -> [String: Asset] {
        let sanitized = Array(Set(symbols.map { InputSanitizer.sanitizeSymbol($0) })).sorted()
        guard !sanitized.isEmpty else { return [:] }
        var components = URLComponents(string: "https://data.alpaca.markets/v2/stocks/snapshots")!
        components.queryItems = [URLQueryItem(name: "symbols", value: sanitized.joined(separator: ",")),
                                 URLQueryItem(name: "feed", value: "iex")]
        guard let url = components.url else { throw APIError.invalidURL }
        let (data, response) = try await MarketDataProxy.data(for: url, using: secureSession)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            if let http = response as? HTTPURLResponse { throw APIError.serverError(statusCode: http.statusCode) }
            throw APIError.invalidResponse
        }
        let snapshots = try JSONDecoder().decode([String: AlpacaSnapshot].self, from: data)
        var result: [String: Asset] = [:]
        for (symbol, snapshot) in snapshots {
            if let asset = Self.quoteAsset(from: snapshot, symbol: symbol) { result[symbol] = asset }
        }
        return result
    }

    /// Price + change from one Alpaca snapshot; nil when it has no price.
    private static func quoteAsset(from snapshot: AlpacaSnapshot, symbol: String) -> Asset? {
        let price = snapshot.latestTrade?.price ?? snapshot.latestQuote?.askPrice ?? 0
        guard price > 0 else { return nil }
        // In a new day's pre-market the latest trade is newer than `dailyBar`,
        // which is still the last completed session — so *its* close is the
        // previous close (prevDailyBar is two sessions back: NVDA showed −2.02%
        // pre-market against a real −0.4%). Otherwise (open, after hours,
        // weekend) the change is the latest session's, vs prevDailyBar.
        let previousClose: Double? = {
            if let daily = snapshot.dailyBar, let barDay = daily.date,
               let tradeDay = snapshot.latestTrade?.date,
               tradeDay > barDay, !TradingHours.us.sameSessionDay(barDay, tradeDay) {
                return daily.close
            }
            return snapshot.prevDailyBar?.close
        }()
        let prevClose = previousClose ?? price
        let change = price - prevClose
        let changePercent = prevClose > 0 ? (change / prevClose) * 100 : 0
        let volume = snapshot.dailyBar?.volume ?? 0

        return Asset(
            id: UUID(),
            symbol: symbol,
            name: symbol,
            price: price,
            change: change,
            changePercent: changePercent,
            volume: volume,
            kind: .stock,
            // Alpaca snapshots don't say which US exchange; don't guess "NYSE" for Nasdaq stocks.
            exchange: "US",
            priceMove: AssetPriceMove(source: .alpacaEquity, observedAt: snapshot.latestTrade?.date,
                                      currency: "USD", last: price, reference: previousClose)
        )
    }

    /// Fetches current price + 24h change from CoinGecko simple price endpoint.
    /// One coin's price: CoinGecko, falling back to Alpaca when CoinGecko is rate-limited.
    func fetchCryptoPrice(id: String) async throws -> Asset {
        do {
            return try await fetchCoinGeckoPrice(id: id)
        } catch {
            if let fallback = try? await fetchAlpacaCryptoSnapshots(ids: [id]), let asset = fallback[id] {
                return asset
            }
            throw error
        }
    }

    private func fetchCoinGeckoPrice(id: String) async throws -> Asset {
        var components = URLComponents(string: "https://api.coingecko.com/api/v3/simple/price")!
        components.queryItems = [
            URLQueryItem(name: "ids", value: id),
            URLQueryItem(name: "vs_currencies", value: "usd"),
            URLQueryItem(name: "include_24hr_change", value: "true"),
            URLQueryItem(name: "include_24hr_vol", value: "true"),
            URLQueryItem(name: "include_last_updated_at", value: "true")
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
            AppLogger.api.error("CoinGecko price HTTP \(http.statusCode) for \(id)")
            throw APIError.serverError(statusCode: http.statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let coinData = json[id] as? [String: Any] else {
            AppLogger.api.warning("CoinGecko returned no price for \(id)")
            throw APIError.noData
        }

        guard let asset = Self.coinGeckoAsset(id: id, data: coinData) else { throw APIError.noData }
        return asset
    }

    /// Fetch prices for multiple crypto IDs in a single CoinGecko request.
    /// Returns a dict of [coinGeckoId: Asset].
    /// CoinGecko batch prices, falling back to Alpaca crypto snapshots for any coin
    /// CoinGecko can't price (its keyless tier answers 429 under light load).
    func fetchCryptoPricesBatch(ids: [String]) async throws -> [String: Asset] {
        guard !ids.isEmpty else { return [:] }
        var result: [String: Asset] = [:]
        var failure: Error?
        do {
            result = try await fetchCoinGeckoPricesBatch(ids: ids)
        } catch {
            failure = error
        }
        let missing = ids.filter { result[$0] == nil && Self.cryptoSymbolMap[$0] != nil }
        if !missing.isEmpty, let fallback = try? await fetchAlpacaCryptoSnapshots(ids: missing) {
            result.merge(fallback) { cg, _ in cg }
        }
        if result.isEmpty, let failure { throw failure }
        return result
    }

    /// Latest price and change vs the previous UTC daily close from Alpaca, keyed by CoinGecko id.
    private func fetchAlpacaCryptoSnapshots(ids: [String]) async throws -> [String: Asset] {
        let pairs = ids.compactMap { id in Self.cryptoSymbolMap[id].map { (id, $0) } }
        guard !pairs.isEmpty else { return [:] }
        var components = URLComponents(url: alpacaDataBaseURL.appendingPathComponent("/v1beta3/crypto/us/snapshots"),
                                       resolvingAgainstBaseURL: true)!
        components.queryItems = [URLQueryItem(name: "symbols", value: pairs.map { "\($0.1)/USD" }.joined(separator: ","))]
        guard let url = components.url else { throw APIError.invalidURL }
        let (data, response) = try await MarketDataProxy.data(for: url, using: secureSession)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.serverError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let snapshots = json["snapshots"] as? [String: [String: Any]] else { throw APIError.noData }
        var out: [String: Asset] = [:]
        for (id, symbol) in pairs {
            guard let snap = snapshots["\(symbol)/USD"], let trade = snap["latestTrade"] as? [String: Any],
                  let price = trade["p"] as? Double, price > 0 else { continue }
            let previousClose = (snap["prevDailyBar"] as? [String: Any])?["c"] as? Double
            let prevClose = previousClose ?? price
            let volume = (snap["dailyBar"] as? [String: Any])?["v"] as? Double ?? 0
            let change = price - prevClose
            out[id] = Asset(symbol: symbol, name: id.split(separator: "-").map { $0.capitalized }.joined(separator: " "),
                            price: price, change: change,
                            changePercent: prevClose > 0 ? change / prevClose * 100 : 0,
                            volume: volume * price, kind: .crypto, exchange: "Alpaca",
                            priceMove: AssetPriceMove(source: .alpacaCrypto,
                                                      observedAt: (trade["t"] as? String).flatMap(AlpacaLatestTrade.parseDate),
                                                      currency: "USD", last: price, reference: previousClose))
        }
        AppLogger.api.info("Alpaca crypto snapshot fallback: \(out.count)/\(pairs.count) prices")
        return out
    }

    private func fetchCoinGeckoPricesBatch(ids: [String]) async throws -> [String: Asset] {

        var components = URLComponents(string: "https://api.coingecko.com/api/v3/simple/price")!
        components.queryItems = [
            URLQueryItem(name: "ids", value: ids.joined(separator: ",")),
            URLQueryItem(name: "vs_currencies", value: "usd"),
            URLQueryItem(name: "include_24hr_change", value: "true"),
            URLQueryItem(name: "include_24hr_vol", value: "true"),
            URLQueryItem(name: "include_last_updated_at", value: "true")
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
            guard let coinData = json[id] as? [String: Any] else { continue }
            result[id] = Self.coinGeckoAsset(id: id, data: coinData)
        }
        AppLogger.api.debug("CoinGecko batch: \(result.count)/\(ids.count) prices fetched")
        return result
    }

    private static func coinGeckoAsset(id: String, data: [String: Any]) -> Asset? {
        guard let price = data["usd"] as? Double, price.isFinite, price > 0 else { return nil }
        let percent = (data["usd_24h_change"] as? Double).flatMap { $0.isFinite && $0 > -100 ? $0 : nil }
        let reference = percent.map { price / (1 + $0 / 100) }
        let time = (data["last_updated_at"] as? Double).flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        return Asset(symbol: cryptoSymbolMap[id] ?? id.uppercased(),
                     name: id.split(separator: "-").map { $0.capitalized }.joined(separator: " "),
                     price: price, change: reference.map { price - $0 } ?? 0, changePercent: percent ?? 0,
                     volume: data["usd_24h_vol"] as? Double ?? 0, kind: .crypto, exchange: "CoinGecko",
                     priceMove: AssetPriceMove(source: .coinGecko, observedAt: time, currency: "USD", last: price, reference: reference))
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

        let (data, response) = try await MarketDataProxy.data(for: url, using: secureSession, provider: "alpha",
                                                direct: URLRequest(url: url), config: .alphaVantage)
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

    // MARK: - Yahoo listing facts (ASX key stats + dividends)

    /// One year of daily bars plus dividend events for a Yahoo-listed symbol (e.g. "BHP.AX").
    /// FMP and Finnhub's free plans don't cover the ASX, and Yahoo's quoteSummary needs a
    /// session crumb, so this is what can be stated honestly for an ASX listing.
    /// Every money value is USD (converted like `fetchYahooQuote`).
    func fetchYahooListingFacts(symbol: String) async throws -> YahooListingFacts {
        let sanitized = InputSanitizer.sanitizeSymbol(symbol)
        guard let url = URL(string: "\(Constants.URLs.yahooFinance)/v8/finance/chart/\(sanitized)?interval=1d&range=1y&events=div") else {
            throw APIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await secureSession.rateLimitedData(for: request, endpoint: "yahoo", config: .yahoo)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            if let http = response as? HTTPURLResponse { throw APIError.serverError(statusCode: http.statusCode) }
            throw APIError.invalidResponse
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let result = ((json["chart"] as? [String: Any])?["result"] as? [[String: Any]])?.first,
              let meta = result["meta"] as? [String: Any] else { throw APIError.noData }

        let currency = meta["currency"] as? String
        let fx = Self.yahooToUSD(currency, symbol: sanitized)
        func number(_ any: Any?) -> Double? {
            if let d = any as? Double { return d }
            if let i = any as? Int { return Double(i) }
            return nil
        }

        let quote = ((result["indicators"] as? [String: Any])?["quote"] as? [[String: Any]])?.first
        let volumes = (quote?["volume"] as? [Any] ?? []).compactMap(number).filter { $0 > 0 }
        let recent = volumes.suffix(63) // ~3 months of sessions
        let avgVolume = recent.isEmpty ? nil : recent.reduce(0, +) / Double(recent.count)

        var dividends: [YahooListingFacts.Dividend] = []
        if let divs = (result["events"] as? [String: Any])?["dividends"] as? [String: Any] {
            for case let event as [String: Any] in divs.values {
                guard let amount = number(event["amount"]), amount > 0,
                      let date = number(event["date"]) else { continue }
                dividends.append(.init(date: Date(timeIntervalSince1970: date), amountUSD: amount * fx))
            }
        }
        dividends.sort { $0.date < $1.date }

        let dayHigh = number(meta["regularMarketDayHigh"]).map { $0 * fx }
        let dayLow = number(meta["regularMarketDayLow"]).map { $0 * fx }
        return YahooListingFacts(
            currency: currency,
            dayHigh: dayHigh.flatMap { $0 > 0 ? $0 : nil },
            dayLow: dayLow.flatMap { $0 > 0 ? $0 : nil },
            volume: number(meta["regularMarketVolume"]).flatMap { $0 > 0 ? $0 : nil },
            avgVolume3M: avgVolume,
            dividends: dividends,
            firstTradeDate: number(meta["firstTradeDate"]).map { Date(timeIntervalSince1970: $0) },
            longName: meta["longName"] as? String)
    }

    // MARK: - Finnhub fundamentals (US key stats when FMP is unavailable)

    /// Finnhub `/stock/metric` + `/stock/profile2`. Free, 60 calls/min, US listings only
    /// (ASX returns 403). Fills the key-stats gaps when FMP's 250/day free quota is spent.
    func fetchFinnhubFundamentals(symbol: String) async throws -> FinnhubFundamentals {
        let sanitized = InputSanitizer.sanitizeSymbol(symbol)
        guard MarketDataProxy.available(debugKey: finnhubAPIKey) else { throw APIError.noData }
        func get(_ path: String, _ extra: [URLQueryItem]) async throws -> [String: Any] {
            var components = URLComponents(string: "\(Constants.URLs.finnhub)\(path)")!
            components.queryItems = [URLQueryItem(name: "symbol", value: sanitized)] + extra
                + [URLQueryItem(name: "token", value: finnhubAPIKey)]
            guard let url = components.url else { throw APIError.invalidURL }
            let (data, response) = try await MarketDataProxy.data(for: url, using: secureSession, provider: "finnhub",
                                                direct: URLRequest(url: url), config: .newsAPI)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                if let http = response as? HTTPURLResponse { throw APIError.serverError(statusCode: http.statusCode) }
                throw APIError.invalidResponse
            }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        }
        // One after the other: this whole call already runs alongside the FMP requests.
        let metric = (try? await get("/stock/metric", [URLQueryItem(name: "metric", value: "all")]))?["metric"] as? [String: Any] ?? [:]
        let profile = (try? await get("/stock/profile2", [])) ?? [:]
        guard !metric.isEmpty || !profile.isEmpty else { throw APIError.noData }
        return FinnhubFundamentals(metric: metric, profile: profile)
    }

    // MARK: - Yahoo Finance Quote (ASX & International)

    /// Fetches a real-time quote from Yahoo Finance chart endpoint.
    /// Works for ASX (e.g. "BHP.AX") and any Yahoo-supported exchange.
    func fetchYahooQuote(symbol: String, name: String = "") async throws -> Asset {
        let sanitized = InputSanitizer.sanitizeSymbol(symbol)

        // range=1d: with range=1d `chartPreviousClose` is the previous session's close.
        // (range=5d made it the close five sessions back, so "daily change" was a 5-day change.)
        guard let url = URL(string: "\(Constants.URLs.yahooFinance)/v8/finance/chart/\(sanitized)?interval=1d&range=1d") else {
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

        // Yahoo quotes in the listing's currency (AUD for .AX). Store USD — see FXRates.
        let currency = meta["currency"] as? String
        let fx = Self.yahooToUSD(currency, symbol: sanitized)
        let last = meta["regularMarketPrice"] as? Double ?? 0
        let reference = meta["chartPreviousClose"] as? Double
        let price = last * fx
        let prevClose = reference.map { $0 * fx } ?? price
        let volume = meta["regularMarketVolume"] as? Int ?? 0
        let fiftyTwoWeekHigh = (meta["fiftyTwoWeekHigh"] as? Double).map { $0 * fx }
        let fiftyTwoWeekLow = (meta["fiftyTwoWeekLow"] as? Double).map { $0 * fx }

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

        let exactSymbol = (meta["symbol"] as? String)?.uppercased() == sanitized.uppercased()
        let priceMove = currency.flatMap { reported -> AssetPriceMove? in
            guard exactSymbol else { return nil }
            let (code, unit) = Self.yahooCurrency(reported)
            let observedAt = (meta["regularMarketTime"] as? Double).flatMap {
                $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil
            }
            return AssetPriceMove(source: .yahooEquity, observedAt: observedAt,
                                  currency: code, last: last * unit, reference: reference.map { $0 * unit })
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
            exchange: exchange,
            isETF: exactSymbol ? (meta["instrumentType"] as? String).map { $0 == "ETF" } : nil,
            priceMove: priceMove
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

        let fx = Self.yahooToUSD(metaDict["currency"] as? String, symbol: sanitized)
        let meta = YahooChartMeta(
            regularMarketPrice: (metaDict["regularMarketPrice"] as? Double ?? 0) * fx,
            chartPreviousClose: (metaDict["chartPreviousClose"] as? Double ?? 0) * fx,
            regularMarketVolume: metaDict["regularMarketVolume"] as? Int ?? 0,
            fiftyTwoWeekHigh: (metaDict["fiftyTwoWeekHigh"] as? Double).map { $0 * fx },
            fiftyTwoWeekLow: (metaDict["fiftyTwoWeekLow"] as? Double).map { $0 * fx },
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
                candles.append(Candle(date: date, open: o * fx, high: h * fx, low: l * fx, close: c * fx, volume: vol))
            }

            if let c = close {
                pricePoints.append(PricePoint(date: date, price: c * fx))
            }
        }

        return YahooChartResult(
            meta: meta,
            candles: candles.sorted { $0.date < $1.date },
            pricePoints: pricePoints.sorted { $0.date < $1.date }
        )
    }

    /// Multiplier from a Yahoo `currency` field to USD. Handles minor units
    /// ("GBp" pence, "ZAc" cents, "ILA" agorot). Unknown currencies are left
    /// as-is and logged rather than silently mis-scaled.
    static func yahooToUSD(_ currency: String?, symbol: String) -> Double {
        // Index levels (^GSPC, ^AXJO) are points, not money — never convert them.
        if symbol.hasPrefix("^") { return 1.0 }
        guard let currency, !currency.isEmpty else { return 1.0 }
        let (code, minorUnit) = yahooCurrency(currency)
        guard let factor = FXRates.shared.toUSDFactor(from: code) else {
            AppLogger.api.warning("No FX rate for \(currency) (\(symbol)); showing unconverted")
            return minorUnit
        }
        return factor * minorUnit
    }

    private static func yahooCurrency(_ currency: String) -> (String, Double) {
        switch currency {
        case "GBp", "GBX": ("GBP", 0.01)
        case "ZAc", "ZAC": ("ZAR", 0.01)
        case "ILA": ("ILS", 0.01)
        default: (currency.uppercased(), 1)
        }
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

        let (data, response) = try await MarketDataProxy.data(for: url, using: secureSession, provider: "alpha",
                                                direct: URLRequest(url: url), config: .alphaVantage)
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
        "cosmos": "ATOM",
        "binancecoin": "BNB",
        "polygon-ecosystem-token": "POL"
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
    let isETF: Bool?

    init(symbol: String, name: String, id: String, exchange: String = "", region: String = "", currency: String = "USD",
         isETF: Bool? = nil) {
        self.symbol = symbol
        self.name = name
        self.id = id
        self.exchange = exchange
        self.region = region
        self.currency = currency
        self.isETF = isETF
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Alpaca returns `"bars": null` (not []) when a window has no trades — e.g. a
        // live-candle request outside market hours, or a non-US symbol. Treat as empty.
        bars = try container.decodeIfPresent([AlpacaBar].self, forKey: .bars) ?? []
        nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
    }
}

/// Response of Alpaca's multi-symbol crypto bars endpoint (`/v1beta3/crypto/us/bars`).
struct AlpacaCryptoBarsResponse: Decodable {
    let bars: [String: [AlpacaBar]]

    enum CodingKeys: String, CodingKey { case bars }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bars = try container.decodeIfPresent([String: [AlpacaBar]].self, forKey: .bars) ?? [:]
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
    let timestamp: String?

    var date: Date? {
        timestamp.flatMap(Self.parseDate)
    }

    static func parseDate(_ timestamp: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
    }

    enum CodingKeys: String, CodingKey {
        case price = "p"
        case timestamp = "t"
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
    /// Session date (00:00 New York time), e.g. "2026-10-16T04:00:00Z".
    let timestamp: String?

    var date: Date? { timestamp.flatMap { ISO8601DateFormatter().date(from: $0) } }

    enum CodingKeys: String, CodingKey {
        case timestamp = "t"
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

/// `GET /v2/company/profile` — descriptive fields only (no market cap / beta / 52-week data).
struct FiscalCompanyProfile: Decodable {
    let name: String?
    let sector: String?
    let industry: String?
    let description: String?
}

/// `GET /v1/company/ratios` — `{ "metrics": [...definitions...], "data": [ { reportDate, metricValues: { ratioId: value } } ] }`
struct FiscalRatiosResponse: Decodable {
    let data: [FiscalRatioEntry]?
}

struct FiscalRatioEntry: Decodable {
    let periodId: String?
    let reportDate: String?
    let metricValues: [String: Double]

    enum CodingKeys: String, CodingKey { case periodId, reportDate, metricValues }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        periodId = try? container.decode(String.self, forKey: .periodId)
        reportDate = try? container.decode(String.self, forKey: .reportDate)
        // Values can be null for metrics a company doesn't report; keep only numbers.
        let raw = (try? container.decode([String: Double?].self, forKey: .metricValues)) ?? [:]
        metricValues = raw.compactMapValues { $0 }
    }
}

// MARK: - Safe Array Subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}


// MARK: - Listing facts models

struct YahooListingFacts: Sendable {
    struct Dividend: Sendable { let date: Date; let amountUSD: Double }
    let currency: String?
    let dayHigh: Double?
    let dayLow: Double?
    let volume: Double?
    let avgVolume3M: Double?
    /// Oldest first; the last year only (the request is range=1y).
    let dividends: [Dividend]
    let firstTradeDate: Date?
    let longName: String?

    /// Dividends paid in the last 365 days, per share in USD; nil if none were paid.
    var trailing12MonthDividendUSD: Double? {
        let cutoff = Date().addingTimeInterval(-365 * 86_400)
        let total = dividends.filter { $0.date >= cutoff }.reduce(0) { $0 + $1.amountUSD }
        return total > 0 ? total : nil
    }
}

/// Raw Finnhub metric/profile dictionaries, read with unit conversion
/// (Finnhub reports market cap and volumes in millions, margins and yields in percent).
struct FinnhubFundamentals: @unchecked Sendable {
    let metric: [String: Any]
    let profile: [String: Any]

    private func number(_ key: String, in dict: [String: Any]) -> Double? {
        if let d = dict[key] as? Double, d.isFinite { return d }
        if let i = dict[key] as? Int { return Double(i) }
        return nil
    }
    private func m(_ key: String) -> Double? { number(key, in: metric) }

    var marketCapUSD: Double? { (number("marketCapitalization", in: profile) ?? m("marketCapitalization")).map { $0 * 1_000_000 } }
    var sharesOutstanding: Double? { number("shareOutstanding", in: profile).map { $0 * 1_000_000 } }
    var peTTM: Double? { m("peTTM") ?? m("peBasicExclExtraTTM") }
    var forwardPE: Double? { m("forwardPE") }
    var peg: Double? { m("pegTTM") }
    var priceToBook: Double? { m("pbQuarterly") ?? m("pbAnnual") }
    var priceToSales: Double? { m("psTTM") }
    var beta: Double? { m("beta") }
    var dividendYield: Double? { (m("currentDividendYieldTTM") ?? m("dividendYieldIndicatedAnnual")).map { $0 / 100 } }
    var week52High: Double? { m("52WeekHigh") }
    var week52Low: Double? { m("52WeekLow") }
    var avgVolume3M: Double? { m("3MonthAverageTradingVolume").map { $0 * 1_000_000 } }
    var grossMargin: Double? { m("grossMarginTTM").map { $0 / 100 } }
    var operatingMargin: Double? { m("operatingMarginTTM").map { $0 / 100 } }
    var netMargin: Double? { m("netProfitMarginTTM").map { $0 / 100 } }
    var revenueGrowthYoY: Double? { m("revenueGrowthTTMYoy").map { $0 / 100 } }
    var epsGrowthYoY: Double? { m("epsGrowthTTMYoy").map { $0 / 100 } }
    var debtToEquity: Double? { m("totalDebt/totalEquityQuarterly") ?? m("totalDebt/totalEquityAnnual") }
    var industry: String? { (profile["finnhubIndustry"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    var website: String? { (profile["weburl"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    var ipoDate: String? { (profile["ipo"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    /// "NASDAQ NMS - GLOBAL MARKET" → "NASDAQ", "NEW YORK STOCK EXCHANGE, INC." → "NYSE".
    var exchangeShortName: String? {
        guard let raw = (profile["exchange"] as? String)?.uppercased(), !raw.isEmpty else { return nil }
        if raw.hasPrefix("NASDAQ") { return "NASDAQ" }
        if raw.hasPrefix("NEW YORK STOCK EXCHANGE") { return "NYSE" }
        if raw.contains("ARCA") { return "NYSE Arca" }
        if raw.contains("AMERICAN") || raw.contains("NYSE MKT") { return "NYSE American" }
        if raw.contains("CBOE") || raw.contains("BATS") { return "Cboe" }
        return nil
    }
}
