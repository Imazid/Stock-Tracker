//
//  StockSearchView.swift
//  Stock Tracker
//

import SwiftUI
import Combine
import Speech
import AVFoundation

// MARK: - Stock Search Tab View

struct StockSearchView: View {
    @EnvironmentObject var marketData: MarketData
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme

    @State private var searchText = ""
    @State private var selectedAsset: Asset?
    @StateObject private var speech = SearchVoiceRecognizer()

    private var results: [Asset] { marketData.searchResults }
    private var isSearching: Bool { !searchText.isEmpty && results.isEmpty }

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        NavigationStack {
            ZStack {
                (colorScheme == .dark ? Color.black : theme.background)
                    .ignoresSafeArea()

                Group {
                    if searchText.isEmpty {
                        popularGrid(theme: theme)
                    } else if isSearching {
                        searchingIndicator
                    } else if results.isEmpty {
                        noResultsView(theme: theme)
                    } else {
                        resultsList(theme: theme)
                    }
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.large)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Stocks, ETFs, crypto..."
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    micButton
                }
            }
            .onChange(of: searchText) { _, newValue in
                guard !newValue.trimmingCharacters(in: .whitespaces).isEmpty else {
                    marketData.searchResults = []
                    return
                }
                marketData.searchAssets(query: newValue, kind: .stock)
            }
            .onDisappear {
                if speech.isRecording { speech.stopRecording() }
            }
            .alert("Microphone Access Needed", isPresented: $speech.permissionDenied) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enable Microphone and Speech Recognition in Settings to use voice search.")
            }
            .sheet(item: $selectedAsset) { asset in
                AppleStocksDetailView(
                    stock: makeDetailedStock(from: asset),
                    asset: asset,
                    position: nil
                )
            }
        }
    }

    // MARK: - Mic Button

    private var micButton: some View {
        Button {
            speech.toggle { transcript in
                searchText = transcript
            }
        } label: {
            ZStack {
                if speech.isRecording {
                    Circle()
                        .fill(Color.red.opacity(0.12))
                        .frame(width: 36, height: 36)
                }
                Image(systemName: speech.isRecording ? "waveform.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 24))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundColor(speech.isRecording ? .red : .blue)
            }
            .animation(.easeInOut(duration: 0.2), value: speech.isRecording)
        }
    }

    // MARK: - Popular Grid

    private let popularStocks = ["AAPL", "TSLA", "NVDA", "MSFT", "GOOGL", "AMZN", "META", "NFLX", "AMD", "ORCL"]
    private let popularASX = ["BHP.AX", "CBA.AX", "CSL.AX", "NAB.AX", "WBC.AX", "ANZ.AX", "FMG.AX"]

    private func popularGrid(theme: Theme) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // Hero
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.blue.opacity(0.12), Color.purple.opacity(0.08)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 80, height: 80)

                        Image(systemName: "chart.line.uptrend.xyaxis.circle.fill")
                            .font(.system(size: 38))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundColor(.blue)
                    }

                    VStack(spacing: 6) {
                        Text("Discover & Invest")
                            .font(.title3.weight(.semibold))
                            .foregroundColor(theme.primaryText)

                        Text("Search for any stock, ETF, or cryptocurrency")
                            .font(.subheadline)
                            .foregroundColor(theme.secondaryText)
                            .multilineTextAlignment(.center)
                    }

                    HStack(spacing: 5) {
                        Image(systemName: "mic.fill")
                            .font(.caption2)
                        Text("Tap the mic to search by voice")
                            .font(.caption)
                    }
                    .foregroundColor(theme.secondaryText.opacity(0.6))
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 20)

                // Popular US
                popularSection(
                    title: "Trending",
                    icon: "flame.fill",
                    symbols: popularStocks,
                    theme: theme
                )

                // Popular ASX
                popularASXSection(theme: theme)

                // Market categories
                categoriesSection(theme: theme)
            }
            .padding(.bottom, 40)
        }
    }

    private func popularSection(title: String, icon: String, symbols: [String], theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(symbols, id: \.self) { symbol in
                        Button {
                            searchText = symbol
                        } label: {
                            Text(symbol)
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(theme.primaryText)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(theme.glassBackground)
                                .cornerRadius(12)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(theme.glassBorder, lineWidth: 0.5)
                                )
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func popularASXSection(theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Label("ASX Popular", systemImage: "globe.asia.australia")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(theme.secondaryText)
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(popularASX, id: \.self) { symbol in
                        Button {
                            searchText = symbol
                        } label: {
                            HStack(spacing: 6) {
                                Text(symbol.replacingOccurrences(of: ".AX", with: ""))
                                    .font(.subheadline.weight(.medium))
                                    .foregroundColor(theme.primaryText)

                                Text("ASX")
                                    .font(.system(size: 9, weight: .heavy))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(
                                        LinearGradient(
                                            colors: [.orange, .orange.opacity(0.8)],
                                            startPoint: .leading, endPoint: .trailing
                                        )
                                    )
                                    .cornerRadius(4)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(theme.glassBackground)
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(theme.glassBorder, lineWidth: 0.5)
                            )
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: - Categories

    private func categoriesSection(theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Browse by Sector", systemImage: "square.grid.2x2")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 20)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                CategoryCard(icon: "cpu", title: "Technology", query: "AAPL", theme: theme) { searchText = $0 }
                CategoryCard(icon: "cross.case", title: "Healthcare", query: "JNJ", theme: theme) { searchText = $0 }
                CategoryCard(icon: "bolt.fill", title: "Energy", query: "XOM", theme: theme) { searchText = $0 }
                CategoryCard(icon: "banknote", title: "Finance", query: "JPM", theme: theme) { searchText = $0 }
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Searching Skeleton

    private var searchingIndicator: some View {
        VStack(spacing: 0) {
            StaggeredSkeletonList(count: 6) {
                VStack(spacing: 0) {
                    HStack(spacing: 14) {
                        SkeletonCircle(size: 44)
                        VStack(alignment: .leading, spacing: 8) {
                            SkeletonBlock(width: 60, height: 14)
                            SkeletonBlock(width: 150, height: 11)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 8) {
                            SkeletonBlock(width: 70, height: 14)
                            SkeletonBlock(width: 50, height: 11)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                }
            }
        }
        .padding(.top, 8)
    }

    // MARK: - No Results

    private func noResultsView(theme: Theme) -> some View {
        VStack(spacing: 20) {
            Spacer()

            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(theme.glassBackground)
                        .frame(width: 72, height: 72)
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                }

                VStack(spacing: 8) {
                    Text("No results for \"\(searchText)\"")
                        .font(.title3.weight(.semibold))
                        .foregroundColor(theme.primaryText)

                    Text("Try a different ticker or company name")
                        .font(.subheadline)
                        .foregroundColor(theme.secondaryText)
                }
            }

            Spacer()
        }
    }

    // MARK: - Results List

    private func resultsList(theme: Theme) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(results.count) \(results.count == 1 ? "result" : "results")")
                    .font(.caption.weight(.medium))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)

                LazyVStack(spacing: 8) {
                    ForEach(results) { asset in
                        StockSearchResultRow(asset: asset) {
                            selectedAsset = asset
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
        }
    }

    // MARK: - Build DetailedStock from Asset

    private func makeDetailedStock(from asset: Asset) -> DetailedStock {
        let changeAmount = asset.price * (asset.changePercent / 100.0)
        let previousClose = asset.price - changeAmount
        let exchange = asset.exchange.isEmpty ? (asset.kind == .stock ? "NASDAQ" : "Crypto") : asset.exchange

        return DetailedStock(
            symbol: asset.symbol,
            name: asset.name,
            exchange: exchange,
            currentPrice: asset.price,
            dayChange: changeAmount,
            dayChangePercent: asset.changePercent,
            preMarketPrice: nil,
            afterHoursPrice: nil,
            previousClose: previousClose,
            marketCap: 0,
            enterpriseValue: nil,
            volume: 0,
            avgVolume: 0,
            float: nil,
            sharesOutstanding: 0,
            peRatio: nil,
            forwardPE: nil,
            pegRatio: nil,
            priceToBook: nil,
            priceToSales: nil,
            revenue: nil,
            grossMargin: nil,
            operatingMargin: nil,
            profitMargin: nil,
            freeCashFlow: nil,
            debtToEquity: nil,
            revenueGrowthYoY: nil,
            earningsGrowthYoY: nil,
            epsGrowth: nil,
            dividendYield: nil,
            annualDividend: nil,
            payoutRatio: nil,
            beta: nil,
            week52High: asset.week52High ?? asset.price * 1.3,
            week52Low: asset.week52Low ?? asset.price * 0.7,
            shortInterest: nil
        )
    }
}

// MARK: - Search Result Row (Card Style)

private struct StockSearchResultRow: View {
    let asset: Asset
    let onTap: () -> Void
    @EnvironmentObject var marketData: MarketData
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme

    private var isInWatchlist: Bool {
        marketData.watchlist.contains { $0.symbol == asset.symbol }
    }

    private var iconGradient: [Color] {
        if asset.exchange == "ASX" {
            return [.orange, .orange.opacity(0.7)]
        }
        if asset.kind == .crypto {
            return [.purple, .purple.opacity(0.7)]
        }
        return [.blue, .blue.opacity(0.7)]
    }

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        Button {
            onTap()
        } label: {
            HStack(spacing: 14) {
                // Symbol icon
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: iconGradient,
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 44, height: 44)

                    Text(String(asset.symbol.prefix(2)))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }

                // Name + exchange
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(asset.symbol)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(theme.primaryText)

                        if asset.exchange == "ASX" {
                            Text("ASX")
                                .font(.system(size: 8, weight: .heavy))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    LinearGradient(
                                        colors: [.orange, .orange.opacity(0.8)],
                                        startPoint: .leading, endPoint: .trailing
                                    )
                                )
                                .cornerRadius(4)
                        } else if !asset.exchange.isEmpty {
                            Text(asset.exchange)
                                .font(.caption2.weight(.medium))
                                .foregroundColor(theme.secondaryText)
                        }
                    }

                    Text(asset.name)
                        .font(.subheadline)
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(1)
                }

                Spacer()

                // Price + change
                if asset.price > 0 {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(asset.price.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(theme.primaryText)

                        HStack(spacing: 3) {
                            Image(systemName: asset.changePercent >= 0 ? "arrow.up.right" : "arrow.down.right")
                                .font(.system(size: 9, weight: .bold))
                            Text("\(asset.changePercent >= 0 ? "+" : "")\(String(format: "%.2f", asset.changePercent))%")
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundColor(asset.changePercent >= 0 ? appTheme.positiveColor : appTheme.negativeColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            (asset.changePercent >= 0 ? appTheme.positiveColor : appTheme.negativeColor).opacity(0.1)
                        )
                        .cornerRadius(4)
                    }
                }

                // Watchlist indicator + add
                Button {
                    guard !isInWatchlist else { return }
                    marketData.addToWatchlist(asset)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } label: {
                    Image(systemName: isInWatchlist ? "checkmark.circle.fill" : "plus.circle")
                        .font(.system(size: 24))
                        .foregroundStyle(
                            isInWatchlist
                                ? AnyShapeStyle(LinearGradient(colors: [appTheme.positiveColor, appTheme.positiveColor.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                                : AnyShapeStyle(LinearGradient(colors: [.blue, .blue.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                        )
                }
                .buttonStyle(.plain)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isInWatchlist)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(theme.glassBackground)
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isInWatchlist ? appTheme.positiveColor.opacity(0.3) : theme.glassBorder, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Category Card

private struct CategoryCard: View {
    let icon: String
    let title: String
    let query: String
    let theme: Theme
    let onTap: (String) -> Void

    var body: some View {
        Button {
            onTap(query)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.blue)
                    .frame(width: 32, height: 32)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(8)

                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(theme.primaryText)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(theme.secondaryText.opacity(0.5))
            }
            .padding(14)
            .background(theme.glassBackground)
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(theme.glassBorder, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}
