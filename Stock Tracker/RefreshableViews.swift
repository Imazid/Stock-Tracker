//
//  RefreshableViews.swift
//  Stock Tracker
//
//  Reusable refresh components and modifiers
//

import SwiftUI

// MARK: - Refresh Indicator

struct RefreshIndicator: View {
    let lastRefreshed: String
    let isStale: Bool
    let onRefresh: () -> Void
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundColor(isStale ? .orange : .gray)
            
            Text("Updated \(lastRefreshed)")
                .font(.caption)
                .foregroundColor(isStale ? .orange : .gray)
            
            if isStale {
                Button(action: onRefresh) {
                    Text("Refresh")
                        .font(.caption.bold())
                        .foregroundColor(.blue)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.05))
        )
    }
}

// MARK: - Stale Data Banner

struct StaleDataBanner: View {
    let message: String
    let action: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Data May Be Outdated")
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                
                Text(message)
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            
            Spacer()
            
            Button(action: action) {
                Text("Refresh")
                    .font(.subheadline.bold())
                    .foregroundColor(.blue)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                )
        )
    }
}

// MARK: - Refreshable List Header

struct RefreshableListHeader: View {
    let title: String
    let subtitle: String?
    let lastRefreshed: String
    let isStale: Bool
    let canRefresh: Bool
    let onRefresh: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title2.bold())
                        .foregroundColor(.white)
                    
                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                
                Spacer()
                
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.title3)
                        .foregroundColor(canRefresh ? .blue : .gray)
                }
                .disabled(!canRefresh)
            }
            
            HStack {
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundColor(.gray)
                
                Text("Updated \(lastRefreshed)")
                    .font(.caption)
                    .foregroundColor(.gray)
                
                if isStale {
                    Text("•")
                        .foregroundColor(.gray)
                    
                    Text("Stale data")
                        .font(.caption.bold())
                        .foregroundColor(.orange)
                }
            }
        }
    }
}

// MARK: - Loading Overlay

struct LoadingOverlay: View {
    let message: String
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
            
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.white)
                
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.white)
            }
            .padding(30)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.black.opacity(0.8))
            )
        }
    }
}

// MARK: - Refresh Button Style

struct RefreshButtonStyle: ButtonStyle {
    let isRefreshing: Bool
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .rotationEffect(.degrees(isRefreshing ? 360 : 0))
            .animation(
                isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                value: isRefreshing
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

// MARK: - View Extensions

extension View {
    /// Add pull-to-refresh with custom action
    func pullToRefresh(isRefreshing: Binding<Bool>, action: @escaping () async -> Void) -> some View {
        self.refreshable {
            await action()
        }
    }
    
    /// Show stale data indicator
    func staleDataIndicator(
        isStale: Bool,
        message: String,
        onRefresh: @escaping () -> Void
    ) -> some View {
        self.overlay(alignment: .top) {
            if isStale {
                StaleDataBanner(message: message, action: onRefresh)
                    .padding()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
    
    /// Show loading overlay
    func loadingOverlay(isLoading: Bool, message: String) -> some View {
        self.overlay {
            if isLoading {
                LoadingOverlay(message: message)
                    .transition(.opacity)
            }
        }
    }
}

// MARK: - Preview Helpers

#Preview("Refresh Indicator") {
    VStack(spacing: 20) {
        RefreshIndicator(
            lastRefreshed: "2m ago",
            isStale: false,
            onRefresh: {}
        )
        
        RefreshIndicator(
            lastRefreshed: "10m ago",
            isStale: true,
            onRefresh: {}
        )
    }
    .padding()
    .background(Color.black)
}

#Preview("Stale Data Banner") {
    StaleDataBanner(
        message: "Last updated 10 minutes ago",
        action: {}
    )
    .padding()
    .background(Color.black)
}

#Preview("List Header") {
    RefreshableListHeader(
        title: "Holdings",
        subtitle: "5 positions",
        lastRefreshed: "Just now",
        isStale: false,
        canRefresh: true,
        onRefresh: {}
    )
    .padding()
    .background(Color.black)
}
