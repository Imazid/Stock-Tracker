//
//  ExchangeHolidays.swift
//  TradingCore
//
//  Full-day closures and early closes for the international venues, from each
//  exchange's published calendar. Placeholder until the verified tables land:
//  with no table, a venue still knows its weekly hours, and an unlisted holiday
//  fails safe (no fresh quotes arrive, so nothing trades).
//

import Foundation

enum ExchangeHolidays {
    /// Venue raw value → full-day closures, "yyyy-MM-dd" in the exchange's own time zone.
    static let closures: [String: Set<String>] = [:]
    /// Venue raw value → early-close days, "yyyy-MM-dd" → last trading time "HH:mm" local.
    static let earlyCloses: [String: [String: String]] = [:]
    /// Venue raw value → the years the tables above are complete for.
    static let coveredYears: [String: ClosedRange<Int>] = [:]
}
