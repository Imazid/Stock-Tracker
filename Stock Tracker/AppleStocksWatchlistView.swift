//
//  AppleStocksWatchlistView.swift
//  Stock Tracker
//

import SwiftUI
import Charts

struct AppleStocksWatchlistView: View {
    @EnvironmentObject var marketData: MarketData
    
    @State private var filter: AssetKind = .stock
    @State private var selectedAsset: Asset?
    @State private var showSearchSheet = false
    @State private var showAlerts = false
    @State private var assetToAddToPortfolio: Asset?  // ← This was the missing/correct name
    
    private var topMovers: [Asset] {
        marketData.watchlist
            .sorted { abs($0.changePercent) > abs($1.changePercent) }
            .prefix(5)
            .map { $0 }
    }
    
    private var filteredAssets: [Asset] {
        marketData.watchlist.filter { $0.kind == filter }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        headerView
                            .padding(.horizontal)
                        
                        WatchlistStatsCard()
                            .padding(.horizontal)
                        
                        if !topMovers.isEmpty {
                            TopMoversSection(movers: Array(topMovers))
                                .padding(.horizontal)
                        }
                        
                        Picker("Asset Type", selection: $filter) {
                            Text("Stocks").tag(AssetKind.stock)
                            Text("Crypto").tag(AssetKind.crypto)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)
                        
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Your \(filter == .stock ? "Stocks" : "Crypto")")
                                    .font(.title2.bold())
                                    .foregroundColor(.white)
                                Spacer()
                                Text("\(filteredAssets.count) assets")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            .padding(.horizontal)
                            
                            if filteredAssets.isEmpty {
                                EmptyWatchlistCard(kind: filter)
                            } else {
                                LazyVStack(spacing: 12) {
                                    ForEach(filteredAssets) { asset in
                                        EnhancedWatchlistRow(asset: asset)
                                            .id(asset.id)
                                            .onTapGesture {
                                                selectedAsset = asset
                                            }
                                            // LEFT SWIPE → Add to Portfolio
                                            .swipeActions(edge: .leading) {
                                                Button {
                                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                                    assetToAddToPortfolio = asset  // ← FIXED: correct variable name
                                                } label: {
                                                    Label("Portfolio", systemImage: "briefcase.fill")
                                                }
                                                .tint(.blue)
                                            }
                                            // RIGHT SWIPE → Remove
                                            .swipeActions(edge: .trailing) {
                                                Button(role: .destructive) {
                                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                                    withAnimation {
                                                        marketData.removeFromWatchlist(asset)
                                                    }
                                                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                                                } label: {
                                                    Label("Remove", systemImage: "trash.fill")
                                                }
                                            }
                                            .contextMenu {
                                                Button {
                                                    assetToAddToPortfolio = asset
                                                } label: {
                                                    Label("Add to Portfolio", systemImage: "briefcase")
                                                }
                                                
                                                Button {
                                                    shareAsset(asset)
                                                } label: {
                                                    Label("Share", systemImage: "square.and.arrow.up")
                                                }
                                                
                                                Divider()
                                                
                                                Button(role: .destructive) {
                                                    withAnimation {
                                                        marketData.removeFromWatchlist(asset)
                                                    }
                                                } label: {
                                                    Label("Remove", systemImage: "trash")
                                                }
                                            }
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                        
                        Spacer(minLength: 120)
                    }
                    .padding(.top)
                }
                
                floatingAddButton
            }
            .navigationTitle("Watchlist")
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $showSearchSheet) { SearchSheet(kind: filter) }
            .sheet(isPresented: $showAlerts) { PriceAlertsView() }
            .sheet(item: $selectedAsset) { AppleStocksDetailView(asset: $0) }
            .sheet(item: $assetToAddToPortfolio) { AddToPortfolioSheet(asset: $0) }
        }
    }
    
    private var headerView: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your Watchlist")
                    .font(.title2)
                    .fontWeight(.medium)
                    .foregroundColor(.white.opacity(0.9))
                
                Text("Track your favorite assets")
                    .font(.largeTitle.bold())
                    .foregroundColor(.white)
            }
            
            Spacer()
            
            Button { showAlerts = true } label: {
                Image(systemName: "bell.fill")
                    .font(.title2)
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.purple)
                    .clipShape(Circle())
                    .shadow(color: .purple.opacity(0.5), radius: 8)
            }
        }
    }
    
    private var floatingAddButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button { showSearchSheet = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.title3.bold())
                        Text("Add Asset")
                            .font(.headline)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .background(LinearGradient(colors: [Color.blue, Color.blue.opacity(0.8)], startPoint: .topLeading, endPoint: .trailing))
                    .cornerRadius(30)
                    .shadow(color: .blue.opacity(0.6), radius: 20, y: 10)
                }
                .padding(.trailing, 20)
                .padding(.bottom, 90)
            }
        }
    }
    
    private func shareAsset(_ asset: Asset) {
        let text = "\(asset.symbol) is at \(asset.price.formatted(.currency(code: "USD")))! 📈"
        let activityVC = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        UIApplication.shared.windows.first?.rootViewController?.present(activityVC, animated: true)
    }
}

