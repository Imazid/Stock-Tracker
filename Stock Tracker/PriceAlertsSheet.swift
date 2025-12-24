//
//  PriceAlertsSheet.swift
//  Stock Tracker
//
//  Created by Ihtisham Mazid on 18/12/2025.
//


//
//  PriceAlertsSheet.swift
//  Stock Tracker
//

import SwiftUI

struct PriceAlertsSheet: View {
    @EnvironmentObject var marketData: MarketData
    @EnvironmentObject var alertManager: PriceAlertManager
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                
                if alertManager.alerts.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "bell.slash")
                            .font(.system(size: 60))
                            .foregroundColor(.gray)
                        
                        Text("No Price Alerts")
                            .font(.title2.bold())
                            .foregroundColor(.white)
                        
                        Text("Set alerts to get notified when prices hit your targets")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                } else {
                    List {
                        ForEach(alertManager.alerts) { alert in
                            AlertRow(alert: alert)
                        }
                        .onDelete { indexSet in
                            indexSet.forEach { index in
                                alertManager.removeAlert(alertManager.alerts[index])
                            }
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Price Alerts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// Reuse your existing AlertRow from PriceAlert.swift
//struct AlertRow: View {
//    @EnvironmentObject var alertManager: PriceAlertManager
//    let alert: PriceAlert
//    
//    var body: some View {
//        HStack(spacing: 12) {
//            ZStack {
//                Circle()
//                    .fill(alert.isActive ? Color.blue.opacity(0.2) : Color.gray.opacity(0.2))
//                    .frame(width: 40, height: 40)
//                Text(String(alert.symbol.prefix(1)))
//                    .font(.headline)
//                    .foregroundColor(alert.isActive ? .blue : .gray)
//            }
//            
//            VStack(alignment: .leading, spacing: 4) {
//                Text(alert.symbol)
//                    .font(.headline)
//                    .foregroundColor(.white)
//                Text("\(alert.condition.symbol) $\(alert.targetPrice, specifier: "%.2f")")
//                    .font(.caption)
//                    .foregroundColor(.gray)
//            }
//            
//            Spacer()
//            
//            Toggle("", isOn: Binding(
//                get: { alert.isActive },
//                set: { _ in alertManager.toggleAlert(alert) }
//            ))
//            .labelsHidden()
//        }
//        .padding(.vertical, 8)
//    }
//}

#Preview {
    PriceAlertsSheet()
        .environmentObject(MarketData())
        .environmentObject(PriceAlertManager())
        .preferredColorScheme(.dark)
}
