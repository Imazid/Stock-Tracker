import Foundation

struct PortfolioGroupChange: Codable {
    nonisolated enum Action: String, Codable, Sendable { case `import`, create, rename, delete }

    let id: UUID
    let groupID: UUID
    let action: Action
    let name: String?
    let emoji: String?
    let holdings: [UUID]

    init(_ action: Action, group: PortfolioGroup) {
        id = UUID()
        groupID = group.id
        self.action = action
        name = group.name
        emoji = group.emoji
        holdings = action == .import ? group.holdings.map(\.id) + group.closedPositions.map(\.id) : []
    }

    nonisolated struct Parameters: Encodable, Sendable {
        let p_user_id: UUID
        let p_id: UUID
        let p_group_id: UUID
        let p_action: String
        let p_name: String?
        let p_emoji: String?
        let p_holdings: [UUID]
    }

    func parameters(owner: UUID) -> Parameters {
        Parameters(p_user_id: owner, p_id: id, p_group_id: groupID, p_action: action.rawValue,
                   p_name: name, p_emoji: emoji, p_holdings: holdings)
    }

    func apply(to groups: inout [PortfolioGroup]) {
        if let index = groups.firstIndex(where: { $0.id == groupID }) {
            switch action {
            case .create, .import: break
            case .rename: if let name { groups[index].name = name }
            case .delete: groups.remove(at: index)
            }
        } else if action == .create || action == .import {
            groups.append(PortfolioGroup(id: groupID, name: name ?? "Portfolio", emoji: emoji ?? "💼"))
        }
    }
}

struct StoredPortfolios: Codable {
    struct Account: Codable {
        var groups = [PortfolioGroup(id: PortfolioGroup.defaultID, name: "Main Portfolio")]
        var selected = PortfolioGroup.defaultID
        var pendingGroups: [PortfolioGroupChange] = []
        var needsImport = false
        var hiddenClosed: Set<UUID> = []
        var pendingValuations: [String: [String: PortfolioSnapshot]] = [:]

        var needsUpload: Bool { needsImport || !pendingGroups.isEmpty || !pendingValuations.isEmpty }

        func importing() -> Self {
            var result = self
            result.pendingGroups = groups.compactMap {
                if $0.id == PortfolioGroup.defaultID && $0.name == "Main Portfolio" && $0.emoji == "💼" { return nil }
                return PortfolioGroupChange(.import, group: $0)
            }
            result.needsImport = groups.contains { !$0.holdings.isEmpty || !$0.closedPositions.isEmpty || !$0.history.isEmpty }
            return result
        }
    }

    var guest = Account()
    var guestImportOwner: UUID?
    var accounts: [String: Account] = [:]

    init() {}

    init(legacyGroups: [PortfolioGroup], selectedIndex: Int, holdings: [PortfolioHolding],
         history: [PortfolioSnapshot], hiddenClosed: Set<UUID>, owner: UUID?) {
        var groups = legacyGroups
        if groups.isEmpty { groups = [PortfolioGroup(name: "Main Portfolio")] }
        groups[0].id = PortfolioGroup.defaultID
        let selectedIndex = min(max(selectedIndex, 0), groups.count - 1)
        // A named portfolio's own saved ledger identifies which previously synced
        // holdings belong there. Give those IDs precedence over the flat default copy.
        if legacyGroups.isEmpty {
            groups[0].holdings = holdings
            groups[0].history = history
        }
        let named = Set(groups.dropFirst().flatMap { $0.holdings.map(\.id) + $0.closedPositions.map(\.id) })
        groups[0].holdings.removeAll { named.contains($0.id) }
        groups[0].closedPositions.removeAll { named.contains($0.id) }
        for index in groups.indices {
            let name = groups[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
            groups[index].name = name.isEmpty ? "Portfolio" : String(name.unicodeScalars.prefix(80))
            let emoji = groups[index].emoji
            groups[index].emoji = emoji.isEmpty ? "💼" : String(emoji.unicodeScalars.prefix(24))
        }
        let account = Account(groups: groups, selected: groups[selectedIndex].id, hiddenClosed: hiddenClosed)
        if let owner {
            accounts[owner.uuidString] = account.importing()
            guestImportOwner = owner
        } else {
            guest = account
        }
    }
}

@MainActor
final class PortfolioAccountStore {
    static let shared = PortfolioAccountStore()
    private let persist = DataPersistenceManager.shared

    private init() {}

    func open(owner: UUID?) -> StoredPortfolios.Account {
        var state = persist.loadPortfolioAccounts()
        guard let owner else { return state.guest }
        if let account = state.accounts[owner.uuidString] { return account }
        let account = state.guestImportOwner == nil ? state.guest.importing() : StoredPortfolios.Account()
        state.guestImportOwner = state.guestImportOwner ?? owner
        state.accounts[owner.uuidString] = account
        persist.savePortfolioAccounts(state)
        return account
    }

    func cached(owner: UUID?) -> StoredPortfolios.Account {
        let state = persist.loadPortfolioAccounts()
        guard let owner else { return state.guest }
        return state.accounts[owner.uuidString] ?? StoredPortfolios.Account()
    }

    @discardableResult
    func update(owner: UUID?, _ change: (inout StoredPortfolios.Account) -> Void) -> Bool {
        var state = persist.loadPortfolioAccounts()
        if let owner {
            guard var account = state.accounts[owner.uuidString] else { return false }
            change(&account)
            state.accounts[owner.uuidString] = account
        } else {
            change(&state.guest)
        }
        return persist.savePortfolioAccounts(state)
    }
}