// MARK: - Top Movers Section
struct TopMoversSection: View {
    let movers: [Asset]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Top Movers")
                .font(.title2.bold())
                .foregroundColor(.white)
                .padding(.horizontal)
            
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(movers) { asset in
                        TopMoverCard(asset: asset)
                            .frame(width: 210)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

struct TopMoverCard: View {
    let asset: Asset
    @State private var isLoading = true
    @EnvironmentObject var marketData: MarketData
    
    private var lineColor: Color { asset.changePercent >= 0 ? .green : .red }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    if isLoading {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 80, height: 12)
                            .cornerRadius(4)
                            .shimmering()
                        
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 120, height: 16)
                            .cornerRadius(6)
                            .shimmering()
                    } else {
                        Text(asset.symbol)
                            .font(.caption)
                            .foregroundColor(.gray)
                        Text(asset.name)
                            .font(.subheadline.bold())
                            .foregroundColor(.white)
                    }
                }
                Spacer()
                Image(systemName: asset.changePercent >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption.bold())
                    .foregroundColor(lineColor)
            }
            
            HStack(alignment: .bottom, spacing: 10) {
                if isLoading {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 100, height: 28)
                        .cornerRadius(8)
                        .shimmering()
                    
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 60, height: 20)
                        .cornerRadius(6)
                        .shimmering()
                } else {
                    Text(asset.price.formattedPrice(in: marketData.preferredCurrency, usdToAudRate: marketData.usdToAudRate))
                        .font(.title2.bold())
                        .foregroundColor(.white)
                    
                    Text("\(asset.changePercent >= 0 ? "+" : "")\(String(format: "%.2f%%", asset.changePercent))")
                        .font(.title3.bold())
                        .foregroundColor(lineColor)
                }
            }
            
            if isLoading {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 60)
                    .shimmering()
            } else {
                GeometryReader { proxy in
                    let w = proxy.size.width
                    let h = proxy.size.height
                    let points = 35
                    let step = w / CGFloat(points - 1)
                    
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: h/2))
                        for i in 1..<points {
                            let x = CGFloat(i) * step
                            let progress = Double(i) / Double(points - 1)
                            let noise = CGFloat.random(in: -6...6)
                            let trend = asset.changePercent >= 0 ? progress : (1 - progress)
                            let y = h * 0.5 - (trend * h * 0.35) + noise
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    .stroke(lineColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .shadow(color: lineColor.opacity(0.6), radius: 8)
                    .shadow(color: lineColor.opacity(0.4), radius: 16)
                }
                .frame(height: 60)
            }
        }
        .padding(20)
        .frame(height: 170)
        .background(Color.white.opacity(0.08))
        .cornerRadius(22)
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(lineColor.opacity(0.4), lineWidth: 2)
        )
        .task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            withAnimation(.easeInOut) {
                isLoading = false
            }
        }
    }
}

