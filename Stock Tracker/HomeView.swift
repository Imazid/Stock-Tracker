//
//  HomeView.swift
//  Stock Tracker
//

import SwiftUI

struct HomeView: View {
    @EnvironmentObject var marketData: MarketData
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Header Greeting
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Good \(greeting()),")
                            .font(.title2)
                            .fontWeight(.medium)
                            .foregroundColor(.white.opacity(0.9))
                        
                        Text("Here's your market overview")
                            .font(.title.bold())
                            .foregroundColor(.white)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    
                    // Total Portfolio Value Card
                    if marketData.totalPortfolioValue > 0 {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Total Portfolio Value")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.7))
                            
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(marketData.totalPortfolioValue, format: .currency(code: "USD"))
                                    .font(.system(size: 42, weight: .bold))
                                    .foregroundColor(.white)
                                
                                if marketData.totalProfitLoss != 0 {
                                    Text(marketData.totalProfitLoss > 0 ? "+" : "")
                                        .foregroundColor(marketData.totalProfitLoss > 0 ? .green : .red)
                                    +
                                    Text(marketData.totalProfitLoss, format: .currency(code: "USD"))
                                        .foregroundColor(marketData.totalProfitLoss > 0 ? .green : .red)
                                    +
                                    Text(" (\(marketData.totalProfitLossPercent > 0 ? "+" : "")\(String(format: "%.2f", marketData.totalProfitLossPercent))%)")
                                        .foregroundColor(marketData.totalProfitLoss > 0 ? .green : .red)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(16)
                        .padding(.horizontal)
                    }
                    
                    // Quick Actions
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 16) {
                        QuickActionButton(title: "Add Stock", icon: "plus.circle.fill", color: .blue) {
                            // Will be handled by parent
                        }
                        QuickActionButton(title: "Price Alerts", icon: "bell.fill", color: .purple) {
                            // Open alerts
                        }
                    }
                    .padding(.horizontal)
                    
                    // Watchlist Preview
                    if !marketData.watchlist.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Your Watchlist")
                                    .font(.title3.bold())
                                    .foregroundColor(.white)
                                Spacer()
                                NavigationLink("See All") {
                                    AppleStocksWatchlistView()
                                }
                                .foregroundColor(.blue)
                            }
                            
                            ForEach(marketData.watchlist.prefix(5)) { asset in
                                WatchlistRowPreview(asset: asset)
                                    .padding(.vertical, 4)
                            }
                        }
                        .padding(.horizontal)
                    }
                    
                    Spacer(minLength: 100)
                }
                .padding(.top)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    private func greeting() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 0..<12:  return "Morning"
        case 12..<17: return "Afternoon"
        default:      return "Evening"
        }
    }
}

// Mini preview row
struct WatchlistRowPreview: View {
    let asset: Asset
    
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(asset.symbol)
                    .font(.headline)
                    .foregroundColor(.white)
                Text(asset.name)
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text(asset.price, format: .currency(code: "USD"))
                    .font(.headline)
                    .foregroundColor(.white)
                Text(String(format: "%+.2f%%", asset.changePercent))
                    .font(.caption)
                    .foregroundColor(asset.changePercent > 0 ? .green : .red)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
    }
}

struct QuickActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 32))
                    .foregroundColor(color)
                Text(title)
                    .font(.caption.bold())
                    .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .background(Color.white.opacity(0.08))
            .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }
}