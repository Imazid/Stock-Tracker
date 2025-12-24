//
//  PortfolioView.swift
//  Stock Tracker
//

import SwiftUI
import Charts

struct PortfolioView: View {
    @EnvironmentObject var marketData: MarketData
    
    @State private var selectedFilter: AssetKind = .stock
    @State private var sortBy: SortOption = .valueDescending
    @State private var selectedSector: PortfolioHolding?
    @State private var showSnapTrade = false
    @State private var scrollOffset: CGFloat = 0
    @State private var selectedHolding: PortfolioHolding?  // For detail view
    
    enum SortOption: String, CaseIterable {
        case valueDescending = "Highest Value"
        case valueAscending = "Lowest Value"
        case gainDescending = "Best Performers"
        case nameAZ = "Name A-Z"
    }
    
    private var filteredHoldings: [PortfolioHolding] {
        marketData.portfolio
            .filter { $0.asset.kind == selectedFilter }
            .sorted { first, second in
                switch sortBy {
                case .valueDescending: return first.currentValue > second.currentValue
                case .valueAscending:  return first.currentValue < second.currentValue
                case .gainDescending:  return first.profitLossPercent > second.profitLossPercent
                case .nameAZ:          return first.asset.name < second.asset.name
                }
            }
    }
    
    var body: some View {
        NavigationStack {
            List {
                // MARK: - Header
                Section {
                    headerSection
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                
                // MARK: - Performance Chart
                Section {
                    InteractivePerformanceChart()
                        .frame(height: 300)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                
                // MARK: - Allocation Pie Chart
                if !marketData.portfolio.isEmpty {
                    Section {
                        PremiumAllocationPieChart(selectedSector: $selectedSector)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                
                // MARK: - Controls
                Section {
                    controlsSection
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                
                // MARK: - Holdings
                if marketData.portfolio.isEmpty {
                    Section {
                        emptyPortfolioState
                    }
                    .listRowBackground(Color.clear)
                } else {
                    Section(header: Text("Holdings")) {
                        ForEach(filteredHoldings) { holding in
                            PortfolioHoldingCard(holding: holding)
                                .onTapGesture {
                                    selectedHolding = holding
                                }
                        }
                        .onDelete { indexSet in
                            let holdingsToRemove = indexSet.map { filteredHoldings[$0] }
                            holdingsToRemove.forEach { marketData.removeFromPortfolio($0) }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .navigationTitle("Portfolio")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Connect Broker") {
                        showSnapTrade = true
                    }
                    .font(.subheadline.bold())
                    .foregroundColor(.blue)
                }
            }
            .sheet(isPresented: $showSnapTrade) {
                SnapTradeConnectionView()
            }
            .sheet(item: $selectedHolding) { holding in
                HoldingDetailView(holding: holding)
            }
        }
    }
    
    // MARK: - Enhanced Header
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Portfolio Value")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.white.opacity(0.8))
            
            Text(marketData.totalPortfolioValue.formattedPrice(in: marketData.preferredCurrency))
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            
            HStack {
                Image(systemName: marketData.totalProfitLoss >= 0 ? "triangle.fill" : "triangle.fill")
                    .foregroundColor(marketData.totalProfitLoss >= 0 ? .green : .red)
                    .rotationEffect(.degrees(marketData.totalProfitLoss >= 0 ? 0 : 180))
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(marketData.totalProfitLoss.formattedPrice(in: marketData.preferredCurrency))
                        .font(.title2.bold())
                        .foregroundColor(marketData.totalProfitLoss >= 0 ? .green : .red)
                    
                    Text("\(marketData.totalProfitLossPercent >= 0 ? "+" : "")\(String(format: "%.2f", marketData.totalProfitLossPercent))% today")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                }
                
                Spacer()
            }
            .padding(.top, 8)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                )
        )
    }
    

    // MARK: - Controls
        private var controlsSection: some View {
            VStack(spacing: 16) {
                Picker("Asset Type", selection: $selectedFilter) {
                    ForEach(AssetKind.allCases, id: \.self) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                
                HStack {
                    Image(systemName: "arrow.up.arrow.down")
                    Text("Sort by")
                        .font(.subheadline)
                    
                    Spacer()
                    
                    Menu {
                        ForEach(SortOption.allCases, id: \.self) { option in
                            Button(option.rawValue) {
                                withAnimation(.easeInOut) {
                                    sortBy = option
                                }
                            }
                        }
                    } label: {
                        Text(sortBy.rawValue)
                            .font(.subheadline.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.12))
                            .cornerRadius(12)
                    }
                }
            }
        }
    
    private func greeting() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 0..<12:  return "Good Morning"
        case 12..<17: return "Good Afternoon"
        default:      return "Good Evening"
        }
    }
    
