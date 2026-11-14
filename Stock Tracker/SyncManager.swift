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
    @Published private(set) var holdingConflicts: [PortfolioLedgerChange] = []

    private let persist = DataPersistenceManager.shared
    private var debounceTask: Task<Void, Never>?
    private var isRunning = false
    private var savedHoldingRevisions: [UUID: UUID] = [:]
    private weak var marketData: MarketData?

    /// Tracks whether the initial full sync has been performed this session.
    /// Prevents `syncOnSignIn` from re-running on every session restore.
    private var syncedUserId: UUID?

    var isSignedIn: Bool { SupabaseManager.auth.currentUser != nil }

    func hasLoadedPortfolio(for userId: UUID) -> Bool { syncedUserId == userId }

    private init() {}

    /// Resets the initial-sync flag so the next sign-in triggers a full merge.
    func resetInitialSyncFlag() {
        syncedUserId = nil
        holdingConflicts = []
        savedHoldingRevisions = [:]
        debounceTask?.cancel()
        debounceTask = nil
    }

    // MARK: - First-sign-in merge (full sync)

    func syncOnSignIn(marketData: MarketData, alertManager: PriceAlertManager) async {
        guard SupabaseManager.isConfigured else { return }
        guard let userId = SupabaseManager.auth.currentUser?.id else { return }
        do {
            while isRunning { try await Task.sleep(for: .milliseconds(250)) }
        } catch { return }
        guard SupabaseManager.auth.currentUser?.id == userId else { return }
        self.marketData = marketData
        marketData.usePortfolioAccount(userId)
        marketData.useWatchlistAccount(userId)
        alertManager.useAccount(userId)

        // If we already synced this session (e.g. session restore on relaunch),
        // use the lighter incremental pull instead of a full merge.
        if syncedUserId == userId {
            await pullAndRefresh(marketData: marketData, alertManager: alertManager)
            return
        }
        isRunning = true
        defer { isRunning = false }
        syncState = .syncing
        AppLogger.sync.info("Starting first-sign-in sync for user \(userId)")

        do {
            try await exchangePortfolios(userId: userId, marketData: marketData)
            let mergedAlerts = try await mergeAlerts(userId: userId, local: alertManager.alerts)
            guard SupabaseManager.auth.currentUser?.id == userId else { return }
            alertManager.applyRemoteAlerts(mergedAlerts)

            let now = Date()
            persist.rememberPortfolioAccount(userId)
            persist.saveLastSyncDate(now)
            syncedUserId = userId
            try await WatchlistSync.shared.exchange(owner: userId, marketData: marketData)
            guard SupabaseManager.auth.currentUser?.id == userId else { return }
            reportSync(at: now)
            AppLogger.sync.info("First-sign-in sync complete")

        } catch is CancellationError {
            return
        } catch {
            guard SupabaseManager.auth.currentUser?.id == userId else { return }
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

        let account = portfolios.cached(owner: userId)
        if !force, !account.needsUpload,
           !WatchlistSync.shared.hasPending(owner: userId),
           !hasPendingHoldings(userId),
           let lastSync = persist.loadLastSyncDate(),
           Date().timeIntervalSince(lastSync) < Constants.Sync.foregroundPullThrottle {
            AppLogger.sync.debug("Foreground pull skipped — within throttle window")
            return
        }

        syncState = .syncing
        isRunning = true
        defer { isRunning = false }

        do {
            try await exchangePortfolios(userId: userId, marketData: marketData)
            let since = persist.loadLastSyncDate() ?? .distantPast
            let sinceStr = ISO8601DateFormatter().string(from: since)
            let response = try await SupabaseManager.client
                .from("price_alerts")
                .select()
                .eq("user_id", value: userId.uuidString)
                .gte("updated_at", value: sinceStr)
                .execute()
            let delta = try JSONDecoder.supabaseDecoder.decode([RemotePriceAlert].self, from: response.data)
            guard SupabaseManager.auth.currentUser?.id == userId else { return }
            var localAlerts = alertManager.alerts
            for row in delta {
                let id = row.id.lowercased()
                if row.isDeleted {
                    localAlerts.removeAll { $0.id.uuidString.lowercased() == id }
                } else if !localAlerts.contains(where: { $0.id.uuidString.lowercased() == id }) {
                    localAlerts.append(row.toDomain())
                }
            }
            alertManager.applyRemoteAlerts(localAlerts)

            let now = Date()
            persist.saveLastSyncDate(now)
            try await WatchlistSync.shared.exchange(owner: userId, marketData: marketData)
            guard SupabaseManager.auth.currentUser?.id == userId else { return }
            reportSync(at: now)
            AppLogger.sync.info("Incremental pull complete")

        } catch is CancellationError {
            return
        } catch {
            guard SupabaseManager.auth.currentUser?.id == userId else { return }
            syncState = .error(error.localizedDescription)
            AppLogger.sync.error("Incremental pull failed: \(error)")
        }
    }

    // MARK: - Debounced background sync (after mutations)

    func scheduleBackgroundSync() async {
        scheduleUpload()
    }

    func scheduleUpload() {
        guard SupabaseManager.isConfigured, let owner = SupabaseManager.auth.currentUser?.id else { return }
        debounceTask?.cancel()
        debounceTask = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(Constants.Sync.backgroundSyncDebounce * 1_000_000_000))
                while isRunning { try await Task.sleep(for: .milliseconds(250)) }
                // A new debounce can cancel the waiting task. Let a started write
                // finish and let the next task pick up any newer local changes.
                guard SupabaseManager.auth.currentUser?.id == owner else { return }
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
            if let marketData, marketData.portfolioOwner == userId,
               portfolios.cached(owner: userId).needsUpload || hasPendingHoldings(userId) {
                try await exchangePortfolios(userId: userId, marketData: marketData)
            }
            if let marketData, marketData.watchlistOwner == userId, WatchlistSync.shared.hasPending(owner: userId) {
                try await WatchlistSync.shared.exchange(owner: userId, marketData: marketData)
            }
            guard SupabaseManager.auth.currentUser?.id == userId else { return }
            if let alerts = marketData?.alertManager, alerts.owner == userId {
                try await upsertAlerts(alerts.alerts, userId: userId)
            }
            guard SupabaseManager.auth.currentUser?.id == userId else { return }
            let now = Date()
            reportSync(at: now)
            AppLogger.sync.info("Background upload complete")
        } catch is CancellationError {
            return
        } catch {
            guard SupabaseManager.auth.currentUser?.id == userId else { return }
            syncState = .error(error.localizedDescription)
            AppLogger.sync.error("Background upload failed: \(error)")
        }
    }

    /// Save mutations before their network request so a relaunch can retry the same trade IDs.
    func queuePortfolioChange(_ holding: PortfolioHolding, groupID: UUID, owner: UUID?,
                              changed: Set<UUID> = [], deleted: [Transaction] = [],
                              archived: Bool = false, closedAt: Date? = nil) -> Bool {
        queuePortfolioChanges([PortfolioLedgerChange(revision: UUID(), holding: holding, changed: changed, deleted: deleted,
                                                     archivedAt: archived ? Date() : nil, closedAt: closedAt, groupID: groupID)], owner: owner)
    }

    private func hasPendingHoldings(_ owner: UUID) -> Bool {
        (persist.loadPortfolioLedgerQueue()[owner.uuidString] ?? []).contains { $0.conflicted != true }
    }

    private func reportSync(at date: Date) {
        syncState = holdingConflicts.isEmpty ? .lastSyncedAt(date)
            : .error("Review the unsynced holding changes in Portfolio.")
    }

    func discardHoldingConflict(_ change: PortfolioLedgerChange, owner: UUID?) {
        guard let owner, marketData?.portfolioOwner == owner, SupabaseManager.auth.currentUser?.id == owner else { return }
        let key = owner.uuidString
        var queue = persist.loadPortfolioLedgerQueue()
        queue[key]?.removeAll { $0.holding.id == change.holding.id && $0.conflicted == true }
        guard persist.savePortfolioLedgerQueue(queue) else { return }
        refreshHoldingConflicts(owner)
        reportSync(at: persist.loadLastSyncDate() ?? Date())
        scheduleUpload()
    }

    private func refreshHoldingConflicts(_ owner: UUID) {
        guard marketData?.portfolioOwner == owner else { return }
        let saved = (persist.loadPortfolioLedgerQueue()[owner.uuidString] ?? []).filter { $0.conflicted == true }
        let followed = Set(saved.compactMap(\.follows))
        holdingConflicts = saved.filter { !followed.contains($0.revision) }.map { last in
            let chain = saved.filter { $0.holding.id == last.holding.id }
            guard chain.count > 1 else { return last }
            let allChanged = chain.reduce(into: Set<UUID>()) { $0.formUnion($1.changed) }
            let allDeleted = Dictionary(chain.flatMap(\.deleted).map { ($0.id, $0) },
                                        uniquingKeysWith: { _, latest in latest })
            return PortfolioLedgerChange(revision: last.revision, holding: last.holding,
                                         changed: allChanged, deleted: Array(allDeleted.values),
                                         archivedAt: last.archivedAt, closedAt: last.closedAt, groupID: last.groupID)
        }
    }

    func queuePortfolioChanges(_ pending: [PortfolioLedgerChange], owner: UUID?) -> Bool {
        guard !pending.isEmpty, let userId = owner else { return true }
        var queue = persist.loadPortfolioLedgerQueue()
        var changes = queue[userId.uuidString, default: []]
        for change in pending {
            let prior = changes.last { $0.holding.id == change.holding.id && $0.conflicted != true }
            let coalesce = prior?.submitted != true ? prior : nil
            let kept = Set(change.holding.transactions.map(\.id))
            let removed = ((coalesce?.deleted ?? []) + change.deleted).filter { !kept.contains($0.id) }
            if let coalesce { changes.removeAll { $0.revision == coalesce.revision } }
            var queued = PortfolioLedgerChange(revision: change.revision, holding: change.holding,
                                               changed: (coalesce?.changed ?? []).union(change.changed),
                                               deleted: Array(Dictionary(removed.map { ($0.id, $0) },
                                                                         uniquingKeysWith: { _, latest in latest }).values),
                                               archivedAt: change.archivedAt, closedAt: change.closedAt,
                                               groupID: change.groupID ?? prior?.groupID)
            queued.follows = prior?.submitted == true ? prior?.revision : coalesce?.follows
            queued.holding.ledgerRevision = prior == nil
                ? (savedHoldingRevisions[change.holding.id] ?? change.holding.ledgerRevision) : prior?.holding.ledgerRevision
            changes.append(queued)
        }
        queue[userId.uuidString] = changes
        guard persist.savePortfolioLedgerQueue(queue) else {
            syncState = .error("Couldn’t save the portfolio change on this device.")
            return false
        }
        scheduleUpload()
        return true
    }

    private struct LedgerResult: Decodable {
        let status: String
        let revision: UUID?
        let merged: Bool?
    }

    private func flushPortfolioChanges(_ pending: [PortfolioLedgerChange], userId: UUID) async throws {
        let key = userId.uuidString
        try requirePortfolioOwner(userId)
        let linked = pending.filter {
            $0.holding.brokerAccount?.tracking == true && $0.changed.isEmpty && $0.deleted.isEmpty
                && $0.archivedAt == nil && $0.follows == nil
        }
        if !linked.isEmpty {
            nonisolated struct Batch: Encodable, Sendable { let p_changes: [PortfolioLedgerChange.Parameters] }
            try await SupabaseManager.client.rpc("sync_broker_portfolio_ledger",
                params: Batch(p_changes: linked.map { $0.parameters(userId: userId) })).execute()
            clearChanges(Set(linked.map(\.revision)), for: key)
        }
        let linkedIDs = Set(linked.map(\.revision))
        for item in pending where !linkedIDs.contains(item.revision) {
            try requirePortfolioOwner(userId)
            var queue = persist.loadPortfolioLedgerQueue()
            guard let idx = queue[key]?.firstIndex(where: { $0.revision == item.revision }),
                  var change = queue[key]?[idx], change.conflicted != true, change.follows == nil else { continue }
            change.groupID = item.groupID
            change.submitted = true
            queue[key]?[idx] = change
            guard persist.savePortfolioLedgerQueue(queue) else { throw CocoaError(.fileWriteUnknown) }

            let result: LedgerResult = try await SupabaseManager.client.rpc("apply_portfolio_ledger_change",
                params: PortfolioLedgerChange.GuardedParameters(change: change.parameters(userId: userId),
                    p_mutation_id: change.revision, p_expected_revision: change.holding.ledgerRevision)).execute().value
            try requirePortfolioOwner(userId)
            queue = persist.loadPortfolioLedgerQueue()
            if result.status == "applied", let revision = result.revision {
                if result.merged == true {
                    savedHoldingRevisions[change.holding.id] = nil
                } else {
                    savedHoldingRevisions[change.holding.id] = revision
                }
                queue[key]?.removeAll { $0.revision == change.revision }
                if let next = queue[key]?.firstIndex(where: { $0.follows == change.revision }) {
                    queue[key]?[next].follows = nil
                    if result.merged != true { queue[key]?[next].holding.ledgerRevision = revision }
                }
            } else if result.status == "conflict" {
                var conflictedIDs: Set<UUID> = [change.revision]
                for i in (queue[key]?.indices ?? 0..<0) {
                    guard let queued = queue[key]?[i],
                          conflictedIDs.contains(queued.revision) || queued.follows.map(conflictedIDs.contains) == true else { continue }
                    conflictedIDs.insert(queued.revision)
                    queue[key]?[i].conflicted = true
                }
            } else {
                throw CocoaError(.coderInvalidValue)
            }
            guard persist.savePortfolioLedgerQueue(queue) else { throw CocoaError(.fileWriteUnknown) }
        }
        refreshHoldingConflicts(userId)
    }

    private func clearChanges(_ revisions: Set<UUID>, for key: String) {
        var queue = persist.loadPortfolioLedgerQueue()
        queue[key]?.removeAll { revisions.contains($0.revision) }
        if queue[key]?.isEmpty == true { queue.removeValue(forKey: key) }
        persist.savePortfolioLedgerQueue(queue)
    }

    // MARK: - Soft delete

    func softDeleteAlert(id: UUID, owner: UUID) async {
        guard SupabaseManager.isConfigured, SupabaseManager.auth.currentUser?.id == owner else { return }
        do {
            let nowStr = ISO8601DateFormatter().string(from: Date())
            try await SupabaseManager.client
                .from("price_alerts")
                .update(["deleted_at": nowStr])
                .eq("id", value: id.uuidString)
                .eq("user_id", value: owner.uuidString)
                .execute()
        } catch {
            AppLogger.sync.error("Soft-delete alert failed: \(error)")
        }
    }

    // MARK: - Upsert helpers

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

    // MARK: - Merge helpers (first sign-in)

    private let portfolios = PortfolioAccountStore.shared

    private struct RemoteGroup: Decodable {
        let id: UUID
        let name: String
        let emoji: String
        let deleted_at: String?

        var domain: PortfolioGroup { PortfolioGroup(id: id, name: name, emoji: emoji) }
    }

    private func requirePortfolioOwner(_ owner: UUID) throws {
        guard SupabaseManager.auth.currentUser?.id == owner, marketData?.portfolioOwner == owner else {
            throw CancellationError()
        }
    }

    private func exchangePortfolios(userId: UUID, marketData: MarketData) async throws {
        try requirePortfolioOwner(userId)
        refreshHoldingConflicts(userId)
        let account = portfolios.cached(owner: userId)
        let pending = (persist.loadPortfolioLedgerQueue()[userId.uuidString] ?? []).filter { $0.conflicted != true }
        // Publish metadata before a holding references it.
        for change in account.pendingGroups where change.action != .delete {
            try requirePortfolioOwner(userId)
            try await SupabaseManager.client.rpc("apply_portfolio_group_change", params: change.parameters(owner: userId)).execute()
        }
        let groupForHolding = Dictionary(account.groups.flatMap { group in
            (group.holdings.map(\.id) + group.closedPositions.map(\.id)).map { ($0, group.id) }
        },
                                         uniquingKeysWith: { first, _ in first })
        try await flushPortfolioChanges(pending.map { item in
            var change = item
            change.groupID = change.groupID ?? groupForHolding[change.holding.id] ?? PortfolioGroup.defaultID
            return change
        }, userId: userId)

        if account.needsImport {
            let existing: [RemoteHolding] = try await portfolioRows("portfolio_holdings", userId: userId)
            let retainedEdits = Set(holdingConflicts.map { $0.holding.id })
            try await importPortfolioLedger(account.groups, existing: existing, excluding: retainedEdits, userId: userId)
        }

        var deletionFailure: PostgrestError?
        for change in account.pendingGroups where change.action == .delete {
            try requirePortfolioOwner(userId)
            if holdingConflicts.contains(where: { $0.groupID == change.groupID }) { continue }
            do {
                try await SupabaseManager.client.rpc("apply_portfolio_group_change", params: change.parameters(owner: userId)).execute()
            } catch let error as PostgrestError where error.code == "22023" {
                // The broker may have started tracking a position on another device.
                // Restore the rejected portfolio from the server and report the error.
                deletionFailure = error
            }
        }

        let metadata: [RemoteGroup] = try await portfolioRows("portfolio_groups", userId: userId)
        let remoteLedger = try await readLedger(userId)
        let byGroup = Dictionary(grouping: remoteLedger) { $0.holding.groupID ?? PortfolioGroup.defaultID }
        let defaultGroup = metadata.first { $0.id == PortfolioGroup.defaultID && $0.deleted_at == nil }?.domain
            ?? PortfolioGroup(id: PortfolioGroup.defaultID, name: "Main Portfolio")
        var groups = [defaultGroup] + metadata.filter { $0.id != PortfolioGroup.defaultID && $0.deleted_at == nil }
            .map(\.domain).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for index in groups.indices {
            let id = groups[index].id
            let remote = byGroup[id] ?? []
            groups[index].holdings = remote.filter { !$0.holding.isDeleted }.map(\.openHolding)
            groups[index].closedPositions = remote.compactMap(\.closedPosition)
            let local = account.groups.first { $0.id == id }?.history ?? []
            let hasConflict = holdingConflicts.contains { $0.groupID == id }
            let queued = hasConflict ? [:] : account.pendingValuations[id.uuidString] ?? [:]
            let localHistory = hasConflict ? local.filter { account.pendingValuations[id.uuidString]?[$0.utcDay] == nil } : local
            groups[index].history = try await syncHistory(groupID: id, userId: userId, local: localHistory,
                                                          importing: account.needsImport, queued: queued)
        }

        try requirePortfolioOwner(userId)
        let blockedGroups = Set(holdingConflicts.compactMap(\.groupID))
        let completed = Set(account.pendingGroups.filter { $0.action != .delete || !blockedGroups.contains($0.groupID) }.map(\.id))
        let ledger = (persist.loadPortfolioLedgerQueue()[userId.uuidString] ?? []).filter { $0.conflicted != true }
        let withQuotes = marketData.portfolioGroupsWithQuotes(groups)
        guard portfolios.update(owner: userId, { stored in
            stored.pendingGroups.removeAll { completed.contains($0.id) }
            for (group, days) in account.pendingValuations {
                for (day, value) in days where stored.pendingValuations[group]?[day]?.date == value.date {
                    stored.pendingValuations[group]?.removeValue(forKey: day)
                }
                if stored.pendingValuations[group]?.isEmpty == true {
                    stored.pendingValuations.removeValue(forKey: group)
                }
            }
            stored.needsImport = false
            var next = withQuotes
            for change in stored.pendingGroups where change.action != .delete || !blockedGroups.contains(change.groupID) { change.apply(to: &next) }
            for i in next.indices {
                let group = next[i].id
                let edits = ledger.reversed().filter {
                    ($0.groupID ?? groupForHolding[$0.holding.id] ?? PortfolioGroup.defaultID) == group
                }.reduce(into: [UUID: PortfolioLedgerChange]()) { result, change in
                    if result[change.holding.id] == nil { result[change.holding.id] = change }
                }.values
                if !blockedGroups.contains(group), let queued = stored.pendingValuations[group.uuidString] {
                    next[i].history = snapshotsByDay(next[i].history + Array(queued.values)).values.sorted { $0.date < $1.date }
                }
                let ids = Set(edits.map { $0.holding.id })
                next[i].holdings.removeAll { ids.contains($0.id) }
                next[i].holdings += edits.filter { $0.archivedAt == nil }.map(\.holding)
                next[i].closedPositions.removeAll { stored.hiddenClosed.contains($0.id) || ids.contains($0.id) }
                next[i].closedPositions += edits.compactMap { edit in
                    guard let closed = edit.closedAt, !stored.hiddenClosed.contains(edit.holding.id) else { return nil }
                    let holding = edit.holding
                    return ClosedPosition(id: holding.id, asset: holding.asset, transactions: holding.transactions,
                                          openedAt: holding.dateAdded, closedAt: closed)
                }
                next[i].closedPositions.sort { $0.closedAt > $1.closedAt }
            }
            stored.groups = next
            if !next.contains(where: { $0.id == stored.selected }) { stored.selected = PortfolioGroup.defaultID }
        }) else { throw CocoaError(.fileWriteUnknown) }
        marketData.showPortfolios(portfolios.cached(owner: userId))
        savedHoldingRevisions = [:]
        if let deletionFailure { throw deletionFailure }
    }

    private struct LedgerRow: Decodable {
        let holding: RemoteHolding
        let transactions: [RemoteTransaction]

        var openHolding: PortfolioHolding { holding.toDomain(transactions: transactions.map { $0.toDomain() }) }
        var closedPosition: ClosedPosition? { holding.toClosedPosition(transactions: transactions.map { $0.toDomain() }) }
    }

    private func readLedger(_ owner: UUID) async throws -> [LedgerRow] {
        nonisolated struct Page: Encodable, Sendable {
            let p_user_id: UUID
            let p_after: UUID?

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(p_user_id, forKey: .p_user_id)
                try container.encode(p_after, forKey: .p_after)
            }

            private enum CodingKeys: String, CodingKey { case p_user_id, p_after }
        }
        var rows: [LedgerRow] = []
        var after: UUID?
        while true {
            try requirePortfolioOwner(owner)
            let page: [LedgerRow] = try await SupabaseManager.client.rpc("read_portfolio_ledger_page",
                params: Page(p_user_id: owner, p_after: after)).execute().value
            rows += page
            guard page.count == 100, let last = page.last, let id = UUID(uuidString: last.holding.id) else { return rows }
            after = id
        }
    }

    private func importPortfolioLedger(_ groups: [PortfolioGroup], existing: [RemoteHolding], excluding: Set<UUID>, userId: UUID) async throws {
        let byID = Dictionary(uniqueKeysWithValues: existing.compactMap { row in UUID(uuidString: row.id).map { ($0, row) } })
        let byGroup = Dictionary(grouping: existing.filter { !$0.isDeleted }) { $0.groupID ?? PortfolioGroup.defaultID }
        for group in groups {
            let signatures = Set((byGroup[group.id] ?? []).map { row in
                [row.assetSymbol, row.assetKind, row.assetExchange ?? "", row.brokerAccount?.account_id ?? ""]
            })
            let rows = group.holdings.filter { holding in
                !excluding.contains(holding.id) && byID[holding.id] == nil && !signatures.contains([holding.asset.symbol, holding.asset.kind.rawValue,
                                                                holding.asset.exchange, holding.brokerAccount?.account_id ?? ""])
            }
            for holding in rows {
                try requirePortfolioOwner(userId)
                let change = PortfolioLedgerChange(revision: UUID(), holding: holding, changed: [], deleted: [],
                                                   archivedAt: nil, closedAt: nil, groupID: group.id)
                try await SupabaseManager.client.rpc("sync_portfolio_ledger", params: change.parameters(userId: userId)).execute()
            }
            for position in group.closedPositions where !excluding.contains(position.id) && position.transactions.contains(where: { $0.type == .sell }) {
                let row = byID[position.id]
                guard row == nil || ((row?.groupID ?? PortfolioGroup.defaultID) == group.id &&
                                     row?.deletedAt != nil && row?.closedAt == nil) else { continue }
                try requirePortfolioOwner(userId)
                let holding = PortfolioHolding(id: position.id, asset: position.asset, shares: 0, avgCost: 0,
                                               dateAdded: position.openedAt, transactions: position.transactions)
                let change = PortfolioLedgerChange(revision: UUID(), holding: holding, changed: [], deleted: [],
                                                   archivedAt: position.closedAt, closedAt: position.closedAt, groupID: group.id)
                try await SupabaseManager.client.rpc("sync_portfolio_ledger",
                    params: change.parameters(userId: userId, existingArchive: row?.deletedAt)).execute()
            }
        }
    }

    private func portfolioRows<Row: Decodable>(_ table: String, userId: UUID) async throws -> [Row] {
        let pageSize = 500
        var rows: [Row] = []
        var lastId: String?
        while true {
            try requirePortfolioOwner(userId)
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

    private func mergeAlerts(userId: UUID, local: [PriceAlert]) async throws -> [PriceAlert] {
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
        let knownIDs = Set(all.map { $0.id.lowercased() })

        var merged: [PriceAlert] = remote.map { $0.toDomain() }
        let localOnly = local.filter { !knownIDs.contains($0.id.uuidString.lowercased()) }
        merged.append(contentsOf: localOnly)
        if !localOnly.isEmpty {
            try requirePortfolioOwner(userId)
            try await upsertAlerts(localOnly, userId: userId)
        }
        return merged
    }

    private struct HistoryRow: Decodable {
        let snapshot_date: String
        let total_value: Double
        let observed_at: String?

        func domain() -> PortfolioSnapshot? {
            let midnight = "\(snapshot_date)T00:00:00Z"
            guard let date = try? Date.ISO8601FormatStyle().parse(midnight) else { return nil }
            return PortfolioSnapshot(date: observed_at.flatMap {
                (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0))
                    ?? (try? Date.ISO8601FormatStyle().parse($0))
            } ?? date, totalValue: total_value)
        }
    }

    private func snapshotsByDay(_ snapshots: [PortfolioSnapshot]) -> [String: PortfolioSnapshot] {
        Dictionary(snapshots.map { ($0.utcDay, $0) }, uniquingKeysWith: { first, second in
            first.date > second.date ? first : second
        })
    }

    private func syncHistory(groupID: UUID, userId: UUID, local: [PortfolioSnapshot],
                             importing: Bool, queued: [String: PortfolioSnapshot]) async throws -> [PortfolioSnapshot] {
        let isDefault = groupID == PortfolioGroup.defaultID
        func cloudValues() async throws -> [String: PortfolioSnapshot] {
            try requirePortfolioOwner(userId)
            let query = SupabaseManager.client.from(isDefault ? "portfolio_snapshots" : "portfolio_group_snapshots")
                .select("snapshot_date,total_value,observed_at").eq("user_id", value: userId.uuidString)
            if !isDefault { _ = query.eq("portfolio_group_id", value: groupID.uuidString) }
            let result = try await query.order("snapshot_date", ascending: false)
                .limit(Constants.Sync.maxSnapshotSyncDays).execute()
            let rows = try JSONDecoder.supabaseDecoder.decode([HistoryRow].self, from: result.data)
            return Dictionary(uniqueKeysWithValues: rows.compactMap { row in row.domain().map { (row.snapshot_date, $0) } })
        }

        var remote = try await cloudValues()
        let localDays = snapshotsByDay(local)
        var uploads = queued
        if importing {
            for day in localDays.keys.sorted().suffix(Constants.Sync.maxSnapshotSyncDays) where remote[day] == nil && uploads[day] == nil {
                if let value = localDays[day], value.totalValue.isFinite, value.totalValue >= 0 {
                    uploads[day] = value
                }
            }
        }
        var uploaded = false
        for (day, snapshot) in uploads {
            if let known = remote[day], known.date >= snapshot.date { continue }
            try requirePortfolioOwner(userId)
            nonisolated struct Value: Encodable, Sendable {
                let p_user_id: UUID
                let p_group_id: UUID
                let p_snapshot_date: String
                let p_total_value: Double
                let p_observed_at: String
            }
            let row = Value(p_user_id: userId, p_group_id: groupID, p_snapshot_date: day,
                            p_total_value: snapshot.totalValue,
                            p_observed_at: snapshot.date.ISO8601Format(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .colon)))
            try await SupabaseManager.client.rpc("save_portfolio_group_value", params: row).execute()
            uploaded = true
        }
        if uploaded { remote = try await cloudValues() }
        let values = localDays.merging(remote) { _, serverValue in serverValue }
        return Array(values.values.sorted { $0.date < $1.date }.suffix(Constants.Refresh.maxPortfolioHistoryDays))
    }
}
