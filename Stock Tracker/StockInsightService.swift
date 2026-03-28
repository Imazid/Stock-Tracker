//
//  StockInsightService.swift
//  Stock Tracker
//
//  Models and service for analyst consensus, earnings, institutional holders,
//  and financial statements. Mock data is used until a real provider is wired.
//

import Foundation
import Combine
import OSLog

// MARK: - Models

struct StockInsight {
    var consensus: AnalystConsensus?
    var ratings: [AnalystRating]
    var earnings: [EarningsEntry]
    var holders: [InstitutionalHolder]
    var financials: FinancialStatements
}

struct AnalystConsensus {
    let strongBuy: Int
    let buy: Int
    let hold: Int
    let sell: Int
    let strongSell: Int
    let targetLow: Double
    let targetMean: Double
    let targetHigh: Double

    var totalRatings: Int { strongBuy + buy + hold + sell + strongSell }

    var bullishCount: Int { strongBuy + buy }
    var bearishCount: Int { sell + strongSell }
}

struct AnalystRating: Identifiable {
    let id: String
    let firm: String
    let analyst: String
    let rating: String
    let priceTarget: Double
    let date: String

    var ratingColor: RatingColor {
        switch rating.lowercased() {
        case "strong buy", "outperform", "overweight": return .positive
        case "sell", "underperform", "underweight", "strong sell": return .negative
        default: return .neutral
        }
    }

    enum RatingColor { case positive, neutral, negative }
}

struct EarningsEntry: Identifiable {
    let id: UUID
    let quarter: String         // e.g. "Q3 2024"
    let date: String            // e.g. "Nov 1, 2024"
    let revenueEst: Double      // Billions
    let revenueActual: Double   // Billions
    let epsEst: Double
    let epsActual: Double
    let priceMove1D: Double     // % move day after earnings

    var revenueBeat: Bool { revenueActual >= revenueEst }
    var epsBeat: Bool     { epsActual >= epsEst }
    var hasRevenueData: Bool { revenueEst != 0 || revenueActual != 0 }
}

struct InstitutionalHolder: Identifiable {
    let id: UUID
    let name: String
    let shares: Double          // millions
    let value: Double           // billions USD
    let changePercent: Double   // quarter-over-quarter
}

struct FinancialStatements {
    var incomeAnnual: [FinancialRow]
    var incomeQuarterly: [FinancialRow]
    var balanceAnnual: [FinancialRow]
    var cashFlowAnnual: [FinancialRow]
}

struct FinancialRow: Identifiable {
    let id: UUID
    let metric: String
    let periods: [String]       // e.g. ["FY2023", "FY2022", "FY2021"]
    let values: [Double?]       // matching length to periods
    let isHeader: Bool          // section separator row

    init(metric: String, periods: [String], values: [Double?], isHeader: Bool = false) {
        self.id = UUID()
        self.metric = metric
        self.periods = periods
        self.values = values
        self.isHeader = isHeader
    }
}

// MARK: - Service

@MainActor
final class StockInsightService: ObservableObject {
    static let shared = StockInsightService()
    private init() {}

    @Published var insights: [String: StockInsight] = [:]
    @Published var loadingSymbols: Set<String> = []

    private let fmp = FMPService.shared

