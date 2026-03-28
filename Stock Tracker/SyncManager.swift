//
//  SyncManager.swift
//  Stock Tracker
//
//  Coordinates between the local Keychain (DataPersistenceManager) and
//  Supabase tables. The Keychain is always the source of truth for offline use.
//  Supabase is updated opportunistically after mutations.
//
//  SYNC TIER RULES:
//    All signed-in users: watchlist + portfolio + price alerts + portfolio history
//

import Foundation
import Supabase
import Combine
import OSLog

// MARK: - JSONDecoder for manual Supabase response parsing

private extension JSONDecoder {
    /// Matches the decoder the Supabase SDK uses internally.
    /// Our CodingKeys already handle snake_case → camelCase mapping.
    static let supabaseDecoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()
}

// MARK: - Sync State

enum SyncState: Equatable {
    case idle
    case syncing
    case lastSyncedAt(Date)
    case error(String)
}

// MARK: - SyncManager

@MainActor
final class SyncManager: ObservableObject {

    static let shared = SyncManager()

    @Published var syncState: SyncState = .idle

    private let persist = DataPersistenceManager.shared
    private var debounceTask: Task<Void, Never>?

    /// Tracks whether the initial full sync has been performed this session.
    /// Prevents `syncOnSignIn` from re-running on every session restore.
    private var hasPerformedInitialSync = false

    var isSignedIn: Bool { SupabaseManager.auth.currentUser != nil }

    private init() {}

    // MARK: - First-sign-in merge (full sync)

    func syncOnSignIn(marketData: MarketData, alertManager: PriceAlertManager) async {
        guard SupabaseManager.isConfigured else { return }
        guard let userId = SupabaseManager.auth.currentUser?.id else { return }

        // If we already synced this session (e.g. session restore on relaunch),
        // use the lighter incremental pull instead of a full merge.
        if hasPerformedInitialSync {
            await pullAndRefresh(marketData: marketData, alertManager: alertManager)
            return
        }
        hasPerformedInitialSync = true

        syncState = .syncing
        AppLogger.sync.info("Starting first-sign-in sync for user \(userId)")

        do {
            let mergedWatchlist = try await mergeWatchlist(userId: userId)

            let mergedPortfolio = try await mergePortfolio(userId: userId)
            let mergedAlerts    = try await mergeAlerts(userId: userId)
            let mergedHistory   = try await mergeSnapshots(userId: userId)

            persist.saveWatchlist(mergedWatchlist)
            persist.savePortfolio(mergedPortfolio)
            persist.savePriceAlerts(mergedAlerts)
            persist.savePortfolioHistory(mergedHistory)

            marketData.applyRemoteSync(
                watchlist: mergedWatchlist,
                portfolio: mergedPortfolio,
                history: mergedHistory
            )
            alertManager.applyRemoteAlerts(mergedAlerts)

            let now = Date()
            persist.saveLastSyncDate(now)
            syncState = .lastSyncedAt(now)
            AppLogger.sync.info("First-sign-in sync complete")

        } catch {
            syncState = .error(error.localizedDescription)
            AppLogger.sync.error("First-sign-in sync failed: \(error)")
        }
    }

    // MARK: - Incremental pull (foreground refresh, throttled)

