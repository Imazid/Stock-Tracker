import Foundation
import SwiftUI
import TradingCore

struct CompanyResearchView: View {
    let instrument: Instrument
    let origin: URL
    @Environment(\.dismiss) private var dismiss
    @State private var report: CompanyResearchReport?
    @State private var failed = false
    @State private var requestCount = 0

    static var origin: URL? {
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
                if let report {
                    List {
                        if let profile = report.profile {
                            Section("Company") {
                                Text(profile.name).font(.headline)
                                if let industry = profile.industry { Text(industry) }
                                if let location = profile.headquarters { Text(location) }
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
                                }
                            }
                        }
                        Section("Research workspace") {
                            Link("Open full company dashboard", destination: origin.appending(path: "markets").appending(path: instrument.id))
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
                } else if failed {
                    ContentUnavailableView {
                        Label("Research unavailable", systemImage: "doc.text.magnifyingglass")
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
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task(id: requestCount) { await load() }
        }
    }

    private func load() async {
        failed = false
        let url = origin.appending(path: "api/markets/instruments").appending(path: instrument.id).appending(path: "research/report")
        var request = URLRequest(url: url, timeoutInterval: 40)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                failed = true
                return
            }
            report = try JSONDecoder().decode(CompanyResearchReport.self, from: data)
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
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
        let headquarters: String?
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

    let asOf: String
    let profile: Profile?
    let facts: [Fact]
    let events: [Event]
    let coverage: [Coverage]
    let links: [SourceLink]?
}
