//
//  HoldingDetailView.swift
//  Stock Tracker
//

import SwiftUI
import Charts

struct HoldingDetailView: View {
    let holding: PortfolioHolding
    @EnvironmentObject var marketData: MarketData
    @EnvironmentObject var insightService: AIInsightService
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme

    @Environment(\.theme) var appTheme

    @State private var showAddTransaction = false
    @State private var showBreakdown = false
    @State private var holdingInsightText: String?
    @State private var holdingInsightLoading = false

    private var isPositive: Bool { holding.profitLoss >= 0 }

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        NavigationStack {
            ZStack {
                theme.background.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 28) {
                        // MARK: - Header
                        headerSection
                            .padding(.horizontal)
                            .padding(.top, 20)
                        
                        // MARK: - Price Chart
                        priceChartSection
                            .padding(.horizontal)

                        // MARK: - AI Holding Insight (Pro/Black only)
                        if SubscriptionManager.shared.currentTier != .free {
                            holdingInsightCard
                                .padding(.horizontal)
                        }

                        // MARK: - Holdings Summary
                        holdingsSummarySection
                            .padding(.horizontal)
                        
                        // MARK: - Performance Metrics
                        performanceMetricsSection
                            .padding(.horizontal)
                        
                        // MARK: - Transactions
                        transactionsSection
                            .padding(.horizontal)
                        
                        Spacer(minLength: 100)
                    }
                }
            }
            .navigationTitle(holding.asset.symbol)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(theme.primaryText)
                }
            }
            .overlay(alignment: .bottom) {
                addTransactionButton
                    .padding(.bottom, 40)
            }
            .sheet(isPresented: $showAddTransaction) {
                AddTransactionSheet(holding: holding)
            }
        }
    }
    
    // MARK: - Header Section
    private var headerSection: some View {
        let theme = Theme(colorScheme: colorScheme)
        let plColor: Color = isPositive ? appTheme.positiveColor : appTheme.negativeColor

        return ZStack(alignment: .top) {
            LinearGradient(
                colors: [plColor.opacity(0.07), theme.background.opacity(0)],
                startPoint: .top, endPoint: .bottom
            )

            VStack(spacing: 20) {
                // Colored symbol badge + name
                VStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(
                                colors: [plColor.opacity(0.22), plColor.opacity(0.06)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ))
                            .frame(width: 72, height: 72)
                        Text(String(holding.asset.symbol.prefix(2)))
                            .font(.title2.weight(.bold))
                            .foregroundColor(plColor)
                    }
                    Text(holding.asset.symbol)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(theme.primaryText)
                    Text(holding.asset.name)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                // Market Value
                VStack(spacing: 4) {
                    Text("Market Value")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text(holding.currentValue.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(theme.primaryText)
                        .contentTransition(.numericText())
                }

                // P&L pill
                HStack(spacing: 6) {
                    Image(systemName: isPositive ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 12, weight: .bold))
                    Text(holding.profitLoss.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    Text("(\(isPositive ? "+" : "")\(String(format: "%.2f", holding.profitLossPercent))%)")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundColor(plColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(plColor.opacity(0.12))
                .clipShape(Capsule())
            }
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
    }
    
    // MARK: - AI Holding Insight

    private var holdingInsightCard: some View {
        let tier = SubscriptionManager.shared.currentTier
        let isLocked = tier == .free
        let cacheKey = "holding_insight_\(holding.asset.symbol)"
        let cachedText: String? = insightService.cached(cacheKey)?.text ?? holdingInsightText
        return AIInsightCard(
            title: "Holding Insight",
            icon: "lightbulb.fill",
            insightText: cachedText,
            isLoading: holdingInsightLoading,
            isLocked: isLocked,
            tier: tier,
            onGenerate: { await loadHoldingInsight() },
            onRegenerate: { await loadHoldingInsight(force: true) }
        )
    }

    private func loadHoldingInsight(force: Bool = false) async {
        holdingInsightLoading = true
        defer { holdingInsightLoading = false }

        let tier = SubscriptionManager.shared.currentTier
        let cacheKey = "holding_insight_\(holding.asset.symbol)"

        let plSign = holding.profitLoss >= 0 ? "+" : ""
        var context = "\(holding.asset.name) (\(holding.asset.symbol)): \(String(format: "%.2f", holding.shares)) shares, avg cost $\(String(format: "%.2f", holding.avgCost)), current $\(String(format: "%.2f", holding.asset.price))."
        context += " P&L: \(plSign)$\(String(format: "%.2f", holding.profitLoss)) (\(plSign)\(String(format: "%.1f", holding.profitLossPercent))%)."
        context += " Day change: \(String(format: "%+.2f%%", holding.asset.changePercent))."

        let systemPrompt = "You are a portfolio analyst. Give a brief 2-3 sentence insight about this holding position. Comment on the cost basis vs current price, and whether the position sizing looks reasonable."
        let userPrompt = context + " Provide a quick insight on this position."

        let result: String?
        if force {
            result = await insightService.regenerateInsight(
                key: cacheKey, type: .holdingInsight,
                systemPrompt: systemPrompt, userPrompt: userPrompt,
                tier: tier, ttl: Constants.AI.holdingCacheTTL
            )
        } else {
            result = await insightService.generateInsight(
                key: cacheKey, type: .holdingInsight,
                systemPrompt: systemPrompt, userPrompt: userPrompt,
                tier: tier, ttl: Constants.AI.holdingCacheTTL
            )
        }
        if let text = result { holdingInsightText = text }
    }

    // MARK: - Price Chart Section
    private var priceChartSection: some View {
        let theme = Theme(colorScheme: colorScheme)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: 28, height: 28)
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.blue)
                }
                Text("Price History")
                    .font(.headline.weight(.semibold))
            }

            RoundedRectangle(cornerRadius: 16)
                .fill(theme.glassBackground)
                .frame(height: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(theme.glassBorder, lineWidth: 1)
                )
                .overlay(
                    VStack(spacing: 8) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.title2)
                            .foregroundColor(.secondary.opacity(0.3))
                        Text("Tap to load chart")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                )
        }
    }
    
    // MARK: - Holdings Summary
    private var holdingsSummarySection: some View {
        let theme = Theme(colorScheme: colorScheme)
        return VStack(spacing: 14) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: 28, height: 28)
                    Image(systemName: "list.bullet.clipboard")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.blue)
                }
                Text("Holdings Summary")
                    .font(.title3.bold())
                Spacer()
            }

            VStack(spacing: 0) {
                SummaryRow(
                    label: "Shares Owned",
                    value: String(format: "%.2f", holding.shares),
                    showDivider: true
                )
                SummaryRow(
                    label: "Average Cost",
                    value: holding.avgCost.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates),
                    showDivider: true
                )
                SummaryRow(
                    label: "Current Price",
                    value: holding.asset.price.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates),
                    showDivider: true
                )
                SummaryRow(
                    label: "Total Cost",
                    value: holding.costBasis.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates),
                    showDivider: false
                )
            }
            .padding(16)
            .background(theme.glassBackground)
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(theme.glassBorder, lineWidth: 1)
            )
        }
    }
    
    // MARK: - Performance Metrics
    private var performanceMetricsSection: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.purple.opacity(0.15))
                        .frame(width: 28, height: 28)
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.purple)
                }
                Text("Performance")
                    .font(.title3.bold())
                Spacer()
            }

            HStack(spacing: 12) {
                MetricCard(
                    title: "Day Change",
                    value: holding.asset.changePercent,
                    isPercentage: true
                )

                MetricCard(
                    title: "Total Return",
                    value: holding.profitLossPercent,
                    isPercentage: true
                )
            }
        }
    }
    
    // MARK: - Transactions Section
    private var transactionsSection: some View {
        let theme = Theme(colorScheme: colorScheme)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.15))
                        .frame(width: 28, height: 28)
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.orange)
                }
                Text("Transactions")
                    .font(.title3.bold())

                Spacer()

                if !holding.transactions.isEmpty {
                    Text("\(holding.transactions.count)")
                        .font(.caption.weight(.bold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(theme.glassBackground)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(theme.glassBorder, lineWidth: 1))
                }
            }

            if holding.transactions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.4))

                    Text("No transactions yet")
                        .font(.body.weight(.medium))
                        .foregroundColor(.secondary)

                    Text("Add your first transaction to track your history")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .background(theme.glassBackground)
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(theme.glassBorder, lineWidth: 1)
                )
            } else {
                VStack(spacing: 8) {
                    ForEach(holding.transactions.sorted(by: { $0.date > $1.date })) { transaction in
                        TransactionRowCompact(transaction: transaction)
                    }
                }
            }
        }
    }
    
    // MARK: - Add Transaction Button
    private var addTransactionButton: some View {
        Button {
            showAddTransaction = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.body.weight(.semibold))
                Text("Add Transaction")
                    .font(.headline)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                LinearGradient(
                    colors: [appTheme.accentColor, appTheme.accentColor.opacity(0.75)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .cornerRadius(16)
            .shadow(color: appTheme.accentColor.opacity(colorScheme == .dark ? 0.4 : 0.04), radius: 12, y: 6)
        }
        .padding(.horizontal)
    }
}

