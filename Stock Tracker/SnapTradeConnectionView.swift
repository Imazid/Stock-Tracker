//
//  SnapTradeConnectionView.swift
//  Stock Tracker
//

import SwiftUI
import SafariServices

enum SnapTradeAutoMode {
    case broker, crypto
}

// MARK: - Main Connection View

struct SnapTradeConnectionView: View {

    @EnvironmentObject var marketData: MarketData
    @StateObject private var viewModel: SnapTradeViewModel
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme

    private let autoMode: SnapTradeAutoMode?
    @State private var showConnectionTypePicker = false
    @State private var showBrokerPicker = false
    @State private var showCryptoExchangePicker = false
    @State private var showManualEntry = false

    private let stockBrokers: [(String, String)] = [
        ("CommSec", "COMMSEC"),
        ("Alpaca", "ALPACA"),
        ("TD Ameritrade", "TDAMERITRADE"),
        ("E*TRADE", "ETRADE"),
        ("Fidelity", "FIDELITY"),
        ("Schwab", "SCHWAB"),
        ("Interactive Brokers", "IBKR"),
        ("Robinhood", "ROBINHOOD"),
        ("Webull", "WEBULL")
    ]

    private let cryptoExchanges: [(String, String)] = [
        ("Coinbase", "COINBASE"),
        ("Kraken", "KRAKEN"),
        ("Binance", "BINANCE"),
        ("Binance US", "BINANCEUS"),
        ("Gemini", "GEMINI"),
        ("CoinSpot", "COINSPOT"),
        ("CoinJar", "COINJAR")
    ]

    init(autoMode: SnapTradeAutoMode? = nil) {
        self.autoMode = autoMode
        let clientId = SecretsConfig.snapTradeClientId
        let consumerKey = SecretsConfig.snapTradeConsumerKey
        let networkService = SnapTradeNetworkService(clientId: clientId, consumerKey: consumerKey)
        let repository = SnapTradeRepository(networkService: networkService)
        _viewModel = StateObject(wrappedValue: SnapTradeViewModel(repository: repository))
    }

    private var theme: Theme { Theme(colorScheme: colorScheme) }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.background.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {
                        headerSection
                            .padding(.top, 8)

                        if viewModel.isAuthenticated {
                            connectedSection
                        } else {
                            disconnectedSection
                        }

                        if viewModel.isAuthenticated {
                            accountsSection
                            holdingsSection
                            syncSection
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 48)
                }

