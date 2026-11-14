//
//  PortfolioAllocationView.swift
//  Stock Tracker
//
//  Allocation segment of the Portfolio tab (after Origin / Revolut on Mobbin):
//  a selectable donut with the total in the centre,
//  a legend with value and share, and an honest concentration card.
//
//  Every number here is derived from live holdings. Volatility is shown only
//  when it can be computed from a year of real price history — never guessed.
//

import SwiftUI
import Charts
import TradingCore

struct PortfolioAllocationTab: View {
    @EnvironmentObject private var marketData: MarketData
    @Environment(\.theme) private var theme
    @AppStorage("portfolioValueHidden") private var valueHidden = false
    @AppStorage("portfolioAllocationGrouping") private var groupingRaw = Grouping.holding.rawValue

    @State private var selectedAngle: Double?
    @State private var showingIssuerSources = false
    @State private var volatility: Double?
    @State private var volatilityState: LoadState = .idle

    enum Grouping: String, CaseIterable {
        case holding, type, market, sector, incorporation
        var title: String {
            switch self {
            case .holding: return "Holdings"
            case .type:    return "Type"
            case .market:  return "Market"
            case .sector: return "SIC sector"
            case .incorporation: return "Issuer incorporation"
            }
        }

        var issuerDimension: PortfolioIssuerExposure.Dimension? {
            switch self {
            case .sector: return .sector
            case .incorporation: return .incorporation
            default: return nil
            }
        }
    }

    enum LoadState { case idle, loading, done, unavailable }

    struct Slice: Identifiable, Equatable {
        let id: String
        let label: String
        let detail: String
        let value: Double
        let color: Color
    }

    private var grouping: Grouping { Grouping(rawValue: groupingRaw) ?? .holding }

    private func slices(holdings: [PortfolioHolding], issuer: PortfolioIssuerExposure?) -> [Slice] {
        switch grouping {
        case .holding:
            let top = holdings.prefix(6)
            var out = top.enumerated().map { i, h in
                Slice(id: h.id.uuidString, label: h.asset.symbol,
                      detail: h.asset.name == h.asset.symbol ? h.asset.marketLabel : h.asset.name,
                      value: h.currentValue, color: AllocationPalette.color(i))
            }
            let rest = holdings.dropFirst(6)
            if !rest.isEmpty {
                out.append(Slice(id: "other", label: "Other", detail: "\(rest.count) holdings",
                                 value: rest.reduce(0) { $0 + $1.currentValue }, color: AllocationPalette.other))
            }
            return out
        case .type:
            return grouped(holdings) { $0.asset.kind == .crypto ? "Crypto" : "Stocks & ETFs" }
        case .market:
            return grouped(holdings) {
                if $0.asset.kind == .crypto { return "Crypto" }
                return $0.asset.listedStock.map { "\($0.venue.shortName) shares" } ?? "Unknown listing market"
            }
        case .sector, .incorporation:
            return grouped(holdings) { issuer?.labels[$0.id] ?? "Unclassified shares" }
        }
    }

    private func grouped(_ holdings: [PortfolioHolding], key: (PortfolioHolding) -> String) -> [Slice] {
        let groups = Dictionary(grouping: holdings, by: key)
        let totals = groups.map { (name: $0.key, value: $0.value.reduce(0) { $0 + $1.currentValue }, count: $0.value.count) }
        let ordered = totals.sorted { $0.value == $1.value ? $0.name < $1.name : $0.value > $1.value }
        return ordered.enumerated().map { index, group in
            Slice(id: group.name, label: group.name, detail: group.count == 1 ? "1 holding" : "\(group.count) holdings",
                  value: group.value, color: AllocationPalette.color(index))
        }
    }

    private func selected(in slices: [Slice]) -> Slice? {
        guard let selectedAngle else { return nil }
        var running = 0.0
        for s in slices {
            running += s.value
            if selectedAngle <= running { return s }
        }
        return slices.last
    }

    private func share(_ value: Double, total: Double) -> Double { total > 0 ? value / total * 100 : 0 }

    // MARK: Body

