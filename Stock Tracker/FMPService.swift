//
//  FMPService.swift
//  Stock Tracker
//
//  Fetches company profile, quote, ratios, statements and analyst data from
//  Financial Modeling Prep's `/stable` API.
//  API docs: https://site.financialmodelingprep.com/developer/docs/stable
//
//  NOTE (verified 2026-10-16): the legacy `/api/v3/...` endpoints return
//  HTTP 403 "Legacy Endpoint ... only available for legacy users" for this key,
//  so every FMP call used to fail silently. Everything below uses `/stable`.
//  Free ("Basic") plan limits observed live:
//    • 250 calls/day, US-listed symbols only (BHP.AX → 402)
//    • `limit` must be ≤ 5 on statements/earnings (limit=8 → 402)
//    • analyst-estimates: annual only; institutional ownership: paid only
//  The stable response field names differ from v3 (marketCap vs mktCap, …);
//  the models decode either spelling so existing call sites keep working.
//

import Foundation
import OSLog

// MARK: - Flexible decoding helpers

/// A CodingKey that can name any JSON key, so models can accept both the
/// legacy v3 and the `/stable` spelling of a field.
private struct AnyKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private extension KeyedDecodingContainer where Key == AnyKey {
    /// First non-null numeric value among `keys` (accepts numbers or numeric strings).
    func double(_ keys: String...) -> Double? {
        for key in keys {
            let k = AnyKey(key)
            if let v = try? decodeIfPresent(Double.self, forKey: k) { return v }
            if let s = try? decodeIfPresent(String.self, forKey: k), let v = Double(s) { return v }
        }
        return nil
    }

    func int(_ keys: String...) -> Int? {
        for key in keys {
            let k = AnyKey(key)
            if let v = try? decodeIfPresent(Int.self, forKey: k) { return v }
            if let v = try? decodeIfPresent(Double.self, forKey: k), v.isFinite { return Int(v) }
            if let s = try? decodeIfPresent(String.self, forKey: k), let v = Int(s) { return v }
        }
        return nil
    }

    func string(_ keys: String...) -> String? {
        for key in keys {
            let k = AnyKey(key)
            if let v = try? decodeIfPresent(String.self, forKey: k) { return v }
            if let v = try? decodeIfPresent(Int.self, forKey: k) { return String(v) }
        }
        return nil
    }

    func bool(_ keys: String...) -> Bool? {
        for key in keys {
            if let v = try? decodeIfPresent(Bool.self, forKey: AnyKey(key)) { return v }
        }
        return nil
    }
}

// MARK: - Response Models

struct FMPRatios: Decodable {
    let date: String?
    // Valuation — long-form and short-form names both included so either works
    let priceEarningsRatio: Double?         // v3 priceEarningsRatio / stable priceToEarningsRatio(TTM)
    let peRatio: Double?                    // other FMP responses
    let priceEarningsToGrowthRatio: Double? // v3 / stable priceToEarningsGrowthRatio(TTM)
    let pegRatio: Double?                   // other FMP responses
    let priceToBookRatio: Double?
    let pbRatio: Double?                    // alternate
    let priceToSalesRatio: Double?
    let priceSalesRatio: Double?            // alternate
    let enterpriseValueMultiple: Double?
    // Financial Health
    let grossProfitMargin: Double?
    let operatingProfitMargin: Double?
    let netProfitMargin: Double?
    let debtEquityRatio: Double?            // v3 debtEquityRatio / stable debtToEquityRatio(TTM)
    let freeCashFlowPerShare: Double?
    let operatingCashFlowPerShare: Double?
    // Dividends
    let dividendYield: Double?
    let payoutRatio: Double?                // v3 payoutRatio / stable dividendPayoutRatio(TTM)

