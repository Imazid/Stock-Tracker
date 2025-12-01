import SwiftUI

enum MainTab: String, CaseIterable, Identifiable {
    case watchlist = "Watchlist"
    case portfolio = "Portfolio"
    case news = "News"
    
    var id: String { rawValue }
}

struct ContentView: View {
    @EnvironmentObject var marketData: MarketData
    @EnvironmentObject var alertManager: PriceAlertManager
    
    @State private var activeTab: MainTab = .watchlist
    @State private var showAlerts: Bool = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Background gradient
                LinearGradient(
                    colors: [
                        Color.black,
                        Color(red: 0.05, green: 0.05, blue: 0.08)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                
                VStack(spacing: 16) {
                    header
                    
                    // Main content for the active tab
                    contentForActiveTab
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )
                        .padding(.horizontal)
                    
                    // Push bar to bottom
                    bottomTabBar
                        .padding(.horizontal)
                        .padding(.bottom, 16)
                }
            }
            .navigationBarHidden(true)
        }
    }
    
    // MARK: - Header
    
    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Markets")
                    .font(.largeTitle.bold())
                    .foregroundColor(.white)
                
                Text(headerSubtitle)
                    .font(.subheadline)
                    .foregroundColor(.gray)
            }
            
            Spacer()
            
            Button {
                showAlerts = true
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 36, height: 36)
                    
                    Image(systemName: "bell.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(
                            alertManager.alerts.contains(where: { $0.isActive })
                            ? .yellow
                            : .white
                        )
                }
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showAlerts) {
                PriceAlertsView()
                    .environmentObject(alertManager)
            }
        }
        .padding([.top, .horizontal])
    }
    
    private var headerSubtitle: String {
        switch activeTab {
        case .watchlist:
            return "Track your favourite stocks & crypto"
        case .portfolio:
            return "See how your holdings are performing"
        case .news:
            return "Latest headlines from the markets"
        }
    }
    
    // MARK: - Bottom Bar (eBay-style)
    
    // MARK: - Bottom Bar (Glass Highlight Style)

    private var bottomTabBar: some View {
        ZStack {
            // BACKGROUND PILLED BAR
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .frame(height: 70)

            // MOVING GLASS HIGHLIGHT
            HStack(spacing: 12) {
                if activeTab == .watchlist {
                    glassHighlight
                } else {
                    Color.clear.frame(maxWidth: .infinity)
                }

                if activeTab == .portfolio {
                    glassHighlight
                } else {
                    Color.clear.frame(maxWidth: .infinity)
                }

                if activeTab == .news {
                    glassHighlight
                } else {
                    Color.clear.frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 12)
            .animation(.easeInOut(duration: 0.25), value: activeTab)

            // FOREGROUND BUTTONS
            HStack(spacing: 12) {
                tabItem(icon: "star.fill", title: "Watchlist", tab: .watchlist)
                tabItem(icon: "briefcase.fill", title: "Portfolio", tab: .portfolio)
                tabItem(icon: "newspaper.fill", title: "News", tab: .news)
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 8)
    }


    // MARK: - GLASS HIGHLIGHT VIEW
    private var glassHighlight: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(.ultraThinMaterial)      // actual glass blur
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            )
            .frame(height: 50)
            .shadow(color: Color.white.opacity(0.15), radius: 4, y: 2)
    }


    private func tabItem(icon: String,
                         title: String,
                         tab: MainTab) -> some View {
        let isSelected = (activeTab == tab)
        
        return Button {
            if activeTab != tab {
                tabHaptic()
            }
            withAnimation(.easeInOut(duration: 0.2)) {
                activeTab = tab
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundColor(isSelected ? .black : .white)
            .background(
                Group {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .stroke(Color.white.opacity(0.25), lineWidth: 1)
                            )
                    } else {
                        Color.clear
                    }
                }
            )
        }
        .buttonStyle(.plain)
    }



    
    // MARK: - Tab Content
    
    @ViewBuilder
    private var contentForActiveTab: some View {
        switch activeTab {
        case .watchlist:
            WatchlistView()
                .environmentObject(marketData)
        case .portfolio:
            PortfolioView()
                .environmentObject(marketData)
        case .news:
            NewsView()
                .environmentObject(marketData)
        }
    }
}

func tabHaptic() {
    let generator = UIImpactFeedbackGenerator(style: .light)
    generator.impactOccurred()
}

// MARK: - Preview

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        let marketData = MarketData()
        let alertManager = PriceAlertManager()
        
        ContentView()
            .environmentObject(marketData)
            .environmentObject(alertManager)
            .preferredColorScheme(.dark)
    }
    
   

}
