import SwiftUI

struct PortfolioReinvestmentList: View {
    let records: ReinvestmentRecords
    let from: String?
    let through: String?
    let invalidRange: Bool
    let onSave: (String) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @State private var entries: [DividendReinvestment]?
    @State private var hasMore = false
    @State private var loadId: UUID?
    @State private var loading = false
    @State private var writing = false
    @State private var problem: String?
    @State private var editor: Editor?
    @State private var removing: DividendReinvestment?

    private struct Editor: Identifiable {
        let id = UUID()
        let entry: DividendReinvestment?
    }

    private let pageSize = 20
    private var rangeKey: String { "\(from ?? "")/\(through ?? "")" }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text("Record shares from your dividend statement when the acquisition is missing from synced purchases.")
                .font(.footnote).foregroundStyle(theme.secondaryText)
            if !invalidRange {
                if let entries {
                    if entries.isEmpty {
                        Text("No reinvestments in this date range.").font(.footnote).foregroundStyle(theme.secondaryText)
                    }
                    ForEach(entries) { entry in
                        Divider()
                        row(entry)
                    }
                    if hasMore {
                        Button("More reinvestments") { Task { await load(after: entries.last) } }
                            .frame(minHeight: 44).disabled(loading || writing)
                    }
                }
                if loading { ProgressView("Loading reinvestments").font(.footnote) }
            }
            if let problem { Text(problem).font(.footnote).foregroundStyle(theme.secondaryText) }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.m) { actions }
                VStack(alignment: .leading) { actions }
            }
        }
        .task(id: rangeKey) { await load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, entries != nil { Task { await load() } }
        }
        .sheet(item: $editor, onDismiss: { Task { await load() } }) { item in
            ReinvestmentEditor(records: records, entry: item.entry,
                               recorded: Set(entries?.compactMap(\.snaptrade_activity_id) ?? []), onSave: onSave)
        }
        .confirmationDialog("Remove this reinvestment?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), presenting: removing) { entry in
            Button("Remove reinvestment", role: .destructive) { Task { await remove(entry) } }
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Record reinvestment") { editor = Editor(entry: nil) }
            .frame(minHeight: 44).disabled(writing)
            .accessibilityIdentifier("portfolio.reinvestment.add")
        Button("Refresh reinvestments") { Task { await load() } }
            .frame(minHeight: 44).disabled(loading || writing || invalidRange)
    }

    private func row(_ entry: DividendReinvestment) -> some View {
        let title = entry.portfolio_holdings?.title ?? "Holding"
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(title).font(.subheadline.weight(.semibold))
                Text("\(entry.shares) shares · \(cashIncomeMoney(entry.reinvested_amount, entry.currency)) applied")
                    .font(.subheadline).monospacedDigit()
                Text("Paid \(entry.paid_on) · Acquired \(entry.acquired_on)")
                    .font(.caption).foregroundStyle(theme.secondaryText)
                if let source = entry.brokerReference {
                    Text(source.details).font(.caption).foregroundStyle(theme.secondaryText)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: DS.Space.s)
            Menu {
                Button("Edit reinvestment") { editor = Editor(entry: entry) }
                Button("Remove reinvestment", role: .destructive) { removing = entry }
            } label: {
                Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
            }
            .disabled(writing)
            .accessibilityLabel("Options for \(title) reinvestment paid on \(entry.paid_on)")
            .accessibilityIdentifier("portfolio.reinvestment.options.\(entry.id.uuidString.lowercased())")
        }
    }

    private func load(after: DividendReinvestment? = nil) async {
        let id = UUID()
        loadId = id
        problem = nil
        if after == nil { entries = nil }
        guard !invalidRange else {
            loading = false
            return
        }
        loading = true
        defer { if loadId == id { loading = false } }
        do {
            let page = try await records.page(from: from, through: through, after: after, limit: pageSize + 1)
            guard loadId == id, !Task.isCancelled else { return }
            let prior = entries ?? []
            let existing = Set(prior.map(\.id))
            entries = prior + page.prefix(pageSize).filter { !existing.contains($0.id) }
            hasMore = page.count > pageSize
        } catch {
            guard loadId == id, !Task.isCancelled else { return }
            problem = "Couldn’t load reinvestments. Refresh to try again."
        }
    }

    private func remove(_ entry: DividendReinvestment) async {
        guard !writing else { return }
        writing = true
        problem = nil
        defer { writing = false }
        do {
            try await records.remove(entry)
            await load()
        } catch let error as ReinvestmentError {
            problem = error.errorDescription
        } catch {
            problem = "Couldn’t remove the reinvestment. Try again."
        }
    }
}

