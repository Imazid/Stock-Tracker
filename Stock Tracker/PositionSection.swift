//
//  PositionSection.swift
//  Stock Tracker
//
//  Created by Ihtisham Mazid on 24/1/2026.
//


//
//  PositionSection.swift
//  Stock Tracker
//

import SwiftUI

struct PositionSection: View {
    let stock: DetailedStock
    let position: StockPosition

    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme
    @EnvironmentObject var marketData: MarketData

    private var unrealizedGL: Double {
        position.unrealizedGainLoss(at: stock.currentPrice)
    }

    private var unrealizedGLPercent: Double {
        position.unrealizedGainLossPercent(at: stock.currentPrice)
    }

    private var isPositive: Bool { unrealizedGL >= 0 }

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        let glColor: Color = isPositive ? appTheme.positiveColor : appTheme.negativeColor

        VStack(alignment: .leading, spacing: 0) {
            // Section Header
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: "person.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.blue)
                }
                Text("Your Position")
                    .font(.headline.weight(.semibold))
                Spacer()
            }
            .padding(.bottom, 16)

            // Main Metrics
            VStack(spacing: 0) {
                // Market Value row
                HStack {
                    Text("Market Value")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(position.currentValue(at: stock.currentPrice).formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                }
                .padding(.bottom, 14)

                Divider()
                    .padding(.bottom, 14)

                // Unrealized G/L row
                HStack {
                    Text("Unrealized G/L")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 5) {
                        Text((unrealizedGL >= 0 ? "+" : "") + unrealizedGL.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                            .font(.body.weight(.bold))
                            .monospacedDigit()
                            .foregroundColor(glColor)
                        Text(String(format: isPositive ? "+%.2f%%" : "%.2f%%", unrealizedGLPercent))
                            .font(.caption.weight(.semibold))
                            .foregroundColor(glColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(glColor.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(18)
        .background(theme.glassBackground)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(glColor.opacity(0.35), lineWidth: 1.5)
        )
    }
}
