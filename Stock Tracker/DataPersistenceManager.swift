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
        static let watchlistStorage     = "com.stocktracker.persist.watchlistStorage"
        static let watchlistGroups      = "com.stocktracker.persist.watchlistGroups"
        static let portfolioVisits      = "com.stocktracker.persist.portfolioVisits"
        static let priceAlertAccounts   = "com.stocktracker.persist.priceAlertAccounts"
        static let portfolioAccounts   = "com.stocktracker.persist.portfolioAccounts"
        static let portfolioGroups      = "com.stocktracker.persist.portfolioGroups"
        static let portfolioLedgerQueue = "com.stocktracker.persist.portfolioLedgerQueue"
        static let lastPortfolioAccount = "com.stocktracker.persist.lastPortfolioAccount"
        static let hiddenClosedPositions = "com.stocktracker.persist.hiddenClosedPositions"
        static let referralCode         = "com.stocktracker.persist.referralCode"
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

    // MARK: - Portfolio Groups

    func loadPortfolioAccounts() -> StoredPortfolios {
        if let data = keychain.retrieveData(key: KeychainKeys.portfolioAccounts),
           let state = try? decoder.decode(StoredPortfolios.self, from: data) {
            return state
        }
        let groups = keychain.retrieveData(key: KeychainKeys.portfolioGroups)
            .flatMap { try? decoder.decode([PortfolioGroup].self, from: $0) } ?? []
        let state = StoredPortfolios(legacyGroups: groups,
                                     selectedIndex: defaults.integer(forKey: "active_portfolio_index"),
                                     holdings: loadPortfolio(), history: loadPortfolioHistory(),
                                     hiddenClosed: hiddenSyncedClosedPositions(), owner: lastPortfolioAccount())
        savePortfolioAccounts(state)
        return state
    }

    @discardableResult
    func savePortfolioAccounts(_ state: StoredPortfolios) -> Bool {
        guard let data = try? encoder.encode(state) else { return false }
        return keychain.saveData(key: KeychainKeys.portfolioAccounts, value: data)
    }

    func portfolioVisit(for scope: PortfolioVisitSnapshot.Scope) -> PortfolioVisitSnapshot? {
        portfolioVisits().first { $0.scope == scope }
    }

    func savePortfolioVisit(_ snapshot: PortfolioVisitSnapshot) {
        let retained = portfolioVisits().filter { $0.scope != snapshot.scope }
        guard let data = try? encoder.encode([snapshot] + retained) else { return }
        _ = keychain.saveData(key: KeychainKeys.portfolioVisits, value: data)
    }

    func removePortfolioVisits(for portfolio: UUID) {
        let retained = portfolioVisits().filter { $0.scope.portfolio != portfolio }
        guard let data = try? encoder.encode(retained) else { return }
        _ = keychain.saveData(key: KeychainKeys.portfolioVisits, value: data)
    }

    private func portfolioVisits() -> [PortfolioVisitSnapshot] {
        guard let data = keychain.retrieveData(key: KeychainKeys.portfolioVisits) else { return [] }
        return (try? decoder.decode([PortfolioVisitSnapshot].self, from: data)) ?? []
    }

    // MARK: - Watchlist Groups

    func loadWatchlistStorage() -> StoredWatchlists {
        if let data = keychain.retrieveData(key: KeychainKeys.watchlistStorage),
           let storage = try? decoder.decode(StoredWatchlists.self, from: data) {
            return storage
        }
        let groups = keychain.retrieveData(key: KeychainKeys.watchlistGroups)
            .flatMap { try? decoder.decode([WatchlistGroup].self, from: $0) } ?? []
        let storage = StoredWatchlists(legacyGroups: groups, legacyAssets: loadWatchlist(),
                                       selectedIndex: defaults.integer(forKey: "active_watchlist_index"),
                                       owner: lastPortfolioAccount())
        saveWatchlistStorage(storage)
        return storage
    }

    @discardableResult
    func saveWatchlistStorage(_ storage: StoredWatchlists) -> Bool {
        guard let data = try? encoder.encode(storage) else { return false }
        return keychain.saveData(key: KeychainKeys.watchlistStorage, value: data)
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

    private struct AlertAccounts: Codable {
        var alerts: [String: [PriceAlert]]
        var guestImported: Bool
    }

    private func loadAlertAccounts() -> AlertAccounts {
        if let data = keychain.retrieveData(key: KeychainKeys.priceAlertAccounts),
           let stored = try? decoder.decode(AlertAccounts.self, from: data) {
            return stored
        }
        migrateFromUserDefaults(keychainKey: KeychainKeys.priceAlerts, defaultsKey: "saved_price_alerts", type: [PriceAlert].self)
        let legacy = keychain.retrieveData(key: KeychainKeys.priceAlerts)
            .flatMap { try? decoder.decode([PriceAlert].self, from: $0) } ?? []
        let owner = lastPortfolioAccount()
        let result = AlertAccounts(alerts: [owner?.uuidString ?? "device": legacy], guestImported: owner != nil)
        saveAlertAccounts(result)
        return result
    }

    func savePriceAlerts(_ alerts: [PriceAlert], owner: UUID? = nil) {
        var stored = loadAlertAccounts()
        stored.alerts[owner?.uuidString ?? "device"] = alerts
        saveAlertAccounts(stored)
    }

    func loadPriceAlerts(owner: UUID? = nil) -> [PriceAlert] {
        var stored = loadAlertAccounts()
        guard let owner else { return stored.alerts["device"] ?? [] }
        if let alerts = stored.alerts[owner.uuidString] { return alerts }
        let initial = stored.guestImported ? [] : stored.alerts["device"] ?? []
        stored.alerts[owner.uuidString] = initial
        stored.guestImported = true
        saveAlertAccounts(stored)
        return initial
    }

    private func saveAlertAccounts(_ stored: AlertAccounts) {
        guard let data = try? encoder.encode(stored) else { return }
        _ = keychain.saveData(key: KeychainKeys.priceAlertAccounts, value: data)
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

    func rememberPortfolioAccount(_ userId: UUID) {
        _ = keychain.save(key: KeychainKeys.lastPortfolioAccount, value: userId.uuidString)
    }

    func lastPortfolioAccount() -> UUID? {
        keychain.retrieve(key: KeychainKeys.lastPortfolioAccount).flatMap(UUID.init(uuidString:))
    }

    func hiddenSyncedClosedPositions() -> Set<UUID> {
        guard let data = keychain.retrieveData(key: KeychainKeys.hiddenClosedPositions),
              let ids = try? decoder.decode(Set<UUID>.self, from: data) else { return [] }
        return ids
    }

    func loadPortfolioLedgerQueue() -> [String: [PortfolioLedgerChange]] {
        guard let data = keychain.retrieveData(key: KeychainKeys.portfolioLedgerQueue),
              let queue = try? decoder.decode([String: [PortfolioLedgerChange]].self, from: data) else { return [:] }
        return queue
    }

    @discardableResult
    func savePortfolioLedgerQueue(_ queue: [String: [PortfolioLedgerChange]]) -> Bool {
        guard let data = try? encoder.encode(queue) else { return false }
        return keychain.saveData(key: KeychainKeys.portfolioLedgerQueue, value: data)
    }

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

    // MARK: - Referral Code (Keychain — user's own code)

    func saveReferralCode(_ code: ReferralCode) {
        guard let data = try? encoder.encode(code) else { return }
        _ = keychain.saveData(key: KeychainKeys.referralCode, value: data)
    }

    func loadReferralCode() -> ReferralCode? {
        guard let data = keychain.retrieveData(key: KeychainKeys.referralCode),
              let decoded = try? decoder.decode(ReferralCode.self, from: data) else { return nil }
        return decoded
    }

    // MARK: - Pending Referral Code (UserDefaults — temporary, pre-signup)

    func savePendingReferralCode(_ code: String) {
        defaults.set(code, forKey: Constants.Referral.pendingReferralCodeKey)
    }

    func loadPendingReferralCode() -> String? {
        defaults.string(forKey: Constants.Referral.pendingReferralCodeKey)
    }

    func clearPendingReferralCode() {
        defaults.removeObject(forKey: Constants.Referral.pendingReferralCodeKey)
    }

    // MARK: - Clear All

    func clearAllData() {
        _ = keychain.delete(key: KeychainKeys.watchlist)
        // Groups hold their own copy of the watchlist and win on reload — clear them too,
        // or "cleared" watchlists come back.
        _ = keychain.delete(key: KeychainKeys.watchlistGroups)
        _ = keychain.delete(key: KeychainKeys.watchlistStorage)
        _ = keychain.delete(key: KeychainKeys.portfolioGroups)
        _ = keychain.delete(key: KeychainKeys.portfolioAccounts)
        _ = keychain.delete(key: KeychainKeys.portfolioVisits)
        _ = keychain.delete(key: KeychainKeys.portfolioLedgerQueue)
        _ = keychain.delete(key: KeychainKeys.lastPortfolioAccount)
        _ = keychain.delete(key: KeychainKeys.hiddenClosedPositions)
        _ = keychain.delete(key: KeychainKeys.portfolio)
        _ = keychain.delete(key: KeychainKeys.customAssets)
        _ = keychain.delete(key: KeychainKeys.priceAlerts)
        _ = keychain.delete(key: KeychainKeys.priceAlertAccounts)
        _ = keychain.delete(key: KeychainKeys.portfolioHistory)
        _ = keychain.delete(key: KeychainKeys.referralCode)
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
