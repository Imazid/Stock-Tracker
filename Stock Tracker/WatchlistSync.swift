import Auth
import Foundation
import Supabase
import TradingCore

struct WatchlistChange: Codable {
    enum Action: String, Codable { case `import`, create, rename, delete, add, remove, reorder }

    let id: UUID
    let groupID: UUID
    let action: Action
    let name: String?
    let assets: [Asset]
    let keys: [String]
    var savedAt: Date? = Date()

    init(_ action: Action, groupID: UUID, name: String? = nil, assets: [Asset] = [], keys: [String] = []) {
        id = UUID()
        self.groupID = groupID
        self.action = action
        self.name = name
        self.assets = assets
        self.keys = keys
    }

    static func key(for asset: Asset, in group: UUID) -> String {
        group == WatchlistGroup.defaultID ? asset.symbol : asset.quoteIdentity
    }

    func apply(to groups: inout [WatchlistGroup]) {
        let index = groups.firstIndex { $0.id == groupID }
        if index == nil, action == .create || action == .import {
            groups.append(WatchlistGroup(id: groupID, name: name ?? "My Watchlist", assets: assets))
            return
        }
        guard let index else { return }
        switch action {
        case .import, .create: break
        case .rename: if let name { groups[index].name = name }
        case .delete: groups.remove(at: index)
        case .add:
            var existing = Set(groups[index].assets.map { Self.key(for: $0, in: groupID) })
            let additions = assets.filter { existing.insert(Self.key(for: $0, in: groupID)).inserted }
            groups[index].assets += additions
            var dates = groups[index].savedDates ?? [:]
            for asset in additions { dates[asset.id.uuidString] = savedAt }
            groups[index].savedDates = dates
        case .remove:
            let removed = Set(keys)
            groups[index].assets.removeAll { asset in
                removed.contains(Self.key(for: asset, in: groupID))
            }
            let remaining = Set(groups[index].assets.map { $0.id.uuidString })
            groups[index].savedDates = groups[index].savedDates?.filter { remaining.contains($0.key) }
        case .reorder:
            let requested = Set(keys)
            let current = Dictionary(groups[index].assets.map { (Self.key(for: $0, in: groupID), $0) },
                                     uniquingKeysWith: { first, _ in first })
            groups[index].assets = keys.compactMap { current[$0] }
                + groups[index].assets.filter { !requested.contains(Self.key(for: $0, in: groupID)) }
        }
    }

    nonisolated struct Parameters: Encodable, Sendable {
        nonisolated struct Row: Encodable, Sendable {
            let listing_id: String
            let symbol: String
            let name: String
            let kind: String
            let exchange: String

            @MainActor init(_ asset: Asset, named: Bool) {
                listing_id = asset.quoteIdentity
                if named, let listing = asset.listedStock {
                    symbol = listing.symbol + (listing.venue == .asx ? "" : listing.venue.yahooSuffix ?? "")
                    exchange = listing.venue.shortName
                } else {
                    symbol = asset.symbol
                    exchange = asset.exchange
                }
                name = asset.name
                kind = asset.kind.rawValue
            }
        }

        let p_user_id: UUID
        let p_id: UUID
        let p_group_id: UUID
        let p_action: String
        let p_name: String?
        let p_assets: [Row]
        let p_keys: [String]
    }

    func parameters(userID: UUID) -> Parameters {
        Parameters(p_user_id: userID, p_id: id, p_group_id: groupID, p_action: action.rawValue, p_name: name,
                   p_assets: assets.map { Parameters.Row($0, named: groupID != WatchlistGroup.defaultID) }, p_keys: keys)
    }
}

struct StoredWatchlists: Codable {
    struct Lists: Codable {
        var groups = [WatchlistGroup(id: WatchlistGroup.defaultID, name: "My Watchlist")]
        var selected = WatchlistGroup.defaultID
        var pending: [WatchlistChange] = []

        func importing() -> Self {
            var copy = self
            copy.pending = groups.map { WatchlistChange(.import, groupID: $0.id, name: $0.name, assets: $0.assets) }
            return copy
        }
    }

    var guest = Lists()
    var guestImportOwner: UUID?
    var accounts: [String: Lists] = [:]

    init() {}

    init(legacyGroups: [WatchlistGroup], legacyAssets: [Asset], selectedIndex: Int, owner: UUID?) {
        var groups = legacyGroups
        if groups.isEmpty { groups = [WatchlistGroup(name: "My Watchlist", assets: legacyAssets)] }
        groups[0].id = WatchlistGroup.defaultID
        for index in groups.indices {
            let trimmed = groups[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
            groups[index].name = trimmed.isEmpty ? "My Watchlist" : String(trimmed.unicodeScalars.prefix(80))
        }
        let lists = Lists(groups: groups, selected: groups[min(max(0, selectedIndex), groups.count - 1)].id)
        if let owner {
            accounts[owner.uuidString] = lists.importing()
            guestImportOwner = owner
        } else {
            guest = lists
        }
    }
}

@MainActor
final class WatchlistSync {
    static let shared = WatchlistSync()

