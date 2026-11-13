import Supabase
import SwiftUI

struct HistoricalCashFX: Codable {
    let source: String
    let currency: String
    let amount: String
    let usd_per_unit: String
    let rate_date: String

    var details: String { "\(amount) \(currency) · \(usd_per_unit) USD per \(currency) · \(source) \(rate_date)" }
}

struct PerformanceFlow: Codable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case deposit, withdrawal

        var label: String {
            switch self {
            case .deposit: return "Deposit"
            case .withdrawal: return "Withdrawal"
            }
        }
    }

    var id = UUID()
    var date: String
    var kind: Kind
    var amount: Decimal
    var snaptrade_id: String?
    var fx: HistoricalCashFX?

    enum CodingKeys: String, CodingKey { case date, kind, amount, snaptrade_id, fx }
}

private struct PerformancePeriod: Decodable, Identifiable {
    let id: UUID
    let starts_on: String
    let ends_on: String
    let opening_value_usd: Decimal
    let closing_value_usd: Decimal
    let external_flows: [PerformanceFlow]
    let transfer_values_usd: [String: Decimal]?
    let deposits_usd: Decimal
    let withdrawals_usd: Decimal
    let investment_change_usd: Decimal
    let return_pct: Decimal?
    let time_weighted_return_pct: Decimal?
    let money_weighted_return_pct: Decimal?
}

private struct PerformancePeriodWrite: Encodable {
    let id: UUID
    let user_id: UUID
    let starts_on: String
    let ends_on: String
    let opening_value_usd: Decimal
    let closing_value_usd: Decimal
    let external_flows: [PerformanceFlow]
    let transfer_values_usd: [String: Decimal]
}

private struct PerformanceSummary: Decodable {
    let starts_on: String
    let ends_on: String
    let periods: Int
    let investment_change_usd: Decimal
    let return_pct: Decimal?
    let time_weighted_return_pct: Decimal?
    let money_weighted_return_pct: Decimal?
}

private func performanceDateFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}

struct PortfolioPerformanceLedger: View {
    let userId: UUID

    @AppStorage("portfolioValueHidden") private var valueHidden = false
    @Environment(\.theme) private var theme
    @State private var periods: [PerformancePeriod]?
    @State private var summary: PerformanceSummary?
    @State private var error: String?
    @State private var editor: Editor?
    @State private var removing: PerformancePeriod?

    private struct Editor: Identifiable {
        var id = UUID()
        let period: PerformancePeriod?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack {
                Text("Portfolio returns").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                if !valueHidden {
                    Button("Add period") { editor = Editor(period: nil) }
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("portfolio.returns.add")
                }
            }
            if valueHidden {
                Text("Balances are hidden.").font(.footnote).foregroundStyle(theme.secondaryText)
            } else if let error {
                Text(error).font(.footnote).foregroundStyle(theme.secondaryText)
                Button("Retry") { Task { await load() } }.frame(minHeight: 44)
            } else if let periods {
                if periods.isEmpty {
                    Text("Enter opening and closing values and external transfers from your account statements.")
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryText)
                } else {
                    Text("Time-weighted return uses transfer-day valuations. Money-weighted return uses the size and dates of transfers. All returns cover the displayed period.")
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryText)
                    if let summary, summary.periods > 1 {
                        Text("Latest continuous returns").font(.subheadline.weight(.semibold))
                        Text("\(summary.starts_on) to \(summary.ends_on) · \(summary.periods) periods")
                            .font(.caption).foregroundStyle(theme.secondaryText)
                        result("Investment change", summary.investment_change_usd.formatted(.currency(code: "USD")))
                        returnRows(summary.time_weighted_return_pct, summary.money_weighted_return_pct, summary.return_pct)
                    }
                    if periods.count > 100 {
                        Text("Showing the 100 most recent periods.").font(.caption)
                    }
                    ForEach(periods.prefix(100)) { period in
                        Divider()
                        periodRow(period)
                    }
                }
            } else {
                ProgressView("Loading portfolio returns")
            }
        }
        .padding(DS.Space.l)
        .frostedCard()
        .task(id: userId) { await load() }
        .sheet(item: $editor) { item in
            PerformancePeriodEditor(userId: userId, period: item.period) { await load() }
        }
        .confirmationDialog("Remove this period?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), presenting: removing) { period in
            Button("Remove period", role: .destructive) { Task { await remove(period.id) } }
        }
    }

    private func periodRow(_ period: PerformancePeriod) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack {
                Text("\(period.starts_on) to \(period.ends_on)").font(.subheadline.weight(.semibold))
                Spacer()
                Menu {
                    Button("Edit period") { editor = Editor(period: period) }
                    Button("Remove period", role: .destructive) { removing = period }
                } label: {
                    Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Options for period ending \(period.ends_on)")
            }
            result("Opening value", period.opening_value_usd.formatted(.currency(code: "USD")))
            result("Closing value", period.closing_value_usd.formatted(.currency(code: "USD")))
            result("Deposits", period.deposits_usd.formatted(.currency(code: "USD")))
            result("Withdrawals", period.withdrawals_usd.formatted(.currency(code: "USD")))
            result("Investment change", period.investment_change_usd.formatted(.currency(code: "USD")))
            returnRows(period.time_weighted_return_pct, period.money_weighted_return_pct, period.return_pct)
        }
    }

    @ViewBuilder
    private func returnRows(_ timeWeighted: Decimal?, _ moneyWeighted: Decimal?, _ dietz: Decimal?) -> some View {
        result("Time-weighted return", formattedReturn(timeWeighted))
        result("Money-weighted return", formattedReturn(moneyWeighted))
        result("Modified Dietz return", formattedReturn(dietz))
    }

    private func result(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(theme.secondaryText)
            Spacer(minLength: DS.Space.s)
            Text(value).monospacedDigit()
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }

    private func formattedReturn(_ value: Decimal?) -> String {
        value.map { ($0 / 100).formatted(.percent.precision(.fractionLength(2))) } ?? "Unavailable"
    }

    private func load() async {
        do {
            async let rows: [PerformancePeriod] = SupabaseManager.client.from("portfolio_performance_results")
                .select()
                .eq("user_id", value: userId.uuidString)
                .order("ends_on", ascending: false)
                .limit(101)
                .execute()
                .value
            async let summaries: [PerformanceSummary] = SupabaseManager.client.from("portfolio_performance_summary")
                .select("starts_on,ends_on,periods,investment_change_usd,return_pct,time_weighted_return_pct,money_weighted_return_pct")
                .eq("user_id", value: userId.uuidString)
                .execute()
                .value
            let (periodRows, summaryRows) = try await (rows, summaries)
            periods = periodRows
            summary = summaryRows.first
            error = nil
        } catch {
            self.error = "Couldn’t load portfolio returns."
        }
    }

    private func remove(_ id: UUID) async {
        do {
            try await SupabaseManager.client.from("portfolio_performance_periods")
                .delete().eq("user_id", value: userId.uuidString).eq("id", value: id.uuidString).execute()
            await load()
        } catch {
            self.error = "Couldn’t remove the period."
        }
    }
}

