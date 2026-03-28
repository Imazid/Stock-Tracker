//
//  BrokerAccount.swift
//  Stock Tracker
//
//  Created by Ihtisham Mazid on 28/1/2026.
//


//
//  BrokerModels.swift
//  Stock Tracker
//
//  App domain models for brokerage data
//  These are used throughout the app and are independent of the API
//

import Foundation

// MARK: - Broker Account

struct BrokerAccount: Identifiable, Codable {
    let id: String
    let name: String?
    let accountNumber: String
    let institutionName: String
    let accountType: String?
    let balance: AccountBalance?
    let createdDate: Date?
    
    var displayName: String {
        name ?? "Account \(accountNumber.suffix(4))"
    }
    
    var maskedAccountNumber: String {
        let suffix = accountNumber.suffix(4)
        return "••••\(suffix)"
    }
}

// MARK: - Account Balance

struct AccountBalance: Codable {
    let total: Money?
    let cash: Money?
}

struct Money: Codable {
    let amount: Double
    let currency: String
    
    /// Convert to user's preferred currency
    func converted(to targetCurrency: String, using exchangeRate: Double) -> Money {
        guard currency != targetCurrency else { return self }
        return Money(amount: amount * exchangeRate, currency: targetCurrency)
    }
    
    var formattedAmount: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSNumber(value: amount)) ?? "\(currency) \(String(format: "%.2f", amount))"
    }
}

// MARK: - Broker Holding

struct BrokerHolding: Identifiable, Codable {
    let id: String
    let accountId: String
    let symbol: String
    let description: String?
    let quantity: Double
    let currentPrice: Double?
    let averageCost: Double?
    let currency: String
    let exchange: String?
    let securityType: String?
    
    /// Market value (quantity × current price)
    var marketValue: Double {
        guard let price = currentPrice else { return 0 }
        return quantity * price
    }
    
    /// Cost basis (quantity × average cost)
    var costBasis: Double {
        guard let avgCost = averageCost else {
            // If no cost basis, estimate from current price
            return marketValue
        }
        return quantity * avgCost
    }
    
    /// Unrealized profit/loss
    var unrealizedPnL: Double {
        marketValue - costBasis
    }
    
    /// Unrealized profit/loss percentage
    var unrealizedPnLPercent: Double {
        guard costBasis > 0 else { return 0 }
        return (unrealizedPnL / costBasis) * 100
    }
    
    var displayName: String {
        description ?? symbol
    }
    
    var isPositive: Bool {
        unrealizedPnL >= 0
    }
}

// MARK: - Mapper Extensions

extension BrokerAccount {
    /// Map from SnapTrade API account to app model
    static func from(snapTradeAccount: SnapTradeAccount) -> BrokerAccount {
        let createdDate: Date? = {
            guard let dateString = snapTradeAccount.createdDate else { return nil }
            let formatter = ISO8601DateFormatter()
            return formatter.date(from: dateString)
        }()
        
        let balance: AccountBalance? = {
            guard let snapBalance = snapTradeAccount.balance else { return nil }
            
            let total: Money? = {
                guard let amount = snapBalance.total?.amount,
                      let currency = snapBalance.total?.currency else { return nil }
                return Money(amount: amount, currency: currency)
            }()
            
            let cash: Money? = {
                guard let amount = snapBalance.cash?.amount,
                      let currency = snapBalance.cash?.currency else { return nil }
                return Money(amount: amount, currency: currency)
            }()
            
            return AccountBalance(total: total, cash: cash)
        }()
        
        return BrokerAccount(
            id: snapTradeAccount.id,
            name: snapTradeAccount.name,
            accountNumber: snapTradeAccount.number,
            institutionName: snapTradeAccount.institutionName,
            accountType: snapTradeAccount.meta?.type,
            balance: balance,
            createdDate: createdDate
        )
    }
}

extension BrokerHolding {
    /// Map from SnapTrade position to app model
    static func from(
        snapTradePosition: SnapTradePosition,
        accountId: String
    ) -> BrokerHolding {
        // Use fractional units if available, otherwise whole units (both may be null)
        let quantity = snapTradePosition.fractionalUnits ?? snapTradePosition.units ?? 0
        
        // Navigate nested BrokerageSymbol → UniversalSymbol for the ticker
        let universalSymbol = snapTradePosition.symbol.symbol

        // Currency: position-level → brokerage symbol → universal symbol
        let positionCurrency = snapTradePosition.currency?.code
        let brokerageCurrency = snapTradePosition.symbol.currency?.code
        let universalCurrency = universalSymbol.currency?.code
        let currency = positionCurrency ?? brokerageCurrency ?? universalCurrency ?? "USD"

        let ticker = universalSymbol.symbol
        let holdingId = "\(accountId)_\(ticker)_\(UUID().uuidString)"

        let description = snapTradePosition.symbol.description ?? universalSymbol.description
        let exchange = snapTradePosition.symbol.exchange?.code ?? universalSymbol.exchange?.code
        let securityType = snapTradePosition.symbol.type?.code ?? universalSymbol.type?.code

        return BrokerHolding(
            id: holdingId,
            accountId: accountId,
            symbol: ticker,
            description: description,
            quantity: quantity,
            currentPrice: snapTradePosition.price,
            averageCost: snapTradePosition.averagePurchasePrice,
            currency: currency,
            exchange: exchange,
            securityType: securityType
        )
    }
}
