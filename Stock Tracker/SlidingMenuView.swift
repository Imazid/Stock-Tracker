//
//  SlidingMenuView.swift
//  Stock Tracker
//

import SwiftUI
import LocalAuthentication  // ← For checking Face ID availability

struct SlidingMenuView: View {
    @Binding var isSignedIn: Bool
    @Binding var showMenu: Bool
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @EnvironmentObject var marketData: MarketData
    @EnvironmentObject var alertManager: PriceAlertManager
    @EnvironmentObject var authManager: AuthManager  // ← Add this to receive the manager
    
    @State private var autoRefresh = true
    @State private var showSubscriptionSettings = false
    @State private var showAlerts = false
    
    private var isFaceIDAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }
    
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Spacer()
                
                VStack(spacing: 0) {
                    // MARK: - Black Top Bar (full safe area)
                    Color.black
                        .frame(height: geo.safeAreaInsets.top)
                        .ignoresSafeArea(edges: .top)
                    
                    // MARK: - Gradient Header
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            ZStack {
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: subscriptionManager.currentTier.gradientColors,
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 80, height: 80)
                                    .shadow(color: subscriptionManager.currentTier.color.opacity(0.7), radius: 20)
                                
                                Image(systemName: subscriptionManager.currentTier.icon)
                                    .font(.system(size: 36, weight: .bold))
                                    .foregroundColor(.white)
                            }
                            
                            VStack(alignment: .leading, spacing: 8) {
                                if isSignedIn {
                                    Text("John Doe")
                                        .font(.title2.bold())
                                        .foregroundColor(.white)
                                    
                                    HStack(spacing: 8) {
                                        Image(systemName: subscriptionManager.currentTier.icon)
                                            .font(.caption)
                                        Text("\(subscriptionManager.currentTier.displayName) Member")
                                            .font(.subheadline.bold())
                                    }
                                    .foregroundColor(subscriptionManager.currentTier.color)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(subscriptionManager.currentTier.color.opacity(0.2))
                                    .cornerRadius(12)
                                } else {
                                    Text("Guest Mode")
                                        .font(.title2.bold())
                                        .foregroundColor(.white)
                                    Text("Sign in for premium features")
                                        .font(.subheadline)
                                        .foregroundColor(.white.opacity(0.7))
                                }
                            }
                            
                            Spacer()
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
                    .background(
                        LinearGradient(
                            colors: [.black, subscriptionManager.currentTier.gradientColors.first ?? .gray, subscriptionManager.currentTier.gradientColors.last ?? .gray],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .overlay(
                        Rectangle()
                            .fill(LinearGradient(colors: [.white.opacity(0.08), .clear], startPoint: .leading, endPoint: .trailing))
                    )
                    
                    // MARK: - Menu Items (Scrollable)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            MenuItemButton(icon: "gearshape.fill", title: "Subscription", color: .purple) {
                                showSubscriptionSettings = true
                            }
                            
                            MenuItemButton(icon: "bell.fill", title: "Price Alerts", color: .orange) {
                                showAlerts = true
                            }
                            
                            HStack(spacing: 16) {
                                Image(systemName: "dollarsign.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(LinearGradient(colors: [.green, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                                
                                Picker("Currency", selection: $marketData.preferredCurrency) {
                                    Text("USD").tag("USD")
                                    Text("AUD").tag("AUD")
                                    Text("EUR").tag("EUR")
                                }
                                .pickerStyle(.menu)
                                .foregroundColor(.white)
                                .accentColor(.green)
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 16)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(16)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Color.green.opacity(0.3), lineWidth: 1)
                            )
                            
                            MenuToggleItem(icon: "arrow.clockwise", title: "Auto Refresh", color: .blue, isOn: $autoRefresh)
                            
                            // MARK: - New Face ID Toggle
                            if isFaceIDAvailable {
                                MenuToggleItem(
                                    icon: authManager.useBiometrics ? "faceid" : "touchid",
                                    title: "App Lock with Face ID",
                                    color: .indigo,
                                    isOn: $authManager.useBiometrics
                                )
                            }
                            
                            MenuItemButton(icon: "gearshape.2.fill", title: "App Settings", color: .gray) {
                                // Future functionality
                            }
                        }
                        .padding(24)
                        .padding(.top, 8)
                    }
                    
                    // MARK: - Sign In / Out + Footer
                    VStack(spacing: 20) {
                        Button {
                            isSignedIn.toggle()
                            withAnimation { showMenu = false }
                        } label: {
                            HStack {
                                Image(systemName: isSignedIn ? "power" : "person.crop.circle.fill.badge.plus")
                                    .font(.title3)
                                Text(isSignedIn ? "Sign Out" : "Sign In")
                                    .font(.headline)
                            }
                            .foregroundColor(.red)
                            .padding(.vertical, 16)
                            .frame(maxWidth: .infinity)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(16)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Color.red.opacity(0.3), lineWidth: 1)
                            )
                        }
                        
                        // MARK: - Footer
                        VStack(spacing: 8) {
                            Text("Markets App")
                                .font(.caption.bold())
                                .foregroundColor(.white.opacity(0.8))
                            
                            Text("Version 1.0 • December 2025")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.5))
                            
                            HStack(spacing: 20) {
                                Image(systemName: "globe")
                                    .foregroundColor(.white.opacity(0.6))
                                Image(systemName: "shield.lefthalf.fill")
                                    .foregroundColor(.white.opacity(0.6))
                                Image(systemName: "heart.fill")
                                    .foregroundColor(.red.opacity(0.7))
                            }
                            .font(.caption)
                        }
                    }
                    .padding(24)
                    .padding(.bottom, geo.safeAreaInsets.bottom)
                    .background(
                        LinearGradient(
                            colors: [.black.opacity(0.9), .black],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
                .frame(width: geo.size.width * 0.78)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                .shadow(color: .black.opacity(0.6), radius: 30, x: -15)
                .offset(x: showMenu ? 0 : geo.size.width)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            .gesture(
                DragGesture()
                    .onEnded { value in
                        if value.translation.width < -100 {
                            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                                showMenu = false
                            }
                        }
                    }
            )
        }
        .ignoresSafeArea(edges: .all)
        .sheet(isPresented: $showSubscriptionSettings) {
            SubscriptionSettingsView()
        }
        .sheet(isPresented: $showAlerts) {
            PriceAlertsSheet()
        }
    }
}

