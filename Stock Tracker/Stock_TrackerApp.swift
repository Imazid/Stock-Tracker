//
//  Stock_TrackerApp.swift
//  Stock Tracker
//

import SwiftUI
import LocalAuthentication
import Combine

@main
struct StockCryptoTrackerApp: App {
    @StateObject private var marketData = MarketData()
    @StateObject private var alertManager = PriceAlertManager()
    @StateObject private var subscriptionManager: SubscriptionManager
    @StateObject private var authManager = AuthManager()
    
    @State private var isLaunching = true
    
    init() {
        let manager = SubscriptionManager.shared
        _subscriptionManager = StateObject(wrappedValue: manager)
    }
    
    var body: some Scene {
        WindowGroup {
            ZStack {
                if authManager.isAuthenticated {
                    ContentView()
                        .environmentObject(marketData)
                        .environmentObject(alertManager)
                        .environmentObject(subscriptionManager)
                        .environmentObject(authManager)
                } else {
                    LockedView()
                        .environmentObject(authManager)
                }
                
                if isLaunching {
                    SplashView()
                        .zIndex(1)
                        .transition(.opacity)
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    withAnimation(.easeOut(duration: 0.6)) {
                        isLaunching = false
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                authManager.reset()
            }
            .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Auth Manager (with working toggle support)
class AuthManager: ObservableObject {
    @Published var isAuthenticated = false
    @Published var errorMessage: String?
    @Published var useBiometrics: Bool = UserDefaults.standard.bool(forKey: "useBiometrics") {
        didSet {
            UserDefaults.standard.set(useBiometrics, forKey: "useBiometrics")
        }
    }
    
    init() {
        // Default to true if no saved value
        if UserDefaults.standard.object(forKey: "useBiometrics") == nil {
            self.useBiometrics = true
        }
    }
    
    func authenticate() {
        // Skip biometrics if user turned it off
        guard useBiometrics else {
            DispatchQueue.main.async {
                self.isAuthenticated = true
                self.errorMessage = nil
            }
            return
        }
        
        let context = LAContext()
        var error: NSError?
        
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            let reason = "Unlock Stock Tracker to view your portfolio"
            
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, authError in
                DispatchQueue.main.async {
                    self.isAuthenticated = success
                    if !success {
                        self.errorMessage = authError?.localizedDescription ?? "Authentication failed"
                    }
                }
            }
        } else {
            // No biometrics available → auto unlock
            DispatchQueue.main.async {
                self.isAuthenticated = true
            }
        }
    }
    
    func reset() {
        // Only lock the app if biometrics are enabled
        if useBiometrics {
            isAuthenticated = false
        }
        // If disabled, stay unlocked when returning from background
    }
}

// MARK: - Locked Screen
struct LockedView: View {
    @EnvironmentObject var authManager: AuthManager
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 40) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 100))
                    .foregroundColor(.blue)
                
                Text("Stock Tracker")
                    .font(.largeTitle.bold())
                    .foregroundColor(.white)
                
                Text("Use Face ID to securely access your portfolio")
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                
                Button("Unlock with Face ID") {
                    authManager.authenticate()
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 40)
                .padding(.vertical, 18)
                .background(Color.blue)
                .cornerRadius(20)
                .shadow(color: .blue.opacity(0.6), radius: 20, y: 10)
                
                if let error = authManager.errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.subheadline)
                        .padding()
                }
            }
        }
        .onAppear {
            // Only auto-prompt if biometrics are enabled
            if authManager.useBiometrics {
                authManager.authenticate()
            } else {
                authManager.isAuthenticated = true
            }
        }
    }
}

#Preview {
    LockedView()
        .environmentObject(AuthManager())
        .preferredColorScheme(.dark)
}
