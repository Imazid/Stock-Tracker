//
//  PortfolioService.swift
//  Stock Tracker
//
//  Domain service responsible for portfolio/watchlist persistence,
//  synthetic history generation, and initial mock data for first launch.
//

import Foundation
import OSLog

// MARK: - Protocol

@MainActor
protocol PortfolioServiceProtocol: AnyObject {
    func save(
        watchlist: [Asset],
        portfolio: [PortfolioHolding],
        history: [PortfolioSnapshot],
        currency: String,
        watchlistGroups: [WatchlistGroup],
        activeWatchlistIndex: Int
    )
    func load() -> (
        watchlist: [Asset],
        portfolio: [PortfolioHolding],
        history: [PortfolioSnapshot],
        currency: String,
        watchlistGroups: [WatchlistGroup],
        activeWatchlistIndex: Int
    )
    func loadWatchlistGroups() -> [WatchlistGroup]
    func loadActiveWatchlistIndex() -> Int
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

    func save(
        watchlist: [Asset],
        portfolio: [PortfolioHolding],
        history: [PortfolioSnapshot],
        currency: String,
        watchlistGroups: [WatchlistGroup],
        activeWatchlistIndex: Int
    ) {
        persistence.saveWatchlist(watchlist)
        persistence.savePortfolio(portfolio)
        persistence.savePortfolioHistory(history)
        persistence.savePreferredCurrency(currency)
        persistence.saveWatchlistGroups(watchlistGroups)
        persistence.saveActiveWatchlistIndex(activeWatchlistIndex)
        AppLogger.persist.debug("Saved portfolio (\(portfolio.count) holdings) and watchlist (\(watchlist.count) assets)")
    }

    func load() -> (
        watchlist: [Asset],
        portfolio: [PortfolioHolding],
        history: [PortfolioSnapshot],
        currency: String,
        watchlistGroups: [WatchlistGroup],
        activeWatchlistIndex: Int
    ) {
        (
            watchlist: persistence.loadWatchlist(),
            portfolio: persistence.loadPortfolio(),
            history: persistence.loadPortfolioHistory(),
            currency: persistence.loadPreferredCurrency(),
            watchlistGroups: persistence.loadWatchlistGroups(),
            activeWatchlistIndex: persistence.loadActiveWatchlistIndex()
        )
    }

    func loadWatchlistGroups() -> [WatchlistGroup] {
        persistence.loadWatchlistGroups()
    }

    func loadActiveWatchlistIndex() -> Int {
        persistence.loadActiveWatchlistIndex()
    }

    // MARK: - Portfolio History (real snapshots)

    /// Appends today's portfolio value as a snapshot. If a snapshot for today already exists,
    /// it is replaced with the new value. Returns the updated history sorted by date.
    func appendCurrentSnapshot(to history: [PortfolioSnapshot], currentValue: Double) -> [PortfolioSnapshot] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let newSnapshot = PortfolioSnapshot(date: Date(), totalValue: currentValue)

        var updated = history.filter {
            calendar.startOfDay(for: $0.date) != today
        }
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
