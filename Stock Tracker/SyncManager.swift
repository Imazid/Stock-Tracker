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
import Auth
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
    private var isRunning = false

    /// Tracks whether the initial full sync has been performed this session.
    /// Prevents `syncOnSignIn` from re-running on every session restore.
    private var syncedUserId: UUID?

    var isSignedIn: Bool { SupabaseManager.auth.currentUser != nil }

    func hasLoadedPortfolio(for userId: UUID) -> Bool { syncedUserId == userId }

    private init() {}

    /// Resets the initial-sync flag so the next sign-in triggers a full merge.
    func resetInitialSyncFlag() {
        syncedUserId = nil
        debounceTask?.cancel()
    }

    // MARK: - First-sign-in merge (full sync)

    func syncOnSignIn(marketData: MarketData, alertManager: PriceAlertManager) async {
        guard SupabaseManager.isConfigured else { return }
        guard let userId = SupabaseManager.auth.currentUser?.id else { return }
        do {
            while isRunning { try await Task.sleep(for: .milliseconds(250)) }
        } catch { return }
        guard SupabaseManager.auth.currentUser?.id == userId else { return }

        // If we already synced this session (e.g. session restore on relaunch),
        // use the lighter incremental pull instead of a full merge.
        if syncedUserId == userId {
            await pullAndRefresh(marketData: marketData, alertManager: alertManager)
            return
        }
        isRunning = true
        defer { isRunning = false }
        let previousOwner = persist.lastPortfolioAccount()
        let samePortfolioAccount = previousOwner == nil || previousOwner == userId

        syncState = .syncing
        AppLogger.sync.info("Starting first-sign-in sync for user \(userId)")

        do {
            try await flushPortfolioChanges(userId: userId)
            let mergedWatchlist = try await mergeWatchlist(userId: userId)

            let remotePortfolio = try await readPortfolio(userId: userId, includeLocal: samePortfolioAccount)
            let mergedAlerts    = try await mergeAlerts(userId: userId)
            let mergedHistory   = try await mergeSnapshots(userId: userId)

            guard SupabaseManager.auth.currentUser?.id == userId else { return }
            persist.saveWatchlist(mergedWatchlist)
            persist.savePriceAlerts(mergedAlerts)
            persist.savePortfolioHistory(mergedHistory)

            marketData.applyRemoteSync(
                watchlist: mergedWatchlist,
                portfolio: preservingPending(remotePortfolio, userId: userId),
                history: mergedHistory
            )
            marketData.applySyncedClosedPositions(remotePortfolio.closed, reset: !samePortfolioAccount)
            alertManager.applyRemoteAlerts(mergedAlerts)

            let now = Date()
            persist.rememberPortfolioAccount(userId)
            persist.saveLastSyncDate(now)
            syncedUserId = userId
            syncState = .lastSyncedAt(now)
            AppLogger.sync.info("First-sign-in sync complete")

        } catch {
            syncState = .error(error.localizedDescription)
            AppLogger.sync.error("First-sign-in sync failed: \(error)")
        }
    }

    // MARK: - Incremental pull (foreground refresh, throttled)

    func pullAndRefresh(marketData: MarketData, alertManager: PriceAlertManager, force: Bool = false) async {
        guard SupabaseManager.isConfigured else { return }
        guard let userId = SupabaseManager.auth.currentUser?.id else { return }
        if force {
            do {
                while isRunning { try await Task.sleep(for: .milliseconds(250)) }
            } catch { return }
            guard SupabaseManager.auth.currentUser?.id == userId else { return }
        } else if isRunning {
            return
        }
        if syncedUserId != userId {
            await syncOnSignIn(marketData: marketData, alertManager: alertManager)
            return
        }

        if !force, (persist.loadPortfolioLedgerQueue()[userId.uuidString]?.isEmpty ?? true),
           let lastSync = persist.loadLastSyncDate(),
           Date().timeIntervalSince(lastSync) < Constants.Sync.foregroundPullThrottle {
            AppLogger.sync.debug("Foreground pull skipped — within throttle window")
            return
        }

        syncState = .syncing
        isRunning = true
        defer { isRunning = false }

        do {
            try await flushPortfolioChanges(userId: userId)
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

            var localAlerts    = persist.loadPriceAlerts()
            let localHistory   = persist.loadPortfolioHistory()
            let remotePortfolio = try await readPortfolio(userId: userId, includeLocal: true, importLocal: false)

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
                let remoteIdLower = remote.id.lowercased()
                if remote.isDeleted {
                    localAlerts.removeAll { $0.id.uuidString.lowercased() == remoteIdLower }
                } else if !localAlerts.contains(where: { $0.id.uuidString.lowercased() == remoteIdLower }) {
                    localAlerts.append(remote.toDomain())
                }
            }

            guard SupabaseManager.auth.currentUser?.id == userId else { return }
            persist.savePriceAlerts(localAlerts)

            marketData.applyRemoteSync(
                watchlist: localWatchlist,
                portfolio: preservingPending(remotePortfolio, userId: userId),
                history: localHistory
            )
            marketData.applySyncedClosedPositions(remotePortfolio.closed)
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
        scheduleUpload()
    }

    private func scheduleUpload() {
        guard SupabaseManager.isConfigured, isSignedIn else { return }
        debounceTask?.cancel()
        debounceTask = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(Constants.Sync.backgroundSyncDebounce * 1_000_000_000))
                while isRunning { try await Task.sleep(for: .milliseconds(250)) }
                // A new debounce can cancel the waiting task. Let a started write
                // finish and let the next task pick up any newer local changes.
                debounceTask = nil
                await uploadCurrentState()
            } catch { /* Task cancelled — another mutation came in */ }
        }
    }

    private func uploadCurrentState() async {
        guard let userId = SupabaseManager.auth.currentUser?.id else { return }
        isRunning = true
        defer { isRunning = false }
        syncState = .syncing
        do {
            try await flushPortfolioChanges(userId: userId)
            try await upsertWatchlist(persist.loadWatchlist(), userId: userId)
            try await upsertAlerts(persist.loadPriceAlerts(), userId: userId)
            try await upsertSnapshots(persist.loadPortfolioHistory(), userId: userId)
            let now = Date()
            syncState = .lastSyncedAt(now)
            AppLogger.sync.info("Background upload complete")
        } catch {
            syncState = .error(error.localizedDescription)
            AppLogger.sync.error("Background upload failed: \(error)")
        }
    }

    /// Save mutations before their network request so a relaunch can retry the same trade IDs.
    func queuePortfolioChange(_ holding: PortfolioHolding, changed: Set<UUID> = [], deleted: [Transaction] = [],
                              archived: Bool = false, closedAt: Date? = nil) -> Bool {
        queuePortfolioChanges([PortfolioLedgerChange(revision: UUID(), holding: holding, changed: changed, deleted: deleted,
                                                     archivedAt: archived ? Date() : nil, closedAt: closedAt)])
    }

    func queuePortfolioChanges(_ pending: [PortfolioLedgerChange]) -> Bool {
        guard !pending.isEmpty, let userId = SupabaseManager.auth.currentUser?.id else { return true }
        var queue = persist.loadPortfolioLedgerQueue()
        var changes = queue[userId.uuidString, default: []]
        for change in pending {
            let prior = changes.last { $0.holding.id == change.holding.id }
            let kept = Set(change.holding.transactions.map(\.id))
            let removed = ((prior?.deleted ?? []) + change.deleted).filter { !kept.contains($0.id) }
            changes.removeAll { $0.holding.id == change.holding.id }
            changes.append(PortfolioLedgerChange(revision: change.revision, holding: change.holding,
                                                 changed: (prior?.changed ?? []).union(change.changed),
                                                 deleted: Array(Dictionary(removed.map { ($0.id, $0) },
                                                                           uniquingKeysWith: { _, latest in latest }).values),
                                                 archivedAt: change.archivedAt, closedAt: change.closedAt))
        }
        queue[userId.uuidString] = changes
        guard persist.savePortfolioLedgerQueue(queue) else {
            syncState = .error("Couldn’t save the portfolio change on this device.")
            return false
        }
        scheduleUpload()
        return true
    }

    private func flushPortfolioChanges(userId: UUID) async throws {
        let key = userId.uuidString
        let pending = persist.loadPortfolioLedgerQueue()[key] ?? []
        let linked = pending.filter { $0.holding.brokerAccount != nil }
        if !linked.isEmpty {
            nonisolated struct Batch: Encodable, Sendable { let p_changes: [PortfolioLedgerChange.Parameters] }
            try await SupabaseManager.client.rpc("sync_broker_portfolio_ledger",
                params: Batch(p_changes: linked.map { $0.parameters(userId: userId) })).execute()
            clearChanges(Set(linked.map(\.revision)), for: key)
        }
        for change in pending where change.holding.brokerAccount == nil {
            try await SupabaseManager.client.rpc("sync_portfolio_ledger", params: change.parameters(userId: userId)).execute()
            clearChanges([change.revision], for: key)
        }
    }

    private func clearChanges(_ revisions: Set<UUID>, for key: String) {
        var queue = persist.loadPortfolioLedgerQueue()
        queue[key]?.removeAll { revisions.contains($0.revision) }
        if queue[key]?.isEmpty == true { queue.removeValue(forKey: key) }
        persist.savePortfolioLedgerQueue(queue)
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

    func softDeleteWatchlistAsset(symbol: String) async {
        guard SupabaseManager.isConfigured, isSignedIn,
              let userId = SupabaseManager.auth.currentUser?.id else { return }
        do {
            let nowStr = ISO8601DateFormatter().string(from: Date())
            try await SupabaseManager.client
                .from("watchlist_assets")
                .update(["deleted_at": nowStr])
                .eq("user_id", value: userId.uuidString)
                .eq("symbol", value: symbol)
                .execute()
        } catch {
            AppLogger.sync.error("Soft-delete watchlist asset failed: \(error)")
        }
    }

    func softDeleteWatchlistAssets(symbols: [String]) async {
        for symbol in symbols {
            await softDeleteWatchlistAsset(symbol: symbol)
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

    private struct PortfolioRead {
        let open: [PortfolioHolding]
        let closed: [ClosedPosition]
    }

    private func readPortfolio(userId: UUID, includeLocal: Bool, importLocal: Bool = true) async throws -> PortfolioRead {
        let holdings: [RemoteHolding] = try await portfolioRows("portfolio_holdings", userId: userId)
        let transactions: [RemoteTransaction] = try await portfolioRows("transactions", userId: userId)
        let byHolding = Dictionary(grouping: transactions.filter { !$0.isDeleted }, by: \.holdingId)
        let holdingIds = Set(holdings.compactMap { UUID(uuidString: $0.id) })
        let open = holdings.filter { !$0.isDeleted }.map { row in
            row.toDomain(transactions: (byHolding[row.id] ?? []).map { $0.toDomain() })
        }
        var closed = holdings.compactMap { row in
            row.toClosedPosition(transactions: (byHolding[row.id] ?? []).map { $0.toDomain() })
        }
        let manualListings = Set(open.filter { $0.brokerAccount?.tracking != true }.map { [$0.asset.symbol, $0.asset.kind.rawValue, $0.asset.exchange] })
        let linkedAccounts = Set(open.compactMap { holding in
            holding.brokerAccount.map { [$0.account_id, holding.asset.symbol, holding.asset.kind.rawValue, holding.asset.exchange] }
        })
        let localOnly = includeLocal && importLocal ? persist.loadPortfolio().filter {
            guard !holdingIds.contains($0.id) else { return false }
            let listing = [$0.asset.symbol, $0.asset.kind.rawValue, $0.asset.exchange]
            if let account = $0.brokerAccount { return !linkedAccounts.contains([account.account_id] + listing) }
            return !manualListings.contains(listing)
        } : []
        for holding in localOnly {
            let change = PortfolioLedgerChange(revision: UUID(), holding: holding, changed: [], deleted: [],
                                               archivedAt: nil, closedAt: nil)
            try await SupabaseManager.client.rpc("sync_portfolio_ledger", params: change.parameters(userId: userId)).execute()
        }
        if includeLocal {
            let archived = Dictionary(uniqueKeysWithValues: holdings.compactMap { row -> (UUID, String)? in
                guard row.closedAt == nil, let deletedAt = row.deletedAt, let id = UUID(uuidString: row.id) else { return nil }
                return (id, deletedAt)
            })
            let groups = persist.loadPortfolioGroups().groups
            for position in groups.flatMap(\.closedPositions) {
                guard let archive = archived[position.id],
                      position.transactions.contains(where: { $0.type == .sell }) else { continue }
                let holding = PortfolioHolding(id: position.id, asset: position.asset, shares: 0, avgCost: 0,
                                               dateAdded: position.openedAt, transactions: position.transactions)
                let change = PortfolioLedgerChange(revision: UUID(), holding: holding, changed: [], deleted: [],
                                                   archivedAt: nil, closedAt: position.closedAt)
                try await SupabaseManager.client.rpc("sync_portfolio_ledger",
                                                     params: change.parameters(userId: userId, existingArchive: archive)).execute()
                closed.append(position)
            }
        }
        return PortfolioRead(open: open + localOnly, closed: closed)
    }

    private func portfolioRows<Row: Decodable>(_ table: String, userId: UUID) async throws -> [Row] {
        let pageSize = 500
        var rows: [Row] = []
        var lastId: String?
        while true {
            let query = SupabaseManager.client.from(table).select().eq("user_id", value: userId.uuidString)
            if let lastId { _ = query.gt("id", value: lastId) }
            let response = try await query.order("id").limit(pageSize).execute()
            let page = try JSONDecoder.supabaseDecoder.decode([Row].self, from: response.data)
            rows.append(contentsOf: page)
            if page.count < pageSize { return rows }
            let ids = try JSONDecoder.supabaseDecoder.decode([RowID].self, from: response.data)
            lastId = ids.last?.id
        }
    }

    private struct RowID: Decodable { let id: String }

    private func preservingPending(_ remote: PortfolioRead, userId: UUID) -> [PortfolioHolding] {
        let pending = persist.loadPortfolioLedgerQueue()[userId.uuidString] ?? []
        let ids = Set(pending.map { $0.holding.id })
        return remote.open.filter { !ids.contains($0.id) } + pending.filter { $0.archivedAt == nil }.map(\.holding)
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
        let remoteById = Dictionary(uniqueKeysWithValues: remote.map { ($0.id.lowercased(), $0) })
        let local      = persist.loadPriceAlerts()

        var merged: [PriceAlert] = remote.map { $0.toDomain() }
        let localOnly = local.filter { remoteById[$0.id.uuidString.lowercased()] == nil }
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
