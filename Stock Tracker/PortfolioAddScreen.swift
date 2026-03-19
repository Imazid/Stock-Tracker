//
//  PortfolioAddScreen.swift
//  Stock Tracker
//
//  OB-070: Manual entry, CSV import, broker redirect.
//

import SwiftUI
import UniformTypeIdentifiers
import OSLog

struct PortfolioAddScreen: View {
    let onComplete: () -> Void
    let onSkip: () -> Void

    @EnvironmentObject var marketData: MarketData
    @State private var appeared = false
    @State private var expandedCard: AddMethod?
    @State private var holdings: [ManualHolding] = []

    // Manual entry fields
    @State private var manualSymbol = ""
    @State private var manualShares = ""
    @State private var manualCost = ""
    @State private var manualError: String?

    // CSV import
    @State private var showFilePicker = false
    @State private var csvResult: CSVImportResult?

    private enum AddMethod: String {
        case manual, csv, broker
    }

    struct ManualHolding: Identifiable {
        let id = UUID()
        let symbol: String
        let shares: Double
        let avgCost: Double
    }

    struct CSVImportResult {
        let imported: Int
        let errors: Int
        let message: String
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer().frame(height: 60)

                // Briefcase icon
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.green.opacity(0.32), Color.clear],
                                center: .center,
                                startRadius: 10,
                                endRadius: 64
                            )
                        )
                        .frame(width: 128, height: 128)

                    Image(systemName: "briefcase.fill")
                        .font(.system(size: 48, weight: .medium))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(red: 0.25, green: 0.88, blue: 0.50), Color.cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: .green.opacity(0.5), radius: 16)
                }
                .opacity(appeared ? 1 : 0)
                .scaleEffect(appeared ? 1 : 0.7)

                Spacer().frame(height: 28)

                // Headline
                VStack(spacing: 12) {
                    Text("Add your holdings")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text("See your real portfolio value.\nYou can always add more later.")
                        .font(.body)
                        .foregroundColor(.white.opacity(0.52))
                        .multilineTextAlignment(.center)
                        .lineSpacing(5)
                }
                .padding(.horizontal, 32)
                .opacity(appeared ? 1 : 0)

                Spacer().frame(height: 32)

                // Method cards
                VStack(spacing: 12) {
                    methodCard(
                        method: .manual,
                        icon: "plus.circle.fill",
                        color: .blue,
                        title: "Add manually",
                        subtitle: "Enter your stock positions one by one"
                    )

                    methodCard(
                        method: .csv,
                        icon: "doc.text.fill",
                        color: .orange,
                        title: "Import from CSV",
                        subtitle: "Upload a spreadsheet from your broker"
                    )

                    methodCard(
                        method: .broker,
                        icon: "building.columns.fill",
                        color: .purple,
                        title: "Connect your broker",
                        subtitle: "Automatically sync your holdings (read-only)"
                    )
                }
                .padding(.horizontal, 28)

                // Added holdings summary
                if !holdings.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Added (\(holdings.count))")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.5))

                        ForEach(holdings) { h in
                            HStack {
                                Text(h.symbol)
                                    .font(.subheadline.bold())
                                    .foregroundColor(.white)
                                Spacer()
                                Text("\(String(format: "%.2f", h.shares)) shares @ $\(String(format: "%.2f", h.avgCost))")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.5))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(10)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 20)
                }

                Spacer().frame(height: 32)

                // CTAs
                VStack(spacing: 14) {
                    OnboardingButton(title: "Continue") {
                        saveHoldings()
                        onComplete()
                    }

                    Button("I'll do this later") { onSkip() }
                        .font(.body)
                        .foregroundColor(.white.opacity(0.42))
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 60)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.commaSeparatedText],
            allowsMultipleSelection: false
        ) { result in
            handleCSVImport(result)
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.82).delay(0.10)) {
                appeared = true
            }
        }
    }

    // MARK: - Method card

    @ViewBuilder
    private func methodCard(method: AddMethod, icon: String, color: Color, title: String, subtitle: String) -> some View {
        VStack(spacing: 0) {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    expandedCard = expandedCard == method ? nil : method
                }
            } label: {
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(color.opacity(0.18))
                            .frame(width: 46, height: 46)
                        Image(systemName: icon)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(color)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.body.weight(.semibold))
                            .foregroundColor(.white)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.50))
                    }

                    Spacer()

                    Image(systemName: expandedCard == method ? "chevron.up" : "chevron.down")
                        .font(.caption.bold())
                        .foregroundColor(.white.opacity(0.35))
                }
                .padding(16)
            }
            .buttonStyle(.plain)

            if expandedCard == method {
                expandedContent(for: method)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.white.opacity(0.07))
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    @ViewBuilder
    private func expandedContent(for method: AddMethod) -> some View {
        switch method {
        case .manual:
            manualEntryForm
        case .csv:
            csvImportSection
        case .broker:
            brokerSection
        }
    }

    // MARK: - Manual entry

    @ViewBuilder
    private var manualEntryForm: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                TextField("Symbol", text: $manualSymbol)
                    .textFieldStyle(.plain)
                    .foregroundColor(.white)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(10)
                    .frame(maxWidth: 100)

                TextField("Shares", text: $manualShares)
                    .textFieldStyle(.plain)
                    .foregroundColor(.white)
                    .keyboardType(.decimalPad)
                    .padding(12)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(10)

                TextField("Avg cost", text: $manualCost)
                    .textFieldStyle(.plain)
                    .foregroundColor(.white)
                    .keyboardType(.decimalPad)
                    .padding(12)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(10)
            }

            if let error = manualError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Button {
                addManualHolding()
            } label: {
                Text("Add holding")
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.blue)
                    .cornerRadius(10)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - CSV

    @ViewBuilder
    private var csvImportSection: some View {
        VStack(spacing: 12) {
            Text("Expected columns: Symbol, Shares, Average Cost")
                .font(.caption)
                .foregroundColor(.white.opacity(0.50))

            Button {
                showFilePicker = true
            } label: {
                HStack {
                    Image(systemName: "folder.badge.plus")
                    Text("Choose CSV file")
                }
                .font(.subheadline.bold())
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.orange.opacity(0.3))
                .cornerRadius(10)
            }
            .buttonStyle(.plain)

            if let result = csvResult {
                Text(result.message)
                    .font(.caption)
                    .foregroundColor(result.errors > 0 ? .orange : .green)
            }
        }
    }

    // MARK: - Broker

    @ViewBuilder
    private var brokerSection: some View {
        VStack(spacing: 10) {
            Text("Connections are read-only. We can see your positions but can never place trades or move funds.")
                .font(.caption)
                .foregroundColor(.white.opacity(0.50))

            Text("Connect your broker in the Watchlist Setup step, or later in Settings.")
                .font(.caption)
                .foregroundColor(.white.opacity(0.40))
        }
    }

    // MARK: - Actions

    private func addManualHolding() {
        manualError = nil
        guard !manualSymbol.isEmpty else {
            manualError = "Enter a symbol"
            return
        }
        guard let shares = Double(manualShares), shares > 0 else {
            manualError = "Enter valid share count"
            return
        }
        guard let cost = Double(manualCost), cost > 0 else {
            manualError = "Enter valid average cost"
            return
        }

        let holding = ManualHolding(
            symbol: manualSymbol.uppercased(),
            shares: shares,
            avgCost: cost
        )
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            holdings.append(holding)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        // Reset fields
        manualSymbol = ""
        manualShares = ""
        manualCost = ""
    }

    private func handleCSVImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let rows = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
            var imported = 0
            var errors = 0

            for (index, row) in rows.enumerated() {
                if index == 0 && row.lowercased().contains("symbol") { continue } // Skip header
                let cols = row.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard cols.count >= 3,
                      !cols[0].isEmpty,
                      let shares = Double(cols[1]),
                      let cost = Double(cols[2])
                else {
                    errors += 1
                    continue
                }
                holdings.append(ManualHolding(symbol: cols[0].uppercased(), shares: shares, avgCost: cost))
                imported += 1
            }

            csvResult = CSVImportResult(
                imported: imported,
                errors: errors,
                message: errors > 0
                    ? "\(imported) of \(imported + errors) rows imported. \(errors) issues found."
                    : "\(imported) holdings imported"
            )
        } catch {
            csvResult = CSVImportResult(imported: 0, errors: 1, message: "Couldn't read this file.")
        }
    }

    private func saveHoldings() {
        let symbols = holdings.map(\.symbol)
        UserDefaults.standard.set(symbols, forKey: "onboarding_portfolio_symbols")

        let data = holdings.map { ["symbol": $0.symbol, "shares": $0.shares, "avgCost": $0.avgCost] as [String: Any] }
        if let encoded = try? JSONSerialization.data(withJSONObject: data) {
            UserDefaults.standard.set(encoded, forKey: "onboarding_portfolio_holdings")
        }
    }
}
