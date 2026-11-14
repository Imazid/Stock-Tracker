import SwiftUI

struct PortfolioStockTransfers: View {
    let records: StockTransferRecords

    @Environment(\.dismiss) private var dismiss
    @AppStorage("portfolioValueHidden") private var hidesValues = false
    @State private var holdings: [StockTransferHolding] = []
    @State private var entries: [StockTransferEntry]?
    @State private var editor: Editor?
    @State private var removing: StockTransferEntry?
    @State private var finding = false
    @State private var loading = false
    @State private var writing = false
    @State private var problem: String?

    private struct Editor: Identifiable {
        let id = UUID()
        var entry: StockTransferEntry?
        var match: BrokerStockTransferMatch?
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Record transfer") { editor = Editor() }
                        .accessibilityIdentifier("portfolio.stockTransfers.add")
                    Button("Find transfers in linked accounts") { finding = true }
                        .accessibilityIdentifier("portfolio.stockTransfers.find")
                } footer: {
                    Text("Review both account statements. The web tax-lot CSV carries the original purchase dates, costs and fees between the holdings.")
                }
                .disabled(entries == nil || loading || writing)

                Section("Recorded transfers") {
                    if let entries, entries.isEmpty {
                        Text("No stock transfers recorded.").foregroundStyle(.secondary)
                    }
                    ForEach(entries ?? []) { entry in transferRow(entry) }
                    if loading { ProgressView("Loading stock transfers") }
                    if let problem {
                        Text(problem).foregroundStyle(.secondary)
                        Button("Refresh transfers") { Task { await load() } }
                    }
                }
            }
            .navigationTitle("Stock transfers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .refreshable { await load() }
            .task { await load() }
            .navigationDestination(isPresented: $finding) {
                BrokerStockTransferFinder(records: records, holdings: holdings, entries: entries ?? [], hidesValues: hidesValues) { match in
                    let prior = entries?.first {
                        $0.snaptrade_reference == nil && $0.from_holding_id == match.source.id &&
                        $0.to_holding_id == match.destination.id && $0.sent_on == match.reference.sentOn &&
                        $0.received_on == match.reference.receivedOn && Decimal(string: $0.shares, locale: .init(identifier: "en_US_POSIX")) ==
                            Decimal(string: match.reference.shares, locale: .init(identifier: "en_US_POSIX"))
                    }
                    editor = Editor(entry: prior, match: match)
                }
            }
            .sheet(item: $editor) { selection in
                StockTransferEditor(records: records, holdings: holdings, entries: entries ?? [], entry: selection.entry,
                                    match: selection.match) {
                    editor = nil
                    finding = false
                    await load()
                }
            }
            .confirmationDialog("Remove this stock transfer?", isPresented: Binding(
                get: { removing != nil }, set: { if !$0 { removing = nil } }
            ), presenting: removing) { entry in
                Button("Remove transfer", role: .destructive) { Task { await remove(entry) } }
            } message: { _ in
                Text("This changes the lot report for both holdings.")
            }
        }
    }

    private func transferRow(_ entry: StockTransferEntry) -> some View {
        let ticker = holdings.first(where: { $0.id == entry.from_holding_id })?.asset_symbol ?? "Stock"
        return Button { editor = Editor(entry: entry) } label: {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(hidesValues ? ticker : "\(ticker) · \(entry.shares) shares").font(.headline)
                Text("\(entry.from_account) → \(entry.to_account)")
                Text("\(entry.sent_on) → \(entry.received_on)")
                if entry.snaptrade_reference != nil { Text("SnapTrade reference attached") }
            }
            .font(.footnote)
            .foregroundStyle(.primary)
            .frame(minHeight: 44, alignment: .leading)
        }
        .disabled(writing || loading)
        .accessibilityIdentifier("portfolio.stockTransfers.entry.\(entry.id.uuidString.lowercased())")
        .swipeActions {
            Button("Remove", role: .destructive) { removing = entry }.disabled(writing)
        }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        problem = nil
        defer { loading = false }
        do {
            let ownedHoldings = try await records.holdings()
            let savedEntries = try await records.entries()
            try Task.checkCancellation()
            holdings = ownedHoldings
            entries = savedEntries
        } catch is CancellationError {
        } catch {
            problem = "Couldn’t load stock transfers. Refresh to try again."
        }
    }

    private func remove(_ entry: StockTransferEntry) async {
        guard !writing else { return }
        writing = true
        defer { writing = false }
        do {
            try await records.remove(entry)
            entries?.removeAll { $0.id == entry.id }
            await load()
        } catch let failure as StockTransferError {
            problem = failure.errorDescription
        } catch {
            problem = "Couldn’t remove the transfer. Try again."
        }
    }
}

