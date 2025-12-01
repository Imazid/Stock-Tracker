import SwiftUI
import Charts

struct PortfolioView: View {
    @EnvironmentObject var marketData: MarketData
    @State private var selectedRange: TimeRange = .oneMonth
    @State private var selectedAsset: Asset?
    @State private var filter: AssetKind = .stock
    @State private var searchText: String = ""
    
    private var filteredHoldings: [PortfolioHolding] {
        var holdings = marketData.portfolio.filter { $0.asset.kind == filter }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            let lower = q.lowercased()
            holdings = holdings.filter {
                $0.asset.symbol.lowercased().contains(lower) ||
                $0.asset.name.lowercased().contains(lower)
            }
        }
        return holdings
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                filterHeader
                headerCard
                performanceSection
                allocationSection

                HStack {
                    Text("Holdings")
                        .font(.headline)
                        .foregroundColor(.white)
                    Spacer()
                    Text("\(filteredHoldings.count) positions")
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                if filteredHoldings.isEmpty {
                    emptyState
                } else {
                    holdingsList
                }
            }
            .padding()
        }
        .sheet(item: $selectedAsset) { asset in
            AssetDetailView(asset: asset)
        }
    }
    
    // MARK: - Filter Header
    
    private var filterHeader: some View {
        VStack(spacing: 12) {
            HStack {
                Picker("Type", selection: $filter) {
                    Text("Stocks").tag(AssetKind.stock)
                    Text("Crypto").tag(AssetKind.crypto)
                }
                .pickerStyle(.segmented)
            }
            
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.gray)
                TextField("Search holdings…", text: $searchText)
                    .foregroundColor(.white)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                    }
                }
            }
            .padding(10)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                    
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.1),
                                    Color.white.opacity(0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                }
            )
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Portfolio Value")
                .font(.caption)
                .foregroundColor(.gray)

            Text("$\(marketData.totalPortfolioValue, specifier: "%.2f")")
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(.white)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Today")
                        .font(.caption2)
                        .foregroundColor(.gray)

                    HStack(spacing: 4) {
                        Image(systemName: marketData.dailyProfitLoss >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.caption2)
                        Text("\(marketData.dailyProfitLoss >= 0 ? "+" : "")$\(abs(marketData.dailyProfitLoss), specifier: "%.2f")")
                            .font(.caption.bold())
                        Text("(\(marketData.dailyProfitLoss >= 0 ? "+" : "")\(marketData.dailyProfitLossPercent, specifier: "%.2f")%)")
                            .font(.caption2)
                    }
                    .foregroundColor(marketData.dailyProfitLoss >= 0 ? .green : .red)
                }

                Divider()
                    .frame(height: 30)
                    .background(Color.white.opacity(0.2))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Total P/L")
                        .font(.caption2)
                        .foregroundColor(.gray)

                    HStack(spacing: 4) {
                        Image(systemName: marketData.totalProfitLoss >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.caption2)
                        Text("\(marketData.totalProfitLoss >= 0 ? "+" : "")$\(abs(marketData.totalProfitLoss), specifier: "%.2f")")
                            .font(.caption.bold())
                        Text("(\(marketData.totalProfitLoss >= 0 ? "+" : "")\(marketData.totalProfitLossPercent, specifier: "%.2f")%)")
                            .font(.caption2)
                    }
                    .foregroundColor(marketData.totalProfitLoss >= 0 ? .green : .red)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Performance

    private var performanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Performance")
                    .font(.headline)
                    .foregroundColor(.white)

                Spacer()

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(TimeRange.allCases, id: \.self) { range in
                            Button {
                                withAnimation {
                                    selectedRange = range
                                }
                            } label: {
                                Text(range.rawValue)
                                    .font(.caption.bold())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(selectedRange == range
                                                  ? Color.white.opacity(0.2)
                                                  : Color.white.opacity(0.06))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                                            )
                                    )
                                    .foregroundColor(.white)
                            }
                        }
                    }
                }
            }

            if marketData.portfolioHistory.isEmpty {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.05))
                    .frame(height: 180)
            } else {
                let history = filteredHistory(for: selectedRange)

                Chart(history) { snapshot in
                    LineMark(
                        x: .value("Date", snapshot.date),
                        y: .value("Value", snapshot.totalValue)
                    )
                    .lineStyle(.init(lineWidth: 2.5))
                    .foregroundStyle(Color.green)

                    AreaMark(
                        x: .value("Date", snapshot.date),
                        y: .value("Value", snapshot.totalValue)
                    )
                    .foregroundStyle(Color.green.opacity(0.3))
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .trailing) { _ in
                        AxisValueLabel()
                            .foregroundStyle(.gray)
                            .font(.caption2)
                    }
                }
                .frame(height: 180)
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.white.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                        )
                )
            }
        }
    }

    private func filteredHistory(for range: TimeRange) -> [PortfolioSnapshot] {
        let history = marketData.portfolioHistory
        guard let lastDate = history.last?.date else { return history }
        let calendar = Calendar.current

        let fromDate: Date
        switch range {
        case .oneDay:
            fromDate = calendar.date(byAdding: .day, value: -1, to: lastDate) ?? lastDate
        case .oneWeek:
            fromDate = calendar.date(byAdding: .day, value: -7, to: lastDate) ?? lastDate
        case .oneMonth:
            fromDate = calendar.date(byAdding: .month, value: -1, to: lastDate) ?? lastDate
        case .threeMonths:
            fromDate = calendar.date(byAdding: .month, value: -3, to: lastDate) ?? lastDate
        case .sixMonths:
            fromDate = calendar.date(byAdding: .month, value: -6, to: lastDate) ?? lastDate
        case .ytd:
            let comps = calendar.dateComponents([.year], from: lastDate)
            fromDate = calendar.date(from: comps) ?? lastDate
        case .oneYear:
            fromDate = calendar.date(byAdding: .year, value: -1, to: lastDate) ?? lastDate
        case .twoYears:
            fromDate = calendar.date(byAdding: .year, value: -2, to: lastDate) ?? lastDate
        case .fiveYears:
            fromDate = calendar.date(byAdding: .year, value: -5, to: lastDate) ?? lastDate
        case .tenYears:
            fromDate = calendar.date(byAdding: .year, value: -10, to: lastDate) ?? lastDate
        case .all:
            return history
        }

        return history.filter { $0.date >= fromDate }
    }

    // MARK: - Allocation

    private var allocationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Allocation")
                .font(.headline)
                .foregroundColor(.white)

            if marketData.portfolio.isEmpty {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.05))
                    .frame(height: 180)
            } else {
                HStack(spacing: 18) {
                    Chart(marketData.portfolio) { holding in
                        SectorMark(
                            angle: .value("Value", holding.currentValue),
                            innerRadius: .ratio(0.6),
                            angularInset: 2
                        )
                        .cornerRadius(6)
                        .foregroundStyle(by: .value("Symbol", holding.asset.symbol))
                    }
                    .frame(width: 140, height: 140)

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(marketData.portfolio.prefix(5)) { holding in
                            HStack {
                                Circle()
                                    .fill(colorForSymbol(holding.asset.symbol))
                                    .frame(width: 8, height: 8)
                                Text(holding.asset.symbol)
                                    .font(.caption.bold())
                                    .foregroundColor(.white)
                                Spacer()
                                let total = marketData.totalPortfolioValue
                                let pct = total > 0 ? (holding.currentValue / total) * 100 : 0
                                Text("\(pct, specifier: "%.1f")%")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        }
                    }
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.white.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                        )
                )
            }
        }
    }

    private func colorForSymbol(_ symbol: String) -> Color {
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .mint, .cyan, .indigo]
        let index = abs(symbol.hashValue) % palette.count
        return palette[index]
    }

    // MARK: - Holdings with swipe actions (using List)

    private var holdingsList: some View {
        // Wrap in a container to maintain layout
        VStack(spacing: 0) {
            ForEach(filteredHoldings) { holding in
                Button {
                    selectedAsset = holding.asset
                } label: {
                    HoldingRow(holding: holding)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) {
                        withAnimation {
                            marketData.removeFromPortfolio(holding)
                        }
                    } label: {
                        Label("Remove from Portfolio", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        withAnimation {
                            marketData.removeFromPortfolio(holding)
                        }
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
                .padding(.bottom, 12)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: filter == .stock ? "chart.bar.fill" : "bitcoinsign.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.gray.opacity(0.5))
            Text("No \(filter == .stock ? "stock" : "crypto") holdings")
                .font(.headline)
                .foregroundColor(.white)
            Text("Add \(filter == .stock ? "stock" : "crypto") positions from the asset detail screen.")
                .font(.subheadline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - Holding row with improved glass effect

struct HoldingRow: View {
    let holding: PortfolioHolding

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(holding.asset.symbol)
                    .font(.headline)
                    .foregroundColor(.white)
                Text(holding.asset.name)
                    .font(.caption)
                    .foregroundColor(.gray)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("$\(holding.currentValue, specifier: "%.2f")")
                    .font(.headline)
                    .foregroundColor(.white)
                Text("$\(holding.asset.price, specifier: "%.2f")")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }

            VStack(alignment: .trailing, spacing: 4) {
                let pl = holding.profitLoss
                let pct = holding.profitLossPercent

                HStack(spacing: 4) {
                    Image(systemName: pl >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption2)
                    Text("\(pl >= 0 ? "+" : "")$\(abs(pl), specifier: "%.2f")")
                        .font(.caption.bold())
                }
                Text("(\(pct >= 0 ? "+" : "")\(pct, specifier: "%.2f")%)")
                    .font(.caption2)
                .foregroundColor(pl >= 0 ? .green : .red)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )
        )
    }
}