private struct ReinvestmentEditor: View {
    let records: ReinvestmentRecords
    let entry: DividendReinvestment?
    let recorded: Set<String>
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ReinvestmentDraft
    @State private var source: BrokerReinvestment?
    @State private var lookup = false
    @State private var brokerStart = CashIncomeDay.calendar.date(byAdding: .day, value: -89, to: Date()) ?? Date()
    @State private var brokerEnd = Date()
    @State private var saving = false
    @State private var problem: String?
    @FocusState private var active: String?

    init(records: ReinvestmentRecords, entry: DividendReinvestment?, recorded: Set<String>,
         onSave: @escaping (String) -> Void) {
        self.records = records
        self.entry = entry
        self.recorded = recorded
        self.onSave = onSave
        _draft = State(initialValue: ReinvestmentDraft(entry: entry))
    }

    var body: some View {
        NavigationStack {
            Form {
                if let source = source ?? entry?.brokerReference {
                    Section("Broker reference") {
                        Text(source.details)
                        if self.source != nil {
                            Button("Clear broker reference") { self.source = nil }
                        }
                    }
                } else {
                    brokerLookup
                }
                Section("Statement dates") {
                    NavigationLink {
                        ReinvestmentHoldingPicker(records: records, selection: $draft.holding)
                    } label: {
                        LabeledContent("Stock holding", value: draft.holding?.title ?? "Choose")
                    }
                    .accessibilityIdentifier("portfolio.reinvestment.holding")
                    DatePicker("Dividend paid (Sydney)", selection: $draft.paid,
                               in: CashIncomeDay.first...Date(), displayedComponents: .date)
                    DatePicker("Shares acquired (Sydney)", selection: $draft.acquired,
                               in: CashIncomeDay.first...Date(), displayedComponents: .date)
                }
                Section("Dividend and shares") {
                    TextField("Payment currency", text: $draft.currency)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .focused($active, equals: "currency")
                        .accessibilityIdentifier("portfolio.reinvestment.currency")
                    amountField("Dividend amount", value: $draft.dividend, id: "dividend")
                    amountField("Amount applied to shares", value: $draft.reinvested, id: "reinvested")
                    amountField("Shares acquired", value: $draft.shares, id: "shares")
                }
                Section {
                    if draft.currencyCode != "USD" {
                        amountField("Acquisition basis in USD (optional)", value: $draft.basis, id: "basis")
                    }
                    amountField("Franking credit in AUD (optional)", value: $draft.credit, id: "credit")
                    TextField("Statement reference (optional)", text: $draft.reference)
                        .focused($active, equals: "reference")
                        .accessibilityIdentifier("portfolio.reinvestment.reference")
                } header: {
                    Text("Statement details")
                } footer: {
                    Text("The income export uses the payment date. The web lot report uses the acquisition date.")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let problem {
                    Text(problem).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                        .padding().background(.regularMaterial)
                        .accessibilityIdentifier("portfolio.reinvestment.error")
                }
            }
            .disabled(saving)
            .navigationTitle(entry == nil ? "Record reinvestment" : "Edit reinvestment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(saving)
                        .accessibilityIdentifier("portfolio.reinvestment.save")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { active = nil }.accessibilityIdentifier("portfolio.reinvestment.keyboardDone")
                }
            }
            .interactiveDismissDisabled(saving)
        }
        .environment(\.timeZone, CashIncomeDay.timeZone)
        .environment(\.calendar, CashIncomeDay.calendar)
    }