private struct BrokerStockTransferFinder: View {
    let records: StockTransferRecords
    let holdings: [StockTransferHolding]
    let entries: [StockTransferEntry]
    let hidesValues: Bool
    let review: (BrokerStockTransferMatch) -> Void

    @State private var start = CashIncomeDay.calendar.date(byAdding: .day, value: -89, to: Date()) ?? Date()
    @State private var end = Date()
    @State private var searchId: UUID?
    @State private var matches: [BrokerStockTransferMatch] = []
    @State private var accounts: Int?
    @State private var searching = false
    @State private var problem: String?

    private var used: Set<String> {
        Set(entries.compactMap(\.snaptrade_reference).flatMap { [$0.sentId, $0.receivedId] })
    }

    var body: some View {
        List {
            Section {
                DatePicker("Broker activity from", selection: $start, in: CashIncomeDay.first...Date(), displayedComponents: .date)
                DatePicker("Broker activity through", selection: $end, in: CashIncomeDay.first...Date(), displayedComponents: .date)
                Button("Search broker activity") { searchId = UUID() }
                    .accessibilityIdentifier("portfolio.stockTransfers.search")
            } footer: {
                Text("Search for matching outgoing and incoming stock activity across your linked accounts.")
            }
            .disabled(searching)
            if searching { ProgressView("Checking linked accounts") }
            if let problem { Text(problem).foregroundStyle(.secondary) }
            if let accounts, matches.isEmpty {
                Text(accounts < 2 ? "Link both brokerage accounts to search for a pair."
                    : "No unambiguous pairs matched your synced holdings for these dates.")
                    .foregroundStyle(.secondary)
            }
            ForEach(matches) { match in
                let reference = match.reference
                let recorded = used.contains(reference.sentId) || used.contains(reference.receivedId)
                Button { review(match) } label: {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text(hidesValues ? reference.symbol : "\(reference.symbol) · \(reference.shares) shares").font(.headline)
                        Text("\(match.source.broker_account?.label ?? "") → \(match.destination.broker_account?.label ?? "")")
                        Text("Broker reported \(reference.sentOn) → \(reference.receivedOn)")
                        Text(recorded ? "Already recorded" : "Review match").font(.subheadline.weight(.semibold))
                    }
                    .font(.footnote)
                    .frame(minHeight: 44, alignment: .leading)
                }
                .disabled(recorded)
                .accessibilityIdentifier("portfolio.stockTransfers.match.\(reference.sentId)")
            }
        }
        .navigationTitle("Broker stock transfers")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.timeZone, CashIncomeDay.timeZone)
        .environment(\.calendar, CashIncomeDay.calendar)
        .onChange(of: start) { clearResults() }
        .onChange(of: end) { clearResults() }
        .task(id: searchId) {
            guard searchId != nil else { return }
            clearResults()
            searching = true
            defer { searching = false }
            do {
                let result = try await BrokerStockTransferSearch(userId: records.userId).search(from: start, through: end, holdings: holdings)
                try Task.checkCancellation()
                accounts = result.accounts
                matches = result.matches
            } catch is CancellationError {
            } catch let failure as StockTransferError {
                problem = failure.errorDescription
            } catch {
                problem = "Couldn’t check broker activity. Try again."
            }
        }
    }

    private func clearResults() {
        accounts = nil
        matches = []
        problem = nil
    }
}

