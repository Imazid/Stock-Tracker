//
//  FMPService.swift
//  Stock Tracker
//
//  Fetches company profile and quote data from Financial Modeling Prep.
//  API docs: https://financialmodelingprep.com/developer/docs
//

import Foundation
import OSLog

// MARK: - Response Models

struct FMPRatios: Decodable {
    let date: String?
    // Valuation — long-form and short-form names both included so either works
    let priceEarningsRatio: Double?         // some FMP responses
    let peRatio: Double?                    // other FMP responses
    let priceEarningsToGrowthRatio: Double? // some FMP responses
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
    let debtEquityRatio: Double?
    let freeCashFlowPerShare: Double?
    let operatingCashFlowPerShare: Double?
    // Dividends
    let dividendYield: Double?
    let payoutRatio: Double?

    // Convenience — picks whichever field name was populated
    var resolvedPE:  Double? { priceEarningsRatio ?? peRatio }
    var resolvedPEG: Double? { priceEarningsToGrowthRatio ?? pegRatio }
    var resolvedPB:  Double? { priceToBookRatio ?? pbRatio }
    var resolvedPS:  Double? { priceToSalesRatio ?? priceSalesRatio }
}

struct FMPAnalystEstimates: Decodable {
    let date: String?
    let estimatedEpsAvg: Double?
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
}

/// Historical earnings from FMP /stable/earning-calendar-confirmed or /api/v3/historical/earning_calendar
struct FMPEarningsHistorical: Decodable {
    let date: String?
    let symbol: String?
    let eps: Double?
    let epsEstimated: Double?
    let revenue: Double?
    let revenueEstimated: Double?
    let fiscalDateEnding: String?
    let updatedFromDate: String?
}

/// Price target consensus from FMP /stable/price-target-consensus
struct FMPPriceTargetConsensus: Decodable {
    let symbol: String?
    let targetHigh: Double?
    let targetLow: Double?
    let targetConsensus: Double?
    let targetMedian: Double?
}

/// Individual analyst upgrades/downgrades from FMP /stable/upgrades-downgrades
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
    let avgVolume: Int?
    let previousClose: Double?
    let eps: Double?
    let pe: Double?
    let sharesOutstanding: Double?
}

// MARK: - Service

final class FMPService {
    static let shared = FMPService()
    private init() {}

    private var apiKey: String { SecretsConfig.fmpAPIKey }
    // Legacy /api/v3 endpoints — free tier compatible (250 calls/day)
    private let baseURL = "https://financialmodelingprep.com/api/v3"
    private let session = URLSession.shared

    /// Decode an FMP response that is always a JSON array `[T]`, returning the first item.
    private func decodeFirst<T: Decodable>(_ type: T.Type, from data: Data) throws -> T? {
        if let items = try? JSONDecoder().decode([T].self, from: data) {
            return items.first
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // Legacy v3 uses path-param style: /api/v3/profile/AAPL?apikey=...
    func fetchProfile(symbol: String) async -> FMPProfile? {
        guard !apiKey.isEmpty,
              let url = URL(string: "\(baseURL)/profile/\(symbol)?apikey=\(apiKey)") else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try decodeFirst(FMPProfile.self, from: data)
        } catch {
            AppLogger.api.error("FMP profile fetch failed for \(symbol): \(error)")
            return nil
        }
    }

    func fetchQuote(symbol: String) async -> FMPQuote? {
        guard !apiKey.isEmpty,
              let url = URL(string: "\(baseURL)/quote/\(symbol)?apikey=\(apiKey)") else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try decodeFirst(FMPQuote.self, from: data)
        } catch {
            AppLogger.api.error("FMP quote fetch failed for \(symbol): \(error)")
            return nil
        }
    }