    @ViewBuilder
    private var brokerLookup: some View {
        Section {
            Button(lookup ? "Hide brokerage lookup" : "Find reinvestments in linked accounts") { lookup.toggle() }
                .accessibilityIdentifier("portfolio.reinvestment.brokerLookup")
            if lookup {
                DatePicker("First broker reinvestment date", selection: $brokerStart,
                           in: CashIncomeDay.first...Date(), displayedComponents: .date)
                DatePicker("Last broker reinvestment date", selection: $brokerEnd,
                           in: CashIncomeDay.first...Date(), displayedComponents: .date)
            }
        }
        if lookup {
            let start = CashIncomeDay.string(brokerStart)
            let end = CashIncomeDay.string(brokerEnd)
            if start <= end {
                PortfolioBrokerActivity(userId: records.userId, start: start, end: end, imported: recorded,
                                        reviewReinvestment: { event in
                    source = event
                    lookup = false
                })
                .id("\(start)/\(end)")
            } else {
                Text("Choose valid broker dates in chronological order.").font(.footnote)
            }
        }
    }

    private func amountField(_ title: String, value: Binding<String>, id: String) -> some View {
        TextField(title, text: value)
            .keyboardType(.decimalPad)
            .focused($active, equals: id)
            .accessibilityIdentifier("portfolio.reinvestment.\(id)")
    }

    private func save() async {
        guard !saving else { return }
        active = nil
        problem = nil
        saving = true
        defer { saving = false }
        do {
            try await records.save(draft, editing: entry, source: source)
            onSave(CashIncomeDay.string(draft.paid))
            dismiss()
        } catch let error as ReinvestmentError {
            problem = error.errorDescription
        } catch {
            problem = "Couldn’t save the reinvestment. Try again."
        }
    }
}

private struct ReinvestmentHoldingPicker: View {
    let records: ReinvestmentRecords
    @Binding var selection: ReinvestmentHolding?

    @Environment(\.dismiss) private var dismiss
    @State private var holdings: [ReinvestmentHolding]?
    @State private var search = ""
    @State private var failed = false

    var body: some View {
        List {
            if let holdings {
                if holdings.isEmpty {
                    ContentUnavailableView("No synced stock holdings", systemImage: "tray",
                                           description: Text("Sync a stock holding to record a reinvestment."))
                } else {
                    let matches = search.isEmpty ? holdings : holdings.filter {
                        $0.title.localizedStandardContains(search) || $0.asset_name.localizedStandardContains(search)
                    }
                    if matches.isEmpty { ContentUnavailableView.search(text: search) }
                    ForEach(matches) { holding in
                        Button {
                            selection = holding
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(holding.title)
                                    if holding.asset_name != holding.asset_symbol {
                                        Text(holding.asset_name).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if holding.id == selection?.id { Image(systemName: "checkmark").accessibilityHidden(true) }
                            }
                        }
                        .accessibilityAddTraits(holding.id == selection?.id ? .isSelected : [])
                        .accessibilityIdentifier("portfolio.reinvestment.holding.\(holding.id.uuidString.lowercased())")
                    }
                }
            } else if failed {
                Text("Couldn’t load stock holdings.")
                Button("Retry") { Task { await load() } }
            } else {
                ProgressView("Loading stock holdings")
            }
        }
        .navigationTitle("Stock holdings")
        .searchable(text: $search, prompt: "Search by ticker or name")
        .task { await load() }
    }

    private func load() async {
        failed = false
        do {
            holdings = try await records.holdings()
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}
