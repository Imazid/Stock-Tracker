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

    // Analyst Consensus (from FMP /stable/grades-consensus)
    var analystStrongBuy: Int? = nil
    var analystBuy: Int? = nil
    var analystHold: Int? = nil
    var analystSell: Int? = nil
    var analystStrongSell: Int? = nil
    var analystConsensus: String? = nil

    // Earnings History — up to 8 quarters (from income-statement, newest first)
    var earningsHistory: [EarningsPeriod] = []

    // Raw income statements from FMP (newest first), used by FinancialsTabView
    var incomeStatements: [FMPIncomeStatement] = []

    var isPositive: Bool { dayChange >= 0 }

    // MARK: - FMP Merge

    /// Returns a new DetailedStock updated with real data from all FMP responses.
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

        // --- Quote (live price + intraday + market data) ---
        if let q = quote {
            s.currentPrice = q.price
            if let ch  = q.change             { s.dayChange        = ch }
            if let chp = q.changesPercentage  { s.dayChangePercent = chp }
            if let pc  = q.previousClose      { s.previousClose    = pc }
            if let mc  = q.marketCap          { s.marketCap        = mc }
            if let v   = q.volume             { s.volume           = v }
            if let av  = q.avgVolume          { s.avgVolume        = av }
            if let so  = q.sharesOutstanding  { s.sharesOutstanding = so }
            if let pe  = q.pe                 { s.peRatio          = pe }
            if let yh  = q.yearHigh           { s.week52High       = yh }
            if let yl  = q.yearLow            { s.week52Low        = yl }
            // Intraday
            if let op  = q.open               { s.openPrice        = op }
            if let dh  = q.dayHigh            { s.dayHigh          = dh }
            if let dl  = q.dayLow             { s.dayLow           = dl }
            // Moving averages
            if let ma50  = q.priceAvg50       { s.priceAvg50       = ma50 }
            if let ma200 = q.priceAvg200      { s.priceAvg200      = ma200 }
            // Exchange (quote may carry short name like "NASDAQ")
            if let exc = q.exchange, !exc.isEmpty { s.exchange = exc }
        }

        // --- Profile (company info + dividend + exchange) ---
        if let p = profile {
            if let beta = p.beta             { s.beta = beta }
            if let mc   = p.mktCap          { s.marketCap = mc }
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

        // --- Analyst Consensus (buy/hold/sell distribution) ---
        if let ar = analystRating {
            s.analystStrongBuy  = ar.strongBuy
            s.analystBuy        = ar.buy
            s.analystHold       = ar.hold
            s.analystSell       = ar.sell
            s.analystStrongSell = ar.strongSell
            s.analystConsensus  = ar.consensus
        }

        // --- Earnings History (up to 8 quarters, newest first) ---
        if !incomeStatements.isEmpty {
            s.earningsHistory = incomeStatements.compactMap { stmt -> EarningsPeriod? in
                guard let date = stmt.date else { return nil }
                // date is typically "2024-09-28" — parse year and derive quarter label
                let parts = date.split(separator: "-")
                let label: String
                if parts.count >= 2, let month = Int(parts[1]), let year = Int(parts[0]) {
                    let quarter = (month - 1) / 3 + 1
                    label = "Q\(quarter) '\(String(year).suffix(2))"
                } else {
                    label = String(date.prefix(7))
                }
                return EarningsPeriod(
                    label: label,
                    eps: stmt.epsDiluted ?? stmt.eps,
                    revenue: stmt.revenue
                )
            }
        }

        return s
    }
}

// MARK: - Earnings Period

struct EarningsPeriod: Identifiable {
    let id = UUID()
    let label: String       // e.g. "Q1 2024"
    let eps: Double?
    let revenue: Double?
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

// MARK: - Chart Data Point
struct ChartDataPoint: Identifiable {
    let id = UUID()
    let date: Date
    let price: Double
    let volume: Double?
}
