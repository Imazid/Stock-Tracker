//
//  AppleStocksDetailView.swift
//  Stock Tracker
//

import SwiftUI
import Charts

struct AppleStocksDetailView: View {
    let asset: Asset
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var marketData: MarketData
    @EnvironmentObject var alertManager: PriceAlertManager
    @EnvironmentObject var subscriptionManager: SubscriptionManager

    @State private var selectedRange: TimeRange = .oneDay
    @State private var showAddToPortfolio = false
    @State private var showAlertSheet = false
    @State private var chartData: [Candle] = []
    @State private var isLoadingChart = true

    @State private var showPaywall = false
    @State private var paywallTier: SubscriptionTier = .pro
    @State private var paywallMessage: String = ""

    @State private var chartType: ChartType = .line  // New state

    enum ChartType: String, CaseIterable {
        case line = "Line"
        case candlestick = "Candlestick"
    }

    private var isPositive: Bool { asset.changePercent >= 0 }
    private var accentColor: Color { isPositive ? .green : .red }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color.black, accentColor.opacity(0.05), Color.black],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        heroSection
                            .padding(.top, 20)

                        chartSection
                            .padding(.top, 32)

                        companyOverviewSection
                            .padding(.top, 32)

                        if subscriptionManager.hasFeatureAccess(feature: .technicalAnalysis) {
                            analysisSection
                                .padding(.top, 32)
                        } else {
                            FeatureLockView(featureName: "Technical Analysis", requiredTier: .pro)
                                .frame(height: 250)
                                .padding(.horizontal)
                                .padding(.top, 32)
                        }

                        if subscriptionManager.hasFeatureAccess(feature: .advancedStats) {
                            allStatisticsSection
                                .padding(.top, 32)
                        } else {
                            limitedStatisticsSection
                                .padding(.top, 32)
                        }

                        compactActionButtons
                            .padding(.top, 24)
                            .padding(.bottom, 40)
                    }
                }

                VStack {
                    Spacer()
                    floatingActionBar
                        .padding(.horizontal)
                        .padding(.bottom, 100)
                }
            }
            .navigationTitle(asset.symbol)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showAddToPortfolio) {
                AddToPortfolioSheet(asset: asset)
            }
            .sheet(isPresented: $showAlertSheet) {
                PriceAlertSheet(asset: asset)
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView(requiredTier: paywallTier, featureName: paywallMessage)
            }
            .task {
                await loadChartData()
            }
        }
    }

    // MARK: - Hero Section
    private var heroSection: some View {
        VStack(spacing: 16) {
            Text(asset.symbol)
                .font(.largeTitle.bold())
                .foregroundColor(.white)

            Text(asset.name)
                .font(.title3)
                .foregroundColor(.gray)

            Text(asset.price, format: .currency(code: "USD"))
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .foregroundColor(.white)

            HStack(spacing: 12) {
                Image(systemName: isPositive ? "arrow.up.right" : "arrow.down.right")
                    .foregroundColor(accentColor)

                Text("\(isPositive ? "+" : "")\(asset.change, specifier: "%.2f")")
                    .font(.title2.bold())
                    .foregroundColor(accentColor)

                Text("(\(isPositive ? "+" : "")\(asset.changePercent, specifier: "%.2f")%)")
                    .font(.title3)
                    .foregroundColor(accentColor)
            }
        }
    }

    // MARK: - Chart Section
    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Price Chart")
                    .font(.title2.bold())
                    .foregroundColor(.white)

                Spacer()

                Picker("Range", selection: $selectedRange) {
                    ForEach(subscriptionManager.currentTier.availableTimeRanges, id: \.self) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }

            Picker("Chart Type", selection: $chartType) {
                ForEach(ChartType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            if isLoadingChart {
                ProgressView()
                    .frame(height: 300)
            } else if chartData.isEmpty {
                Text("No chart data available")
                    .foregroundColor(.gray)
                    .frame(height: 300)
            } else {
                if chartType == .candlestick && selectedRange == .oneDay {
                    Chart(chartData) { item in
                        // Wick (high-low)
                        RectangleMark(
                            x: .value("Time", item.date),
                            yStart: .value("Low", item.low),
                            yEnd: .value("High", item.high),
                            width: .fixed(4)
                        )
                        .foregroundStyle(.gray.opacity(0.4))  // Subtle wick color
                        
                        // Body (open-close)
                        RectangleMark(
                            x: .value("Time", item.date),
                            yStart: .value("Open", item.open),
                            yEnd: .value("Close", item.close),
                            width: .fixed(12)
                        )
                        .foregroundStyle(item.isBullish ? .green : .red)  // Bullish green, bearish red
                    }
                    .chartYScale(domain: .automatic)  // Auto-scale for price range
                    .chartXAxis {
                        AxisMarks(position: .bottom) { value in
                            AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .omitted)))  // Intraday time labels
                        }
                    }
                    .frame(height: 300)
                    .padding()
                } else {
                    Chart(chartData) {
                        LineMark(
                            x: .value("Date", $0.date),
                            y: .value("Price", $0.close)
                        )
                        .foregroundStyle(accentColor)
                    }
                    .frame(height: 300)
                }
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Company Overview
    private var companyOverviewSection: some View {
        StatGroupView(title: "Overview", icon: "info.circle", color: .blue) {
            StatRow(label: "Market Cap", value: asset.marketCap.map { formatLargeNumber($0) } ?? "N/A")
            StatRow(label: "Volume", value: formatVolume(asset.volume))
            StatRow(label: "52W High", value: asset.week52High.map { "$" + String(format: "%.2f", $0) } ?? "N/A")
            StatRow(label: "52W Low", value: asset.week52Low.map { "$" + String(format: "%.2f", $0) } ?? "N/A")
        }
        .padding(.horizontal)
    }

    // MARK: - Analysis Section
    private var analysisSection: some View {
        StatGroupView(title: "Technical Analysis", icon: "chart.xyaxis.line", color: .purple) {
            Text("RSI, MACD, Moving Averages coming soon...")
                .foregroundColor(.gray)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal)
    }

    // MARK: - Full Statistics
    private var allStatisticsSection: some View {
        StatGroupView(title: "Advanced Statistics", icon: "chart.bar.fill", color: .orange) {
            StatRow(label: "P/E Ratio", value: asset.peRatio.map { String(format: "%.2f", $0) } ?? "N/A")
            StatRow(label: "EPS", value: asset.eps.map { "$" + String(format: "%.2f", $0) } ?? "N/A")
            StatRow(label: "Beta", value: asset.beta.map { String(format: "%.2f", $0) } ?? "N/A")
            StatRow(label: "Dividend", value: asset.dividend.map { "$" + String(format: "%.2f", $0) } ?? "N/A")
        }
        .padding(.horizontal)
    }

    // MARK: - Limited Statistics
    private var limitedStatisticsSection: some View {
        FeatureLockView(featureName: "Advanced Statistics", requiredTier: .pro)
            .frame(height: 200)
            .padding(.horizontal)
    }

    // MARK: - Compact Action Buttons
    private var compactActionButtons: some View {
        HStack(spacing: 20) {
            Button {
                if subscriptionManager.hasFeatureAccess(feature: .portfolio) {
                    showAddToPortfolio = true
                } else {
                    paywallTier = .pro
                    paywallMessage = "Portfolio tracking is a Pro feature"
                    showPaywall = true
                }
            } label: {
                Label("Add to Portfolio", systemImage: "briefcase")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)

            Button {
                showAlertSheet = true
            } label: {
                Label("Set Alert", systemImage: "bell")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.purple)
        }
        .padding(.horizontal)
    }

    // MARK: - Floating Action Bar (FIXED: direct calls)
    private var floatingActionBar: some View {
        HStack(spacing: 20) {
//            Button {
//                $marketData.toggleWatchlist(asset)  // ← Direct call on the object
//            } label: {
//                Image(systemName: $marketData.isInWatchlist(asset) ? "star.fill" : "star")  // ← Direct call
//                    .font(.title2)
//                    .frame(width: 60, height: 60)
//                    .background(Color.white.opacity(0.15))
//                    .clipShape(Circle())
//            }

            Button {
                if subscriptionManager.hasFeatureAccess(feature: .portfolio) {
                    showAddToPortfolio = true
                } else {
                    paywallTier = .pro
                    paywallMessage = "Add to Portfolio requires Pro"
                    showPaywall = true
                }
            } label: {
                Image(systemName: "briefcase")
                    .font(.title2)
                    .frame(width: 60, height: 60)
                    .background(Color.blue)
                    .clipShape(Circle())
                    .foregroundColor(.white)
            }
        }
        .padding()
        .background(Color.black.opacity(0.7))
        .cornerRadius(30)
        .shadow(radius: 10)
    }

    // MARK: - Price Alert Sheet
    private struct PriceAlertSheet: View {
        let asset: Asset
        @Environment(\.dismiss) var dismiss
        @EnvironmentObject var alertManager: PriceAlertManager

        @State private var targetPrice = ""
        @State private var condition: AlertCondition = .above

        var body: some View {
            NavigationStack {
                Form {
                    Section("Set Price Alert for \(asset.symbol)") {
                        TextField("Target Price", text: $targetPrice)
                            .keyboardType(.decimalPad)

                        Picker("Condition", selection: $condition) {
                            ForEach(AlertCondition.allCases, id: \.self) { cond in
                                Text(cond.rawValue).tag(cond)
                            }
                        }
                    }
                }
                .navigationTitle("Price Alert")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            if let price = Double(targetPrice) {
                                let alert = PriceAlert(
                                    symbol: asset.symbol,
                                    assetName: asset.name,
                                    targetPrice: price,
                                    condition: condition
                                )
                                alertManager.addAlert(alert)
                            }
                            dismiss()
                        }
                        .disabled(targetPrice.isEmpty || Double(targetPrice) == nil)
                    }
                }
            }
        }
    }

    // MARK: - StatGroupView and StatRow
    struct StatGroupView<Content: View>: View {
        let title: String
        let icon: String
        let color: Color
        let content: Content

        init(title: String, icon: String, color: Color, @ViewBuilder content: () -> Content) {
            self.title = title
            self.icon = icon
            self.color = color
            self.content = content()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: icon)
                        .font(.subheadline)
                        .foregroundColor(color)

                    Text(title)
                        .font(.subheadline.bold())
                        .foregroundColor(.white.opacity(0.9))

                    Spacer()
                }
                .padding(.horizontal)

                VStack(spacing: 0) {
                    content
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.08), color.opacity(0.03)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(
                                    LinearGradient(
                                        colors: [color.opacity(0.3), color.opacity(0.1)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1
                                )
                        )
                )
            }
        }
    }

    struct StatRow: View {
        let label: String
        let value: String

        var body: some View {
            HStack {
                Text(label)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.7))

                Spacer()

                Text(value)
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
            }
            .padding(.vertical, 6)
        }
    }

    // MARK: - Helpers
    private func loadChartData() async {
        isLoadingChart = true
        do {
            chartData = try await marketData.fetchHistoricalData(symbol: asset.symbol, range: selectedRange)
        } catch {
            // Handle error, fallback to mock if needed
            chartData = generateMockCandleHistory()
        }
        isLoadingChart = false
    }

    private func generateMockCandleHistory() -> [Candle] {
        var points: [Candle] = []
        let intervals = 90
        var close = asset.price
        for i in 0..<intervals {
            let date = Calendar.current.date(byAdding: .minute, value: -intervals + i, to: Date())!
            let open = close
            let change = Double.random(in: -5...5)
            close += change
            let high = max(open, close) + Double.random(in: 0...2)
            let low = min(open, close) - Double.random(in: 0...2)
            points.append(Candle(date: date, open: open, high: high, low: low, close: close, volume: Double.random(in: 1000...10000)))
        }
        return points
    }

    private func formatLargeNumber(_ value: Double) -> String {
        if value >= 1_000_000_000_000 {
            return String(format: "$%.2fT", value / 1_000_000_000_000)
        } else if value >= 1_000_000_000 {
            return String(format: "$%.2fB", value / 1_000_000_000)
        } else if value >= 1_000_000 {
            return String(format: "$%.2fM", value / 1_000_000)
        }
        return String(format: "$%.2f", value)
    }

    private func formatVolume(_ value: Double) -> String {
        if value >= 1_000_000_000 {
            return String(format: "%.2fB", value / 1_000_000_000)
        } else if value >= 1_000_000 {
            return String(format: "%.2fM", value / 1_000_000)
        } else if value >= 1_000 {
            return String(format: "%.2fK", value / 1_000)
        }
        return String(format: "%.0f", value)
    }
}

#Preview {
    AppleStocksDetailView(
        asset: Asset(
            symbol: "AAPL",
            name: "Apple Inc.",
            price: 178.42,
            change: 3.21,
            changePercent: 1.83,
            volume: 89_200_000,
            kind: .stock,
            exchange: "NYSE"
        )
    )
    .environmentObject(MarketData())
    .environmentObject(PriceAlertManager())
    .environmentObject(SubscriptionManager.shared)
    .preferredColorScheme(.dark)
}