                if viewModel.isLoading {
                    loadingOverlay
                }
            }
            .onAppear {
                if let mode = autoMode {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        switch mode {
                        case .broker: showBrokerPicker = true
                        case .crypto: showCryptoExchangePicker = true
                        }
                    }
                }
            }
            .navigationTitle("Connect Broker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(theme.primaryText)
                }
            }
            .sheet(isPresented: $viewModel.showConnectionView) {
                if let url = viewModel.connectionURL {
                    SafariView(url: url)
                        .ignoresSafeArea()
                        .onDisappear {
                            Task { await viewModel.syncAll() }
                        }
                }
            }
            .alert("Error", isPresented: $viewModel.showError) {
                Button("OK", role: .cancel) {}
            } message: {
                if let msg = viewModel.errorMessage { Text(msg) }
            }
            .sheet(isPresented: $showConnectionTypePicker) {
                ConnectionTypeSheet(
                    onStockBroker: {
                        showConnectionTypePicker = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showBrokerPicker = true }
                    },
                    onCryptoExchange: {
                        showConnectionTypePicker = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showCryptoExchangePicker = true }
                    },
                    onManual: {
                        showConnectionTypePicker = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showManualEntry = true }
                    }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showBrokerPicker) {
                BrokerPickerSheet(brokers: stockBrokers) { slug in
                    Task { await viewModel.connectBroker(broker: slug) }
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showCryptoExchangePicker) {
                CryptoPickerSheet(exchanges: cryptoExchanges) { slug in
                    Task { await viewModel.connectBroker(broker: slug) }
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showManualEntry) {
                ManualPositionSheet()
                    .environmentObject(marketData)
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                colors: [appTheme.accentColor.opacity(0.09), theme.background.opacity(0)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 200)
            .allowsHitTesting(false)

            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [appTheme.accentColor.opacity(0.28), Color.purple.opacity(0.18)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .frame(width: 110, height: 110)
                        .blur(radius: 22)

                    ZStack {
                        Circle()
                            .fill(LinearGradient(
                                colors: [appTheme.accentColor, Color(red: 0.4, green: 0.22, blue: 0.9)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ))
                            .frame(width: 76, height: 76)
                        Image(systemName: "link.circle.fill")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .shadow(color: appTheme.accentColor.opacity(colorScheme == .dark ? 0.5 : 0.04), radius: 18, y: 8)
                }

                VStack(spacing: 6) {
                    Text("Brokerage Connect")
                        .font(.title2.weight(.bold))
                        .foregroundColor(.primary)
                    Text("Sync your holdings automatically")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.bottom, 8)
        }
    }

    // MARK: - Disconnected

    private var disconnectedSection: some View {
        VStack(spacing: 16) {
            VStack(spacing: 0) {
                featureBullet(icon: "arrow.triangle.2.circlepath", title: "Auto-Sync Holdings",
                              subtitle: "Your positions update in real time", color: appTheme.accentColor)
                Divider().opacity(0.4).padding(.leading, 54)
                featureBullet(icon: "chart.line.uptrend.xyaxis", title: "Real-Time P&L",
                              subtitle: "Live gain/loss across all accounts", color: .purple)
                Divider().opacity(0.4).padding(.leading, 54)
                featureBullet(icon: "lock.shield.fill", title: "Bank-Level Security",
                              subtitle: "Read-only access via SnapTrade", color: appTheme.positiveColor)
            }
            .padding(18)
            .background(theme.glassBackground)
            .cornerRadius(16)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.glassBorder, lineWidth: 1))

            Button {
                showConnectionTypePicker = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill").font(.body.weight(.semibold))
                    Text("Connect Account").font(.headline)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(LinearGradient(
                    colors: [appTheme.accentColor, appTheme.accentColor.opacity(0.75)],
                    startPoint: .leading, endPoint: .trailing
                ))
                .cornerRadius(16)
                .shadow(color: appTheme.accentColor.opacity(colorScheme == .dark ? 0.4 : 0.04), radius: 12, y: 6)
            }
        }
    }

    private func featureBullet(icon: String, title: String, subtitle: String, color: Color) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(color.opacity(0.13)).frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 12)
    }

    // MARK: - Connected

    private var connectedSection: some View {
        let glColor = appTheme.positiveColor
        return VStack(spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [glColor.opacity(0.22), glColor.opacity(0.06)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .frame(width: 52, height: 52)
                    Image(systemName: "checkmark")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(glColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Connected")
                        .font(.headline.weight(.semibold))
                    if viewModel.accounts.isEmpty {
                        Text("No broker accounts linked yet")
                            .font(.caption).foregroundColor(.secondary)
                    } else {
                        Text("\(viewModel.accounts.count) account\(viewModel.accounts.count == 1 ? "" : "s") linked")
                            .font(.caption).foregroundColor(glColor)
                    }
                }

                Spacer()

                if !viewModel.accounts.isEmpty {
                    Text("\(viewModel.accounts.count)")
                        .font(.caption.weight(.bold))
                        .foregroundColor(glColor)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(glColor.opacity(0.12))
                        .clipShape(Capsule())
                }
            }

            Divider().opacity(0.4)

            Button {
                showConnectionTypePicker = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill").font(.system(size: 14, weight: .semibold))
                    Text("Connect Another").font(.subheadline.weight(.semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(LinearGradient(
                    colors: [appTheme.accentColor, appTheme.accentColor.opacity(0.75)],
                    startPoint: .leading, endPoint: .trailing
                ))
                .cornerRadius(12)
                .shadow(color: appTheme.accentColor.opacity(colorScheme == .dark ? 0.3 : 0.04), radius: 8, y: 4)
            }

            Button {
                viewModel.disconnect()
            } label: {
                Text("Disconnect All")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.secondary)
            }
        }
        .padding(18)
        .background(theme.glassBackground)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(glColor.opacity(0.3), lineWidth: 1.5))
    }

    // MARK: - Accounts Section

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color.blue.opacity(0.15)).frame(width: 32, height: 32)
                    Image(systemName: "building.columns.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.blue)
                }
                Text("Connected Accounts")
                    .font(.title3.bold())
                Spacer()
                if !viewModel.accounts.isEmpty {
                    Button {
                        Task { await viewModel.fetchAccounts() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(appTheme.accentColor)
                            .padding(8)
                            .background(appTheme.accentColor.opacity(0.1))
                            .clipShape(Circle())
                    }
                }
            }

            if viewModel.accounts.isEmpty {
                HStack {
                    Text("No accounts found. Connect a broker above.")
                        .font(.subheadline).foregroundColor(.secondary)
                    Spacer()
                }
                .padding(16)
                .background(theme.glassBackground)
                .cornerRadius(14)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.glassBorder, lineWidth: 1))
            } else {
                VStack(spacing: 10) {
                    ForEach(viewModel.accounts) { account in
                        AccountCard(account: account)
                    }
                }
            }
        }
    }

    // MARK: - Holdings Section

    private var holdingsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color.purple.opacity(0.15)).frame(width: 32, height: 32)
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.purple)
                }
                Text("Holdings")
                    .font(.title3.bold())
                Spacer()
                if !viewModel.holdings.isEmpty {
                    HStack(spacing: 6) {
                        Text("\(viewModel.holdings.count)")
                            .font(.caption.weight(.bold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(theme.glassBackground)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(theme.glassBorder, lineWidth: 1))

                        Button {
                            Task { await viewModel.fetchAllHoldings() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(appTheme.accentColor)
                                .padding(8)
                                .background(appTheme.accentColor.opacity(0.1))
                                .clipShape(Circle())
                        }
                    }
                }
            }

            if viewModel.holdings.isEmpty {
                if !viewModel.accounts.isEmpty {
                    Button {
                        Task { await viewModel.fetchAllHoldings() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(appTheme.accentColor)
                            Text("Load Holdings")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(appTheme.accentColor)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary.opacity(0.5))
                        }
                        .padding(16)
                        .background(appTheme.accentColor.opacity(0.08))
                        .cornerRadius(14)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(appTheme.accentColor.opacity(0.2), lineWidth: 1))
                    }
                } else {
                    HStack {
                        Text("Connect an account to see holdings")
                            .font(.subheadline).foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(16)
                    .background(theme.glassBackground)
                    .cornerRadius(14)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.glassBorder, lineWidth: 1))
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(viewModel.holdings) { holding in
                        HoldingCard(holding: holding)
                    }
                }
            }
        }
    }

    // MARK: - Sync Section

    private var syncSection: some View {
        VStack(spacing: 10) {
            if !viewModel.holdings.isEmpty {
                Button {
                    Task {
                        await viewModel.syncToPortfolio(marketData: marketData)
                        dismiss()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.body.weight(.semibold))
                        Text("Sync to Portfolio").font(.headline)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(LinearGradient(
                        colors: [Color(red: 0.06, green: 0.68, blue: 0.40), Color(red: 0.0, green: 0.52, blue: 0.36)],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .cornerRadius(16)
                    .shadow(color: Color.green.opacity(colorScheme == .dark ? 0.35 : 0.04), radius: 12, y: 6)
                }

                Text("This will replace your current portfolio with broker data")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Loading Overlay

    private var loadingOverlay: some View {
        ZStack {
            theme.background.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 20) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(theme.progressTint)
                Text(viewModel.loadingMessage)
                    .foregroundColor(theme.primaryText)
                    .font(.subheadline)
            }
            .padding(40)
            .background(theme.glassBackground)
            .cornerRadius(20)
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(theme.glassBorder, lineWidth: 1))
        }
    }
}

// MARK: - Account Card

struct AccountCard: View {
    let account: BrokerAccount
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color.blue, Color.blue.opacity(0.7)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 46, height: 46)
                Image(systemName: "building.columns.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(account.institutionName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                Text(account.maskedAccountNumber)
                    .font(.caption).foregroundColor(.secondary)
                if let type = account.accountType {
                    Text(type)
                        .font(.caption2.weight(.medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(Capsule())
                }
            }

            Spacer()

            if let balance = account.balance?.total {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("Balance")
                        .font(.caption2).foregroundColor(.secondary)
                    Text(balance.formattedAmount)
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                        .foregroundColor(appTheme.positiveColor)
                }
            }
        }
        .padding(14)
        .background(theme.glassBackground)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.glassBorder, lineWidth: 1))
    }
}

