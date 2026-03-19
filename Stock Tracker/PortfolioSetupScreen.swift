//
//  PortfolioSetupScreen.swift
//  Stock Tracker
//
//  Onboarding step that lets users pick watchlist stocks,
//  connect a stock broker via SnapTrade, or connect a crypto exchange.
//

import SwiftUI
import Combine

// MARK: - Tab

enum PortfolioSetupTab: CaseIterable {
    case watchlist, broker, crypto

    var title: String {
        switch self {
        case .watchlist: return "Watchlist"
        case .broker:    return "Broker"
        case .crypto:    return "Crypto"
        }
    }

    var icon: String {
        switch self {
        case .watchlist: return "eye.fill"
        case .broker:    return "building.columns.fill"
        case .crypto:    return "bitcoinsign.circle.fill"
        }
    }
}

// MARK: - Main Screen

struct PortfolioSetupScreen: View {
    let onComplete: () -> Void
    let onSkip: () -> Void

    @StateObject private var stockVM = QuickSetupViewModel()
    @StateObject private var snapVM: SnapTradeViewModel

    @State private var selectedTab: PortfolioSetupTab = .watchlist
    @State private var brokerConnected = false
    @State private var cryptoConnected = false

    init(onComplete: @escaping () -> Void, onSkip: @escaping () -> Void) {
        self.onComplete = onComplete
        self.onSkip = onSkip
        let networkService = SnapTradeNetworkService(
            clientId: SecretsConfig.snapTradeClientId,
            consumerKey: SecretsConfig.snapTradeConsumerKey
        )
        _snapVM = StateObject(
            wrappedValue: SnapTradeViewModel(repository: SnapTradeRepository(networkService: networkService))
        )
    }

    private var canContinue: Bool {
        !stockVM.addedStocks.isEmpty || brokerConnected || cryptoConnected
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection

            SetupTabBar(selected: $selectedTab)
                .padding(.top, 28)
                .padding(.horizontal, 24)

            // Tab content — switch keeps all tab state alive
            ZStack {
                WatchlistSetupTab(viewModel: stockVM)
                    .opacity(selectedTab == .watchlist ? 1 : 0)

                BrokerSetupTab(snapVM: snapVM, isConnected: $brokerConnected)
                    .opacity(selectedTab == .broker ? 1 : 0)

                CryptoSetupTab(snapVM: snapVM, isConnected: $cryptoConnected)
                    .opacity(selectedTab == .crypto ? 1 : 0)
            }
            .animation(.easeInOut(duration: 0.2), value: selectedTab)

            Spacer()

            bottomCTAs
        }
        // SnapTrade Safari sheet — shown when connectBroker() gets the URL
        .sheet(isPresented: $snapVM.showConnectionView, onDismiss: {
            // Credentials are saved to Keychain by SnapTradeRepository.
            // Mark whichever tab triggered the connection as connected.
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                switch selectedTab {
                case .broker: brokerConnected = true
                case .crypto: cryptoConnected = true
                case .watchlist: break
                }
            }
        }) {
            if let url = snapVM.connectionURL {
                SafariView(url: url).ignoresSafeArea()
            }
        }
        .alert("Connection Error", isPresented: $snapVM.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            if let msg = snapVM.errorMessage { Text(msg) }
        }
        .overlay { loadingOverlay }
    }

    // MARK: - Sub-views

    private var headerSection: some View {
        VStack(spacing: 10) {
            Text("Build your portfolio")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text("Pick stocks to watch, or connect your\nbrokerage or crypto exchange")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .padding(.top, 60)
        .padding(.horizontal, 24)
    }

    private var bottomCTAs: some View {
        VStack(spacing: 14) {
            OnboardingButton(title: "Continue", disabled: !canContinue) {
                stockVM.saveStocks()
                onComplete()
            }
            Button("I'll do this later") { onSkip() }
                .font(.body)
                .foregroundColor(.white.opacity(0.6))
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 80)
    }

    @ViewBuilder
    private var loadingOverlay: some View {
        if snapVM.isLoading {
            ZStack {
                Color.black.opacity(0.55).ignoresSafeArea()
                VStack(spacing: 16) {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.4)
                    if !snapVM.loadingMessage.isEmpty {
                        Text(snapVM.loadingMessage)
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
                .padding(32)
                .background(.ultraThinMaterial)
                .cornerRadius(20)
            }
        }
    }
}

// MARK: - Segmented Tab Bar

struct SetupTabBar: View {
    @Binding var selected: PortfolioSetupTab
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(PortfolioSetupTab.allCases, id: \.title) { tab in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        selected = tab
                    }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 15, weight: .semibold))
                        Text(tab.title)
                            .font(.caption.bold())
                    }
                    .foregroundColor(selected == tab ? .white : .white.opacity(0.35))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background {
                        if selected == tab {
                            RoundedRectangle(cornerRadius: 13)
                                .fill(Color.white.opacity(0.14))
                                .matchedGeometryEffect(id: "tab_bg", in: ns)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 17))
    }
}