// MARK: - Watchlist Stats Card with Skeleton
struct WatchlistStatsCard: View {
    @EnvironmentObject var marketData: MarketData
    @State private var isLoading = true
    
    private var totalValue: Double {
        marketData.watchlist.reduce(0) { $0 + $1.price }
    }
    
    private var gainers: Int {
        marketData.watchlist.filter { $0.changePercent > 0 }.count
    }
    
    private var losers: Int {
        marketData.watchlist.filter { $0.changePercent < 0 }.count
    }
    
    private var totalAssets: Int {
        marketData.watchlist.count
    }
    
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                // Total Assets Card
                VStack(alignment: .leading, spacing: 8) {
                    if isLoading {
                        Rectangle().fill(Color.gray.opacity(0.3)).frame(width: 120, height: 14).cornerRadius(4).shimmering()
                        Rectangle().fill(Color.gray.opacity(0.3)).frame(width: 80, height: 32).cornerRadius(8).shimmering()
                    } else {
                        HStack {
                            Image(systemName: "chart.bar.fill")
                                .font(.title3)
                                .foregroundColor(.blue)
                            Text("Total Assets")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.7))
                        }
                        Text("\(totalAssets)")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.08)))
                
                // Gainers/Losers
                VStack(spacing: 12) {
                    if isLoading {
                        Rectangle().fill(Color.gray.opacity(0.3)).frame(height: 60).cornerRadius(12).shimmering()
                        Divider().background(Color.gray.opacity(0.2))
                        Rectangle().fill(Color.gray.opacity(0.3)).frame(height: 40).cornerRadius(12).shimmering()
                    } else {
                        // Existing gainers/losers content...
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.up.circle.fill")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                    Text("Gainers")
                                        .font(.caption2)
                                        .foregroundColor(.green.opacity(0.8))
                                }
                                Text("\(gainers)")
                                    .font(.title2.bold())
                                    .foregroundColor(.green)
                            }
                            Spacer()
                            ZStack {
                                Circle().stroke(Color.red.opacity(0.3), lineWidth: 6)
                                Circle()
                                    .trim(from: 0, to: totalAssets > 0 ? CGFloat(gainers) / CGFloat(totalAssets) : 0)
                                    .stroke(Color.green, lineWidth: 6)
                                    .rotationEffect(.degrees(-90))
                            }
                            .frame(width: 40, height: 40)
                        }
                        
                        Divider().background(Color.white.opacity(0.2))
                        
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.down.circle.fill")
                                        .font(.caption)
                                        .foregroundColor(.red)
                                    Text("Losers")
                                        .font(.caption2)
                                        .foregroundColor(.red.opacity(0.8))
                                }
                                Text("\(losers)")
                                    .font(.title2.bold())
                                    .foregroundColor(.red)
                            }
                            Spacer()
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.08)))
            }
        }
        .padding(.horizontal)
        .task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            withAnimation { isLoading = false }
        }
    }
}

// MARK: - Index Card with Chart
struct IndexCardWithChart: View {
    let index: MarketIndex
    let history: [PricePoint]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(index.name)
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.9))
                    
                    HStack(spacing: 4) {
                        Image(systemName: index.change >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.caption2)
                        Text(String(format: "%+.2f%%", index.changePercent))
                            .font(.caption.bold())
                    }
                    .foregroundColor(index.change >= 0 ? .green : .red)
                }
                Spacer()
            }
            
            // Mini Chart
            if !history.isEmpty {
                Chart(history) {
                    LineMark(
                        x: .value("Date", $0.date),
                        y: .value("Price", $0.price)
                    )
                    .foregroundStyle(index.change >= 0 ? Color.green : Color.red)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    
                    AreaMark(
                        x: .value("Date", $0.date),
                        y: .value("Price", $0.price)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                (index.change >= 0 ? Color.green : Color.red).opacity(0.3),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 60)
            }
            
            // Price
            Text(index.price, format: .currency(code: "USD").precision(.fractionLength(index.name.contains("Bitcoin") || index.name.contains("Ethereum") ? 0 : 2)))
                .font(.title3.bold())
                .foregroundColor(.white)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke((index.change >= 0 ? Color.green : Color.red).opacity(0.3), lineWidth: 1)
                )
        )
    }
}

