//
//  ContentView.swift
//  Stock Tracker
//

import SwiftUI
import UIKit

/// Primary destinations. Search is hosted in Markets.
enum MainTab: String, CaseIterable, Hashable {
    case home = "Home"
    case markets = "Markets"
    case portfolio = "Portfolio"
    case privateMarkets = "Private Markets"
    case agents = "Agents"
    case activity = "Activity"
    case search = "Search"

    var icon: String {
        switch self {
        case .home:         return "house"
        case .markets:      return "chart.line.uptrend.xyaxis"
        case .portfolio:    return "briefcase"
        case .privateMarkets: return "building.2"
        case .agents:       return "gearshape.2"
        case .activity:     return "list.bullet.rectangle"
        case .search:       return "magnifyingglass"
        }
    }

    var localizedTitle: LocalizedStringKey {
        switch self {
        case .home: return "Home"
        case .markets: return "Markets"
        case .portfolio: return "Portfolio"
        case .privateMarkets: return "Private Markets"
        case .agents: return "Agents"
        case .activity: return "Activity"
        case .search: return "Search"
        }
    }
}

// MARK: - Tab switching from inside a tab

private struct SelectTabKey: EnvironmentKey {
    static let defaultValue: (MainTab) -> Void = { _ in }
}

extension EnvironmentValues {
    /// Switches the root tab (e.g. Home's "See all" → Watchlist).
    var selectTab: (MainTab) -> Void {
        get { self[SelectTabKey.self] }
        set { self[SelectTabKey.self] = newValue }
    }
}

struct ContentView: View {
    @EnvironmentObject var marketData: MarketData
    @EnvironmentObject var alertManager: PriceAlertManager
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @EnvironmentObject var trading: TradingStore
    @EnvironmentObject var router: TradingRouter
    @EnvironmentObject private var cloudAuth: SupabaseAuthManager
    @StateObject private var privateMarkets = PrivateMarketsStore.shared
    @Environment(\.colorScheme) var colorScheme
    @AppStorage("portfolioSegment") private var portfolioSegment = PortfolioSegment.holdings.rawValue
    @State private var pendingCommand: WorkspaceDestination?

    /// Binding allows the parent (StockCryptoTrackerApp) to drive tab selection from widget deep links.
    @Binding var selectedTab: MainTab

    init(selectedTab: Binding<MainTab> = .constant(.home)) {
        _selectedTab = selectedTab
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: MainTab.home.icon, value: MainTab.home) {
                HomeView()
            }

            Tab("Markets", systemImage: MainTab.markets.icon, value: MainTab.markets) {
                MarketsTabView()
            }

            Tab("Portfolio", systemImage: MainTab.portfolio.icon, value: MainTab.portfolio) {
                PortfolioView()
            }

            Tab("Private Markets", systemImage: MainTab.privateMarkets.icon, value: MainTab.privateMarkets) {
                PrivateMarketsView()
            }

            Tab("Agents", systemImage: MainTab.agents.icon, value: MainTab.agents) {
                AgentsTabView()
            }
            // Proposals waiting for a yes or no.
            .badge(trading.pendingProposals.count)

            Tab("Activity", systemImage: MainTab.activity.icon, value: MainTab.activity) {
                ActivityTabView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .onChange(of: selectedTab) { _, tab in
            if tab == .search {
                router.marketsSection = .search
                selectedTab = .markets
            }
        }
        .tint(DS.accent)
        .onChange(of: cloudAuth.userId, initial: true) { _, id in privateMarkets.selectAccount(id) }
        .modifier(TradingRootSheets())
        .environmentObject(privateMarkets)
        .sheet(isPresented: $router.showCommands, onDismiss: performCommand) {
            CommandPalette { destination in
                pendingCommand = destination
                router.showCommands = false
            }
            .presentationDetents([.large])
            .presentationBackground(.regularMaterial)
        }
        .onChange(of: router.requestedTab, initial: true) { _, tab in
            if let tab {
                selectedTab = tab
                router.requestedTab = nil
            }
        }
        .environment(\.selectTab, { [selectedTab = $selectedTab] tab in selectedTab.wrappedValue = tab })
        .sensoryFeedback(.impact(flexibility: .soft), trigger: selectedTab)
        .onChange(of: selectedTab) { _, _ in marketData.refreshIfStale() }
        .onChange(of: colorScheme, initial: true) { _, _ in configureTabBar() }
    }

