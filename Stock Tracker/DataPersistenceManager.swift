//
//  DataPersistenceManager.swift
//  Stock Tracker
//
//  Sensitive financial data (portfolio, watchlist, price alerts) → Keychain
//  Non-sensitive preferences (currency, theme) → UserDefaults
//
//  Keychain items use kSecAttrAccessibleWhenUnlockedThisDeviceOnly so data
//  is inaccessible when the device is locked and cannot be restored to a
//  different device via iCloud backup.
//

import Foundation
import OSLog

final class DataPersistenceManager {
    static let shared = DataPersistenceManager()

    private let defaults  = UserDefaults.standard
    private let keychain  = KeychainManager.shared
    private let encoder   = JSONEncoder()
    private let decoder   = JSONDecoder()

    private init() {
        migrateModelVersionIfNeeded()
    }

    // MARK: - Model version check

    /// Bump `currentModelVersion` whenever a Codable model's stored properties change.
    /// On version mismatch, all Keychain data is cleared so the app starts fresh
    /// rather than crashing on a decode error. Users lose data — acceptable; a crash is not.
    private func migrateModelVersionIfNeeded() {
        let storedVersion = defaults.integer(forKey: DefaultsKeys.modelVersion)
        if storedVersion == 0 {
            // First install — just record the current version
            defaults.set(DataPersistenceManager.currentModelVersion, forKey: DefaultsKeys.modelVersion)
            return
        }
        if storedVersion != DataPersistenceManager.currentModelVersion {
            AppLogger.persist.warning(
                "Model version mismatch (stored \(storedVersion) → current \(DataPersistenceManager.currentModelVersion)). Clearing persisted data."
            )
            clearAllData()
            defaults.set(DataPersistenceManager.currentModelVersion, forKey: DefaultsKeys.modelVersion)
        }
    }

    // MARK: - Keychain keys (sensitive financial data)

    private enum KeychainKeys {
        static let watchlist            = "com.stocktracker.persist.watchlist"
        static let portfolio            = "com.stocktracker.persist.portfolio"
        static let priceAlerts          = "com.stocktracker.persist.priceAlerts"
        static let portfolioHistory     = "com.stocktracker.persist.portfolioHistory"
        static let customAssets         = "com.stocktracker.persist.customAssets"
        static let watchlistGroups      = "com.stocktracker.persist.watchlistGroups"
    }

    // MARK: - UserDefaults keys (non-sensitive preferences)

    private enum DefaultsKeys {
        static let preferredCurrency = "preferred_currency"
        static let modelVersion      = "persist_model_version"
    }

    // MARK: - Current model version (bump when Codable models change)

    static let currentModelVersion = 1

    // MARK: - Watchlist

    func saveWatchlist(_ assets: [Asset]) {
        guard let data = try? encoder.encode(assets) else { return }
        _ = keychain.saveData(key: KeychainKeys.watchlist, value: data)
    }

    func loadWatchlist() -> [Asset] {
        guard let data = keychain.retrieveData(key: KeychainKeys.watchlist),
              let decoded = try? decoder.decode([Asset].self, from: data) else {
            migrateFromUserDefaults(keychainKey: KeychainKeys.watchlist, defaultsKey: "saved_watchlist", type: [Asset].self)
            guard let data2 = keychain.retrieveData(key: KeychainKeys.watchlist),
                  let decoded2 = try? decoder.decode([Asset].self, from: data2) else {
                return []
            }
            return decoded2
        }
        return decoded
    }

    // MARK: - Watchlist Groups

    func saveWatchlistGroups(_ groups: [WatchlistGroup]) {
        guard let data = try? encoder.encode(groups) else { return }
        _ = keychain.saveData(key: KeychainKeys.watchlistGroups, value: data)
    }

    func loadWatchlistGroups() -> [WatchlistGroup] {
        guard let data = keychain.retrieveData(key: KeychainKeys.watchlistGroups),
              let groups = try? decoder.decode([WatchlistGroup].self, from: data) else { return [] }
        return groups
    }

    func saveActiveWatchlistIndex(_ index: Int) {
        UserDefaults.standard.set(index, forKey: "active_watchlist_index")
    }

    func loadActiveWatchlistIndex() -> Int {
        UserDefaults.standard.integer(forKey: "active_watchlist_index")
    }

    // MARK: - Portfolio

    func savePortfolio(_ holdings: [PortfolioHolding]) {
        guard let data = try? encoder.encode(holdings) else { return }
        _ = keychain.saveData(key: KeychainKeys.portfolio, value: data)
    }

    func loadPortfolio() -> [PortfolioHolding] {
        guard let data = keychain.retrieveData(key: KeychainKeys.portfolio),
              let decoded = try? decoder.decode([PortfolioHolding].self, from: data) else {
            migrateFromUserDefaults(keychainKey: KeychainKeys.portfolio, defaultsKey: "saved_portfolio", type: [PortfolioHolding].self)
            guard let data2 = keychain.retrieveData(key: KeychainKeys.portfolio),
                  let decoded2 = try? decoder.decode([PortfolioHolding].self, from: data2) else {
                return []
            }
            return decoded2
        }
        return decoded
    }

