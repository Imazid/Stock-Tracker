import Supabase
import SwiftUI
import UniformTypeIdentifiers

struct PortfolioCashIncomeLedger: View {
    let userId: UUID

    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("portfolioValueHidden") private var valueHidden = false
    @State private var rows: [CashIncomePayment]?
    @State private var totals: [CashIncomeTotal] = []
    @State private var editor: Editor?
    @State private var removing: CashIncomePayment?
    @State private var section = SectionKind.cash
    @State private var filtered = false
    @State private var start = CashIncomeDay.calendar.date(byAdding: .year, value: -1, to: Date()) ?? Date()
    @State private var end = Date()
    @State private var problem: String?
    @State private var busy = false
    @State private var loadId: UUID?
    @State private var hasMore = false
    @State private var document: IncomeCSV?
    @State private var exporting = false
    @State private var preparingExport = false

    private enum SectionKind: String, CaseIterable {
        case cash = "Cash payments"
        case reinvestments = "Reinvestments"
    }

    private struct Editor: Identifiable {
        let id = UUID()
        let payment: CashIncomePayment?
    }

    private let pageSize = 20
    private var records: CashIncomeRecords { CashIncomeRecords(userId: userId) }
    private var first: String? { filtered ? CashIncomeDay.string(start) : nil }
    private var last: String? { filtered ? CashIncomeDay.string(end) : nil }
    private var rangeKey: String { "\(first ?? "")/\(last ?? "")" }
    private var invalidRange: Bool { filtered && CashIncomeDay.string(start) > CashIncomeDay.string(end) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack {
                Text("Dividends and distributions").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                if !valueHidden, section == .cash {
                    Button { Task { await load() } } label: {
                        Image(systemName: "arrow.clockwise").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Refresh cash income")
                    .disabled(busy)
                }
            }
            if valueHidden {
                Text("Balances are hidden.").font(.footnote).foregroundStyle(theme.secondaryText)
            } else {
                content
            }
        }
        .padding(DS.Space.l)
        .frostedCard()
        .environment(\.timeZone, CashIncomeDay.timeZone)
        .environment(\.calendar, CashIncomeDay.calendar)
        .task(id: "\(section.rawValue)/\(rangeKey)/\(valueHidden)") {
            if section == .cash, !valueHidden { await load() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, section == .cash, !valueHidden, rows != nil { Task { await load() } }
        }
        .sheet(item: $editor) { item in
            CashIncomeEditor(records: records, payment: item.payment, recorded: Set(rows?.compactMap(\.snaptrade_activity_id) ?? [])) {
                revealSavedDay($0)
                await load()
            }
        }
        .confirmationDialog("Remove this payment?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), presenting: removing) { payment in
            Button("Remove payment", role: .destructive) { Task { await remove(payment) } }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .commaSeparatedText,
                      defaultFilename: "stock-tracker-cash-income") { result in
            document = nil
            if case .failure = result { problem = "Couldn’t save the income CSV." }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Picker("Income records", selection: $section) {
                ForEach(SectionKind.allCases, id: \.self) { kind in Text(kind.rawValue).tag(kind) }
            }
            .pickerStyle(.segmented)
            Toggle("Filter by Sydney payment date", isOn: $filtered).font(.subheadline)
            if filtered {
                DatePicker("Payments from", selection: $start, in: CashIncomeDay.first...Date(), displayedComponents: .date)
                DatePicker("Payments through", selection: $end, in: CashIncomeDay.first...Date(), displayedComponents: .date)
            }
            if invalidRange {
                Text("Choose valid payment dates in chronological order.").font(.footnote).foregroundStyle(theme.secondaryText)
            }
            if section == .cash {
                if !invalidRange { cashPayments }
                Button("Record payment") { editor = Editor(payment: nil) }
                    .buttonStyle(.borderless)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("portfolio.cashIncome.add")
            } else {
                PortfolioReinvestmentList(records: ReinvestmentRecords(userId: userId), from: first, through: last,
                                          invalidRange: invalidRange, onSave: revealSavedDay)
            }
            if let problem { Text(problem).font(.footnote).foregroundStyle(theme.secondaryText) }
            Button("Export CSV") { Task { await export() } }
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
                .disabled(invalidRange || exporting || preparingExport)
                .accessibilityIdentifier("portfolio.cashIncome.export")
            if preparingExport { ProgressView("Preparing income CSV").font(.footnote) }
            Text(cashIncomeNotice).font(.caption).foregroundStyle(theme.secondaryText)
        }
    }

    @ViewBuilder
    private var cashPayments: some View {
        if let rows {
            if rows.isEmpty {
                Text("No recorded cash payments in this date range.").font(.footnote).foregroundStyle(theme.secondaryText)
            }
            ForEach(totals) { total in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(total.currency) cash received").font(.caption).foregroundStyle(theme.secondaryText)
                    Text(cashIncomeMoney(total.cash_received, total.currency))
                        .font(.title3.weight(.semibold)).monospacedDigit()
                        .accessibilityIdentifier("portfolio.cashIncome.total.\(total.currency)")
                    Text(total.payments == 1 ? "1 payment" : "\(total.payments) payments")
                        .font(.caption).foregroundStyle(theme.secondaryText)
                }
                .accessibilityElement(children: .contain)
            }
            ForEach(rows) { payment in
                Divider()
                paymentRow(payment)
            }
            if hasMore {
                Button("More payments") { Task { await load(after: rows.last) } }
                    .frame(minHeight: 44).disabled(busy)
            }
        }
        if busy { ProgressView("Loading cash income").font(.footnote) }
    }