    var body: some View {
        if marketData.portfolio.isEmpty {
            EmptyStateCard(systemImage: "chart.pie", title: "Nothing to break down yet",
                           message: "Add a holding to see your portfolio allocation.")
        } else {
            let open = marketData.portfolio.filter { $0.shares > 0 }
            let dimension = grouping.issuerDimension
            let holdings = open.filter { holding in
                holding.currentValue.isFinite && holding.currentValue > 0
                    && (dimension == nil || !marketData.hasNoLivePrice(holding.asset))
            }.sorted { $0.currentValue > $1.currentValue }
            let issuer = dimension.map { PortfolioIssuerExposure(holdings: holdings, dimension: $0) }
            let chartTotal = holdings.reduce(0) { $0 + $1.currentValue }

            VStack(alignment: .leading, spacing: DS.Space.l) {
                allocationPicker
                if let issuer, let dimension {
                    issuerCoverage(issuer, dimension: dimension, valued: holdings.count, open: open.count, total: chartTotal)
                }
                if let issuer, !issuer.sources.isEmpty {
                    issuerSources(issuer.sources)
                }
                if chartTotal.isFinite, chartTotal > 0 {
                    donutCard(slices(holdings: holdings, issuer: issuer), total: chartTotal, count: holdings.count)
                } else {
                    EmptyStateCard(systemImage: "chart.pie", title: "Allocation unavailable",
                                   message: "The breakdown appears when holdings have usable prices.")
                }
                concentrationCard(marketData.portfolioConcentration)
            }
            .task(id: marketData.portfolio.map { "\($0.asset.quoteIdentity):\($0.shares)" }.joined()) { await loadVolatility() }
        }
    }

