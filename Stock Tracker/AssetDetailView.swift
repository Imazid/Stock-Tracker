import SwiftUI
import Charts
import OSLog

// MARK: - Add to Portfolio Sheet

struct AddToPortfolioSheet: View {
    @EnvironmentObject var marketData: MarketData
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme

    let asset: Asset

    @State private var sharesText = ""
    @State private var avgCostText = ""
    @FocusState private var focusedField: Field?

    enum Field { case shares, avgCost }

    private var shares: Double? {
        Double(sharesText.replacingOccurrences(of: ",", with: "."))
    }
    private var avgCost: Double? {
        Double(avgCostText.replacingOccurrences(of: ",", with: "."))
    }
    private var totalCost: Double? {
        guard let s = shares, let c = avgCost else { return nil }
        return s * c
    }
    private var unrealizedPL: Double? {
        guard let s = shares, let c = avgCost, c > 0 else { return nil }
        return (asset.price - c) * s
    }
    private var isValid: Bool {
        (shares ?? 0) > 0 && (avgCost ?? 0) > 0
    }

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        NavigationStack {
            ZStack {
                theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        assetHeader(theme: theme)
                        inputFields(theme: theme)
                        if totalCost != nil {
                            positionSummary(theme: theme)
                        }
                        addButton
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 48)
                }
            }
            .navigationTitle("Add to Portfolio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.secondary)
                }
            }
            .onAppear {
                avgCostText = String(format: "%.2f", asset.price)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    focusedField = .shares
                }
            }
        }
    }

    // MARK: - Asset Header

    private func assetHeader(theme: Theme) -> some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [.blue, .blue.opacity(0.5)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 54, height: 54)
                Text(String(asset.symbol.prefix(2)))
                    .font(.title3.bold())
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(asset.symbol)
                    .font(.title2.bold())
                    .foregroundColor(.primary)
                Text(asset.name)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(asset.price.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                    .font(.title3.bold())
                    .foregroundColor(.primary)
                HStack(spacing: 3) {
                    Image(systemName: asset.changePercent >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption2.bold())
                    Text("\(asset.changePercent >= 0 ? "+" : "")\(String(format: "%.2f", asset.changePercent))%")
                        .font(.caption.bold())
                }
                .foregroundColor(asset.changePercent >= 0 ? appTheme.positiveColor : appTheme.negativeColor)
            }
        }
        .padding(20)
        .background(LinearGradient(
            colors: [Color.blue.opacity(0.12), Color.blue.opacity(0.04)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        ))
        .cornerRadius(18)
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.blue.opacity(0.2), lineWidth: 1))
    }

    // MARK: - Input Fields

    private func inputFields(theme: Theme) -> some View {
        VStack(spacing: 14) {
            Label("Position Details", systemImage: "list.bullet.clipboard")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            inputRow(
                label: "Number of Shares",
                icon: "number",
                placeholder: "0.00",
                text: $sharesText,
                field: .shares,
                theme: theme
            )

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Average Cost per Share")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                        .padding(.leading, 2)

                    Spacer()

                    Button {
                        avgCostText = String(format: "%.2f", asset.price)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Text("Use Market Price")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(.blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }

                let isFocused = focusedField == .avgCost
                HStack(spacing: 10) {
                    Image(systemName: "dollarsign")
                        .foregroundColor(isFocused ? .blue : .secondary)
                        .frame(width: 20)
                        .animation(.easeInOut(duration: 0.15), value: isFocused)

                    TextField("0.00", text: $avgCostText)
                        .keyboardType(.decimalPad)
                        .focused($focusedField, equals: .avgCost)
                        .font(.title3.weight(.medium))
                }
                .padding(16)
                .background(isFocused ? Color.blue.opacity(0.06) : theme.glassBackground)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isFocused ? Color.blue.opacity(0.5) : theme.separator, lineWidth: 1.5)
                )
                .animation(.easeInOut(duration: 0.15), value: isFocused)
            }
        }
    }

    private func inputRow(
        label: String,
        icon: String,
        placeholder: String,
        text: Binding<String>,
        field: Field,
        theme: Theme
    ) -> some View {
        let isFocused = focusedField == field
        return VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .padding(.leading, 2)

            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundColor(isFocused ? .blue : .secondary)
                    .frame(width: 20)
                    .animation(.easeInOut(duration: 0.15), value: isFocused)

                TextField(placeholder, text: text)
                    .keyboardType(.decimalPad)
                    .focused($focusedField, equals: field)
                    .font(.title3.weight(.medium))
            }
            .padding(16)
            .background(isFocused ? Color.blue.opacity(0.06) : theme.glassBackground)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isFocused ? Color.blue.opacity(0.5) : theme.separator, lineWidth: 1.5)
            )
            .animation(.easeInOut(duration: 0.15), value: isFocused)
        }
    }

    // MARK: - Position Summary

    private func positionSummary(theme: Theme) -> some View {
        VStack(spacing: 14) {
            Label("Position Summary", systemImage: "chart.bar.doc.horizontal")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 10) {
                summaryRow("Shares", value: shares.map { String(format: "%.4f", $0) } ?? "—")
                summaryRow("Avg Cost", value: avgCost.map { "$\(String(format: "%.2f", $0))" } ?? "—")
                Divider().opacity(0.6)
                summaryRow(
                    "Total Cost",
                    value: totalCost.map { "$\(String(format: "%.2f", $0))" } ?? "—",
                    bold: true
                )
                if let pl = unrealizedPL {
                    summaryRow(
                        "Unrealized P/L",
                        value: "\(pl >= 0 ? "+" : "")$\(String(format: "%.2f", pl))",
                        valueColor: pl >= 0 ? appTheme.positiveColor : appTheme.negativeColor
                    )
                }
            }
            .padding(16)
            .background(theme.glassBackground)
            .cornerRadius(14)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.separator, lineWidth: 0.5))
        }
    }

    private func summaryRow(
        _ label: String,
        value: String,
        bold: Bool = false,
        valueColor: Color? = nil
    ) -> some View {
        HStack {
            Text(label)
                .font(bold ? .subheadline.weight(.semibold) : .subheadline)
                .foregroundColor(bold ? .primary : .secondary)
            Spacer()
            Text(value)
                .font(bold ? .subheadline.weight(.bold) : .subheadline.weight(.medium))
                .foregroundColor(valueColor ?? (bold ? .primary : .secondary))
        }
    }

    // MARK: - Add Button

    private var addButton: some View {
        Button {
            guard let s = shares, let c = avgCost, s > 0, c > 0 else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            marketData.addToPortfolio(asset: asset, shares: s, avgCost: c)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill").font(.title3)
                Text("Add to Portfolio").font(.headline)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                isValid
                    ? LinearGradient(colors: [.blue, Color.blue.opacity(0.7)],
                                     startPoint: .leading, endPoint: .trailing)
                    : LinearGradient(colors: [Color.gray.opacity(0.35), Color.gray.opacity(0.25)],
                                     startPoint: .leading, endPoint: .trailing)
            )
            .cornerRadius(16)
            .shadow(color: isValid ? Color.blue.opacity(colorScheme == .dark ? 0.35 : 0.10) : .clear, radius: 12, y: 6)
        }
        .disabled(!isValid)
        .animation(.easeInOut(duration: 0.2), value: isValid)
    }
}

