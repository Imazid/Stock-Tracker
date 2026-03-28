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

struct SnapTradeAccount: Codable {
    let id: String
    let brokerageAuthorization: String
    let portfolioGroup: String?
    let name: String?
    let number: String
    let institutionName: String
    let createdDate: String?
    let meta: SnapTradeAccountMeta?
    let cashRestrictions: [String]?
    let balance: SnapTradeBalance?
    
    enum CodingKeys: String, CodingKey {
        case id
        case brokerageAuthorization = "brokerage_authorization"
        case portfolioGroup = "portfolio_group"
        case name
        case number
        case institutionName = "institution_name"
        case createdDate = "created_date"
        case meta
        case cashRestrictions = "cash_restrictions"
        case balance
    }
}

struct SnapTradeAccountMeta: Codable {
    let type: String?
    let status: String?
    let institutionName: String?
    
    enum CodingKeys: String, CodingKey {
        case type
        case status
        case institutionName = "institution_name"
    }
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

/// Response wrapper for account holdings
struct SnapTradeAccountHoldingsResponse: Codable {
    let account: SnapTradeAccountSimple?
    let positions: [SnapTradePosition]?
    let totalValue: SnapTradeAmount?
    
    enum CodingKeys: String, CodingKey {
        case account
        case positions
        case totalValue = "total_value"
    }
}

struct SnapTradeAccountSimple: Codable {
    let id: String
    let number: String
    let name: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case number
        case name
    }
}

struct SnapTradePosition: Codable {
    let symbol: SnapTradeBrokerageSymbol
    let units: Double?
    let price: Double?
    let openPnl: Double?
    let fractionalUnits: Double?
    let averagePurchasePrice: Double?
    let currency: SnapTradeCurrency?

    enum CodingKeys: String, CodingKey {
        case symbol
        case units
        case price
        case openPnl = "open_pnl"
        case fractionalUnits = "fractional_units"
        case averagePurchasePrice = "average_purchase_price"
        case currency
    }
}

/// The inner "UniversalSymbol" — contains the actual ticker string.
struct SnapTradeUniversalSymbol: Codable {
    let id: String?
    let symbol: String
    let rawSymbol: String?
    let description: String?
    let currency: SnapTradeCurrency?
    let exchange: SnapTradeExchange?
    let type: SnapTradeSecurityType?

    enum CodingKeys: String, CodingKey {
        case id
        case symbol
        case rawSymbol = "raw_symbol"
        case description
        case currency
        case exchange
        case type
    }
}

/// The outer "BrokerageSymbol" wrapper returned in Position objects.
/// Its `.symbol` field is a nested UniversalSymbol object, not a string.
struct SnapTradeBrokerageSymbol: Codable {
    let id: String?
    let symbol: SnapTradeUniversalSymbol
    let localId: String?
    let description: String?
    let currency: SnapTradeCurrency?
    let exchange: SnapTradeExchange?
    let type: SnapTradeSecurityType?

    enum CodingKeys: String, CodingKey {
        case id
        case symbol
        case localId = "local_id"
        case description
        case currency
        case exchange
        case type
    }
}

/// Legacy alias kept for any callers that reference SnapTradeSymbol directly.
typealias SnapTradeSymbol = SnapTradeBrokerageSymbol

struct SnapTradeCurrency: Codable {
    let id: String?
    let code: String
    let name: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case code
        case name
    }
}

struct SnapTradeExchange: Codable {
    let id: String?
    let code: String?
    let micCode: String?
    let name: String?
    let timezone: String?
    let startTime: String?
    let closeTime: String?
    let suffix: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case code
        case micCode = "mic_code"
        case name
        case timezone
        case startTime = "start_time"
        case closeTime = "close_time"
        case suffix
    }
}

struct SnapTradeSecurityType: Codable {
    let id: String?
    let code: String?
    let description: String?
    let isSupported: Bool?
    
    enum CodingKeys: String, CodingKey {
        case id
        case code
        case description
        case isSupported = "is_supported"
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