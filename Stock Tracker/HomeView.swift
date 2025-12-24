//
//  HomeView.swift
//  Stock Tracker
//

import SwiftUI
import Charts

struct HomeView: View {
    @EnvironmentObject var marketData: MarketData
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    
    @State private var showMenu = false
    @State private var isSignedIn = false
    @State private var isDayTradeMode = false  // Moved here correctly

    var body: some View {
        ZStack {
            NavigationStack {
                ScrollView {
                    
                    // MARK: - AI Agent Card
                    VStack(alignment: .leading, spacing: 12) {
                        Text("AI Investing Assistant")
                            .font(.title2.bold())
                            .foregroundColor(.white)
                        
                        Text("Get instant insights, stock analysis, and portfolio advice powered by AI.")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.7))
                        
                        NavigationLink {
                            AIAgentView()
                        } label: {
                            HStack {
                                Image(systemName: "brain.head.profile")
                                    .font(.title2)
                                    .foregroundColor(.purple)
                                
                                Text("Talk to AI Agent")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                
                                Spacer()
                                
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.white.opacity(0.6))
                            }
                            .padding()
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(18)
                            .overlay(
                                RoundedRectangle(cornerRadius: 18)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                            )
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 20)
                    VStack(spacing: 26) {
                            
                        
                        // Greeting + Menu Button
                        HStack {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Good \(greeting()),")
                                    .font(.title2)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white.opacity(0.9))
                                
                                Text("Here's your market overview")
                                    .font(.system(size: 34, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                            }
                            
                            Spacer()
                            
                            Button {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                                    showMenu.toggle()
                                }
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(
                                            RadialGradient(
                                                colors: [.white.opacity(0.2), .white.opacity(0.05)],
                                                center: .center,
                                                startRadius: 10,
                                                endRadius: 50
                                            )
                                        )
                                        .blur(radius: 10)
                                        .frame(width: 60, height: 60)
                                    
                                    Circle()
                                        .fill(Color.white.opacity(0.12))
                                        .overlay(
                                            Circle()
                                                .stroke(Color.white.opacity(0.3), lineWidth: 1)
                                                .blur(radius: 1)
                                        )
                                        .frame(width: 56, height: 56)
                                    
                                    Image(systemName: "line.3.horizontal")
                                        .font(.system(size: 22, weight: .semibold))
                                        .foregroundColor(.white)
                                        .shadow(color: .white.opacity(0.6), radius: 8)
                                }
                                .frame(width: 70, height: 70)
                                .scaleEffect(showMenu ? 0.95 : 1.0)
                                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: showMenu)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 10)
                        
                        // Subscription Badge
                        subscriptionBadge
                            .padding(.horizontal)
                        
                        // Portfolio Card (only for paid tiers)
                        if subscriptionManager.hasFeatureAccess(feature: .portfolio) && marketData.totalPortfolioValue > 0 {
                            CompactPortfolioCard()
                                .padding(.horizontal)
                        }
                        
                        LiveIndicesWithGlow()
                            .padding(.horizontal)
                        
                        QuickActionsGrid()
                            .padding(.horizontal)
                        
                        WatchlistPreviewSection()
                            .padding(.horizontal)
                    }
                    .padding(.bottom, 60)
                }
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .background(Color.black.ignoresSafeArea())
            }
            .disabled(showMenu)
            .blur(radius: showMenu ? 10 : 0)
            
            // Sliding Menu Overlay
            if showMenu {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation { showMenu = false }
                    }
                
                SlidingMenuView(isSignedIn: $isSignedIn, showMenu: $showMenu)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.35), value: showMenu)
    }
    
    private var subscriptionBadge: some View {
        HStack(spacing: 12) {
            Image(systemName: subscriptionManager.currentTier.icon)
                .font(.title3)
                .foregroundColor(subscriptionManager.currentTier.color)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(subscriptionManager.currentTier.displayName)
                    .font(.headline)
                    .foregroundColor(.white)
                
                if subscriptionManager.currentTier == .free {
                    Text("Tap to upgrade")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                } else {
                    Text("Active subscription")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
            
            Spacer()
            
            if subscriptionManager.currentTier == .free {
                Image(systemName: "arrow.right")
                    .foregroundColor(.white.opacity(0.6))
            }
        }
        .padding()
        .background(
            LinearGradient(
                colors: subscriptionManager.currentTier.gradientColors.map { $0.opacity(0.3) },
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(subscriptionManager.currentTier.color.opacity(0.5), lineWidth: 1)
        )
        .onTapGesture {
            if subscriptionManager.currentTier == .free {
                // Present paywall here
            }
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
    
private var subscriptionBadge: some View {
    // Inject the environment object here
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    
    return HStack(spacing: 12) {
        Image(systemName: subscriptionManager.currentTier.icon)
            .font(.title3)
            .foregroundColor(subscriptionManager.currentTier.color)
        
        VStack(alignment: .leading, spacing: 2) {
            Text(subscriptionManager.currentTier.displayName)
                .font(.headline)
                .foregroundColor(.white)
            
            if subscriptionManager.currentTier == .free {
                Text("Tap to upgrade")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
            } else {
                Text("Active subscription")
                    .font(.caption)
                    .foregroundColor(.green)
            }
        }
    
            
            Spacer()
            
            if subscriptionManager.currentTier == .free {
                Image(systemName: "arrow.right")
                    .foregroundColor(.white.opacity(0.6))
            }
        }
        .padding()
        .background(
            LinearGradient(
                colors: subscriptionManager.currentTier.gradientColors.map { $0.opacity(0.3) },
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(subscriptionManager.currentTier.color.opacity(0.5), lineWidth: 1)
        )
        .onTapGesture {
            if subscriptionManager.currentTier == .free {
                // Show paywall
            }
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

// MARK: - Compact Portfolio Card
struct CompactPortfolioCard: View {
    @EnvironmentObject var marketData: MarketData
    
    var body: some View {
        VStack(spacing: 14) {
            Text("Portfolio Value")
                .font(.headline)
                .foregroundColor(.white.opacity(0.8))
            
            Text(marketData.totalPortfolioValue, format: .currency(code: "USD"))
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            
            HStack(spacing: 12) {
                Image(systemName: marketData.totalProfitLoss >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.title3.bold())
                    .foregroundColor(marketData.totalProfitLoss >= 0 ? .green : .red)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(marketData.totalProfitLoss, format: .currency(code: "USD"))
                        .font(.title2.bold())
                        .foregroundColor(marketData.totalProfitLoss >= 0 ? .green : .red)
                    
                    Text("\(marketData.totalProfitLoss >= 0 ? "+" : "")\(String(format: "%.2f", marketData.totalProfitLossPercent))%")
                        .font(.subheadline)
                        .foregroundColor(marketData.totalProfitLoss >= 0 ? .green : .red)
                }
            }
            
            PortfolioMiniChart()
                .frame(height: 140)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.08))
        .cornerRadius(22)
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
    }
}

// MARK: - Mini Chart
struct PortfolioMiniChart: View {
    @EnvironmentObject var marketData: MarketData
    
    private var lineColor: Color { marketData.totalProfitLoss >= 0 ? .green : .red }
    
    var body: some View {
        Chart {
            ForEach(marketData.portfolioHistory) { snapshot in
                LineMark(
                    x: .value("Date", snapshot.date),
                    y: .value("Value", snapshot.totalValue)
                )
                .foregroundStyle(lineColor)
                .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                
                AreaMark(
                    x: .value("Date", snapshot.date),
                    y: .value("Value", snapshot.totalValue)
                )
                .foregroundStyle(
                    LinearGradient(colors: [lineColor.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom)
                )
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
    }
}

// Rest remains the same (LiveIndicesWithGlow, GlowingIndexCard, QuickActionsGrid, etc.)
struct LiveIndicesWithGlow: View {
    @State private var indices: [MarketIndex] = []
    @State private var isLoading = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Live Indices")
                .font(.title2.bold())
                .foregroundColor(.white)
                .padding(.horizontal)
            
            if isLoading {
                // Skeleton index cards
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 18) {
                        ForEach(0..<4) { _ in
                            skeletonIndexCard
                                .frame(width: 210)
                        }
                    }
                    .padding(.horizontal)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 18) {
                        ForEach(indices) { index in
                            GlowingIndexCard(index: index)
                                .frame(width: 210)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .task { await loadIndices() }
    }
    
    private var skeletonIndexCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 80, height: 12)
                        .shimmering()
                    
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 120, height: 16)
                        .shimmering()
                }
                Spacer()
                Circle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 20, height: 20)
                    .shimmering()
            }
            
            HStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 100, height: 28)
                    .shimmering()
                
                Spacer()
                
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 70, height: 24)
                    .shimmering()
            }
            
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.2))
                .frame(height: 60)
                .shimmering()
        }
        .padding(20)
        .frame(height: 170)
        .background(Color.white.opacity(0.08))
        .cornerRadius(22)
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.1), lineWidth: 1))
        .shimmering()
    }
    
    private func loadIndices() async {
            isLoading = true
            
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            
            // Your real data loading logic here...
            let symbols = [
                ("S&P 500", "^GSPC"),
                ("Nasdaq", "^IXIC"),
                ("Dow Jones", "^DJI"),
                ("Bitcoin", "BTC-USD"),
                ("Ethereum", "ETH-USD"),
                ("Gold", "GC=F"),
                ("Oil", "CL=F"),
                ("VIX", "^VIX")
            ]
            
            var results: [MarketIndex] = []
            
            for (name, symbol) in symbols {
                do {
                    let asset = try await APIService.shared.fetchAssetDetails(
                        identifier: symbol,
                        kind: symbol.contains("USD") ? .crypto : .stock,
                        name: name
                    )
                    
                    results.append(MarketIndex(
                        name: name,
                        symbol: symbol,
                        price: asset.price,
                        change: asset.change,
                        changePercent: asset.changePercent
                    ))
                } catch {
                    results.append(MarketIndex(
                        name: name,
                        symbol: symbol,
                        price: Double.random(in: 100...100000),
                        change: Double.random(in: -1000...1000),
                        changePercent: Double.random(in: -5...5)
                    ))
                }
            }
            
            await MainActor.run {
                withAnimation(.easeInOut) {
                    self.indices = results
                    self.isLoading = false
                }
            }
        }
    }



