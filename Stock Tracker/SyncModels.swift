//
//  SyncModels.swift
//  Stock Tracker
//
//  Codable structs that mirror each Supabase table column-for-column.
//  These are the transport layer only — the rest of the app always works
//  with domain models (Asset, PortfolioHolding, etc.).
//
//  CodingKeys map Swift camelCase → Postgres snake_case automatically.
//  Each struct has:
//    - toDomain()              → converts remote row → domain model
//    - static from(_:userId:)  → converts domain model → remote row for upsert
//

import Foundation

// MARK: - ISO 8601 formatter (shared, thread-safe after init)

private let iso8601Full: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let iso8601Basic: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

private func parseDate(_ string: String) -> Date {
    iso8601Full.date(from: string) ?? iso8601Basic.date(from: string) ?? Date()
}

// MARK: - RemoteHolding
// Maps to: public.portfolio_holdings
// Primary key: id (same UUID as PortfolioHolding.id)
// Sync tier: All signed-in users

struct RemoteHolding: Codable {
    let id: String
    let userId: String
    let assetSymbol: String
    let assetName: String
    let assetKind: String
    let assetExchange: String?
    let shares: Double
    let avgCost: Double
    let dateAdded: String
    let updatedAt: String
    let deletedAt: String?
    let closedAt: String?
    let brokerAccount: HoldingBrokerAccount?
    let groupID: UUID?
    let ledgerRevision: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case userId        = "user_id"
        case assetSymbol   = "asset_symbol"
        case assetName     = "asset_name"
        case assetKind     = "asset_kind"
        case assetExchange = "asset_exchange"
        case shares
        case avgCost       = "avg_cost"
        case dateAdded     = "date_added"
        case updatedAt     = "updated_at"
        case deletedAt     = "deleted_at"
        case closedAt      = "closed_at"
        case brokerAccount = "broker_account"
        case groupID       = "portfolio_group_id"
        case ledgerRevision = "ledger_revision"
    }

    var isDeleted: Bool { deletedAt != nil }

    func toDomain(transactions: [Transaction] = []) -> PortfolioHolding {
        let asset = Asset(
            symbol: assetSymbol,
            name: assetName,
            price: 0,
            change: 0,
            changePercent: 0,
            volume: 0,
            kind: AssetKind(rawValue: assetKind) ?? .stock,
            exchange: assetExchange ?? ""
        )
        return PortfolioHolding(
            id: UUID(uuidString: id) ?? UUID(),
            asset: asset,
            shares: shares,
            avgCost: avgCost,
            dateAdded: parseDate(dateAdded),
            transactions: transactions,
            brokerAccount: brokerAccount,
            ledgerRevision: ledgerRevision
        )
    }

    func toClosedPosition(transactions: [Transaction]) -> ClosedPosition? {
        guard let closedAt, let id = UUID(uuidString: id), !transactions.isEmpty else { return nil }
        let holding = toDomain()
        return ClosedPosition(id: id, asset: holding.asset, transactions: transactions,
                              openedAt: transactions.map(\.date).min() ?? holding.dateAdded,
                              closedAt: parseDate(closedAt))
    }

    static func from(_ holding: PortfolioHolding, userId: UUID, groupID: UUID?) -> HoldingUpsert {
        HoldingUpsert(
            id:             holding.id.uuidString,
            user_id:        userId.uuidString,
            asset_symbol:   holding.asset.symbol,
            asset_name:     holding.asset.name,
            asset_kind:     holding.asset.kind.rawValue,
            asset_exchange: holding.asset.exchange,
            shares:         holding.shares,
            avg_cost:       holding.avgCost,
            date_added:     iso8601Basic.string(from: holding.dateAdded),
            broker_account: holding.brokerAccount,
            portfolio_group_id: groupID
        )
    }
}

nonisolated struct HoldingUpsert: Encodable, Sendable {
    let id: String
    let user_id: String
    let asset_symbol: String
    let asset_name: String
    let asset_kind: String
    let asset_exchange: String?
    let shares: Double
    let avg_cost: Double
    let date_added: String
    let broker_account: HoldingBrokerAccount?
    let portfolio_group_id: UUID?
}