    private func performCommand() {
        guard let destination = pendingCommand else { return }
        pendingCommand = nil
        switch destination {
        case .command(let command):
            switch command {
            case .home: selectedTab = .home
            case .markets:
                router.marketsSection = .watchlist
                selectedTab = .markets
            case .news:
                router.marketsSection = .news
                selectedTab = .markets
            case .privateMarkets: selectedTab = .privateMarkets
            case .portfolio: selectedTab = .portfolio
            case .performance:
                portfolioSegment = PortfolioSegment.performance.rawValue
                selectedTab = .portfolio
            case .agents: selectedTab = .agents
            case .activity: selectedTab = .activity
            case .search: selectedTab = .search
            case .copilot: router.askCopilot()
            case .newAgent: router.createAgent()
            }
        case .asset(let asset):
            router.assetDetail = asset
        case .watchlist(let id):
            guard let index = marketData.watchlistGroups.firstIndex(where: { $0.id == id }) else { return }
            marketData.switchToWatchlist(index: index)
            router.marketsSection = .watchlist
            selectedTab = .markets
        case .agent(let id):
            router.agent = TradingRouter.Ref(id: id)
        case .order(let id):
            router.order = TradingRouter.Ref(id: id)
        case .trade(let instrument, let side):
            router.trade(instrument, side: side)
        case .ask(let question):
            router.askCopilot(question)
        }
    }

    private func configureTabBar() {
        let isDark = colorScheme == .dark
        let normalColor = isDark ? UIColor.white.withAlphaComponent(0.6) : UIColor.label.withAlphaComponent(0.5)
        let style = UITraitCollection(userInterfaceStyle: isDark ? .dark : .light)
        let selectedColor = UIColor(DS.accent).resolvedColor(with: style)

        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        appearance.shadowColor = .clear

        appearance.stackedLayoutAppearance.normal.iconColor = normalColor
        appearance.stackedLayoutAppearance.selected.iconColor = selectedColor
        appearance.stackedLayoutAppearance.normal.titleTextAttributes = [.foregroundColor: normalColor]
        appearance.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: selectedColor]

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
        UITabBar.appearance().tintColor = selectedColor
        UITabBar.appearance().unselectedItemTintColor = normalColor
    }
}

// MARK: - AI Agent Locked View
struct AIAgentLockedView: View {
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme
    @State private var showPaywall = false

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        ZStack {
            theme.background.ignoresSafeArea()

            VStack(spacing: 32) {
                // Animated AI Brain Icon
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.purple.opacity(0.4), .blue.opacity(0.3)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 180, height: 180)
                        .blur(radius: 40)

                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 80))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.purple, .blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: .purple.opacity(colorScheme == .dark ? 0.6 : 0.04), radius: 20)

                    // Lock overlay
                    Image(systemName: "lock.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.white)
                        .padding(12)
                        .background(Color.purple)
                        .clipShape(Circle())
                        .shadow(color: .purple.opacity(colorScheme == .dark ? 0.6 : 0.04), radius: 10)
                        .offset(x: 50, y: 50)
                }
                .accessibilityHidden(true)

                VStack(spacing: 16) {
                    Text("AI Investing Assistant")
                        .font(.title.bold())
                        .foregroundColor(theme.primaryText)
                        .multilineTextAlignment(.center)

                    Text("Get market summaries, stock research and portfolio insights.")
                        .font(.body)
                        .foregroundColor(theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                // Feature highlights
                VStack(spacing: 16) {
                    AIFeatureHighlight(icon: "lightbulb.fill", text: "Smart investment insights", color: .yellow)
                    AIFeatureHighlight(icon: "chart.bar.fill", text: "Real-time market analysis", color: .blue)
                    AIFeatureHighlight(icon: "message.fill", text: "24/7 AI assistant", color: .purple)
                    AIFeatureHighlight(icon: "sparkles", text: "Portfolio summaries", color: .pink)
                }
                .padding(.horizontal, 40)

                Spacer()

                // Upgrade button
                Button {
                    showPaywall = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "crown.fill")
                            .font(.title3)
                        Text("Upgrade to Pro")
                            .font(.headline)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(
                        LinearGradient(
                            colors: [.purple, .blue],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(16)
                    .shadow(color: .purple.opacity(colorScheme == .dark ? 0.5 : 0.04), radius: 15, y: 8)
                }
                .accessibilityHint("Opens subscription options to unlock AI assistant")
                .padding(.horizontal, 40)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle("AI Assistant")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPaywall) {
            PaywallView(requiredTier: .pro, featureName: "AI Investing Assistant")
        }
    }
}

// MARK: - AI Feature Highlight Helper
struct AIFeatureHighlight: View {
    let icon: String
    let text: String
    let color: Color
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(color)
                .frame(width: 30)

            Text(text)
                .font(.body)
                .foregroundColor(theme.primaryText.opacity(0.9))

            Spacer()

            Image(systemName: "checkmark")
                .font(.caption)
                .foregroundColor(appTheme.positiveColor)
        }
        .padding()
        .background(theme.chartPlaceholder)
        .cornerRadius(12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

#Preview {
    ContentView()  // uses .constant(.home) default
        .environmentObject(MarketData())
        .environmentObject(PriceAlertManager())
        .environmentObject(SubscriptionManager.shared)
        .environmentObject(ThemeManager())
        .environmentObject(SupabaseAuthManager())
        .environmentObject(AIInsightService.shared)
        .environmentObject(TradingStore.shared)
        .environmentObject(TradingRouter.shared)
}