struct GlowingIndexCard: View {
    let index: MarketIndex
    
    private var lineColor: Color { index.isPositive ? .green : .red }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(index.symbol)
                        .font(.caption)
                        .foregroundColor(.gray)
                    Text(index.name)
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                }
                Spacer()
                Image(systemName: index.isPositive ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption.bold())
                    .foregroundColor(lineColor)
            }
            
            HStack(alignment: .bottom, spacing: 10) {
                Text(index.price, format: .number.precision(.fractionLength(index.price > 1000 ? 0 : 2)))
                    .font(.title2.bold())
                    .foregroundColor(.white)
                
                Text("\(index.isPositive ? "+" : "")\(String(format: "%.2f", index.changePercent))%")
                    .font(.title3.bold())
                    .foregroundColor(lineColor)
            }
            
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
                        let trend = index.isPositive ? progress : (1 - progress)
                        let y = h * 0.5 - (trend * h * 0.35) + noise
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                .stroke(lineColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .shadow(color: lineColor.opacity(0.6), radius: 8)
                .shadow(color: lineColor.opacity(0.4), radius: 16)
                .shadow(color: lineColor.opacity(0.3), radius: 24)
            }
            .frame(height: 60)
        }
        .padding(20)
        .frame(height: 170)
        .background(Color.white.opacity(0.08))
        .cornerRadius(22)
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(lineColor.opacity(0.4), lineWidth: 2)
                .shadow(color: lineColor.opacity(0.6), radius: 15)
                .shadow(color: lineColor.opacity(0.4), radius: 30)
        )
        .shadow(color: lineColor.opacity(0.3), radius: 20, x: 0, y: 10)
    }
}

