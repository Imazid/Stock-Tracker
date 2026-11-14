//
//  PortfolioService.swift
//  Stock Tracker
//
//  Domain service responsible for portfolio/watchlist persistence,
//  synthetic history generation, and initial mock data for first launch.
//

import Foundation

// MARK: - Protocol

@MainActor
protocol PortfolioServiceProtocol: AnyObject {
    func saveCurrency(_ currency: String)
    func loadCurrency() -> String
    func appendCurrentSnapshot(to history: [PortfolioSnapshot], currentValue: Double) -> [PortfolioSnapshot]
    func starterAssets() -> (stocks: [Asset], crypto: [Asset])
}

// MARK: - Implementation

@MainActor
final class PortfolioService: PortfolioServiceProtocol {

    private let persistence: DataPersistenceManager

    init(persistence: DataPersistenceManager? = nil) {
        self.persistence = persistence ?? .shared
    }

    // MARK: - Persistence

    func saveCurrency(_ currency: String) { persistence.savePreferredCurrency(currency) }

    func loadCurrency() -> String { persistence.loadPreferredCurrency() }

    // MARK: - Portfolio History (real snapshots)

    /// Appends today's portfolio value as a snapshot. If a snapshot for today already exists,
    /// it is replaced with the new value. Returns the updated history sorted by date.
    func appendCurrentSnapshot(to history: [PortfolioSnapshot], currentValue: Double) -> [PortfolioSnapshot] {
        let newSnapshot = PortfolioSnapshot(date: Date(), totalValue: currentValue)
        let day = newSnapshot.utcDay
        var updated = history.filter { $0.utcDay != day }
        updated.append(newSnapshot)
        return updated.sorted { $0.date < $1.date }
    }

    // MARK: - Starter catalogue

    func starterAssets() -> (stocks: [Asset], crypto: [Asset]) {
        let stocks = OnboardingCatalog.us.filter { ["AAPL", "TSLA", "MSFT", "NVDA"].contains($0.symbol) }
        let crypto = OnboardingCatalog.crypto.filter { ["BTC", "ETH", "SOL", "ADA"].contains($0.symbol) }
        func asset(_ pick: PickedAsset) -> Asset {
            Asset(symbol: pick.symbol, name: pick.name, price: 0, change: 0, changePercent: 0,
                  volume: 0, kind: pick.kind, exchange: pick.exchange)
        }
        return (stocks.map(asset), crypto.map(asset))
    }
}