    private let persist = DataPersistenceManager.shared

    private init() {}

    func open(owner: UUID?) -> StoredWatchlists.Lists {
        var storage = persist.loadWatchlistStorage()
        guard let owner else { return storage.guest }
        if let lists = storage.accounts[owner.uuidString] { return lists }
        let lists = storage.guestImportOwner == nil ? storage.guest.importing() : StoredWatchlists.Lists()
        storage.guestImportOwner = storage.guestImportOwner ?? owner
        storage.accounts[owner.uuidString] = lists
        persist.saveWatchlistStorage(storage)
        return lists
    }

    func save(groups: [WatchlistGroup], selected: UUID, owner: UUID?, changes: [WatchlistChange] = []) -> Bool {
        var storage = persist.loadWatchlistStorage()
        if let owner {
            guard var lists = storage.accounts[owner.uuidString] else { return false }
            lists.groups = groups
            lists.selected = selected
            lists.pending += changes
            storage.accounts[owner.uuidString] = lists
        } else {
            storage.guest = .init(groups: groups, selected: selected)
        }
        return persist.saveWatchlistStorage(storage)
    }

    func cached(owner: UUID?) -> StoredWatchlists.Lists {
        let storage = persist.loadWatchlistStorage()
        guard let owner else { return storage.guest }
        return storage.accounts[owner.uuidString] ?? StoredWatchlists.Lists()
    }

    func hasPending(owner: UUID) -> Bool {
        !(persist.loadWatchlistStorage().accounts[owner.uuidString]?.pending.isEmpty ?? true)
    }

    func exchange(owner: UUID, marketData: MarketData) async throws {
        let key = owner.uuidString
        let sent = open(owner: owner).pending
        for change in sent {
            guard SupabaseManager.auth.currentUser?.id == owner else { return }
            try await SupabaseManager.client.rpc("apply_watchlist_change", params: change.parameters(userID: owner)).execute()
        }
        guard SupabaseManager.auth.currentUser?.id == owner else { return }
        nonisolated struct Reader: Encodable, Sendable { let p_user_id: UUID }
        let response = try await SupabaseManager.client.rpc("get_watchlists", params: Reader(p_user_id: owner)).execute()
        let remote = try JSONDecoder().decode([RemoteGroup].self, from: response.data)
        guard SupabaseManager.auth.currentUser?.id == owner, marketData.watchlistOwner == owner else { return }
        guard remote.first?.id == WatchlistGroup.defaultID else { throw URLError(.cannotParseResponse) }
        var storage = persist.loadWatchlistStorage()
        guard var lists = storage.accounts[key] else { return }
        let sentIDs = Set(sent.map(\.id))
        lists.pending.removeAll { sentIDs.contains($0.id) }
        // Edits made while fetching remain visible until the next exchange.
        let groups = marketData.mergingWatchlistQuotes(into: remote.map(\.domain))
        lists.groups = groups
        for change in lists.pending { change.apply(to: &lists.groups) }
        if !lists.groups.contains(where: { $0.id == lists.selected }) { lists.selected = WatchlistGroup.defaultID }
        storage.accounts[key] = lists
        guard persist.saveWatchlistStorage(storage) else { throw CocoaError(.fileWriteUnknown) }
        marketData.showWatchlists(lists)
    }

    private struct RemoteGroup: Decodable {
        struct Row: Decodable {
            let id: UUID
            let symbol: String
            let name: String
            let kind: AssetKind
            let exchange: String?
            let saved_at: String?

            var domain: Asset {
                Asset(id: id, symbol: symbol, name: name, price: 0, change: 0, changePercent: 0, volume: 0,
                      kind: kind, exchange: exchange ?? "")
            }
        }

        let id: UUID
        let name: String
        let assets: [Row]

        var domain: WatchlistGroup {
            let dates = Dictionary(uniqueKeysWithValues: assets.compactMap { row -> (String, Date)? in
                guard let text = row.saved_at else { return nil }
                let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
                guard let date = (try? format.parse(text)) ?? (try? Date.ISO8601FormatStyle().parse(text)) else { return nil }
                return (row.id.uuidString, date)
            })
            return WatchlistGroup(id: id, name: name, assets: assets.map(\.domain), savedDates: dates)
        }
    }
}
