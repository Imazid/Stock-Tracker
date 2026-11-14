//
//  SnapTradeViewModel.swift
//  Stock Tracker
//
//  UI state for SnapTrade broker connections — one shared instance, so every
//  screen (Portfolio, Home, onboarding) agrees on what's connected.
//
//  Syncing merges: it only adds, updates or removes holdings this app imported
//  from the broker earlier (their ids are remembered). Manual holdings are
//  never touched. New and changed positions go into the portfolio on every
//  sync (linked holdings just appear, as in Coinbase / Origin / Copilot);
//  removals wait in `pendingRemovals` until the person confirms them.
//

import Foundation
import Auth
import SwiftUI
import Combine
import CryptoKit

@MainActor
final class SnapTradeViewModel: ObservableObject {

    static let shared: SnapTradeViewModel = {
        // SnapTrade's consumer key signs requests for every user of the client id, so it must
        // never ship in the app: release builds always use the snaptrade-proxy Edge Function.
        // Debug builds sign on the device only while no Supabase project is configured.
        let network: SnapTradeNetworkService
        #if DEBUG
        network = SecureBackend.shouldUseServer
            ? .serverBacked()
            : SnapTradeNetworkService(clientId: SecretsConfig.snapTradeClientId,
                                      consumerKey: SecretsConfig.snapTradeConsumerKey)
        #else
        network = .serverBacked()
        #endif
        return SnapTradeViewModel(repository: SnapTradeRepository(networkService: network))
    }()

    // MARK: - Published State

    @Published var isAuthenticated: Bool = false
    @Published var isLoading: Bool = false
    @Published var loadingMessage: String = ""

    @Published var accounts: [BrokerAccount] = []
    @Published var holdings: [BrokerHolding] = []
    @Published private(set) var lastSyncedAt: Date?
    /// The last sync failed (offline, broker needs re-linking); shown as "Couldn't sync".
    @Published private(set) var lastSyncFailed = false

    /// What the last automatic import changed ("3 added from CommSec…"), for a banner.
    @Published private(set) var lastImport: SyncSummary?
    /// Imported holdings the broker no longer reports — removed only once confirmed.
    @Published private(set) var pendingRemovals: [PortfolioHolding] = []

    @Published var errorMessage: String?
    @Published var showError: Bool = false

    /// SnapTrade's live list of institutions: the real `broker` slugs, names, logos and
    /// status. Empty until loaded (or if SnapTrade can't be reached) — the picker then
    /// falls back to its built-in list.
    @Published private(set) var directory: [InstitutionPickerSheet.Institution] = []

    /// Set at launch; imports need the portfolio. Holdings that arrived before it
    /// was set are imported as soon as it is.
    weak var marketData: MarketData? {
        didSet { if marketData != nil, !holdings.isEmpty { autoImport() } }
    }

    // Connection state
    @Published var connectionURL: URL?
    @Published var showConnectionView: Bool = false

    // MARK: - Dependencies

    private let repository: SnapTradeRepository
    private var accountGeneration = UUID()
    private static let importedKey = "snaptrade_imported_holding_ids"

    /// Ids of portfolio holdings that came from the broker.
    private var importedIDs: Set<UUID> {
        get {
            let raw = UserDefaults.standard.stringArray(forKey: Self.importedKey) ?? []
            return Set(raw.compactMap(UUID.init(uuidString:)))
        }
        set { UserDefaults.standard.set(newValue.map(\.uuidString), forKey: Self.importedKey) }
    }

    // MARK: - Initialization

    init(repository: SnapTradeRepository) {
        self.repository = repository
        self.isAuthenticated = repository.isAuthenticated
        #if DEBUG
        if Self.usesFixture { return }
        #endif
        if repository.isAuthenticated, !SecureBackend.shouldUseServer {
            Task {
                await syncAll()
                await loadDirectory()   // logos for the Accounts card
            }
        }
    }

    /// Registered with SnapTrade *and* at least one account linked.
    var hasLinkedAccounts: Bool { isAuthenticated && !accounts.isEmpty }

