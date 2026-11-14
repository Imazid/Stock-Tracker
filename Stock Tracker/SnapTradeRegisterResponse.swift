//
//  SnapTradeRegisterResponse.swift
//  Stock Tracker
//
//  Created by Ihtisham Mazid on 28/1/2026.
//


//
//  SnapTradeModels.swift
//  Stock Tracker
//
//  SnapTrade API Response Models (DTOs)
//  These models map directly to API responses and should NOT be used in views
//

import Foundation

// MARK: - Authentication Models

struct SnapTradeRegisterResponse: Codable {
    let userSecret: String
    let userId: String?
    
    enum CodingKeys: String, CodingKey {
        case userSecret
        case userId
    }
}

struct SnapTradeLoginResponse: Codable {
    let redirectURI: String
    let sessionId: String?
    
    enum CodingKeys: String, CodingKey {
        case redirectURI
        case sessionId
    }
}

// MARK: - Account Models

enum BrokerPositionsStatus: String, Codable {
    case available, pending, disconnected, closed, archived, unavailable

    var label: String? {
        switch self {
        case .available: nil
        case .pending: "Waiting for positions"
        case .disconnected: "Reconnect to refresh"
        case .closed: "Closed"
        case .archived: "Archived"
        case .unavailable: "Positions unavailable"
        }
    }
}

struct SnapTradeAccount: Decodable {
    let id: String
    let name: String?
    let number: String
    let institutionName: String
    let createdDate: String?
    let meta: SnapTradeAccountMeta?
    let balance: SnapTradeBalance?
    let positionsStatus: BrokerPositionsStatus?
    
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case number
        case institutionName = "institution_name"
        case createdDate = "created_date"
        case meta
        case balance
        case positionsStatus = "positions_status"
    }
}

struct SnapTradeAccountMeta: Codable {
    let type: String?
}

/// Provider response used by the direct connection in Debug builds.
struct SnapTradeAccountDirectory: Decodable {
    struct Account: Decodable {
        struct SyncStatus: Decodable {
            let positionsPending: Bool

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                positionsPending = try values.contains(.positions) && values.decodeNil(forKey: .positions)
            }

            private enum CodingKeys: String, CodingKey { case positions }
        }

        let kind: String
        let id: UUID
        let connectionId: UUID
        let displayName: String?
        let maskedAccountNumber: String
        let rawType: String?
        let netValue: SnapTradeAmount?
        let status: String?
        let syncStatus: SyncStatus?

        private enum CodingKeys: String, CodingKey {
            case kind, id, status
            case connectionId = "connection_id"
            case displayName = "display_name"
            case maskedAccountNumber = "masked_account_number"
            case rawType = "raw_type"
            case netValue = "net_value"
            case syncStatus = "sync_status"
        }
    }

    struct Connection: Decodable {
        let id: UUID
        let brokerage: SnapTradeBrokerage?
        let disabled: Bool?
    }

    let results: [Account]
}

struct SnapTradeBalance: Codable {
    let total: SnapTradeAmount?
    let cash: SnapTradeAmount?
    
    enum CodingKeys: String, CodingKey {
        case total
        case cash
    }
}

struct SnapTradeAmount: Codable {
    let amount: Double?
    let currency: String?
    
    enum CodingKeys: String, CodingKey {
        case amount
        case currency
    }
}

// MARK: - Holdings Models

struct SnapTradePositionsResponse: Decodable {
    let results: [SnapTradePosition]
}

struct SnapTradePosition: Decodable {
    struct Instrument: Decodable {
        let kind: String
        let symbol: String?
        let description: String?
        let currency: String?
        let exchange: String?
    }

    let instrument: Instrument
    let units: String?
    let price: String?
    let costBasis: String?
    let currency: String?
    let cashEquivalent: Bool?

    enum CodingKeys: String, CodingKey {
        case instrument, units, price, currency
        case costBasis = "cost_basis"
        case cashEquivalent = "cash_equivalent"
    }
}

// MARK: - Error Response

struct SnapTradeErrorResponse: Codable {
    let detail: String?
    let code: String?
    
    enum CodingKeys: String, CodingKey {
        case detail
        case code
    }
}
// MARK: - Brokerages (GET /brokerages)

/// One institution SnapTrade can connect. `slug` is what `/snapTrade/login` expects as `broker`.
struct SnapTradeBrokerage: Decodable {
    let slug: String?
    let name: String?
    let displayName: String?
    let squareLogoURL: String?
    let logoURL: String?
    let enabled: Bool?
    let maintenanceMode: Bool?
    let brokerageType: BrokerageType?

    struct BrokerageType: Decodable { let name: String? }

    enum CodingKeys: String, CodingKey {
        case slug, name, enabled
        case displayName = "display_name"
        case squareLogoURL = "aws_s3_square_logo_url"
        case logoURL = "aws_s3_logo_url"
        case maintenanceMode = "maintenance_mode"
        case brokerageType = "brokerage_type"
    }
}

/// DELETE /snapTrade/deleteUser
struct SnapTradeDeleteUserResponse: Decodable {
    let status: String?
    let detail: String?
    let userId: String?
}
