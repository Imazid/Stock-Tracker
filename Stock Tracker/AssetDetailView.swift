import SwiftUI
import Charts

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
                              let avgCost = Double(avgCostText), shares > 0, avgCost > 0 else { return }
                        marketData.addToPortfolio(asset: asset, shares: shares, avgCost: avgCost)
                        dismiss()
                    }
                    .disabled(sharesText.isEmpty || avgCostText.isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct AssetDetailView: View {
    @EnvironmentObject var marketData: MarketData
    @Environment(\.dismiss) var dismiss
    
    let asset: Asset
    @State private var selectedRange: TimeRange = .oneMonth
    @State private var priceHistory: [PricePoint] = []
    @State private var showAddToPortfolio = false
    @State private var showAddAlert = false
    @State private var selectedPrice: PricePoint?
    @State private var isLoading = false
    
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(red: 0.05, green: 0.05, blue: 0.10)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    headerSection
                    chartSection
                    statsSection
                    portfolioSection
                    newsSection
                }
                .padding()
            }
        }
        .task {
            await loadPriceHistory()
        }
        .onChange(of: selectedRange) { oldValue, newValue in
            Task { await loadPriceHistory() }
        }
        .sheet(isPresented: $showAddToPortfolio) {
            AddToPortfolioSheet(asset: asset)
        }
        .sheet(isPresented: $showAddAlert) {
            AddPriceAlertSheet(asset: asset)
        }
        .preferredColorScheme(.dark)
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
                    Text(formatPrice(selectedPrice?.price ?? asset.price))
                        .font(.title2.bold())
                        .foregroundColor(.white)
                    
                    if selectedPrice == nil {
                        HStack(spacing: 4) {
                            Image(systemName: asset.isPositive ? "arrow.up.right" : "arrow.down.right")
                            Text(formatChange(asset.change, asset.changePercent))
                        }
                        .font(.caption)
                        .foregroundColor(asset.isPositive ? .green : .red)
                    } else {
                        Text(selectedPrice!.date, style: .date)
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
            }
        }
    }
    
    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Price History")
                .font(.headline)
                .foregroundColor(.white)
            
            if isLoading {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.05))
                    .frame(height: 300)
                    .overlay(
                        ProgressView()
                            .tint(.white)
                    )
            } else if priceHistory.isEmpty {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.05))
                    .frame(height: 300)
                    .overlay(
                        VStack {
                            Image(systemName: "chart.xyaxis.line")
                                .font(.largeTitle)
                                .foregroundColor(.gray)
                            Text("No data available")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    )
            } else {
                interactiveChart
                    .frame(height: 300)
            }
            
            timeRangeSelector
        }
    }
    
    private var interactiveChart: some View {
        let minPrice = priceHistory.map { $0.price }.min() ?? 0
        let maxPrice = priceHistory.map { $0.price }.max() ?? 1
        let padding = (maxPrice - minPrice) * 0.1
        
        return Chart(priceHistory) { point in
            LineMark(
                x: .value("Date", point.date),
                y: .value("Price", point.price)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [.blue, .cyan],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .chartYScale(domain: minPrice - padding ... maxPrice + padding)
        .chartXAxis {
            AxisMarks(position: .bottom)
        }
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .foregroundColor(.white)
        .background(Color.white.opacity(0.05))
        .cornerRadius(16)
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
                            .background(selectedRange == range ? Color.blue : Color.gray.opacity(0.2))
                            .cornerRadius(20)
                    }
                    .foregroundColor(.white)
                }
            }
        }
    }
    
    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Statistics")
                .font(.headline)
                .foregroundColor(.white)
            
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 16) {
                StatCard(title: "Market Cap", value: formatLargeNumber(asset.marketCap ?? 0))
                StatCard(title: "P/E Ratio", value: String(format: "%.2f", asset.peRatio ?? 0))
                StatCard(title: "EPS", value: String(format: "%.2f", asset.eps ?? 0))
                StatCard(title: "52W High", value: String(format: "%.2f", asset.week52High ?? 0))
                StatCard(title: "52W Low", value: String(format: "%.2f", asset.week52Low ?? 0))
                StatCard(title: "Volume", value: formatVolume(asset.volume))
                StatCard(title: "Avg Volume", value: formatVolume(asset.avgVolume ?? 0))
                StatCard(title: "Dividend", value: String(format: "%.2f", asset.dividend ?? 0))
                StatCard(title: "Beta", value: String(format: "%.2f", asset.beta ?? 0))
            }
        }
    }
    
    private var portfolioSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Portfolio Actions")
                .font(.headline)
                .foregroundColor(.white)
            
            Button("Add to Portfolio") {
                showAddToPortfolio = true
            }
            .font(.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.blue)
            .cornerRadius(12)
            
            Button("Set Price Alert") {
                showAddAlert = true
            }
            .font(.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.green)
            .cornerRadius(12)
        }
    }
    
    private var newsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Related News")
                .font(.headline)
                .foregroundColor(.white)
            
            ForEach(marketData.newsArticles.filter { $0.relatedSymbols.contains(asset.symbol) }) { article in
                NewsCard(article: article)
            }
        }
    }
    
    private func loadPriceHistory() async {
        isLoading = true
        priceHistory = await marketData.fetchPriceHistory(for: asset, range: selectedRange)
        isLoading = false
    }
    
    // Formatting functions (from your original code)
    private func formatPrice(_ price: Double) -> String {
        return String(format: "$%.2f", price)
    }
    
    private func formatChange(_ change: Double, _ percent: Double) -> String {
        let sign = change >= 0 ? "+" : ""
        let changeStr = String(format: "%.2f", abs(change))
        let percentStr = String(format: "%.2f", abs(percent))
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
        let valueStr = String(format: "%.2f", abs(value))
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
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )
        )
    }
}