    // MARK: - Empty State (much better UX)
        private var emptyPortfolioState: some View {
            VStack(spacing: 28) {
                Image(systemName: "briefcase")
                    .font(.system(size: 80))
                    .foregroundColor(.white.opacity(0.3))
                
                VStack(spacing: 12) {
                    Text("Your portfolio is empty")
                        .font(.title2.bold())
                        .foregroundColor(.white)
                    
                    Text("Start tracking your investments by adding positions from your watchlist or connecting a brokerage.")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                
                NavigationLink(destination: AppleStocksWatchlistView()) {
                    Label("Browse Assets", systemImage: "magnifyingglass")
                        .font(.headline)
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.white)
                        .cornerRadius(16)
                        .padding(.horizontal, 50)
                }
                
                Button("Connect Brokerage") {
                    showSnapTrade = true
                }
                .font(.subheadline)
                .foregroundColor(.blue)
            }
        }
    }

// MARK: Interactive Chart — NOW COMPILER-FRIENDLY
struct InteractivePerformanceChart: View {
    @EnvironmentObject var marketData: MarketData
    @State private var selectedSnapshot: PortfolioSnapshot?
    
    private var lineColor: Color { marketData.totalProfitLoss >= 0 ? .green : .red }
    
    var body: some View {
        ZStack {
            // Background card
            RoundedRectangle(cornerRadius: 20)
                .fill(LinearGradient(colors: [.white.opacity(0.08), .white.opacity(0.02)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.15), lineWidth: 1))
            
            // Chart content — broken into smaller parts to help compiler
            chartContent
                .padding(20)
        }
        .frame(height: 280)
    }
    
    private var chartContent: some View {
        Chart {
            // Main line and area
            ForEach(marketData.portfolioHistory) { snapshot in
                LineMark(
                    x: .value("Date", snapshot.date),
                    y: .value("Value", snapshot.totalValue)
                )
                .foregroundStyle(lineColor)
                .lineStyle(StrokeStyle(lineWidth: 3.5, lineCap: .round))
                
                AreaMark(
                    x: .value("Date", snapshot.date),
                    y: .value("Value", snapshot.totalValue)
                )
                .foregroundStyle(
                    LinearGradient(colors: [lineColor.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom)
                )
            }
            
            // Selected point marker
            if let selected = selectedSnapshot {
                RuleMark(x: .value("Selected Date", selected.date))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [8]))
                
                PointMark(
                    x: .value("Selected Date", selected.date),
                    y: .value("Value", selected.totalValue)
                )
                .symbol(Circle())
                .symbolSize(100)
                .foregroundStyle(.white)
               // .overlay(Circle().stroke(lineColor, lineWidth: 3))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.white.opacity(0.1))
                AxisValueLabel {
                    if let val = value.as(Double.self) {
                        Text("$\(Int(val/1000))k")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { _ in AxisGridLine().foregroundStyle(.white.opacity(0.1)) }
        }
        .chartOverlay { proxy in
            GeometryReader { _ in
                Rectangle().fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let x = value.location.x
                                guard let date: Date = proxy.value(atX: x) else { return }
                                guard let closest = marketData.portfolioHistory.min(by: {
                                    abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
                                }) else { return }
                                
                                if selectedSnapshot?.id != closest.id {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                }
                                selectedSnapshot = closest
                            }
                            .onEnded { _ in selectedSnapshot = nil }
                    )
            }
        }
        
        // Tooltip
        .overlay(alignment: .top) {
            if let snapshot = selectedSnapshot {
                VStack(spacing: 4) {
                    Text(snapshot.date, format: .dateTime.month(.abbreviated).day())
                        .font(.caption.bold())
                    Text(snapshot.totalValue, format: .currency(code: "USD"))
                        .font(.title3.bold())
                        .foregroundColor(.white)
                }
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .offset(y: -110)
            }
        }
    }
}