// MARK: - Empty Watchlist Card
struct EmptyWatchlistCard: View {
    let kind: AssetKind
    
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.3), Color.purple.opacity(0.3)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 100, height: 100)
                    .blur(radius: 20)
                
                Image(systemName: kind == .stock ? "chart.line.uptrend.xyaxis" : "bitcoinsign.circle")
                    .font(.system(size: 50))
                    .foregroundColor(.white.opacity(0.8))
            }
            
            Text("No \(kind == .stock ? "Stocks" : "Crypto") Yet")
                .font(.headline)
                .foregroundColor(.white)
            
            Text("Add \(kind == .stock ? "stocks" : "cryptocurrencies") to start tracking their performance")
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.05))
        )
        .padding(.horizontal)
    }
}

struct EnhancedWatchlistRow: View {
    let asset: Asset
    @EnvironmentObject var marketData: MarketData
    @State private var miniHistory: [PricePoint] = []
    @State private var isLoading = true  // New: loading state
    
    var body: some View {
        HStack(spacing: 16) {
            // Icon
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.2, green: 0.3, blue: 0.5), Color(red: 0.15, green: 0.25, blue: 0.45)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 50, height: 50)
                Text(String(asset.symbol.prefix(1)))
                    .font(.title3.bold())
                    .foregroundColor(.white)
            }
            
            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(asset.symbol)
                    .font(.headline)
                    .foregroundColor(.white)
                Text(asset.name)
                    .font(.caption)
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
            
            Spacer()
            
            // Mini Chart with Skeleton
            if isLoading {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 70, height: 35)
                    .shimmering()  // Pulsing animation
            } else if !miniHistory.isEmpty {
                Chart(miniHistory) {
                    LineMark(
                        x: .value("Date", $0.date),
                        y: .value("Price", $0.price)
                    )
                    .foregroundStyle(asset.changePercent >= 0 ? Color.green : Color.red)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    
                    AreaMark(
                        x: .value("Date", $0.date),
                        y: .value("Price", $0.price)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [(asset.changePercent >= 0 ? Color.green : Color.red).opacity(0.2), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(width: 70, height: 35)
            }
            
            // Price Info
            VStack(alignment: .trailing, spacing: 4) {
                Text(asset.price.formattedPrice(in: marketData.preferredCurrency, usdToAudRate: marketData.usdToAudRate))
                    .font(.headline)
                    .foregroundColor(.white)
                
                HStack(spacing: 4) {
                    Image(systemName: asset.changePercent >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption2)
                    Text(String(format: "%+.2f%%", asset.changePercent))
                        .font(.caption.bold())
                }
                .foregroundColor(asset.changePercent >= 0 ? .green : .red)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill((asset.changePercent >= 0 ? Color.green : Color.red).opacity(0.2))
                )
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.08))
        )
        .task {
            // Simulate loading delay for realism
            try? await Task.sleep(nanoseconds: 800_000_000)
            miniHistory = await marketData.fetchPriceHistory(for: asset, range: TimeRange.oneWeek)
            if miniHistory.isEmpty {
                miniHistory = mockSparkline(for: asset)
            }
            withAnimation(.easeInOut) {
                isLoading = false
            }
        }
    }
    
    private func mockSparkline(for asset: Asset) -> [PricePoint] {
        var points: [PricePoint] = []
        var price = asset.price * 0.97
        let now = Date()
        for i in 0..<28 {
            price += Double.random(in: -2...2)
            points.append(PricePoint(date: now.addingTimeInterval(Double(i) * 3600 * 6), price: max(price, 1)))
        }
        return points
    }
}
// MARK: - Search Sheet (Aesthetic)
struct SearchSheet: View {
    @EnvironmentObject var marketData: MarketData
    @Environment(\.dismiss) var dismiss
    let kind: AssetKind
    
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var isShowingCustomAdd = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                
                if filteredResults.isEmpty && !searchText.isEmpty && !isSearching {
                    VStack(spacing: 24) {
                        ZStack {
                            Circle()
                                .fill(LinearGradient(colors: [.blue.opacity(0.3), .purple.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 180, height: 180)
                                .blur(radius: 40)
                            
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 80))
                                .foregroundColor(.white.opacity(0.4))
                        }
                        
                        Text("No results for \"\(searchText)\"")
                            .font(.title2.bold())
                            .foregroundColor(.white.opacity(0.8))
                        
                        Text("Try a different symbol or add it manually")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                        
                        Button {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            isShowingCustomAdd = true
                        } label: {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                Text("Add \"\(searchText.uppercased())\" Manually")
                            }
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 16)
                            .background(LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing))
                            .cornerRadius(20)
                            .shadow(color: .purple.opacity(0.6), radius: 20, y: 10)
                        }
                    }
                    .transition(.opacity.combined(with: .scale))
                } else {
                    List {
                        ForEach(filteredResults) { asset in
                            SearchResultRow(asset: asset)
                                .onTapGesture {
                                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                                    marketData.addToWatchlist(asset)
                                    dismiss()
                                }
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                    .listStyle(PlainListStyle())
                    .animation(.easeInOut(duration: 0.3), value: filteredResults)
                }
                
                if isSearching {
                    Color.black.opacity(0.6)
                        .ignoresSafeArea()
                        .overlay(
                            ProgressView("Searching...")
                                .scaleEffect(1.2)
                                .foregroundColor(.white)
                                .padding()
                                .background(Color.black.opacity(0.8))
                                .cornerRadius(16)
                                .shadow(radius: 20)
                        )
                }
            }
            .navigationTitle("Search \(kind == .stock ? "Stocks" : "Crypto")")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.white.opacity(0.8))
                }
            }
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text("Search symbols or names (e.g., AAPL, Bitcoin)")
                    .foregroundColor(.white.opacity(0.6))
            )
            .onChange(of: searchText) { _, newValue in
                Task {
                    isSearching = !newValue.isEmpty
                    if !newValue.isEmpty {
                        await marketData.searchAssets(query: newValue, kind: kind)
                    }
                    withAnimation(.easeInOut) {
                        isSearching = false
                    }
                }
            }
            .sheet(isPresented: $isShowingCustomAdd) {
                AddCustomAssetSheet(kind: kind, presetSymbol: searchText)
            }
        }
        .preferredColorScheme(.dark)
    }
    
    private var filteredResults: [Asset] {
        marketData.searchResults.filter { $0.kind == kind }
    }
}