    func fetchInsight(for symbol: String, currentPrice: Double = 0) async {
        guard insights[symbol] == nil, !loadingSymbols.contains(symbol) else { return }
        loadingSymbols.insert(symbol)
        defer { loadingSymbols.remove(symbol) }

        let hasFMP = !SecretsConfig.fmpAPIKey.isEmpty

        // Finnhub calls (free tier)
        async let finnhubEarningsTask = fetchFinnhubEarningsSafe(symbol)
        async let finnhubRecsTask = fetchFinnhubRecommendationsSafe(symbol)
        async let finnhubGradesTask = fetchFinnhubUpgradeDowngradeSafe(symbol)
        async let finnhubFundTask = fetchFinnhubFundOwnershipSafe(symbol)

        // FMP calls only if key exists
        async let fmpRating = hasFMP ? fmp.fetchAnalystRating(symbol: symbol) : nil
        async let fmpTargets = hasFMP ? fmp.fetchPriceTargetConsensus(symbol: symbol) : nil
        async let fmpGrades: [FMPUpgradeDowngrade] = hasFMP ? fmp.fetchUpgradesDowngrades(symbol: symbol, limit: 10) : []
        async let fmpEarnings: [FMPEarningsHistorical] = hasFMP ? fmp.fetchEarningsHistorical(symbol: symbol, limit: 8) : []
        async let fmpHolders: [FMPInstitutionalHolder] = hasFMP ? fmp.fetchInstitutionalHolders(symbol: symbol, limit: 10) : []
        async let fmpBalance: [FMPBalanceSheet] = hasFMP ? fmp.fetchBalanceSheet(symbol: symbol, limit: 4) : []
        async let fmpCashFlow: [FMPCashFlow] = hasFMP ? fmp.fetchCashFlowStatements(symbol: symbol, limit: 4) : []

        let finnhubEarningsResult = await finnhubEarningsTask
        let finnhubRecs = await finnhubRecsTask
        let finnhubGrades = await finnhubGradesTask
        let finnhubFundResult = await finnhubFundTask
        let rating = await fmpRating
        let targets = await fmpTargets
        let fmpGradeResults = await fmpGrades
        let earnings = await fmpEarnings
        let fmpHolderResults = await fmpHolders
        let fmpBalanceResults = await fmpBalance
        let fmpCashFlowResults = await fmpCashFlow

        // --- Consensus waterfall (per-field, no mock) ---
        // Rating counts: Finnhub recommendation → FMP rating → nil
        var consensus: AnalystConsensus? = nil
        if let rec = finnhubRecs.first {
            let total = rec.strongBuy + rec.buy + rec.hold + rec.sell + rec.strongSell
            if total > 0 {
                // Price targets: FMP only (Finnhub premium — skip)
                let tLow: Double  = targets?.targetLow ?? 0
                let tMean: Double = targets?.targetConsensus ?? targets?.targetMedian ?? 0
                let tHigh: Double = targets?.targetHigh ?? 0
                consensus = AnalystConsensus(
                    strongBuy: rec.strongBuy, buy: rec.buy, hold: rec.hold,
                    sell: rec.sell, strongSell: rec.strongSell,
                    targetLow: tLow, targetMean: tMean, targetHigh: tHigh
                )
            }
        }
        if consensus == nil, let r = rating {
            let sb = r.strongBuy ?? 0
            let b  = r.buy ?? 0
            let h  = r.hold ?? 0
            let se = r.sell ?? 0
            let ss = r.strongSell ?? 0
            let total = sb + b + h + se + ss
            if total > 0 {
                let tLow: Double  = targets?.targetLow ?? 0
                let tMean: Double = targets?.targetConsensus ?? targets?.targetMedian ?? 0
                let tHigh: Double = targets?.targetHigh ?? 0
                consensus = AnalystConsensus(
                    strongBuy: sb, buy: b, hold: h, sell: se, strongSell: ss,
                    targetLow: tLow, targetMean: tMean, targetHigh: tHigh
                )
            }
        }
        // If neither API returns counts → consensus stays nil, UI shows "Consensus data unavailable"

        // --- Ratings waterfall: Finnhub upgrade-downgrade → FMP grades → [] ---
        let ratings: [AnalystRating]
        if !finnhubGrades.isEmpty {
            ratings = finnhubGrades.enumerated().map { i, g in
                AnalystRating(
                    id:          "\(symbol)-fh-\(i)",
                    firm:        g.company ?? "Unknown",
                    analyst:     "",
                    rating:      g.toGrade ?? g.action ?? "N/A",
                    priceTarget: 0,   // Not available from Finnhub free tier
                    date:        Self.formatUnixTimestamp(g.gradeTime)
                )
            }
        } else if !fmpGradeResults.isEmpty {
            ratings = fmpGradeResults.enumerated().map { i, g in
                AnalystRating(
                    id:          "\(symbol)-\(i)",
                    firm:        g.gradingCompany ?? "Unknown",
                    analyst:     "",
                    rating:      g.newGrade ?? g.action ?? "N/A",
                    priceTarget: g.priceWhenPosted ?? 0,
                    date:        Self.formatFMPDate(g.publishedDate)
                )
            }
        } else {
            ratings = []
        }

        // --- Earnings waterfall: Finnhub → FMP → [] (no mock) ---
        let earningsEntries: [EarningsEntry]
        if !finnhubEarningsResult.isEmpty {
            earningsEntries = finnhubEarningsResult.compactMap { item -> EarningsEntry? in
                guard let period = item.period else { return nil }
                let q = item.quarter ?? 0
                let y = item.year ?? 0
                let quarterLabel = (q >= 1 && q <= 4 && y > 0) ? "Q\(q) \(y)" : Self.quarterLabel(from: period)
                return EarningsEntry(
                    id:             UUID(),
                    quarter:        quarterLabel,
                    date:           Self.formatFMPDate(period),
                    revenueEst:     0,
                    revenueActual:  0,
                    epsEst:         item.estimate ?? 0,
                    epsActual:      item.actual ?? 0,
                    priceMove1D:    0
                )
            }
        } else if !earnings.isEmpty {
            earningsEntries = earnings.compactMap { (e: FMPEarningsHistorical) -> EarningsEntry? in
                guard let dateStr = e.date ?? e.fiscalDateEnding else { return nil }
                let revEstBillions: Double = (e.revenueEstimated ?? 0) / 1_000_000_000
                let revActBillions: Double = (e.revenue ?? 0) / 1_000_000_000
                return EarningsEntry(
                    id:             UUID(),
                    quarter:        Self.quarterLabel(from: dateStr),
                    date:           Self.formatFMPDate(dateStr),
                    revenueEst:     revEstBillions,
                    revenueActual:  revActBillions,
                    epsEst:         e.epsEstimated ?? 0,
                    epsActual:      e.eps ?? 0,
                    priceMove1D:    0
                )
            }
        } else {
            earningsEntries = []
        }

        // --- Holders waterfall: Finnhub fund-ownership → FMP institutional → [] ---
        let holders: [InstitutionalHolder]
        let finnhubHolders = finnhubFundResult?.ownership ?? []
        if !finnhubHolders.isEmpty {
            holders = finnhubHolders.compactMap { h -> InstitutionalHolder? in
                guard let name = h.name, !name.isEmpty else { return nil }
                let shares = Double(h.share ?? 0)
                let sharesMil = shares / 1_000_000
                let valueBil = currentPrice > 0 ? (shares * currentPrice) / 1_000_000_000 : 0
                let changePct: Double = {
                    guard let change = h.change, let total = h.share, total != 0 else { return 0 }
                    return (Double(change) / Double(total)) * 100
                }()
                return InstitutionalHolder(
                    id: UUID(), name: name, shares: sharesMil,
                    value: valueBil, changePercent: changePct
                )
            }
        } else if !fmpHolderResults.isEmpty {
            holders = fmpHolderResults.compactMap { h -> InstitutionalHolder? in
                guard let name = h.holder, !name.isEmpty else { return nil }
                let shares = h.shares ?? 0
                let sharesMil = shares / 1_000_000
                let valueBil = currentPrice > 0 ? (shares * currentPrice) / 1_000_000_000 : 0
                let changePct: Double = {
                    guard let change = h.change, shares > 0 else { return 0 }
                    return (change / shares) * 100
                }()
                return InstitutionalHolder(
                    id: UUID(), name: name, shares: sharesMil,
                    value: valueBil, changePercent: changePct
                )
            }
        } else {
            holders = []
        }

        // --- Financials: real FMP data or empty ---
        let balanceRows = Self.buildBalanceRows(from: fmpBalanceResults)
        let cashFlowRows = Self.buildCashFlowRows(from: fmpCashFlowResults)

        insights[symbol] = StockInsight(
            consensus:  consensus,
            ratings:    ratings,
            earnings:   earningsEntries,
            holders:    holders,
            financials: FinancialStatements(
                incomeAnnual: [],
                incomeQuarterly: [],
                balanceAnnual: balanceRows,
                cashFlowAnnual: cashFlowRows
            )
        )
    }