private struct PerformancePeriodEditor: View {
    private struct Transfer: Identifiable {
        var id = UUID()
        var date = Date()
        var kind = PerformanceFlow.Kind.deposit
        var amount = ""
        var snaptradeID: String?
        var fx: HistoricalCashFX?
    }

    let userId: UUID
    let onSave: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var id: UUID
    @State private var start: Date
    @State private var end: Date
    @State private var opening: String
    @State private var closing: String
    @State private var transfers: [Transfer]
    @State private var transferValues: [String: String]

    private var valuationDates: [String] {
        let formatter = performanceDateFormatter()
        let lower = formatter.string(from: start)
        let upper = formatter.string(from: end)
        return Set(transfers.map { formatter.string(from: $0.date) }.filter { $0 > lower && $0 < upper }).sorted()
    }
    @State private var saving = false
    @State private var error: String?

    init(userId: UUID, period: PerformancePeriod?, onSave: @escaping () async -> Void) {
        self.userId = userId
        self.onSave = onSave
        let formatter = performanceDateFormatter()
        _id = State(initialValue: period?.id ?? UUID())
        _start = State(initialValue: period.flatMap { formatter.date(from: $0.starts_on) } ??
            Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date())
        _end = State(initialValue: period.flatMap { formatter.date(from: $0.ends_on) } ?? Date())
        _opening = State(initialValue: period?.opening_value_usd.description ?? "")
        _closing = State(initialValue: period?.closing_value_usd.description ?? "")
        _transferValues = State(initialValue: period?.transfer_values_usd?.mapValues(\.description) ?? [:])
        _transfers = State(initialValue: period?.external_flows.compactMap { flow in
            guard let date = formatter.date(from: flow.date) else { return nil }
            return Transfer(date: date, kind: flow.kind, amount: flow.amount.description, snaptradeID: flow.snaptrade_id, fx: flow.fx)
        } ?? [])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Opening date", selection: $start, displayedComponents: .date)
                    TextField("Opening value (USD)", text: $opening).keyboardType(.decimalPad)
                        .accessibilityIdentifier("portfolio.returns.opening")
                    DatePicker("Closing date", selection: $end, displayedComponents: .date)
                    TextField("Closing value (USD)", text: $closing).keyboardType(.decimalPad)
                        .accessibilityIdentifier("portfolio.returns.closing")
                } footer: {
                    Text("Use end-of-day values for the same accounts, including cash. Convert balances and transfers to USD at their dates.")
                }
                let formatter = performanceDateFormatter()
                let startsOn = formatter.string(from: start)
                let endsOn = formatter.string(from: end)
                if startsOn < endsOn {
                    PortfolioBrokerActivity(userId: userId, start: startsOn, end: endsOn,
                        imported: Set(transfers.compactMap(\.snaptradeID)), canInclude: transfers.count < 366
                    ) { flow in
                        guard let date = formatter.date(from: flow.date), transfers.count < 366,
                              !transfers.contains(where: { $0.snaptradeID == flow.snaptrade_id }) else { return }
                        transfers.append(Transfer(date: date, kind: flow.kind, amount: flow.amount.description, snaptradeID: flow.snaptrade_id, fx: flow.fx))
                    }
                    .id("\(startsOn)/\(endsOn)")
                }
                Section {
                    ForEach($transfers) { $transfer in
                        if transfer.snaptradeID != nil {
                            Text("SnapTrade transfer").font(.caption).foregroundStyle(.secondary)
                        }
                        DatePicker("Transfer date", selection: $transfer.date, displayedComponents: .date)
                            .disabled(transfer.snaptradeID != nil)
                        Picker("Transfer type", selection: $transfer.kind) {
                            ForEach(PerformanceFlow.Kind.allCases, id: \.self) { kind in
                                Text(kind.label).tag(kind)
                            }
                        }
                        .disabled(transfer.snaptradeID != nil)
                        TextField("Transfer amount (USD)", text: $transfer.amount)
                            .keyboardType(.decimalPad)
                            .disabled(transfer.snaptradeID != nil)
                        if let fx = transfer.fx {
                            Text(fx.details).font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Remove transfer", role: .destructive) {
                            let id = transfer.id
                            transfers.removeAll { $0.id == id }
                        }
                    }
                    Button("Add transfer") { transfers.append(Transfer(date: end)) }.disabled(transfers.count >= 366)
                } header: {
                    Text("External transfers")
                } footer: {
                    Text("Purchases, sales, reinvested income and transfers between these accounts stay inside the portfolio.")
                }
                if !valuationDates.isEmpty {
                    Section {
                        ForEach(valuationDates, id: \.self) { date in
                            TextField("Value after transfers on \(date) (USD)", text: Binding(
                                get: { transferValues[date] ?? "" },
                                set: { transferValues[date] = $0 }
                            ))
                            .keyboardType(.decimalPad)
                        }
                    } header: {
                        Text("Transfer-day valuations")
                    } footer: {
                        Text("For time-weighted return, enter the total value including cash after all transfers on each date. The closing value covers transfers on the closing date.")
                    }
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .disabled(saving)
            .navigationTitle("Reconcile period")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }.disabled(saving)
                        .accessibilityIdentifier("portfolio.returns.save")
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    private func usd(_ input: String) -> Decimal? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^[0-9]+([.,][0-9]{1,2})?$"#, options: .regularExpression) != nil,
              let amount = Decimal(string: value.replacingOccurrences(of: ",", with: "."), locale: Locale(identifier: "en_US_POSIX")),
              amount <= Decimal(string: "9999999999999.99", locale: Locale(identifier: "en_US_POSIX"))! else { return nil }
        return amount
    }

    private func save() async {
        guard !saving else { return }
        error = nil
        let formatter = performanceDateFormatter()
        let startsOn = formatter.string(from: start)
        let endsOn = formatter.string(from: end)
        guard startsOn < endsOn, let openingValue = usd(opening), let closingValue = usd(closing) else {
            error = "Check the dates and enter opening and closing amounts in USD."
            return
        }
        var flows: [PerformanceFlow] = []
        for transfer in transfers {
            let date = formatter.string(from: transfer.date)
            guard date > startsOn, date <= endsOn, let amount = usd(transfer.amount), amount > 0 else {
                error = "Enter a positive amount and a date after opening and through closing for each transfer."
                return
            }
            flows.append(PerformanceFlow(date: date, kind: transfer.kind, amount: amount, snaptrade_id: transfer.snaptradeID, fx: transfer.fx))
        }
        var values: [String: Decimal] = [:]
        for date in valuationDates {
            guard let input = transferValues[date], !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard let value = usd(input) else {
                error = "Check the transfer-day valuations and enter amounts in USD."
                return
            }
            values[date] = value
        }
        let row = PerformancePeriodWrite(id: id, user_id: userId, starts_on: startsOn, ends_on: endsOn,
            opening_value_usd: openingValue, closing_value_usd: closingValue, external_flows: flows, transfer_values_usd: values)
        saving = true
        defer { saving = false }
        do {
            try await SupabaseManager.client.from("portfolio_performance_periods")
                .upsert(row, onConflict: "id").execute()
            await onSave()
            dismiss()
        } catch let failure as PostgrestError where failure.code == "23P01" {
            error = "This period overlaps an existing period. Edit that period or choose different dates."
        } catch {
            self.error = "Couldn’t save the period. Try again."
        }
    }
}
