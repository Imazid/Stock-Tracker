//
//  ContentView.swift
//  Stock Tracker
//

import SwiftUI
import UIKit

// Add to MainTab enum
enum MainTab: String, CaseIterable, Hashable {
    case home = "Home"
    case watchlist = "Watchlist"
    case portfolio = "Portfolio"
    case aiAgent = "AI Agent"
    case news = "News"
    case search = "Search"

    var icon: String {
        switch self {
        case .home:         return "house"
        case .watchlist:    return "chart.line.uptrend.xyaxis"
        case .portfolio:    return "briefcase"
        case .aiAgent:      return "brain.head.profile"
        case .news:         return "newspaper"
        case .search:       return "magnifyingglass"
        }
    }

    var localizedTitle: LocalizedStringKey {
        switch self {
        case .home: return "Home"
        case .watchlist: return "Watchlist"
        case .portfolio: return "Portfolio"
        case .aiAgent: return "AI Agent"
        case .news: return "News"
        case .search: return "Search"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var marketData: MarketData
    @EnvironmentObject var alertManager: PriceAlertManager
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @Environment(\.colorScheme) var colorScheme

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

            Tab("Watchlist", systemImage: MainTab.watchlist.icon, value: MainTab.watchlist) {
                AppleStocksWatchlistView()
            }

            Tab("Portfolio", systemImage: MainTab.portfolio.icon, value: MainTab.portfolio) {
                PortfolioView()
            }

            Tab("News", systemImage: MainTab.news.icon, value: MainTab.news) {
                NewsView()
            }

            Tab("Search", systemImage: "magnifyingglass", value: MainTab.search, role: .search) {
                StockSearchView()
            }
        }
        .tint(Color(red: 0.45, green: 0.75, blue: 1.0))
        .sensoryFeedback(.impact(flexibility: .soft), trigger: selectedTab)
        .onChange(of: selectedTab) { _, _ in marketData.refreshIfStale() }
        .onAppear { configureTabBar() }
    }

    private func configureTabBar() {
        let isDark = colorScheme == .dark
        let normalColor = isDark ? UIColor.white.withAlphaComponent(0.6) : UIColor.label.withAlphaComponent(0.5)
        let selectedColor = UIColor(red: 0.45, green: 0.75, blue: 1.0, alpha: 1.0)

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

                    Text("Get instant insights, stock analysis, and portfolio advice powered by AI")
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
                    AIFeatureHighlight(icon: "sparkles", text: "Personalized recommendations", color: .pink)
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
}
