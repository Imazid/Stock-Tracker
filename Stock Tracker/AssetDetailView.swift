import SwiftUI
import Charts

struct AssetDetailView: View {
    @EnvironmentObject var marketData: MarketData
    @Environment(\.dismiss) var dismiss
    
    let asset: Asset
    @State private var selectedRange: TimeRange = .oneMonth
    @State private var priceHistory: [PricePoint] = []
    @State private var showAddToPortfolio = false
    @State private var showAddAlert = false
    
    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.black,
                    Color(red: 15/255, green: 23/255, blue: 42/255)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    headerSection
                    chartSection
                    statisticsSection
                    portfolioPositionSection
                }
                .padding()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showAddToPortfolio = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.white)
                }
            }
        }
        .sheet(isPresented: $showAddToPortfolio) {
            AddToPortfolioSheet(asset: asset)
        }
        .task {
            loadPriceHistory()
        }
        .onChange(of: selectedRange) { _, _ in
            loadPriceHistory()
        }
    }
    
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ZStack {
                    Circle()
                        .fill(Color(red: 0.2, green: 0.3, blue: 0.5))
                        .frame(width: 60, height: 60)
                    Text(String(asset.symbol.prefix(1)))
                        .font(.title.bold())
                        .foregroundColor(.white)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(asset.symbol)
                        .font(.title2.bold())
                        .foregroundColor(.white)
                    Text(asset.name)
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    Text(formatPrice(asset.price))
                        .font(.title2.bold())
                        .foregroundColor(.white)
                    HStack(spacing: 4) {
                        Image(systemName: asset.isPositive ? "arrow.up.right" : "arrow.down.right")
                        Text(formatChange(asset.change, asset.changePercent))
                    }
                    .font(.caption)
                    .foregroundColor(asset.isPositive ? .green : .red)
                }
            }
        }
    }
    
    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Price History")
                .font(.headline)
                .foregroundColor(.white)
            
            if priceHistory.isEmpty {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.05))
                    .frame(height: 250)
                    .overlay(
                        ProgressView()
                            .tint(.white)
                    )
            } else {
                Chart(priceHistory) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Price", point.price)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .cyan],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    
                    AreaMark(
                        x: .value("Date", point.date),
                        y: .value("Price", point.price)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue.opacity(0.3), .cyan.opacity(0.1)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
                .chartXAxis {
                    AxisMarks(values: .automatic) { _ in
                        AxisValueLabel()
                            .foregroundStyle(.gray)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing) { _ in
                        AxisValueLabel()
                            .foregroundStyle(.gray)
                    }
                }
                .frame(height: 250)
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.white.opacity(0.05))
                )
            }
            
            timeRangeSelector
        }
    }
    
    private var timeRangeSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TimeRange.allCases, id: \.self) { range in
                    Button {
                        selectedRange = range
                    } label: {
                        Text(range.rawValue)
                            .font(.caption.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(selectedRange == range ? Color.white.opacity(0.2) : Color.white.opacity(0.05))
                            )
                            .foregroundColor(.white)
                    }
                }
            }
        }
    }
    
    private var statisticsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Key Statistics")
                .font(.headline)
                .foregroundColor(.white)
            
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                if let marketCap = asset.marketCap {
                    StatCard(title: "Market Cap", value: formatLargeNumber(marketCap))
                }
                if let peRatio = asset.peRatio {
                    StatCard(title: "P/E Ratio", value: String(format: "%.2f", peRatio))
                }
                if let eps = asset.eps {
                    StatCard(title: "EPS (TTM)", value: String(format: "$%.2f", eps))
                }
                if let high = asset.week52High {
                    StatCard(title: "52W High", value: String(format: "$%.2f", high))
                }
                if let low = asset.week52Low {
                    StatCard(title: "52W Low", value: String(format: "$%.2f", low))
                }
                StatCard(title: "Volume", value: formatVolume(asset.volume))
                if let avgVol = asset.avgVolume {
                    StatCard(title: "Avg Volume", value: formatVolume(avgVol))
                }
                if let beta = asset.beta {
                    StatCard(title: "Beta", value: String(format: "%.2f", beta))
                }
                if let dividend = asset.dividend {
                    StatCard(title: "Dividend", value: String(format: "$%.2f", dividend))
                }
            }
        }
    }
    
    @ViewBuilder
    private var portfolioPositionSection: some View {
        let holdings = marketData.portfolio.filter { $0.asset.symbol == asset.symbol }
        if let holding = holdings.first {
            positionSection(holding: holding)
        }
    }
    
    private func positionSection(holding: PortfolioHolding) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your Position")
                .font(.headline)
                .foregroundColor(.white)
            
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Shares")
                            .font(.caption)
                            .foregroundColor(.gray)
                        Text(String(format: "%.2f", holding.shares))
                            .font(.title3.bold())
                            .foregroundColor(.white)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Avg Cost")
                            .font(.caption)
                            .foregroundColor(.gray)
                        Text(String(format: "$%.2f", holding.avgCost))
                            .font(.title3.bold())
                            .foregroundColor(.white)
                    }
                }
                
                Divider()
                    .background(Color.white.opacity(0.2))
                
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Market Value")
                            .font(.caption)
                            .foregroundColor(.gray)
                        Text(String(format: "$%.2f", holding.currentValue))
                            .font(.title3.bold())
                            .foregroundColor(.white)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Total P/L")
                            .font(.caption)
                            .foregroundColor(.gray)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(formatProfitLoss(holding.profitLoss))
                                .font(.title3.bold())
                                .foregroundColor(holding.profitLoss >= 0 ? .green : .red)
                            Text(formatPercent(holding.profitLossPercent))
                                .font(.caption)
                                .foregroundColor(holding.profitLoss >= 0 ? .green : .red)
                        }
                    }
                }
                
                Text("Added on \(holding.dateAdded.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2)
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.black.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            )
        }
    }
    
    private func loadPriceHistory() {
        Task {
            // call the async API-backed method on the actual environment object
            let history = await marketData.fetchPriceHistory(for: asset, range: selectedRange)
            
            // update the local @State on the main actor
            await MainActor.run {
                self.priceHistory = history
            }
        }
    }

    
    private func formatPrice(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }
    
    private func formatChange(_ change: Double, _ percent: Double) -> String {
        let sign = change >= 0 ? "+" : ""
        let changeStr = String(format: "%.2f", change)
        let percentStr = String(format: "%.2f", percent)
        return "\(sign)\(changeStr) (\(sign)\(percentStr)%)"
    }
    
    private func formatProfitLoss(_ value: Double) -> String {
        let sign = value >= 0 ? "+" : ""
        let absValue = abs(value)
        let valueStr = String(format: "%.2f", absValue)
        return "\(sign)$\(valueStr)"
    }
    
    private func formatPercent(_ value: Double) -> String {
        let sign = value >= 0 ? "+" : ""
        let valueStr = String(format: "%.2f", value)
        return "\(sign)\(valueStr)%"
    }
    
    private func formatLargeNumber(_ value: Double) -> String {
        if value >= 1_000_000_000_000 {
            let result = value / 1_000_000_000_000
            return String(format: "$%.2fT", result)
        } else if value >= 1_000_000_000 {
            let result = value / 1_000_000_000
            return String(format: "$%.2fB", result)
        } else if value >= 1_000_000 {
            let result = value / 1_000_000
            return String(format: "$%.2fM", result)
        }
        return String(format: "$%.2f", value)
    }
    
    private func formatVolume(_ value: Double) -> String {
        if value >= 1_000_000_000 {
            let result = value / 1_000_000_000
            return String(format: "%.2fB", result)
        } else if value >= 1_000_000 {
            let result = value / 1_000_000
            return String(format: "%.2fM", result)
        } else if value >= 1_000 {
            let result = value / 1_000
            return String(format: "%.2fK", result)
        }
        return String(format: "%.0f", value)
    }
}

struct StatCard: View {
    let title: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundColor(.gray)
            Text(value)
                .font(.headline)
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.05))
        )
    }
}

struct AddToPortfolioSheet: View {
    @EnvironmentObject var marketData: MarketData
    @Environment(\.dismiss) var dismiss
    
    let asset: Asset
    @State private var sharesText = ""
    @State private var avgCostText = ""
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                
                Form {
                    Section {
                        HStack {
                            Text(asset.symbol)
                                .font(.headline)
                            Spacer()
                            Text(asset.name)
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                    
                    Section(header: Text("Position Details")) {
                        TextField("Number of shares", text: $sharesText)
                            .keyboardType(.decimalPad)
                        TextField("Average cost per share", text: $avgCostText)
                            .keyboardType(.decimalPad)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Add to Portfolio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let shares = Double(sharesText),
                              let avgCost = Double(avgCostText) else { return }
                        marketData.addToPortfolio(asset: asset, shares: shares, avgCost: avgCost)
                        dismiss()
                    }
                }
            }
        }
    }
}
