//
//  AppLogger.swift
//  Stock Tracker
//
//  Structured logging via OSLog. Use these loggers instead of print().
//  Logs are visible in Console.app and Instruments in both Debug and Release.
//  Sensitive fields (keys, tokens) must NOT be passed to log functions — use
//  the redact() helper in SecurityManager if needed.
//
//  Usage:
//    AppLogger.api.info("Fetching quotes for \(symbol)")
//    AppLogger.portfolio.error("Decode failed: \(error)")
//

import OSLog

enum AppLogger {

    // MARK: - Subsystem

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.stocktracker"

    // MARK: - Categories

    /// Networking and API calls.
    static let api       = Logger(subsystem: subsystem, category: "API")
    /// Portfolio calculations and mutations.
    static let portfolio = Logger(subsystem: subsystem, category: "Portfolio")
    /// News fetching and display.
    static let news      = Logger(subsystem: subsystem, category: "News")
    /// StoreKit / subscription events.
    static let store     = Logger(subsystem: subsystem, category: "Store")
    /// Data persistence (UserDefaults, Keychain).
    static let persist   = Logger(subsystem: subsystem, category: "Persistence")
    /// Security events (jailbreak, biometrics, auth).
    static let security  = Logger(subsystem: subsystem, category: "Security")
    /// Refresh scheduler.
    static let refresh   = Logger(subsystem: subsystem, category: "Refresh")
    /// General / uncategorised.
    static let general   = Logger(subsystem: subsystem, category: "General")
    /// Search flow.
    static let search    = Logger(subsystem: subsystem, category: "Search")
    /// Supabase cloud sync.
    static let sync      = Logger(subsystem: subsystem, category: "Sync")
}