private struct StockTransferEditor: View {
    let records: StockTransferRecords
    let holdings: [StockTransferHolding]
    let entries: [StockTransferEntry]
    let entry: StockTransferEntry?
    let reference: StockTransferBrokerReference?
    let onSave: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: StockTransferDraft
    @State private var confirmed: Bool
    @State private var snapshots: [StockTransferSnapshot]?
    @State private var snapshotFailed = false
    @State private var snapshotRetry = 0
    @State private var saving = false
    @State private var problem: String?
    private enum Field: Hashable { case sender, receiver, shares, order, statement }
    @FocusState private var focused: Field?

    init(records: StockTransferRecords, holdings: [StockTransferHolding], entries: [StockTransferEntry],
         entry: StockTransferEntry?, match: BrokerStockTransferMatch?, onSave: @escaping () async -> Void) {
        self.records = records
        self.holdings = holdings
        self.entries = entries
        self.entry = entry
        self.onSave = onSave
        reference = match?.reference ?? entry?.snaptrade_reference
        var draft = StockTransferDraft(entry: entry)
        if let match, entry == nil {
            draft.source = match.source.id
            draft.destination = match.destination.id
            draft.fromAccount = match.source.broker_account?.label ?? ""
            draft.toAccount = match.destination.broker_account?.label ?? ""
            draft.sent = CashIncomeDay.date(match.reference.sentOn) ?? Date()
            draft.received = CashIncomeDay.date(match.reference.receivedOn) ?? Date()
            draft.shares = match.reference.shares
        }
        if entry == nil { draft.order = Self.nextOrder(for: draft.sent, entries: entries) }
        _draft = State(initialValue: draft)
        _confirmed = State(initialValue: match == nil && entry?.snaptrade_reference != nil)
    }

    private var receivers: [StockTransferHolding] {
        guard let source = holdings.first(where: { $0.id == draft.source }) else { return [] }
        return holdings.filter { source.canSend(to: $0) }
    }

