//
//  FinancialsTabView.swift
//  Stock Tracker
//
//  Financial statements tab — Income Statement (real FMP data), Balance Sheet, Cash Flow.
//

import SwiftUI

struct FinancialsTabView: View {
    let insight: StockInsight?
    let isLoading: Bool
    let stock: DetailedStock          // carries real FMP incomeStatements

    @State private var segment: FinancialSegment = .income

    enum FinancialSegment: String, CaseIterable {
        case income   = "Income"
        case balance  = "Balance Sheet"
        case cashFlow = "Cash Flow"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Segment pills
            segmentPicker
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 16)

            // Content
            switch segment {
            case .income:    incomeView
            case .balance:   insightTable(rows: insight?.financials.balanceAnnual)
            case .cashFlow:  insightTable(rows: insight?.financials.cashFlowAnnual)
            }
        }
    }

    // MARK: - Segment Picker

    private var segmentPicker: some View {
        HStack(spacing: 0) {
            ForEach(FinancialSegment.allCases, id: \.self) { seg in
                let isSelected = segment == seg
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { segment = seg }
                } label: {
                    Text(seg.rawValue)
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            isSelected
                                ? Color(.secondarySystemBackground)
                                : Color.clear
                        )
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    // MARK: - Income (real FMP data)

    @ViewBuilder
    private var incomeView: some View {
        if stock.incomeStatements.isEmpty {
            if isLoading {
                loadingPlaceholder
            } else {
                placeholderView
            }
        } else {
            incomeCard
        }
    }

    private var incomeCard: some View {
        let stmts = Array(stock.incomeStatements.prefix(4))

        // Extract period year labels (FMP dates are "YYYY-MM-DD")
        let periodLabels: [String] = stmts.compactMap {
            $0.date.flatMap { String($0.prefix(4)) }
        }

        let metrics: [IncomeMetric] = [
            IncomeMetric(
                label: "Revenue",
                icon: "chart.bar.fill",
                values: stmts.map { $0.revenue },
                isEPS: false
            ),
            IncomeMetric(
                label: "Gross Profit",
                icon: "checkmark.seal.fill",
                values: stmts.map { $0.grossProfit },
                isEPS: false
            ),
            IncomeMetric(
                label: "Operating Income",
                icon: "gearshape.fill",
                values: stmts.map { $0.operatingIncome },
                isEPS: false
            ),
            IncomeMetric(
                label: "Net Income",
                icon: "dollarsign.circle.fill",
                values: stmts.map { $0.netIncome },
                isEPS: false
            ),
            IncomeMetric(
                label: "EBITDA",
                icon: "waveform.path.ecg",
                values: stmts.map { $0.ebitda },
                isEPS: false
            ),
            IncomeMetric(
                label: "EPS (Diluted)",
                icon: "person.fill",
                values: stmts.map { $0.epsDiluted ?? $0.eps },
                isEPS: true
            ),
        ]

        return VStack(spacing: 0) {
            // Period header strip
            if !periodLabels.isEmpty {
                HStack {
                    Text("Annual · FMP")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    HStack(spacing: 16) {
                        ForEach(periodLabels.prefix(3), id: \.self) { label in
                            Text(label)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(.systemBackground))

                Divider()
            }

            ForEach(Array(metrics.enumerated()), id: \.offset) { idx, metric in
                FMPMetricRow(metric: metric, periods: periodLabels)
                if idx < metrics.count - 1 {
                    Divider().padding(.leading, 16)
                }
            }
        }
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    // MARK: - Insight-based table (Balance / Cash Flow)

    @ViewBuilder
    private func insightTable(rows: [FinancialRow]?) -> some View {
        if isLoading && insight == nil {
            loadingPlaceholder
        } else if let rows = rows, !rows.isEmpty {
            redesignedTable(rows: rows)
        } else {
            placeholderView
        }
    }

    private func redesignedTable(rows: [FinancialRow]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                RedesignedFinancialRow(row: row)
                if idx < rows.count - 1 && !row.isHeader {
                    Divider().padding(.leading, 16)
                }
            }
        }
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    // MARK: - Loading / Placeholder

    private var loadingPlaceholder: some View {
        VStack(spacing: 0) {
            ForEach(0..<5, id: \.self) { _ in
                HStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.systemGray5))
                        .frame(maxWidth: .infinity, minHeight: 14, maxHeight: 14)
                    Spacer(minLength: 40)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.systemGray5))
                        .frame(width: 64, height: 14)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .redacted(reason: .placeholder)
                Divider().padding(.leading, 16)
            }
        }
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private var placeholderView: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.title)
                .foregroundColor(.secondary.opacity(0.5))
            Text("Financial data unavailable")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(48)
    }
}

// MARK: - Income Metric Model

private struct IncomeMetric {
    let label: String
    let icon: String
    let values: [Double?]  // newest first
    let isEPS: Bool

    var current: Double? { values.first ?? nil }
    var prior: Double?   { values.count > 1 ? values[1] : nil }

    var yoyChange: Double? {
        guard let c = current, let p = prior, p != 0 else { return nil }
        return (c - p) / abs(p)
    }
}

// MARK: - FMP Metric Row

private struct FMPMetricRow: View {
    let metric: IncomeMetric
    let periods: [String]

    var body: some View {
        HStack(spacing: 12) {
            // Icon + label
            VStack(alignment: .leading, spacing: 3) {
                Text(metric.label)
                    .font(.subheadline)
                    .foregroundColor(.primary)

                // YoY change badge
                if let yoy = metric.yoyChange {
                    HStack(spacing: 3) {
                        Image(systemName: yoy >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 9, weight: .bold))
                        Text(String(format: "%+.1f%%", yoy * 100))
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundColor(yoy >= 0 ? .green : .red)
                }
            }

            Spacer()

            // Values for up to 3 periods (newest = primary, others = secondary)
            HStack(spacing: 0) {
                ForEach(metric.values.prefix(3).indices, id: \.self) { i in
                    let val = metric.values[i]
                    Text(formattedValue(val))
                        .font(i == 0
                              ? .subheadline.weight(.semibold)
                              : .caption)
                        .foregroundColor(i == 0 ? valueColor(val) : .secondary)
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func formattedValue(_ val: Double?) -> String {
        guard let val else { return "—" }
        if metric.isEPS {
            return String(format: "$%.2f", val)
        }
        return val.compactFormatted()
    }

    private func valueColor(_ val: Double?) -> Color {
        guard let val else { return .secondary }
        return val < 0 ? .red : .primary
    }
}

// MARK: - Redesigned Financial Row (Balance / Cash Flow)

struct RedesignedFinancialRow: View {
    let row: FinancialRow

    var body: some View {
        if row.isHeader {
            // Section header
            Text(row.metric)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)
                .background(Color(.systemBackground))
        } else {
            HStack(spacing: 0) {
                Text(row.metric)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Show up to 3 period values
                ForEach(row.values.prefix(3).indices, id: \.self) { i in
                    let val = row.values[i]
                    Text(val.map { $0.compactFormatted() } ?? "—")
                        .font(i == 0 ? .subheadline.weight(.semibold) : .caption)
                        .foregroundColor(
                            val == nil ? .secondary
                            : val! < 0 ? .red
                            : i == 0 ? .primary : .secondary
                        )
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
    }
}