// MARK: - Summary Row
struct SummaryRow: View {
    let label: String
    let value: String
    let showDivider: Bool
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(.body)
                    .foregroundColor(theme.secondaryText)

                Spacer()

                Text(value)
                    .font(.body.bold())
                    .foregroundColor(theme.primaryText)
            }
            .padding(.vertical, 12)

            if showDivider {
                Divider()
                    .background(theme.separator)
            }
        }
    }
}

// MARK: - Metric Card
struct MetricCard: View {
    let title: String
    let value: Double
    let isPercentage: Bool
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme

    private var isPositive: Bool { value >= 0 }

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        let valueColor: Color = isPositive ? appTheme.positiveColor : appTheme.negativeColor
        VStack(spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundColor(.secondary)

            Text(isPercentage ? "\(isPositive ? "+" : "")\(String(format: "%.2f", value))%" : String(format: "%.2f", value))
                .font(.title3.bold())
                .monospacedDigit()
                .foregroundColor(valueColor)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(theme.glassBackground)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(valueColor.opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - Compact Transaction Row
struct TransactionRowCompact: View {
    let transaction: Transaction
    @EnvironmentObject var marketData: MarketData
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        let isBuy = transaction.type == .buy
        let badgeColor: Color = isBuy ? appTheme.positiveColor : appTheme.negativeColor
        HStack(spacing: 12) {
            // Type Badge
            HStack(spacing: 4) {
                Image(systemName: isBuy ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                    .font(.caption)
                Text(transaction.type.rawValue.capitalized)
                    .font(.caption.weight(.bold))
            }
            .foregroundColor(badgeColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(badgeColor.opacity(0.12))
            .clipShape(Capsule())

            // Details
            VStack(alignment: .leading, spacing: 3) {
                Text("\(String(format: "%.4g", transaction.shares)) shares")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)

                Text(transaction.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Value
            VStack(alignment: .trailing, spacing: 3) {
                Text(transaction.pricePerShare.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundColor(.primary)

                Text(transaction.totalValue.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .background(theme.glassBackground)
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(theme.glassBorder, lineWidth: 1)
        )
    }
}

// MARK: - Add Transaction Sheet
struct AddTransactionSheet: View {
    let holding: PortfolioHolding
    @EnvironmentObject var marketData: MarketData
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.theme) var appTheme

    @State private var transactionType: TransactionType = .buy
    @State private var sharesText = ""
    @State private var priceText = ""
    @State private var transactionDate = Date()
    @FocusState private var focusedField: TxField?

    enum TxField { case shares, price }

    private var shares: Double? {
        Double(sharesText.replacingOccurrences(of: ",", with: "."))
    }
    private var price: Double? {
        Double(priceText.replacingOccurrences(of: ",", with: "."))
    }
    private var totalValue: Double? {
        guard let s = shares, let p = price else { return nil }
        return s * p
    }
    private var isValid: Bool {
        (shares ?? 0) > 0 && (price ?? 0) > 0
    }
    private var isBuy: Bool { transactionType == .buy }
    private var accentColor: Color { isBuy ? appTheme.positiveColor : appTheme.negativeColor }

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        NavigationStack {
            ZStack {
                theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        txAssetHeader(theme: theme)
                        txTypePicker(theme: theme)
                        txInputFields(theme: theme)
                        txDateRow(theme: theme)
                        if totalValue != nil {
                            txSummary(theme: theme)
                        }
                        txAddButton
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 48)
                }
            }
            .navigationTitle("Add Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.secondary)
                }
            }
            .onAppear {
                priceText = String(format: "%.2f", holding.asset.price)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    focusedField = .shares
                }
            }
        }
    }

    // MARK: - Asset Header

    private func txAssetHeader(theme: Theme) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [accentColor, accentColor.opacity(0.5)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 48, height: 48)
                Image(systemName: isBuy ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(holding.asset.symbol)
                    .font(.title3.bold())
                    .foregroundColor(.primary)
                Text(holding.asset.name)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(String(format: "%.4g", holding.shares))
                    .font(.title3.bold())
                    .foregroundColor(.primary)
                Text("shares held")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .background(accentColor.opacity(0.08))
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(accentColor.opacity(0.15), lineWidth: 1))
        .animation(.easeInOut(duration: 0.2), value: isBuy)
    }

    // MARK: - Buy/Sell Picker

    private func txTypePicker(theme: Theme) -> some View {
        HStack(spacing: 0) {
            txTypeButton(.buy, label: "Buy", icon: "arrow.down.circle.fill", theme: theme)
            txTypeButton(.sell, label: "Sell", icon: "arrow.up.circle.fill", theme: theme)
        }
        .padding(4)
        .background(theme.glassBackground)
        .cornerRadius(14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.separator, lineWidth: 1))
    }