    private func revealSavedDay(_ day: String) {
        if let first, day < first { filtered = false }
        if let last, day > last { filtered = false }
    }

    private func paymentRow(_ payment: CashIncomePayment) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(payment.payer).font(.subheadline.weight(.semibold))
                Text(cashIncomeMoney(payment.cash_received, payment.currency)).font(.subheadline).monospacedDigit()
                Text([payment.paid_on, payment.kind.title, payment.account_label,
                      payment.snaptrade_activity_id == nil ? "" : "SnapTrade reference"]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(theme.secondaryText)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: DS.Space.s)
            Menu {
                Button("Edit payment") { editor = Editor(payment: payment) }
                Button("Remove payment", role: .destructive) { removing = payment }
            } label: {
                Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Options for \(payment.payer) payment on \(payment.paid_on)")
            .accessibilityIdentifier("portfolio.cashIncome.options.\(payment.payer)")
        }
    }

    private func load(after: CashIncomePayment? = nil) async {
        let id = UUID()
        loadId = id
        guard !invalidRange else {
            busy = false
            return
        }
        let requested = rangeKey
        let from = first
        let through = last
        if after == nil { rows = nil }
        busy = true
        problem = nil
        defer { if loadId == id { busy = false } }
        do {
            let result: [CashIncomePayment]
            if let after {
                result = try await records.page(from: from, through: through, after: after, limit: pageSize + 1)
            } else {
                async let page = records.page(from: from, through: through, limit: pageSize + 1)
                async let summary = records.totals(from: from, through: through)
                let (payments, totals) = try await (page, summary)
                guard loadId == id, requested == rangeKey, !Task.isCancelled else { return }
                self.totals = totals
                result = payments
            }
            guard loadId == id, requested == rangeKey, !Task.isCancelled else { return }
            let prior = after == nil ? [] : (rows ?? [])
            let existing = Set(prior.map(\.id))
            rows = prior + result.prefix(pageSize).filter { !existing.contains($0.id) }
            hasMore = result.count > pageSize
        } catch {
            guard loadId == id, requested == rangeKey, !Task.isCancelled else { return }
            problem = "Couldn’t load cash income. Refresh to try again."
        }
    }

    private func remove(_ payment: CashIncomePayment) async {
        do {
            try await records.remove(payment)
            await load()
        } catch let error as CashIncomeError {
            problem = error.errorDescription
        } catch {
            problem = "Couldn’t remove the payment. Try again."
        }
    }

    private func export() async {
        guard !preparingExport else { return }
        preparingExport = true
        problem = nil
        defer { preparingExport = false }
        do {
            document = IncomeCSV(data: try await records.export(from: first, through: last))
            exporting = true
        } catch {
            problem = "Couldn’t prepare the income CSV. Try again."
        }
    }
}