    // Convenience — picks whichever field name was populated
    var resolvedPE:  Double? { priceEarningsRatio ?? peRatio }
    var resolvedPEG: Double? { priceEarningsToGrowthRatio ?? pegRatio }
    var resolvedPB:  Double? { priceToBookRatio ?? pbRatio }
    var resolvedPS:  Double? { priceToSalesRatio ?? priceSalesRatio }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        date                       = c.string("date")
        priceEarningsRatio         = c.double("priceEarningsRatio", "priceToEarningsRatio", "priceToEarningsRatioTTM")
        peRatio                    = c.double("peRatio", "peRatioTTM")
        priceEarningsToGrowthRatio = c.double("priceEarningsToGrowthRatio", "priceToEarningsGrowthRatio", "priceToEarningsGrowthRatioTTM")
        pegRatio                   = c.double("pegRatio", "pegRatioTTM")
        priceToBookRatio           = c.double("priceToBookRatio", "priceToBookRatioTTM")
        pbRatio                    = c.double("pbRatio")
        priceToSalesRatio          = c.double("priceToSalesRatio", "priceToSalesRatioTTM")
        priceSalesRatio            = c.double("priceSalesRatio")
        enterpriseValueMultiple    = c.double("enterpriseValueMultiple", "enterpriseValueMultipleTTM")
        grossProfitMargin          = c.double("grossProfitMargin", "grossProfitMarginTTM")
        operatingProfitMargin      = c.double("operatingProfitMargin", "operatingProfitMarginTTM")
        netProfitMargin            = c.double("netProfitMargin", "netProfitMarginTTM")
        debtEquityRatio            = c.double("debtEquityRatio", "debtToEquityRatio", "debtToEquityRatioTTM")
        freeCashFlowPerShare       = c.double("freeCashFlowPerShare", "freeCashFlowPerShareTTM")
        operatingCashFlowPerShare  = c.double("operatingCashFlowPerShare", "operatingCashFlowPerShareTTM")
        dividendYield              = c.double("dividendYield", "dividendYieldTTM")
        payoutRatio                = c.double("payoutRatio", "dividendPayoutRatio", "dividendPayoutRatioTTM")
    }
}

struct FMPAnalystEstimates: Decodable {
    let date: String?
    let estimatedEpsAvg: Double?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        date            = c.string("date")
        estimatedEpsAvg = c.double("estimatedEpsAvg", "epsAvg")
    }
}

/// Analyst consensus rating counts from FMP /stable/grades-consensus
struct FMPAnalystRating: Decodable {
    let symbol: String?
    let strongBuy: Int?
    let buy: Int?
    let hold: Int?
    let sell: Int?
    let strongSell: Int?
    let consensus: String?
}

struct FMPIncomeStatement: Decodable {
    let date: String?
    let revenue: Double?
    let grossProfit: Double?
    let grossProfitRatio: Double?
    let operatingIncome: Double?
    let operatingIncomeRatio: Double?
    let netIncome: Double?
    let netIncomeRatio: Double?
    let eps: Double?
    let epsDiluted: Double?
    let ebitda: Double?
    let weightedAverageShsOut: Double?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        let rev = c.double("revenue")
        let gross = c.double("grossProfit")
        let opIncome = c.double("operatingIncome")
        let net = c.double("netIncome")
        date                  = c.string("date")
        revenue               = rev
        grossProfit           = gross
        operatingIncome       = opIncome
        netIncome             = net
        eps                   = c.double("eps")
        epsDiluted            = c.double("epsDiluted", "epsdiluted")
        ebitda                = c.double("ebitda")
        weightedAverageShsOut = c.double("weightedAverageShsOut")
        // `/stable` dropped the *Ratio fields — derive them from the raw numbers.
        func ratio(_ part: Double?) -> Double? {
            guard let part, let rev, rev != 0 else { return nil }
            return part / rev
        }
        grossProfitRatio      = c.double("grossProfitRatio") ?? ratio(gross)
        operatingIncomeRatio  = c.double("operatingIncomeRatio") ?? ratio(opIncome)
        netIncomeRatio        = c.double("netIncomeRatio") ?? ratio(net)
    }
}