// MARK: - RemoteTransaction
// Maps to: public.transactions
// Primary key: id (same UUID as Transaction.id)
// Sync tier: All signed-in users (child of holdings)

struct RemoteTransaction: Codable {
    let id: String
    let userId: String
    let holdingId: String
    let transactionDate: String
    let shares: Double
    let pricePerShare: Double
    let type: String        // "Buy" | "Sell"
    /// Optional so rows written before fees/realised profit existed still decode.
    let fees: Double?
    let avgCostAtSale: Double?
    let provenance: TradeProvenance?
    let updatedAt: String
    let deletedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId          = "user_id"
        case holdingId       = "holding_id"
        case transactionDate = "transaction_date"
        case shares
        case pricePerShare   = "price_per_share"
        case type
        case fees
        case avgCostAtSale   = "avg_cost_at_sale"
        case provenance      = "trade_provenance"
        case updatedAt       = "updated_at"
        case deletedAt       = "deleted_at"
    }

    var isDeleted: Bool { deletedAt != nil }

    func toDomain() -> Transaction {
        Transaction(
            id: UUID(uuidString: id) ?? UUID(),
            date: parseDate(transactionDate),
            shares: shares,
            pricePerShare: pricePerShare,
            type: TransactionType(rawValue: type) ?? .buy,
            fees: fees ?? 0,
            avgCostAtSale: avgCostAtSale,
            provenance: provenance
        )
    }

    static func from(_ tx: Transaction, holdingId: UUID, userId: UUID) -> TransactionUpsert {
        TransactionUpsert(
            id:               tx.id.uuidString,
            user_id:          userId.uuidString,
            holding_id:       holdingId.uuidString,
            transaction_date: iso8601Full.string(from: tx.date),
            shares:           tx.shares,
            price_per_share:  tx.pricePerShare,
            type:             tx.type.rawValue,
            fees:             tx.fees,
            avg_cost_at_sale: tx.avgCostAtSale,
            trade_provenance: tx.provenance
        )
    }
}

nonisolated struct TransactionUpsert: Encodable, Sendable {
    let id: String
    let user_id: String
    let holding_id: String
    let transaction_date: String
    let shares: Double
    let price_per_share: Double
    let type: String
    let fees: Double
    let avg_cost_at_sale: Double?
    let trade_provenance: TradeProvenance?
}

struct PortfolioLedgerChange: Codable {
    let revision: UUID
    var holding: PortfolioHolding
    let changed: Set<UUID>
    let deleted: [Transaction]
    let archivedAt: Date?
    let closedAt: Date?
    var groupID: UUID? = nil
    var submitted: Bool? = nil
    var follows: UUID? = nil
    var conflicted: Bool? = nil

    nonisolated struct GuardedParameters: Encodable, Sendable {
        let change: Parameters
        let p_mutation_id: UUID
        let p_expected_revision: UUID?

        func encode(to encoder: Encoder) throws {
            try change.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(p_mutation_id, forKey: .p_mutation_id)
            try container.encode(p_expected_revision, forKey: .p_expected_revision)
        }

        private enum CodingKeys: String, CodingKey { case p_mutation_id, p_expected_revision }
    }

    nonisolated struct Parameters: Encodable, Sendable {
        let p_user_id: UUID
        let p_holding: HoldingUpsert
        let p_transactions: [TransactionUpsert]
        let p_changed_ids: Set<UUID>
        let p_deleted_ids: [UUID]
        let p_archived_at: String?
        let p_closed_at: String?

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(p_user_id, forKey: .p_user_id)
            try container.encode(p_holding, forKey: .p_holding)
            try container.encode(p_transactions, forKey: .p_transactions)
            try container.encode(p_changed_ids, forKey: .p_changed_ids)
            try container.encode(p_deleted_ids, forKey: .p_deleted_ids)
            try container.encode(p_archived_at, forKey: .p_archived_at)
            try container.encode(p_closed_at, forKey: .p_closed_at)
        }

