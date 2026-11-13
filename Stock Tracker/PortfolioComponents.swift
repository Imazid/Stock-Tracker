//
//  PortfolioComponents.swift
//  Stock Tracker
//
//  Shared pieces for the Portfolio tab: money/quantity formatting, the holding
//  row, a 44pt segmented bar, ledger rows and the allocation palette.
//
//  Money invariant (see FXRates): every stored price/cost is USD. Screens show
//  the person's display currency via `MarketData.formatPrice`; forms take input
//  in the asset's own trading currency (A$ for ASX, US$ for US + crypto).
//

import SwiftUI

// MARK: - Formatting

extension MarketData {
    /// The last quote failed, or none has arrived yet.
    func hasNoLivePrice(_ asset: Asset) -> Bool {
        quoteFailures.contains(asset.symbol) || asset.looksUnpriced
    }

    /// "+$12.30" / "−$4.10" in the display currency.
    func signedMoney(_ value: Double) -> String {
        (value >= 0 ? "+" : "−") + formatPrice(abs(value))
    }
}

/// Quantity with up to 8 decimals and grouping ("1,250", "0.0512").
func formatQuantity(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...8)))
}

func formatPercent(_ value: Double, signed: Bool = false) -> String {
    let body = String(format: "%.2f%%", abs(value))
    guard signed else { return String(format: "%.1f%%", value) }
    return (value >= 0 ? "+" : "−") + body
}

extension Asset {
    var isASX: Bool { kind == .stock && (exchange.uppercased() == "ASX" || symbol.uppercased().hasSuffix(".AX")) }

    /// Currency the asset trades in — what a broker statement shows.
    var tradingCurrency: String { isASX ? "AUD" : "USD" }

    var tradingCurrencySymbol: String { tradingCurrency == "AUD" ? "A$" : "US$" }

    /// Short market label for badges and grouping.
    var marketLabel: String {
        if kind == .crypto { return "Crypto" }
        return isASX ? "ASX" : "US"
    }

    /// Converts a stored USD amount into this asset's trading currency.
    func toTradingCurrency(_ usd: Double) -> Double {
        usd / (FXRates.shared.toUSDFactor(from: tradingCurrency) ?? 1)
    }

    /// "A$45.10" — an amount already in the trading currency.
    func formatTrading(_ amount: Double) -> String {
        let digits = abs(amount) < 1 && amount != 0 ? 6 : 2
        return tradingCurrencySymbol + amount.formatted(.number.precision(.fractionLength(2...digits)))
    }

    /// "10 shares" / "1 share" / "0.05 BTC".
    func unitsText(_ quantity: Double) -> String {
        let q = formatQuantity(quantity)
        if kind == .crypto { return "\(q) \(symbol)" }
        return quantity == 1 ? "1 share" : "\(q) shares"
    }

    /// True until a real quote has landed: manual/CSV/broker placeholders carry no
    /// volume and no change (every live source reports both).
    var looksUnpriced: Bool { price <= 0 || (volume == 0 && change == 0 && changePercent == 0) }

    /// Copy of the asset with a better name / exchange (search results know both).
    func with(name: String? = nil, exchange: String? = nil, price: Double? = nil) -> Asset {
        Asset(id: id, symbol: symbol, name: name ?? self.name, price: price ?? self.price,
              change: change, changePercent: changePercent, volume: volume, kind: kind,
              marketCap: marketCap, peRatio: peRatio, eps: eps, week52High: week52High,
              week52Low: week52Low, avgVolume: avgVolume, dividend: dividend, beta: beta,
              exchange: exchange ?? self.exchange)
    }
}

/// Parses a typed number, accepting "," as the decimal separator and grouping spaces.
func parseDecimal(_ text: String) -> Double? {
    let cleaned = text.trimmingCharacters(in: .whitespaces)
        .replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: ",", with: ".")
    guard !cleaned.isEmpty, let value = Double(cleaned), value.isFinite else { return nil }
    return value
}

// MARK: - Transactions (validated replace)

extension MarketData {
    /// Replaces a holding's transaction list (used to edit one transaction) and
    /// rebuilds shares + average cost from it. Refuses lists that would ever sell
    /// more than was held, or that leave nothing.
    @discardableResult
    func replaceTransactions(holdingID: UUID, with transactions: [Transaction]) -> HoldingChange {
        guard let index = portfolio.firstIndex(where: { $0.id == holdingID }) else {
            return .invalid("That holding no longer exists.")
        }
        var running = 0.0
        for t in transactions.sorted(by: { $0.date < $1.date }) {
            running += t.type == .buy ? t.shares : -t.shares
            if running < -1e-9 {
                return .invalid("That would sell more than you held on \(t.date.formatted(date: .abbreviated, time: .omitted)).")
            }
        }
        let rebuilt = MarketData.position(from: transactions)
        guard rebuilt.shares > 1e-9 else {
            return .invalid("That leaves no shares — remove the holding instead.")
        }
        portfolio[index].transactions = transactions
        portfolio[index].shares = rebuilt.shares
        portfolio[index].avgCost = rebuilt.avgCost
        saveToDisk()
        updateWidgetData()
        if SyncManager.shared.isSignedIn { Task { await SyncManager.shared.scheduleBackgroundSync() } }
        return .ok
    }
}

// MARK: - Holding row

enum HoldingMetric: String, CaseIterable {
    case today, total
    var title: String { self == .today ? "Today" : "Total return" }
}

