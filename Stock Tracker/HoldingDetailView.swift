//
//  HoldingDetailView.swift
//  Stock Tracker
//

import SwiftUI

struct HoldingDetailView: View {
    let holding: PortfolioHolding
    @EnvironmentObject var marketData: MarketData
    @Environment(\.dismiss) var dismiss
    
    private var isPositive: Bool { holding.profitLoss >= 0 }
    private var accentColor: Color { isPositive ? .green : .red }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        // Header with symbol and arrow
                        VStack(spacing: 12) {
                            HStack {
                                Text(holding.asset.symbol)
                                    .font(.largeTitle.bold())
                                    .foregroundColor(.white)
                                
                                Image(systemName: holding.asset.change >= 0 ? "arrow.up.right" : "arrow.down.right")
                                    .font(.title2.bold())
                                    .foregroundColor(holding.asset.change >= 0 ? .green : .red)
                            }
                            
                            Text(holding.asset.name)
                                .font(.subheadline)
                                .foregroundColor(.gray)
                        }
                        .padding(.top, 20)
                        
                        // Key Metrics Grid
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                            MetricCard(title: "Exchange", value: holding.asset.exchange ?? "N/A")  // Assume exchange added to Asset model
                            MetricCard(title: "Currency", value: marketData.preferredCurrency)
                            MetricCard(title: "Units Purchased", value: "\(holding.shares, specifier: "%.2f")")
                            MetricCard(title: "Purchase Price", value: holding.avgCost.formattedPrice(in: marketData.preferredCurrency))
                            MetricCard(title: "Last Price", value: holding.asset.price.formattedPrice(in: marketData.preferredCurrency))
                            MetricCard(title: "Market Value", value: holding.currentValue.formattedPrice(in: marketData.preferredCurrency))
                            MetricCard(title: "Profit/Loss", value: holding.profitLoss.formattedPrice(in: marketData.preferredCurrency), color: accentColor)
                            MetricCard(title: "P/L %", value: "\(holding.profitLossPercent >= 0 ? "+" : "")\(String(format: "%.2f", holding.profitLossPercent))%", color: accentColor)
                            MetricCard(title: "Today's Change", value: holding.asset.change.formattedPrice(in: marketData.preferredCurrency), color: holding.asset.change >= 0 ? .green : .red)
                            MetricCard(title: "Today's %", value: "\(holding.asset.changePercent >= 0 ? "+" : "")\(String(format: "%.2f", holding.asset.changePercent))%", color: holding.asset.change >= 0 ? .green : .red)
                        }
                        .padding(.horizontal)
                    }
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("Holding Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// Simple Metric Card
struct MetricCard: View {
    let title: String
    let value: String
    var color: Color = .white
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.bold())
                .foregroundColor(.gray)
            
            Text(value)
                .font(.headline.bold())
                .foregroundColor(color)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }
}

#Preview {
    HoldingDetailView(holding: PortfolioHolding(asset: Asset(symbol: "AAPL", name: "Apple Inc.", price: 178.42, change: 3.21, changePercent: 1.83, volume: 89200000, kind: .stock), shares: 10.0, avgCost: 150.0))
        .environmentObject(MarketData())
        .preferredColorScheme(.dark)
}