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
import SwiftUI
import Combine

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
        if repository.isAuthenticated {
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

    func isImported(_ holding: PortfolioHolding) -> Bool { importedIDs.contains(holding.id) }

    /// The broker an imported holding came from, as displayed (nil for holdings added by hand).
    func institution(for holding: PortfolioHolding) -> String? {
        institutionKey(for: holding).map { displayName(forInstitution: $0) }
    }

    /// The account's raw institution name (what `institutions` lists), for matching.
    func institutionKey(for holding: PortfolioHolding) -> String? {
        guard isImported(holding) else { return nil }
        let symbol = holding.asset.symbol
        guard let accountID = holdings.first(where: { normalisedSymbol($0.symbol) == symbol })?.accountId else { return nil }
        return accounts.first { $0.id == accountID }?.institutionName
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
        if Self.usesFixture { repository.disconnect(); clearConnection(); return }
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
        clearConnection()
    }

    private func clearConnection() {
        isAuthenticated = false
        accounts = []
        holdings = []
        lastSyncedAt = nil
        lastSyncFailed = false
        lastImport = nil
        pendingRemovals = []
        importedIDs = []
    }

    // MARK: - Accounts & holdings

    func fetchAccounts() async {
        isLoading = true
        loadingMessage = "Loading accounts…"
        errorMessage = nil
        do {
            accounts = try await repository.fetchAccounts()
            isLoading = false
            loadingMessage = ""
        } catch {
            lastSyncFailed = true
            handleError(error)
        }
    }

    func fetchAllHoldings() async {
        isLoading = true
        loadingMessage = "Loading holdings…"
        errorMessage = nil
        do {
            var fetched = try await repository.fetchAllHoldings()
            loadingMessage = "Updating prices…"
            fetched = await repository.enrichHoldings(fetched)
            holdings = fetched
            lastSyncedAt = Date()
            lastSyncFailed = false
            isLoading = false
            loadingMessage = ""
            autoImport()
        } catch {
            lastSyncFailed = true
            handleError(error)
        }
    }

    func fetchHoldings(for accountId: String) async {
        isLoading = true
        loadingMessage = "Loading account holdings…"
        errorMessage = nil
        do {
            let fetched = try await repository.fetchHoldings(for: accountId)
            holdings.removeAll { $0.accountId == accountId }
            holdings.append(contentsOf: fetched)
            isLoading = false
            loadingMessage = ""
        } catch {
            handleError(error)
        }
    }

    /// Accounts, then holdings (which then go into the portfolio).
    func syncAll() async {
        #if DEBUG
        if Self.usesFixture { if isAuthenticated { fixtureSync() }; return }
        #endif
        errorMessage = nil
        await fetchAccounts()
        if !accounts.isEmpty {
            await fetchAllHoldings()
        }
    }

    /// Puts new and changed broker positions into the portfolio; holds removals for review.
    func autoImport() {
        guard let marketData else { return }
        var plan = makeSyncPlan(marketData: marketData)
        pendingRemovals = plan.removals
        plan.removals = []
        guard !plan.adds.isEmpty || !plan.updates.isEmpty || !plan.skipped.isEmpty else { return }
        let summary = apply(plan, marketData: marketData)
        // Only worth a banner when something changed or needs saying.
        if summary.added + summary.updated + summary.overLimit > 0 || summary.skipped != lastImport?.skipped {
            lastImport = summary
        }
    }

    /// Removes the imported holdings the broker no longer reports.
    func confirmPendingRemovals() {
        guard let marketData, !pendingRemovals.isEmpty else { return }
        var plan = SyncPlan()
        plan.removals = pendingRemovals
        apply(plan, marketData: marketData)
        pendingRemovals = []
    }

    /// Keeps them as holdings the person tracks themselves (syncs stop touching them).
    func keepPendingRemovals() {
        importedIDs.subtract(pendingRemovals.map(\.id))
        pendingRemovals = []
    }

    // MARK: - Portfolio merge

    struct SyncPlan {
        struct Add { let asset: Asset; let quantity: Double; let costPerUnit: Double; let currency: String }
        struct Update { let holdingID: UUID; let symbol: String; let quantity: Double; let avgCostUSD: Double }

        var adds: [Add] = []
        var updates: [Update] = []
        var removals: [PortfolioHolding] = []
        /// Broker symbols already tracked manually — left alone.
        var skipped: [String] = []

        var isEmpty: Bool { adds.isEmpty && updates.isEmpty && removals.isEmpty }
    }

    struct SyncSummary: Equatable {
        var added = 0, updated = 0, removed = 0, overLimit = 0
        var skipped: [String] = []

        var message: String {
            var parts: [String] = []
            if added > 0 { parts.append("\(added) added") }
            if updated > 0 { parts.append("\(updated) updated") }
            if removed > 0 { parts.append("\(removed) removed") }
            if parts.isEmpty { parts.append("Already up to date") }
            var text = parts.joined(separator: ", ")
            if overLimit > 0 { text += ". \(overLimit) not added — your plan's holding limit was reached" }
            if !skipped.isEmpty { text += ". Already tracked manually: \(skipped.joined(separator: ", "))" }
            return text + "."
        }
    }

    private static let knownCrypto: Set<String> = ["BTC", "ETH", "SOL", "ADA", "BNB", "XRP", "DOGE", "DOT", "MATIC", "POL",
                                                   "LINK", "AVAX", "UNI", "LTC", "ATOM"]

    /// What a sync would change, without changing anything.
    func makeSyncPlan(marketData: MarketData) -> SyncPlan {
        var plan = SyncPlan()
        let imported = importedIDs
        let groups = Dictionary(grouping: holdings, by: { normalisedSymbol($0.symbol) })
        var seenImported = Set<UUID>()

        for (symbol, lots) in groups {
            let quantity = lots.reduce(0) { $0 + $1.quantity }
            guard quantity > 0, let first = lots.first else { continue }
            let currency = first.currency.isEmpty ? "USD" : first.currency.uppercased()
            let costTotal = lots.reduce(0.0) { $0 + ($1.averageCost ?? $1.currentPrice ?? 0) * $1.quantity }
            let costPerUnit = costTotal / quantity
            let secType = first.securityType?.uppercased() ?? ""
            let isCrypto = secType.contains("CRYPTO") || secType.contains("DIGITAL") || Self.knownCrypto.contains(symbol)
            let exchange = isCrypto ? "Crypto"
                : ((first.exchange ?? "").uppercased().contains("ASX") || first.symbol.uppercased().hasSuffix(".AX") ? "ASX" : "US")
            let kind: AssetKind = isCrypto ? .crypto : .stock

            if let existing = marketData.portfolio.first(where: { $0.asset.symbol == symbol && $0.asset.kind == kind }) {
                if imported.contains(existing.id) {
                    seenImported.insert(existing.id)
                    let usd = costPerUnit * (FXRates.shared.toUSDFactor(from: currency) ?? 1)
                    if abs(existing.shares - quantity) > 1e-9 || abs(existing.avgCost - usd) > 0.005 {
                        plan.updates.append(.init(holdingID: existing.id, symbol: symbol, quantity: quantity, avgCostUSD: usd))
                    }
                } else {
                    plan.skipped.append(symbol)
                }
                continue
            }

            let priceUSD = (first.currentPrice ?? 0) * (FXRates.shared.toUSDFactor(from: currency) ?? 1)
            let asset = Asset(symbol: symbol, name: first.displayName, price: priceUSD, change: 0, changePercent: 0,
                              volume: 0, kind: kind, exchange: exchange)
            plan.adds.append(.init(asset: asset, quantity: quantity, costPerUnit: costPerUnit, currency: currency))
        }

        plan.removals = marketData.portfolio.filter { imported.contains($0.id) && !seenImported.contains($0.id) }
        plan.skipped.sort()
        // Biggest first: when the plan's holding limit cuts the import short, it keeps the
        // positions that matter most (it used to keep whichever came first).
        plan.adds.sort { $0.quantity * $0.asset.price > $1.quantity * $1.asset.price }
        return plan
    }

    /// Applies a plan made by `makeSyncPlan`.
    @discardableResult
    func apply(_ plan: SyncPlan, marketData: MarketData) -> SyncSummary {
        var summary = SyncSummary(skipped: plan.skipped)
        var ids = importedIDs

        for update in plan.updates {
            guard let holding = marketData.portfolio.first(where: { $0.id == update.holdingID }) else { continue }
            let firstDate = holding.transactions.map(\.date).min() ?? Date()
            let tx = Transaction(date: firstDate, shares: update.quantity, pricePerShare: update.avgCostUSD, type: .buy)
            if marketData.replaceTransactions(holdingID: holding.id, with: [tx]) == .ok { summary.updated += 1 }
        }

        for add in plan.adds {
            switch marketData.addHolding(asset: add.asset, shares: add.quantity, costPerUnit: add.costPerUnit,
                                         costCurrency: add.currency) {
            case .ok:
                if let id = marketData.portfolio.first(where: { $0.asset.symbol == add.asset.symbol && $0.asset.kind == add.asset.kind })?.id {
                    ids.insert(id)
                }
                summary.added += 1
            case .limitReached:
                summary.overLimit += 1
            case .invalid:
                break
            }
        }

        for holding in plan.removals {
            marketData.removeFromPortfolio(holding)
            ids.remove(holding.id)
            summary.removed += 1
        }

        importedIDs = ids
        return summary
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
            BrokerHolding(id: "fx-cba", accountId: "fx-commsec", symbol: "CBA.AX", description: "Commonwealth Bank of Australia",
                          quantity: 20, currentPrice: 170.00, averageCost: 104.50, currency: "AUD", exchange: "ASX", securityType: "cs"),
            BrokerHolding(id: "fx-bhp", accountId: "fx-commsec", symbol: "BHP.AX", description: "BHP Group",
                          quantity: 50, currentPrice: 60.00, averageCost: 38.10, currency: "AUD", exchange: "ASX", securityType: "cs"),
            BrokerHolding(id: "fx-btc", accountId: "fx-coinbase", symbol: "BTC", description: "Bitcoin",
                          quantity: 0.05, currentPrice: 80_400, averageCost: 61_000, currency: "USD", exchange: nil, securityType: "crypto")
        ]
        if fixtureSyncCount > 1, let drop = UserDefaults.standard.string(forKey: "UITestBrokerFixtureDrop") {
            positions.removeAll { $0.symbol.hasPrefix(drop) }
        }
        func value(_ account: String) -> Double {
            positions.filter { $0.accountId == account }.reduce(0) { $0 + $1.marketValue }
        }
        accounts = [
            BrokerAccount(id: "fx-commsec", name: "Individual", accountNumber: "40123456", institutionName: "CommSec",
                          accountType: "Individual",
                          balance: AccountBalance(total: Money(amount: value("fx-commsec") + 1_250, currency: "AUD"),
                                                  cash: Money(amount: 1_250, currency: "AUD")),
                          createdDate: nil),
            BrokerAccount(id: "fx-coinbase", name: "Coinbase", accountNumber: "77001234", institutionName: "Coinbase",
                          accountType: "Crypto",
                          balance: AccountBalance(total: Money(amount: value("fx-coinbase"), currency: "USD"), cash: nil),
                          createdDate: nil)
        ]
        holdings = positions
        lastSyncedAt = Date()
        lastSyncFailed = false
        autoImport()
    }
    #endif
}
