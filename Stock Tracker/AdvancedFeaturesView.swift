//
//  AdvancedFeaturesView.swift
//  Stock Tracker
//
//  Created by Ihtisham Mazid on 27/1/2026.
//


//
//  AdvancedFeaturesView.swift
//  Stock Tracker
//
//  PHASE 6 - Advanced & Pro-Only Features
//

import SwiftUI

struct AdvancedFeaturesView: View {
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @State private var selectedFeature: AdvancedFeature = .analytics
    
    enum AdvancedFeature: String, CaseIterable {
        case analytics = "Analytics"
        case alerts = "Custom Alerts"
        case tax = "Tax Tools"
        case export = "Export"
        
        var icon: String {
            switch self {
            case .analytics: return "chart.xyaxis.line"
            case .alerts: return "exclamationmark.triangle"
            case .tax: return "calculator"
            case .export: return "square.and.arrow.up"
            }
        }
        
        var requiredTier: SubscriptionTier {
            switch self {
            case .analytics, .tax, .export: return .pro
            case .alerts: return .black
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header
                headerSection
                    .padding()
                    .background(Color(UIColor.systemBackground))
                
                Divider()
                
                // Feature Selector
                featureSelector
                    .padding()
                    .background(Color(UIColor.systemBackground))
                
                // Content
                ScrollView {
                    Group {
                        switch selectedFeature {
                        case .analytics:
                            AdvancedAnalyticsView()
                        case .alerts:
                            CustomAlertsView()
                        case .tax:
                            TaxReportingView()
                        case .export:
                            ExportToolsView()
                        }
                    }
                    .padding()
                }
                .background(Color(UIColor.systemGroupedBackground))
            }
            .navigationTitle("Advanced Features")
            .navigationBarTitleDisplayMode(.large)
        }
    }
    
    // MARK: - Header Section
    
    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Advanced Features")
                    .font(.title2.weight(.bold))
                    .foregroundColor(.primary)
                
                Text("Professional tools for serious investors")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            HStack(spacing: 6) {
                Image(systemName: subscriptionManager.currentTier.icon)
                    .font(.caption)
                Text(subscriptionManager.currentTier.displayName.uppercased())
                    .font(.caption.weight(.semibold))
            }
            .foregroundColor(subscriptionManager.currentTier.color)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(subscriptionManager.currentTier.color.opacity(0.1))
            .cornerRadius(12)
        }
    }
    
    // MARK: - Feature Selector
    
    private var featureSelector: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(AdvancedFeature.allCases, id: \.self) { feature in
                Button {
                    selectedFeature = feature
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: feature.icon)
                            .font(.title2)
                            .foregroundColor(selectedFeature == feature ? .purple : .secondary)
                        
                        Text(feature.rawValue)
                            .font(.caption.weight(.medium))
                            .foregroundColor(selectedFeature == feature ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        selectedFeature == feature
                            ? Color(UIColor.systemBackground)
                            : Color.clear
                    )
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                selectedFeature == feature ? Color.purple : Color(UIColor.systemGray5),
                                lineWidth: selectedFeature == feature ? 2 : 1
                            )
                    )
                }
            }
        }
    }
}

// MARK: - Advanced Analytics View

struct AdvancedAnalyticsView: View {
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    
    private let metrics = [
        (name: "Volatility (30d)", value: "18.2%", status: "moderate", description: "Measures how much your portfolio value fluctuates"),
        (name: "Maximum Drawdown", value: "-12.4%", status: "good", description: "Largest peak-to-trough decline in portfolio value"),
        (name: "Sharpe Ratio", value: "1.45", status: "good", description: "Risk-adjusted return measure (higher is better)"),
        (name: "Beta", value: "1.08", status: "moderate", description: "How much your portfolio moves relative to the market")
    ]
    
    var body: some View {
        VStack(spacing: 16) {
            if !subscriptionManager.hasFeatureAccess(feature: .technicalAnalysis) {
                FeatureLockView(
                    featureName: "Advanced Analytics",
                    requiredTier: .pro
                )
            } else {
                // Risk Metrics
                VStack(alignment: .leading, spacing: 16) {
                    Text("Risk Metrics")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(metrics, id: \.name) { metric in
                            RiskMetricCard(
                                name: metric.name,
                                value: metric.value,
                                status: metric.status,
                                description: metric.description
                            )
                        }
                    }
                }
                .padding()
                .background(Color(UIColor.systemBackground))
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(UIColor.systemGray5), lineWidth: 1)
                )
                
