import SwiftUI

struct PortfolioBenchmarkPeriod: Identifiable {
    let id: String
    let start: String
    let end: String
    let timeWeighted: Decimal?
    var continuous = false

    var title: String { "\(start) to \(end)" + (continuous ? " · Continuous" : "") }
}

struct PortfolioBenchmarkSheet: View {
    private enum Fund: String, CaseIterable {
        case spy = "SPY"
        case stw = "STW"

        var label: String {
            switch self {
            case .spy: "S&P 500 ETF (SPY)"
            case .stw: "S&P/ASX 200 ETF (STW)"
            }
        }

        var url: URL {
            switch self {
            case .spy: URL(string: "https://www.ssga.com/us/en/individual/etfs/state-street-spdr-500-etf-trust-spy")!
            case .stw: URL(string: "https://www.ssga.com/au/en_gb/individual/etfs/state-street-spdr-spasx-200-etf-stw")!
            }
        }
    }

    private struct Request: Hashable {
        let fund: Fund
        let start: String
        let end: String
        let retry: Int
    }

    private struct Result: Decodable {
        struct Boundary: Decodable {
            let session: String
            let fxDate: String?
        }
        let returnPct: Decimal
        let start: Boundary
        let end: Boundary
        let source: String
        let sourceUrl: URL
    }

    private struct Response: Decodable {
        struct Data: Decodable { let result: Result? }
        let data: Data
    }

    private enum State {
        case result(Result?)
        case failure(String)
    }

    let userId: UUID
    let periods: [PortfolioBenchmarkPeriod]

    @Environment(\.dismiss) private var dismiss
    @State private var selectedPeriod = ""
    @State private var fund: Fund = Benchmark.preferred == .asx200 ? .stw : .spy
    @State private var retry = 0
    @State private var loaded: (request: Request, state: State)?

    private var period: PortfolioBenchmarkPeriod? {
        periods.first { $0.id == selectedPeriod } ?? periods.first
    }

    private var request: Request? {
        period.map { Request(fund: fund, start: $0.start, end: $0.end, retry: retry) }
    }

    private var periodTooLong: Bool {
        guard let period,
              let start = ISO8601DateFormatter.benchmarkDay.date(from: period.start),
              let end = ISO8601DateFormatter.benchmarkDay.date(from: period.end) else { return false }
        return end.timeIntervalSince(start) > 3_660 * 86_400
    }

    var body: some View {
        NavigationStack {
            List {
                if let period, let request {
                    Section {
                        VStack(alignment: .leading, spacing: DS.Space.xs) {
                            Text("Return period").font(.footnote).foregroundStyle(.secondary)
                            Picker("Return period", selection: Binding(get: { period.id }, set: { selectedPeriod = $0 })) {
                                ForEach(periods) { option in Text(option.title).tag(option.id) }
                            }
                            .labelsHidden()
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("portfolio.returns.benchmark.period")
                        }
                        Picker("Benchmark", selection: $fund) {
                            ForEach(Fund.allCases, id: \.self) { fund in Text(fund.label).tag(fund) }
                        }
                        .accessibilityIdentifier("portfolio.returns.benchmark.fund")
                    } footer: {
                        Text("Compares the portfolio’s time-weighted return with the ETF’s distribution-adjusted return in USD. The ETF uses its local market close on or before each date.")
                    }
                    Section("Returns") {
                        metric("Portfolio time-weighted return", percent(period.timeWeighted), id: "portfolio")
                        if periodTooLong {
                            Text("Choose a return period of up to ten years.").foregroundStyle(.secondary)
                        } else {
                            comparison(request, period: period)
                        }
                    }
                }
            }
            .navigationTitle("Benchmark comparison")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task(id: request) {
            if let request, !periodTooLong { await load(request) }
        }
    }

    @ViewBuilder
    private func comparison(_ request: Request, period: PortfolioBenchmarkPeriod) -> some View {
        if loaded?.request != request {
            ProgressView("Loading benchmark")
        } else if let state = loaded?.state {
            switch state {
            case .result(let result):
                if let result {
                    metric("ETF return in USD", percent(result.returnPct), id: "etf")
                    let difference = period.timeWeighted.map { $0 - result.returnPct }
                    let format = Decimal.FormatStyle.number.precision(.fractionLength(2)).sign(strategy: .always(includingZero: false))
                    metric("Difference", difference.map { "\($0.formatted(format)) pp" } ?? "Unavailable", id: "difference")
                    Text("ETF closes \(result.start.session) and \(result.end.session).")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let start = result.start.fxDate, let end = result.end.fxDate {
                        Text("ECB AUD/USD rates observed \(start) and \(end).")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Link(result.source, destination: result.sourceUrl)
                    Link("ETF details", destination: request.fund.url)
                } else {
                    Text("Completed prices or exchange rates are unavailable for these dates.")
                        .foregroundStyle(.secondary)
                }
            case .failure(let message):
                Text(message).foregroundStyle(.secondary)
                Button("Retry benchmark") { retry += 1 }
            }
        }
    }

    private func percent(_ value: Decimal?) -> String {
        value.map { ($0 / 100).formatted(.percent.precision(.fractionLength(2))) } ?? "Unavailable"
    }

    private func metric(_ label: String, _ value: String, id: String) -> some View {
        LabeledContent(label, value: value)
            .monospacedDigit()
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("portfolio.returns.benchmark.\(id)")
    }

    private func load(_ request: Request) async {
        let state: State
        do {
            let data = try await SecureBackend.invoke("market-workspace", body: [
                "action": "portfolioBenchmark", "benchmark": request.fund.rawValue, "start": request.start, "end": request.end,
            ], expectedUserID: userId)
            state = .result(try JSONDecoder().decode(Response.self, from: data).data.result)
        } catch let error as SecureBackend.FunctionError {
            state = .failure(error.message)
        } catch {
            state = .failure("Couldn’t load the benchmark.")
        }
        guard !Task.isCancelled else { return }
        loaded = (request, state)
    }
}

private extension ISO8601DateFormatter {
    static let benchmarkDay: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }()
}