// MARK: - Aesthetic Search Result Row with Skeleton Loading
struct SearchResultRow: View {
    let asset: Asset
    @EnvironmentObject var marketData: MarketData
    @State private var miniHistory: [PricePoint] = []
    @State private var isLoading = true  // New: loading state for skeleton
    
    var body: some View {
        HStack(spacing: 16) {
            // Gradient Icon
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.blue.opacity(0.6), .purple.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 50, height: 50)
                
                Text(String(asset.symbol.prefix(1)))
                    .font(.title2.bold())
                    .foregroundColor(.white)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text(asset.symbol)
                    .font(.headline)
                    .foregroundColor(.white)
                
                Text(asset.name)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(1)
            }
            
            Spacer()
            
            // Mini Sparkline with Skeleton
            if isLoading {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 80, height: 40)
                    .shimmering()  // Pulsing shimmer effect
            } else if !miniHistory.isEmpty {
                Chart(miniHistory) {
                    LineMark(
                        x: .value("Date", $0.date),
                        y: .value("Price", $0.price)
                    )
                    .foregroundStyle(asset.changePercent >= 0 ? Color.green : Color.red)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(width: 80, height: 40)
            }
            
            // Price & Change
            VStack(alignment: .trailing, spacing: 4) {
                if isLoading {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 90, height: 20)
                        .shimmering()
                    
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 70, height: 24)
                        .shimmering()
                } else {
                    Text(asset.price.formattedPrice(in: marketData.preferredCurrency, usdToAudRate: marketData.usdToAudRate))
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    Text(String(format: "%+.2f%%", asset.changePercent))
                        .font(.caption.bold())
                        .foregroundColor(asset.changePercent >= 0 ? .green : .red)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill((asset.changePercent >= 0 ? Color.green : Color.red).opacity(0.2))
                        )
                }
            }
            
            Image(systemName: "plus.circle.fill")
                .font(.title2)
                .foregroundColor(isLoading ? .gray.opacity(0.5) : .green.opacity(0.8))
                .opacity(isLoading ? 0.6 : 1.0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal)
        .background(Color.white.opacity(0.06))
        .cornerRadius(18)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(LinearGradient(colors: [.white.opacity(0.1), .clear], startPoint: .top, endPoint: .bottom), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
        .task {
            // Simulate slight delay for realistic loading
            try? await Task.sleep(nanoseconds: 600_000_000)
            
            miniHistory = await marketData.fetchPriceHistory(for: asset, range: TimeRange.oneWeek)
            if miniHistory.isEmpty {
                miniHistory = mockMiniHistory(for: asset)
            }
            
            withAnimation(.easeInOut(duration: 0.4)) {
                isLoading = false
            }
        }
    }
    
    private func mockMiniHistory(for asset: Asset) -> [PricePoint] {
        var points: [PricePoint] = []
        var price = asset.price * 0.98
        let now = Date()
        for i in 0..<20 {
            price += Double.random(in: -1.5...1.5)
            points.append(PricePoint(date: now.addingTimeInterval(Double(i) * 3600), price: max(price, 1)))
        }
        return points
    }
}

