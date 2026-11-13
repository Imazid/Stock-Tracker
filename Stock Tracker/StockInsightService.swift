//
//  StockInsightService.swift
//  Stock Tracker
//
//  Analyst consensus, price targets, rating changes, reported earnings and
//  annual statements for the stock detail screen — US listings only.
//
//  Sources (all real; nothing is mocked or inferred):
//  - Analyst counts: Finnhub `/stock/recommendation` → FMP `grades-consensus`
//  - Price targets: FMP `price-target-consensus` (USD)
//  - Rating changes: FMP `grades` (firm, from → to, date)
//  - Earnings: Finnhub `/stock/earnings` (EPS estimate vs actual) → FMP `earnings`
//  - Balance sheet / cash flow: FMP, loaded only when a Pro user opens them
//
//  Callers must not ask about ASX or crypto symbols: FMP and Finnhub answer
//  "BHP" with the NYSE ADR and "BTC" with the Grayscale ETF.
//

import Foundation
import Combine
import OSLog

// MARK: - Models

struct StockInsight {
    var consensus: AnalystConsensus?
    var targets: PriceTargets?
    var ratingChanges: [AnalystRatingChange]
    var earnings: [EarningsEntry]          // newest first

    var isEmpty: Bool {
        consensus == nil && targets == nil && ratingChanges.isEmpty && earnings.isEmpty
    }
}

struct AnalystConsensus: Equatable {
    let strongBuy: Int
    let buy: Int
    let hold: Int
    let sell: Int
    let strongSell: Int

    var total: Int { strongBuy + buy + hold + sell + strongSell }
    var buyCount: Int { strongBuy + buy }
    var sellCount: Int { sell + strongSell }

    enum Verdict: String { case buy = "Buy", hold = "Hold", sell = "Sell" }

    /// The plurality bucket — what most analysts say (ties lean to Hold).
    var verdict: Verdict {
        if buyCount > hold && buyCount > sellCount { return .buy }
        if sellCount > hold && sellCount > buyCount { return .sell }
        return .hold
    }
}

struct PriceTargets: Equatable {
    let low: Double
    let average: Double
    let high: Double
}

struct AnalystRatingChange: Identifiable, Equatable {
    let id: String
    let firm: String
    let previousGrade: String?
    let newGrade: String
    let action: String?
    let date: Date?
}

struct EarningsEntry: Identifiable, Equatable {
    let id: String
    let label: String           // "Q3 2026" (the company's fiscal quarter when the source says so)
    let periodEnd: Date?
    let epsEstimate: Double?
    let epsActual: Double?

    /// nil when there's no estimate to compare with.
    var beat: Bool? {
        guard let est = epsEstimate, let act = epsActual else { return nil }
        return act >= est
    }
}

struct FinancialStatements {
    var balance: [FinancialRow]
    var cashFlow: [FinancialRow]
    var isEmpty: Bool { balance.isEmpty && cashFlow.isEmpty }
}

struct FinancialRow: Identifiable {
    let id = UUID()
    let metric: String
    let periods: [String]       // ["FY2025", "FY2024", …] newest first
    let values: [Double?]
}

// MARK: - Service

@MainActor
final class StockInsightService: ObservableObject {
    static let shared = StockInsightService()
    private init() {}

    private let fmp = FMPService.shared
    private var insightCache: [String: (insight: StockInsight, fetchedAt: Date)] = [:]
    private var statementCache: [String: FinancialStatements] = [:]
    private let ttl: TimeInterval = 6 * 3600

    func insight(for symbol: String, force: Bool = false) async -> StockInsight {
        let key = symbol.uppercased()
        if !force, let hit = insightCache[key], Date().timeIntervalSince(hit.fetchedAt) < ttl {
            return hit.insight
        }
        let hasFMP = MarketDataProxy.available(debugKey: SecretsConfig.fmpAPIKey)

        async let recsTask = Self.finnhubRecommendations(key)
        async let earningsTask = Self.finnhubEarnings(key)
        async let targetsTask: FMPPriceTargetConsensus? = hasFMP ? fmp.fetchPriceTargetConsensus(symbol: key) : nil
        async let gradesTask: [FMPUpgradeDowngrade] = hasFMP ? fmp.fetchUpgradesDowngrades(symbol: key, limit: 6) : []

        let recs = await recsTask
        let finnhubEarnings = await earningsTask
        let targetResult = await targetsTask
        let grades = await gradesTask

        // Analyst counts: Finnhub's latest month, else FMP's consensus.
        var consensus: AnalystConsensus?
        if let rec = recs.first {
            let c = AnalystConsensus(strongBuy: rec.strongBuy, buy: rec.buy, hold: rec.hold,
                                     sell: rec.sell, strongSell: rec.strongSell)
            if c.total > 0 { consensus = c }
        }
        if consensus == nil, hasFMP, let r = await fmp.fetchAnalystRating(symbol: key) {
            let c = AnalystConsensus(strongBuy: r.strongBuy ?? 0, buy: r.buy ?? 0, hold: r.hold ?? 0,
                                     sell: r.sell ?? 0, strongSell: r.strongSell ?? 0)
            if c.total > 0 { consensus = c }
        }

        var targets: PriceTargets?
        if let t = targetResult,
           let avg = t.targetConsensus ?? t.targetMedian, avg > 0,
           let low = t.targetLow, let high = t.targetHigh, low > 0, high >= low {
            targets = PriceTargets(low: low, average: avg, high: high)
        }

        let changes: [AnalystRatingChange] = grades.enumerated().compactMap { i, g in
            guard let firm = g.gradingCompany, !firm.isEmpty, let grade = g.newGrade, !grade.isEmpty else { return nil }
            return AnalystRatingChange(
                id: "\(key)-\(i)", firm: firm, previousGrade: g.previousGrade,
                newGrade: grade, action: g.action, date: Self.day(g.publishedDate))
        }

        var earnings: [EarningsEntry] = finnhubEarnings.compactMap { item in
            guard let period = item.period, item.actual != nil || item.estimate != nil else { return nil }
            let label: String
            if let q = item.quarter, let y = item.year, (1...4).contains(q) {
                label = "Q\(q) \(y)"
            } else {
                label = Self.monthYear(Self.day(period))
            }
            return EarningsEntry(id: "\(key)-fh-\(period)", label: label, periodEnd: Self.day(period),
                                 epsEstimate: item.estimate, epsActual: item.actual)
        }
        if earnings.isEmpty, hasFMP {
            let rows = await fmp.fetchEarningsHistorical(symbol: key, limit: 6)
            earnings = rows.compactMap { e in
                guard let raw = e.date ?? e.fiscalDateEnding, e.eps != nil else { return nil }
                let date = Self.day(raw)
                return EarningsEntry(id: "\(key)-fmp-\(raw)", label: "Reported \(Self.monthYear(date))",
                                     periodEnd: date, epsEstimate: e.epsEstimated, epsActual: e.eps)
            }
        }
        earnings.sort { ($0.periodEnd ?? .distantPast) > ($1.periodEnd ?? .distantPast) }

        let insight = StockInsight(consensus: consensus, targets: targets,
                                   ratingChanges: changes, earnings: earnings)
        insightCache[key] = (insight, Date())
        return insight
    }