    func pullAndRefresh(marketData: MarketData, alertManager: PriceAlertManager) async {
        guard SupabaseManager.isConfigured else { return }
        guard let userId = SupabaseManager.auth.currentUser?.id else { return }

        if let lastSync = persist.loadLastSyncDate(),
           Date().timeIntervalSince(lastSync) < Constants.Sync.foregroundPullThrottle {
            AppLogger.sync.debug("Foreground pull skipped — within throttle window")
            return
        }

        syncState = .syncing

        do {
            let since = persist.loadLastSyncDate() ?? .distantPast
            let sinceStr = ISO8601DateFormatter().string(from: since)

            // Watchlist — available to all signed-in users
            let remoteWatchlist: [RemoteWatchlistAsset]
            do {
                let response = try await SupabaseManager.client
                    .from("watchlist_assets")
                    .select()
                    .eq("user_id", value: userId.uuidString)
                    .gte("updated_at", value: sinceStr)
                    .execute()
                remoteWatchlist = try JSONDecoder.supabaseDecoder.decode([RemoteWatchlistAsset].self, from: response.data)
            } catch let decodeError as DecodingError {
                AppLogger.sync.error("Watchlist decode failed: \(decodeError)")
                remoteWatchlist = []
            }

            var localWatchlist = persist.loadWatchlist()
            for remote in remoteWatchlist {
                if remote.isDeleted {
                    localWatchlist.removeAll { $0.symbol == remote.symbol }
                } else if !localWatchlist.contains(where: { $0.symbol == remote.symbol }) {
                    localWatchlist.append(remote.toDomain())
                }
            }
            persist.saveWatchlist(localWatchlist)

            var localPortfolio = persist.loadPortfolio()
            var localAlerts    = persist.loadPriceAlerts()
            let localHistory   = persist.loadPortfolioHistory()

            let remoteHoldings: [RemoteHolding]
            do {
                let response = try await SupabaseManager.client
                    .from("portfolio_holdings")
                    .select()
                    .eq("user_id", value: userId.uuidString)
                    .gte("updated_at", value: sinceStr)
                    .execute()
                remoteHoldings = try JSONDecoder.supabaseDecoder.decode([RemoteHolding].self, from: response.data)
            } catch let decodeError as DecodingError {
                AppLogger.sync.error("Holdings decode failed: \(decodeError)")
                remoteHoldings = []
            }

            for remote in remoteHoldings {
                if remote.isDeleted {
                    localPortfolio.removeAll { $0.id.uuidString == remote.id }
                } else if !localPortfolio.contains(where: { $0.id.uuidString == remote.id || $0.asset.symbol == remote.assetSymbol }) {
                    localPortfolio.append(remote.toDomain())
                }
            }

            let remoteAlerts: [RemotePriceAlert]
            do {
                let response = try await SupabaseManager.client
                    .from("price_alerts")
                    .select()
                    .eq("user_id", value: userId.uuidString)
                    .gte("updated_at", value: sinceStr)
                    .execute()
                remoteAlerts = try JSONDecoder.supabaseDecoder.decode([RemotePriceAlert].self, from: response.data)
            } catch let decodeError as DecodingError {
                AppLogger.sync.error("Alerts decode failed: \(decodeError)")
                remoteAlerts = []
            }

            for remote in remoteAlerts {
                if remote.isDeleted {
                    localAlerts.removeAll { $0.id.uuidString == remote.id }
                } else if !localAlerts.contains(where: { $0.id.uuidString == remote.id }) {
                    localAlerts.append(remote.toDomain())
                }
            }

            persist.savePortfolio(localPortfolio)
            persist.savePriceAlerts(localAlerts)

            marketData.applyRemoteSync(
                watchlist: localWatchlist,
                portfolio: localPortfolio,
                history: localHistory
            )
            alertManager.applyRemoteAlerts(localAlerts)

            let now = Date()
            persist.saveLastSyncDate(now)
            syncState = .lastSyncedAt(now)
            AppLogger.sync.info("Incremental pull complete")

        } catch {
            syncState = .error(error.localizedDescription)
            AppLogger.sync.error("Incremental pull failed: \(error)")
        }
    }

    // MARK: - Debounced background sync (after mutations)

