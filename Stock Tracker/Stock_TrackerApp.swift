import SwiftUI

@main
struct StockCryptoTrackerApp: App {
    @StateObject private var marketData = MarketData()
    @StateObject private var alertManager = PriceAlertManager()
    
    @State private var isLaunching: Bool = true   // controls the loading screen
    
    var body: some Scene {
        WindowGroup {
            ZStack {
                // Main app UI
                ContentView()
                    .environmentObject(marketData)
                    .environmentObject(alertManager)
                
                // Splash / loading screen overlay
                if isLaunching {
                    SplashView()
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .onAppear {
                // Fake loading delay – adjust as you like
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation(.easeOut(duration: 0.5)) {
                        isLaunching = false
                    }
                }
            }
        }
    }
}