                // Assessment
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "shield.fill")
                        .font(.title2)
                        .foregroundColor(.blue)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Portfolio Risk Assessment")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)
                        
                        Text("Your portfolio shows moderate volatility with good risk-adjusted returns. The Sharpe ratio of 1.45 indicates you're getting solid returns for the risk taken.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                )
            }
        }
    }
}

struct RiskMetricCard: View {
    let name: String
    let value: String
    let status: String
    let description: String
    
    private var statusColor: Color {
        switch status {
        case "good": return .green
        case "moderate": return .orange
        default: return .red
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(name)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Image(systemName: "waveform.path.ecg")
                    .font(.caption)
                    .foregroundColor(statusColor)
            }
            
            Text(value)
                .font(.title2.weight(.bold))
                .foregroundColor(.primary)
            
            Text(description)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
        .padding()
        .background(Color(UIColor.systemGray6))
        .cornerRadius(12)
    }
}

// MARK: - Custom Alerts View

struct CustomAlertsView: View {
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    
    private let alerts = [
        (name: "Tech Sector Rotation", conditions: ["AAPL down 5%", "MSFT down 3%", "Same day"], active: true),
        (name: "Portfolio Drawdown", conditions: ["Total value down 10%", "From all-time high"], active: true),
        (name: "Dividend Accumulation", conditions: ["Monthly dividends > $100", "Reinvest automatically"], active: false)
    ]
    
    var body: some View {
        VStack(spacing: 16) {
            if subscriptionManager.currentTier != .black {
                FeatureLockView(
                    featureName: "Custom Alert Engine",
                    requiredTier: .black
                )
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Active Custom Alerts")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        Spacer()
                        
                        Button {
                            // Add new alert
                        } label: {
                            Text("+ New Alert")
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.purple)
                                .cornerRadius(8)
                        }
                    }
                    
                    ForEach(alerts, id: \.name) { alert in
                        CustomAlertCard(
                            name: alert.name,
                            conditions: alert.conditions,
                            isActive: alert.active
                        )
                    }
                }
                .padding()
                .background(Color(UIColor.systemBackground))
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(UIColor.systemGray5), lineWidth: 1)
                )
                
                // Explanation
                VStack(alignment: .leading, spacing: 8) {
                    Text("What are Custom Alerts?")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    
                    Text("Create complex, multi-condition alerts that monitor multiple stocks, portfolio metrics, or market conditions simultaneously. Get notified when all your conditions are met.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.purple.opacity(0.1))
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.purple.opacity(0.3), lineWidth: 1)
                )
            }
        }
    }
}

struct CustomAlertCard: View {
    let name: String
    let conditions: [String]
    let isActive: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                
                Spacer()
                
                Toggle("", isOn: .constant(isActive))
                    .labelsHidden()
                    .toggleStyle(.glass)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(conditions, id: \.self) { condition in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.purple)
                            .frame(width: 6, height: 6)
                        
                        Text(condition)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(Color(UIColor.systemBackground))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(UIColor.systemGray5), lineWidth: 1)
        )
    }
}

// MARK: - Tax Reporting View