struct PortfolioHoldingRow: View {
    let holding: PortfolioHolding
    let metric: HoldingMetric
    /// Share of the portfolio, 0–100.
    let weight: Double
    var hidesValues = false
    /// The broker it's synced from (nil = added by hand).
    var source: String? = nil

    @EnvironmentObject private var marketData: MarketData
    @Environment(\.theme) private var theme

    private var asset: Asset { holding.asset }
    private var noLivePrice: Bool { marketData.hasNoLivePrice(asset) }
    private var hasCost: Bool { holding.costBasis > 0 }

    var body: some View {
        AdaptiveQuoteRow {
            HStack(spacing: DS.Space.m) {
                TickerLogo(symbol: asset.symbol, kind: asset.kind, exchange: asset.exchange, size: 40)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(asset.symbol)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)
                        if asset.isASX { MarketBadge(text: "ASX") }
                    }
                    Text([asset.unitsText(holding.shares), formatPercent(weight), source].compactMap { $0 }.joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
            }
        } numbers: { stacked in
            let value = Text(hidesValues ? "••••" : marketData.formatPrice(holding.currentValue))
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .contentTransition(.numericText())
                .priceFlash(value: holding.asset.price)
            if stacked {
                HStack(spacing: DS.Space.s) { value; trailingDetail; Spacer(minLength: 0) }
            } else {
                VStack(alignment: .trailing, spacing: 4) { value; trailingDetail }
            }
        }
        .padding(.vertical, DS.Space.s + 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var trailingDetail: some View {
        if noLivePrice {
            Text("No live price")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.warningColor)
        } else if metric == .total && !hasCost {
            Text("Cost not set")
                .font(.caption.weight(.medium))
                .foregroundStyle(theme.secondaryText)
        } else {
            // Total return includes profit already banked from partial sales (matches the holding page).
            ChangePill(percent: metric == .today ? asset.changePercent : holding.totalReturnPercent, compact: true)
        }
    }

    private var accessibilityText: String {
        var parts = [asset.name == asset.symbol ? asset.symbol : "\(asset.symbol), \(asset.name)",
                     asset.unitsText(holding.shares)]
        if !hidesValues { parts.append("worth \(marketData.formatPrice(holding.currentValue))") }
        if noLivePrice {
            parts.append("no live price")
        } else if metric == .today {
            parts.append("today \(asset.changePercent >= 0 ? "up" : "down") \(String(format: "%.2f", abs(asset.changePercent))) percent")
        } else if hasCost {
            parts.append("total return \(holding.totalReturn >= 0 ? "up" : "down") \(String(format: "%.2f", abs(holding.totalReturnPercent))) percent")
        }
        parts.append("\(String(format: "%.1f", weight)) percent of portfolio")
        if let source { parts.append("synced from \(source)") }
        return parts.joined(separator: ", ")
    }
}

struct MarketBadge: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(theme.subtleFill))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(theme.cardBorder.opacity(0.6), lineWidth: 0.5))
            .accessibilityHidden(true)
            .lineLimit(1)
            .fixedSize()
    }
}

// MARK: - Segmented bar (44pt)

struct DSSegmentBar<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    var identifier: (Value) -> String = { "\($0)" }

    @Environment(\.theme) private var theme
    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isOn = option == selection
                Button {
                    guard !isOn else { return }
                    Haptics.select()
                    dsAnimate(DS.quick) { selection = option }
                } label: {
                    Text(title(option))
                        .font(.subheadline.weight(isOn ? .semibold : .medium))
                        .foregroundStyle(isOn ? theme.primaryText : theme.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background {
                            if isOn {
                                Capsule().fill(theme.cardBackground)
                                    .matchedGeometryEffect(id: "selection", in: indicator)
                            }
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityIdentifier(identifier(option))
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Capsule().fill(theme.subtleFill))
    }
}

// MARK: - Ledger

/// One "label … value" line, Public / Fidelity style.
struct LedgerLine: View {
    let label: LocalizedStringKey
    let value: String
    var tint: Color? = nil
    var detail: String? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
            Spacer(minLength: DS.Space.m)
            VStack(alignment: .trailing, spacing: 1) {
                Text(value)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(tint ?? theme.primaryText)
                    .multilineTextAlignment(.trailing)
                if let detail {
                    Text(detail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }
}

/// Compact stat for the summary strip under the hero.
struct LedgerStat: View {
    let label: LocalizedStringKey
    let value: String
    var tint: Color? = nil
    var alignment: HorizontalAlignment = .leading
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint ?? theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Allocation palette

/// Categorical colours for allocation slices — system colours, so they adapt to
/// light/dark. (Gain/loss colours never appear here.)
enum AllocationPalette {
    static let colors: [Color] = [
        DS.accent,
        Color(UIColor.systemTeal),
        Color(UIColor.systemPurple),
        Color(UIColor.systemOrange),
        Color(UIColor.systemPink),
        Color(UIColor.systemIndigo),
        Color(UIColor.systemMint)
    ]
    static let other = Color(UIColor.systemGray3)

    static func color(_ index: Int) -> Color { colors[index % colors.count] }
}

// MARK: - List row helpers

extension View {
    /// A full-width row in the Portfolio's plain List: no separator, clear background.
    func portfolioRow(top: CGFloat = 0, bottom: CGFloat = 0) -> some View {
        self
            .listRowInsets(EdgeInsets(top: top, leading: DS.Space.l, bottom: bottom, trailing: DS.Space.l))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