    // MARK: - Custom Assets

    func saveCustomAssets(_ assets: [Asset]) {
        guard let data = try? encoder.encode(assets) else { return }
        _ = keychain.saveData(key: KeychainKeys.customAssets, value: data)
    }

    func loadCustomAssets() -> [Asset] {
        guard let data = keychain.retrieveData(key: KeychainKeys.customAssets),
              let decoded = try? decoder.decode([Asset].self, from: data) else {
            migrateFromUserDefaults(keychainKey: KeychainKeys.customAssets, defaultsKey: "saved_custom_assets", type: [Asset].self)
            guard let data2 = keychain.retrieveData(key: KeychainKeys.customAssets),
                  let decoded2 = try? decoder.decode([Asset].self, from: data2) else {
                return []
            }
            return decoded2
        }
        return decoded
    }

    // MARK: - Price Alerts

    func savePriceAlerts(_ alerts: [PriceAlert]) {
        guard let data = try? encoder.encode(alerts) else { return }
        _ = keychain.saveData(key: KeychainKeys.priceAlerts, value: data)
    }

    func loadPriceAlerts() -> [PriceAlert] {
        guard let data = keychain.retrieveData(key: KeychainKeys.priceAlerts),
              let decoded = try? decoder.decode([PriceAlert].self, from: data) else {
            migrateFromUserDefaults(keychainKey: KeychainKeys.priceAlerts, defaultsKey: "saved_price_alerts", type: [PriceAlert].self)
            guard let data2 = keychain.retrieveData(key: KeychainKeys.priceAlerts),
                  let decoded2 = try? decoder.decode([PriceAlert].self, from: data2) else {
                return []
            }
            return decoded2
        }
        return decoded
    }

    // MARK: - Portfolio History

    func savePortfolioHistory(_ history: [PortfolioSnapshot]) {
        // Prune to keep only the most recent N days before saving
        let pruned = history.suffix(Constants.Refresh.maxPortfolioHistoryDays)
        guard let data = try? encoder.encode(Array(pruned)) else { return }
        _ = keychain.saveData(key: KeychainKeys.portfolioHistory, value: data)
    }

    func loadPortfolioHistory() -> [PortfolioSnapshot] {
        guard let data = keychain.retrieveData(key: KeychainKeys.portfolioHistory),
              let decoded = try? decoder.decode([PortfolioSnapshot].self, from: data) else {
            migrateFromUserDefaults(keychainKey: KeychainKeys.portfolioHistory, defaultsKey: "saved_portfolio_history", type: [PortfolioSnapshot].self)
            guard let data2 = keychain.retrieveData(key: KeychainKeys.portfolioHistory),
                  let decoded2 = try? decoder.decode([PortfolioSnapshot].self, from: data2) else {
                return []
            }
            return decoded2
        }
        return decoded
    }

    // MARK: - Currency Preference (non-sensitive → UserDefaults)

    func savePreferredCurrency(_ currency: String) {
        defaults.set(currency, forKey: DefaultsKeys.preferredCurrency)
    }

    func loadPreferredCurrency() -> String {
        defaults.string(forKey: DefaultsKeys.preferredCurrency) ?? "USD"
    }

    // MARK: - Sync metadata

    func saveLastSyncDate(_ date: Date) {
        let iso = ISO8601DateFormatter().string(from: date)
        _ = keychain.save(key: Constants.Sync.lastSyncDateKey, value: iso)
    }

    func loadLastSyncDate() -> Date? {
        guard let iso = keychain.retrieve(key: Constants.Sync.lastSyncDateKey) else { return nil }
        return ISO8601DateFormatter().date(from: iso)
    }

    /// Removes only sync session credentials — does NOT touch portfolio/watchlist data.
    /// Call this on sign-out so the app keeps working offline.
    func clearSyncCredentials() {
        _ = keychain.delete(key: Constants.Sync.sessionKeychainKey)
        _ = keychain.delete(key: Constants.Sync.lastSyncDateKey)
        AppLogger.persist.info("Sync credentials cleared from Keychain")
    }

    // MARK: - Clear All

    func clearAllData() {
        _ = keychain.delete(key: KeychainKeys.watchlist)
        _ = keychain.delete(key: KeychainKeys.portfolio)
        _ = keychain.delete(key: KeychainKeys.customAssets)
        _ = keychain.delete(key: KeychainKeys.priceAlerts)
        _ = keychain.delete(key: KeychainKeys.portfolioHistory)
        // Leave UserDefaults preferences intact (currency, theme)
        AppLogger.persist.info("All secure data cleared from Keychain")
    }

    // MARK: - Migration helper

    /// One-time migration: copy data from UserDefaults → Keychain, then delete from defaults.
    private func migrateFromUserDefaults<T: Codable>(
        keychainKey: String,
        defaultsKey: String,
        type: T.Type
    ) {
        guard let data = defaults.data(forKey: defaultsKey),
              !data.isEmpty else { return }
        _ = keychain.saveData(key: keychainKey, value: data)
        defaults.removeObject(forKey: defaultsKey)
        AppLogger.persist.info("Migrated \(defaultsKey) from UserDefaults → Keychain")
    }
}