    /// Annual balance sheet + cash flow (FMP). Only fetched when someone opens them.
    func statements(for symbol: String) async -> FinancialStatements {
        let key = symbol.uppercased()
        if let hit = statementCache[key], !hit.isEmpty { return hit }
        guard MarketDataProxy.available(debugKey: SecretsConfig.fmpAPIKey) else { return FinancialStatements(balance: [], cashFlow: []) }
        async let balanceTask = fmp.fetchBalanceSheet(symbol: key, limit: 3)
        async let cashTask = fmp.fetchCashFlowStatements(symbol: key, limit: 3)
        let result = FinancialStatements(
            balance: Self.balanceRows(await balanceTask),
            cashFlow: Self.cashFlowRows(await cashTask)
        )
        statementCache[key] = result
        return result
    }

    // MARK: Finnhub

    private static func finnhubRecommendations(_ symbol: String) async -> [FinnhubRecommendationItem] {
        do { return try await APIService.shared.fetchFinnhubRecommendations(symbol: symbol) }
        catch {
            AppLogger.api.warning("Finnhub recommendations failed for \(symbol): \(error.localizedDescription)")
            return []
        }
    }

    private static func finnhubEarnings(_ symbol: String) async -> [FinnhubEarningsItem] {
        do { return try await APIService.shared.fetchFinnhubEarnings(symbol: symbol) }
        catch {
            AppLogger.api.warning("Finnhub earnings failed for \(symbol): \(error.localizedDescription)")
            return []
        }
    }

    // MARK: Statements

    private static func fiscalLabels(_ dates: [String?]) -> [String] {
        dates.map { raw in raw.map { "FY" + String($0.prefix(4)) } ?? "—" }
    }

    private static func balanceRows(_ items: [FMPBalanceSheet]) -> [FinancialRow] {
        guard !items.isEmpty else { return [] }
        let periods = fiscalLabels(items.map(\.date))
        func row(_ metric: String, _ extract: (FMPBalanceSheet) -> Double?) -> FinancialRow {
            FinancialRow(metric: metric, periods: periods, values: items.map(extract))
        }
        return [
            row("Total assets") { $0.totalAssets },
            row("Cash & short-term investments") { $0.cashAndShortTermInvestments },
            row("Total debt") { $0.totalDebt },
            row("Shareholders' equity") { $0.totalStockholdersEquity },
            row("Current assets") { $0.totalCurrentAssets },
            row("Current liabilities") { $0.totalCurrentLiabilities }
        ].filter { $0.values.contains { $0 != nil } }
    }

    private static func cashFlowRows(_ items: [FMPCashFlow]) -> [FinancialRow] {
        guard !items.isEmpty else { return [] }
        let periods = fiscalLabels(items.map(\.date))
        func row(_ metric: String, _ extract: (FMPCashFlow) -> Double?) -> FinancialRow {
            FinancialRow(metric: metric, periods: periods, values: items.map(extract))
        }
        return [
            row("Operating cash flow") { $0.operatingCashFlow },
            row("Capital expenditure") { $0.capitalExpenditure },
            row("Free cash flow") { $0.freeCashFlow },
            row("Investing cash flow") { $0.netCashUsedForInvestingActivites },
            row("Financing cash flow") { $0.netCashUsedProvidedByFinancingActivities },
            row("Dividends paid") { $0.dividendsPaid }
        ].filter { $0.values.contains { $0 != nil } }
    }

    // MARK: Dates

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func day(_ raw: String?) -> Date? {
        guard let raw, raw.count >= 10 else { return nil }
        return dayFormatter.date(from: String(raw.prefix(10)))
    }

    private static func monthYear(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(.dateTime.month(.abbreviated).year())
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