// MARK: - Holding Card

struct HoldingCard: View {
    let holding: BrokerHolding
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        let glColor: Color = holding.isPositive ? appTheme.positiveColor : appTheme.negativeColor

        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(glColor.opacity(0.12))
                    .frame(width: 42, height: 42)
                Text(String(holding.symbol.prefix(2)))
                    .font(.caption.weight(.bold))
                    .foregroundColor(glColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(holding.symbol)
                    .font(.subheadline.weight(.semibold))
                Text(holding.displayName)
                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
                Text(String(format: "%.4g shares", holding.quantity))
                    .font(.caption2).foregroundColor(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if let price = holding.currentPrice {
                    Text(price, format: .currency(code: holding.currency))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
                Text(holding.marketValue, format: .currency(code: holding.currency))
                    .font(.caption).foregroundColor(.secondary).monospacedDigit()

                HStack(spacing: 3) {
                    Image(systemName: holding.isPositive ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 9, weight: .bold))
                    Text(String(format: "%@%.2f%%", holding.isPositive ? "+" : "", holding.unrealizedPnLPercent))
                        .font(.caption.weight(.bold)).monospacedDigit()
                }
                .foregroundColor(glColor)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(glColor.opacity(0.12))
                .clipShape(Capsule())
            }
        }
        .padding(14)
        .background(theme.glassBackground)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.glassBorder, lineWidth: 1))
    }
}

