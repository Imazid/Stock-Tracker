import SwiftUI

struct CompanyMarketResearch: Decodable {
    struct Values: Decodable {
        let marketCapMillions: Double?
        let pe: Double?
        let revenueGrowth: Double?
        let margin: Double?
    }
    struct Profile: Decodable { let currency: String }
    struct Earnings: Decodable, Identifiable {
        let date: String
        let actual: Double?
        let estimate: Double?
        var id: String { date }
    }
    struct Article: Decodable, Identifiable {
        let title: String
        let url: URL
        let source: String
        let time: Double
        var id: URL { url }
        var published: Date { Date(timeIntervalSince1970: time / 1000) }
    }

    let profile: Profile
    let values: Values
    let earnings: [Earnings]
    let news: [Article]
    let asOf: Double
    let source: String
    let newsAvailable: Bool
}

struct CompanyMarketResearchSections: View {
    let company: CompanyMarketResearch

    var body: some View {
        let values = company.values
        if values.marketCapMillions != nil || values.pe != nil || values.revenueGrowth != nil || values.margin != nil {
            Section("Market fundamentals") {
                if let cap = values.marketCapMillions {
                    LabeledContent("Market capitalisation", value: "\((cap * 1_000_000).formatted(.number.notation(.compactName))) \(company.profile.currency)")
                }
                if let pe = values.pe {
                    LabeledContent("P/E", value: "\(pe.formatted(.number.precision(.fractionLength(0...2))))×")
                }
                if let growth = values.revenueGrowth {
                    LabeledContent("Revenue growth (TTM)", value: TradingFormat.percent(growth, signed: false))
                }
                if let margin = values.margin {
                    LabeledContent("Net margin (TTM)", value: TradingFormat.percent(margin, signed: false))
                }
                Text("\(company.source) · Retrieved \(Date(timeIntervalSince1970: company.asOf / 1000).formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        if !company.earnings.isEmpty {
            Section("Reported earnings") {
                ForEach(company.earnings) { result in
                    LabeledContent {
                        VStack(alignment: .trailing, spacing: 3) {
                            if let actual = result.actual { Text("Actual \(actual, format: .number.precision(.fractionLength(0...4)))") }
                            if let estimate = result.estimate { Text("Estimate \(estimate, format: .number.precision(.fractionLength(0...4)))") }
                        }
                        .monospacedDigit()
                    } label: {
                        Text(result.date)
                    }
                }
                Text("Earnings per share · \(company.source)")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        Section("Recent headlines") {
            if !company.newsAvailable {
                Text("The Finnhub company news feed is unavailable.").foregroundStyle(.secondary)
            } else if company.news.isEmpty {
                Text("No headlines returned for the past 14 days.").foregroundStyle(.secondary)
            }
            ForEach(company.news) { article in
                Link(destination: article.url) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(article.title).font(.subheadline.weight(.medium))
                        Text("\(article.source) · \(article.published.formatted(date: .abbreviated, time: .shortened))")
                            .font(.footnote).foregroundStyle(Color.secondary)
                    }
                }
                .accessibilityIdentifier("companyResearch.headline")
            }
        }
    }
}