    func scheduleBackgroundSync() async {
        guard SupabaseManager.isConfigured, isSignedIn else { return }
        debounceTask?.cancel()
        debounceTask = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(Constants.Sync.backgroundSyncDebounce * 1_000_000_000))
                await uploadCurrentState()
            } catch { /* Task cancelled — another mutation came in */ }
        }
    }

    private func uploadCurrentState() async {
        guard let userId = SupabaseManager.auth.currentUser?.id else { return }
        syncState = .syncing
        do {
            try await upsertWatchlist(persist.loadWatchlist(), userId: userId)
            try await upsertPortfolio(persist.loadPortfolio(), userId: userId)
            try await upsertAlerts(persist.loadPriceAlerts(), userId: userId)
            try await upsertSnapshots(persist.loadPortfolioHistory(), userId: userId)
            let now = Date()
            persist.saveLastSyncDate(now)
            syncState = .lastSyncedAt(now)
            AppLogger.sync.info("Background upload complete")
        } catch {
            syncState = .error(error.localizedDescription)
            AppLogger.sync.error("Background upload failed: \(error)")
        }
    }

    // MARK: - Soft delete

    func softDeleteAlert(id: UUID) async {
        guard SupabaseManager.isConfigured, isSignedIn else { return }
        do {
            let nowStr = ISO8601DateFormatter().string(from: Date())
            try await SupabaseManager.client
                .from("price_alerts")
                .update(["deleted_at": nowStr])
                .eq("id", value: id.uuidString)
                .execute()
        } catch {
            AppLogger.sync.error("Soft-delete alert failed: \(error)")
        }
    }

    func softDeleteHolding(id: UUID) async {
        guard SupabaseManager.isConfigured, isSignedIn else { return }
        do {
            let nowStr = ISO8601DateFormatter().string(from: Date())
            try await SupabaseManager.client
                .from("portfolio_holdings")
                .update(["deleted_at": nowStr])
                .eq("id", value: id.uuidString)
                .execute()
        } catch {
            AppLogger.sync.error("Soft-delete holding failed: \(error)")
        }
    }

    // MARK: - Upsert helpers

    private func upsertWatchlist(_ assets: [Asset], userId: UUID) async throws {
        let rows = assets.map { RemoteWatchlistAsset.from($0, userId: userId) }
        guard !rows.isEmpty else { return }
        // Deduplicate by (user_id, symbol) — keep last occurrence to avoid
        // "ON CONFLICT DO UPDATE cannot affect row a second time"
        var seen = Set<String>()
        let unique = rows.reversed().filter { seen.insert($0.symbol).inserted }.reversed()
        try await SupabaseManager.client
            .from("watchlist_assets")
            .upsert(Array(unique), onConflict: "user_id,symbol")
            .execute()
    }

    private func upsertPortfolio(_ holdings: [PortfolioHolding], userId: UUID) async throws {
        let holdingRows = holdings.map { RemoteHolding.from($0, userId: userId) }
        if !holdingRows.isEmpty {
            // Deduplicate by id
            var seenH = Set<String>()
            let uniqueH = holdingRows.reversed().filter { seenH.insert($0.id).inserted }.reversed()
            try await SupabaseManager.client
                .from("portfolio_holdings")
                .upsert(Array(uniqueH), onConflict: "id")
                .execute()
        }
        let txRows = holdings.flatMap { h in
            h.transactions.map { RemoteTransaction.from($0, holdingId: h.id, userId: userId) }
        }
        if !txRows.isEmpty {
            // Deduplicate by id
            var seenT = Set<String>()
            let uniqueT = txRows.reversed().filter { seenT.insert($0.id).inserted }.reversed()
            try await SupabaseManager.client
                .from("transactions")
                .upsert(Array(uniqueT), onConflict: "id")
                .execute()
        }
    }

    private func upsertAlerts(_ alerts: [PriceAlert], userId: UUID) async throws {
        let rows = alerts.map { RemotePriceAlert.from($0, userId: userId) }
        guard !rows.isEmpty else { return }
        // Deduplicate by id
        var seen = Set<String>()
        let unique = rows.reversed().filter { seen.insert($0.id).inserted }.reversed()
        try await SupabaseManager.client
            .from("price_alerts")
            .upsert(Array(unique), onConflict: "id")
            .execute()
    }

    private func upsertSnapshots(_ history: [PortfolioSnapshot], userId: UUID) async throws {
        let recent = history.suffix(Constants.Sync.maxSnapshotSyncDays)
        let rows = recent.map { RemotePortfolioSnapshot.from($0, userId: userId) }
        guard !rows.isEmpty else { return }
        // Deduplicate by snapshot_date — keep last occurrence
        var seen = Set<String>()
        let unique = rows.reversed().filter { seen.insert($0.snapshot_date).inserted }.reversed()
        try await SupabaseManager.client
            .from("portfolio_snapshots")
            .upsert(Array(unique), onConflict: "user_id,snapshot_date")
            .execute()
    }

    // MARK: - Merge helpers (first sign-in)

    private func mergeWatchlist(userId: UUID) async throws -> [Asset] {
        let response = try await SupabaseManager.client
            .from("watchlist_assets")
            .select()
            .eq("user_id", value: userId.uuidString)
            .execute()
        let all: [RemoteWatchlistAsset]
        do {
            all = try JSONDecoder.supabaseDecoder.decode([RemoteWatchlistAsset].self, from: response.data)
        } catch {
            AppLogger.sync.error("mergeWatchlist decode failed: \(error)")
            all = []
        }

        let remote = all.filter { !$0.isDeleted }
        let local  = persist.loadWatchlist()
        let remoteBySymbol = Dictionary(uniqueKeysWithValues: remote.map { ($0.symbol, $0) })

        var merged: [Asset] = remote.map { $0.toDomain() }
        let localOnly = local.filter { remoteBySymbol[$0.symbol] == nil }
        merged.append(contentsOf: localOnly)
        if !localOnly.isEmpty { try await upsertWatchlist(localOnly, userId: userId) }
        return merged
    }

    private func mergePortfolio(userId: UUID) async throws -> [PortfolioHolding] {
        let holdingsResponse = try await SupabaseManager.client
            .from("portfolio_holdings")
            .select()
            .eq("user_id", value: userId.uuidString)
            .execute()
        let allHoldings: [RemoteHolding]
        do {
            allHoldings = try JSONDecoder.supabaseDecoder.decode([RemoteHolding].self, from: holdingsResponse.data)
        } catch {
            AppLogger.sync.error("mergePortfolio holdings decode failed: \(error)")
            allHoldings = []
        }

        let txnsResponse = try await SupabaseManager.client
            .from("transactions")
            .select()
            .eq("user_id", value: userId.uuidString)
            .execute()
        let allTxns: [RemoteTransaction]
        do {
            allTxns = try JSONDecoder.supabaseDecoder.decode([RemoteTransaction].self, from: txnsResponse.data)
        } catch {
            AppLogger.sync.error("mergePortfolio transactions decode failed: \(error)")
            allTxns = []
        }

        let remote     = allHoldings.filter { !$0.isDeleted }
        let txByHolding = Dictionary(grouping: allTxns.filter { !$0.isDeleted }, by: { $0.holdingId })
        let remoteById  = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
        let remoteSymbols = Set(remote.map { $0.assetSymbol })
        let local       = persist.loadPortfolio()

        var merged: [PortfolioHolding] = remote.map { r in
            r.toDomain(transactions: (txByHolding[r.id] ?? []).map { $0.toDomain() })
        }
        // Only add local holdings whose ID AND symbol are both absent from remote
        let localOnly = local.filter { remoteById[$0.id.uuidString] == nil && !remoteSymbols.contains($0.asset.symbol) }
        merged.append(contentsOf: localOnly)
        if !localOnly.isEmpty { try await upsertPortfolio(localOnly, userId: userId) }
        return merged
    }

    private func mergeAlerts(userId: UUID) async throws -> [PriceAlert] {
        let response = try await SupabaseManager.client
            .from("price_alerts")
            .select()
            .eq("user_id", value: userId.uuidString)
            .execute()
        let all: [RemotePriceAlert]
        do {
            all = try JSONDecoder.supabaseDecoder.decode([RemotePriceAlert].self, from: response.data)
        } catch {
            AppLogger.sync.error("mergeAlerts decode failed: \(error)")
            all = []
        }

        let remote     = all.filter { !$0.isDeleted }
        let remoteById = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
        let local      = persist.loadPriceAlerts()

        var merged: [PriceAlert] = remote.map { $0.toDomain() }
        let localOnly = local.filter { remoteById[$0.id.uuidString] == nil }
        merged.append(contentsOf: localOnly)
        if !localOnly.isEmpty { try await upsertAlerts(localOnly, userId: userId) }
        return merged
    }

    private func mergeSnapshots(userId: UUID) async throws -> [PortfolioSnapshot] {
        let response = try await SupabaseManager.client
            .from("portfolio_snapshots")
            .select()
            .eq("user_id", value: userId.uuidString)
            .order("snapshot_date", ascending: false)
            .limit(Constants.Sync.maxSnapshotSyncDays)
            .execute()
        let all: [RemotePortfolioSnapshot]
        do {
            all = try JSONDecoder.supabaseDecoder.decode([RemotePortfolioSnapshot].self, from: response.data)
        } catch {
            AppLogger.sync.error("mergeSnapshots decode failed: \(error)")
            all = []
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(identifier: "UTC")

        let remoteByDate = Dictionary(uniqueKeysWithValues: all.map { ($0.snapshotDate, $0) })
        let local        = persist.loadPortfolioHistory()

        var merged: [PortfolioSnapshot] = all.map { $0.toDomain() }
        let localOnly = local.filter { remoteByDate[df.string(from: $0.date)] == nil }
        merged.append(contentsOf: localOnly)
        if !localOnly.isEmpty { try await upsertSnapshots(localOnly, userId: userId) }

        merged.sort { $0.date < $1.date }
        return Array(merged.suffix(Constants.Sync.maxSnapshotSyncDays))
    }
}