// MARK: - Shimmering Skeleton Effect
extension View {
    func shimmering() -> some View {
        self
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.15))
                    .mask(
                        Rectangle()
                            .fill(LinearGradient(gradient: Gradient(colors: [.clear, .white, .clear]), startPoint: .leading, endPoint: .trailing))
                            .rotationEffect(.degrees(30))
                            .offset(x: -100)
                            .animation(Animation.linear(duration: 1.5).repeatForever(autoreverses: false), value: UUID())
                    )
            )
    }
}

// MARK: - Custom Asset Sheet
struct AddCustomAssetSheet: View {
    @EnvironmentObject var marketData: MarketData
    @Environment(\.dismiss) var dismiss
    
    let kind: AssetKind
    let presetSymbol: String
    
    @State private var symbol = ""
    @State private var name = ""
    @State private var priceText = ""
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Custom \(kind == .stock ? "Stock" : "Crypto")") {
                    TextField("Symbol", text: $symbol)
                        .textInputAutocapitalization(.characters)
                    TextField("Name (optional)", text: $name)
                    TextField("Current Price", text: $priceText)
                        .keyboardType(.decimalPad)
                }
                
                Section {
                    Text("This will be added with the price you enter.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Add Custom Asset")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let price = Double(priceText),
                              !symbol.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        
                        let cleanSymbol = symbol.trimmingCharacters(in: .whitespaces).uppercased()
                        let cleanName = name.isEmpty ? cleanSymbol : name
                        
                        marketData.addCustomAsset(
                            symbol: cleanSymbol,
                            name: cleanName,
                            price: price,
                            kind: kind,
                            exchange: "NYSE"
                        )
                        dismiss()
                        dismiss()
                    }
                    .disabled(symbol.isEmpty || priceText.isEmpty || Double(priceText) == nil)
                }
            }
            .onAppear {
                symbol = presetSymbol.uppercased()
            }
        }
    }
}
