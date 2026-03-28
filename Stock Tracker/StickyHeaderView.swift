//
//  StickyHeaderView.swift
//  Stock Tracker
//
//  Created by Ihtisham Mazid on 24/1/2026.
//


//
//  StickyHeaderView.swift
//  Stock Tracker
//

import SwiftUI

struct StickyHeaderView: View {
    let stock: DetailedStock

    @Environment(\.theme) var appTheme
    @EnvironmentObject var marketData: MarketData

    var body: some View {
        let changeColor: Color = stock.isPositive ? appTheme.positiveColor : appTheme.negativeColor

        HStack(alignment: .center, spacing: 12) {
            // Symbol
            Text(stock.symbol)
                .font(.headline.weight(.bold))

            Spacer()

            // Price
            Text(stock.currentPrice.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                .font(.body.weight(.semibold))
                .monospacedDigit()

            // Change pill
            HStack(spacing: 4) {
                Image(systemName: stock.isPositive ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption.weight(.semibold))
                Text(String(format: stock.isPositive ? "+%.2f%%" : "%.2f%%", stock.dayChangePercent))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }
            .foregroundColor(changeColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(changeColor.opacity(0.12))
            .cornerRadius(6)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(
            .ultraThinMaterial,
            in: Rectangle()
        )
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(Color.secondary.opacity(0.2)),
            alignment: .bottom
        )
    }
}