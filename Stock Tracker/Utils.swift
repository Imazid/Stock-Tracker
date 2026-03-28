//
//  Haptic.swift
//  Stock Tracker
//
//  Created by Ihtisham Mazid on 15/12/2025.
//


//
//  Utils.swift
//  Stock Tracker
//

import Foundation
import SwiftUI

// MARK: - Currency Conversion Extension

extension Double {

    /// Converts and formats a USD-denominated value into the target currency.
    /// Returns a symbol-prefixed string: `$200.00`, `€166.00`, `A$301.00`.
    ///
    /// - Parameters:
    ///   - currency: Target ISO 4217 code (e.g. "USD", "AUD", "EUR", "GBP", "JPY", "CAD").
    ///   - rates: Dictionary of rate vs USD (e.g. ["AUD": 1.505, "EUR": 0.92]).
    ///            USD does not need to be listed; it defaults to 1.0.
    func formattedPrice(
        in currency: String = "USD",
        rates: [String: Double] = [:]
    ) -> String {
        let rate = currency == "USD" ? 1.0 : (rates[currency] ?? 1.0)
        let converted = self * rate

        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.locale = Locale.current
        formatter.maximumFractionDigits = currency == "JPY" ? 0 : 2
        formatter.minimumFractionDigits = currency == "JPY" ? 0 : 2

        let symbol = formatter.string(from: NSNumber(value: converted))
            ?? String(format: "%.2f", converted)

        return symbol
    }

    /// Legacy overload so existing call-sites with `usdToAudRate:` still compile.
    /// Prefer `formattedPrice(in:rates:)` or `MarketData.formatPrice(_:)` for new code.
    func formattedPrice(
        in currency: String = "USD",
        usdToAudRate: Double = 1.0
    ) -> String {
        formattedPrice(in: currency, rates: ["AUD": usdToAudRate])
    }
}

extension UserDefaults {
    var hasCompletedOnboarding: Bool {
        get { bool(forKey: "hasCompletedOnboarding") }
        set { set(newValue, forKey: "hasCompletedOnboarding") }
    }
}

//import CryptoKit
//
//extension String {
//    func sha256() -> String {
//        let data = Data(self.utf8)
//        let hashed = SHA256.hash(data: data)
//        return hashed.compactMap { String(format: "%02x", $0) }.joined()
//    }
//}

//// MARK: - Shimmering Skeleton Effect (if not already added)
//extension View {
//    func shimmering() -> some View {
//        self.overlay(
//            RoundedRectangle(cornerRadius: 8)
//                .fill(Color.white.opacity(0.15))
//                .mask(
//                    Rectangle()
//                        .fill(
//                            LinearGradient(
//                                gradient: Gradient(colors: [.clear, .white.opacity(0.8), .clear]),
//                                startPoint: .leading,
//                                endPoint: .trailing
//                            )
//                        )
//                        .rotationEffect(.degrees(30))
//                        .offset(x: -150)
//                        .animation(
//                            Animation.linear(duration: 1.8)
//                                .repeatForever(autoreverses: false),
//                            value: UUID()
//                        )
//                )
//        )
//    }
//}

// MARK: - Haptic Feedback Helper
enum Haptic {
    static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func medium() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func heavy() { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}