// MARK: Pie Chart — unchanged & perfect
struct PremiumAllocationPieChart: View {
    @EnvironmentObject var marketData: MarketData
    @Binding var selectedSector: PortfolioHolding?
    
    private let colors: [Color] = [.blue, .purple, .pink, .orange, .green, .cyan, .mint, .yellow]
    
    private func color(for holding: PortfolioHolding) -> Color {
        let index = marketData.portfolio.firstIndex(where: { $0.id == holding.id }) ?? 0
        return colors[index % colors.count]
    }
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Allocation")
                .font(.title3.bold())
                .foregroundColor(.white)
            
            HStack(spacing: 24) {
                Chart(marketData.portfolio) { holding in
                    SectorMark(
                        angle: .value("Value", holding.currentValue),
                        innerRadius: .ratio(0.6),
                        outerRadius: selectedSector?.id == holding.id ? .ratio(1.04) : .ratio(0.96),
                        angularInset: 2
                    )
                    .foregroundStyle(color(for: holding))
                }
                .frame(width: 170, height: 170)
                .chartLegend(.hidden)
                
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(marketData.portfolio.sorted(by: { $0.currentValue > $1.currentValue })) { holding in
                        HStack {
                            Circle().fill(color(for: holding)).frame(width: 10)
                            Text(holding.asset.symbol)
                                .font(.caption)
                            Spacer()
                            Text("\((holding.currentValue / marketData.totalPortfolioValue * 100), specifier: "%.1f")%")
                                .font(.caption.bold())
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 10)
                        .background(selectedSector?.id == holding.id ? color(for: holding).opacity(0.25) : Color.white.opacity(0.05))
                        .cornerRadius(10)
                        .onTapGesture {
                            withAnimation(.spring(response: 0.3)) {
                                selectedSector = selectedSector?.id == holding.id ? nil : holding
                            }
                        }
                    }
                }
            }
            .padding(16)
            .background(Color.white.opacity(0.04))
            .cornerRadius(18)
        }
        .padding(.horizontal, 12)
    }
}

// MARK: Holding Card — unchanged
// MARK: - Portfolio Holding Card (Fixed)
struct PortfolioHoldingCard: View {
    let holding: PortfolioHolding
    
    @EnvironmentObject var marketData: MarketData  // Needed for currency conversion
    
    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(Color.blue.opacity(0.2))
                .frame(width: 44, height: 44)
                .overlay(
                    Text(String(holding.asset.symbol.prefix(1)))
                        .font(.title3.bold())
                        .foregroundColor(.blue)
                )
            
            VStack(alignment: .leading, spacing: 3) {
                Text(holding.asset.symbol)
                    .font(.headline)
                    .foregroundColor(.white)
                Text(holding.asset.name)
                    .font(.caption)
                    .foregroundColor(.gray)
                Text("\(holding.shares, specifier: "%.2f") shares")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.7))
                HStack(spacing: 2) {
                    Text("Avg: \(holding.avgCost.formattedPrice(in: marketData.preferredCurrency, usdToAudRate: marketData.usdToAudRate))")
                }
                .font(.caption2)
                .foregroundColor(.white.opacity(0.7))
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 3) {
                // ← FIXED: Use holding.currentValue, not asset.price
                Text(holding.currentValue.formattedPrice(
                    in: marketData.preferredCurrency,
                    usdToAudRate: marketData.usdToAudRate
                ))
                .font(.title3.bold())
                .foregroundColor(.white)
                
                HStack(spacing: 5) {
                    Image(systemName: holding.profitLoss >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption.bold())
                    
                    Text(holding.profitLoss.formattedPrice(
                        in: marketData.preferredCurrency,
                        usdToAudRate: marketData.usdToAudRate
                    ))
                    .font(.caption.bold())
                    
                    Text("(\(holding.profitLossPercent >= 0 ? "+" : "")\(String(format: "%.1f", holding.profitLossPercent))%)")
                        .font(.caption.bold())
                }
                .foregroundColor(holding.profitLoss >= 0 ? .green : .red)
            }
        }
        .padding(18)
        .background(Color.white.opacity(0.08))
        .cornerRadius(18)
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }
}



#Preview {
    PortfolioView()
        .environmentObject(MarketData())
        .preferredColorScheme(.dark)
}
