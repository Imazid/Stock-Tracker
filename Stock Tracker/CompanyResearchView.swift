import Foundation
import SwiftUI
import TradingCore

struct CompanyResearchView: View {
    let instrument: Instrument
    @EnvironmentObject private var auth: SupabaseAuthManager
    @Environment(\.dismiss) private var dismiss
    @State private var loaded: LoadedReport?
    @State private var errorMessage: String?
    @State private var requestCount = 0

    private struct LoadedReport {
        let owner: UUID?
        let report: CompanyResearchReport
        let dashboardURL: URL
    }

    private struct RequestKey: Equatable {
        let owner: UUID?
        let attempt: Int
    }

    static func listing(for asset: Asset) -> Instrument? {
        guard let listing = asset.listedStock else { return nil }
        return .listed(listing.symbol, name: asset.name, on: listing.venue, etf: asset.isListedETF)
    }

    static var directOrigin: URL? {
        #if DEBUG
        if let override = UserDefaults.standard.string(forKey: "CompanyResearchURLOverride"),
           let url = URL(string: override), url.host() == "127.0.0.1", url.scheme == "http" {
            return url
        }
        #endif
        guard let value = Bundle.main.object(forInfoDictionaryKey: "CompanyResearchURL") as? String,
              let url = URL(string: value), url.scheme == "https", url.host() != nil,
              url.user() == nil, url.password() == nil, url.query() == nil, url.fragment() == nil
        else { return nil }
        return url
    }

    var body: some View {
        NavigationStack {
            Group {
                if let loaded, loaded.owner == auth.userId {
                    let report = loaded.report
                    List {
                        if let errorMessage {
                            Section { Text(errorMessage).font(.footnote).foregroundStyle(.secondary) }
                        }
                        if let quote = report.quote {
                            Section("Market quote") {
                                LabeledContent("Last price", value: TradingFormat.price(quote.last, quote.currency))
                                Text([quote.source, quote.observedAt, quote.stale ? "Stale" : quote.status.replacingOccurrences(of: "_", with: " ")].joined(separator: " · "))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        if let profile = report.profile {
                            Section("Company") {
                                Text(profile.name).font(.headline)
                                if let industry = profile.industry ?? profile.sector { Text(industry) }
                                if let location = profile.headquarters ?? profile.incorporation { Text(location) }
                                Link(profile.evidence.provider, destination: profile.evidence.url)
                            }
                        }
                        if !report.facts.isEmpty {
                            Section("Financial evidence") {
                                ForEach(report.facts) { fact in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(fact.label).font(.subheadline)
                                        Text("\(fact.value.formatted(.number.precision(.fractionLength(0...4)))) \(fact.unit)")
                                            .font(.body.monospacedDigit())
                                        Text("Period ended \(fact.end) · Filed \(fact.evidence.publishedAt ?? "date unavailable")")
                                            .font(.caption).foregroundStyle(.secondary)
                                            .accessibilityIdentifier("companyResearch.filingDate")
                                        ForEach(Array((fact.inputs ?? [fact.evidence]).enumerated()), id: \.offset) { index, source in
                                            Link(fact.inputs == nil ? source.provider : "Source filing \(index + 1)", destination: source.url)
                                                .font(.caption)
                                                .accessibilityIdentifier("companyResearch.filingSource")
                                        }
                                    }
                                }
                            }
                        }
                        if !report.events.isEmpty {
                            Section("News & filings") {
                                ForEach(report.events) { event in
                                    Link(destination: event.evidence.url) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(event.title)
                                            Text("\(event.date.prefix(10)) · \(event.category) · \(event.publisher ?? event.evidence.provider)")
                                            .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    .accessibilityIdentifier("companyResearch.eventSource")
                                }
                            }
                        }
                        Section("Research workspace") {
                            Link("Open full company dashboard", destination: loaded.dashboardURL)
                            ForEach(report.links ?? []) { link in
                                Link(link.label, destination: link.url)
                            }
                        }
                        Section("Coverage through \(report.asOf) UTC") {
                            ForEach(report.coverage) { row in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(row.dataset).font(.subheadline.weight(.semibold))
                                    Text(row.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .refreshable { await load() }
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Research unavailable", systemImage: "doc.text.magnifyingglass")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try again") { requestCount += 1 }
                    }
                } else {
                    ProgressView("Collecting company evidence…")
                }
            }
            .navigationTitle("\(instrument.symbol) Research")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("companyResearch.done")
                }
            }
            .task(id: RequestKey(owner: auth.userId, attempt: requestCount)) { await load() }
        }
    }

    private func load() async {
        let owner = auth.userId
        errorMessage = nil
        let decoder = JSONDecoder()
        do {
            let loaded: CompanyResearchReport
            let dashboard: URL
            if let origin = Self.directOrigin {
                let url = origin.appending(path: "api/markets/instruments").appending(path: instrument.id).appending(path: "research/report")
                var request = URLRequest(url: url, timeoutInterval: 40)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                loaded = try decoder.decode(CompanyResearchReport.self, from: data)
                dashboard = origin.appending(path: "markets").appending(path: instrument.id)
            } else {
                guard let owner else {
                    errorMessage = "Sign in to Stock Tracker in Settings to view the company report."
                    return
                }
                let data = try await SecureBackend.invoke("market-workspace", body: [
                    "action": "companyReport", "instrumentId": instrument.id,
                ], expectedUserID: owner)
                let payload = try decoder.decode(CompanyResearchResponse.self, from: data).data
                loaded = payload.report
                dashboard = payload.dashboardURL
            }
            guard loaded.instrumentId == instrument.id else { throw URLError(.badServerResponse) }
            guard !Task.isCancelled, owner == auth.userId else { return }
            self.loaded = LoadedReport(owner: owner, report: loaded, dashboardURL: dashboard)
        } catch {
            guard !Task.isCancelled, owner == auth.userId else { return }
            errorMessage = (error as? SecureBackend.FunctionError)?.message ?? "Couldn’t load the company report. Try again."
        }
    }
}

private struct CompanyResearchResponse: Decodable {
    struct Payload: Decodable {
        let report: CompanyResearchReport
        let dashboardURL: URL
    }
    let data: Payload
}

private struct CompanyResearchReport: Decodable {
    struct Source: Decodable {
        let provider: String
        let url: URL
        let publishedAt: String?
    }
    struct Profile: Decodable {
        let name: String
        let industry: String?
        let sector: String?
        let headquarters: String?
        let incorporation: String?
        let evidence: Source
    }
    struct Fact: Decodable, Identifiable {
        let concept: String
        let label: String
        let value: Double
        let unit: String
        let end: String
        let evidence: Source
        let inputs: [Source]?
        var id: String { "\(concept):\(unit):\(end)" }
    }
    struct Event: Decodable, Identifiable {
        let id: String
        let title: String
        let category: String
        let date: String
        let publisher: String?
        let evidence: Source
    }
    struct Coverage: Decodable, Identifiable {
        let dataset: String
        let detail: String
        var id: String { dataset }
    }
    struct SourceLink: Decodable, Identifiable {
        let label: String
        let url: URL
        var id: URL { url }
    }

    struct Quote: Decodable {
        let last: Double
        let currency: String
        let source: String
        let observedAt: String
        let status: String
        let stale: Bool
    }

    let instrumentId: String
    let asOf: String
    let quote: Quote?
    let profile: Profile?
    let facts: [Fact]
    let events: [Event]
    let coverage: [Coverage]
    let links: [SourceLink]?
}