    func fetchRatios(symbol: String) async -> FMPRatios? {
        guard !apiKey.isEmpty,
              let url = URL(string: "\(baseURL)/ratios/\(symbol)?limit=1&apikey=\(apiKey)") else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try decodeFirst(FMPRatios.self, from: data)
        } catch {
            AppLogger.api.error("FMP ratios fetch failed for \(symbol): \(error)")
            return nil
        }
    }

    func fetchAnalystEstimates(symbol: String) async -> FMPAnalystEstimates? {
        guard !apiKey.isEmpty,
              let url = URL(string: "\(baseURL)/analyst-estimates/\(symbol)?limit=1&apikey=\(apiKey)") else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try decodeFirst(FMPAnalystEstimates.self, from: data)
        } catch {
            AppLogger.api.error("FMP analyst-estimates fetch failed for \(symbol): \(error)")
            return nil
        }
    }

    func fetchAnalystRating(symbol: String) async -> FMPAnalystRating? {
        guard !apiKey.isEmpty,
              let url = URL(string: "\(baseURL)/grade/\(symbol)?limit=1&apikey=\(apiKey)") else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try decodeFirst(FMPAnalystRating.self, from: data)
        } catch {
            AppLogger.api.error("FMP grades-consensus fetch failed for \(symbol): \(error)")
            return nil
        }
    }

    func fetchEarningsHistorical(symbol: String, limit: Int = 8) async -> [FMPEarningsHistorical] {
        guard !apiKey.isEmpty,
              let url = URL(string: "\(baseURL)/historical/earning_calendar/\(symbol)?limit=\(limit)&apikey=\(apiKey)") else { return [] }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            if let items = try? JSONDecoder().decode([FMPEarningsHistorical].self, from: data) {
                return items
            }
            if let item = try? JSONDecoder().decode(FMPEarningsHistorical.self, from: data) {
                return [item]
            }
            return []
        } catch {
            AppLogger.api.error("FMP earnings-historical fetch failed for \(symbol): \(error)")
            return []
        }
    }

    func fetchPriceTargetConsensus(symbol: String) async -> FMPPriceTargetConsensus? {
        guard !apiKey.isEmpty,
              let url = URL(string: "\(baseURL)/price-target-consensus/\(symbol)?apikey=\(apiKey)") else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try decodeFirst(FMPPriceTargetConsensus.self, from: data)
        } catch {
            AppLogger.api.error("FMP price-target-consensus fetch failed for \(symbol): \(error)")
            return nil
        }
    }

    func fetchUpgradesDowngrades(symbol: String, limit: Int = 10) async -> [FMPUpgradeDowngrade] {
        guard !apiKey.isEmpty,
              let url = URL(string: "\(baseURL)/upgrades-downgrades?symbol=\(symbol)&limit=\(limit)&apikey=\(apiKey)") else { return [] }
        // Note: v3 uses query params for this endpoint
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            if let items = try? JSONDecoder().decode([FMPUpgradeDowngrade].self, from: data) {
                return items
            }
            if let item = try? JSONDecoder().decode(FMPUpgradeDowngrade.self, from: data) {
                return [item]
            }
            return []
        } catch {
            AppLogger.api.error("FMP upgrades-downgrades fetch failed for \(symbol): \(error)")
            return []
        }
    }

    func fetchIncomeStatements(symbol: String, limit: Int = 8) async -> [FMPIncomeStatement] {
        guard !apiKey.isEmpty,
              let url = URL(string: "\(baseURL)/income-statement/\(symbol)?limit=\(limit)&apikey=\(apiKey)") else { return [] }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            if let items = try? JSONDecoder().decode([FMPIncomeStatement].self, from: data) {
                return items
            }
            // Fallback: single object returned
            if let item = try? JSONDecoder().decode(FMPIncomeStatement.self, from: data) {
                return [item]
            }
            return []
        } catch {
            AppLogger.api.error("FMP income-statement fetch failed for \(symbol): \(error)")
            return []
        }
    }

    func fetchInstitutionalHolders(symbol: String, limit: Int = 10) async -> [FMPInstitutionalHolder] {
        guard !apiKey.isEmpty,
              let url = URL(string: "\(baseURL)/institutional-holder/\(symbol)?limit=\(limit)&apikey=\(apiKey)") else { return [] }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            if let items = try? JSONDecoder().decode([FMPInstitutionalHolder].self, from: data) {
                return items
            }
            if let item = try? JSONDecoder().decode(FMPInstitutionalHolder.self, from: data) {
                return [item]
            }
            return []
        } catch {
            AppLogger.api.error("FMP institutional-holder fetch failed for \(symbol): \(error)")
            return []
        }
    }

    func fetchBalanceSheet(symbol: String, limit: Int = 4) async -> [FMPBalanceSheet] {
        guard !apiKey.isEmpty,
              let url = URL(string: "\(baseURL)/balance-sheet-statement/\(symbol)?limit=\(limit)&apikey=\(apiKey)") else { return [] }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            if let items = try? JSONDecoder().decode([FMPBalanceSheet].self, from: data) {
                return items
            }
            if let item = try? JSONDecoder().decode(FMPBalanceSheet.self, from: data) {
                return [item]
            }
            return []
        } catch {
            AppLogger.api.error("FMP balance-sheet fetch failed for \(symbol): \(error)")
            return []
        }
    }

    func fetchCashFlowStatements(symbol: String, limit: Int = 4) async -> [FMPCashFlow] {
        guard !apiKey.isEmpty,
              let url = URL(string: "\(baseURL)/cash-flow-statement/\(symbol)?limit=\(limit)&apikey=\(apiKey)") else { return [] }
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            if let items = try? JSONDecoder().decode([FMPCashFlow].self, from: data) {
                return items
            }
            if let item = try? JSONDecoder().decode(FMPCashFlow.self, from: data) {
                return [item]
            }
            return []
        } catch {
            AppLogger.api.error("FMP cash-flow fetch failed for \(symbol): \(error)")
            return []
        }
    }
}
