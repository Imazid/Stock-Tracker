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
    func seedInitialHistory(currentValue: Double, costBasis: Double) -> [PortfolioSnapshot]
    func mockAssets() -> (stocks: [Asset], crypto: [Asset])
    func mockPortfolio(
        stocks: [Asset],
        crypto: [Asset]
    ) -> (portfolio: [PortfolioHolding], watchlist: [Asset])
}

// MARK: - Implementation

@MainActor
final class PortfolioService: PortfolioServiceProtocol {

    private let persistence: DataPersistenceManager

    init(persistence: DataPersistenceManager = .shared) {
        self.persistence = persistence
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

    /// Generates seed history so the portfolio chart has data points to display
    /// immediately on first launch, rather than waiting for multiple days of usage.
    /// Creates 30 daily snapshots with a gentle random walk from costBasis → currentValue.
    func seedInitialHistory(currentValue: Double, costBasis: Double) -> [PortfolioSnapshot] {
        let calendar = Calendar.current
        let now = Date()
        let days = 30
        let startValue = costBasis > 0 ? costBasis : currentValue * 0.95
        let endValue = currentValue

        var snapshots: [PortfolioSnapshot] = []
        for i in 0..<days {
            let dayOffset = -(days - 1 - i)
            guard let date = calendar.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            let progress = Double(i) / Double(max(1, days - 1))
            // Linear interpolation with small random noise
            let noise = Double.random(in: -0.01...0.01) * endValue
            let value = startValue + (endValue - startValue) * progress + noise
            snapshots.append(PortfolioSnapshot(date: date, totalValue: max(0, value)))
        }
        // Ensure the last point is exactly the current value
        if !snapshots.isEmpty {
            snapshots[snapshots.count - 1] = PortfolioSnapshot(date: now, totalValue: currentValue)
        }
        return snapshots
    }

    // MARK: - Mock Data (first launch)

    func mockAssets() -> (stocks: [Asset], crypto: [Asset]) {
        let stocks: [Asset] = [
            Asset(symbol: "AAPL", name: "Apple Inc.",           price: 180.12, change:  1.24, changePercent:  0.69, volume: 55_000_000, kind: .stock,  exchange: "NYSE"),
            Asset(symbol: "TSLA", name: "Tesla Inc.",           price: 240.87, change: -2.45, changePercent: -1.01, volume: 38_000_000, kind: .stock,  exchange: "NYSE"),
            Asset(symbol: "MSFT", name: "Microsoft Corporation",price: 350.54, change:  3.21, changePercent:  0.92, volume: 29_000_000, kind: .stock,  exchange: "NYSE"),
            Asset(symbol: "NVDA", name: "NVIDIA Corporation",   price: 480.90, change:  5.12, changePercent:  1.08, volume: 32_000_000, kind: .stock,  exchange: "NYSE")
        ]
        let crypto: [Asset] = [
            Asset(symbol: "BTC",  name: "Bitcoin",  price: 62_500, change: -1_200, changePercent: -1.88, volume:     18_000, kind: .crypto, exchange: "Binance"),
            Asset(symbol: "ETH",  name: "Ethereum", price:  3_200, change:     45, changePercent:  1.43, volume:    220_000, kind: .crypto, exchange: "Binance"),
            Asset(symbol: "SOL",  name: "Solana",   price:    135, change:   -3.4, changePercent: -2.45, volume:  1_800_000, kind: .crypto, exchange: "Binance"),
            Asset(symbol: "ADA",  name: "Cardano",  price:   0.45, change:   0.01, changePercent:   2.3, volume: 75_000_000, kind: .crypto, exchange: "Binance")
        ]
        return (stocks, crypto)
    }

    func mockPortfolio(
        stocks: [Asset],
        crypto: [Asset]
    ) -> (portfolio: [PortfolioHolding], watchlist: [Asset]) {
        guard stocks.count >= 2, crypto.count >= 2 else { return ([], []) }
        let portfolio: [PortfolioHolding] = [
            PortfolioHolding(asset: stocks[0], shares: 10,  avgCost: 170),
            PortfolioHolding(asset: stocks[1], shares:  8,  avgCost: 130),
            PortfolioHolding(asset: crypto[0], shares:  0.3, avgCost: 50_000),
            PortfolioHolding(asset: crypto[1], shares:  1.5, avgCost:  2_900)
        ]
        let watchlist = Array(stocks.prefix(4)) + Array(crypto.prefix(2))
        return (portfolio, watchlist)
    }
}