/// Historical earnings from FMP /stable/earnings (v3: /historical/earning_calendar)
struct FMPEarningsHistorical: Decodable {
    let date: String?
    let symbol: String?
    let eps: Double?
    let epsEstimated: Double?
    let revenue: Double?
    let revenueEstimated: Double?
    let fiscalDateEnding: String?
    let updatedFromDate: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        date             = c.string("date")
        symbol           = c.string("symbol")
        eps              = c.double("eps", "epsActual")
        epsEstimated     = c.double("epsEstimated")
        revenue          = c.double("revenue", "revenueActual")
        revenueEstimated = c.double("revenueEstimated")
        fiscalDateEnding = c.string("fiscalDateEnding")
        updatedFromDate  = c.string("updatedFromDate", "lastUpdated")
    }
}

/// Price target consensus from FMP /stable/price-target-consensus
struct FMPPriceTargetConsensus: Decodable {
    let symbol: String?
    let targetHigh: Double?
    let targetLow: Double?
    let targetConsensus: Double?
    let targetMedian: Double?
}

/// Individual analyst grade changes from FMP /stable/grades (v3: /upgrades-downgrades)
struct FMPUpgradeDowngrade: Decodable {
    let symbol: String?
    let publishedDate: String?
    let newsURL: String?
    let newsTitle: String?
    let newsBaseURL: String?
    let newsPublisher: String?
    let newGrade: String?
    let previousGrade: String?
    let gradingCompany: String?
    let action: String?
    let priceWhenPosted: Double?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        symbol          = c.string("symbol")
        publishedDate   = c.string("publishedDate", "date")
        newsURL         = c.string("newsURL")
        newsTitle       = c.string("newsTitle")
        newsBaseURL     = c.string("newsBaseURL")
        newsPublisher   = c.string("newsPublisher")
        newGrade        = c.string("newGrade")
        previousGrade   = c.string("previousGrade")
        gradingCompany  = c.string("gradingCompany")
        action          = c.string("action")
        priceWhenPosted = c.double("priceWhenPosted")
    }
}

struct FMPInstitutionalHolder: Decodable {
    let holder: String?
    let shares: Double?
    let dateReported: String?
    let change: Double?
    let weightPercent: Double?
}

struct FMPBalanceSheet: Decodable {
    let date: String?
    let totalAssets: Double?
    let cashAndShortTermInvestments: Double?
    let totalDebt: Double?
    let totalLiabilities: Double?
    let totalStockholdersEquity: Double?
    let totalCurrentAssets: Double?
    let totalCurrentLiabilities: Double?
    let goodwill: Double?
    let netDebt: Double?
    let totalInvestments: Double?
}

struct FMPCashFlow: Decodable {
    let date: String?
    let operatingCashFlow: Double?
    let capitalExpenditure: Double?
    let freeCashFlow: Double?
    let netCashUsedForInvestingActivites: Double?
    let netCashUsedProvidedByFinancingActivities: Double?
    let netChangeInCash: Double?
    let dividendsPaid: Double?
    let stockBasedCompensation: Double?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        date                   = c.string("date")
        operatingCashFlow      = c.double("operatingCashFlow", "netCashProvidedByOperatingActivities")
        capitalExpenditure     = c.double("capitalExpenditure")
        freeCashFlow           = c.double("freeCashFlow")
        netCashUsedForInvestingActivites = c.double("netCashUsedForInvestingActivites", "netCashProvidedByInvestingActivities")
        netCashUsedProvidedByFinancingActivities = c.double("netCashUsedProvidedByFinancingActivities", "netCashProvidedByFinancingActivities")
        netChangeInCash        = c.double("netChangeInCash")
        dividendsPaid          = c.double("dividendsPaid", "netDividendsPaid", "commonDividendsPaid")
        stockBasedCompensation = c.double("stockBasedCompensation")
    }
}

