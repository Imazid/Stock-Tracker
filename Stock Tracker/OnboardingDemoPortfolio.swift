import SwiftUI
import TradingCore

struct OnboardingDemoPortfolio: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var viewModel: OnboardingViewModel
    @EnvironmentObject private var auth: SupabaseAuthManager
    @State private var series: BarSeries?
    @State private var problem = false
    @State private var request = 0
    @State private var units = 5
    @State private var selection: DSChartPoint?

    private var instrument: Instrument {
        if viewModel.markets.contains(.asx) && viewModel.currency == "AUD" {
            return Instrument(symbol: "BHP", name: "BHP Group", assetClass: .equity, venue: .asx)
        }
        if viewModel.markets == [.crypto] {
            return Instrument(symbol: "BTC", name: "Bitcoin", assetClass: .crypto, venue: .crypto)
        }
        return Instrument(symbol: "AAPL", name: "Apple", assetClass: .equity, venue: .us)
    }

    private var quantity: Double { Double(units) * (instrument.venue == .crypto ? 0.001 : 1) }
    private var startingCash: Double { 2_500 }
    private var points: [DSChartPoint] {
        series?.bars.map { DSChartPoint(date: $0.time, value: startingCash + quantity * $0.close) } ?? []
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        Text("Sample portfolio").font(.headline)
                        Text("The holdings and cash are for this demo. The chart uses daily market prices.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text(TradingFormat.money((selection ?? points.last)?.value ?? startingCash, instrument.currency))
                            .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                            .accessibilityLabel(points.isEmpty ? "Sample cash" : "Sample portfolio value")
                            .accessibilityValue(TradingFormat.money((selection ?? points.last)?.value ?? startingCash, instrument.currency))
                            .accessibilityIdentifier("onboarding.demo.value")
                        DSPriceChart(points: points,
                            phase: problem ? .failed("Market history is unavailable.") : series == nil ? .loading : .loaded,
                            height: 170, valueText: { TradingFormat.money($0, instrument.currency) },
                            selection: $selection, onRetry: { request += 1 },
                            accessibilityID: "onboarding.demo.chart", range: .oneMonth)
                        if let series, let last = series.bars.last {
                            Text("\(series.provenance.source) · Latest bar \(last.time.formatted(date: .abbreviated, time: .omitted))")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .dsCard()

                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        Label("Try a different position", systemImage: "slider.horizontal.3")
                            .font(.headline)
                        LabeledContent("Cash", value: TradingFormat.money(startingCash, instrument.currency))
                        Stepper(value: $units, in: 0...20) {
                            LabeledContent(instrument.symbol, value: quantity.formatted() + " units")
                        }
                        .accessibilityIdentifier("onboarding.demo.quantity")
                        Text("Changing the units updates the demo chart. You can practise orders from Portfolio after setup.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .dsCard()
                }
                .padding(DS.Space.gutter)
            }
            .dsScreenBackground()
            .navigationTitle("Portfolio demo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("onboarding.demo.done")
                }
            }
            .onChange(of: units) { _, _ in selection = nil }
            .task(id: request) { await load() }
        }
    }

    private func load() async {
        problem = false
        do {
            let market = LiveMarketData()
            let history: BarSeries
            if auth.isSignedIn && instrument.venue != .asx {
                do { history = try await market.bars(for: instrument, timeframe: .day, count: 22) }
                catch { try Task.checkCancellation(); history = try await market.publicDailyBars(for: instrument, count: 22) }
            } else {
                history = try await market.publicDailyBars(for: instrument, count: 22)
            }
            guard history.bars.count >= 2 else { throw TradingDataError.empty(instrument.symbol) }
            if !Task.isCancelled { series = history }
        } catch {
            if !Task.isCancelled { problem = true }
        }
    }
}
