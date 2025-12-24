import SwiftUI

struct AppleStocksWatchlistView: View {
    @EnvironmentObject var marketData: MarketData
    
    @State private var filter: AssetKind = .stock
    @State private var selectedAsset: Asset?
    @State private var showSearchSheet = false
    
    private var filteredAssets: [Asset] {
        marketData.watchlist.filter { $0.kind == filter }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Header
                        headerSection
                            .padding(.horizontal)
                            .padding(.top, 8)
                        
                        // Horizontal scrolling ticker at top
                        if !filteredAssets.isEmpty {
                            tickerScrollView
                                .padding(.top, 16)
                        }
                        
                        // Stock list
                        LazyVStack(spacing: 0) {
                            ForEach(filteredAssets) { asset in
                                Button {
                                    selectedAsset = asset
                                } label: {
                                    AppleStockRow(asset: asset)
                                }
                                .buttonStyle(.plain)
                                
                                Divider()
                                    .background(Color.white.opacity(0.1))
                                    .padding(.leading, 20)
                            }
                        }
                        .padding(.top, 20)
                        
                        // News section
                        newsSection
                            .padding(.top, 40)
                    }
                }
            }
            .sheet(item: $selectedAsset) { asset in
                AppleStocksDetailView(asset: asset)
            }
            .sheet(isPresented: $showSearchSheet) {
                SearchSheet(kind: filter)
            }
        }
    }
    
    private var headerSection: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(filter == .stock ? "Stocks" : "Crypto")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(.white)
                
                Text(Date().formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 28, weight: .regular))
                    .foregroundColor(.gray)
            }
            
            Spacer()
            
            HStack(spacing: 12) {
                Button {
                    showSearchSheet = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                
                Menu {
                    Button("Add Stock") { }
                    Button("Edit Watchlist") { }
                    Picker("Type", selection: $filter) {
                        Text("Stocks").tag(AssetKind.stock)
                        Text("Crypto").tag(AssetKind.crypto)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
    
    private var tickerScrollView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 24) {
                ForEach(filteredAssets.prefix(5)) { asset in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(asset.symbol)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                        
                        Text(String(format: "%.2f", asset.price))
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                        
                        Text(String(format: "%+.2f%%", asset.changePercent))
                            .font(.system(size: 15, weight: .regular))
                            .foregroundColor(asset.isPositive ? .green : .red)
                    }
                    .frame(width: 100, alignment: .leading)
                }
            }
            .padding(.horizontal, 20)
        }
    }
    
    private var newsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Business News")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.horizontal, 20)
            
            VStack(alignment: .leading, spacing: 12) {
                Text("From 🍎News")
                    .font(.system(size: 15))
                    .foregroundColor(.gray)
                    .padding(.horizontal, 20)
                
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 200)
                    .overlay(
                        VStack {
                            Image(systemName: "newspaper")
                                .font(.system(size: 40))
                                .foregroundColor(.gray)
                            Text("News articles")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    )
                    .padding(.horizontal, 20)
            }
        }
    }
}

// MARK: - Apple Stock Row

struct AppleStockRow: View {
    let asset: Asset
    
    var body: some View {
        HStack(spacing: 12) {
            // Symbol and name
            VStack(alignment: .leading, spacing: 4) {
                Text(asset.symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                
                Text(asset.name)
                    .font(.system(size: 15))
                    .foregroundColor(.gray)
                    .lineLimit(1)
            }
            
            Spacer()
            
            // Mini chart
            MiniSparkline(
                price: asset.price,
                change: asset.changePercent,
                isPositive: asset.isPositive
            )
            .frame(width: 80, height: 40)
            
            // Price and change
            VStack(alignment: .trailing, spacing: 4) {
                Text(String(format: "%.2f", asset.price))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                
                Text(String(format: "%+.2f%%", asset.changePercent))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(asset.isPositive ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(asset.isPositive ? Color.green : Color.red, lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

// MARK: - Mini Sparkline Chart

struct MiniSparkline: View {
    let price: Double
    let change: Double
    let isPositive: Bool
    
    @State private var points: [CGPoint] = []
    
    var body: some View {
        Canvas { context, size in
            guard points.count > 1 else { return }
            
            // Draw area
            var areaPath = Path()
            areaPath.move(to: CGPoint(x: 0, y: size.height))
            areaPath.addLine(to: points[0])
            for point in points {
                areaPath.addLine(to: point)
            }
            areaPath.addLine(to: CGPoint(x: size.width, y: size.height))
            areaPath.closeSubpath()
            
            context.fill(
                areaPath,
                with: .color(isPositive ? .green.opacity(0.1) : .red.opacity(0.1))
            )
            
            // Draw line
            var linePath = Path()
            linePath.move(to: points[0])
            for point in points.dropFirst() {
                linePath.addLine(to: point)
            }
            
            context.stroke(
                linePath,
                with: .color(isPositive ? .green : .red),
                lineWidth: 1.5
            )
        }
        .onAppear {
            generatePoints()
        }
    }
    
    private func generatePoints() {
        let count = 20
        var pts: [CGPoint] = []
        let basePrice = price / (1 + change / 100)
        
        for i in 0..<count {
            let x = CGFloat(i) / CGFloat(count - 1)
            let randomVariation = Double.random(in: -abs(change) * 0.3...abs(change) * 0.3)
            let progress = Double(i) / Double(count - 1)
            let priceAtPoint = basePrice * (1 + (change / 100) * progress + randomVariation / 100)
            
            // Normalize to 0-1 range
            let minPrice = basePrice * (1 + min(0, change / 100) * 1.2)
            let maxPrice = basePrice * (1 + max(0, change / 100) * 1.2)
            let normalizedY = (priceAtPoint - minPrice) / (maxPrice - minPrice)
            
            // Invert Y (0 is top in SwiftUI)
            let y = 1 - normalizedY
            
            pts.append(CGPoint(x: x, y: y))
        }
        self.points = pts
    }
}

// MARK: - Search Sheet

struct SearchSheet: View {
    @EnvironmentObject var marketData: MarketData
    @Environment(\.dismiss) var dismiss
    let kind: AssetKind
    
    @State private var searchText = ""
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                
                VStack {
                    Text("Search for \(kind == .stock ? "stocks" : "crypto")")
                        .foregroundColor(.white)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .searchable(text: $searchText, prompt: "Search")
        }
    }
}