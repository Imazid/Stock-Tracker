//
//  OnboardingModel.swift
//  Stock Tracker
//
//  State, catalog and hand-off for the redesigned onboarding.
//
//  Flow (value before commitment — the account ask comes last):
//    welcome → markets → follow → portfolio → alerts → security* → account* → done
//    * security only when Face ID / Touch ID is available
//    * account only when not already signed in
//

import SwiftUI
import Combine
import LocalAuthentication
import UserNotifications
import OSLog

// MARK: - Steps

enum OnboardingStep: Int, CaseIterable, Comparable {
    case welcome, markets, follow, portfolio, alerts, security, account, done

    static func < (lhs: OnboardingStep, rhs: OnboardingStep) -> Bool { lhs.rawValue < rhs.rawValue }
}

// MARK: - Market choice

enum MarketChoice: String, CaseIterable, Identifiable, Codable {
    case asx, us, crypto
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .asx:    return "Australian shares"
        case .us:     return "US shares"
        case .crypto: return "Crypto"
        }
    }

    var subtitle: LocalizedStringKey {
        switch self {
        case .asx:    return "ASX-listed companies and ETFs"
        case .us:     return "NYSE and Nasdaq, including ETFs"
        case .crypto: return "Bitcoin, Ethereum and more"
        }
    }

    var badge: String {
        switch self {
        case .asx:    return "🇦🇺"
        case .us:     return "🇺🇸"
        case .crypto: return "₿"
        }
    }
}

// MARK: - Picked asset

/// A ticker chosen during onboarding, before we have a live quote for it.
struct PickedAsset: Codable, Hashable, Identifiable {
    let symbol: String      // display symbol, e.g. "BHP", "AAPL", "BTC"
    let name: String
    let kind: AssetKind
    let exchange: String    // "ASX", "US", or "" for crypto
    /// CoinGecko id for crypto ("bitcoin"); unused for stocks.
    var coinID: String = ""

    var id: String { "\(kind.rawValue):\(exchange):\(symbol)" }

    /// The identifier `APIService.fetchAssetDetails` expects.
    var lookupIdentifier: String {
        switch kind {
        case .crypto: return coinID.isEmpty ? symbol.lowercased() : coinID
        case .stock:  return exchange == "ASX" ? "\(symbol).AX" : symbol
        }
    }

    var marketLabel: String {
        switch kind {
        case .crypto: return "Crypto"
        case .stock:  return exchange == "ASX" ? "ASX" : "US"
        }
    }
}

// MARK: - Catalog

/// Curated, offline list so the picker is instant. Search covers everything else.
enum OnboardingCatalog {
    static let asx: [PickedAsset] = [
        .init(symbol: "BHP", name: "BHP Group", kind: .stock, exchange: "ASX"),
        .init(symbol: "CBA", name: "Commonwealth Bank", kind: .stock, exchange: "ASX"),
        .init(symbol: "CSL", name: "CSL Limited", kind: .stock, exchange: "ASX"),
        .init(symbol: "NAB", name: "National Australia Bank", kind: .stock, exchange: "ASX"),
        .init(symbol: "WBC", name: "Westpac", kind: .stock, exchange: "ASX"),
        .init(symbol: "ANZ", name: "ANZ Group", kind: .stock, exchange: "ASX"),
        .init(symbol: "MQG", name: "Macquarie Group", kind: .stock, exchange: "ASX"),
        .init(symbol: "WES", name: "Wesfarmers", kind: .stock, exchange: "ASX"),
        .init(symbol: "FMG", name: "Fortescue", kind: .stock, exchange: "ASX"),
        .init(symbol: "RIO", name: "Rio Tinto", kind: .stock, exchange: "ASX"),
        .init(symbol: "WDS", name: "Woodside Energy", kind: .stock, exchange: "ASX"),
        .init(symbol: "TLS", name: "Telstra", kind: .stock, exchange: "ASX"),
        .init(symbol: "XRO", name: "Xero", kind: .stock, exchange: "ASX"),
        .init(symbol: "WOW", name: "Woolworths", kind: .stock, exchange: "ASX")
    ]

