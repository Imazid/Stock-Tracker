import Foundation
import SwiftUI
import TradingCore

struct AssetRiskView: View {
    let instrument: Instrument
    @EnvironmentObject private var auth: SupabaseAuthManager
    @Environment(\.dismiss) private var dismiss
    @State private var range = "3M"
    @State private var result: AssetRiskResponse?
    @State private var problem: String?
    @State private var attempt = 0

    private struct Request: Equatable {
        let owner: UUID?
        let range: String
        let attempt: Int
    }

    static func listing(for asset: Asset) -> Instrument? {
        if asset.kind == .crypto {
            let id = asset.quoteIdentity
            let symbol = String(id.dropFirst("crypto:".count))
            return .crypto(symbol, name: asset.name)
        }
        switch asset.symbol {
        case "^GSPC", "^IXIC", "^DJI": return .listed(asset.symbol, name: asset.name, on: .us)
        case "^AXJO": return .listed(asset.symbol, name: asset.name, on: .asx)
        default: return CompanyResearchView.listing(for: asset)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let owner = auth.userId {
                    Picker("Risk period", selection: $range) {
                        ForEach(["3M", "6M", "1Y"], id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("assetRisk.range")
                    .listRowBackground(Color.clear)
                    if let result, result.range == range {
                        measurements(result)
                    } else if let problem {
                        Section {
                            Text(problem)
                            Button("Try again") { attempt += 1 }
                        }
                    } else {
                        ProgressView("Loading daily price history…")
                    }
                    Section {
                        DisclosureGroup("How these figures are calculated") {
                            Text("Price change compares the first and last completed daily closes. Drawdown is the largest fall from an earlier closing peak. Daily volatility is the sample standard deviation of the last 20 consecutive daily percentage changes.")
                                .font(.footnote)
                        }
                    }
                } else {
                    ContentUnavailableView("Sign in for price risk", systemImage: "chart.line.downtrend.xyaxis",
                                           description: Text("Sign in to your Stock Tracker account to load this listing’s historical figures."))
                }
            }
            .navigationTitle("\(instrument.symbol) Price Risk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .refreshable { if let owner = auth.userId { await load(owner: owner, period: range) } }
            .task(id: Request(owner: auth.userId, range: range, attempt: attempt)) {
                guard let owner = auth.userId else { result = nil; problem = nil; return }
                await load(owner: owner, period: range)
            }
            .onChange(of: range) { _, _ in problem = nil }
        }
    }

    @ViewBuilder
    private func measurements(_ result: AssetRiskResponse) -> some View {
        Section {
            LabeledContent("Price change", value: result.priceChangePct.map { TradingFormat.percent($0) } ?? "Unavailable")
            LabeledContent("Largest drawdown", value: TradingFormat.percent(-result.maxDrawdownPct, signed: false))
                .accessibilityIdentifier("assetRisk.drawdown")
            if result.maxDrawdownPct > 0 {
                Text("\(result.drawdownPeakDate) to \(result.drawdownTroughDate)")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            LabeledContent("Daily volatility · 20 sessions", value: result.dailyVolatilityPct.map {
                TradingFormat.percent($0, signed: false)
            } ?? "Unavailable")
            if let start = result.volatilityFrom {
                Text("\(start) to \(result.through)").font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Volatility needs 21 consecutive completed closes.").font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("\(result.from) to \(result.through)")
        }
        Section("Price history source") {
            Text(result.source).accessibilityIdentifier("assetRisk.source")
            Text("\(result.currency) · \(result.adjustment)")
            Text("\(result.sessions) closes · \(result.status.replacingOccurrences(of: "_", with: " "))")
            if result.missingSessions > 0 {
                Text("\(result.missingSessions) expected closes are absent within this period. Drawdown uses observed closes.")
                    .foregroundStyle(.secondary)
            }
            if result.missedRecentSessions > 0 {
                Text("\(result.missedRecentSessions) more recent completed sessions are missing.")
                    .foregroundStyle(.secondary)
            }
            if !result.calendarCovered {
                Text("Exchange holiday coverage is incomplete for these dates.").foregroundStyle(.secondary)
            }
        }
    }

    private func load(owner: UUID, period: String) async {
        problem = nil
        do {
            let response = try await SecureBackend.invoke("market-workspace", body: [
                "action": "assetRisk", "instrumentId": instrument.id, "range": period,
            ], expectedUserID: owner)
            let payload = try JSONDecoder().decode(AssetRiskResponse.Envelope.self, from: response).data
            guard payload.instrumentId == instrument.id, payload.range == period else { throw URLError(.badServerResponse) }
            if !Task.isCancelled, owner == auth.userId, period == range { result = payload }
        } catch {
            if !Task.isCancelled, owner == auth.userId, period == range {
                result = nil
                problem = (error as? SecureBackend.FunctionError)?.message ?? "Couldn’t load daily price history."
            }
        }
    }
}

private struct AssetRiskResponse: Decodable {
    struct Envelope: Decodable { let data: AssetRiskResponse }
    let instrumentId: String
    let range: String
    let currency: String
    let source: String
    let status: String
    let adjustment: String
    let from: String
    let through: String
    let sessions: Int
    let missingSessions: Int
    let missedRecentSessions: Int
    let calendarCovered: Bool
    let priceChangePct: Double?
    let maxDrawdownPct: Double
    let drawdownPeakDate: String
    let drawdownTroughDate: String
    let dailyVolatilityPct: Double?
    let volatilityFrom: String?
}