// MenuItemButton and MenuToggleItem unchanged

#Preview {
    SlidingMenuView(isSignedIn: .constant(true), showMenu: .constant(true))
        .environmentObject(SubscriptionManager.shared)
        .environmentObject(MarketData())
        .environmentObject(PriceAlertManager())
        .environmentObject(AuthManager())
        .preferredColorScheme(.dark)
}

// Reusable Menu Items (unchanged but improved)
struct MenuItemButton: View {
    let icon: String
    let title: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(LinearGradient(colors: [color, color.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing))
                
                Text(title)
                    .font(.headline)
                    .foregroundColor(.white)
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .background(Color.white.opacity(0.05))
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(color.opacity(0.3), lineWidth: 1)
            )
        }
    }
}

struct MenuToggleItem: View {
    let icon: String
    let title: String
    let color: Color
    @Binding var isOn: Bool
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(LinearGradient(colors: [color, color.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing))
            
            Text(title)
                .font(.headline)
                .foregroundColor(.white)
            
            Spacer()
            
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(color)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(Color.white.opacity(0.05))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(color.opacity(0.3), lineWidth: 1)
        )
    }
}

#Preview {
    SlidingMenuView(isSignedIn: .constant(true), showMenu: .constant(true))
        .environmentObject(SubscriptionManager.shared)
        .environmentObject(MarketData())
        .environmentObject(PriceAlertManager())
        .preferredColorScheme(.dark)
}