    static let us: [PickedAsset] = [
        .init(symbol: "AAPL", name: "Apple", kind: .stock, exchange: "US"),
        .init(symbol: "NVDA", name: "NVIDIA", kind: .stock, exchange: "US"),
        .init(symbol: "MSFT", name: "Microsoft", kind: .stock, exchange: "US"),
        .init(symbol: "AMZN", name: "Amazon", kind: .stock, exchange: "US"),
        .init(symbol: "GOOGL", name: "Alphabet", kind: .stock, exchange: "US"),
        .init(symbol: "META", name: "Meta Platforms", kind: .stock, exchange: "US"),
        .init(symbol: "TSLA", name: "Tesla", kind: .stock, exchange: "US"),
        .init(symbol: "AVGO", name: "Broadcom", kind: .stock, exchange: "US"),
        .init(symbol: "JPM", name: "JPMorgan Chase", kind: .stock, exchange: "US"),
        .init(symbol: "V", name: "Visa", kind: .stock, exchange: "US"),
        .init(symbol: "NFLX", name: "Netflix", kind: .stock, exchange: "US"),
        .init(symbol: "AMD", name: "AMD", kind: .stock, exchange: "US")
    ]

    static let etfs: [PickedAsset] = [
        .init(symbol: "VAS", name: "Vanguard Australian Shares", kind: .stock, exchange: "ASX"),
        .init(symbol: "VGS", name: "Vanguard MSCI Intl Shares", kind: .stock, exchange: "ASX"),
        .init(symbol: "IVV", name: "iShares S&P 500 (ASX)", kind: .stock, exchange: "ASX"),
        .init(symbol: "NDQ", name: "Betashares Nasdaq 100", kind: .stock, exchange: "ASX"),
        .init(symbol: "A200", name: "Betashares Australia 200", kind: .stock, exchange: "ASX"),
        .init(symbol: "VOO", name: "Vanguard S&P 500", kind: .stock, exchange: "US"),
        .init(symbol: "QQQ", name: "Invesco QQQ", kind: .stock, exchange: "US"),
        .init(symbol: "VTI", name: "Vanguard Total Stock Market", kind: .stock, exchange: "US")
    ]

    static let crypto: [PickedAsset] = [
        .init(symbol: "BTC", name: "Bitcoin", kind: .crypto, exchange: "", coinID: "bitcoin"),
        .init(symbol: "ETH", name: "Ethereum", kind: .crypto, exchange: "", coinID: "ethereum"),
        .init(symbol: "SOL", name: "Solana", kind: .crypto, exchange: "", coinID: "solana"),
        .init(symbol: "XRP", name: "XRP", kind: .crypto, exchange: "", coinID: "ripple"),
        .init(symbol: "ADA", name: "Cardano", kind: .crypto, exchange: "", coinID: "cardano"),
        .init(symbol: "DOGE", name: "Dogecoin", kind: .crypto, exchange: "", coinID: "dogecoin"),
        .init(symbol: "LINK", name: "Chainlink", kind: .crypto, exchange: "", coinID: "chainlink")
    ]

    /// A sensible starting watchlist if someone skips picking.
    static func starter(for markets: Set<MarketChoice>) -> [PickedAsset] {
        var out: [PickedAsset] = []
        if markets.contains(.asx) { out += asx.prefix(3) }
        if markets.contains(.us) || markets.isEmpty { out += us.prefix(3) }
        if markets.contains(.crypto) { out += crypto.prefix(2) }
        return out
    }
}

// MARK: - View model

@MainActor
final class OnboardingViewModel: ObservableObject {
    @Published private(set) var step: OnboardingStep = .welcome
    /// True when the last navigation went backwards — drives the slide direction.
    @Published private(set) var movingBack = false

    @Published var markets: Set<MarketChoice>
    @Published var currency: String
    @Published var picks: [PickedAsset] = []
    @Published var notificationsEnabled: Bool? = nil
    @Published var biometricsEnabled: Bool? = nil
    @Published var accountLabel: String? = nil   // e.g. email, or "Apple ID"

    let biometryType: LABiometryType
    /// Hardware present *and* enrolled — otherwise offering it would just fail.
    let biometricsAvailable: Bool

    /// Set by the container so the flow can skip the account step when already signed in.
    var isSignedIn: () -> Bool = { false }
    /// The plan's watchlist cap (free = 10). nil = unlimited.
    var watchlistLimit: Int? = nil
    /// True after someone tries to follow more than their plan allows.
    @Published var hitWatchlistLimit = false