        private enum CodingKeys: String, CodingKey {
            case p_user_id, p_holding, p_transactions, p_changed_ids, p_deleted_ids, p_archived_at, p_closed_at
        }
    }

    func parameters(userId: UUID, existingArchive: String? = nil) -> Parameters {
        let rows = Dictionary((holding.transactions + deleted).map { ($0.id, $0) },
                              uniquingKeysWith: { _, latest in latest })
        return Parameters(p_user_id: userId, p_holding: RemoteHolding.from(holding, userId: userId, groupID: groupID == PortfolioGroup.defaultID ? nil : groupID),
                   p_transactions: rows.values.map {
                       RemoteTransaction.from($0, holdingId: holding.id, userId: userId)
                   }, p_changed_ids: changed, p_deleted_ids: deleted.map(\.id),
                   p_archived_at: existingArchive ?? archivedAt.map { iso8601Full.string(from: $0) },
                   p_closed_at: closedAt.map { iso8601Full.string(from: $0) })
    }
}

// MARK: - RemotePriceAlert
// Maps to: public.price_alerts
// Primary key: id (same UUID as PriceAlert.id)
// Sync tier: All signed-in users

struct RemotePriceAlert: Codable {
    let id: String
    let userId: String
    let symbol: String
    let assetName: String
    let targetPrice: Double
    let condition: String   // "Above" | "Below"
    let isActive: Bool
    /// Optional so rows written before repeating alerts existed still decode.
    let repeats: Bool?
    let isArmed: Bool?
    let lastTriggeredAt: String?
    let assetKind: String?
    let assetExchange: String?
    let createdAt: String
    let updatedAt: String
    let deletedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId      = "user_id"
        case symbol
        case assetName   = "asset_name"
        case targetPrice = "target_price"
        case condition
        case isActive    = "is_active"
        case repeats
        case isArmed     = "is_armed"
        case lastTriggeredAt = "last_triggered_at"
        case assetKind   = "asset_kind"
        case assetExchange = "asset_exchange"
        case createdAt   = "created_at"
        case updatedAt   = "updated_at"
        case deletedAt   = "deleted_at"
    }

    var isDeleted: Bool { deletedAt != nil }

    func toDomain() -> PriceAlert {
        PriceAlert(
            id: UUID(uuidString: id) ?? UUID(),
            symbol: symbol,
            assetName: assetName,
            targetPrice: targetPrice,
            condition: AlertCondition(rawValue: condition) ?? .above,
            isActive: isActive,
            createdAt: parseDate(createdAt),
            repeats: repeats ?? false,
            isArmed: isArmed ?? true,
            lastTriggeredAt: lastTriggeredAt.map(parseDate),
            kind: assetKind.flatMap(AssetKind.init(rawValue:)),
            exchange: assetExchange
        )
    }

    static func from(_ alert: PriceAlert, userId: UUID) -> AlertUpsert {
        AlertUpsert(
            id:           alert.id.uuidString,
            user_id:      userId.uuidString,
            symbol:       alert.symbol,
            asset_name:   alert.assetName,
            target_price: alert.targetPrice,
            condition:    alert.condition.rawValue,
            is_active:    alert.isActive,
            repeats:      alert.repeats,
            is_armed:     alert.isArmed,
            last_triggered_at: alert.lastTriggeredAt.map { iso8601Basic.string(from: $0) },
            asset_kind:   alert.kind?.rawValue,
            asset_exchange: alert.exchange,
            created_at:   iso8601Basic.string(from: alert.createdAt)
        )
    }
}

struct AlertUpsert: Encodable {
    let id: String
    let user_id: String
    let symbol: String
    let asset_name: String
    let target_price: Double
    let condition: String
    let is_active: Bool
    let repeats: Bool
    let is_armed: Bool
    let last_triggered_at: String?
    let asset_kind: String?
    let asset_exchange: String?
    let created_at: String
}
