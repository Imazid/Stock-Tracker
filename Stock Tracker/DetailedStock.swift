//
//  DetailedStock.swift
//  Stock Tracker
//
//  Created by Ihtisham Mazid on 24/1/2026.
//

import Foundation

// MARK: - Enhanced Stock Model
struct DetailedStock: Identifiable {
    let id = UUID()
    let symbol: String
    let name: String
    var exchange: String           // mutable so FMP exchangeShortName can override

    // Price & Performance
    var currentPrice: Double
    var openPrice: Double?
    var dayChange: Double
    var dayChangePercent: Double
    var dayHigh: Double?
    var dayLow: Double?
    var preMarketPrice: Double?
    var afterHoursPrice: Double?
    var previousClose: Double

    // Moving Averages
    var priceAvg50: Double?
    var priceAvg200: Double?

    // Market Stats
    var marketCap: Double
    var enterpriseValue: Double?
    var volume: Int
    var avgVolume: Int
    var float: Double?
    var sharesOutstanding: Double

    // Valuation
    var peRatio: Double?
    var forwardPE: Double?
    var pegRatio: Double?
    var priceToBook: Double?
    var priceToSales: Double?

    // Financial Health
    var revenue: Double?
    var grossMargin: Double?
    var operatingMargin: Double?
    var profitMargin: Double?
    var freeCashFlow: Double?
    var debtToEquity: Double?

    // Growth
    var revenueGrowthYoY: Double?
    var earningsGrowthYoY: Double?
    var epsGrowth: Double?

    // Dividends
    var dividendYield: Double?
    var annualDividend: Double?
    var payoutRatio: Double?
    // Risk
    var beta: Double?
    var week52High: Double
    var week52Low: Double
    var shortInterest: Double?

    // Company Overview (populated from FMP)
    var companyDescription: String? = nil
    var sector: String? = nil
    var industry: String? = nil
    var website: String? = nil
    var ceo: String? = nil
    var logoURL: String? = nil
    var employees: String? = nil
    var ipoDate: String? = nil
    var country: String? = nil

    // Raw income statements from FMP (newest first), used by FinancialsTabView
    var incomeStatements: [FMPIncomeStatement] = []

    var isPositive: Bool { dayChange >= 0 }

    /// Seeded from a quote; nil until FMP's profile names the listing.
    var hasProfile: Bool { companyDescription?.isEmpty == false || sector?.isEmpty == false }

    // MARK: - FMP Merge

    /// Returns a new DetailedStock updated with real data from all FMP responses.
    /// Fills only what FMP left empty (FMP's figures win when both answer), so the
    /// page still has real key stats when FMP's free daily quota is spent.
    static func filling(from f: FinnhubFundamentals, to base: DetailedStock) -> DetailedStock {
        var s = base
        if s.marketCap <= 0, let v = f.marketCapUSD, v > 0 { s.marketCap = v }
        if s.sharesOutstanding <= 0, let v = f.sharesOutstanding, v > 0 { s.sharesOutstanding = v }
        if s.avgVolume <= 0, let v = f.avgVolume3M, v > 0 { s.avgVolume = Int(v) }
        if s.week52High <= 0, let v = f.week52High, v > 0 { s.week52High = v }
        if s.week52Low <= 0, let v = f.week52Low, v > 0 { s.week52Low = v }
        if s.peRatio == nil, let v = f.peTTM, v > 0 { s.peRatio = v }
        if s.forwardPE == nil, let v = f.forwardPE, v > 0 { s.forwardPE = v }
        if s.pegRatio == nil, let v = f.peg, v > 0 { s.pegRatio = v }
        if s.priceToBook == nil, let v = f.priceToBook, v > 0 { s.priceToBook = v }
        if s.priceToSales == nil, let v = f.priceToSales, v > 0 { s.priceToSales = v }
        if s.beta == nil { s.beta = f.beta }
        if s.dividendYield == nil { s.dividendYield = f.dividendYield }
        if s.grossMargin == nil { s.grossMargin = f.grossMargin }
        if s.operatingMargin == nil { s.operatingMargin = f.operatingMargin }
        if s.profitMargin == nil { s.profitMargin = f.netMargin }
        if s.revenueGrowthYoY == nil { s.revenueGrowthYoY = f.revenueGrowthYoY }
        if s.earningsGrowthYoY == nil { s.earningsGrowthYoY = f.epsGrowthYoY }
        if s.debtToEquity == nil { s.debtToEquity = f.debtToEquity }
        if s.industry?.isEmpty ?? true { s.industry = f.industry }
        if s.website?.isEmpty ?? true { s.website = f.website }
        if s.ipoDate?.isEmpty ?? true { s.ipoDate = f.ipoDate }
        if let short = f.exchangeShortName, ["", "US", "—"].contains(s.exchange.uppercased()) { s.exchange = short }
        return s
    }