    init() {
        let region = Locale.current.region?.identifier ?? "US"
        let isAU = region == "AU"
        markets = isAU ? [.asx] : [.us]
        currency = isAU ? "AUD" : "USD"

        let context = LAContext()
        var error: NSError?
        let canEvaluate = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        biometryType = context.biometryType
        biometricsAvailable = canEvaluate && biometryType != .none

        #if DEBUG
        applyDebugLaunchArguments()
        #endif
    }

    // MARK: Navigation

    /// Steps this person will actually see, in order.
    var route: [OnboardingStep] {
        OnboardingStep.allCases.filter { step in
            switch step {
            case .security: return biometricsAvailable
            case .account:  return !isSignedIn() || accountLabel != nil
            default:        return true
            }
        }
    }

    /// Steps that count toward the progress bar (everything between welcome and done).
    var progressSteps: [OnboardingStep] { route.filter { $0 != .welcome && $0 != .done } }

    var progressIndex: Int { min(progressSteps.filter { $0 < step }.count, max(progressSteps.count - 1, 0)) }

    // Order-based rather than index-based: the route can change under us (e.g.
    // signing in mid-flow removes the account step) and that must never strand
    // someone on a step that's no longer listed.
    func next() {
        guard let target = route.first(where: { $0 > step }) else { return }
        go(to: target, back: false)
    }

    func back() {
        guard let target = route.last(where: { $0 < step }) else { return }
        go(to: target, back: true)
    }

    func go(to target: OnboardingStep, back: Bool = false) {
        movingBack = back
        dsAnimate { step = target }
    }

    // MARK: Picks

    func isPicked(_ asset: PickedAsset) -> Bool { picks.contains(asset) }

    func toggle(_ asset: PickedAsset) {
        if !picks.contains(asset), let limit = watchlistLimit, picks.count >= limit {
            Haptics.warning()
            dsAnimate(DS.quick) { hitWatchlistLimit = true }
            return
        }
        Haptics.select()
        dsAnimate(DS.quick) {
            if let i = picks.firstIndex(of: asset) {
                picks.remove(at: i)
                hitWatchlistLimit = false
            } else {
                picks.append(asset)
            }
        }
    }

    // MARK: Permissions

    func requestNotifications() async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        notificationsEnabled = granted
        if granted { Haptics.success() }
    }

    func enableBiometrics() async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = String(localized: "Not now")
        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: String(localized: "Use \(biometryName) to keep your portfolio private.")
            )
            biometricsEnabled = ok
            if ok { Haptics.success() }
            return ok
        } catch {
            return false
        }
    }

    var biometryName: String {
        switch biometryType {
        case .touchID:  return "Touch ID"
        case .opticID:  return "Optic ID"
        default:        return "Face ID"
        }
    }

    // MARK: Commit

    /// Persists every choice. Watchlist picks are queued for `OnboardingHandoff`,
    /// which adds them once live quotes load (and retries next launch if offline).
    func commit(marketData: MarketData) {
        let defaults = UserDefaults.standard
        // Home market drives the market-hours badge: ASX when it's the only share
        // market picked, or when they've chosen to see values in AUD.
        let homeIsASX = markets.contains(.asx) && (!markets.contains(.us) || currency == "AUD")
        defaults.set(homeIsASX ? "AU" : "US", forKey: "preferredMarket")
        defaults.set(markets.map(\.rawValue), forKey: "onboarding_markets")
        defaults.set(biometricsEnabled ?? false, forKey: "useBiometrics")

        if marketData.preferredCurrency != currency {
            marketData.preferredCurrency = currency
            marketData.saveToDisk()
        }

        OnboardingHandoff.enqueue(picks)
        defaults.set(true, forKey: "hasCompletedOnboarding")
        AppLogger.general.info("Onboarding complete: \(self.picks.count) picks, markets \(self.markets.map(\.rawValue))")
    }

    // MARK: Debug

    #if DEBUG
    /// `-OnboardingStep follow` jumps straight to a step; `-OnboardingDemoPicks` preselects a few.
    private func applyDebugLaunchArguments() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "OnboardingStep"),
           let target = OnboardingStep.allCases.first(where: { "\($0)" == raw }) {
            step = target
        }
        if defaults.bool(forKey: "OnboardingDemoPicks") {
            markets = [.asx, .us, .crypto]
            picks = [OnboardingCatalog.asx[0], OnboardingCatalog.us[1], OnboardingCatalog.us[0], OnboardingCatalog.crypto[0]]
        }
    }
    #endif
}

// MARK: - Hand-off to the app

