//
//  WidgetDeepLinks.swift
//  Stock Tracker Widget
//
//  All URL scheme constants used by widget tap targets.
//  Handled in Stock_TrackerApp via .onOpenURL { }.
//

import Foundation

enum WidgetDeepLink {
    static let portfolio = URL(string: "stocktracker://portfolio")!
    static let watchlist = URL(string: "stocktracker://watchlist")!
    static let paywall   = URL(string: "stocktracker://paywall")!
    static let home      = URL(string: "stocktracker://home")!

    static let news     = URL(string: "stocktracker://news")!
    static let calendar = URL(string: "stocktracker://calendar")!

    static func asset(_ symbol: String) -> URL {
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        return URL(string: "stocktracker://asset/\(encoded)") ?? portfolio
    }

    static func trade(_ symbol: String) -> URL {
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        return URL(string: "stocktracker://trade/\(encoded)") ?? portfolio
    }
}
