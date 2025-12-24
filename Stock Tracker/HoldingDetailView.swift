//
//  HoldingDetailView.swift
//  Stock Tracker
//

import SwiftUI

struct HoldingDetailView: View {
    let holding: PortfolioHolding
    @EnvironmentObject var marketData: MarketData
    @Environment(\.dismiss) var dismiss
    
    @State private var selectedTab: Tab = .general
    @State private var showAddShares = false
    @State private var additionalShares: Double = 1.0
    @State private var showBreakdown = false
    @State private var showNewTransaction = false
    
    enum Tab: String, CaseIterable {
        case general = "General"
        case transactions = "Transactions"
    }
    
    private var isPositive: Bool { holding.profitLoss >= 0 }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // MARK: - Header Section
                VStack(spacing: 16) {
                    Text(holding.asset.symbol)
                        .font(.largeTitle.bold())
                        .foregroundColor(.white)
                    
                    Text(holding.asset.name)
                        .font(.title3)
                        .foregroundColor(.white.opacity(0.8))
                    
                    HStack(spacing: 12) {
                        Text("Owned")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.7))
                        
                        Text("\(holding.shares, specifier: "%.0f")")
                            .font(.title2.bold())
                            .foregroundColor(.white)
                    }
                    
                    HStack(spacing: 32) {
                        VStack {
                            Text("Market Value")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.7))
                            Text(holding.currentValue.formattedPrice(in: marketData.preferredCurrency))
                                .font(.title.bold())
                                .foregroundColor(.white)
                        }
                        
                        VStack {
                            Text(isPositive ? "Total Gain" : "Total Loss")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.7))
                            Text(holding.profitLoss.formattedPrice(in: marketData.preferredCurrency))
                                .font(.title.bold())
                                .foregroundColor(isPositive ? .green : .red)
                        }
                    }
                    
                    // Cost & Gains Breakdown Toggle
                    Button {
                        withAnimation(.easeInOut) {
                            showBreakdown.toggle()
                        }
                    } label: {
                        HStack {
                            Image(systemName: "chevron.right")
                                .rotationEffect(.degrees(showBreakdown ? 90 : 0))
                            Text("Show Cost & Gains Breakdown")
                                .font(.headline)
                        }
                        .foregroundColor(.yellow)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.yellow.opacity(0.2))
                        .cornerRadius(12)
                    }
                    .padding(.top, 8)
                    
                    if showBreakdown {
                        VStack(alignment: .leading, spacing: 12) {
                            DetailRow(title: "Sum of Cost", value: (holding.shares * holding.avgCost).formattedPrice(in: marketData.preferredCurrency))
                            DetailRow(title: "Total Fees", value: "-")
                            DetailRow(title: "Dividends", value: "-")
                        }
                        .padding()
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(12)
                    }
                }
                .padding()
                .background(Color.black)
                
                // MARK: - Tab Selector
                Picker("View", selection: $selectedTab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                
                // MARK: - Tab Content
                if selectedTab == .general {
                    VStack(spacing: 20) {
                        Text("General Overview")
                            .font(.title2)
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.top, 20)
                        
                        // You can add more general stats here later
                        Spacer()
                    }
                } else {
                    if holding.transactions.isEmpty {
                        VStack(spacing: 20) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 60))
                                .foregroundColor(.gray.opacity(0.5))
                            Text("No transactions yet")
                                .font(.title3)
                                .foregroundColor(.white.opacity(0.8))
                            Text("Add your first transaction to see history")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                        }
                        .padding(.top, 60)
                    } else {
                        List {
                            ForEach(holding.transactions) { transaction in
                                TransactionRow(transaction: transaction)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
                
                Spacer()
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Holding Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .font(.headline)
                        .foregroundColor(.white)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Button {
                    showNewTransaction = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 70, height: 70)
                        .background(Color.green)
                        .clipShape(Circle())
                        .shadow(color: .green.opacity(0.6), radius: 15)
                }
                .padding()
            }
            .sheet(isPresented: $showNewTransaction) {
                NewTransactionSheet(holding: holding)
            }
            .sheet(isPresented: $showAddShares) {
                AddSharesSheet(holding: holding, additionalShares: $additionalShares)
            }
        }
    }
}