struct QuickActionsGrid: View {
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
            QuickActionButton(title: "Add Stock", icon: "plus.circle.fill", color: .blue) {}
            QuickActionButton(title: "Price Alerts", icon: "bell.fill", color: .purple) {}
            QuickActionButton(title: "News", icon: "newspaper.fill", color: .orange) {}
            QuickActionButton(title: "Settings", icon: "gearshape.fill", color: .green) {}
        }
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

struct WatchlistPreviewSection: View {
    @EnvironmentObject var marketData: MarketData
    @State private var isLoading = true  // Simulate loading state
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your Watchlist")
                    .font(.title3.bold())
                    .foregroundColor(.white)
                Spacer()
                NavigationLink("See Watchlist") { AppleStocksWatchlistView() }
                    .foregroundColor(.blue)
            }
            
            if marketData.watchlist.isEmpty && isLoading {
                // Skeleton cards
                ForEach(0..<5) { _ in
                    skeletonWatchlistRow
                }
            } else if marketData.watchlist.isEmpty {
                Text("No assets in watchlist yet")
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(12)
            } else {
                ForEach(marketData.watchlist.prefix(5)) { asset in
                    WatchlistRowPreview(asset: asset)
                }
            }
        }
        .onAppear {
            // Simulate loading delay (remove when real data loads fast)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation {
                    isLoading = false
                }
            }
        }
    }
    
    private var skeletonWatchlistRow: some View {
        HStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.3))
                .frame(width: 50, height: 50)
                .shimmering()
            
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 100, height: 16)
                    .shimmering()
                
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 160, height: 12)
                    .shimmering()
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 8) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 90, height: 20)
                    .shimmering()
                
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 60, height: 16)
                    .shimmering()
            }
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(16)
        .padding(.horizontal)
        .padding(.vertical, 4)
    }
}

struct WatchlistRowPreview: View {
    let asset: Asset
    
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(asset.symbol).font(.headline).foregroundColor(.white)
                Text(asset.name).font(.caption).foregroundColor(.gray)
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
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
        
//        Text("1 USD ≈ \(marketData.usdToAudRate, specifier: "%.4f") AUD")
//            .font(.caption)
//            .foregroundColor(.gray)
    }
}

#Preview {
    HomeView()
        .environmentObject(MarketData())
        .environmentObject(SubscriptionManager.shared)
        .preferredColorScheme(.dark)
}