    static func applying(
        profile: FMPProfile?,
        quote: FMPQuote?,
        ratios: FMPRatios?,
        incomeStatements: [FMPIncomeStatement],
        analystEstimates: FMPAnalystEstimates? = nil,
        analystRating: FMPAnalystRating? = nil,
        to base: DetailedStock
    ) -> DetailedStock {
        var s = base

        // --- Quote: fundamentals only ---
        // The live price, day change and previous close come from the app's own
        // quote (Alpaca/Yahoo/CoinGecko). FMP's quote can be a session behind, so
        // it never overwrites them (Home showed $523.97 +1.50% and the detail
        // $514.71 −0.28% for the same tap). Intraday open/high/low are kept only
        // when FMP's previous close matches ours, i.e. it describes the same session.
        if let q = quote {
            if let mc  = q.marketCap, mc > 0          { s.marketCap        = mc }
            if let v   = q.volume, v > 0              { s.volume           = v }
            if let av  = q.avgVolume, av > 0          { s.avgVolume        = av }
            if let so  = q.sharesOutstanding, so > 0  { s.sharesOutstanding = so }
            if let pe  = q.pe, pe > 0                 { s.peRatio          = pe }
            if let yh  = q.yearHigh, yh > 0           { s.week52High       = yh }
            if let yl  = q.yearLow, yl > 0            { s.week52Low        = yl }
            if let ma50  = q.priceAvg50               { s.priceAvg50       = ma50 }
            if let ma200 = q.priceAvg200              { s.priceAvg200      = ma200 }
            let sameSession: Bool = {
                guard let pc = q.previousClose, pc > 0, base.previousClose > 0 else { return false }
                return abs(pc - base.previousClose) / base.previousClose < 0.002
            }()
            if sameSession {
                s.openPrice = q.open
                s.dayHigh   = q.dayHigh
                s.dayLow    = q.dayLow
            }
        }

        // --- Profile (company info + dividend + exchange) ---
        if let p = profile {
            if let beta = p.beta             { s.beta = beta }
            if let mc   = p.mktCap, mc > 0  { s.marketCap = mc }
            // Prefer exchangeShortName (e.g. "NASDAQ"), fall back to full exchange string
            if let short = p.exchangeShortName, !short.isEmpty {
                s.exchange = short
            } else if let exc = p.exchange, !exc.isEmpty {
                s.exchange = exc
            }
            s.companyDescription = p.description
            s.sector             = p.sector
            s.industry           = p.industry
            s.website            = p.website
            s.ceo                = p.ceo
            s.logoURL            = p.image
            s.employees          = p.fullTimeEmployees
            s.ipoDate            = p.ipoDate
            s.country            = p.country
            if let lastDiv = p.lastDiv, let price = p.price, price > 0 {
                s.dividendYield  = lastDiv / price
                s.annualDividend = lastDiv
            }
        }

        // --- Ratios (valuation multiples + margins + FCF + D/E + dividends) ---
        if let r = ratios {
            if let pe  = r.resolvedPE                  { s.peRatio        = pe }
            if let pb  = r.resolvedPB                  { s.priceToBook    = pb }
            if let ps  = r.resolvedPS                  { s.priceToSales   = ps }
            if let peg = r.resolvedPEG                 { s.pegRatio       = peg }
            if let gm  = r.grossProfitMargin           { s.grossMargin    = gm }
            if let om  = r.operatingProfitMargin       { s.operatingMargin = om }
            if let pm  = r.netProfitMargin             { s.profitMargin   = pm }
            if let de  = r.debtEquityRatio             { s.debtToEquity   = de }
            if let dy  = r.dividendYield               { s.dividendYield  = dy }
            if let pr  = r.payoutRatio                 { s.payoutRatio    = pr }
            if let fcfps = r.freeCashFlowPerShare, s.sharesOutstanding > 0 {
                s.freeCashFlow = fcfps * s.sharesOutstanding
            }
            if let evm = r.enterpriseValueMultiple,
               let stmt = incomeStatements.first,
               let ebitda = stmt.ebitda, ebitda > 0 {
                s.enterpriseValue = evm * ebitda
            }
        }

        // --- Analyst Estimates (Forward P/E = price / estimated EPS) ---
        if let est = analystEstimates,
           let epsEst = est.estimatedEpsAvg, epsEst > 0,
           s.currentPrice > 0 {
            s.forwardPE = s.currentPrice / epsEst
        }

        // --- Store raw income statements for FinancialsTabView ---
        s.incomeStatements = incomeStatements

        // --- Income Statements (revenue + margins + YoY growth) ---
        if let latest = incomeStatements.first {
            if let rev = latest.revenue { s.revenue = rev }

            // Prefer pre-calculated ratio fields; fall back to computing from raw numbers
            if s.grossMargin == nil {
                if let r = latest.grossProfitRatio {
                    s.grossMargin = r
                } else if let gp = latest.grossProfit, let rev = latest.revenue, rev > 0 {
                    s.grossMargin = gp / rev
                }
            }
            if s.operatingMargin == nil {
                if let r = latest.operatingIncomeRatio {
                    s.operatingMargin = r
                } else if let oi = latest.operatingIncome, let rev = latest.revenue, rev > 0 {
                    s.operatingMargin = oi / rev
                }
            }
            if s.profitMargin == nil {
                if let r = latest.netIncomeRatio {
                    s.profitMargin = r
                } else if let ni = latest.netIncome, let rev = latest.revenue, rev > 0 {
                    s.profitMargin = ni / rev
                }
            }
        }

        if incomeStatements.count >= 2 {
            let cur = incomeStatements[0]
            let prv = incomeStatements[1]
            if let r0 = cur.revenue, let r1 = prv.revenue, r1 != 0 {
                s.revenueGrowthYoY = (r0 - r1) / abs(r1)
            }
            // Use diluted EPS if available, otherwise basic
            let eps0 = cur.epsDiluted ?? cur.eps
            let eps1 = prv.epsDiluted ?? prv.eps
            if let e0 = eps0, let e1 = eps1, e1 != 0 {
                s.earningsGrowthYoY = (e0 - e1) / abs(e1)
                s.epsGrowth         = s.earningsGrowthYoY
            }
        }

        // --- Derived: PEG fallback (P/E ÷ annualised earnings growth %) ---
        if s.pegRatio == nil, let pe = s.peRatio, let growth = s.earningsGrowthYoY, growth > 0 {
            s.pegRatio = pe / (growth * 100)
        }

        return s
    }
}

// MARK: - User Position
struct StockPosition {
    let symbol: String
    var shares: Double
    var avgCost: Double
    var totalCost: Double { shares * avgCost }

    func currentValue(at price: Double) -> Double {
        shares * price
    }

    func unrealizedGainLoss(at price: Double) -> Double {
        currentValue(at: price) - totalCost
    }

    func unrealizedGainLossPercent(at price: Double) -> Double {
        guard totalCost > 0 else { return 0 }
        return (unrealizedGainLoss(at: price) / totalCost) * 100
    }
}
