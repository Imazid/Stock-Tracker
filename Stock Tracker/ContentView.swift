//
//  ContentView.swift
//  Stock Tracker
//

import SwiftUI

enum MainTab: String, CaseIterable {
    case home = "Home"
    case watchlist = "Watchlist"
    case portfolio = "Portfolio"
    case news = "News"
    
    var icon: String {
        switch self {
        case .home:      return "house.fill"
        case .watchlist: return "chart.line.uptrend.xyaxis"
        case .portfolio: return "briefcase.fill"
        case .news:      return "newspaper.fill"
        }
    }
    
    var title: String {
        rawValue
    }
}

struct ContentView: View {
    @EnvironmentObject var marketData: MarketData
    @EnvironmentObject var alertManager: PriceAlertManager
    
    @State private var selectedTab: MainTab = .home
    
    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem {
                    Label(MainTab.home.title, systemImage: MainTab.home.icon)
                }
                .tag(MainTab.home)
            AppleStocksWatchlistView()
                .tabItem {
                    Label(MainTab.watchlist.title, systemImage: MainTab.watchlist.icon)
                }
                .tag(MainTab.watchlist)
            
            PortfolioView()
                .tabItem {
                    Label(MainTab.portfolio.title, systemImage: MainTab.portfolio.icon)
                }
                .tag(MainTab.portfolio)
            
            NewsView()
                .tabItem {
                    Label(MainTab.news.title, systemImage: MainTab.news.icon)
                }
                .tag(MainTab.news)
        }
        .tint(.white)  // Beautiful white icons
        .sensoryFeedback(.impact(flexibility: .soft), trigger: selectedTab)  // Added haptic feedback
        .onAppear {
            let appearance = UITabBarAppearance()
            appearance.configureWithTransparentBackground()
            appearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
            appearance.shadowColor = .clear
            
            appearance.stackedLayoutAppearance.normal.iconColor = UIColor.white.withAlphaComponent(0.6)
            appearance.stackedLayoutAppearance.selected.iconColor = .white
            appearance.stackedLayoutAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.white.withAlphaComponent(0.6)]
            appearance.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: UIColor.white]
            
            UITabBar.appearance().standardAppearance = appearance
            UITabBar.appearance().scrollEdgeAppearance = appearance
            UITabBar.appearance().tintColor = .white
            UITabBar.appearance().unselectedItemTintColor = UIColor.white.withAlphaComponent(0.6)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(MarketData())
        .environmentObject(PriceAlertManager())
        .preferredColorScheme(.dark)
}