struct TaxReportingView: View {
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    
    var body: some View {
        VStack(spacing: 16) {
            if !subscriptionManager.hasFeatureAccess(feature: .exportReports) {
                FeatureLockView(
                    featureName: "Tax & Reporting Tools",
                    requiredTier: .pro
                )
            } else {
                // Tax Summary
                VStack(alignment: .leading, spacing: 16) {
                    Text("Tax Year 2024")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    HStack(spacing: 12) {
                        TaxSummaryCard(title: "Short-term Gains", value: "$1,240", color: .green)
                        TaxSummaryCard(title: "Long-term Gains", value: "$3,850", color: .blue)
                        TaxSummaryCard(title: "Realized Losses", value: "-$420", color: .red)
                    }
                    
                    VStack(spacing: 12) {
                        Button {
                            // Download PDF
                        } label: {
                            HStack {
                                Image(systemName: "arrow.down.circle.fill")
                                Text("Download Tax Report (PDF)")
                            }
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.primary)
                            .cornerRadius(12)
                        }
                        
                        Button {
                            // Export CSV
                        } label: {
                            HStack {
                                Image(systemName: "doc.text")
                                Text("Export for TurboTax (CSV)")
                            }
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color(UIColor.systemBackground))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.primary, lineWidth: 2)
                            )
                        }
                    }
                }
                .padding()
                .background(Color(UIColor.systemBackground))
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(UIColor.systemGray5), lineWidth: 1)
                )
                
                // Tax Loss Harvesting
                VStack(alignment: .leading, spacing: 12) {
                    Text("Tax Loss Harvesting Opportunities")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Consider selling XYZ")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.primary)
                            
                            Text("Down $340 (-8.2%). Selling now could offset gains and reduce tax burden.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Button("Learn more →") {}
                                .font(.caption.weight(.medium))
                                .foregroundColor(.orange)
                        }
                    }
                    .padding()
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(12)
                }
                .padding()
                .background(Color(UIColor.systemBackground))
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(UIColor.systemGray5), lineWidth: 1)
                )
                
                // Education
                VStack(alignment: .leading, spacing: 12) {
                    Text("Understanding Tax Reporting")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    
                    Text("Capital gains taxes depend on how long you held the investment:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        TaxInfoRow(title: "Short-term:", description: "Held less than 1 year, taxed as ordinary income")
                        TaxInfoRow(title: "Long-term:", description: "Held more than 1 year, preferential tax rates")
                    }
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                )
            }
        }
    }
}

struct TaxSummaryCard: View {
    let title: String
    let value: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text(value)
                .font(.title2.weight(.bold))
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(color.opacity(0.1))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(color.opacity(0.3), lineWidth: 1)
        )
    }
}

struct TaxInfoRow: View {
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color.blue)
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.primary)
                +
                Text(" \(description)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Export Tools View

struct ExportToolsView: View {
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    
    var body: some View {
        VStack(spacing: 16) {
            if !subscriptionManager.hasFeatureAccess(feature: .exportReports) {
                FeatureLockView(
                    featureName: "Export & Reports",
                    requiredTier: .pro
                )
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Export Portfolio Data")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ExportOptionCard(
                            icon: "doc.text.fill",
                            title: "Portfolio Report (PDF)",
                            description: "Comprehensive report with charts and analysis",
                            color: .blue
                        )
                        
                        ExportOptionCard(
                            icon: "arrow.down.circle.fill",
                            title: "Transactions (CSV)",
                            description: "All buy/sell transactions for spreadsheet",
                            color: .green
                        )
                        
                        ExportOptionCard(
                            icon: "chart.bar.fill",
                            title: "Performance Data (CSV)",
                            description: "Daily portfolio values and returns",
                            color: .purple
                        )
                        
                        ExportOptionCard(
                            icon: "square.stack.3d.up.fill",
                            title: "Holdings Snapshot (JSON)",
                            description: "Current positions in machine-readable format",
                            color: .orange
                        )
                    }
                }
                .padding()
                .background(Color(UIColor.systemBackground))
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(UIColor.systemGray5), lineWidth: 1)
                )
                
                // Scheduled Reports
                VStack(alignment: .leading, spacing: 16) {
                    Text("Scheduled Reports")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text("Automatically receive portfolio reports via email")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    VStack(spacing: 12) {
                        ScheduledReportRow(title: "Weekly Performance Summary", isEnabled: true)
                        ScheduledReportRow(title: "Monthly Tax Report", isEnabled: false)
                    }
                }
                .padding()
                .background(Color(UIColor.systemBackground))
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color(UIColor.systemGray5), lineWidth: 1)
                )
            }
        }
    }
}

struct ExportOptionCard: View {
    let icon: String
    let title: String
    let description: String
    let color: Color
    
    var body: some View {
        Button {
            // Export action
        } label: {
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title)
                    .foregroundColor(color)
                
                VStack(spacing: 6) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.center)
                    
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color(UIColor.systemBackground))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(UIColor.systemGray4), lineWidth: 2)
            )
        }
    }
}

struct ScheduledReportRow: View {
    let title: String
    let isEnabled: Bool
    
    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundColor(.primary)
            
            Spacer()
            
            Toggle("", isOn: .constant(isEnabled))
                .labelsHidden()
                .toggleStyle(.glass)
        }
        .padding()
        .background(Color(UIColor.systemGray6))
        .cornerRadius(12)
    }
}

#Preview {
    AdvancedFeaturesView()
        .environmentObject(SubscriptionManager.shared)
}