// MARK: - Detail Row (for breakdown and details)
struct DetailRow: View {
    let title: String
    let value: String
    
    var body: some View {
        HStack {
            Text(title)
                .font(.body)
                .foregroundColor(.white.opacity(0.8))
            
            Spacer()
            
            Text(value)
                .font(.body.bold())
                .foregroundColor(.white)
        }
        .padding(16)
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
    }
}

// MARK: - Transaction Row
struct TransactionRow: View {
    let transaction: Transaction
    @EnvironmentObject var marketData: MarketData
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(transaction.type == .buy ? "Buy" : "Sell")
                    .font(.headline)
                    .foregroundColor(transaction.type == .buy ? .green : .red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(transaction.type == .buy ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                    .cornerRadius(8)
                
                Text(transaction.date, format: .dateTime.day().month(.abbreviated).year())
                    .foregroundColor(.white.opacity(0.8))
                
                Spacer()
            }
            
            HStack {
                Text("Price: \(transaction.pricePerShare.formattedPrice(in: marketData.preferredCurrency))")
                Spacer()
                Text("Shares: \(transaction.shares, specifier: "%.2f")")
            }
            .foregroundColor(.white.opacity(0.7))
            
            HStack {
                Text("Cost: \((transaction.pricePerShare * transaction.shares).formattedPrice(in: marketData.preferredCurrency))")
                Spacer()
                Text("Delta: -1.88%") // Placeholder — calculate real delta later
                    .foregroundColor(.red)
            }
            .foregroundColor(.white.opacity(0.7))
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
    }
}

// MARK: - Add Shares Sheet
struct AddSharesSheet: View {
    let holding: PortfolioHolding
    @Binding var additionalShares: Double
    @EnvironmentObject var marketData: MarketData
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Text("Add Shares to \(holding.asset.symbol)")
                    .font(.title2.bold())
                    .foregroundColor(.white)
                
                VStack(spacing: 20) {
                    Text("Current Price: \(holding.asset.price.formattedPrice(in: marketData.preferredCurrency))")
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.8))
                    
                    Slider(value: $additionalShares, in: 0.1...100, step: 0.1)
                        .tint(.green)
                    
                    Text("\(additionalShares, specifier: "%.2f") shares")
                        .font(.largeTitle.bold())
                        .foregroundColor(.white)
                    
                    Text("Cost: \((holding.asset.price * additionalShares).formattedPrice(in: marketData.preferredCurrency))")
                        .font(.title3)
                        .foregroundColor(.green)
                }
                .padding()
                .background(Color.white.opacity(0.08))
                .cornerRadius(20)
                
                Button("Confirm Add") {
                    //$marketData.addShares(to: holding, shares: additionalShares, atPrice: holding.asset.price)
                    dismiss()
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding()
                .frame(maxWidth: .infinity)
                .background(.blue)
                .cornerRadius(20)
                .padding(.horizontal)
            }
            .padding()
            .background(Color.black)
            .navigationTitle("Add Shares")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - New Transaction Sheet (placeholder for full form)
struct NewTransactionSheet: View {
    let holding: PortfolioHolding
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 30) {
                Text("New Transaction")
                    .font(.largeTitle.bold())
                    .foregroundColor(.white)
                
                Text("Full transaction form coming soon...")
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.7))
                
                Spacer()
            }
            .padding()
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("New Transaction")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    HoldingDetailView(holding: PortfolioHolding(
        asset: Asset(symbol: "AMD", name: "Advanced Micro Devices", price: 213.45, change: -4.28, changePercent: -1.97, volume: 45000000, kind: .stock, exchange: "NASDAQ"),
        shares: 50.0,
        avgCost: 217.53,
        transactions: [] // Empty for preview
    ))
    .environmentObject(MarketData())
    .preferredColorScheme(.dark)
}
