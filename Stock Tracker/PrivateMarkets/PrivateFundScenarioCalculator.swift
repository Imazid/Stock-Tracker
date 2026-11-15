import SwiftUI
import TradingCore

struct PrivateFundScenarioCalculator: View {
    private enum Outcome: Int, CaseIterable, Identifiable {
        case bear, base, bull

        var id: Self { self }
        var title: String {
            switch self {
            case .bear: "Bear"
            case .base: "Base"
            case .bull: "Bull"
            }
        }
    }

    private struct DraftFlow: Identifiable {
        let id = UUID()
        var date = Date.now
        var amount = ""
    }

    private struct DraftScenario: Identifiable {
        let id: Outcome
        var date: Date?
        var nav = ""
        var distributions: [DraftFlow] = []
    }

    let round: PrivateDeal.Round?
    @State private var currency: String
    @State private var calls = [DraftFlow()]
    @State private var drafts = Outcome.allCases.map { DraftScenario(id: $0) }
    @State private var selected: Outcome = .base
    @FocusState private var amountFocused: Bool

    init(round: PrivateDeal.Round? = nil) {
        self.round = round
        _currency = State(initialValue: round?.currency ?? "AUD")
    }

    private let currencies = ["AUD", "USD", "CAD", "EUR", "GBP", "JPY", "NZD", "SGD"]
    private var index: Int { selected.rawValue }

    var body: some View {
        Form {
            Section {
                if let round {
                    Text("\(round.company.name) · \(round.stage)")
                    LabeledContent("Currency", value: currency)
                    if round.sourceUrl.privateSourceIsSafe {
                        Link("Published disclosure", destination: round.sourceUrl)
                    }
                } else {
                    Picker("Currency", selection: $currency) {
                        ForEach(currencies, id: \.self) { Text($0) }
                    }
                }
            }
            Section("Capital calls") {
                Text("Enter your cash flows in one currency. The same calls apply to all three scenarios. Include fees or taxes in the amounts if you want them reflected.")
                    .font(.footnote).foregroundStyle(.secondary)
                flowFields("Capital call", $calls)
                if parsedFlows(calls) == nil {
                    Text("Enter a positive amount for each capital call.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Projection assumptions") {
                Picker("Fund outcome", selection: $selected) {
                    ForEach(Outcome.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if drafts[index].date == nil {
                    Button("Set projection date") { drafts[index].date = .now }
                } else {
                    DatePicker("Projection date", selection: Binding(
                        get: { drafts[index].date ?? .now },
                        set: { drafts[index].date = $0 }
                    ), displayedComponents: .date)
                    Button("Clear projection date", role: .destructive) { drafts[index].date = nil }
                }
                TextField("Remaining NAV (optional)", text: $drafts[index].nav)
                    .keyboardType(.decimalPad).focused($amountFocused)
                Text("Leave remaining net asset value (NAV) blank to assume zero. Enter expected payouts as dated distributions.")
                    .font(.footnote).foregroundStyle(.secondary)
                flowFields("Distribution", $drafts[index].distributions)
                if let message = inputError(drafts[index]) {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Projected returns") {
                Text("TVPI includes remaining NAV. DPI measures cash distributed. XIRR uses dated cash flows and the assumed NAV at the projection date.")
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach(drafts) { draft in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(draft.id.title).font(.headline)
                        if let result = projection(draft) {
                            LabeledContent("Paid in", value: PrivateInput.money(result.paidIn, currency: currency))
                            LabeledContent("Distributions", value: PrivateInput.money(result.distributions, currency: currency))
                            metric("TVPI", value: result.tvpi.formatted(.number.precision(.fractionLength(2))) + "×", outcome: draft.id)
                            metric("DPI", value: result.dpi.formatted(.number.precision(.fractionLength(2))) + "×", outcome: draft.id)
                            metric("XIRR", value: result.xirr?.formatted(.percent.precision(.fractionLength(2...4))) ?? "Unavailable",
                                   outcome: draft.id)
                        } else {
                            Text("Enter the cash flows and projection date.").foregroundStyle(.secondary)
                        }
                    }
                    .font(.subheadline.monospacedDigit())
                }
            }
        }
        .environment(\.calendar, Calendar(identifier: .gregorian))
        .environment(\.timeZone, .gmt)
        .navigationTitle("Fund Cash-Flow Scenarios")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { amountFocused = false }
            }
        }
    }

    private func flowFields(_ kind: String, _ rows: Binding<[DraftFlow]>) -> some View {
        Group {
            ForEach(rows) { $flow in
                let index = rows.wrappedValue.firstIndex { $0.id == flow.id } ?? 0
                let title = "\(kind) \(index + 1)"
                DatePicker(title + " date", selection: $flow.date, displayedComponents: .date)
                TextField(title + " amount", text: $flow.amount)
                    .keyboardType(.decimalPad).focused($amountFocused)
                Button("Remove " + title.lowercased(), role: .destructive) {
                    rows.wrappedValue.removeAll { $0.id == flow.id }
                }
            }
            Button("Add " + kind.lowercased()) { rows.wrappedValue.append(DraftFlow()) }
        }
    }

    private func parsedFlows(_ rows: [DraftFlow]) -> [(date: Date, amount: Decimal)]? {
        let entered = rows.filter { !$0.amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let parsed = entered.compactMap { flow -> (Date, Decimal)? in
            guard let amount = PrivateInput.amount(flow.amount), amount > 0 else { return nil }
            return (flow.date, amount)
        }
        return parsed.count == entered.count ? parsed : nil
    }

    private func netAssetValue(_ draft: DraftScenario) -> Decimal? {
        draft.nav.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : PrivateInput.amount(draft.nav)
    }

    private func projection(_ draft: DraftScenario) -> PrivateMath.FundScenario? {
        guard let date = draft.date, let called = parsedFlows(calls), let distributions = parsedFlows(draft.distributions),
              let remaining = netAssetValue(draft) else { return nil }
        return PrivateMath.fundScenario(calls: called, distributions: distributions, remainingValue: remaining, asOf: date)
    }

    private func inputError(_ draft: DraftScenario) -> String? {
        if netAssetValue(draft) == nil { return "Enter a nonnegative remaining value." }
        if parsedFlows(draft.distributions) == nil { return "Enter a positive amount for each distribution." }
        if draft.date != nil, parsedFlows(calls)?.isEmpty == false, projection(draft) == nil {
            return "Check the projection date and enter distributions on or after the first capital call."
        }
        return nil
    }

    private func metric(_ title: String, value: String, outcome: Outcome) -> some View {
        LabeledContent(title, value: value)
            .accessibilityIdentifier("private.fund.\(outcome.title.lowercased()).\(title.lowercased())")
    }
}