// MARK: - Watchlist Tab

struct WatchlistSetupTab: View {
    @ObservedObject var viewModel: QuickSetupViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 24)

            // Search field
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.white.opacity(0.5))
                TextField("Search stocks or funds", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .foregroundColor(.white)
                    .focused($isFocused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                if !viewModel.searchText.isEmpty {
                    Button { viewModel.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
            }
            .padding(14)
            .background(Color.white.opacity(0.1))
            .cornerRadius(14)
            .padding(.horizontal, 24)

            Spacer().frame(height: 24)

            // Popular stocks
            if viewModel.searchText.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Popular stocks")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.leading, 24)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(viewModel.suggestedStocks, id: \.self) { symbol in
                                StockPillButton(symbol: symbol) {
                                    viewModel.addStock(symbol)
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                }
                .transition(.opacity)
            }

            // Added stocks
            if !viewModel.addedStocks.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Added (\(viewModel.addedStocks.count))")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.leading, 24)
                        .padding(.top, 16)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(viewModel.addedStocks, id: \.self) { symbol in
                                AddedStockPill(symbol: symbol) {
                                    viewModel.removeStock(symbol)
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Spacer()
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: viewModel.addedStocks)
    }
}

// MARK: - Broker Tab

struct BrokerSetupTab: View {
    @ObservedObject var snapVM: SnapTradeViewModel
    @Binding var isConnected: Bool

    private let brokers: [(name: String, slug: String, icon: String, color: Color)] = [
        ("CommSec",             "COMMSEC",      "building.columns.fill",         .blue),
        ("Alpaca",              "ALPACA",        "chart.line.uptrend.xyaxis",     Color(red: 0.2, green: 0.78, blue: 0.4)),
        ("Interactive Brokers", "IBKR",          "globe.americas.fill",           .orange),
        ("Fidelity",            "FIDELITY",      "f.circle.fill",                 Color(red: 0.1, green: 0.5, blue: 0.9)),
        ("Charles Schwab",      "SCHWAB",        "chart.bar.fill",                .blue),
        ("TD Ameritrade",       "TDAMERITRADE",  "dollarsign.circle.fill",        Color(red: 0.0, green: 0.55, blue: 0.27)),
        ("E*TRADE",             "ETRADE",        "e.circle.fill",                 Color(red: 0.55, green: 0.0, blue: 0.0)),
        ("Robinhood",           "ROBINHOOD",     "bird.fill",                     Color(red: 0.0, green: 0.72, blue: 0.45)),
        ("Webull",              "WEBULL",        "candlestick.chart.fill",        .orange),
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                if isConnected {
                    OnboardingConnectionBadge(
                        message: "Broker connected! Your holdings will sync automatically when you open the app."
                    )
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                }

                VStack(spacing: 10) {
                    ForEach(brokers, id: \.slug) { b in
                        OnboardingConnectionCard(name: b.name, icon: b.icon, color: b.color) {
                            Task { await snapVM.connectBroker(broker: b.slug) }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, isConnected ? 8 : 20)
                .padding(.bottom, 20)
            }
        }
    }
}

// MARK: - Crypto Tab

struct CryptoSetupTab: View {
    @ObservedObject var snapVM: SnapTradeViewModel
    @Binding var isConnected: Bool

    private let exchanges: [(name: String, slug: String, icon: String, color: Color)] = [
        ("Coinbase",    "COINBASE",   "bitcoinsign.circle.fill",  .blue),
        ("Kraken",      "KRAKEN",     "k.circle.fill",            Color(red: 0.38, green: 0.0, blue: 0.8)),
        ("Binance",     "BINANCE",    "chart.bar.fill",           Color(red: 0.95, green: 0.77, blue: 0.0)),
        ("Binance US",  "BINANCEUS",  "chart.bar.fill",           .orange),
        ("Gemini",      "GEMINI",     "moon.stars.fill",          Color(red: 0.0, green: 0.55, blue: 0.95)),
        ("CoinSpot",    "COINSPOT",   "bitcoinsign.circle.fill",  Color(red: 1.0, green: 0.6, blue: 0.0)),
        ("CoinJar",     "COINJAR",    "j.circle.fill",            Color(red: 0.0, green: 0.7, blue: 0.5)),
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                if isConnected {
                    OnboardingConnectionBadge(
                        message: "Exchange connected! Your crypto will sync automatically when you open the app."
                    )
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                }

                VStack(spacing: 10) {
                    ForEach(exchanges, id: \.slug) { e in
                        OnboardingConnectionCard(name: e.name, icon: e.icon, color: e.color) {
                            Task { await snapVM.connectBroker(broker: e.slug) }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, isConnected ? 8 : 20)
                .padding(.bottom, 20)
            }
        }
    }
}

// MARK: - Shared subcomponents

struct OnboardingConnectionBadge: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(.green)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.85))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.14))
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.green.opacity(0.3), lineWidth: 1))
    }
}

