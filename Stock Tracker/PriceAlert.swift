//
//  PriceAlert.swift
//  Stock Tracker
//
//  Created by Ihtisham Mazid on 30/11/2025.
//


import Foundation
import UserNotifications
import Combine 

// MARK: - Price Alert Model
struct PriceAlert: Identifiable, Codable {
    let id: UUID
    let symbol: String
    let assetName: String
    let targetPrice: Double
    let condition: AlertCondition
    let isActive: Bool
    let createdAt: Date
    
    init(id: UUID = UUID(), symbol: String, assetName: String, targetPrice: Double, condition: AlertCondition, isActive: Bool = true, createdAt: Date = Date()) {
        self.id = id
        self.symbol = symbol
        self.assetName = assetName
        self.targetPrice = targetPrice
        self.condition = condition
        self.isActive = isActive
        self.createdAt = createdAt
    }
    
    func shouldTrigger(currentPrice: Double) -> Bool {
        guard isActive else { return false }
        
        switch condition {
        case .above:
            return currentPrice >= targetPrice
        case .below:
            return currentPrice <= targetPrice
        }
    }
}

enum AlertCondition: String, Codable, CaseIterable {
    case above = "Above"
    case below = "Below"
    
    var symbol: String {
        switch self {
        case .above: return "↑"
        case .below: return "↓"
        }
    }
}

// MARK: - Alert Manager
@MainActor
class PriceAlertManager: ObservableObject {
    @Published var alerts: [PriceAlert] = []
    
    private let alertsKey = "price_alerts"
    
    init() {
        loadAlerts()
        requestNotificationPermission()
    }
    
    func addAlert(_ alert: PriceAlert) {
        alerts.append(alert)
        saveAlerts()
    }
    
    func removeAlert(_ alert: PriceAlert) {
        alerts.removeAll { $0.id == alert.id }
        saveAlerts()
    }
    
    func toggleAlert(_ alert: PriceAlert) {
        if let index = alerts.firstIndex(where: { $0.id == alert.id }) {
            alerts[index] = PriceAlert(
                id: alert.id,
                symbol: alert.symbol,
                assetName: alert.assetName,
                targetPrice: alert.targetPrice,
                condition: alert.condition,
                isActive: !alert.isActive,
                createdAt: alert.createdAt
            )
            saveAlerts()
        }
    }
    
    func checkAlerts(for assets: [Asset]) {
        for asset in assets {
            let triggeredAlerts = alerts.filter { alert in
                alert.symbol == asset.symbol && alert.shouldTrigger(currentPrice: asset.price)
            }
            
            for alert in triggeredAlerts {
                sendNotification(for: alert, currentPrice: asset.price)
                removeAlert(alert) // Remove after triggering
            }
        }
    }
    
    private func sendNotification(for alert: PriceAlert, currentPrice: Double) {
        let content = UNMutableNotificationContent()
        content.title = "Price Alert: \(alert.symbol)"
        content.body = "\(alert.assetName) is now $\(String(format: "%.2f", currentPrice)) (\(alert.condition.rawValue) $\(String(format: "%.2f", alert.targetPrice)))"
        content.sound = .default
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: alert.id.uuidString, content: content, trigger: trigger)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error sending notification: \(error)")
            }
        }
    }
    
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("Notification permission error: \(error)")
            }
        }
    }
    
    private func saveAlerts() {
        if let encoded = try? JSONEncoder().encode(alerts) {
            UserDefaults.standard.set(encoded, forKey: alertsKey)
        }
    }
    
    private func loadAlerts() {
        if let data = UserDefaults.standard.data(forKey: alertsKey),
           let decoded = try? JSONDecoder().decode([PriceAlert].self, from: data) {
            alerts = decoded
        }
    }
}

// MARK: - Alert Creation Sheet
import SwiftUI

struct AddPriceAlertSheet: View {
    @EnvironmentObject var alertManager: PriceAlertManager
    @Environment(\.dismiss) var dismiss
    
    let asset: Asset
    @State private var targetPriceText = ""
    @State private var selectedCondition: AlertCondition = .above
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                
                Form {
                    Section {
                        HStack {
                            ZStack {
                                Circle()
                                    .fill(Color(red: 0.2, green: 0.3, blue: 0.5))
                                    .frame(width: 40, height: 40)
                                Text(String(asset.symbol.prefix(1)))
                                    .font(.headline)
                                    .foregroundColor(.white)
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(asset.symbol)
                                    .font(.headline)
                                    .foregroundColor(.white)
                                Text(asset.name)
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            
                            Spacer()
                            
                            Text("$\(asset.price, specifier: "%.2f")")
                                .font(.headline)
                                .foregroundColor(.white)
                        }
                    }
                    
                    Section(header: Text("Alert Condition")) {
                        Picker("Condition", selection: $selectedCondition) {
                            ForEach(AlertCondition.allCases, id: \.self) { condition in
                                HStack {
                                    Text(condition.symbol)
                                    Text(condition.rawValue)
                                }
                                .tag(condition)
                            }
                        }
                        .pickerStyle(.segmented)
                        
                        HStack {
                            Text("Price")
                            Spacer()
                            TextField("0.00", text: $targetPriceText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                            Text("USD")
                                .foregroundColor(.gray)
                        }
                    }
                    
                    Section {
                        Text("You'll receive a notification when \(asset.symbol) reaches \(selectedCondition == .above ? "above" : "below") your target price.")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Set Price Alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        guard let targetPrice = Double(targetPriceText) else { return }
                        let alert = PriceAlert(
                            symbol: asset.symbol,
                            assetName: asset.name,
                            targetPrice: targetPrice,
                            condition: selectedCondition
                        )
                        alertManager.addAlert(alert)
                        dismiss()
                    }
                    .disabled(targetPriceText.isEmpty)
                }
            }
        }
    }
}

// MARK: - Alerts List View
struct PriceAlertsView: View {
    @EnvironmentObject var alertManager: PriceAlertManager
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.black,
                        Color(red: 15/255, green: 23/255, blue: 42/255)
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                if alertManager.alerts.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "bell.badge")
                            .font(.system(size: 60))
                            .foregroundColor(.gray.opacity(0.5))
                        
                        Text("No Price Alerts")
                            .font(.headline)
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
    }
}

struct AlertRow: View {
    @EnvironmentObject var alertManager: PriceAlertManager
    let alert: PriceAlert
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(alert.isActive ? Color.blue.opacity(0.2) : Color.gray.opacity(0.2))
                    .frame(width: 40, height: 40)
                Text(String(alert.symbol.prefix(1)))
                    .font(.headline)
                    .foregroundColor(alert.isActive ? .blue : .gray)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(alert.symbol)
                    .font(.headline)
                    .foregroundColor(.white)
                Text("\(alert.condition.symbol) $\(alert.targetPrice, specifier: "%.2f")")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            
            Spacer()
            
            Toggle("", isOn: Binding(
                get: { alert.isActive },
                set: { _ in alertManager.toggleAlert(alert) }
            ))
            .labelsHidden()
        }
        .padding(.vertical, 8)
    }
}