    private var allocationPicker: some View {
        Menu {
            Picker("Group by", selection: Binding(get: { grouping }, set: { groupingRaw = $0.rawValue; selectedAngle = nil })) {
                ForEach(Grouping.allCases, id: \.self) { option in
                    Text(LocalizedStringKey(option.title)).tag(option)
                }
            }
        } label: {
            HStack(spacing: DS.Space.s) {
                Text("Group by").foregroundStyle(theme.secondaryText)
                Spacer(minLength: DS.Space.s)
                Text(LocalizedStringKey(grouping.title)).fontWeight(.semibold)
                Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold))
            }
            .font(.subheadline)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Group by")
        .accessibilityValue(Text(LocalizedStringKey(grouping.title)))
        .accessibilityIdentifier("portfolio.allocation.grouping")
    }

    private func issuerCoverage(_ issuer: PortfolioIssuerExposure, dimension: PortfolioIssuerExposure.Dimension,
                                valued: Int, open: Int, total: Double) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("\(valued) of \(open) holdings valued.")
            if total > 0 {
                Text("\(formatPercent(share(issuer.classifiedValue, total: total))) of valued holdings classified.")
                    .accessibilityIdentifier("portfolio.allocation.issuerCoverage")
            }
            if dimension == .sector {
                Text("Sectors group SEC Standard Industrial Classification codes by SIC division.")
            } else {
                Text("Countries reflect the issuer’s legal incorporation. Revenue by country can differ.")
            }
        }
        .font(.footnote)
        .foregroundStyle(theme.secondaryText)
    }

    private func issuerSources(_ sources: [PortfolioIssuerExposure.Source]) -> some View {
        Button {
            showingIssuerSources = true
        } label: {
            Label("Issuer filing sources", systemImage: "doc.text")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("portfolio.allocation.filings")
        .sheet(isPresented: $showingIssuerSources) {
            NavigationStack {
                List {
                    ForEach(sources) { source in
                        Link(destination: source.filing.evidence.url) {
                            VStack(alignment: .leading, spacing: DS.Space.xs) {
                                Text("\(source.filing.issuer) · \(source.listing)").font(.subheadline.weight(.semibold))
                                Text("SEC filing \(source.filing.evidence.filedOn) · SIC \(source.filing.sic)")
                                    .font(.caption)
                                    .foregroundStyle(theme.secondaryText)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("portfolio.allocation.filing.\(source.id)")
                    }
                }
                .navigationTitle("Issuer filing sources")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingIssuerSources = false }
                    }
                }
            }
        }
    }

    private func donutCard(_ data: [Slice], total: Double, count: Int) -> some View {
        let selected = selected(in: data)
        return VStack(spacing: DS.Space.l) {
            Chart(data) { slice in
                SectorMark(angle: .value("Value", slice.value), innerRadius: .ratio(0.64), angularInset: 1.5)
                    .cornerRadius(3)
                    .foregroundStyle(slice.color)
                    .opacity(selected == nil || selected == slice ? 1 : 0.3)
            }
            .chartAngleSelection(value: $selectedAngle)
            .chartLegend(.hidden)
            .frame(height: 220)
            .chartBackground { proxy in
                GeometryReader { geo in
                    if let frame = proxy.plotFrame {
                        let rect = geo[frame]
                        centerLabel(selected: selected, total: total, count: count)
                            .frame(width: rect.width * 0.56)
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
            }
            .accessibilityLabel(data.map { "\($0.label) \(String(format: "%.1f", share($0.value, total: total))) percent" }.joined(separator: ", "))
            .accessibilityIdentifier("portfolio.allocation.donut")

            VStack(spacing: 0) {
                ForEach(data) { slice in
                    legendRow(slice, total: total)
                    if slice != data.last { Divider().overlay(theme.cardBorder.opacity(0.4)).padding(.leading, 22) }
                }
            }
        }
        .dsCard()
    }

    private func centerLabel(selected: Slice?, total: Double, count: Int) -> some View {
        VStack(spacing: 2) {
            Text(selected?.label ?? "Total")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
            Text(valueHidden ? "••••" : marketData.formatPrice(selected?.value ?? total))
                .font(DS.money(20, weight: .bold))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(selected.map { formatPercent(share($0.value, total: total)) } ?? "\(count) holdings")
                .font(.caption.monospacedDigit())
                .foregroundStyle(theme.secondaryText)
        }
        .multilineTextAlignment(.center)
    }

    private func legendRow(_ slice: Slice, total: Double) -> some View {
        HStack(spacing: DS.Space.m) {
            Circle().fill(slice.color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(slice.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                Text(slice.detail)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: DS.Space.s)
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatPercent(share(slice.value, total: total)))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(theme.primaryText)
                Text(valueHidden ? "••••" : marketData.formatPrice(slice.value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .padding(.vertical, DS.Space.s)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("portfolio.allocation.slice.\(slice.id)")
    }

    // MARK: Concentration

    private func concentrationCard(_ concentration: PortfolioConcentration) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("Concentration")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                if let largest = concentration.listings.first {
                    LedgerLine(label: "Largest listing", value: "\(concentration.label(for: largest)) · \(formatPercent(concentration.share(of: largest.value)))")
                        .accessibilityIdentifier("portfolio.concentration.largest")
                }
                if concentration.listings.count > 3 {
                    LedgerLine(label: "Top 3 listings", value: formatPercent(concentration.topThreeShare))
                }
                LedgerLine(label: "Volatility (past year)", value: volatilityText)
            }
            Text(concentration.coverage)
                .font(.footnote)
                .foregroundStyle(theme.secondaryText)
            Text("Concentration uses positions with usable prices and combines the same listing across accounts.")
                .font(.caption2)
                .foregroundStyle(theme.secondaryText)
            Text("Volatility is how much your current holdings’ combined value swung day to day over the past year, annualised.")
                .font(.caption2)
                .foregroundStyle(theme.secondaryText)
        }
        .dsCard()
    }

    private var volatilityText: String {
        switch volatilityState {
        case .idle, .loading: return "Calculating…"
        case .unavailable:    return "—"
        case .done:           return volatility.map { String(format: "%.1f%% a year", $0) } ?? "—"
        }
    }

    /// Annualised standard deviation of the reconstructed 1Y series' period returns.
    private func loadVolatility() async {
        guard !marketData.portfolio.isEmpty else { return }
        volatilityState = .loading
        do {
            let value = marketData.totalPortfolioValue
            let series = try await PriceHistoryService.shared.portfolioSeries(
                holdings: marketData.portfolio, range: .oneYear,
                liveValue: value, previousCloseValue: value - marketData.dailyProfitLoss)
            let pts = series.points
            guard pts.count >= 60, let first = pts.first?.date, let last = pts.last?.date else {
                volatilityState = .unavailable; return
            }
            var returns: [Double] = []
            for (a, b) in zip(pts, pts.dropFirst()) where a.price > 0 {
                returns.append(b.price / a.price - 1)
            }
            let years = last.timeIntervalSince(first) / (365.25 * 86_400)
            guard returns.count >= 30, years > 0.5 else { volatilityState = .unavailable; return }
            let mean = returns.reduce(0, +) / Double(returns.count)
            let variance = returns.reduce(0) { $0 + pow($1 - mean, 2) } / Double(returns.count - 1)
            let perYear = Double(returns.count) / years
            volatility = sqrt(variance) * sqrt(perYear) * 100
            volatilityState = .done
        } catch {
            volatilityState = .unavailable
        }
    }
}