// MARK: - Safari View

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        config.barCollapsingEnabled = true
        let safari = SFSafariViewController(url: url, configuration: config)
        safari.preferredControlTintColor = .systemBlue
        safari.preferredBarTintColor = .systemBackground
        safari.dismissButtonStyle = .close
        return safari
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

// MARK: - Connection Type Sheet

struct ConnectionTypeSheet: View {
    let onStockBroker: () -> Void
    let onCryptoExchange: () -> Void
    let onManual: () -> Void
    var onCSVImport: (() -> Void)? = nil

    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [appTheme.accentColor.opacity(0.22), Color.purple.opacity(0.12)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .frame(width: 80, height: 80)
                        .blur(radius: 18)

                    ZStack {
                        Circle()
                            .fill(LinearGradient(
                                colors: [appTheme.accentColor, Color.purple.opacity(0.8)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ))
                            .frame(width: 60, height: 60)
                        Image(systemName: "plus")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .shadow(color: appTheme.accentColor.opacity(colorScheme == .dark ? 0.45 : 0.04), radius: 14, y: 6)
                }
                .padding(.top, 28)

                VStack(spacing: 5) {
                    Text("Add Position")
                        .font(.title2.weight(.bold))
                    Text("Choose how to add to your portfolio")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.bottom, 28)

            // Options
            VStack(spacing: 12) {
                connectionOption(
                    gradient: [Color(red: 0.18, green: 0.44, blue: 1.0), Color(red: 0.38, green: 0.62, blue: 1.0)],
                    icon: "magnifyingglass",
                    title: "Search & Add Manually",
                    subtitle: "Search any stock, ETF or crypto",
                    badge: nil,
                    theme: theme,
                    action: onManual
                )
                connectionOption(
                    gradient: [Color(red: 0.13, green: 0.55, blue: 0.95), Color(red: 0.0, green: 0.36, blue: 0.8)],
                    icon: "building.columns.fill",
                    title: "Connect Stock Broker",
                    subtitle: "CommSec, Fidelity, IBKR & more",
                    badge: "Auto-sync",
                    theme: theme,
                    action: onStockBroker
                )
                connectionOption(
                    gradient: [Color(red: 1.0, green: 0.52, blue: 0.0), Color(red: 0.9, green: 0.32, blue: 0.0)],
                    icon: "bitcoinsign.circle.fill",
                    title: "Connect Crypto Exchange",
                    subtitle: "Coinbase, Kraken, CoinSpot & more",
                    badge: "Auto-sync",
                    theme: theme,
                    action: onCryptoExchange
                )
                if let onCSVImport {
                    connectionOption(
                        gradient: [Color(red: 0.42, green: 0.35, blue: 0.65), Color(red: 0.32, green: 0.25, blue: 0.55)],
                        icon: "doc.text.fill",
                        title: "Import from CSV",
                        subtitle: "Bulk import from a spreadsheet",
                        badge: "Black",
                        theme: theme,
                        action: onCSVImport
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 36)
        }
        .frame(maxWidth: .infinity)
        .background(theme.background)
    }

    private func connectionOption(
        gradient: [Color],
        icon: String,
        title: String,
        subtitle: String,
        badge: String?,
        theme: Theme,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 52, height: 52)
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.white)
                }
                .shadow(color: (gradient.first ?? .blue).opacity(colorScheme == .dark ? 0.35 : 0.04), radius: 8, y: 4)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(gradient.first ?? .blue)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background((gradient.first ?? .blue).opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.5))
                    .padding(7)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(Circle())
            }
            .padding(14)
            .background(theme.glassBackground)
            .cornerRadius(16)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.glassBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Broker Picker Sheet

