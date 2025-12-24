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
    /// Formats a price in the user's preferred currency using live USD→AUD rate
    func formattedPrice(
        in currency: String = "USD",
        usdToAudRate: Double = 1.0
    ) -> String {
        let value = currency == "AUD" ? self * usdToAudRate : self
        
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }
}

// MARK: - Shimmering Skeleton Effect (if not already added)
extension View {
    func shimmering() -> some View {
        self.overlay(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.15))
                .mask(
                    Rectangle()
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [.clear, .white.opacity(0.8), .clear]),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .rotationEffect(.degrees(30))
                        .offset(x: -150)
                        .animation(
                            Animation.linear(duration: 1.8)
                                .repeatForever(autoreverses: false),
                            value: UUID()
                        )
                )
        )
    }
}

// MARK: - Haptic Feedback Helper
enum Haptic {
    static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func medium() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func heavy() { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}