struct AssetDetailView: View {
    @EnvironmentObject var marketData: MarketData
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme

    let asset: Asset

    enum ChartType: String, CaseIterable {
        case line   = "Line"
        case candle = "Candle"
    }

    @State private var selectedRange: TimeRange = .oneMonth
    @State private var chartType: ChartType = .line
    @State private var priceHistory: [PricePoint] = []
    @State private var candleHistory: [Candle] = []
    @State private var showAddToPortfolio = false
    @State private var showAddAlert = false
    @State private var selectedPrice: PricePoint?
    @State private var isLoading = false

    // AI Summary
    @State private var aiSummary: String = ""
    @State private var aiSummaryLoading = false
    @State private var aiSummaryError: String?
    @State private var aiSummaryLoaded = false
    @State private var aiGlowRotation: Double = 0
    private let aiService = AIAgentService()

    // Fundamentals (Fiscal.ai or FMP)
    @State private var fiscalData: FiscalFundamentals?
    @State private var fiscalLoading = false
    @State private var fundamentalsSource: String = ""

    // Ranges shown in the picker — filtered to what the current tier allows.
    private var displayedRanges: [TimeRange] {
        let all: [TimeRange] = [.oneDay, .oneWeek, .oneMonth, .threeMonths, .sixMonths, .ytd, .oneYear, .fiveYears]
        let available = subscriptionManager.currentTier.availableTimeRanges
        return all.filter { available.contains($0) }
    }

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        ZStack {
            theme.backgroundGradient
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    headerSection
                    chartSection
                    statsSection
                    aiSummarySection
                    portfolioSection
                    newsSection
                }
                .padding()
            }
            .refreshable {
                await marketData.refreshFromAPI()
                await loadPriceHistory()
            }
        }
        .task {
            // Clamp selected range to what the tier allows (e.g. if downgraded)
            if !displayedRanges.contains(selectedRange) {
                selectedRange = displayedRanges.last ?? .oneMonth
            }
            await loadPriceHistory()
            if asset.kind == .stock {
                await loadFiscalFundamentals()
            }
        }
        .onChange(of: selectedRange) { _, _ in
            Task { await loadPriceHistory() }
        }
        .onChange(of: chartType) { _, _ in
            Task { await loadPriceHistory() }
        }
        .sheet(isPresented: $showAddToPortfolio) {
            AddToPortfolioSheet(asset: asset)
        }
        .sheet(isPresented: $showAddAlert) {
            AddPriceAlertSheet(asset: asset)
        }
    }

    private var headerSection: some View {
        let theme = Theme(colorScheme: colorScheme)
        return VStack(alignment: .leading, spacing: 12) {
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
                        .foregroundColor(theme.primaryText)
                    Text(asset.name)
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(formatPrice(selectedPrice?.price ?? asset.price))
                        .font(.title2.bold())
                        .foregroundColor(theme.primaryText)

                    if selectedPrice == nil {
                        HStack(spacing: 4) {
                            Image(systemName: asset.isPositive ? "arrow.up.right" : "arrow.down.right")
                            Text(formatChange(asset.change, asset.changePercent))
                        }
                        .font(.caption)
                        .foregroundColor(asset.isPositive ? appTheme.positiveColor : appTheme.negativeColor)
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
        let theme = Theme(colorScheme: colorScheme)
        let isEmpty = chartType == .line ? priceHistory.isEmpty : candleHistory.isEmpty

        return VStack(alignment: .leading, spacing: 12) {
            // Header row: title + Line/Candle toggle (candle only for stocks)
            HStack {
                Text("Price History")
                    .font(.headline)
                    .foregroundColor(theme.primaryText)

                Spacer()

                if asset.kind == .stock {
                    Picker("Chart", selection: $chartType) {
                        ForEach(ChartType.allCases, id: \.self) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 130)
                }
            }

            if isLoading {
                RoundedRectangle(cornerRadius: 16)
                    .fill(theme.chartPlaceholder)
                    .frame(height: 280)
                    .overlay(ProgressView().tint(theme.progressTint))
            } else if isEmpty {
                RoundedRectangle(cornerRadius: 16)
                    .fill(theme.chartPlaceholder)
                    .frame(height: 280)
                    .overlay(
                        VStack(spacing: 8) {
                            Image(systemName: "chart.xyaxis.line")
                                .font(.largeTitle).foregroundColor(.gray)
                            Text("No data available")
                                .font(.caption).foregroundColor(.gray)
                        }
                    )
            } else if chartType == .candle {
                candlestickChart.frame(height: 280)
            } else {
                lineChart.frame(height: 280)
            }

            timeRangeSelector
        }
    }

    // MARK: - Line Chart

    private var lineChart: some View {
        let theme = Theme(colorScheme: colorScheme)
        let prices  = priceHistory.map { $0.price }
        let minP    = prices.min() ?? 0
        let maxP    = prices.max() ?? 1
        let range   = maxP - minP
        let padding = range > 0 ? range * 0.08 : maxP * 0.05
        let yMin    = max(0, minP - padding)
        let yMax    = maxP + padding
        let isUp    = (priceHistory.last?.price ?? 0) >= (priceHistory.first?.price ?? 0)
        let lineColor: Color = isUp ? .green : .red

        return Chart(priceHistory) { point in
            // Area fill — fills from 0, chartYScale clips the visible range to yMin...yMax
            AreaMark(
                x: .value("Date", point.date),
                y: .value("Price", point.price)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [lineColor.opacity(0.25), lineColor.opacity(0.0)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .interpolationMethod(.catmullRom)

            // Line
            LineMark(
                x: .value("Date", point.date),
                y: .value("Price", point.price)
            )
            .foregroundStyle(lineColor)
            .lineStyle(StrokeStyle(lineWidth: 2.5))
            .interpolationMethod(.catmullRom)
        }
        .chartYScale(domain: yMin...yMax)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { val in
                AxisGridLine().foregroundStyle(Color.gray.opacity(0.15))
                AxisValueLabel {
                    if let v = val.as(Double.self) {
                        Text(formatAxisPrice(v))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .background(theme.chartPlaceholder)
        .cornerRadius(16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(FinancialAccessibility.chartDescription(
            assetName: asset.name,
            timeRange: selectedRange.rawValue,
            dataPointCount: priceHistory.count,
            trend: isUp ? "upward" : "downward"
        ))
    }

    // MARK: - Candlestick Chart

    private var candlestickChart: some View {
        let theme = Theme(colorScheme: colorScheme)
        let lows   = candleHistory.map { $0.low }
        let highs  = candleHistory.map { $0.high }
        let minP   = lows.min() ?? 0
        let maxP   = highs.max() ?? 1
        let rng    = maxP - minP
        let pad    = rng > 0 ? rng * 0.08 : maxP * 0.05
        let yMin   = max(0, minP - pad)
        let yMax   = maxP + pad

        return Chart(candleHistory) { candle in
            // High-low wick
            RuleMark(
                x: .value("Date", candle.date),
                yStart: .value("Low",  candle.low),
                yEnd:   .value("High", candle.high)
            )
            .lineStyle(StrokeStyle(lineWidth: 1.5))
            .foregroundStyle(candle.isBullish ? Color.green : Color.red)

            // Open-close body
            BarMark(
                x: .value("Date", candle.date),
                yStart: .value("Open",  min(candle.open, candle.close)),
                yEnd:   .value("Close", max(candle.open, candle.close)),
                width: .ratio(0.65)
            )
            .foregroundStyle(candle.isBullish ? Color.green : Color.red)
            .cornerRadius(1)
        }
        .chartYScale(domain: yMin...yMax)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { val in
                AxisGridLine().foregroundStyle(Color.gray.opacity(0.15))
                AxisValueLabel {
                    if let v = val.as(Double.self) {
                        Text(formatAxisPrice(v))
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
        }
        .background(theme.chartPlaceholder)
        .cornerRadius(16)
    }

    // MARK: - Time Range Selector

    private var timeRangeSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(displayedRanges, id: \.self) { range in
                    Button {
                        selectedRange = range
                    } label: {
                        Text(range.rawValue)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(
                                selectedRange == range
                                    ? Color.blue
                                    : (colorScheme == .dark ? Color(UIColor.systemGray5) : Color(red: 0.929, green: 0.910, blue: 0.878))
                            )
                            .foregroundColor(selectedRange == range ? .white : .primary)
                            .cornerRadius(20)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Axis Helpers

    private func formatAxisPrice(_ v: Double) -> String {
        v.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates)
    }

    private var statsSection: some View {
        let theme = Theme(colorScheme: colorScheme)
        let f = fiscalData

        // Use Fiscal.ai data when available, fall back to existing asset data
        let marketCap = f?.marketCap ?? asset.marketCap ?? 0
        let pe = f?.peRatio ?? asset.peRatio ?? 0
        let epsVal = f?.eps ?? asset.eps ?? 0
        let high52 = f?.week52High ?? asset.week52High ?? 0
        let low52 = f?.week52Low ?? asset.week52Low ?? 0
        let avgVol = f?.avgVolume ?? asset.avgVolume ?? 0
        let div = f?.dividend ?? asset.dividend ?? 0
        let betaVal = f?.beta ?? asset.beta ?? 0

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Statistics")
                    .font(.headline)
                    .foregroundColor(theme.primaryText)

                Spacer()

                if fiscalLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                } else if fiscalData != nil && !fundamentalsSource.isEmpty {
                    Text(fundamentalsSource)
                        .font(.caption2.weight(.medium))
                        .foregroundColor(.purple)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.12))
                        .cornerRadius(4)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 16) {
                StatCard(label: "Market Cap", value: formatLargeNumber(marketCap))
                StatCard(label: "P/E Ratio", value: pe > 0 ? String(format: "%.2f", pe) : "—")
                StatCard(label: "EPS", value: epsVal != 0 ? String(format: "%.2f", epsVal) : "—")
                StatCard(label: "52W High", value: high52 > 0 ? formatPrice(high52) : "—")
                StatCard(label: "52W Low", value: low52 > 0 ? formatPrice(low52) : "—")
                StatCard(label: "Volume", value: formatVolume(asset.volume))
                StatCard(label: "Avg Volume", value: avgVol > 0 ? formatVolume(avgVol) : "—")
                StatCard(label: "Dividend", value: div > 0 ? String(format: "%.2f%%", div) : "—")
                StatCard(label: "Beta", value: betaVal > 0 ? String(format: "%.2f", betaVal) : "—")

                // Extra fundamentals from Fiscal.ai
                if let revenue = f?.revenue, revenue > 0 {
                    StatCard(label: "Revenue", value: formatLargeNumber(revenue))
                }
                if let margin = f?.profitMargin, margin != 0 {
                    StatCard(label: "Profit Margin", value: String(format: "%.1f%%", margin * 100))
                }
                if let roe = f?.roe, roe != 0 {
                    StatCard(label: "ROE", value: String(format: "%.1f%%", roe * 100))
                }
                if let dte = f?.debtToEquity, dte > 0 {
                    StatCard(label: "Debt/Equity", value: String(format: "%.2f", dte))
                }
                if let cr = f?.currentRatio, cr > 0 {
                    StatCard(label: "Current Ratio", value: String(format: "%.2f", cr))
                }
            }

            // Sector/Industry from Fiscal.ai
            if let sector = f?.sector, !sector.isEmpty {
                HStack(spacing: 8) {
                    if let industry = f?.industry, !industry.isEmpty {
                        Text("\(sector) · \(industry)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text(sector)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - AI Summary

    private var aiSummarySection: some View {
        let theme = Theme(colorScheme: colorScheme)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.purple, .blue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text("AI Analysis")
                    .font(.headline)
                    .foregroundColor(theme.primaryText)

                Spacer()

                if aiSummaryLoaded && !aiSummaryLoading {
                    Button {
                        Task { await loadAISummary() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                    }
                }
            }

            if aiSummaryLoading {
                HStack(spacing: 12) {
                    ProgressView()
                        .tint(.purple)
                    Text("Analyzing \(asset.symbol)...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(theme.chartPlaceholder)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(
                            AngularGradient(
                                colors: [
                                    .purple.opacity(0.5),
                                    .blue.opacity(0.3),
                                    .cyan.opacity(0.2),
                                    .blue.opacity(0.3),
                                    .purple.opacity(0.5)
                                ],
                                center: .center,
                                angle: .degrees(aiGlowRotation)
                            ),
                            lineWidth: 1.5
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(
                            AngularGradient(
                                colors: [
                                    .purple.opacity(0.3),
                                    .clear,
                                    .blue.opacity(0.25),
                                    .clear,
                                    .purple.opacity(0.3)
                                ],
                                center: .center,
                                angle: .degrees(aiGlowRotation)
                            ),
                            lineWidth: 6
                        )
                        .blur(radius: 6)
                )
                .onAppear {
                    aiGlowRotation = 0
                    withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
                        aiGlowRotation = 360
                    }
                }
            } else if let error = aiSummaryError {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title3)
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    Button {
                        Task { await loadAISummary() }
                    } label: {
                        Text("Try Again")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.purple.opacity(0.8))
                            .cornerRadius(8)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(theme.chartPlaceholder)
                .cornerRadius(14)
            } else if !aiSummary.isEmpty {
                Text(aiSummary)
                    .font(.subheadline)
                    .foregroundColor(theme.primaryText.opacity(0.9))
                    .lineSpacing(4)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(theme.chartPlaceholder)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(
                                AngularGradient(
                                    colors: [
                                        .purple.opacity(0.6),
                                        .blue.opacity(0.4),
                                        .cyan.opacity(0.3),
                                        .blue.opacity(0.4),
                                        .purple.opacity(0.6)
                                    ],
                                    center: .center,
                                    angle: .degrees(aiGlowRotation)
                                ),
                                lineWidth: 1.5
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(
                                AngularGradient(
                                    colors: [
                                        .purple.opacity(0.25),
                                        .clear,
                                        .blue.opacity(0.2),
                                        .clear,
                                        .purple.opacity(0.25)
                                    ],
                                    center: .center,
                                    angle: .degrees(aiGlowRotation)
                                ),
                                lineWidth: 4
                            )
                            .blur(radius: 4)
                    )
                    .onAppear {
                        withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) {
                            aiGlowRotation = 360
                        }
                    }

                Text("Powered by ChatGPT. Not financial advice.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Button {
                    Task { await loadAISummary() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .font(.subheadline)
                        Text("Generate AI Analysis")
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(
                            colors: [.purple, .blue],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(12)
                }
            }
        }
    }

    private func loadAISummary() async {
        aiSummaryLoading = true
        aiSummaryError = nil

        let kind = asset.kind == .crypto ? "cryptocurrency" : "stock"
        let priceStr = String(format: "%.2f", asset.price)
        let changeStr = String(format: "%.2f", asset.changePercent)

        let f = fiscalData
        var statsContext = ""
        let pe = f?.peRatio ?? asset.peRatio
        let epsV = f?.eps ?? asset.eps
        let mc = f?.marketCap ?? asset.marketCap
        let div = f?.dividend ?? asset.dividend
        let betaV = f?.beta ?? asset.beta
        let h52 = f?.week52High ?? asset.week52High
        let l52 = f?.week52Low ?? asset.week52Low

        if let pe, pe > 0 { statsContext += " P/E: \(String(format: "%.1f", pe))." }
        if let epsV, epsV != 0 { statsContext += " EPS: \(String(format: "%.2f", epsV))." }
        if let mc, mc > 0 { statsContext += " Market Cap: \(formatLargeNumber(mc))." }
        if let div, div > 0 { statsContext += " Dividend Yield: \(String(format: "%.2f%%", div))." }
        if let betaV, betaV > 0 { statsContext += " Beta: \(String(format: "%.2f", betaV))." }
        if let h52, h52 > 0 { statsContext += " 52W High: \(String(format: "%.2f", h52))." }
        if let l52, l52 > 0 { statsContext += " 52W Low: \(String(format: "%.2f", l52))." }
        if let revenue = f?.revenue, revenue > 0 { statsContext += " Revenue: \(formatLargeNumber(revenue))." }
        if let margin = f?.profitMargin, margin != 0 { statsContext += " Profit Margin: \(String(format: "%.1f%%", margin * 100))." }
        if let roe = f?.roe, roe != 0 { statsContext += " ROE: \(String(format: "%.1f%%", roe * 100))." }
        if let sector = f?.sector, !sector.isEmpty { statsContext += " Sector: \(sector)." }

        let prompt = """
        Give a concise 3-4 sentence investment summary for \(asset.name) (\(asset.symbol)), a \(kind). \
        Current price: $\(priceStr). Daily change: \(changeStr)%.\(statsContext) \
        Cover: current sentiment, key metrics outlook, and one thing investors should watch. \
        Be balanced and factual. Do not give buy/sell recommendations.
        """

        let systemMsg = ChatMessage(
            text: "You are a concise financial analyst. Provide brief, factual investment summaries. Never recommend buying or selling. Always note this is not financial advice.",
            isUser: false,
            role: "system"
        )
        let userMsg = ChatMessage(text: prompt, isUser: true)

        do {
            let response = try await aiService.sendMessage(messages: [systemMsg, userMsg])
            aiSummary = response
            aiSummaryLoaded = true
        } catch {
            aiSummaryError = "Unable to generate analysis. Check your API key or try again."
        }

        aiSummaryLoading = false
    }

    private var portfolioSection: some View {
        let theme = Theme(colorScheme: colorScheme)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Portfolio Actions")
                .font(.headline)
                .foregroundColor(theme.primaryText)

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
            .background(appTheme.positiveColor)
            .cornerRadius(12)
        }
    }

    private var newsSection: some View {
        let theme = Theme(colorScheme: colorScheme)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Related News")
                .font(.headline)
                .foregroundColor(theme.primaryText)

            ForEach(marketData.newsArticles.filter { $0.relatedSymbols.contains(asset.symbol) }) { article in
                NewsCompactCard(article: article)
            }
        }
    }

    private func loadPriceHistory() async {
        isLoading = true
        if chartType == .candle {
            candleHistory = (try? await marketData.fetchHistoricalData(for: asset, range: selectedRange)) ?? []
        } else {
            priceHistory = await marketData.fetchPriceHistory(for: asset, range: selectedRange)
        }
        isLoading = false
    }

    private func loadFiscalFundamentals() async {
        fiscalLoading = true

        if APIService.isFiscalSupported(symbol: asset.symbol) {
            // Use Fiscal.ai for supported free-tier companies
            do {
                fiscalData = try await APIService.shared.fetchFiscalFundamentals(
                    symbol: asset.symbol,
                    exchange: asset.exchange
                )
                fundamentalsSource = "Fiscal.ai"
            } catch {
                AppLogger.api.debug("Fiscal.ai fetch failed for \(asset.symbol), falling back to FMP")
                await loadFMPFundamentals()
            }
        } else {
            // Use FMP for all other companies
            await loadFMPFundamentals()
        }

        fiscalLoading = false
    }

    private func loadFMPFundamentals() async {
        async let profileTask = FMPService.shared.fetchProfile(symbol: asset.symbol)
        async let ratiosTask = FMPService.shared.fetchRatios(symbol: asset.symbol)
        async let quoteTask = FMPService.shared.fetchQuote(symbol: asset.symbol)

        let profile = await profileTask
        let ratios = await ratiosTask
        let quote = await quoteTask

        // Only set if we got at least some data
        guard profile != nil || ratios != nil || quote != nil else { return }

        fiscalData = FiscalFundamentals(
            marketCap: profile?.mktCap ?? quote?.marketCap,
            peRatio: ratios?.resolvedPE ?? quote?.pe,
            eps: quote?.eps,
            beta: profile?.beta,
            dividend: ratios?.dividendYield,
            week52High: quote?.yearHigh,
            week52Low: quote?.yearLow,
            avgVolume: quote?.avgVolume.map { Double($0) },
            revenue: nil,
            profitMargin: ratios?.netProfitMargin,
            roe: nil,
            debtToEquity: ratios?.debtEquityRatio,
            currentRatio: nil,
            sector: profile?.sector,
            industry: profile?.industry,
            description: profile?.description,
            employees: profile?.fullTimeEmployees.flatMap { Int($0) }
        )
        fundamentalsSource = "FMP"
    }

    private func formatPrice(_ price: Double) -> String {
        return price.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates)
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

    private var currencySymbol: String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .currency
        fmt.currencyCode = marketData.preferredCurrency
        fmt.locale = Locale.current
        return fmt.currencySymbol ?? "$"
    }

    private func formatLargeNumber(_ value: Double) -> String {
        let rate = marketData.preferredCurrency == "USD" ? 1.0 : (marketData.exchangeRates[marketData.preferredCurrency] ?? 1.0)
        let converted = value * rate
        let sym = currencySymbol
        if converted >= 1_000_000_000_000 { return String(format: "\(sym)%.2fT", converted / 1_000_000_000_000) }
        if converted >= 1_000_000_000     { return String(format: "\(sym)%.2fB", converted / 1_000_000_000) }
        if converted >= 1_000_000         { return String(format: "\(sym)%.2fM", converted / 1_000_000) }
        return String(format: "\(sym)%.2f", converted)
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

struct StatisticCard: View {
    let title: String
    let value: String
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundColor(.gray)
            Text(value)
                .font(.headline)
                .foregroundColor(theme.primaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.chartPlaceholder)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 0.5)
                )
        )
    }
}