    /// "Synced just now" / "Synced 5 min. ago" — short enough for one line.
    static func syncedText(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return "Synced just now" }
        return "Synced \(date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))"
    }

    /// Connected institutions, in the order their accounts arrived.
    var institutions: [String] {
        var seen = Set<String>()
        return accounts.map(\.institutionName).filter { seen.insert($0).inserted }
    }

    func isImported(_ holding: PortfolioHolding) -> Bool {
        holding.brokerAccount?.tracking ?? importedIDs.contains(holding.id)
    }

    func institution(for holding: PortfolioHolding) -> String? {
        guard isImported(holding) else { return nil }
        if let account = holding.brokerAccount { return account.label }
        return institutionKey(for: holding).map { displayName(forInstitution: $0) }
    }

    func institutionKey(for holding: PortfolioHolding) -> String? {
        guard isImported(holding) else { return nil }
        if let account = holding.brokerAccount {
            return accounts.first { $0.id.lowercased() == account.account_id }?.institutionName ?? account.institution
        }
        let symbol = holding.asset.symbol
        let ids = Set(holdings.filter { normalisedSymbol($0.symbol) == symbol }.map(\.accountId))
        guard ids.count == 1, let id = ids.first else { return nil }
        return accounts.first { $0.id == id }?.institutionName
    }

    func trackedHolding(for position: BrokerHolding, in portfolio: [PortfolioHolding]) -> PortfolioHolding? {
        let symbol = normalisedSymbol(position.symbol)
        return portfolio.first {
            $0.brokerAccount?.tracking == true && $0.brokerAccount?.account_id == position.accountId.lowercased()
                && $0.asset.symbol == symbol && $0.asset.exchange == positionExchange(position)
        }
    }

    // MARK: - Directory

    /// The directory entry for an account's institution. Accounts carry a name that can be a
    /// bare slug (the sandbox reports "sandbox"), so match the slug first, then the name.
    private func directoryEntry(for institutionName: String) -> InstitutionPickerSheet.Institution? {
        directory.first { $0.slug.caseInsensitiveCompare(institutionName) == .orderedSame }
            ?? directory.first { $0.name.caseInsensitiveCompare(institutionName) == .orderedSame }
            ?? directory.first { institutionName.localizedCaseInsensitiveContains($0.name)
                                 || $0.name.localizedCaseInsensitiveContains(institutionName) }
    }

    /// SnapTrade's logo for a connected institution.
    func logoURL(for institutionName: String) -> URL? { directoryEntry(for: institutionName)?.logoURL }

    /// SnapTrade's display name for it ("sandbox" → "SnapTrade Sandbox").
    func displayName(forInstitution institutionName: String) -> String {
        directoryEntry(for: institutionName)?.name ?? institutionName
    }

    /// Crypto by the broker's security type or a known coin symbol.
    func isCrypto(_ position: BrokerHolding) -> Bool {
        let type = position.securityType?.uppercased() ?? ""
        return type.contains("CRYPTO") || type.contains("DIGITAL") || Self.knownCrypto.contains(normalisedSymbol(position.symbol))
    }

    /// Loads SnapTrade's institution list once per launch. Hard-coded slugs drifted from
    /// SnapTrade's ("IBKR" → "Requested broker IBKR does not exist"), so connecting uses these.
    func loadDirectory() async {
        guard directory.isEmpty else { return }
        #if DEBUG
        if Self.usesFixture { return }
        #endif
        guard let list = try? await repository.fetchBrokerages() else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-SnapTradeBrokerageProbe") {
            for b in list {
                print("BROKERAGE \(b.slug ?? "-")|\(b.displayName ?? b.name ?? "-")|enabled=\(b.enabled ?? false)|maintenance=\(b.maintenanceMode ?? false)|\(b.brokerageType?.name ?? "-")")
            }
        }
        #endif
        directory = list.compactMap { b in
            guard let slug = b.slug, !slug.isEmpty, b.enabled != false else { return nil }
            let name = b.displayName ?? b.name ?? slug
            let isExchange = (b.brokerageType?.name ?? "").localizedCaseInsensitiveContains("crypto")
            return InstitutionPickerSheet.Institution(
                name: name, slug: slug,
                region: InstitutionPickerSheet.knownRegion(for: name) ?? "",
                isExchange: isExchange,
                logoURL: b.squareLogoURL.flatMap(URL.init(string:)) ?? b.logoURL.flatMap(URL.init(string:)),
                inMaintenance: b.maintenanceMode == true)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Authentication

    /// Starts linking a broker: registers with SnapTrade if needed, then opens the portal.
    func connectBroker(broker: String = "ALPACA") async {
        #if DEBUG
        if Self.usesFixture { fixtureSync(); return }
        #endif
        isLoading = true
        loadingMessage = "Opening secure connection…"
        errorMessage = nil
        do {
            if !repository.isAuthenticated {
                _ = try await repository.authenticateUser()
                isAuthenticated = true
            }
            let url = try await repository.getBrokerConnectionURL(broker: broker)
            connectionURL = url
            showConnectionView = true
            isLoading = false
            loadingMessage = ""
        } catch {
            handleError(error)
        }
    }

    /// Title for the error alert ("Couldn't connect" / "Couldn't disconnect").
    @Published private(set) var errorTitle = "Couldn't connect"

    /// Removes the connection at SnapTrade — so nothing can read the broker any more — then
    /// forgets it here. Holdings already in the portfolio stay (as manual). If SnapTrade
    /// can't be reached the connection is kept and the person is told, not left believing
    /// it's gone (it used to only forget the login on this iPhone).
    func disconnect() async {
        #if DEBUG
        if Self.usesFixture { repository.disconnect(); clearConnection(keepPositions: true); return }
        #endif
        isLoading = true
        loadingMessage = "Disconnecting…"
        do {
            try await repository.deleteUserAndDisconnect()
        } catch {
            isLoading = false
            loadingMessage = ""
            errorTitle = "Couldn't disconnect"
            errorMessage = "SnapTrade didn't respond, so your broker is still connected. Try again in a moment."
            showError = true
            SecureLogger.error("SnapTrade deleteUser failed")
            return
        }
        isLoading = false
        loadingMessage = ""
        clearConnection(keepPositions: true)
    }

    func accountChanged() {
        accountGeneration = UUID()
        clearConnection(keepPositions: false)
    }

    private func clearConnection(keepPositions: Bool) {
        if keepPositions, let marketData {
            for holding in marketData.portfolio where isImported(holding) {
                stopTracking(holding, marketData: marketData)
            }
            importedIDs = []
        }
        isAuthenticated = false
        accounts = []
        holdings = []
        lastSyncedAt = nil
        lastSyncFailed = false
        lastImport = nil
        pendingRemovals = []
        isLoading = false
        loadingMessage = ""
    }

    // MARK: - Accounts & holdings

    func syncAll() async {
        #if DEBUG
        if Self.usesFixture { if isAuthenticated { fixtureSync() }; return }
        #endif
        guard !isLoading else { return }
        let owner = SupabaseManager.auth.currentUser?.id
        let generation = accountGeneration
        let requestedAt = Date()
        if SecureBackend.shouldUseServer {
            guard let owner, SyncManager.shared.hasLoadedPortfolio(for: owner) else { return }
        }
        isLoading = true
        loadingMessage = "Loading brokerage positions…"
        errorMessage = nil
        defer {
            if generation == accountGeneration {
                isLoading = false
                loadingMessage = ""
            }
        }
        do {
            let registered = try await repository.refreshRegistration()
            guard generation == accountGeneration, SupabaseManager.auth.currentUser?.id == owner else { return }
            isAuthenticated = registered
            guard registered else {
                accounts = []
                holdings = []
                pendingRemovals = []
                return
            }
            let linked = try await repository.fetchAccounts()
            guard generation == accountGeneration, SupabaseManager.auth.currentUser?.id == owner else { return }
            accounts = linked
            let readable = linked.filter(\.canReadPositions).map(\.id)
            let readableIDs = Set(readable.map { $0.lowercased() })
            let hasUnreadablePositions = marketData?.portfolio.contains { holding in
                guard let account = holding.brokerAccount else { return false }
                return account.tracking && holding.shares > 0 && !readableIDs.contains(account.account_id)
            } ?? false
            guard !hasUnreadablePositions else { throw SnapTradeError.missingData }
            let fetched = try await repository.fetchAllHoldings(accountIds: readable)
            guard generation == accountGeneration, SupabaseManager.auth.currentUser?.id == owner else { return }
            holdings = fetched
            lastSyncedAt = requestedAt
            lastSyncFailed = false
            autoImport()
        } catch {
            guard generation == accountGeneration, SupabaseManager.auth.currentUser?.id == owner else { return }
            lastSyncFailed = true
            pendingRemovals = []
            errorTitle = "Couldn’t sync brokerage positions"
            errorMessage = "Try again when all linked accounts are available. The last synced positions are still shown."
            showError = true
        }
    }

    /// Puts new and changed broker positions into the portfolio; holds removals for review.
    func autoImport() {
        guard let marketData, lastSyncedAt != nil, !lastSyncFailed else { return }
        var plan = makeSyncPlan(marketData: marketData)
        let priorRemovals = Dictionary(uniqueKeysWithValues: pendingRemovals.map { ($0.id, $0) })
        pendingRemovals = plan.removals.map { priorRemovals[$0.id] ?? $0 }
        plan.removals = []
        guard !plan.adds.isEmpty || !plan.updates.isEmpty || !plan.zeroed.isEmpty || !plan.skipped.isEmpty || !plan.review.isEmpty || lastImport != nil else { return }
        let summary = apply(plan, marketData: marketData)
        // Only worth a banner when something changed or needs saying.
        if summary.added + summary.updated + summary.overLimit > 0 || summary.skipped != lastImport?.skipped || summary.review != lastImport?.review {
            lastImport = summary
        }
    }

    /// Removes the imported holdings the broker no longer reports.
    func confirmPendingRemovals() {
        guard let marketData, !pendingRemovals.isEmpty else { return }
        var plan = SyncPlan()
        let ids = Set(pendingRemovals.map(\.id))
        plan.removals = marketData.portfolio.filter { ids.contains($0.id) }
        apply(plan, marketData: marketData)
        pendingRemovals = []
    }

    /// Keeps them as holdings the person tracks themselves (syncs stop touching them).
    func keepPendingRemovals() {
        guard let marketData else { return }
        let reviewed = pendingRemovals.map { old in
            var holding = marketData.portfolio.first { $0.id == old.id } ?? old
            holding.shares = old.shares
            return holding
        }
        for holding in reviewed { stopTracking(holding, marketData: marketData) }
        pendingRemovals = []
    }

    // MARK: - Portfolio merge

    struct SyncPlan {
        var adds: [PortfolioHolding] = []
        var updates: [PortfolioHolding] = []
        var changedCount = 0
        var removals: [PortfolioHolding] = []
        var zeroed: [PortfolioHolding] = []
        var skipped: [String] = []
        var review: [String] = []
    }

    struct SyncSummary: Equatable {
        var added = 0, updated = 0, removed = 0, overLimit = 0
        var skipped: [String] = []
        var review: [String] = []

        var message: String {
            var parts: [String] = []
            if added > 0 { parts.append("\(added) added") }
            if updated > 0 { parts.append("\(updated) updated") }
            if removed > 0 { parts.append("\(removed) removed") }
            if parts.isEmpty { parts.append("Already up to date") }
            var text = parts.joined(separator: ", ") + "."
            if overLimit > 0 { text += " \(overLimit) exceeded your plan’s holding limit." }
            if !skipped.isEmpty { text += " Already tracked manually: \(skipped.joined(separator: ", "))." }
            if !review.isEmpty {
                text += " Review older broker holdings for \(review.joined(separator: ", ")). Remove the combined holding after checking its history, then sync again."
            }
            return text
        }
    }

    private static let knownCrypto: Set<String> = ["BTC", "ETH", "SOL", "ADA", "BNB", "XRP", "DOGE", "DOT", "MATIC", "POL",
                                                   "LINK", "AVAX", "UNI", "LTC", "ATOM"]

    private func positionExchange(_ position: BrokerHolding) -> String {
        if isCrypto(position) { return "Crypto" }
        let exchange = position.exchange?.uppercased() ?? ""
        if ["ASX", "XASX"].contains(exchange) || position.symbol.uppercased().hasSuffix(".AX") { return "ASX" }
        switch exchange {
        case "XNYS", "NYSE": return "NYSE"
        case "XNAS", "NASDAQ": return "NASDAQ"
        case "": return "US"
        default: return exchange
        }
    }

    private func linkedHoldingID(owner: UUID?, account: String, asset: Asset) -> UUID {
        let fields = [owner?.uuidString ?? "", account, asset.kind.rawValue, asset.exchange, asset.symbol]
        var bytes = Array(SHA256.hash(data: Data(fields.joined(separator: "\u{0}").utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                          bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    func makeSyncPlan(marketData: MarketData) -> SyncPlan {
        var plan = SyncPlan()
        let current = marketData.portfolio
        let known = Set(accounts.filter(\.canReadPositions).map { $0.id.lowercased() })
        let eligible = holdings.filter {
            $0.quantity.isFinite && $0.quantity > 0 && known.contains($0.accountId.lowercased())
        }
        let bySymbol = Dictionary(grouping: eligible) { normalisedSymbol($0.symbol) }
        let groups = Dictionary(grouping: eligible) {
            [$0.accountId.lowercased(), normalisedSymbol($0.symbol), positionExchange($0)]
        }
        let stamp = lastSyncedAt ?? Date()
        let observed = stamp.ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        let owner = SupabaseManager.auth.currentUser?.id
        var seen = Set<UUID>()
        for (key, positions) in groups.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) {
            guard let first = positions.first, let account = accounts.first(where: { $0.id.lowercased() == key[0] }) else { continue }
            let symbol = key[1]
            let kind: AssetKind = isCrypto(first) ? .crypto : .stock
            let related = current.filter {
                $0.asset.symbol == symbol && $0.asset.kind == kind &&
                    ($0.asset.exchange == key[2] || ($0.brokerAccount == nil && $0.asset.exchange == "US"))
            }
            let linked = related.first { $0.brokerAccount?.account_id == key[0] && $0.asset.exchange == key[2] }
            let legacy = related.filter { holding in
                holding.brokerAccount == nil && (importedIDs.contains(holding.id) ||
                    (!holding.transactions.isEmpty && holding.transactions.allSatisfy { $0.provenance?.source == .brokerPosition }))
            }
            let listingCount = Set((bySymbol[symbol] ?? []).map { [$0.accountId.lowercased(), positionExchange($0)] }).count
            if linked == nil, !legacy.isEmpty, (legacy.count != 1 || listingCount != 1 || !legacy.allSatisfy({
                !$0.transactions.isEmpty && $0.transactions.allSatisfy { $0.provenance?.source == .brokerPosition } &&
                    abs($0.shares - positions.reduce(0) { $0 + $1.quantity }) <= 1e-9
            })) {
                plan.review.append(symbol)
                continue
            }
            if linked == nil, legacy.isEmpty, related.contains(where: { $0.brokerAccount == nil }) {
                plan.skipped.append(symbol)
                continue
            }
            if let linked, linked.brokerAccount?.tracking == false { continue }
            let existing = linked ?? legacy.first
            let quantity = positions.reduce(0) { $0 + $1.quantity }
            guard quantity.isFinite, quantity > 0 else { continue }
            let costUSD = positions.reduce(0.0) { total, position in
                guard let average = position.averageCost, average.isFinite, average >= 0,
                      let factor = FXRates.shared.toUSDFactor(from: position.currency) else { return total }
                return total + average * position.quantity * factor
            } / quantity
            let hasCost = positions.allSatisfy {
                guard let average = $0.averageCost, average.isFinite, average >= 0 else { return false }
                return FXRates.shared.toUSDFactor(from: $0.currency) != nil
            }
            let safeCost = hasCost && costUSD.isFinite ? costUSD : 0
            let price = (first.currentPrice ?? 0) * (FXRates.shared.toUSDFactor(from: first.currency) ?? 0)
            let asset = Asset(symbol: symbol, name: first.displayName, price: price.isFinite ? price : 0,
                              change: 0, changePercent: 0, volume: 0, kind: kind, exchange: key[2])
            let institution = String((account.institutionName.isEmpty ? "Brokerage account" : account.institutionName).prefix(80))
            let suffix = account.accountNumber.isEmpty ? String(account.id.suffix(4)) : String(account.accountNumber.suffix(4))
            let label = String("\(displayName(forInstitution: institution)) · ••••\(suffix)".prefix(100))
            let accountRecord = HoldingBrokerAccount(account_id: key[0], label: label, institution: institution,
                                                     observed_at: observed, tracking: true)
            if var holding = existing {
                seen.insert(holding.id)
                if holding.brokerAccount?.account_id != accountRecord.account_id || holding.brokerAccount?.label != label ||
                    abs(holding.shares - quantity) > 1e-9 || abs(holding.avgCost - safeCost) > 0.005 {
                    plan.changedCount += 1
                }
                holding.brokerAccount = accountRecord
                if holding.asset.exchange != asset.exchange { holding.asset = asset }
                holding.shares = quantity
                holding.avgCost = safeCost
                plan.updates.append(holding)
            } else {
                let id = linkedHoldingID(owner: owner, account: key[0], asset: asset)
                let snapshotID = linkedHoldingID(owner: id, account: key[0], asset: asset)
                let snapshot = Transaction(id: snapshotID, date: stamp, shares: quantity, pricePerShare: safeCost, type: .buy,
                    provenance: marketData.tradeProvenance(source: .brokerPosition, currency: nil, unitPrice: nil, fees: nil, factor: 1))
                plan.adds.append(PortfolioHolding(id: id, asset: asset, shares: quantity, avgCost: safeCost,
                                                  dateAdded: stamp, transactions: [snapshot], brokerAccount: accountRecord))
            }
        }
        plan.removals = current.filter { holding in
            guard let account = holding.brokerAccount else { return false }
            return account.tracking && known.contains(account.account_id) && !seen.contains(holding.id)
        }
        plan.changedCount += plan.removals.filter { $0.shares > 0 }.count
        plan.zeroed = plan.removals.map { holding in
            var zero = holding
            zero.shares = 0
            zero.brokerAccount?.observed_at = observed
            return zero
        }
        plan.skipped = Array(Set(plan.skipped)).sorted()
        plan.review = Array(Set(plan.review)).sorted()
        plan.adds.sort { $0.currentValue > $1.currentValue }
        return plan
    }

    @discardableResult
    func apply(_ plan: SyncPlan, marketData: MarketData) -> SyncSummary {
        var summary = SyncSummary(skipped: plan.skipped, review: plan.review)
        var accepted: [PortfolioHolding] = []
        for holding in plan.adds {
            if SubscriptionManager.shared.canAddPortfolioHolding(currentCount: marketData.portfolio.count + accepted.count) {
                accepted.append(holding)
            } else {
                summary.overLimit += 1
            }
        }
        let changed = plan.updates + plan.zeroed + accepted
        if !changed.isEmpty && marketData.saveBrokerHoldings(changed) {
            importedIDs.subtract(plan.updates.map(\.id))
            summary.updated = plan.changedCount
            summary.added = accepted.count
        }
        for holding in plan.removals {
            if marketData.removeFromPortfolio(holding) { summary.removed += 1 }
        }
        return summary
    }

    private func stopTracking(_ holding: PortfolioHolding, marketData: MarketData) {
        if var account = holding.brokerAccount {
            var manual = holding
            account.tracking = false
            account.observed_at = Date().ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            manual.brokerAccount = account
            if marketData.saveBrokerHoldings([manual]) { importedIDs.remove(holding.id) }
        } else {
            importedIDs.remove(holding.id)
        }
    }

    private func normalisedSymbol(_ raw: String) -> String {
        var s = raw.uppercased()
        if s.hasSuffix(".AX") { s.removeLast(3) }
        return s
    }

    // MARK: - Error Handling

    private func handleError(_ error: Error) {
        isLoading = false
        loadingMessage = ""
        errorTitle = "Couldn't connect"
        if let snapTradeError = error as? SnapTradeError {
            // People see this: say what happened and what to do, with SnapTrade's reason last.
            if case .apiError(_, let message) = snapTradeError {
                errorMessage = "SnapTrade couldn't start this connection. Try again in a moment, or pick another broker.\n\n\(message)"
            } else {
                errorMessage = snapTradeError.errorDescription
            }
        } else {
            errorMessage = error.localizedDescription
        }
        showError = true
        SecureLogger.error("SnapTrade error: \(errorMessage ?? "Unknown")")
    }

    // MARK: - Computed

    var totalAccountsValue: Double {
        accounts.compactMap { $0.balance?.total?.amount }.reduce(0, +)
    }

    var totalHoldingsValue: Double {
        holdings.reduce(0) { $0 + $1.marketValue }
    }

    // MARK: - UI-test fixture

    #if DEBUG
    /// `-UITestBrokerFixture`: "connecting" links two sample accounts (CommSec, Coinbase)
    /// with three positions and no network, so tests can drive the whole flow.
    /// `-UITestBrokerFixtureDrop BHP` leaves that position out of later syncs (removal review).
    static let usesFixture = ProcessInfo.processInfo.arguments.contains("-UITestBrokerFixture")
    private var fixtureSyncCount = 0

    private func fixtureSync() {
        fixtureSyncCount += 1
        isAuthenticated = true
        var positions = [
            BrokerHolding(id: "fx-cba", accountId: "a8cc1385-31a7-4c4d-9955-6789589cc956", symbol: "CBA.AX", description: "Commonwealth Bank of Australia",
                          quantity: 20, currentPrice: 170.00, averageCost: 104.50, currency: "AUD", exchange: "ASX", securityType: "cs"),
            BrokerHolding(id: "fx-bhp", accountId: "a8cc1385-31a7-4c4d-9955-6789589cc956", symbol: "BHP.AX", description: "BHP Group",
                          quantity: 50, currentPrice: 60.00, averageCost: 38.10, currency: "AUD", exchange: "ASX", securityType: "cs"),
            BrokerHolding(id: "fx-btc", accountId: "3ef9b308-6463-4307-b2a2-88d4af9ac560", symbol: "BTC", description: "Bitcoin",
                          quantity: 0.05, currentPrice: 80_400, averageCost: 61_000, currency: "USD", exchange: nil, securityType: "crypto")
        ]
        if fixtureSyncCount > 1, let drop = UserDefaults.standard.string(forKey: "UITestBrokerFixtureDrop") {
            positions.removeAll { $0.symbol.hasPrefix(drop) }
        }
        let secondAccount = "0cc77f5f-2b5f-481a-95cb-e44b9c0ad97f"
        let multiAccount = ProcessInfo.processInfo.arguments.contains("-UITestBrokerMultiAccount")
        if multiAccount {
            let moved = fixtureSyncCount > 1
            if moved { positions.removeAll { $0.id == "fx-bhp" } }
            positions.append(BrokerHolding(id: "fx-bhp-second", accountId: secondAccount, symbol: "BHP.AX",
                description: "BHP Group", quantity: moved ? 70 : 20, currentPrice: 60,
                averageCost: 42, currency: "AUD", exchange: "ASX", securityType: "cs"))
        }
        func value(_ account: String) -> Double {
            positions.filter { $0.accountId == account }.reduce(0) { $0 + $1.marketValue }
        }
        accounts = [
            BrokerAccount(id: "a8cc1385-31a7-4c4d-9955-6789589cc956", name: "Individual", accountNumber: "40123456", institutionName: "CommSec",
                          accountType: "Individual",
                          balance: AccountBalance(total: Money(amount: value("a8cc1385-31a7-4c4d-9955-6789589cc956") + 1_250, currency: "AUD"),
                                                  cash: Money(amount: 1_250, currency: "AUD")),
                          createdDate: nil),
            BrokerAccount(id: "3ef9b308-6463-4307-b2a2-88d4af9ac560", name: "Coinbase", accountNumber: "77001234", institutionName: "Coinbase",
                          accountType: "Crypto",
                          balance: AccountBalance(total: Money(amount: value("3ef9b308-6463-4307-b2a2-88d4af9ac560"), currency: "USD"), cash: nil),
                          createdDate: nil)
        ]
        if multiAccount {
            accounts.append(BrokerAccount(id: secondAccount, name: "Second account", accountNumber: "12344321",
                institutionName: "CommSec", accountType: "Individual", balance: nil, createdDate: nil))
        }
        holdings = positions
        lastSyncedAt = Date()
        lastSyncFailed = false
        autoImport()
    }
    #endif
}