struct BrokerPickerSheet: View {
    let brokers: [(String, String)]
    let onSelect: (String) -> Void

    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme

    private let brokerMeta: [String: (icon: String, color: Color)] = [
        "COMMSEC":     ("building.columns.fill",      Color(red: 0.0,  green: 0.38, blue: 0.75)),
        "ALPACA":      ("hare.fill",                   Color(red: 0.88, green: 0.24, blue: 0.24)),
        "TDAMERITRADE":("chart.bar.fill",              Color(red: 0.0,  green: 0.48, blue: 0.86)),
        "ETRADE":      ("e.circle.fill",               Color(red: 0.35, green: 0.70, blue: 0.22)),
        "FIDELITY":    ("building.2.fill",             Color(red: 0.10, green: 0.20, blue: 0.68)),
        "SCHWAB":      ("s.circle.fill",               Color(red: 0.0,  green: 0.48, blue: 0.76)),
        "IBKR":        ("globe.americas.fill",         Color(red: 0.82, green: 0.10, blue: 0.10)),
        "ROBINHOOD":   ("leaf.fill",                   Color(red: 0.0,  green: 0.72, blue: 0.38)),
        "WEBULL":      ("w.circle.fill",               Color(red: 0.0,  green: 0.48, blue: 0.82)),
    ]

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        NavigationStack {
            ZStack {
                theme.background.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        // Section header info
                        HStack(spacing: 10) {
                            ZStack {
                                Circle().fill(Color.blue.opacity(0.15)).frame(width: 32, height: 32)
                                Image(systemName: "building.columns.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.blue)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Supported Brokers")
                                    .font(.subheadline.weight(.semibold))
                                Text("Select your brokerage to connect")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.bottom, 6)

                        ForEach(brokers, id: \.1) { name, slug in
                            let meta = brokerMeta[slug] ?? ("building.columns.fill", Color.blue)
                            Button {
                                onSelect(slug)
                                dismiss()
                            } label: {
                                HStack(spacing: 14) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(LinearGradient(
                                                colors: [meta.color, meta.color.opacity(0.7)],
                                                startPoint: .topLeading, endPoint: .bottomTrailing
                                            ))
                                            .frame(width: 48, height: 48)
                                        Image(systemName: meta.icon)
                                            .font(.system(size: 20, weight: .semibold))
                                            .foregroundColor(.white)
                                    }
                                    .shadow(color: meta.color.opacity(colorScheme == .dark ? 0.3 : 0.04), radius: 6, y: 3)

                                    Text(name)
                                        .font(.body.weight(.semibold))
                                        .foregroundColor(.primary)

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundColor(.secondary.opacity(0.5))
                                        .padding(7)
                                        .background(Color.secondary.opacity(0.08))
                                        .clipShape(Circle())
                                }
                                .padding(14)
                                .background(theme.glassBackground)
                                .cornerRadius(16)
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.glassBorder, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 20)
                }
            }
            .navigationTitle("Select Broker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Crypto Picker Sheet

struct CryptoPickerSheet: View {
    let exchanges: [(String, String)]
    let onSelect: (String) -> Void

    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme

    private let exchangeMeta: [String: (icon: String, color: Color)] = [
        "COINBASE":  ("bitcoinsign.circle.fill",  Color(red: 0.06, green: 0.40, blue: 1.00)),
        "KRAKEN":    ("waveform",                  Color(red: 0.42, green: 0.22, blue: 0.82)),
        "BINANCE":   ("b.circle.fill",             Color(red: 0.93, green: 0.72, blue: 0.00)),
        "BINANCEUS": ("b.circle",                  Color(red: 0.85, green: 0.60, blue: 0.00)),
        "GEMINI":    ("star.circle.fill",          Color(red: 0.20, green: 0.60, blue: 0.90)),
        "COINSPOT":  ("circle.hexagongrid.fill",   Color(red: 0.98, green: 0.42, blue: 0.06)),
        "COINJAR":   ("cylinder.fill",             Color(red: 0.16, green: 0.76, blue: 0.58)),
    ]

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        NavigationStack {
            ZStack {
                theme.background.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        // Section header info
                        HStack(spacing: 10) {
                            ZStack {
                                Circle().fill(Color.orange.opacity(0.15)).frame(width: 32, height: 32)
                                Image(systemName: "bitcoinsign.circle.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.orange)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Supported Exchanges")
                                    .font(.subheadline.weight(.semibold))
                                Text("Select your crypto exchange to connect")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.bottom, 6)

                        ForEach(exchanges, id: \.1) { name, slug in
                            let meta = exchangeMeta[slug] ?? ("bitcoinsign.circle.fill", Color.orange)
                            Button {
                                onSelect(slug)
                                dismiss()
                            } label: {
                                HStack(spacing: 14) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(LinearGradient(
                                                colors: [meta.color, meta.color.opacity(0.7)],
                                                startPoint: .topLeading, endPoint: .bottomTrailing
                                            ))
                                            .frame(width: 48, height: 48)
                                        Image(systemName: meta.icon)
                                            .font(.system(size: 20, weight: .semibold))
                                            .foregroundColor(.white)
                                    }
                                    .shadow(color: meta.color.opacity(colorScheme == .dark ? 0.3 : 0.04), radius: 6, y: 3)

                                    Text(name)
                                        .font(.body.weight(.semibold))
                                        .foregroundColor(.primary)

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundColor(.secondary.opacity(0.5))
                                        .padding(7)
                                        .background(Color.secondary.opacity(0.08))
                                        .clipShape(Circle())
                                }
                                .padding(14)
                                .background(theme.glassBackground)
                                .cornerRadius(16)
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.glassBorder, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 20)
                }
            }
            .navigationTitle("Select Exchange")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Manual Position Sheet

struct ManualPositionSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var marketData: MarketData
    @Environment(\.colorScheme) var colorScheme

    @State private var symbol: String
    @State private var name: String
    @State private var quantity = ""
    @State private var avgCost = ""
    @State private var isCrypto: Bool
    @FocusState private var focusedField: ManualField?

    enum ManualField { case symbol, name, quantity, avgCost }

    init(asset: Asset? = nil) {
        _symbol   = State(initialValue: asset?.symbol ?? "")
        _name     = State(initialValue: asset?.name ?? "")
        _isCrypto = State(initialValue: asset?.kind == .crypto)
    }

    private var parsedQuantity: Double? {
        Double(quantity.replacingOccurrences(of: ",", with: "."))
    }
    private var parsedCost: Double? {
        Double(avgCost.replacingOccurrences(of: ",", with: "."))
    }
    private var totalCostBasis: Double? {
        guard let q = parsedQuantity, let c = parsedCost else { return nil }
        return q * c
    }
    private var canAdd: Bool {
        !symbol.trimmingCharacters(in: .whitespaces).isEmpty &&
        (parsedQuantity ?? 0) > 0
    }

    private var accentColor: Color {
        isCrypto ? Color.orange : Color.blue
    }

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        NavigationStack {
            ZStack {
                theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        manualHeader(theme: theme)
                        assetTypePicker(theme: theme)
                        assetFields(theme: theme)
                        positionFields(theme: theme)
                        if totalCostBasis != nil {
                            manualSummary(theme: theme)
                        }
                        manualAddButton
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 48)
                }
            }
            .navigationTitle("Manual Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.secondary)
                }
            }
            .onAppear {
                if symbol.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        focusedField = .symbol
                    }
                }
            }
        }
    }

    // MARK: - Header

    private func manualHeader(theme: Theme) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [accentColor, accentColor.opacity(0.5)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 48, height: 48)
                Image(systemName: isCrypto ? "bitcoinsign.circle.fill" : "chart.line.uptrend.xyaxis.circle.fill")
                    .font(.title2)
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(symbol.isEmpty ? "New Position" : symbol.uppercased())
                    .font(.title3.bold())
                    .foregroundColor(.primary)
                Text(isCrypto ? "Cryptocurrency" : "Stock / ETF")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if !symbol.isEmpty {
                Text(symbol.prefix(2).uppercased())
                    .font(.caption.bold())
                    .foregroundColor(accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(accentColor.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
        .padding(16)
        .background(accentColor.opacity(0.08))
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(accentColor.opacity(0.15), lineWidth: 1))
        .animation(.easeInOut(duration: 0.2), value: isCrypto)
        .animation(.easeInOut(duration: 0.15), value: symbol)
    }

    // MARK: - Asset Type Picker

    private func assetTypePicker(theme: Theme) -> some View {
        HStack(spacing: 0) {
            manualTypeButton(label: "Stock / ETF", icon: "chart.line.uptrend.xyaxis", isCryptoType: false, theme: theme)
            manualTypeButton(label: "Crypto", icon: "bitcoinsign.circle", isCryptoType: true, theme: theme)
        }
        .padding(4)
        .background(theme.glassBackground)
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.separator, lineWidth: 1))
    }

    private func manualTypeButton(label: String, icon: String, isCryptoType: Bool, theme: Theme) -> some View {
        let isSelected = isCrypto == isCryptoType
        let color: Color = isCryptoType ? .orange : .blue
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                isCrypto = isCryptoType
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                Text(label)
                    .font(.subheadline.weight(.bold))
            }
            .foregroundColor(isSelected ? .white : color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(isSelected ? color : Color.clear)
            .cornerRadius(10)
        }
    }

    // MARK: - Asset Fields

    private func assetFields(theme: Theme) -> some View {
        VStack(spacing: 14) {
            Label("Asset Details", systemImage: "tag")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            manualInputRow(
                label: isCrypto ? "Symbol (e.g. BTC)" : "Symbol (e.g. AAPL)",
                icon: "textformat",
                placeholder: isCrypto ? "BTC" : "AAPL",
                text: $symbol,
                field: .symbol,
                theme: theme,
                capitalize: true
            )

            manualInputRow(
                label: "Name (optional)",
                icon: "character.cursor.ibeam",
                placeholder: isCrypto ? "Bitcoin" : "Apple Inc.",
                text: $name,
                field: .name,
                theme: theme
            )
        }
    }

    // MARK: - Position Fields

    private func positionFields(theme: Theme) -> some View {
        VStack(spacing: 14) {
            Label("Position Details", systemImage: "list.bullet.clipboard")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            manualInputRow(
                label: isCrypto ? "Quantity (e.g. 0.5)" : "Number of Shares",
                icon: "number",
                placeholder: "0.00",
                text: $quantity,
                field: .quantity,
                theme: theme,
                isNumeric: true
            )

            manualInputRow(
                label: "Average Cost per Unit",
                icon: "dollarsign",
                placeholder: "0.00",
                text: $avgCost,
                field: .avgCost,
                theme: theme,
                isNumeric: true
            )
        }
    }

    // MARK: - Input Row

    private func manualInputRow(
        label: String,
        icon: String,
        placeholder: String,
        text: Binding<String>,
        field: ManualField,
        theme: Theme,
        capitalize: Bool = false,
        isNumeric: Bool = false
    ) -> some View {
        let isFocused = focusedField == field
        return VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .padding(.leading, 2)

            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundColor(isFocused ? accentColor : .secondary)
                    .frame(width: 20)
                    .animation(.easeInOut(duration: 0.15), value: isFocused)

                TextField(placeholder, text: text)
                    .keyboardType(isNumeric ? .decimalPad : .default)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(capitalize ? .characters : .never)
                    .focused($focusedField, equals: field)
                    .font(.title3.weight(.medium))
            }
            .padding(16)
            .background(isFocused ? accentColor.opacity(0.06) : theme.glassBackground)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isFocused ? accentColor.opacity(0.5) : theme.separator, lineWidth: 1.5)
            )
            .animation(.easeInOut(duration: 0.15), value: isFocused)
        }
    }

    // MARK: - Summary

    private func manualSummary(theme: Theme) -> some View {
        VStack(spacing: 14) {
            Label("Position Summary", systemImage: "chart.bar.doc.horizontal")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 10) {
                manualSummaryRow(
                    isCrypto ? "Quantity" : "Shares",
                    value: parsedQuantity.map { String(format: "%.4g", $0) } ?? "-"
                )
                manualSummaryRow(
                    "Avg Cost",
                    value: parsedCost.map { String(format: "$%.2f", $0) } ?? "-"
                )
                Divider().opacity(0.6)
                manualSummaryRow(
                    "Total Cost Basis",
                    value: totalCostBasis.map { String(format: "$%.2f", $0) } ?? "-",
                    bold: true
                )
            }
            .padding(16)
            .background(theme.glassBackground)
            .cornerRadius(14)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.separator, lineWidth: 0.5))
        }
    }

    private func manualSummaryRow(_ label: String, value: String, bold: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(bold ? .subheadline.weight(.semibold) : .subheadline)
                .foregroundColor(bold ? .primary : .secondary)
            Spacer()
            Text(value)
                .font(bold ? .subheadline.weight(.bold) : .subheadline.weight(.medium))
                .foregroundColor(bold ? .primary : .secondary)
                .monospacedDigit()
        }
    }

    // MARK: - Add Button

    private var manualAddButton: some View {
        Button {
            guard canAdd else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            addPosition()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill").font(.title3)
                Text("Add to Portfolio").font(.headline)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                canAdd
                    ? LinearGradient(colors: [accentColor, accentColor.opacity(0.7)],
                                     startPoint: .leading, endPoint: .trailing)
                    : LinearGradient(colors: [Color.gray.opacity(0.35), Color.gray.opacity(0.25)],
                                     startPoint: .leading, endPoint: .trailing)
            )
            .cornerRadius(16)
            .shadow(color: canAdd ? accentColor.opacity(colorScheme == .dark ? 0.35 : 0.10) : .clear, radius: 12, y: 6)
        }
        .disabled(!canAdd)
        .animation(.easeInOut(duration: 0.2), value: canAdd)
    }

    // MARK: - Add Position

    private func addPosition() {
        let sym = symbol.uppercased().trimmingCharacters(in: .whitespaces)
        let qty = parsedQuantity ?? 0
        let cost = parsedCost ?? 0
        let assetName = name.trimmingCharacters(in: .whitespaces).isEmpty ? sym : name

        let asset = Asset(
            symbol: sym,
            name: assetName,
            price: cost,
            change: 0,
            changePercent: 0,
            volume: 0,
            kind: isCrypto ? .crypto : .stock,
            exchange: isCrypto ? "Crypto" : "Manual"
        )

        marketData.addToPortfolio(asset: asset, shares: qty, avgCost: cost)
        dismiss()
    }
}

// MARK: - Preview

#Preview {
    SnapTradeConnectionView()
        .environmentObject(MarketData())
}
