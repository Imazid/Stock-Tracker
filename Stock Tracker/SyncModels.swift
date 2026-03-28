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

// MARK: - RemoteWatchlistAsset
// Maps to: public.watchlist_assets
// Uniqueness: (user_id, symbol)
// Sync tier: FREE (all signed-in users)

struct RemoteWatchlistAsset: Codable {
    let id: String          // uuid, server-generated
    let userId: String
    let symbol: String
    let name: String
    let kind: String        // "Stock" | "Crypto"
    let exchange: String?
    let updatedAt: String
    let deletedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userId      = "user_id"
        case symbol
        case name
        case kind
        case exchange
        case updatedAt   = "updated_at"
        case deletedAt   = "deleted_at"
    }

    var isDeleted: Bool { deletedAt != nil }

    /// Converts to a domain Asset. Live price fields are zeroed out — they are
    /// always refreshed from the market API, never stored in the cloud.
    func toDomain() -> Asset {
        Asset(
            symbol: symbol,
            name: name,
            price: 0,
            change: 0,
            changePercent: 0,
            volume: 0,
            kind: AssetKind(rawValue: kind) ?? .stock,
            exchange: exchange ?? ""
        )
    }

    /// Builds an upsert payload from a domain Asset.
    static func from(_ asset: Asset, userId: UUID) -> WatchlistUpsert {
        WatchlistUpsert(
            user_id:  userId.uuidString,
            symbol:   asset.symbol,
            name:     asset.name,
            kind:     asset.kind.rawValue,
            exchange: asset.exchange
        )
    }
}

struct WatchlistUpsert: Encodable {
    let user_id: String
    let symbol: String
    let name: String
    let kind: String
    let exchange: String?
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
            transactions: transactions
        )
    }

    static func from(_ holding: PortfolioHolding, userId: UUID) -> HoldingUpsert {
        HoldingUpsert(
            id:             holding.id.uuidString,
            user_id:        userId.uuidString,
            asset_symbol:   holding.asset.symbol,
            asset_name:     holding.asset.name,
            asset_kind:     holding.asset.kind.rawValue,
            asset_exchange: holding.asset.exchange,
            shares:         holding.shares,
            avg_cost:       holding.avgCost,
            date_added:     iso8601Basic.string(from: holding.dateAdded)
        )
    }
}

struct HoldingUpsert: Encodable {
    let id: String
    let user_id: String
    let asset_symbol: String
    let asset_name: String
    let asset_kind: String
    let asset_exchange: String?
    let shares: Double
    let avg_cost: Double
    let date_added: String
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
            type: TransactionType(rawValue: type) ?? .buy
        )
    }

    static func from(_ tx: Transaction, holdingId: UUID, userId: UUID) -> TransactionUpsert {
        TransactionUpsert(
            id:               tx.id.uuidString,
            user_id:          userId.uuidString,
            holding_id:       holdingId.uuidString,
            transaction_date: iso8601Basic.string(from: tx.date),
            shares:           tx.shares,
            price_per_share:  tx.pricePerShare,
            type:             tx.type.rawValue
        )
    }
}

struct TransactionUpsert: Encodable {
    let id: String
    let user_id: String
    let holding_id: String
    let transaction_date: String
    let shares: Double
    let price_per_share: Double
    let type: String
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
            createdAt: parseDate(createdAt)
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
    let created_at: String
}

// MARK: - RemotePortfolioSnapshot
// Maps to: public.portfolio_snapshots
// Uniqueness: (user_id, snapshot_date) — upserted by date, not by id
// Sync tier: All signed-in users

struct RemotePortfolioSnapshot: Codable {
    let id: String
    let userId: String
    let snapshotDate: String    // "YYYY-MM-DD"
    let totalValue: Double
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case userId       = "user_id"
        case snapshotDate = "snapshot_date"
        case totalValue   = "total_value"
        case updatedAt    = "updated_at"
    }

    func toDomain() -> PortfolioSnapshot {
        // Parse date-only string "YYYY-MM-DD"
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(identifier: "UTC")
        let date = df.date(from: snapshotDate) ?? Date()
        return PortfolioSnapshot(date: date, totalValue: totalValue)
    }

    static func from(_ snapshot: PortfolioSnapshot, userId: UUID) -> SnapshotUpsert {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(identifier: "UTC")
        return SnapshotUpsert(
            user_id:       userId.uuidString,
            snapshot_date: df.string(from: snapshot.date),
            total_value:   snapshot.totalValue
        )
    }
}

struct SnapshotUpsert: Encodable {
    let user_id: String
    let snapshot_date: String
    let total_value: Double
}