/// Moves onboarding picks into the real watchlist. Each pick stays queued until
/// its quote loads, so an offline first launch doesn't lose anything.
@MainActor
enum OnboardingHandoff {
    private static let queueKey = "onboarding_picks_v2"
    /// Pre-redesign key (plain stock symbols); still honoured for upgrades.
    private static let legacyKey = "onboarding_stocks"

    static func enqueue(_ picks: [PickedAsset]) {
        guard !picks.isEmpty else { return }
        var queue = load()
        for pick in picks where !queue.contains(pick) { queue.append(pick) }
        save(queue)
    }

    static func applyPending(to marketData: MarketData) {
        var queue = load()
        if let legacy = UserDefaults.standard.array(forKey: legacyKey) as? [String] {
            for symbol in legacy {
                let isASX = symbol.hasSuffix(".AX")
                let display = symbol.replacingOccurrences(of: ".AX", with: "")
                let pick = PickedAsset(symbol: display, name: display, kind: .stock, exchange: isASX ? "ASX" : "US")
                if !queue.contains(pick) { queue.append(pick) }
            }
            UserDefaults.standard.removeObject(forKey: legacyKey)
            save(queue)
        }
        guard !queue.isEmpty else { return }

        // All picks are priced at once. One at a time, a single slow or rate-limited
        // source (CoinGecko backing off) held every later pick back: new users saw an
        // almost empty Home for about a minute.
        Task { @MainActor in
            let started = Date()
            var assets: [Int: Asset] = [:]
            var finished = Set<Int>()
            var added = Set<Int>()
            var nextInOrder = 0

            @MainActor func add(_ index: Int) {
                guard let asset = assets[index], added.insert(index).inserted else { return }
                marketData.addToWatchlist(named(asset, queue[index].name))
                remove(queue[index])
            }

            await withTaskGroup(of: (Int, Asset?).self) { group in
                for (index, pick) in queue.enumerated() {
                    group.addTask { @MainActor in
                        do {
                            let asset = try await APIService.shared.fetchAssetDetails(
                                identifier: pick.lookupIdentifier,
                                kind: pick.kind,
                                name: pick.name,
                                exchange: pick.exchange == "ASX" ? "ASX" : ""
                            )
                            return (index, asset)
                        } catch {
                            AppLogger.api.error("Onboarding pick \(pick.symbol) not added yet: \(error.localizedDescription)")
                            return (index, nil)
                        }
                    }
                }
                for await (index, asset) in group {
                    finished.insert(index)
                    if let asset { assets[index] = asset }
                    // Keep the order they were picked in…
                    while nextInOrder < queue.count && finished.contains(nextInOrder) {
                        add(nextInOrder)
                        nextInOrder += 1
                    }
                    // …but never hold a ready pick back for a slow one for more than 2s.
                    if Date().timeIntervalSince(started) > 2 {
                        for ready in finished.sorted() { add(ready) }
                    }
                }
            }
        }
    }

    /// Some quote sources return the ticker as the name ("AAPL"); keep the
    /// friendly name the person picked ("Apple") in that case.
    private static func named(_ asset: Asset, _ name: String) -> Asset {
        guard asset.name == asset.symbol || asset.name.isEmpty, !name.isEmpty, name != asset.symbol else { return asset }
        return Asset(
            id: asset.id, symbol: asset.symbol, name: name,
            price: asset.price, change: asset.change, changePercent: asset.changePercent,
            volume: asset.volume, kind: asset.kind,
            marketCap: asset.marketCap, peRatio: asset.peRatio, eps: asset.eps,
            week52High: asset.week52High, week52Low: asset.week52Low,
            avgVolume: asset.avgVolume, dividend: asset.dividend, beta: asset.beta,
            exchange: asset.exchange
        )
    }

    private static func load() -> [PickedAsset] {
        guard let data = UserDefaults.standard.data(forKey: queueKey),
              let picks = try? JSONDecoder().decode([PickedAsset].self, from: data) else { return [] }
        return picks
    }

    private static func save(_ picks: [PickedAsset]) {
        if picks.isEmpty {
            UserDefaults.standard.removeObject(forKey: queueKey)
        } else if let data = try? JSONEncoder().encode(picks) {
            UserDefaults.standard.set(data, forKey: queueKey)
        }
    }

    private static func remove(_ pick: PickedAsset) {
        save(load().filter { $0 != pick })
    }
}