struct FMPProfile: Decodable {
    let symbol: String
    let companyName: String?
    let price: Double?
    let beta: Double?
    let volAvg: Double?
    let mktCap: Double?
    let lastDiv: Double?
    let changes: Double?
    let exchange: String?
    let exchangeShortName: String?
    let industry: String?
    let website: String?
    let description: String?
    let ceo: String?
    let sector: String?
    let country: String?
    let fullTimeEmployees: String?
    let image: String?
    let ipoDate: String?
    let isEtf: Bool?
    let isActivelyTrading: Bool?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let symbol = c.string("symbol") else {
            throw DecodingError.keyNotFound(AnyKey("symbol"), .init(codingPath: decoder.codingPath, debugDescription: "FMP profile without symbol"))
        }
        self.symbol       = symbol
        companyName       = c.string("companyName")
        price             = c.double("price")
        beta              = c.double("beta")
        volAvg            = c.double("volAvg", "averageVolume")
        mktCap            = c.double("mktCap", "marketCap")
        lastDiv           = c.double("lastDiv", "lastDividend")
        changes           = c.double("changes", "change")
        // v3: exchange = full name, exchangeShortName = "NASDAQ".
        // stable: exchangeFullName = full name, exchange = "NASDAQ".
        exchangeShortName = c.string("exchangeShortName", "exchange")
        exchange          = c.string("exchangeFullName", "exchange")
        industry          = c.string("industry")
        website           = c.string("website")
        description       = c.string("description")
        ceo               = c.string("ceo")
        sector            = c.string("sector")
        country           = c.string("country")
        fullTimeEmployees = c.string("fullTimeEmployees")
        image             = c.string("image")
        ipoDate           = c.string("ipoDate")
        isEtf             = c.bool("isEtf")
        isActivelyTrading = c.bool("isActivelyTrading")
    }
}

struct FMPQuote: Decodable {
    let symbol: String
    let name: String?
    let price: Double
    let changesPercentage: Double?
    let change: Double?
    let open: Double?
    let dayLow: Double?
    let dayHigh: Double?
    let yearHigh: Double?
    let yearLow: Double?
    let marketCap: Double?
    let priceAvg50: Double?
    let priceAvg200: Double?
    let exchange: String?
    let volume: Int?
    let avgVolume: Int?       // not in /stable/quote (profile.averageVolume has it)
    let previousClose: Double?
    let eps: Double?          // not in /stable/quote
    let pe: Double?           // not in /stable/quote — ratios-ttm supplies P/E
    let sharesOutstanding: Double?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard let symbol = c.string("symbol"), let price = c.double("price") else {
            throw DecodingError.keyNotFound(AnyKey("price"), .init(codingPath: decoder.codingPath, debugDescription: "FMP quote without symbol/price"))
        }
        self.symbol       = symbol
        self.price        = price
        name              = c.string("name")
        changesPercentage = c.double("changesPercentage", "changePercentage")
        change            = c.double("change")
        open              = c.double("open")
        dayLow            = c.double("dayLow")
        dayHigh           = c.double("dayHigh")
        yearHigh          = c.double("yearHigh")
        yearLow           = c.double("yearLow")
        marketCap         = c.double("marketCap")
        priceAvg50        = c.double("priceAvg50")
        priceAvg200       = c.double("priceAvg200")
        exchange          = c.string("exchange")
        volume            = c.int("volume")
        avgVolume         = c.int("avgVolume", "averageVolume")
        previousClose     = c.double("previousClose")
        eps               = c.double("eps")
        pe                = c.double("pe")
        // /stable/quote has no sharesOutstanding; derive it from market cap ÷ price.
        if let so = c.double("sharesOutstanding") {
            sharesOutstanding = so
        } else if let mc = marketCap, price > 0 {
            sharesOutstanding = mc / price
        } else {
            sharesOutstanding = nil
        }
    }
}

// MARK: - Service

final class FMPService {
    static let shared = FMPService()
    private init() {}

    private var apiKey: String { SecretsConfig.fmpAPIKey }
    private let baseURL = "https://financialmodelingprep.com/stable"
    private let session = SecureURLSessionFactory.makeSecureSession(timeoutInterval: 30)

    /// Free plan allows `limit` ≤ 5 on statements/earnings (larger values → HTTP 402).
    private static let maxFreeLimit = 5