    private func txTypeButton(_ type: TransactionType, label: String, icon: String, theme: Theme) -> some View {
        let isSelected = transactionType == type
        let color: Color = type == .buy ? appTheme.positiveColor : appTheme.negativeColor
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                transactionType = type
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                Text(label)
                    .font(.subheadline.weight(.bold))
            }
            .foregroundColor(isSelected ? .white : color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(isSelected ? color : Color.clear)
            .cornerRadius(10)
        }
    }

    // MARK: - Input Fields

    private func txInputFields(theme: Theme) -> some View {
        VStack(spacing: 14) {
            txInputRow(
                label: "Number of Shares",
                icon: "number",
                placeholder: "0.00",
                text: $sharesText,
                field: .shares,
                theme: theme
            )

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Price per Share")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                        .padding(.leading, 2)

                    Spacer()

                    Button {
                        priceText = String(format: "%.2f", holding.asset.price)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Text("Use Market Price")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(accentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(accentColor.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }

                let isFocused = focusedField == .price
                HStack(spacing: 10) {
                    Image(systemName: "dollarsign")
                        .foregroundColor(isFocused ? accentColor : .secondary)
                        .frame(width: 20)
                        .animation(.easeInOut(duration: 0.15), value: isFocused)

                    TextField("0.00", text: $priceText)
                        .keyboardType(.decimalPad)
                        .focused($focusedField, equals: .price)
                        .font(.title3.weight(.medium))
                }
                .padding(16)
                .background(isFocused ? accentColor.opacity(0.06) : theme.glassBackground)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(isFocused ? accentColor.opacity(0.5) : theme.separator, lineWidth: 1.5)
                )
                .animation(.easeInOut(duration: 0.15), value: isFocused)
            }
        }
    }

    private func txInputRow(
        label: String,
        icon: String,
        placeholder: String,
        text: Binding<String>,
        field: TxField,
        theme: Theme
    ) -> some View {
        let isFocused = focusedField == field
        return VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .padding(.leading, 2)

            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundColor(isFocused ? accentColor : .secondary)
                    .frame(width: 20)
                    .animation(.easeInOut(duration: 0.15), value: isFocused)

                TextField(placeholder, text: text)
                    .keyboardType(.decimalPad)
                    .focused($focusedField, equals: field)
                    .font(.title3.weight(.medium))
            }
            .padding(16)
            .background(isFocused ? accentColor.opacity(0.06) : theme.glassBackground)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isFocused ? accentColor.opacity(0.5) : theme.separator, lineWidth: 1.5)
            )
            .animation(.easeInOut(duration: 0.15), value: isFocused)
        }
    }

    // MARK: - Date Row

    private func txDateRow(theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Transaction Date")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .padding(.leading, 2)

            HStack(spacing: 10) {
                Image(systemName: "calendar")
                    .foregroundColor(accentColor)
                    .frame(width: 20)

                DatePicker("", selection: $transactionDate, displayedComponents: .date)
                    .labelsHidden()

                Spacer()
            }
            .padding(12)
            .background(theme.glassBackground)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(theme.separator, lineWidth: 1)
            )
        }
    }

    // MARK: - Summary

    private func txSummary(theme: Theme) -> some View {
        VStack(spacing: 14) {
            Label("Transaction Summary", systemImage: "chart.bar.doc.horizontal")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 10) {
                txSummaryRow("Shares", value: shares.map { String(format: "%.4g", $0) } ?? "-")
                txSummaryRow("Price per Share", value: price.map {
                    $0.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates)
                } ?? "-")

                Divider().opacity(0.6)

                txSummaryRow(
                    "Total Value",
                    value: totalValue.map {
                        $0.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates)
                    } ?? "-",
                    bold: true
                )

                // Show impact on position
                if let s = shares, let p = price {
                    let newShares = isBuy ? holding.shares + s : holding.shares - s
                    let newAvgCost: Double = {
                        if isBuy {
                            let totalCost = (holding.shares * holding.avgCost) + (s * p)
                            return newShares > 0 ? totalCost / newShares : 0
                        }
                        return holding.avgCost
                    }()

                    Divider().opacity(0.6)

                    HStack {
                        Text("New Position")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    txSummaryRow("Shares After", value: String(format: "%.4g", newShares))
                    if isBuy {
                        txSummaryRow("Avg Cost After", value: newAvgCost.formattedPrice(in: marketData.preferredCurrency, rates: marketData.exchangeRates))
                    }
                }
            }
            .padding(16)
            .background(theme.glassBackground)
            .cornerRadius(14)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.separator, lineWidth: 0.5))
        }
    }

    private func txSummaryRow(
        _ label: String,
        value: String,
        bold: Bool = false
    ) -> some View {
        HStack {
            Text(label)
                .font(bold ? .subheadline.weight(.semibold) : .subheadline)
                .foregroundColor(bold ? .primary : .secondary)
            Spacer()
            Text(value)
                .font(bold ? .subheadline.weight(.bold) : .subheadline.weight(.medium))
                .foregroundColor(bold ? .primary : .secondary)
                .monospacedDigit()
        }
    }

    // MARK: - Add Button

    private var txAddButton: some View {
        Button {
            guard let s = shares, let p = price, s > 0, p > 0 else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            addTransaction()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isBuy ? "plus.circle.fill" : "minus.circle.fill")
                    .font(.title3)
                Text(isBuy ? "Add Buy Transaction" : "Add Sell Transaction")
                    .font(.headline)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                isValid
                    ? LinearGradient(colors: [accentColor, accentColor.opacity(0.7)],
                                     startPoint: .leading, endPoint: .trailing)
                    : LinearGradient(colors: [Color.gray.opacity(0.35), Color.gray.opacity(0.25)],
                                     startPoint: .leading, endPoint: .trailing)
            )
            .cornerRadius(16)
            .shadow(color: isValid ? accentColor.opacity(colorScheme == .dark ? 0.35 : 0.10) : .clear, radius: 12, y: 6)
        }
        .disabled(!isValid)
        .animation(.easeInOut(duration: 0.2), value: isValid)
        .animation(.easeInOut(duration: 0.2), value: isBuy)
    }

    // MARK: - Add Transaction Logic

    private func addTransaction() {
        guard let shares = shares, let price = price else { return }

        let transaction = Transaction(
            date: transactionDate,
            shares: shares,
            pricePerShare: price,
            type: transactionType
        )

        if let index = marketData.portfolio.firstIndex(where: { $0.id == holding.id }) {
            var updatedHolding = marketData.portfolio[index]
            updatedHolding.transactions.append(transaction)

            if transactionType == .buy {
                let totalCost = (updatedHolding.shares * updatedHolding.avgCost) + (shares * price)
                updatedHolding.shares += shares
                updatedHolding.avgCost = totalCost / updatedHolding.shares
            } else {
                updatedHolding.shares -= shares
            }

            marketData.portfolio[index] = updatedHolding
            marketData.saveToDisk()
            if SyncManager.shared.isSignedIn { Task { await SyncManager.shared.scheduleBackgroundSync() } }
        }

        dismiss()
    }
}

#Preview {
    HoldingDetailView(holding: PortfolioHolding(
        asset: Asset(symbol: "AAPL", name: "Apple Inc.", price: 178.50, change: 2.30, changePercent: 1.30, volume: 50000000, kind: .stock, exchange: "NASDAQ"),
        shares: 10.0,
        avgCost: 170.00,
        transactions: []
    ))
    .environmentObject(MarketData())
}