struct OnboardingConnectionCard: View {
    let name: String
    let icon: String
    let color: Color
    let onConnect: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(color.opacity(0.18))
                    .frame(width: 46, height: 46)
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(color)
            }

            Text(name)
                .font(.body.weight(.semibold))
                .foregroundColor(.white)

            Spacer()

            Button(action: onConnect) {
                Text("Connect")
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(Color.blue)
                    .cornerRadius(20)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(Color.white.opacity(0.07))
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

// MARK: - Quick Setup ViewModel
@MainActor
class QuickSetupViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var addedStocks: [String] = []

    @AppStorage("preferredMarket") private var preferredMarket = "US"

    var suggestedStocks: [String] {
        switch preferredMarket {
        case "AU":
            return ["BHP.AX", "CBA.AX", "CSL.AX", "NAB.AX", "WBC.AX", "ANZ.AX"]
        case "BOTH":
            return ["AAPL", "BHP.AX", "MSFT", "CBA.AX", "NVDA", "CSL.AX"]
        default:
            return ["AAPL", "GOOGL", "MSFT", "TSLA", "AMZN", "NVDA"]
        }
    }

    func addStock(_ symbol: String) {
        guard !addedStocks.contains(symbol) else { return }

        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            addedStocks.append(symbol)
        }

        // Haptic feedback
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func removeStock(_ symbol: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            addedStocks.removeAll { $0 == symbol }
        }

        // Haptic feedback
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func saveStocks() {
        // Save to UserDefaults or MarketData
        UserDefaults.standard.set(addedStocks, forKey: "onboarding_stocks")
    }
}

// MARK: - Stock Pill Button
struct StockPillButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.caption)
                Text(symbol)
                    .font(.body.bold())
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.blue.opacity(0.3))
            .cornerRadius(20)
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.blue.opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Added Stock Pill
struct AddedStockPill: View {
    let symbol: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(symbol)
                .font(.body.bold())

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.green.opacity(0.3))
        .cornerRadius(20)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.green.opacity(0.5), lineWidth: 1)
        )
    }
}