    private var matchingSnapshots: [StockTransferSnapshot] {
        let used = Set(entries.filter { $0.id != entry?.id }.compactMap(\.receiving_snapshot_id))
        return (snapshots ?? []).filter { !used.contains($0.id) && $0.matches(shares: draft.normalizedShares, received: draft.received) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Holdings") {
                    Picker("Sending holding", selection: $draft.source) {
                        Text("Choose holding").tag(UUID?.none)
                        ForEach(holdings) { Text($0.title).tag(Optional($0.id)) }
                    }
                    .accessibilityIdentifier("portfolio.stockTransfers.source")
                    .disabled(reference != nil)
                    Picker("Receiving holding", selection: $draft.destination) {
                        Text("Choose holding").tag(UUID?.none)
                        ForEach(receivers) { Text($0.title).tag(Optional($0.id)) }
                    }
                    .accessibilityIdentifier("portfolio.stockTransfers.destination")
                    .disabled(reference != nil || draft.source == nil)
                    if draft.source != nil && receivers.isEmpty {
                        Text("Choose a sending holding with a separate receiving holding for the same stock and exchange.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    TextField("Sending account label", text: $draft.fromAccount).focused($focused, equals: .sender)
                    TextField("Receiving account label", text: $draft.toAccount).focused($focused, equals: .receiver)
                }
                Section("Statement details") {
                    DatePicker("Shares sent (Sydney)", selection: $draft.sent, in: CashIncomeDay.first...Date(), displayedComponents: .date)
                    DatePicker("Shares received (Sydney)", selection: $draft.received, in: CashIncomeDay.first...Date(), displayedComponents: .date)
                    TextField("Shares transferred", text: $draft.shares)
                        .keyboardType(.decimalPad)
                        .focused($focused, equals: .shares)
                        .accessibilityIdentifier("portfolio.stockTransfers.shares")
                    TextField("Order on sending date", value: $draft.order, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                        .focused($focused, equals: .order)
                    TextField("Statement reference (optional)", text: $draft.statement)
                        .focused($focused, equals: .statement)
                        .accessibilityIdentifier("portfolio.stockTransfers.statement")
                }
                if draft.destination != nil { snapshotSection }
                if let reference {
                    Section("SnapTrade report") {
                        Text("\(reference.shares) shares of \(reference.symbol), sent \(reference.sentOn) and received \(reference.receivedOn).")
                        Toggle("I checked the holdings, dates and shares against both statements", isOn: $confirmed)
                            .accessibilityIdentifier("portfolio.stockTransfers.confirm")
                    }
                }
            }
            .disabled(saving)
            .navigationTitle(entry == nil ? "Record stock transfer" : "Edit stock transfer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(saving || (reference != nil && !confirmed))
                        .accessibilityIdentifier("portfolio.stockTransfers.save")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = nil }
                }
            }
            .onChange(of: draft.source) {
                draft.destination = nil
                draft.fromAccount = holdings.first { $0.id == draft.source }?.broker_account?.label ?? ""
            }
            .onChange(of: draft.destination) {
                draft.snapshot = nil
                draft.toAccount = holdings.first { $0.id == draft.destination }?.broker_account?.label ?? ""
            }
            .onChange(of: draft.sent) {
                confirmed = false
                draft.order = Self.nextOrder(for: draft.sent, entries: entries.filter { $0.id != entry?.id })
            }
            .onChange(of: draft.received) { confirmed = false; draft.snapshot = nil }
            .onChange(of: draft.shares) { confirmed = false; draft.snapshot = nil }
            .task(id: "\(draft.destination?.uuidString ?? "")/\(snapshotRetry)") {
                await loadSnapshots(for: draft.destination)
            }
            .interactiveDismissDisabled(saving)
            .alert("Couldn’t save transfer", isPresented: Binding(
                get: { problem != nil }, set: { if !$0 { problem = nil } }
            )) {
                Button("OK", role: .cancel) { problem = nil }
            } message: {
                Text(problem ?? "")
            }
        }
        .environment(\.timeZone, CashIncomeDay.timeZone)
        .environment(\.calendar, CashIncomeDay.calendar)
    }

    private var snapshotSection: some View {
        Section {
            Picker("Receiving position snapshot", selection: $draft.snapshot) {
                Text("None").tag(UUID?.none)
                ForEach(matchingSnapshots) { snapshot in
                    Text("\(snapshot.day ?? "Position snapshot") · \(snapshot.id.uuidString.prefix(8))")
                        .tag(Optional(snapshot.id))
                        .accessibilityIdentifier("portfolio.stockTransfers.snapshot.\(snapshot.id.uuidString.lowercased())")
                }
                if let id = draft.snapshot, !matchingSnapshots.contains(where: { $0.id == id }) {
                    Text("Previously selected snapshot").tag(Optional(id))
                }
            }
            .accessibilityIdentifier("portfolio.stockTransfers.snapshot")
            if snapshotFailed {
                Button("Retry receiving snapshots") { snapshotRetry += 1 }
            } else if snapshots == nil {
                ProgressView("Loading receiving snapshots")
            }
        } footer: {
            Text("Select a snapshot only if it represents these exact shares. The lot report uses the transferred lots in its place.")
        }
    }

    private func loadSnapshots(for destination: UUID?) async {
        snapshots = nil
        snapshotFailed = false
        guard let destination else { return }
        do {
            let result = try await records.snapshots(for: destination)
            try Task.checkCancellation()
            snapshots = result
        } catch is CancellationError {
        } catch {
            snapshotFailed = true
        }
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        problem = nil
        defer { saving = false }
        do {
            if reference != nil && !confirmed {
                throw StockTransferError.invalid("Check both statements before saving.")
            }
            let values = try draft.values(holdings: holdings, reference: reference)
            if let id = draft.snapshot, !matchingSnapshots.contains(where: { $0.id == id }) {
                throw StockTransferError.invalid("Choose a matching receiving snapshot or clear the selection.")
            }
            try await records.save(values, editing: entry)
            await onSave()
        } catch let failure as StockTransferError {
            problem = failure.errorDescription
        } catch {
            problem = "Try again when you’re connected."
        }
    }

    private static func nextOrder(for date: Date, entries: [StockTransferEntry]) -> Int {
        let day = CashIncomeDay.string(date)
        let used = Set(entries.filter { $0.sent_on == day }.map(\.same_day_order))
        return (1...999).first { !used.contains($0) } ?? 1000
    }
}
