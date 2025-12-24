import SwiftUI
import Charts

struct AppleStocksDetailView: View {
    @EnvironmentObject var marketData: MarketData
    @Environment(\.dismiss) var dismiss
    
    let asset: Asset
    @State private var selectedRange: TimeRange = .oneDay
    @State private var priceHistory: [PricePoint] = []
    @State private var isLoading = false
    @State private var selectedPrice: PricePoint?
    
    var body: some View {
        ZStack {
            Color(red: 0.11, green: 0.11, blue: 0.12).ignoresSafeArea()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Top ticker
                    topTicker
                        .padding(.top, 8)
                    
                    // Close button and share
                    topButtons
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                    
                    // Symbol and company name
                    headerInfo
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                    
                    // Price info
                    priceSection
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                    
                    // Time range selector
                    timeRangeSelector
                        .padding(.horizontal, 20)
                        .padding(.top, 24)
                    
                    // Chart
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                            .frame(height: 300)
                    } else {
                        chartView
                            .frame(height: 300)
                    }
                    
                    // Stats grid
                    statsGrid
                        .padding(.horizontal, 20)
                        .padding(.top, 24)
                    
                    // News section
                    newsSection
                        .padding(.top, 32)
                }
            }
        }
        .task {
            await loadPriceHistory()
        }
        .onChange(of: selectedRange) { _, _ in
            Task { await loadPriceHistory() }
        }
    }
    
    private var topTicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 24) {
                ForEach(marketData.watchlist.prefix(5)) { tickerAsset in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tickerAsset.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                        
                        Text(String(format: "%.2f", tickerAsset.price))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                        
                        Text(String(format: "%+.2f%%", tickerAsset.changePercent))
                            .font(.system(size: 13))
                            .foregroundColor(tickerAsset.isPositive ? .green : .red)
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }
    
    private var topButtons: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Circle())
            }
            
            Spacer()
            
            HStack(spacing: 12) {
                Button {
                    // Share action
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                }
                
                Menu {
                    Button("Add to Portfolio") { }
                    Button("Set Alert") { }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                }
            }
        }
    }
    
    private var headerInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(asset.symbol)
                .font(.system(size: 34, weight: .bold))
                .foregroundColor(.white)
            
            Text(asset.name)
                .font(.system(size: 17))
                .foregroundColor(.gray)
        }
    }
    
    private var priceSection: some View {
        HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: "%.2f", selectedPrice?.price ?? asset.price))
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.white)
                
                HStack(spacing: 4) {
                    Text("At Close")
                        .font(.system(size: 13))
                        .foregroundColor(.gray)
                }
                
                Text("NASDAQ · USD")
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
            }
            
            if selectedPrice == nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: "%.2f", asset.price))
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(.white)
                    
                    Text(String(format: "%+.2f%%", asset.changePercent))
                        .font(.system(size: 13))
                        .foregroundColor(asset.isPositive ? .green : .red)
                    
                    Text("Pre-Market")
                        .font(.system(size: 13))
                        .foregroundColor(.gray)
                }
            }
        }
    }
    
    private var timeRangeSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(TimeRange.allCases, id: \.self) { range in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedRange = range
                            selectedPrice = nil
                        }
                    } label: {
                        Text(range.rawValue)
                            .font(.system(size: 15, weight: selectedRange == range ? .semibold : .regular))
                            .foregroundColor(selectedRange == range ? .white : .gray)
                            .frame(width: 50, height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(selectedRange == range ? Color.white.opacity(0.15) : Color.clear)
                            )
                    }
                }
            }
        }
    }
    
    private var chartView: some View {
        GeometryReader { geometry in
            let minPrice = priceHistory.map { $0.price }.min() ?? asset.price
            let maxPrice = priceHistory.map { $0.price }.max() ?? asset.price
            let range = maxPrice - minPrice
            let padding = range * 0.05
            
            ZStack(alignment: .topTrailing) {
                Chart(priceHistory) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Price", point.price)
                    )
                    .foregroundStyle(asset.isPositive ? Color.green : Color.red)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    
                    AreaMark(
                        x: .value("Date", point.date),
                        y: .value("Price", point.price)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                (asset.isPositive ? Color.green : Color.red).opacity(0.3),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    
                    if let selected = selectedPrice, selected.date == point.date {
                        PointMark(
                            x: .value("Date", point.date),
                            y: .value("Price", point.price)
                        )
                        .foregroundStyle(.white)
                        .symbolSize(100)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                        AxisValueLabel()
                            .foregroundStyle(.gray)
                            .font(.system(size: 11))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing) { value in
                        AxisValueLabel()
                            .foregroundStyle(.gray)
                            .font(.system(size: 11))
                    }
                }
                .chartYScale(domain: (minPrice - padding)...(maxPrice + padding))
                .frame(height: 280)
                .padding(.horizontal, 20)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let x = value.location.x
                            let chartWidth = geometry.size.width - 40
                            let percentage = max(0, min(x / chartWidth, 1))
                            let index = Int(percentage * Double(priceHistory.count - 1))
                            if index < priceHistory.count {
                                selectedPrice = priceHistory[index]
                            }
                        }
                        .onEnded { _ in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                withAnimation {
                                    selectedPrice = nil
                                }
                            }
                        }
                )
                
                // Price labels on right
                if let selected = selectedPrice {
                    Text(String(format: "%.2f", selected.price))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.gray.opacity(0.8))
                        .cornerRadius(4)
                        .offset(y: calculateYPosition(for: selected.price, in: geometry, min: minPrice, max: maxPrice))
                        .padding(.trailing, 24)
                }
            }
        }
    }
    
    private func calculateYPosition(for price: Double, in geometry: GeometryProxy, min: Double, max: Double) -> CGFloat {
        let range = max - min
        let percentage = (max - price) / range
        return CGFloat(percentage) * (geometry.size.height - 60)
    }
    
    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
            StatRow(label: "Open", value: String(format: "%.2f", asset.price * 1.001))
            StatRow(label: "High", value: String(format: "%.2f", asset.price * 1.01))
            StatRow(label: "Low", value: String(format: "%.2f", asset.price * 0.995))
            
            StatRow(label: "Vol.", value: formatVolume(asset.volume))
            StatRow(label: "P/E", value: asset.peRatio != nil ? String(format: "%.2f", asset.peRatio!) : "—")
            StatRow(label: "Mkt Cap", value: asset.marketCap != nil ? formatMarketCap(asset.marketCap!) : "—")
            
            StatRow(label: "52W H", value: asset.week52High != nil ? String(format: "%.2f", asset.week52High!) : "—")
            StatRow(label: "52W L", value: asset.week52Low != nil ? String(format: "%.2f", asset.week52Low!) : "—")
            StatRow(label: "Avg Vol", value: asset.avgVolume != nil ? formatVolume(asset.avgVolume!) : "—")
        }
    }
    
    private var newsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("From 🍎News")
                .font(.system(size: 13))
                .foregroundColor(.gray)
                .padding(.horizontal, 20)
            
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.05))
                .frame(height: 150)
                .overlay(
                    Text("News content")
                        .foregroundColor(.gray)
                )
                .padding(.horizontal, 20)
        }
    }
    
    private func loadPriceHistory() async {
        isLoading = true
        priceHistory = await marketData.fetchPriceHistory(for: asset, range: selectedRange)
        isLoading = false
    }
    
    private func formatVolume(_ value: Double) -> String {
        if value >= 1_000_000 {
            return String(format: "%.2fM", value / 1_000_000)
        } else if value >= 1_000 {
            return String(format: "%.2fK", value / 1_000)
        }
        return String(format: "%.0f", value)
    }
    
    private func formatMarketCap(_ value: Double) -> String {
        if value >= 1_000_000_000_000 {
            return String(format: "%.3fT", value / 1_000_000_000_000)
        } else if value >= 1_000_000_000 {
            return String(format: "%.2fB", value / 1_000_000_000)
        }
        return String(format: "%.2fM", value / 1_000_000)
    }
}

struct StatRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 15))
                .foregroundColor(.gray)
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white)
        }
    }
}