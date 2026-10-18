//
//  FXRates.swift
//  Stock Tracker
//
//  The app's money invariant: every stored price, cost and value is in USD,
//  and `formattedPrice(in:rates:)` converts to the person's currency only for
//  display. Quotes that arrive in another currency (Yahoo returns ASX in AUD)
//  must be converted to USD on the way in — otherwise they get converted a
//  second time on screen (BHP at A$60 showed as A$90).
//
//  `MarketData` owns the live rates; this mirror lets the network layer read
//  them without reaching into a MainActor object.
//

import Foundation

final class FXRates: @unchecked Sendable {
    static let shared = FXRates()

    private let lock = NSLock()
    /// Units of each currency per 1 USD (e.g. "AUD": 1.505).
    private var perUSD: [String: Double] = ["USD": 1.0, "AUD": 1.505]

    func update(_ rates: [String: Double]) {
        lock.lock(); defer { lock.unlock() }
        for (code, rate) in rates where rate > 0 { perUSD[code.uppercased()] = rate }
        perUSD["USD"] = 1.0
    }

    /// Multiplier that turns an amount in `currency` into USD, or nil if unknown.
    func toUSDFactor(from currency: String) -> Double? {
        let code = currency.uppercased()
        if code.isEmpty || code == "USD" { return 1.0 }
        lock.lock(); defer { lock.unlock() }
        guard let rate = perUSD[code], rate > 0 else { return nil }
        return 1.0 / rate
    }

    func rate(for currency: String) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return perUSD[currency.uppercased()]
    }
}