    // MARK: - Finnhub Earnings (safe wrapper)

    private func fetchFinnhubEarningsSafe(_ symbol: String) async -> [FinnhubEarningsItem] {
        do {
            return try await APIService.shared.fetchFinnhubEarnings(symbol: symbol)
        } catch {
            AppLogger.api.warning("Finnhub earnings failed for \(symbol): \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Finnhub Recommendations (safe wrapper)

    private func fetchFinnhubRecommendationsSafe(_ symbol: String) async -> [FinnhubRecommendationItem] {
        do {
            return try await APIService.shared.fetchFinnhubRecommendations(symbol: symbol)
        } catch {
            AppLogger.api.warning("Finnhub recommendations failed for \(symbol): \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Finnhub Upgrade/Downgrade (safe wrapper)

    private func fetchFinnhubUpgradeDowngradeSafe(_ symbol: String) async -> [FinnhubUpgradeDowngrade] {
        do {
            return try await APIService.shared.fetchFinnhubUpgradeDowngrade(symbol: symbol)
        } catch {
            AppLogger.api.warning("Finnhub upgrade-downgrade failed for \(symbol): \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Finnhub Fund Ownership (safe wrapper)

    private func fetchFinnhubFundOwnershipSafe(_ symbol: String) async -> FinnhubFundOwnership? {
        do {
            return try await APIService.shared.fetchFinnhubFundOwnership(symbol: symbol)
        } catch {
            AppLogger.api.warning("Finnhub fund-ownership failed for \(symbol): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Balance Sheet → FinancialRow

    private static func buildBalanceRows(from items: [FMPBalanceSheet]) -> [FinancialRow] {
        guard !items.isEmpty else { return [] }
        let periods = items.compactMap { $0.date?.prefix(4) }.map { String($0) }
        guard !periods.isEmpty else { return [] }

        func row(_ metric: String, _ extract: (FMPBalanceSheet) -> Double?) -> FinancialRow {
            FinancialRow(metric: metric, periods: periods, values: items.map(extract))
        }

        return [
            row("Total Assets")          { $0.totalAssets },
            row("Cash & Equiv")          { $0.cashAndShortTermInvestments },
            row("Total Debt")            { $0.totalDebt },
            row("Shareholders Eq.")      { $0.totalStockholdersEquity },
            row("Current Assets")        { $0.totalCurrentAssets },
            row("Current Liabilities")   { $0.totalCurrentLiabilities },
        ]
    }

    // MARK: - Cash Flow → FinancialRow

    private static func buildCashFlowRows(from items: [FMPCashFlow]) -> [FinancialRow] {
        guard !items.isEmpty else { return [] }
        let periods = items.compactMap { $0.date?.prefix(4) }.map { String($0) }
        guard !periods.isEmpty else { return [] }

        func row(_ metric: String, _ extract: (FMPCashFlow) -> Double?) -> FinancialRow {
            FinancialRow(metric: metric, periods: periods, values: items.map(extract))
        }

        return [
            row("Operating CF")  { $0.operatingCashFlow },
            row("Investing CF")  { $0.netCashUsedForInvestingActivites },
            row("Financing CF")  { $0.netCashUsedProvidedByFinancingActivities },
            row("Free Cash Flow") { $0.freeCashFlow },
            row("Capex")         { $0.capitalExpenditure },
            row("Dividends Paid") { $0.dividendsPaid },
        ]
    }

    // MARK: - FMP Date Helpers

    private static func formatFMPDate(_ raw: String?) -> String {
        guard let raw = raw else { return "" }
        let inputFmt = DateFormatter()
        inputFmt.dateFormat = "yyyy-MM-dd"
        inputFmt.locale = Locale(identifier: "en_US_POSIX")
        guard let date = inputFmt.date(from: String(raw.prefix(10))) else { return raw }
        let outputFmt = DateFormatter()
        outputFmt.dateFormat = "MMM d, yyyy"
        outputFmt.locale = Locale(identifier: "en_US")
        return outputFmt.string(from: date)
    }

    private static func quarterLabel(from dateStr: String) -> String {
        let inputFmt = DateFormatter()
        inputFmt.dateFormat = "yyyy-MM-dd"
        inputFmt.locale = Locale(identifier: "en_US_POSIX")
        guard let date = inputFmt.date(from: String(dateStr.prefix(10))) else { return dateStr }
        let cal = Calendar(identifier: .gregorian)
        let month = cal.component(.month, from: date)
        let year = cal.component(.year, from: date)
        let q: String
        switch month {
        case 1...3:  q = "Q1"
        case 4...6:  q = "Q2"
        case 7...9:  q = "Q3"
        default:     q = "Q4"
        }
        return "\(q) \(year)"
    }

    // MARK: - UNIX Timestamp Helper

    private static func formatUnixTimestamp(_ timestamp: Int?) -> String {
        guard let ts = timestamp else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, yyyy"
        fmt.locale = Locale(identifier: "en_US")
        return fmt.string(from: date)
    }

}

// MARK: - Number Formatting Helper

extension Double {
    /// Compact formatting: 1_234_567_000 → "1.23B", 456_000_000 → "456M", etc.
    func compactFormatted() -> String {
        let abs = Swift.abs(self)
        let sign = self < 0 ? "-" : ""
        switch abs {
        case 1_000_000_000_000...: return "\(sign)\(String(format: "%.2f", abs / 1_000_000_000_000))T"
        case 1_000_000_000...:     return "\(sign)\(String(format: "%.2f", abs / 1_000_000_000))B"
        case 1_000_000...:         return "\(sign)\(String(format: "%.1f", abs / 1_000_000))M"
        case 1_000...:             return "\(sign)\(String(format: "%.1f", abs / 1_000))K"
        default:                   return "\(sign)\(String(format: "%.2f", abs))"
        }
    }
}