private struct IncomeCSV: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText]
    let data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct CashIncomeEditor: View {
    let records: CashIncomeRecords
    let payment: CashIncomePayment?
    let recorded: Set<String>
    let onSave: (String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: CashIncomeDraft
    @State private var source: CashIncomeBrokerPayment?
    @State private var lookup = false
    @State private var brokerStart = CashIncomeDay.calendar.date(byAdding: .day, value: -89, to: Date()) ?? Date()
    @State private var brokerEnd = Date()
    @State private var busy = false
    @State private var problem: String?
    @FocusState private var active: String?

    init(records: CashIncomeRecords, payment: CashIncomePayment?, recorded: Set<String>, onSave: @escaping (String) async -> Void) {
        self.records = records
        self.payment = payment
        self.recorded = recorded
        self.onSave = onSave
        var draft = CashIncomeDraft()
        if let payment {
            draft.date = CashIncomeDay.date(payment.paid_on) ?? Date()
            draft.kind = payment.kind
            draft.payer = payment.payer
            draft.account = payment.account_label
            draft.currency = payment.currency
            draft.cash = payment.cash_received
            draft.gross = payment.gross_amount ?? ""
            draft.withheld = payment.withholding ?? ""
            draft.credit = payment.franking_credit_aud ?? ""
            draft.reference = payment.statement_reference
        }
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            Form {
                if payment == nil { brokerLookup }
                Section("Payment") {
                    DatePicker("Payment date (Sydney)", selection: $draft.date, in: CashIncomeDay.first...Date(), displayedComponents: .date)
                    Picker("Payment type", selection: $draft.kind) {
                        ForEach(CashIncomeKind.allCases, id: \.self) { kind in Text(kind.title).tag(kind) }
                    }
                    TextField("Payer or ticker", text: $draft.payer)
                        .focused($active, equals: "payer")
                        .accessibilityIdentifier("portfolio.cashIncome.payer")
                    TextField("Account label (optional)", text: $draft.account)
                        .focused($active, equals: "account")
                    TextField("Payment currency", text: $draft.currency)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .focused($active, equals: "currency")
                        .accessibilityIdentifier("portfolio.cashIncome.currency")
                    amountField("Cash received", value: $draft.cash, id: "cash")
                }
                Section {
                    amountField("Gross payment (optional)", value: $draft.gross, id: "gross")
                    amountField("Withholding (optional)", value: $draft.withheld, id: "withholding")
                    amountField("Franking credit in AUD (optional)", value: $draft.credit, id: "credit")
                    TextField("Statement reference (optional)", text: $draft.reference)
                        .focused($active, equals: "reference")
                } header: {
                    Text("Statement details")
                } footer: {
                    Text("Enter gross payment and withholding in the payment currency.")
                }
                if let source {
                    Section {
                        Text("SnapTrade reported \(cashIncomeMoney(source.amount, source.currency)) on \(source.date). Enter the cash received from your statement.")
                        Button("Clear broker reference") { self.source = nil }
                    }
                } else if let payment, let amount = payment.snaptrade_reported_amount,
                          let currency = payment.snaptrade_reported_currency, let date = payment.snaptrade_reported_on {
                    Section("Broker reference") {
                        Text("SnapTrade reported \(cashIncomeMoney(amount, currency)) on \(date).")
                    }
                }
                if let problem { Text(problem).foregroundStyle(.red).accessibilityIdentifier("portfolio.cashIncome.error") }
            }
            .disabled(busy)
            .navigationTitle(payment == nil ? "Record cash payment" : "Edit cash payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(busy)
                        .accessibilityIdentifier("portfolio.cashIncome.save")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { active = nil }.accessibilityIdentifier("portfolio.cashIncome.keyboardDone")
                }
            }
            .interactiveDismissDisabled(busy)
        }
        .environment(\.timeZone, CashIncomeDay.timeZone)
        .environment(\.calendar, CashIncomeDay.calendar)
    }

    @ViewBuilder
    private var brokerLookup: some View {
        Section {
            Button(lookup ? "Hide brokerage lookup" : "Find payments in linked accounts") { lookup.toggle() }
                .accessibilityIdentifier("portfolio.cashIncome.brokerLookup")
            if lookup {
                DatePicker("First broker payment date", selection: $brokerStart, in: CashIncomeDay.first...Date(), displayedComponents: .date)
                DatePicker("Last broker payment date", selection: $brokerEnd, in: CashIncomeDay.first...Date(), displayedComponents: .date)
            }
        }
        if lookup {
            let start = CashIncomeDay.string(brokerStart)
            let end = CashIncomeDay.string(brokerEnd)
            if start <= end {
                PortfolioBrokerActivity(userId: records.userId, start: start, end: end, imported: recorded,
                    canInclude: source == nil, selectedIncomeID: source?.id) { activity in
                    source = activity
                    if let date = CashIncomeDay.date(activity.date) { draft.date = date }
                    draft.kind = activity.kind
                    if draft.payer.isEmpty { draft.payer = activity.symbol ?? "" }
                    if draft.account.isEmpty { draft.account = activity.account }
                    if draft.cash.isEmpty { draft.currency = activity.currency }
                    lookup = false
                }
                .id("\(start)/\(end)")
            } else {
                Text("Choose valid broker payment dates in chronological order.").font(.footnote)
            }
        }
    }

    private func amountField(_ title: String, value: Binding<String>, id: String) -> some View {
        TextField(title, text: value)
            .keyboardType(.decimalPad)
            .focused($active, equals: id)
            .accessibilityIdentifier("portfolio.cashIncome.\(id)")
    }

    private func save() async {
        guard !busy else { return }
        active = nil
        problem = nil
        busy = true
        defer { busy = false }
        do {
            try await records.save(draft, editing: payment, source: source)
            await onSave(CashIncomeDay.string(draft.date))
            dismiss()
        } catch let error as CashIncomeError {
            problem = error.errorDescription
        } catch let error as PostgrestError where error.code == "23505" {
            problem = "This SnapTrade payment is already recorded."
        } catch {
            problem = "Couldn’t save the payment. Try again."
        }
    }
}
