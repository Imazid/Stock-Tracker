//
//  SlidingMenuView.swift
//  Stock Tracker
//

import SwiftUI

struct SlidingMenuView: View {
    @Binding var isSignedIn: Bool
    @Binding var showMenu: Bool
    
    @State private var autoRefresh = true
    @State private var isDarkMode = true
    
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                // Profile Header
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 70))
                        .foregroundColor(.blue)
                        .background(Circle().fill(Color.white.opacity(0.1))
                    
                    if isSignedIn {
                        Text("John Doe")
                            .font(.title2.bold())
                            .foregroundColor(.white)
                        Text("Premium Member")
                            .font(.caption)
                            .foregroundColor(.green)
                    } else {
                        Text("Welcome")
                            .font(.title2.bold())
                            .foregroundColor(.white)
                        Text("Sign in to unlock Pro")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                    }
                }
                .padding(.top, 80)
                
                Divider().background(Color.gray.opacity(0.3))
                
                .padding(.horizontal, -20)
                
                // Menu Items
                VStack(alignment: .leading, spacing: 20) {
                    MenuRow(icon: "bell.fill", title: "Price Alerts")
                    MenuRow(icon: "dollarsign.circle.fill", title: "Go Pro", badge: "Upgrade", color: .orange)
                    MenuRow(icon: "arrow.clockwise.circle", title: "Auto Refresh", isToggle: true, isOn: $autoRefresh)
                    MenuRow(icon: "moon.fill", title: "Dark Mode", isToggle: true, isOn: $isDarkMode)
                    MenuRow(icon: "star.fill", title: "Rate on App Store", color: .yellow)
                    MenuRow(icon: "square.and.arrow.up", title: "Share App")
                    MenuRow(icon: "questionmark.circle", title: "Help & Support")
                }
                
                Spacer()
                
                // Pro Banner
                Button {
                    // Show subscription sheet later
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                } label: {
                    HStack {
                        Image(systemName: "crown.fill")
                            .foregroundColor(.yellow)
                        Text("Upgrade to Pro")
                            .font(.headline)
                        Spacer()
                        Text("→")
                    }
                    .padding()
                    .background(Color.orange.opacity(0.2))
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange, lineWidth: 1))
                }
                .padding(.horizontal)
                
                // Sign In / Out Button
                Button(isSignedIn ? "Sign Out" : "Sign In / Sign Up") {
                    withAnimation { showMenu = false }
                    // TODO: Add auth
                }
                .font(.headline)
                .foregroundColor(.red)
                .padding(.bottom, 40)
            }
            .padding(.leading, 28)
            .frame(width: 300)
            .background(Color.black)
            .shadow(color: .black.opacity(0.6), radius: 30, x: 15)
            
            Spacer()
        }
        .ignoresSafeArea()
    }
}

struct MenuRow: View {
    let icon: String
    let title: String
    var badge: String? = nil
    var color: Color = .blue
    var isToggle = false
    @Binding var isOn: Bool?
    
    init(icon: String, title: String, badge: String? = nil, color: Color = .blue, isToggle: Bool = false, isOn: Binding<Bool>? = nil) {
        self.icon = icon
        self.title = title
        self.badge = badge
        self.color = color
        self.isToggle = isToggle
        self._isOn = isOn ?? .constant(false)
    }
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(color)
                .frame(width: 30)
            
            Text(title)
                .foregroundColor(.white)
                .font(.body)
            
            if let badge = badge {
                Spacer()
                Text(badge)
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(color.opacity(0.3))
                    .cornerRadius(8)
            }
            
            if isToggle {
                Spacer()
                Toggle("", isOn: isOn!)
                    .labelsHidden()
                    .tint(.blue)
            }
        }
        .padding(.vertical, 6)
    }
}