    // Small in-memory cache: the free plan is 250 calls/day and one stock detail screen
    // fans out to ~10 FMP calls, so repeat visits must not re-spend quota.
    private var cache: [String: (stored: Date, data: Data)] = [:]
    /// Endpoint paths that returned "Restricted Endpoint" (plan-gated) — skipped this session.
    private var restrictedPaths: Set<String> = []
    private var loggedInstitutionalNotice = false

    nonisolated private static let quoteTTL: TimeInterval = 60
    nonisolated private static let fundamentalsTTL: TimeInterval = 6 * 3600

    /// Performs `GET /stable/{path}?{query}&apikey=…` and returns the body on HTTP 200.
    /// Every failure is logged with its status and FMP's message (the key is never logged).
    private func get(_ path: String, _ query: [String: String], ttl: TimeInterval = fundamentalsTTL) async -> Data? {
        guard MarketDataProxy.available(debugKey: apiKey) else { return nil }
        guard !restrictedPaths.contains(path) else { return nil }

        let sortedQuery = query.sorted { $0.key < $1.key }
        let cacheKey = path + "?" + sortedQuery.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        if let hit = cache[cacheKey], Date().timeIntervalSince(hit.stored) < ttl {
            return hit.data
        }

        var components = URLComponents(string: "\(baseURL)/\(path)")!
        components.queryItems = sortedQuery.map { URLQueryItem(name: $0.key, value: $0.value) }
            + [URLQueryItem(name: "apikey", value: apiKey)]
        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await MarketDataProxy.data(for: url, using: session, provider: "fmp",
                                                 direct: URLRequest(url: url), config: .fmp)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                let rawMessage = String(data: data, encoding: .utf8) ?? ""
                let message = (apiKey.isEmpty ? rawMessage : rawMessage.replacingOccurrences(of: apiKey, with: "<key>")).prefix(200)
                if message.contains("Restricted Endpoint") {
                    restrictedPaths.insert(path)
                    AppLogger.api.warning("FMP \(path) is not in the current plan (HTTP \(status)); skipping for this session")
                } else {
                    AppLogger.api.error("FMP \(cacheKey) HTTP \(status): \(String(message))")
                }
                return nil
            }
            cache[cacheKey] = (Date(), data)
            return data
        } catch {
            AppLogger.api.error("FMP \(cacheKey) request failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Decode an FMP response that is a JSON array `[T]` (or a single object).
    private func decodeArray<T: Decodable>(_ type: T.Type, from data: Data, label: String) -> [T] {
        do {
            return try JSONDecoder().decode([T].self, from: data)
        } catch let arrayError {
            if let single = try? JSONDecoder().decode(T.self, from: data) { return [single] }
            AppLogger.api.error("FMP \(label) decode failed: \(arrayError)")
            return []
        }
    }

    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    // MARK: Profile / quote / ratios

    func fetchProfile(symbol: String) async -> FMPProfile? {
        guard let data = await get("profile", ["symbol": symbol]) else { return nil }
        return decodeArray(FMPProfile.self, from: data, label: "profile \(symbol)").first
    }

    func fetchQuote(symbol: String) async -> FMPQuote? {
        guard let data = await get("quote", ["symbol": symbol], ttl: Self.quoteTTL) else { return nil }
        return decodeArray(FMPQuote.self, from: data, label: "quote \(symbol)").first
    }

    /// Trailing-twelve-month ratios (current valuation); falls back to the latest fiscal year.
    func fetchRatios(symbol: String) async -> FMPRatios? {
        if let data = await get("ratios-ttm", ["symbol": symbol]),
           let ttm = decodeArray(FMPRatios.self, from: data, label: "ratios-ttm \(symbol)").first {
            return ttm
        }
        guard let data = await get("ratios", ["symbol": symbol, "limit": "1"]) else { return nil }
        return decodeArray(FMPRatios.self, from: data, label: "ratios \(symbol)").first
    }

    // MARK: Analyst data

    /// Annual EPS estimate for the next fiscal year that hasn't ended yet
    /// (the endpoint lists the furthest-out year first, so `limit=1` returned FY+4).
    func fetchAnalystEstimates(symbol: String) async -> FMPAnalystEstimates? {
        guard let data = await get("analyst-estimates",
                                   ["symbol": symbol, "period": "annual", "page": "0", "limit": "10"]) else { return nil }
        let all = decodeArray(FMPAnalystEstimates.self, from: data, label: "analyst-estimates \(symbol)")
        let today = Self.isoDay.string(from: Date())
        let upcoming = all
            .filter { ($0.date ?? "") >= today && $0.estimatedEpsAvg != nil }
            .min { ($0.date ?? "") < ($1.date ?? "") }
        return upcoming ?? all.first
    }

    func fetchAnalystRating(symbol: String) async -> FMPAnalystRating? {
        guard let data = await get("grades-consensus", ["symbol": symbol]) else { return nil }
        return decodeArray(FMPAnalystRating.self, from: data, label: "grades-consensus \(symbol)").first
    }

    /// Reported earnings (newest first). The free plan caps `limit` at 5 and the first row
    /// is usually the *upcoming* report (actuals null), so only reported rows are returned.
    func fetchEarningsHistorical(symbol: String, limit: Int = 8) async -> [FMPEarningsHistorical] {
        guard let data = await get("earnings", ["symbol": symbol, "limit": "\(Self.maxFreeLimit)"]) else { return [] }
        let rows = decodeArray(FMPEarningsHistorical.self, from: data, label: "earnings \(symbol)")
        return Array(rows.filter { $0.eps != nil }.prefix(limit))
    }

    func fetchPriceTargetConsensus(symbol: String) async -> FMPPriceTargetConsensus? {
        guard let data = await get("price-target-consensus", ["symbol": symbol]) else { return nil }
        return decodeArray(FMPPriceTargetConsensus.self, from: data, label: "price-target-consensus \(symbol)").first
    }

    /// Latest analyst grade actions. `/stable/grades` ignores `limit` (returns full history),
    /// so the list is truncated client-side.
    func fetchUpgradesDowngrades(symbol: String, limit: Int = 10) async -> [FMPUpgradeDowngrade] {
        guard let data = await get("grades", ["symbol": symbol]) else { return [] }
        return Array(decodeArray(FMPUpgradeDowngrade.self, from: data, label: "grades \(symbol)").prefix(limit))
    }

    // MARK: Statements

    func fetchIncomeStatements(symbol: String, limit: Int = 8) async -> [FMPIncomeStatement] {
        let capped = min(limit, Self.maxFreeLimit)
        guard let data = await get("income-statement", ["symbol": symbol, "limit": "\(capped)"]) else { return [] }
        return decodeArray(FMPIncomeStatement.self, from: data, label: "income-statement \(symbol)")
    }

    /// Institutional holders are a paid feature on both FMP (`/stable/institutional-ownership/*`
    /// → 402) and Finnhub (`/stock/fund-ownership` → 403) for the configured keys, so this
    /// returns [] without spending a call. Wire up the stable endpoint after upgrading the plan.
    func fetchInstitutionalHolders(symbol: String, limit: Int = 10) async -> [FMPInstitutionalHolder] {
        if !loggedInstitutionalNotice {
            loggedInstitutionalNotice = true
            AppLogger.api.info("FMP institutional holders need a paid FMP plan — returning none")
        }
        return []
    }

    func fetchBalanceSheet(symbol: String, limit: Int = 4) async -> [FMPBalanceSheet] {
        let capped = min(limit, Self.maxFreeLimit)
        guard let data = await get("balance-sheet-statement", ["symbol": symbol, "limit": "\(capped)"]) else { return [] }
        return decodeArray(FMPBalanceSheet.self, from: data, label: "balance-sheet \(symbol)")
    }

    func fetchCashFlowStatements(symbol: String, limit: Int = 4) async -> [FMPCashFlow] {
        let capped = min(limit, Self.maxFreeLimit)
        guard let data = await get("cash-flow-statement", ["symbol": symbol, "limit": "\(capped)"]) else { return [] }
        return decodeArray(FMPCashFlow.self, from: data, label: "cash-flow \(symbol)")
    }
}
