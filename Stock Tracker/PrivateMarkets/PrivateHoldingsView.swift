import Charts
import SwiftUI
import TradingCore

enum PrivateInput {
    static func amount(_ text: String) -> Decimal? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator = Locale.current.decimalSeparator ?? "."
        let normalized = value.replacingOccurrences(of: separator, with: ".")
        guard normalized.range(of: #"^\d{1,15}(\.\d{1,8})?$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
    }

    static func accountAmount(_ value: String) -> String? {
        let separator = Locale.current.decimalSeparator ?? "."
        let normalized = value.replacingOccurrences(of: separator, with: ".")
        return normalized.range(of: #"^[0-9]{1,22}(\.[0-9]{1,16})?$"#, options: .regularExpression) == nil ? nil : normalized
    }

    static func money(_ value: Decimal?, currency: String) -> String {
        value?.formatted(.currency(code: currency)) ?? "Unavailable"
    }
}

struct PrivateHoldingsView: View {
    @EnvironmentObject private var auth: SupabaseAuthManager
    @EnvironmentObject private var store: PrivateMarketsStore
    @State private var add = false
    @State private var accountEditor: AccountHoldingEdit?


    var body: some View {
        List {
            UnifiedPrivateAllocation()
            Section("Self-reported holdings") {
                if store.state.holdings.isEmpty {
                    ContentUnavailableView("No self-reported holdings", systemImage: "briefcase",
                                           description: Text("Add a holding from your ownership records."))
                }
                ForEach(store.state.holdings) { holding in
                    let valuation = store.linkedFundValuation(for: holding)
                    NavigationLink {
                        PrivateHoldingDetail(id: holding.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(holding.name).font(.headline)
                            Text(holding.assetClass.rawValue + " · Self-reported")
                                .font(.footnote).foregroundStyle(.secondary)
                            if holding.matchingProviderHoldingID != nil {
                                Text("Linked to provider ownership").font(.footnote).foregroundStyle(.secondary)
                            } else if holding.closedOn() != nil {
                                Text("Exited · Self-reported").font(.subheadline)
                            } else if let mark = (valuation?.holding ?? holding).valuation() {
                                Text(PrivateInput.money(mark.value, currency: holding.currency) + (mark.isStale() ? " · Stale valuation" : " · Dated valuation"))
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(mark.isStale() ? Color.orange : Color.primary)
                                if valuation != nil {
                                    Text(PrivateFundSnapshot.source).font(.footnote).foregroundStyle(.secondary)
                                }
                            } else {
                                Text(holding.latestManualSale == nil ? "No carrying value recorded" : "Updated valuation needed")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("private.holding.row")
                }
                Button { add = true } label: { Label("Add private holding", systemImage: "plus") }
                    .accessibilityIdentifier("private.holding.add")
            }
            if let owner = auth.userId {
                Section("Account holdings") {
                    ForEach(store.accountHoldings) { record in
                        NavigationLink {
                            AccountPrivateHoldingDetail(owner: owner, id: record.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(record.name).font(.headline)
                                Text(record.assetClass.rawValue + " · Self-reported")
                                    .font(.footnote).foregroundStyle(.secondary)
                                if let closed = record.exitedOn {
                                    Text("Exited " + PrivateDeal.Round.Listing.formattedDay(closed))
                                        .font(.subheadline)
                                } else if let mark = record.holding.valuation() {
                                    Text(PrivateInput.money(mark.value, currency: record.currency) +
                                         (mark.isStale() ? " · Stale valuation" : " · Dated valuation"))
                                        .font(.subheadline.monospacedDigit())
                                }
                            }
                        }
                        .accessibilityIdentifier("private.holding.accountRow")
                    }
                    if let error = store.accountHoldingsError {
                        Text(error).foregroundStyle(.secondary)
                        Button("Refresh account holdings") { Task { await store.refreshAccountHoldings(for: owner) } }
                    } else if !store.hasLoadedAccountHoldings {
                        ProgressView("Loading account holdings")
                    }
                    Button {
                        accountEditor = .init(owner: owner, revision: store.accountHoldingsRevision, holding: nil)
                    } label: {
                        Label("Add account holding", systemImage: "plus")
                    }
                    .disabled(!store.hasLoadedAccountHoldings || store.accountHoldingsError != nil)
                    .accessibilityIdentifier("private.holding.accountAdd")
                    Text("Account holdings appear on the web and iPhone. Enter each position once.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !store.providerHoldings.isEmpty || store.providerError != nil || store.loadingProviderHoldings {
                Section("Provider-confirmed ownership") {
                    ForEach(store.providerHoldings) { position in
                        let holding = position.holding
                        NavigationLink {
                            PrivateHoldingDetail(id: position.id, providerRecord: true)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(holding.name).font(.headline)
                                Text(holding.assetClass.rawValue).font(.footnote).foregroundStyle(.secondary)
                                if position.commitment.connection?.revokedAt != nil {
                                    Text("Provider updates paused").font(.footnote).foregroundStyle(.orange)
                                }
                                if position.hasExited {
                                    Text("Exited · Provider confirmed").font(.subheadline)
                                } else if let mark = holding.valuation() {
                                    Text(PrivateInput.money(mark.value, currency: holding.currency) +
                                         (mark.isStale() ? " · Stale valuation" : " · Dated valuation"))
                                        .font(.subheadline.monospacedDigit())
                                        .foregroundStyle(mark.isStale() ? Color.orange : Color.primary)
                                } else {
                                    Text(position.dispositionRevisionAt == nil ? "Carrying value unavailable" : "Updated valuation needed")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("private.holding.providerRow")
                    }
                    if store.loadingProviderHoldings { ProgressView("Checking provider records") }
                    if let error = store.providerError { Text(error).foregroundStyle(.secondary) }
                }
            }
            if let owner = auth.userId {
                Section {
                    NavigationLink("Publish self-reported holdings to web") { PrivateManualPortfolioPublication(owner: owner) }
                        .accessibilityIdentifier("private.portfolio.publish")
                }
                Section("AngelList statements") {
                    ForEach(store.angelListSnapshots) { statement in
                        NavigationLink {
                            PrivateFundSnapshotDetail(id: statement.id, owner: owner)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(statement.name).font(.headline)
                                Text(statement.asOf.formatted(date: .abbreviated, time: .omitted))
                                    .font(.footnote).foregroundStyle(.secondary)
                                Text(PrivateInput.money(statement.netAssetValue, currency: statement.currency))
                                    .font(.subheadline.monospacedDigit())
                            }
                        }
                    }
                    NavigationLink("Read an AngelList capital account") { AngelListView() }
                        .accessibilityIdentifier("private.angellist.open")
                }
            }
            Section {
                NavigationLink {
                    PrivateMarketsExportView(owner: auth.userId)
                } label: {
                    Label("Export Private Markets", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("private.portfolio.export")
            }
        }
        .navigationTitle("My Private Portfolio")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $add) { PrivateHoldingEditor() }
        .sheet(item: $accountEditor) { edit in AccountPrivateHoldingEditor(edit: edit) }
        .onChange(of: auth.userId) { _, _ in accountEditor = nil }
        .task(id: auth.userId) { await refresh() }
        .refreshable { await refresh() }
    }

    private func refresh() async {
        if let owner = auth.userId { await store.refreshInvestmentHoldings(for: owner) }
    }
}

private struct AccountPrivateHoldingDetail: View {
    @EnvironmentObject private var auth: SupabaseAuthManager
    @EnvironmentObject private var store: PrivateMarketsStore
    @Environment(\.dismiss) private var dismiss
    let owner: UUID
    let id: UUID
    @State private var editor: AccountHoldingEdit?
    @State private var removal: AccountHoldingEdit?
    @State private var removing = false
    @State private var editError: String?
    @State private var markEditor: AccountValuationEdit?
    @State private var removeMark: AccountValuationEdit?
    @State private var updatingMark = false
    @State private var markError: String?
    @State private var opened: (owner: UUID, excerptID: UUID, text: String)?
    @State private var excerptError: String?

    var body: some View {
        if auth.userId == owner, let current = store.accountHoldings.first(where: { $0.id == id }) {
            List {
                Section("Ownership") {
                    Text(current.assetClass.rawValue + " · Self-reported")
                    LabeledContent("Currency", value: current.currency)
                    if let remaining = current.remainingUnits { LabeledContent("Remaining units", value: remaining) }
                    else if let units = current.units { LabeledContent("Shares or units", value: units) }
                    if let ownership = current.ownership {
                        LabeledContent(current.lastSaleOn == nil ? "Ownership" : "Opening ownership", value: ownership + "%")
                    }
                    if let commitment = current.commitment { LabeledContent("Committed capital", value: current.currency + " " + commitment) }
                    if let shareClass = current.shareClass { LabeledContent("Share class", value: shareClass) }
                    if let lockup = current.lockupUntil {
                        LabeledContent("Lock-up ends", value: PrivateDeal.Round.Listing.formattedDay(CashIncomeDay.string(lockup)))
                    }
                }
                if let exit = current.exitedOn {
                    Section("Exited position") {
                        LabeledContent("Carrying value", value: current.currency + " 0")
                        LabeledContent("Exit date", value: PrivateDeal.Round.Listing.formattedDay(exit))
                    }
                } else if let mark = current.valuation {
                    Section("Recorded valuation") {
                        LabeledContent("Carrying value", value: current.currency + " " + mark.value)
                        LabeledContent("Valuation date", value: PrivateDeal.Round.Listing.formattedDay(CashIncomeDay.string(mark.date)))
                        LabeledContent("Source", value: mark.source)
                        LabeledContent("Method", value: mark.method)
                    }
                } else if let sale = current.lastSaleOn {
                    Text("Add a valuation of the remaining position dated after " + PrivateDeal.Round.Listing.formattedDay(sale) + ".")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Valuation history") {
                    ForEach(current.marks) { mark in
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledContent(current.currency + " " + mark.value,
                                           value: PrivateDeal.Round.Listing.formattedDay(CashIncomeDay.string(mark.date)))
                            Text(mark.method + " · " + mark.source).font(.footnote).foregroundStyle(.secondary)
                            if mark.date == current.valuation?.date {
                                Text("Used for carrying value").font(.footnote).foregroundStyle(.secondary)
                            }
                            HStack {
                                Button("Edit valuation") {
                                    markEditor = .init(revision: store.accountHoldingsRevision, mark: mark)
                                }
                                Button("Remove valuation", role: .destructive) {
                                    removeMark = .init(revision: store.accountHoldingsRevision, mark: mark)
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("private.accountValuation.row")
                    }
                    Button("Add valuation") {
                        markEditor = .init(revision: store.accountHoldingsRevision, mark: nil)
                    }
                    .accessibilityIdentifier("private.accountValuation.add")
                    if let markError { Text(markError).foregroundStyle(.orange) }
                }
                .disabled(updatingMark || removing)
                NavigationLink("Cash flows and performance") {
                    AccountCashFlowView(owner: owner, holdingID: id)
                }
                .accessibilityIdentifier("private.accountCashFlow.open")
                if let evidence = current.ownershipEvidence {
                    let excerpt = opened?.owner == owner && opened?.excerptID == evidence.excerptID ? opened?.text : nil
                    Section("Reviewed ownership excerpt") {
                        Button(excerpt == nil ? "Open ownership excerpt" : "Close ownership excerpt") {
                            if excerpt != nil { opened = nil; return }
                            excerptError = nil
                            Task {
                                do {
                                    let response: PrivateMarketsAPI.DocumentExcerpt = try await PrivateMarketsAPI.request(
                                        "document", ["id": evidence.excerptID.uuidString], expectedUserID: owner)
                                    if auth.userId == owner { opened = (owner, evidence.excerptID, response.excerpt) }
                                } catch {
                                    if auth.userId == owner { excerptError = error.localizedDescription }
                                }
                            }
                        }
                        if let excerpt { Text(excerpt) }
                        if let excerptError { Text(excerptError).foregroundStyle(.secondary) }
                    }
                    .id(evidence.excerptID)
                }
                Section {
                    Button("Edit account holding") {
                        editor = .init(owner: owner, revision: store.accountHoldingsRevision, holding: current)
                    }
                    .disabled(removing)
                    .accessibilityIdentifier("private.holding.accountEdit")
                    Button("Remove account holding", role: .destructive) {
                        removal = .init(owner: owner, revision: store.accountHoldingsRevision, holding: current)
                    }
                    .disabled(removing)
                    .accessibilityIdentifier("private.holding.accountRemove")
                    if removing { ProgressView("Removing holding") }
                    if let editError { Text(editError).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(current.name)
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: current.ownershipEvidence?.excerptID) { _, _ in opened = nil; excerptError = nil }
            .sheet(item: $editor) { edit in AccountPrivateHoldingEditor(edit: edit) }
            .confirmationDialog("Remove this holding from your account?", isPresented: Binding(
                get: { removal != nil }, set: { if !$0 { removal = nil } }
            ), titleVisibility: .visible, presenting: removal) { edit in
                Button("Remove holding", role: .destructive) { Task { await remove(edit) } }
            }
            .sheet(item: $markEditor) { edit in
                AccountValuationEditor(owner: owner, holding: id, edit: edit, existingDates: current.marks.map(\.date))
            }
            .confirmationDialog("Remove this dated valuation?", isPresented: Binding(
                get: { removeMark != nil }, set: { if !$0 { removeMark = nil } }
            ), titleVisibility: .visible, presenting: removeMark) { edit in
                Button("Remove valuation", role: .destructive) { Task { await deleteValuation(edit) } }
            }
            .refreshable { await store.refreshAccountHoldings(for: owner) }
        } else {
            ContentUnavailableView("Holding unavailable", systemImage: "briefcase")
        }
    }
    private func deleteValuation(_ edit: AccountValuationEdit) async {
        guard auth.userId == owner, let mark = edit.mark, !updatingMark else { return }
        updatingMark = true
        markError = nil
        defer { updatingMark = false }
        do {
            try await store.removeAccountValuation(CashIncomeDay.string(mark.date) + "T00:00:00Z", holding: id,
                                                   owner: owner, revision: edit.revision)
        } catch is CancellationError {
        } catch let failure as SecureBackend.FunctionError where failure.code == "HOLDINGS_CHANGED" {
            await store.refreshAccountHoldings(for: owner)
            if auth.userId == owner { markError = failure.localizedDescription }
        } catch {
            if auth.userId == owner { markError = error.localizedDescription }
        }
    }

    private func remove(_ edit: AccountHoldingEdit) async {
        guard auth.userId == owner, !removing else { return }
        removing = true
        editError = nil
        defer { removing = false }
        do {
            try await store.removeAccountHolding(id, owner: owner, revision: edit.revision)
            if auth.userId == owner { dismiss() }
        } catch is CancellationError {
        } catch let failure as SecureBackend.FunctionError where failure.code == "HOLDINGS_CHANGED" {
            await store.refreshAccountHoldings(for: owner)
            if auth.userId == owner { editError = failure.localizedDescription }
        } catch {
            if auth.userId == owner { editError = error.localizedDescription }
        }
    }
}

private struct AccountCashFlowEdit: Identifiable {
    let id = UUID()
    let revision: UUID?
    var record: PrivateMarketsAPI.AccountHolding.CashFlow?
    var resolution: PrivateMarketsAPI.AccountHolding.CashFlow.Status?
}

private struct AccountCashFlowView: View {
    @EnvironmentObject private var auth: SupabaseAuthManager
    @EnvironmentObject private var store: PrivateMarketsStore
    let owner: UUID
    let holdingID: UUID
    @State private var editor: AccountCashFlowEdit?
    @State private var removal: AccountCashFlowEdit?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        if auth.userId == owner, let holding = store.accountHoldings.first(where: { $0.id == holdingID }) {
            List {
                records(holding)
            }
            .navigationTitle("Cash Flows & Performance")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(busy)
            .sheet(item: $editor) { edit in
                let units = store.accountHoldings.first { $0.id == holdingID }?.units
                AccountCashFlowEditor(owner: owner, holding: holdingID, hasOpeningUnits: units != nil, edit: edit)
            }
            .confirmationDialog("Remove this cash flow?", isPresented: Binding(
                get: { removal != nil }, set: { if !$0 { removal = nil } }
            ), titleVisibility: .visible, presenting: removal) { edit in
                Button("Remove cash flow", role: .destructive) { Task { await remove(edit) } }
            }
            .refreshable { await store.refreshAccountHoldings(for: owner) }
        } else {
            ContentUnavailableView("Holding unavailable", systemImage: "briefcase")
        }
    }

    @ViewBuilder
    private func records(_ holding: PrivateMarketsAPI.AccountHolding) -> some View {
        Section("Cash flows") {
            ForEach(holding.activity.sorted { $0.date > $1.date }) { flow in
                VStack(alignment: .leading, spacing: 6) {
                    AccountCashFlowLabel(flow: flow, currency: holding.currency)
                    HStack {
                        Button("Edit") { open(flow) }
                        if flow.status == .pending {
                            Button("Record payment") { open(flow, as: .paid) }
                            Button("Cancel call") { open(flow, as: .cancelled) }
                        }
                        Button("Remove", role: .destructive) {
                            removal = .init(revision: store.accountHoldingsRevision, record: flow)
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button("Add cash flow") { open() }.accessibilityIdentifier("private.accountCashFlow.add")
            if let error { Text(error).foregroundStyle(.orange) }
        }
        if !holding.activity.isEmpty {
            let metrics = holding.holding.metrics()
            Section("Performance") {
                if let paid = holding.paid { LabeledContent("Capital deployed", value: holding.currency + " " + paid) }
                if let returned = holding.returned { LabeledContent("Distributions", value: holding.currency + " " + returned) }
                if let proceeds = holding.saleProceeds { LabeledContent("Net sale proceeds", value: holding.currency + " " + proceeds) }
                if let pending = holding.pendingCalls { LabeledContent("Pending calls", value: holding.currency + " " + pending) }
                performanceAmounts(metrics, holding: holding)
                if let multiple = metrics.multiple {
                    let showsTVPI = holding.assetClass.isFund && holding.sales?.isEmpty != false
                    LabeledContent(showsTVPI ? "TVPI" : "MOIC", value: multiple.formatted(.number.precision(.fractionLength(2))) + "×")
                } else {
                    Text("Valuation-based returns require deployed capital and a valuation dated on or after all settled flows.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let dpi = metrics.dpi {
                    LabeledContent("DPI", value: dpi.formatted(.number.precision(.fractionLength(2))) + "×")
                }
                if let xirr = metrics.xirr { LabeledContent("XIRR", value: xirr.formatted(.percent.precision(.fractionLength(2)))) }
            }
        }
    }

    @ViewBuilder
    private func performanceAmounts(_ metrics: PrivateMetrics, holding: PrivateMarketsAPI.AccountHolding) -> some View {
        let format = Decimal.FormatStyle.Currency(code: holding.currency)
        if let gain = metrics.netGain { LabeledContent("Total gain or loss", value: gain.formatted(format)) }
        if let realised = metrics.realizedGain { LabeledContent("Realised gain on sales", value: realised.formatted(format)) }
        if holding.sales?.isEmpty == false, let unrealised = metrics.unrealizedGain {
            LabeledContent("Unrealised gain", value: unrealised.formatted(format))
        }
    }

    private func open(_ record: PrivateMarketsAPI.AccountHolding.CashFlow? = nil,
                      as resolution: PrivateMarketsAPI.AccountHolding.CashFlow.Status? = nil) {
        error = nil
        editor = .init(revision: store.accountHoldingsRevision, record: record, resolution: resolution)
    }

    private func remove(_ edit: AccountCashFlowEdit) async {
        guard auth.userId == owner, let record = edit.record, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await store.removeAccountCashFlow(record.id, holding: holdingID, owner: owner, revision: edit.revision)
        } catch is CancellationError {
        } catch let failure as SecureBackend.FunctionError where failure.code == "HOLDINGS_CHANGED" {
            await store.refreshAccountHoldings(for: owner)
            if auth.userId == owner { error = failure.localizedDescription }
        } catch {
            if auth.userId == owner { self.error = error.localizedDescription }
        }
    }
}

private struct AccountCashFlowLabel: View {
    let flow: PrivateMarketsAPI.AccountHolding.CashFlow
    let currency: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(flow.status.title, value: currency + " " + flow.amount)
            Text(PrivateDeal.Round.Listing.formattedDay(flow.date) + " · " + (flow.resolutionSource ?? flow.source))
            if let due = flow.dueOn {
                Text("Originally due " + PrivateDeal.Round.Listing.formattedDay(due) + " · " + flow.source)
            }
            if let units = flow.soldUnits { Text(units + " units sold") }
            if flow.closesPosition == true { Text("Entire remaining position sold") }
            if let basis = flow.disposedCost { Text("Cost basis " + currency + " " + basis) }
        }
        .font(.subheadline)
    }
}

private struct AccountCashFlowEditor: View {
    typealias Status = PrivateMarketsAPI.AccountHolding.CashFlow.Status
    @EnvironmentObject private var auth: SupabaseAuthManager
    @EnvironmentObject private var store: PrivateMarketsStore
    @Environment(\.dismiss) private var dismiss
    let owner: UUID
    let holding: UUID
    let hasOpeningUnits: Bool
    let edit: AccountCashFlowEdit
    @State private var status: Status
    @State private var amount: String
    @State private var date: Date
    @State private var source: String
    @State private var soldUnits: String
    @State private var basis: String
    @State private var closesPosition: Bool
    @State private var error: String?
    @State private var saving = false
    @State private var changed = false

    init(owner: UUID, holding: UUID, hasOpeningUnits: Bool, edit: AccountCashFlowEdit) {
        self.owner = owner
        self.holding = holding
        self.hasOpeningUnits = hasOpeningUnits
        self.edit = edit
        let record = edit.record
        let status = edit.resolution ?? record?.status ?? .contribution
        _status = State(initialValue: status)
        _amount = State(initialValue: record?.amount ?? "")
        _date = State(initialValue: edit.resolution == nil ? record.flatMap { CashIncomeDay.date($0.date) } ?? .now : .now)
        _source = State(initialValue: status.isResolution ? record?.resolutionSource ?? "" : record?.source ?? "")
        _soldUnits = State(initialValue: record?.soldUnits ?? "")
        _basis = State(initialValue: record?.disposedCost ?? "")
        _closesPosition = State(initialValue: record?.closesPosition == true || !hasOpeningUnits)
    }

    var body: some View {
        NavigationStack {
            Form {
                if edit.record == nil {
                    Picker("Cash flow type", selection: $status) {
                        ForEach([Status.contribution, .pending, .distribution, .sale], id: \.self) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier("private.accountCashFlow.type")
                }
                if status.isResolution, let record = edit.record {
                    Text("Original notice " + (record.dueOn ?? record.date) + " · " + record.source)
                } else {
                    TextField(status == .sale ? "Net sale proceeds" : "Cash flow amount", text: $amount).keyboardType(.decimalPad)
                        .accessibilityIdentifier("private.accountCashFlow.amount")
                }
                if status == .sale {
                    Toggle("Sold the entire remaining position", isOn: $closesPosition).disabled(!hasOpeningUnits)
                        .accessibilityIdentifier("private.accountCashFlow.closePosition")
                    if !closesPosition {
                        TextField("Units sold", text: $soldUnits).keyboardType(.decimalPad)
                            .accessibilityIdentifier("private.accountCashFlow.soldUnits")
                    }
                    TextField("Cost basis of units sold (optional)", text: $basis).keyboardType(.decimalPad)
                        .accessibilityIdentifier("private.accountCashFlow.basis")
                }
                if status == .pending {
                    DatePicker("Due date", selection: $date, displayedComponents: .date)
                        .environment(\.timeZone, CashIncomeDay.timeZone)
                } else {
                    DatePicker(status.isResolution ? "Resolution date" : status == .sale ? "Settlement date" : "Cash flow date", selection: $date,
                               in: ...Date.now, displayedComponents: .date)
                        .environment(\.timeZone, CashIncomeDay.timeZone)
                }
                TextField(status.isResolution ? "Resolution source" : "Cash flow source", text: $source)
                    .accessibilityIdentifier("private.accountCashFlow.source")
                if let error { Text(error).foregroundStyle(.orange) }
            }
            .disabled(saving || auth.userId != owner)
            .navigationTitle(edit.record == nil ? "Add Cash Flow" : status.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving || changed || auth.userId != owner)
                        .accessibilityIdentifier("private.accountCashFlow.save")
                }
            }
            .interactiveDismissDisabled(saving)
            .onChange(of: auth.userId) { _, _ in if auth.userId != owner { dismiss() } }
        }
    }

    private func save() async {
        guard auth.userId == owner, !saving, !changed else { return }
        let note = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let day = CashIncomeDay.string(date)
        guard let amount = PrivateInput.accountAmount(amount.trimmingCharacters(in: .whitespacesAndNewlines)),
              status == .sale || amount.range(of: "[1-9]", options: .regularExpression) != nil,
              !note.isEmpty, note.utf16.count <= 400, status == .pending || day <= CashIncomeDay.string(.now) else {
            error = status == .sale ? "Enter net proceeds, a valid settlement date and a source."
                : "Enter a positive amount, a valid date and a source."
            return
        }
        var fields: [String: Any] = ["id": (edit.record?.id ?? edit.id).uuidString, "status": status.rawValue, "amount": amount,
                      "date": day, "source": note]
        if status.isResolution, let record = edit.record {
            fields["source"] = record.source
            fields["dueOn"] = record.dueOn ?? record.date
            fields["resolutionSource"] = note
        }
        if status == .sale {
            let cost = basis.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cost.isEmpty {
                guard let parsed = PrivateInput.accountAmount(cost) else {
                    error = "Enter a valid cost basis if known."
                    return
                }
                fields["disposedCost"] = parsed
            }
            if closesPosition {
                fields["closesPosition"] = true
            } else {
                guard let units = PrivateInput.accountAmount(soldUnits.trimmingCharacters(in: .whitespacesAndNewlines)),
                      units.range(of: "[1-9]", options: .regularExpression) != nil else {
                    error = "Enter the positive number of units sold."
                    return
                }
                fields["soldUnits"] = units
            }
        }
        saving = true
        error = nil
        defer { saving = false }
        do {
            try await store.saveAccountCashFlow(fields, holding: holding, owner: owner, revision: edit.revision)
            if auth.userId == owner { dismiss() }
        } catch is CancellationError {
        } catch let failure as SecureBackend.FunctionError where failure.code == "HOLDINGS_CHANGED" {
            await store.refreshAccountHoldings(for: owner)
            if auth.userId == owner {
                changed = true
                error = failure.localizedDescription + " Close this editor and reopen the latest entry."
            }
        } catch {
            if auth.userId == owner { self.error = error.localizedDescription }
        }
    }
}

private struct AccountValuationEdit: Identifiable {
    let id = UUID()
    let revision: UUID?
    let mark: PrivateMarketsAPI.AccountHolding.Mark?
}

private struct AccountValuationEditor: View {
    @EnvironmentObject private var auth: SupabaseAuthManager
    @EnvironmentObject private var store: PrivateMarketsStore
    @Environment(\.dismiss) private var dismiss
    let owner: UUID
    let holding: UUID
    let edit: AccountValuationEdit
    let existingDates: [Date]
    @State private var date: Date
    @State private var value: String
    @State private var source: String
    @State private var method: String
    @State private var error: String?
    @State private var changed = false
    @State private var saving = false

    init(owner: UUID, holding: UUID, edit: AccountValuationEdit, existingDates: [Date]) {
        self.owner = owner
        self.holding = holding
        self.edit = edit
        self.existingDates = existingDates
        _date = State(initialValue: edit.mark?.date ?? .now)
        _value = State(initialValue: edit.mark?.value ?? "")
        _source = State(initialValue: edit.mark?.source ?? "")
        _method = State(initialValue: edit.mark?.method ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Valuation date", selection: $date, in: ...Date.now, displayedComponents: .date)
                    .environment(\.timeZone, CashIncomeDay.timeZone)
                    .disabled(edit.mark != nil)
                TextField("Carrying value", text: $value).keyboardType(.decimalPad)
                    .accessibilityIdentifier("private.accountValuation.value")
                TextField("Valuation source", text: $source)
                    .accessibilityIdentifier("private.accountValuation.source")
                TextField("Valuation method", text: $method)
                    .accessibilityIdentifier("private.accountValuation.method")
                if let error { Text(error).foregroundStyle(.orange) }
            }
            .disabled(saving || auth.userId != owner)
            .navigationTitle(edit.mark == nil ? "Add Valuation" : "Edit Valuation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving || changed || auth.userId != owner)
                        .accessibilityIdentifier("private.accountValuation.save")
                }
            }
            .interactiveDismissDisabled(saving)
            .onChange(of: auth.userId) { _, _ in if auth.userId != owner { dismiss() } }
        }
    }

    private func save() async {
        guard auth.userId == owner, !saving, !changed else { return }
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let method = method.trimmingCharacters(in: .whitespacesAndNewlines)
        let day = CashIncomeDay.string(date)
        guard let amount = PrivateInput.accountAmount(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              !source.isEmpty, source.utf16.count <= 400, !method.isEmpty, method.utf16.count <= 400,
              day <= CashIncomeDay.string(.now) else {
            error = "Enter an amount, a date through today, a source and a method."
            return
        }
        if edit.mark == nil && existingDates.contains(where: { CashIncomeDay.string($0) == day }) {
            error = "A valuation already exists for this date. Use Edit valuation to correct it."
            return
        }
        saving = true
        error = nil
        defer { saving = false }
        do {
            try await store.saveAccountValuation(["value": amount, "date": day + "T00:00:00Z", "source": source, "method": method],
                                                 holding: holding, owner: owner, revision: edit.revision)
            if auth.userId == owner { dismiss() }
        } catch is CancellationError {
        } catch let failure as SecureBackend.FunctionError where failure.code == "HOLDINGS_CHANGED" {
            await store.refreshAccountHoldings(for: owner)
            if auth.userId == owner {
                changed = true
                error = failure.localizedDescription + " Close this editor and reopen the latest valuation."
            }
        } catch {
            if auth.userId == owner { self.error = error.localizedDescription }
        }
    }
}

private struct AccountHoldingEdit: Identifiable {
    let id = UUID()
    let owner: UUID
    let revision: UUID?
    let holding: PrivateMarketsAPI.AccountHolding?
}

private struct AccountPrivateHoldingEditor: View {
    @EnvironmentObject private var auth: SupabaseAuthManager
    @EnvironmentObject private var store: PrivateMarketsStore
    @Environment(\.dismiss) private var dismiss
    let edit: AccountHoldingEdit
    @State private var name: String
    @State private var assetClass: PrivateAssetClass
    @State private var currency: String
    @State private var units: String
    @State private var ownership: String
    @State private var commitment: String
    @State private var shareClass: String
    @State private var lockup: Date?
    @State private var markDate: Date
    @State private var markValue: String
    @State private var markSource: String
    @State private var markMethod: String
    @State private var includesMark: Bool
    @State private var excerptID: UUID?
    @State private var documents: [PrivateMarketsAPI.DocumentSummary] = []
    @State private var evidenceRead: (id: UUID, text: String)?
    @State private var reviewed = false
    @State private var evidenceError: String?
    @State private var error: String?
    @State private var changed = false
    @State private var saving = false

    init(edit: AccountHoldingEdit) {
        self.edit = edit
        let holding = edit.holding
        _name = State(initialValue: holding?.name ?? "")
        _assetClass = State(initialValue: holding?.assetClass ?? .startupEquity)
        _currency = State(initialValue: holding?.currency ?? "AUD")
        _units = State(initialValue: holding?.units ?? "")
        _ownership = State(initialValue: holding?.ownership ?? "")
        _commitment = State(initialValue: holding?.commitment ?? "")
        _shareClass = State(initialValue: holding?.shareClass ?? "")
        _lockup = State(initialValue: holding?.lockupUntil)
        _markDate = State(initialValue: holding?.valuation?.date ?? .now)
        _markValue = State(initialValue: holding?.valuation?.value ?? "")
        _markSource = State(initialValue: holding?.valuation?.source ?? "")
        _markMethod = State(initialValue: holding?.valuation?.method ?? "")
        _includesMark = State(initialValue: holding?.valuation != nil)
        _excerptID = State(initialValue: holding?.ownershipEvidence?.excerptID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Holding") {
                    TextField("Company or fund name", text: $name)
                        .accessibilityIdentifier("private.accountHolding.name")
                    Picker("Asset class", selection: $assetClass) {
                        ForEach(PrivateAssetClass.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    TextField("Currency", text: $currency)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .disabled(edit.holding.map { !$0.marks.isEmpty || !$0.activity.isEmpty } ?? false)
                    TextField("Shares or units", text: $units).keyboardType(.decimalPad)
                    TextField("Ownership percentage", text: $ownership).keyboardType(.decimalPad)
                    TextField("Committed capital", text: $commitment).keyboardType(.decimalPad)
                    TextField("Share class", text: $shareClass)
                    Toggle("Has a lock-up date", isOn: Binding(
                        get: { lockup != nil }, set: { lockup = $0 ? .now : nil }
                    ))
                    if lockup != nil {
                        DatePicker("Lock-up ends", selection: Binding(
                            get: { lockup ?? .now }, set: { lockup = $0 }
                        ), displayedComponents: .date)
                        .environment(\.timeZone, CashIncomeDay.timeZone)
                    }
                }
                Section("Dated valuation") {
                    Toggle("Include a valuation", isOn: $includesMark)
                        .accessibilityIdentifier("private.accountHolding.includeMark")
                        .disabled(edit.holding?.valuation != nil)
                    if edit.holding?.valuation != nil {
                        Text("A new valuation date keeps earlier values. Remove recorded values from Valuation history.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if includesMark {
                        TextField("Carrying value", text: $markValue).keyboardType(.decimalPad)
                            .accessibilityIdentifier("private.accountHolding.value")
                        DatePicker("Valuation date", selection: $markDate, in: ...Date.now, displayedComponents: .date)
                            .environment(\.timeZone, CashIncomeDay.timeZone)
                        TextField("Valuation source", text: $markSource)
                            .accessibilityIdentifier("private.accountHolding.source")
                        TextField("Valuation method", text: $markMethod)
                            .accessibilityIdentifier("private.accountHolding.method")
                    }
                }
                Section("Deal Room") {
                    Picker("Ownership excerpt", selection: $excerptID) {
                        Text("None").tag(nil as UUID?)
                        ForEach(documents) { Text($0.title).tag(Optional($0.id)) }
                        if let excerptID, !documents.contains(where: { $0.id == excerptID }) {
                            Text("Previously linked excerpt").tag(Optional(excerptID))
                        }
                    }
                    if let excerptID {
                        if let evidenceRead, evidenceRead.id == excerptID {
                            Text(evidenceRead.text).textSelection(.enabled)
                            Toggle("I reviewed the selected excerpt", isOn: $reviewed)
                        } else {
                            Button("Read ownership excerpt") { Task { await openExcerpt(excerptID) } }
                        }
                    }
                    if let evidenceError { Text(evidenceError).foregroundStyle(.secondary) }
                }
                if let error { Text(error).foregroundStyle(.orange) }
                if changed {
                    Button("Refresh holdings and close editor") {
                        Task {
                            await store.refreshAccountHoldings(for: edit.owner)
                            dismiss()
                        }
                    }
                }
            }
            .disabled(saving || auth.userId != edit.owner)
            .navigationTitle(edit.holding == nil ? "Add Account Holding" : "Edit Account Holding")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving || changed || auth.userId != edit.owner)
                        .accessibilityIdentifier("private.accountHolding.save")
                }
            }
            .interactiveDismissDisabled(saving)
            .task {
                do {
                    let result: PrivateMarketsAPI.DocumentList = try await PrivateMarketsAPI.request("documents", expectedUserID: edit.owner)
                    if auth.userId == edit.owner, !Task.isCancelled { documents = result.items }
                } catch is CancellationError {
                } catch {
                    if auth.userId == edit.owner { evidenceError = error.localizedDescription }
                }
            }
            .onChange(of: excerptID) { _, _ in reviewed = false; evidenceRead = nil; evidenceError = nil }
            .onChange(of: auth.userId) { _, _ in if auth.userId != edit.owner { dismiss() } }
        }
    }

    private func openExcerpt(_ id: UUID) async {
        evidenceError = nil
        do {
            let result: PrivateMarketsAPI.DocumentExcerpt = try await PrivateMarketsAPI.request(
                "document", ["id": id.uuidString], expectedUserID: edit.owner)
            guard auth.userId == edit.owner, excerptID == id else { return }
            evidenceRead = (id, result.excerpt)
        } catch is CancellationError {
        } catch {
            if auth.userId == edit.owner, excerptID == id { evidenceError = error.localizedDescription }
        }
    }

    private func save() async {
        guard auth.userId == edit.owner, !saving && !changed else { return }
        let name = clean(name)
        let currency = clean(currency).uppercased()
        let shareClass = clean(shareClass)
        let amounts = [("units", clean(units)), ("ownership", clean(ownership)), ("commitment", clean(commitment))]
        guard !name.isEmpty, name.utf16.count <= 160, shareClass.utf16.count <= 160,
              currency.range(of: #"^[A-Z]{3}$"#, options: .regularExpression) != nil,
              amounts.allSatisfy({ $0.1.isEmpty || parse($0.1) != nil }),
              (parse(clean(ownership)).flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) } ?? 0) <= 100 else {
            error = "Enter a name, a three-letter currency and valid amounts. Ownership must be between zero and 100 percent."
            return
        }
        if excerptID != nil && (!reviewed || evidenceRead?.id != excerptID) {
            error = "Review the selected ownership excerpt or remove its link before saving."
            return
        }
        var fields: [String: Any] = [
            "id": edit.holding?.id.uuidString ?? edit.id.uuidString, "name": name,
            "assetClass": assetClass.rawValue, "currency": currency,
        ]
        for (key, value) in amounts {
            if let number = parse(value) { fields[key] = number }
        }
        if !shareClass.isEmpty { fields["shareClass"] = shareClass }
        if let lockup { fields["lockupUntil"] = CashIncomeDay.string(lockup) + "T00:00:00Z" }
        if let excerptID { fields["excerptID"] = excerptID.uuidString }
        if includesMark {
            let source = clean(markSource)
            let method = clean(markMethod)
            guard let amount = parse(clean(markValue)), !source.isEmpty, source.utf16.count <= 400,
                  !method.isEmpty, method.utf16.count <= 400,
                  CashIncomeDay.string(markDate) <= CashIncomeDay.string(.now) else {
                error = "A valuation needs an amount, a date through today, a source and a method."
                return
            }
            fields["valuation"] = ["value": amount,
                                   "date": CashIncomeDay.string(markDate) + "T00:00:00Z",
                                   "source": source, "method": method]
        }
        error = nil
        saving = true
        defer { saving = false }
        do {
            try await store.saveAccountHolding(fields, owner: edit.owner, revision: edit.revision)
            if auth.userId == edit.owner { dismiss() }
        } catch is CancellationError {
        } catch let failure as SecureBackend.FunctionError where failure.code == "HOLDINGS_CHANGED" {
            changed = true
            error = failure.localizedDescription
        } catch {
            if auth.userId == edit.owner { self.error = error.localizedDescription }
        }
    }

    private func clean(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func parse(_ value: String) -> String? { PrivateInput.accountAmount(value) }
}

private struct PrivateManualPortfolioPublication: View {
    private struct Remote: Decodable {
        struct Snapshot: Decodable { let updatedAt: Date }
        let revision: UUID?
        let snapshot: Snapshot?
    }

    let owner: UUID
    @EnvironmentObject private var auth: SupabaseAuthManager
    @EnvironmentObject private var store: PrivateMarketsStore
    @State private var remote: Remote?
    @State private var busy = false
    @State private var includeOwnershipEvidence = false
    @State private var includeCapitalActivity = false
    @State private var confirmPublish = false
    @State private var confirmRemoval = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Text("Publish a dated view of your self-reported holdings to your signed-in web portfolio. Publish again after changes to update the web copy.")
                Text("The encrypted snapshot includes holding names, ownership, manually recorded values and sources, and calculated performance.")
                    .font(.footnote).foregroundStyle(.secondary)
                if store.independentManualHoldings.contains(where: { $0.ownershipEvidenceID != nil && $0.ownershipReviewedOn != nil }) {
                    Toggle("Include reviewed ownership excerpt links", isOn: $includeOwnershipEvidence)
                        .accessibilityIdentifier("private.portfolio.publish.evidence")
                        .disabled(busy)
                    Text("The web portfolio can open linked excerpts already saved in your Deal Room.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if store.independentManualHoldings.contains(where: { holding in
                    holding.cashFlows.contains { $0.kind != .contribution }
                }) {
                    Toggle("Include capital activity", isOn: $includeCapitalActivity)
                        .accessibilityIdentifier("private.portfolio.publish.capital")
                        .disabled(busy)
                    Text("Capital calls, distributions and sales will appear on the web with their dates, amounts and source notes.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let published = remote?.snapshot?.updatedAt {
                    LabeledContent("Last published", value: published.formatted(date: .abbreviated, time: .shortened))
                }
            }
            Section {
                Button("Publish current holdings") { confirmPublish = true }
                    .disabled(busy || remote == nil || store.independentManualHoldings.isEmpty)
                    .accessibilityIdentifier("private.portfolio.publish.current")
                if remote?.snapshot != nil {
                    Button("Remove web snapshot", role: .destructive) { confirmRemoval = true }
                        .disabled(busy)
                }
                Button("Refresh web status") { Task { await load() } }.disabled(busy)
                if busy { ProgressView("Contacting Stock Tracker") }
                if let error { Text(error).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Publish Portfolio")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .confirmationDialog("Publish these holdings to your web portfolio?", isPresented: $confirmPublish, titleVisibility: .visible) {
            Button("Publish to web") { Task { await write(removing: false) } }
        } message: {
            Text("This replaces any existing web snapshot for this account. Linked provider positions and imported AngelList data stay in their original records.")
        }
        .confirmationDialog("Remove this snapshot from the web?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Remove web snapshot", role: .destructive) { Task { await write(removing: true) } }
        }
    }

    private func readRemote() async throws -> Remote {
        try await PrivateMarketsAPI.request("manual_portfolio", expectedUserID: owner)
    }

    private func load() async {
        guard !busy, auth.userId == owner else { return }
        busy = true
        defer { busy = false }
        error = nil
        do {
            let response = try await readRemote()
            try Task.checkCancellation()
            if auth.userId == owner { remote = response }
        } catch is CancellationError {
        } catch { if auth.userId == owner { self.error = error.localizedDescription } }
    }

    private func write(removing: Bool) async {
        guard !busy, auth.userId == owner, let remote else { return }
        busy = true
        defer { busy = false }
        error = nil
        do {
            var fields: [String: Any] = ["expected_revision": remote.revision.map { $0.uuidString as Any } ?? NSNull()]
            if !removing {
                let ledger = try store.exportDeviceRecords(for: owner)
                let date = Date.now
                let holdings = ledger.holdings.filter { $0.matchingProviderHoldingID == nil }
                guard (1...150).contains(holdings.count) else {
                    error = "A web snapshot can contain between 1 and 150 holdings."
                    return
                }
                let publishedHoldings = holdings.map { snapshot($0, asOf: date) }
                if includeCapitalActivity, try JSONSerialization.data(withJSONObject: publishedHoldings).count > 110_000 {
                    error = "This snapshot is too large. Turn off Include capital activity to publish holdings and balances."
                    return
                }
                fields["holdings"] = publishedHoldings
            }
            try await PrivateMarketsAPI.send(removing ? "remove_manual_portfolio" : "save_manual_portfolio",
                                             fields, expectedUserID: owner)
            let response = try await readRemote()
            try Task.checkCancellation()
            if auth.userId == owner { self.remote = response }
        } catch is CancellationError {
        } catch let failure as SecureBackend.FunctionError where failure.code == "PORTFOLIO_CHANGED" {
            if auth.userId == owner {
                self.remote = nil
                error = failure.localizedDescription
            }
        } catch { if auth.userId == owner { self.error = error.localizedDescription } }
    }

    private func snapshot(_ holding: PrivateHolding, asOf: Date) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        func number(_ value: Decimal) -> String {
            var amount = value
            var rounded = Decimal()
            NSDecimalRound(&rounded, &amount, 16, .plain)
            return NSDecimalNumber(decimal: rounded).stringValue
        }
        let metrics = holding.metrics(asOf: asOf)
        var fields: [String: Any] = [
            "id": holding.id.uuidString, "name": holding.name, "assetClass": holding.assetClass.rawValue,
            "currency": holding.currency, "paid": number(metrics.paid), "returned": number(metrics.returned),
            "pendingCalls": number(metrics.pendingCalls),
        ]
        fields["units"] = holding.remainingUnits(asOf: asOf).map(number)
        fields["ownership"] = holding.latestManualSale == nil ? holding.ownershipPercent.map(number) : nil
        fields["shareClass"] = holding.shareClass.isEmpty ? nil : holding.shareClass
        if includeOwnershipEvidence, let excerptID = holding.ownershipEvidenceID,
           let reviewedOn = holding.ownershipReviewedOn, reviewedOn <= asOf {
            fields["ownershipEvidence"] = ["excerptID": excerptID.uuidString, "reviewedOn": iso.string(from: reviewedOn)]
        }
        if includeCapitalActivity {
            let localDay = ISO8601DateFormatter()
            localDay.formatOptions = [.withFullDate]
            localDay.timeZone = .current
            fields["capitalActivity"] = holding.cashFlows.compactMap { flow -> [String: String]? in
                let dueDate = flow.originalDueDate ?? flow.date
                var activity = ["id": flow.id.uuidString, "amount": number(flow.amount), "source": flow.source]
                switch flow.kind {
                case .contribution:
                    return nil
                case .capitalCall:
                    if let cancellation = flow.cancellation, cancellation.date <= asOf {
                        activity["status"] = "cancelled"
                        activity["date"] = localDay.string(from: cancellation.date)
                        activity["resolutionSource"] = cancellation.source
                        activity["dueOn"] = localDay.string(from: dueDate)
                    } else if flow.isPendingCapitalCall(asOf: asOf) {
                        activity["status"] = "pending"
                        activity["date"] = localDay.string(from: dueDate)
                    } else {
                        activity["status"] = "paid"
                        activity["date"] = localDay.string(from: flow.paymentEvidence?.date ?? flow.date)
                        activity["resolutionSource"] = flow.paymentEvidence?.source
                        activity["dueOn"] = flow.originalDueDate.map(localDay.string(from:))
                    }
                case .distribution, .sale:
                    guard flow.settled, flow.date <= asOf else { return nil }
                    activity["status"] = flow.kind == .distribution ? "distribution" : "sale"
                    activity["date"] = localDay.string(from: flow.date)
                }
                return activity
            }
        }
        fields["lockupUntil"] = holding.lockupUntil.map(iso.string(from:))
        fields["commitment"] = holding.commitment.map(number)
        fields["exitedOn"] = holding.closedOn(asOf: asOf).map(iso.string(from:))
        fields["netGain"] = metrics.netGain.map(number)
        fields["realizedGain"] = metrics.realizedGain.map(number)
        fields["unrealizedGain"] = metrics.unrealizedGain.map(number)
        fields["multiple"] = metrics.multiple.map(number)
        fields["dpi"] = metrics.dpi.map(number)
        if let rate = metrics.xirr {
            fields["xirr"] = String(format: "%.12f", locale: Locale(identifier: "en_US_POSIX"), rate)
        }
        if let mark = holding.valuation(asOf: asOf) {
            fields["valuation"] = ["value": number(mark.value), "date": iso.string(from: mark.date),
                                   "source": mark.source, "method": mark.method]
        }
        return fields
    }
}

private struct PrivateFundSnapshotDetail: View {
    @EnvironmentObject private var auth: SupabaseAuthManager
    @EnvironmentObject private var store: PrivateMarketsStore
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    let owner: UUID
    @State private var showRemove = false
    @State private var editPlacement = false
    @State private var error: String?

    var body: some View {
        if auth.userId == owner, let statement = store.angelListSnapshots.first(where: { $0.id == id }) {
            let linked = store.state.holdings.first { $0.id == statement.replacesManualHoldingID }
            let usesStatement = linked.flatMap { store.linkedFundValuation(for: $0)?.statement.id } == statement.id
            List {
                Section("Statement") {
                    Text(PrivateFundSnapshot.source + " · User-reviewed")
                        .font(.footnote).foregroundStyle(.secondary)
                    LabeledContent("Statement date", value: statement.asOf.formatted(date: .abbreviated, time: .omitted))
                    LabeledContent("Retrieved", value: statement.retrievedAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Capital account ID", value: statement.reference)
                    LabeledContent("Investment type", value: statement.assetClass.rawValue)
                    LabeledContent("Currency", value: statement.currency)
                }
                Section("Reported balances") {
                    balance("Net asset value", statement.netAssetValue, statement.currency)
                    balance("Capital committed", statement.commitment, statement.currency)
                    balance("Paid-in capital", statement.paidIn, statement.currency)
                    balance("Distributions received", statement.distributions, statement.currency)
                    if statement.allocationHolding.valuation()?.isStale() == true {
                        Label("Stale valuation", systemImage: "clock.badge.exclamationmark").foregroundStyle(Color.orange)
                    }
                    Text("Return metrics require dated contributions, distributions and valuations.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Portfolio allocation") {
                    if let linked {
                        NavigationLink(linked.name) { PrivateHoldingDetail(id: linked.id) }
                        if usesStatement {
                            Text("This NAV is used for the holding’s carrying value.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } else if statement.replacesManualHoldingID != nil {
                        Text("The linked holding was removed. This statement is kept in your history.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text(statement.placement == .history ? "Statement history only" : "Separate portfolio position")
                            .accessibilityIdentifier("private.statement.placementStatus")
                    }
                    Button("Change allocation") { editPlacement = true }
                        .accessibilityIdentifier("private.statement.changePlacement")
                }
                Button("Remove statement", role: .destructive) { showRemove = true }
                if let error { Text(error).foregroundStyle(.orange) }
            }
            .navigationTitle(statement.name)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $editPlacement) { PrivateFundPlacementEditor(statement: statement, owner: owner) }
            .confirmationDialog("Remove this saved statement?", isPresented: $showRemove, titleVisibility: .visible) {
                Button("Remove statement", role: .destructive) {
                    do {
                        try store.removeAngelListSnapshot(id, owner: owner)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
            }
        } else {
            ContentUnavailableView("Statement unavailable", systemImage: "doc.text")
        }
    }

    private func balance(_ title: String, _ value: Decimal?, _ currency: String) -> some View {
        LabeledContent(title, value: PrivateInput.money(value, currency: currency))
    }
}

private struct PrivateFundPlacementEditor: View {
    @EnvironmentObject private var auth: SupabaseAuthManager
    @EnvironmentObject private var store: PrivateMarketsStore
    @Environment(\.dismiss) private var dismiss
    let statement: PrivateFundSnapshot
    let owner: UUID
    @State private var selection: PrivateFundSnapshot.Placement
    @State private var error: String?

    init(statement: PrivateFundSnapshot, owner: UUID) {
        self.statement = statement
        self.owner = owner
        _selection = State(initialValue: statement.placement)
    }

    var body: some View {
        NavigationStack {
            let holdings = store.eligibleFundHoldings(currency: statement.currency, excludingReference: statement.reference)
            Form {
                Picker("Use this statement", selection: $selection) {
                    Text("Statement history only").tag(PrivateFundSnapshot.Placement.history)
                    Text("Separate portfolio position").tag(PrivateFundSnapshot.Placement.standalone)
                    ForEach(holdings) { holding in
                        Text(holding.name).tag(PrivateFundSnapshot.Placement.linked(holding.id))
                    }
                    if case let .linked(id) = selection, !holdings.contains(where: { $0.id == id }) {
                        Text("Current holding unavailable").tag(PrivateFundSnapshot.Placement.linked(id))
                    }
                }
                .pickerStyle(.inline)
                Text("Choose a holding for the same investment, track this as a separate position, or retain only the statement.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.orange) }
            }
            .navigationTitle("Statement Allocation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(auth.userId != owner || selection == statement.placement)
                        .accessibilityIdentifier("private.statement.savePlacement")
                }
            }
        }
        .onChange(of: auth.userId) { _, _ in dismiss() }
    }

    private func save() {
        guard auth.userId == owner else { return }
        do {
            try store.setAngelListPlacement(selection, for: statement.id, owner: owner)
            dismiss()
        } catch is CancellationError {
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct UnifiedPrivateAllocation: View {
    @EnvironmentObject private var store: PrivateMarketsStore
    @EnvironmentObject private var market: MarketData
    @AppStorage("portfolioValueHidden") private var hide = false

    private struct Slice: Identifiable {
        let id: String
        let usd: Double
    }

    private var breakdown: (slices: [Slice], listedExcluded: Int, privateExcluded: Int, includesStaleMark: Bool) {
        var values: [String: Double] = [:]
        var listedExcluded = 0
        var privateExcluded = 0
        var includesStaleMark = false
        for holding in market.allTrackedHoldings where holding.shares > 0 {
            guard let value = market.pricedPositionValue(holding) else {
                listedExcluded += 1
                continue
            }
            let category: String
            if holding.asset.kind == .crypto {
                category = "Crypto"
            } else if holding.asset.isListedETF {
                category = "ETFs"
            } else {
                category = "Listed equities"
            }
            values[category, default: 0] += value
        }
        for holding in store.allocationHoldings {
            guard let mark = holding.valuation(), let rate = market.verifiedFXRates[holding.currency] else {
                privateExcluded += 1
                continue
            }
            let value = NSDecimalNumber(decimal: mark.value).doubleValue / rate
            guard value.isFinite, value >= 0 else {
                privateExcluded += 1
                continue
            }
            guard value > 0 else { continue }
            values[holding.assetClass.rawValue, default: 0] += value
            includesStaleMark = includesStaleMark || mark.isStale()
        }
        var slices = values.map { Slice(id: $0.key, usd: $0.value) }
        slices.sort { left, right in
            if left.usd == right.usd { return left.id < right.id }
            return left.usd > right.usd
        }
        return (slices, listedExcluded, privateExcluded, includesStaleMark)
    }

    var body: some View {
        let snapshot = breakdown
        let allocation = snapshot.slices
        let total = allocation.reduce(0) { $0 + $1.usd }
        let code = market.verifiedFXRates[market.preferredCurrency] != nil ? market.preferredCurrency : "USD"
        let fx = market.verifiedFXRates[code] ?? 1
        let displayedTotal = total * fx
        VStack(alignment: .leading, spacing: 12) {
            Text("Unified allocation").font(.headline).accessibilityAddTraits(.isHeader)
            Text("All tracked listed portfolios and this private portfolio. Private values use dated marks.")
                .font(.footnote).foregroundStyle(.secondary)
            if hide {
                Text("Portfolio values are hidden.").font(.footnote).foregroundStyle(.secondary)
            } else if total <= 0 || !displayedTotal.isFinite {
                Text("Allocation appears when holdings have a supported value.").font(.footnote).foregroundStyle(.secondary)
            } else {
                allocationChart(allocation, total: total, displayedTotal: displayedTotal.formatted(.currency(code: code)))
            }
            if snapshot.listedExcluded > 0 {
                Text("Listed positions excluded for an unavailable quote: \(snapshot.listedExcluded)")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if snapshot.privateExcluded > 0 {
                Text("Private positions excluded for a missing valuation or verified FX rate: \(snapshot.privateExcluded)")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if store.accountHoldingsError != nil {
                Text("Account holdings could not be refreshed. Showing the last available values.")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if store.unavailableLinkedProviderCount > 0 {
                Text("Some linked provider positions are unavailable and excluded from allocation.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if snapshot.includesStaleMark {
                Label("Includes stale valuations where a conversion is available.", systemImage: "clock.badge.exclamationmark")
                    .font(.footnote).foregroundStyle(Color.orange)
            }
        }
        .padding(.vertical, 8)
        .accessibilityIdentifier("private.allocation")
    }

    @ViewBuilder
    private func allocationChart(_ slices: [Slice], total: Double, displayedTotal: String) -> some View {
        Text(displayedTotal)
            .font(.title2.weight(.semibold).monospacedDigit())
            .accessibilityIdentifier("private.allocation.total")
        Chart(slices) { slice in
            SectorMark(angle: .value("Value in USD", slice.usd), innerRadius: .ratio(0.72), angularInset: 2)
                .cornerRadius(4)
                .foregroundStyle(by: .value("Asset class", slice.id))
        }
        .chartForegroundStyleScale(range: [Color.blue, .cyan, .purple, .mint, .orange, .pink, .teal, .indigo, .yellow])
        .chartLegend(.hidden)
        .frame(height: 118)
        .accessibilityHidden(true)
        ForEach(slices) { slice in
            let percentage = (slice.usd / total).formatted(.percent.precision(.fractionLength(1)))
            LabeledContent(slice.id, value: percentage)
                .font(.subheadline)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("private.allocation.slice.\(slice.id)")
        }
    }
}

private struct PrivateHoldingEditor: View {
    @EnvironmentObject private var store: PrivateMarketsStore
    @Environment(\.dismiss) private var dismiss
    let holding: PrivateHolding?
    @State private var name: String
    @State private var kind: PrivateAssetClass
    @State private var currency: String
    @State private var commitment: String
    @State private var units: String
    @State private var ownership: String
    @State private var shareClass: String
    @State private var catalogueCompanyID: UUID?
    @State private var companies: [PrivateDeal.Company] = []
    @State private var catalogueError: String?
    @State private var locked: Bool
    @State private var lockup: Date
    @State private var error: String?

    init(holding: PrivateHolding? = nil) {
        self.holding = holding
        _name = State(initialValue: holding?.name ?? "")
        _kind = State(initialValue: holding?.assetClass ?? .startupEquity)
        _currency = State(initialValue: holding?.currency ?? "AUD")
        func text(_ value: Decimal?) -> String { value?.formatted(.number.grouping(.never).precision(.fractionLength(0...8))) ?? "" }
        _commitment = State(initialValue: text(holding?.commitment))
        _units = State(initialValue: text(holding?.units))
        _ownership = State(initialValue: text(holding?.ownershipPercent))
        _shareClass = State(initialValue: holding?.shareClass ?? "")
        _catalogueCompanyID = State(initialValue: holding?.catalogueCompanyID)
        _locked = State(initialValue: holding?.lockupUntil != nil)
        _lockup = State(initialValue: holding?.lockupUntil ?? .now)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Holding") {
                    TextField("Company or fund name", text: $name).accessibilityIdentifier("private.holding.name")
                    Picker("Asset class", selection: $kind) {
                        ForEach(PrivateAssetClass.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Currency", selection: $currency) {
                        ForEach(Array(Set(MarketData.supportedCurrencies + ["NZD", currency])).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    .accessibilityIdentifier("private.holding.currency")
                    .disabled(holding.map { !$0.valuations.isEmpty || !$0.cashFlows.isEmpty } ?? false)
                }
                Section("Ownership") {
                    TextField("Committed capital", text: $commitment).keyboardType(.decimalPad)
                    TextField("Shares or units", text: $units).keyboardType(.decimalPad)
                        .disabled(holding?.latestManualSale != nil)
                        .accessibilityIdentifier("private.holding.units.input")
                    TextField("Ownership percentage", text: $ownership).keyboardType(.decimalPad)
                    TextField("Share class", text: $shareClass)
                    Toggle("Has a lock-up date", isOn: $locked)
                    if locked { DatePicker("Lock-up ends", selection: $lockup, displayedComponents: .date) }
                }
                if !companies.isEmpty || catalogueCompanyID != nil {
                    Picker("Company to monitor", selection: $catalogueCompanyID) {
                        Text("None").tag(nil as UUID?)
                        ForEach(companies) { company in Text(company.name).tag(Optional(company.id)) }
                        if let catalogueCompanyID, !companies.contains(where: { $0.id == catalogueCompanyID }) {
                            Text("Previously linked company").tag(Optional(catalogueCompanyID))
                        }
                    }
                }
                if let catalogueError { Text(catalogueError).font(.footnote).foregroundStyle(.secondary) }
                if holding?.matchingProviderHoldingID != nil, !keepsProviderMatch {
                    Text("Changing the currency or monitored company removes the provider link.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(Color.orange) }
            }
            .task {
                do {
                    let catalogue: PrivateMarketsAPI.Catalog = try await PrivateMarketsAPI.request("catalog")
                    try Task.checkCancellation()
                    var seen = Set<UUID>()
                    companies = catalogue.deals.map(\.company).filter { seen.insert($0.id).inserted }
                        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                } catch is CancellationError {
                } catch { catalogueError = "The company catalogue is unavailable." }
            }
            .navigationTitle(holding == nil ? "Add Private Holding" : "Edit Private Holding")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).accessibilityIdentifier("private.holding.save")
                }
            }
        }
    }

    private var keepsProviderMatch: Bool {
        holding?.catalogueCompanyID == catalogueCompanyID && holding?.currency == currency
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let committed = PrivateInput.amount(commitment)
        let parsedUnits = holding?.latestManualSale == nil ? PrivateInput.amount(units) : holding?.units
        let percent = PrivateInput.amount(ownership)
        guard !trimmedName.isEmpty, trimmedName.count <= 160, shareClass.count <= 120,
              commitment.isEmpty || committed != nil,
              units.isEmpty || (parsedUnits ?? 0) > 0,
              ownership.isEmpty || (percent.map { $0 <= 100 } ?? false) else {
            error = "Enter a name and valid ownership and commitment amounts."
            return
        }
        let evidenceStillApplies = holding?.name == trimmedName && holding?.assetClass == kind && holding?.currency == currency &&
            holding?.commitment == committed && holding?.units == parsedUnits && holding?.ownershipPercent == percent &&
            holding?.shareClass == shareClass
        let updated = PrivateHolding(id: holding?.id ?? UUID(), name: trimmedName, assetClass: kind, currency: currency,
                                     commitment: committed, units: parsedUnits, ownershipPercent: percent,
                                     shareClass: shareClass, lockupUntil: locked ? lockup : nil,
                                     valuations: holding?.valuations ?? [], cashFlows: holding?.cashFlows ?? [],
                                     catalogueCompanyID: catalogueCompanyID,
                                     ownershipEvidenceID: evidenceStillApplies ? holding?.ownershipEvidenceID : nil,
                                     ownershipReviewedOn: evidenceStillApplies ? holding?.ownershipReviewedOn : nil,
                                     matchingProviderHoldingID: keepsProviderMatch ? holding?.matchingProviderHoldingID : nil)
        do {
            try store.save(updated)
            dismiss()
        } catch { self.error = "The holding could not be saved." }
    }
}

struct PrivateHoldingDetail: View {
    @EnvironmentObject private var store: PrivateMarketsStore
    @EnvironmentObject private var auth: SupabaseAuthManager
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    var providerRecord = false
    @State private var editor: Editor?
    @State private var showDelete = false
    @State private var showProviderMatch = false
    @State private var showRemoveSale = false
    @State private var error: String?

    private enum Editor: String, Identifiable {
        case holding, valuation, cashFlow, sale
        var id: String { rawValue }
    }

    private var providerPosition: ProviderPrivateHolding? {
        guard providerRecord else { return nil }
        return store.providerHoldings.first { $0.id == id }
    }

    var body: some View {
        if let holding = providerRecord ? providerPosition?.holding : store.state.holdings.first(where: { $0.id == id }) {
            let valuation = providerRecord ? nil : store.linkedFundValuation(for: holding)
            let valuedHolding = valuation?.holding ?? holding
            List {
                overview(valuedHolding, statement: valuation?.statement)
                if !providerRecord, let owner = auth.userId {
                    let match = holding.matchingProviderHoldingID
                    if match != nil || !store.availableProviderMatches(for: holding).isEmpty {
                        Section("Portfolio allocation") {
                            if let match {
                                if let provider = store.providerHoldings.first(where: { $0.id == match }) {
                                    NavigationLink {
                                        PrivateHoldingDetail(id: provider.id, providerRecord: true)
                                    } label: { Text("Open linked provider record") }
                                } else {
                                    Text("The linked provider record is currently unavailable.")
                                }
                                Text("Allocation, capital activity and reminders use the provider record. Your manual ledger remains available here.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Button(match == nil ? "Link matching provider record" : "Manage provider link") { showProviderMatch = true }
                                .accessibilityIdentifier("private.holding.matchProvider")
                        }
                    }
                    Section("Ownership evidence") {
                        NavigationLink(holding.ownershipEvidenceID == nil ? "Link a Deal Room excerpt" : "Review linked ownership evidence") {
                            PrivateOwnershipEvidenceView(holding: holding, owner: owner)
                        }
                        .accessibilityIdentifier("private.ownership.evidence")
                    }
                }
                if providerPosition?.canCalculatePerformance != false {
                    performance(valuedHolding, statement: valuation?.statement)
                } else {
                    Section("Performance") {
                        Text("Full return metrics require the provider’s dated opening settlement and complete cash-flow records.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Valuation history") {
                    ForEach(holding.valuations.sorted(by: { $0.date > $1.date }), id: \.date) { mark in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(PrivateInput.money(mark.value, currency: holding.currency)).font(.headline)
                            Text("\(mark.date.formatted(date: .abbreviated, time: .omitted)) · \(mark.method)")
                            Text(mark.source)
                        }
                        .font(.subheadline)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("private.valuation.record")
                    }
                    if !providerRecord, holding.closedOn() == nil {
                        if let sale = holding.latestManualSale, valuedHolding.valuation() == nil {
                            Text("Record a valuation dated after the sale on \(sale.date.formatted(date: .abbreviated, time: .omitted)).")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Button("Record valuation") { editor = .valuation }.accessibilityIdentifier("private.valuation.add")
                    }
                }
                Section("Cash flows") {
                    ForEach(holding.cashFlows.sorted(by: { $0.date > $1.date }), id: \.id) { flow in
                        PrivateCashFlowRow(holding: holding, flow: flow, isEditable: !providerRecord)
                    }
                    if !providerRecord {
                        Button("Record cash flow") { editor = .cashFlow }
                            .accessibilityIdentifier("private.ledger.openCashFlow")
                        if holding.closedOn() == nil, holding.matchingProviderHoldingID == nil {
                            Button("Record settled sale") { editor = .sale }
                                .accessibilityIdentifier("private.holding.sale.add")
                        }
                        if holding.matchingProviderHoldingID == nil, let latest = holding.latestManualSale {
                            Button("Remove most recent sale", role: .destructive) { showRemoveSale = true }
                                .accessibilityIdentifier("private.holding.sale.remove")
                                .confirmationDialog("Remove the most recent sale?", isPresented: $showRemoveSale,
                                                    titleVisibility: .visible, presenting: latest.id) { saleID in
                                    Button("Remove sale", role: .destructive) { removeSale(saleID) }
                                }
                        }
                    }
                }
                if let cancellations = providerPosition?.cancelledCalls, !cancellations.isEmpty {
                    Section("Cancelled capital calls") {
                        ForEach(cancellations) { call in
                            PrivateCancelledCallRow(call: call, currency: holding.currency)
                        }
                    }
                }
                if !providerRecord {
                    Button("Remove holding", role: .destructive) { showDelete = true }
                }
            }
            .navigationTitle(holding.name)
            .toolbar {
                if !providerRecord { Button("Edit") { editor = .holding } }
            }
            .sheet(item: $editor) { item in
                switch item {
                case .holding: PrivateHoldingEditor(holding: holding)
                case .valuation: PrivateLedgerEditor(holding: holding, isValuation: true)
                case .cashFlow: PrivateLedgerEditor(holding: holding, isValuation: false)
                case .sale: PrivateManualSaleEditor(holdingID: holding.id, owner: auth.userId)
                }
            }
            .sheet(isPresented: $showProviderMatch) {
                if let owner = auth.userId { PrivateProviderMatchEditor(holdingID: id, owner: owner) }
            }
            .confirmationDialog("Remove this holding and its records?", isPresented: $showDelete, titleVisibility: .visible) {
                Button("Remove holding", role: .destructive) {
                    do { try store.change { $0.holdings.removeAll { $0.id == id } }; dismiss() }
                    catch { self.error = "The holding could not be removed." }
                }
            }
            .alert("Private holding", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        } else {
            ContentUnavailableView("Holding unavailable", systemImage: "briefcase")
        }
    }

    private func removeSale(_ saleID: UUID) {
        do {
            try store.change { state in
                guard let index = state.holdings.firstIndex(where: { $0.id == id }),
                      state.holdings[index].removeLatestManualSale(saleID) else { throw PrivateLedgerError.holdingChanged }
            }
        } catch { self.error = "The sale could not be removed." }
    }

    private func overview(_ holding: PrivateHolding, statement: PrivateFundSnapshot?) -> some View {
        let exited = providerPosition?.hasExited == true || holding.closedOn() != nil
        let ownershipStatus = providerRecord
            ? (exited ? "Exited · Provider confirmed" : "Provider-confirmed ownership · Illiquid")
            : (exited ? "Exited · Self-reported" : "Self-reported holding · Illiquid")
        return Section("Ownership") {
            Text(ownershipStatus)
                .font(.footnote).foregroundStyle(.secondary)
            LabeledContent("Asset class", value: holding.assetClass.rawValue)
            if let position = providerPosition {
                LabeledContent("Provider reference", value: position.commitment.providerReference)
                LabeledContent("Ownership confirmed", value: position.confirmedAt.formatted(date: .abbreviated, time: .omitted))
                LabeledContent("Opening settled capital", value: PrivateInput.money(position.settledAmount, currency: holding.currency))
                if let original = position.units, position.lastDispositionOn != nil {
                    LabeledContent("Original shares or units", value: original.formatted())
                }
                if position.hasExited, let date = position.lastDispositionOn, let source = position.exitSource {
                    LabeledContent("Exit settled", value: date.formatted(date: .abbreviated, time: .omitted))
                    LabeledContent("Exit source", value: source)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Exit source")
                        .accessibilityValue(source)
                        .accessibilityIdentifier("private.holding.exitSource")
                }
                if !position.hasCompleteActivity {
                    Text("Only recent provider activity is available.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !providerRecord, let sale = holding.latestManualSale {
                if let original = holding.units { LabeledContent("Original shares or units", value: original.formatted()) }
                if sale.closesManualPosition == true {
                    LabeledContent("Exit settled", value: sale.date.formatted(date: .abbreviated, time: .omitted))
                    LabeledContent("Exit source", value: sale.source)
                }
            }
            let unitsLabel = holding.latestDispositionOn == nil && holding.latestManualSale == nil ? "Shares or units" : "Remaining shares or units"
            if let units = holding.remainingUnits() {
                LabeledContent(unitsLabel, value: units.formatted())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(unitsLabel)
                    .accessibilityValue(units.formatted())
                    .accessibilityIdentifier("private.holding.units")
            }
            if holding.latestManualSale == nil, let percent = holding.ownershipPercent { LabeledContent("Ownership", value: (percent / 100).formatted(.percent)) }
            if !holding.shareClass.isEmpty { LabeledContent("Share class", value: holding.shareClass) }
            if let end = holding.lockupUntil { LabeledContent("Lock-up ends", value: end.formatted(date: .abbreviated, time: .omitted)) }
            if let mark = holding.valuation() {
                LabeledContent("Latest carrying value", value: PrivateInput.money(mark.value, currency: holding.currency))
                if let statement, let owner = auth.userId {
                    NavigationLink(PrivateFundSnapshot.source) { PrivateFundSnapshotDetail(id: statement.id, owner: owner) }
                        .accessibilityIdentifier("private.holding.valuationStatement")
                }
                if holding.closedOn() == nil {
                    Text(mark.isStale() ? "Stale valuation · \(mark.date.formatted(date: .abbreviated, time: .omitted))" :
                            "As of \(mark.date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.footnote).foregroundStyle(mark.isStale() ? Color.orange : Color.secondary)
                }
            } else {
                let markStatus = holding.dispositionRevisionAt == nil && holding.latestManualSale == nil ? "Unavailable" : "Updated valuation needed"
                LabeledContent("Latest carrying value", value: markStatus)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Latest carrying value")
                    .accessibilityValue(markStatus)
                    .accessibilityIdentifier("private.holding.valuationStatus")
            }
        }
    }

    private func performance(_ holding: PrivateHolding, statement: PrivateFundSnapshot?) -> some View {
        let metrics = holding.metrics()
        let reconciles = statement?.agreesWithRecordedCashFlows(of: holding) ?? true
        let hasReturnData = reconciles && (statement == nil || metrics.paid > 0)
        return Section("Performance") {
            LabeledContent("Capital committed", value: PrivateInput.money(holding.commitment, currency: holding.currency))
            LabeledContent("Capital deployed", value: PrivateInput.money(metrics.paid, currency: holding.currency))
            LabeledContent("Returned capital and proceeds", value: PrivateInput.money(metrics.returned, currency: holding.currency))
            LabeledContent("Uncalled commitment", value: PrivateInput.money(metrics.uncalled, currency: holding.currency))
            LabeledContent("Pending calls", value: PrivateInput.money(metrics.pendingCalls, currency: holding.currency))
            LabeledContent("Total gain or loss", value: PrivateInput.money(hasReturnData ? metrics.netGain : nil, currency: holding.currency))
            LabeledContent("Realized gain on sales", value: PrivateInput.money(metrics.realizedGain, currency: holding.currency))
            LabeledContent("Unrealized gain", value: PrivateInput.money(hasReturnData ? metrics.unrealizedGain : nil, currency: holding.currency))
            LabeledContent(holding.assetClass.isFund && !holding.cashFlows.contains(where: { $0.kind == .sale }) ? "TVPI" : "MOIC",
                           value: multiple(hasReturnData ? metrics.multiple : nil))
            if holding.assetClass.isFund { LabeledContent("DPI", value: multiple(hasReturnData ? metrics.dpi : nil)) }
            LabeledContent("XIRR", value: (hasReturnData ? metrics.xirr : nil)?.formatted(.percent.precision(.fractionLength(1))) ?? "Unavailable")
            if !reconciles {
                Text("The statement’s paid-in capital or distributions differ from recorded cash flows. Review the dated ledger before calculating returns.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if !hasReturnData {
                Text("Record dated contributions to calculate returns from this NAV.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func multiple(_ value: Decimal?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(2))) + "×" } ?? "Unavailable"
    }
}

private struct PrivateProviderMatchEditor: View {
    let holdingID: UUID
    let owner: UUID
    @EnvironmentObject private var auth: SupabaseAuthManager
    @EnvironmentObject private var store: PrivateMarketsStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected: UUID?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            if auth.userId == owner, let holding = store.state.holdings.first(where: { $0.id == holdingID }) {
                Form {
                    Section("Same investment") {
                        ForEach(store.availableProviderMatches(for: holding)) { position in
                            Button {
                                selected = position.id
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(position.name)
                                        Text("\(position.commitment.provider.capitalized) · \(position.commitment.providerReference)")
                                            .font(.footnote).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selected == position.id { Image(systemName: "checkmark").accessibilityHidden(true) }
                                }
                            }
                            .accessibilityAddTraits(selected == position.id ? .isSelected : [])
                            .accessibilityIdentifier("private.holding.providerMatch.option")
                        }
                        Text("Match the provider reference against your records. Linking counts this investment once in your portfolio.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if holding.matchingProviderHoldingID != nil {
                        Button("Remove link", role: .destructive) { save(nil) }
                            .accessibilityIdentifier("private.holding.providerMatch.remove")
                    }
                    if let error { Text(error).foregroundStyle(Color.orange) }
                }
                .onAppear { selected = holding.matchingProviderHoldingID }
                .navigationTitle("Link Provider Record")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Link") { save(selected) }.disabled(selected == nil || selected == holding.matchingProviderHoldingID)
                            .accessibilityIdentifier("private.holding.providerMatch.save")
                    }
                }
            }
        }
    }

    private func save(_ providerID: UUID?) {
        do {
            try store.setProviderMatch(providerID, for: holdingID, owner: owner)
            dismiss()
        } catch is CancellationError {
        } catch { self.error = error.localizedDescription }
    }
}

private enum PrivateLedgerError: Error { case holdingChanged, invalidSale, afterExit }

private struct PrivateManualSaleEditor: View {
    @EnvironmentObject private var store: PrivateMarketsStore
    @EnvironmentObject private var auth: SupabaseAuthManager
    @Environment(\.dismiss) private var dismiss
    let holdingID: UUID
    let owner: UUID?
    @State private var closesPosition = false
    @State private var date = Date.now
    @State private var units = ""
    @State private var proceeds = ""
    @State private var basis = ""
    @State private var source = ""
    @State private var error: String?

    private var holding: PrivateHolding? { store.state.holdings.first { $0.id == holdingID } }

    var body: some View {
        NavigationStack {
            Form {
                if auth.userId == owner, let holding, holding.closedOn() == nil, holding.matchingProviderHoldingID == nil {
                    Toggle("Close the entire position", isOn: $closesPosition)
                        .accessibilityIdentifier("private.sale.full")
                    if !closesPosition {
                        if let remaining = holding.remainingUnits() {
                            LabeledContent("Shares or units available", value: remaining.formatted())
                            TextField("Shares or units sold", text: $units).keyboardType(.decimalPad)
                                .accessibilityIdentifier("private.sale.units")
                        } else {
                            Text("Enter the original units in the holding before recording a partial sale.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    DatePicker("Settlement date", selection: $date, in: ...Date.now, displayedComponents: .date)
                    TextField("Net proceeds (\(holding.currency))", text: $proceeds).keyboardType(.decimalPad)
                        .accessibilityIdentifier("private.sale.proceeds")
                    TextField("Cost basis of units sold", text: $basis).keyboardType(.decimalPad)
                    TextField("Settlement source", text: $source)
                        .accessibilityIdentifier("private.sale.source")
                    if let error { Text(error).foregroundStyle(Color.orange) }
                } else {
                    Text("This holding is unavailable for recording a sale.")
                }
            }
            .navigationTitle("Record Settled Sale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).accessibilityIdentifier("private.sale.save")
                        .disabled(auth.userId != owner || holding == nil || holding?.closedOn() != nil ||
                                  holding?.matchingProviderHoldingID != nil || (!closesPosition && holding?.remainingUnits() == nil))
                }
            }
        }
        .onChange(of: auth.userId) { _, _ in dismiss() }
    }

    private func save() {
        guard auth.userId == owner else { return }
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedBasis = PrivateInput.amount(basis)
        guard let amount = PrivateInput.amount(proceeds), !source.isEmpty, source.count <= 400,
              basis.isEmpty || parsedBasis != nil else {
            error = "Enter the net proceeds, settlement source and any known cost basis."
            return
        }
        do {
            try store.change { state in
                guard let index = state.holdings.firstIndex(where: { $0.id == holdingID }),
                      state.holdings[index].recordManualSale(amount: amount, date: Calendar.current.startOfDay(for: date),
                                                            source: source, soldUnits: closesPosition ? nil : PrivateInput.amount(units),
                                                            basis: parsedBasis, closesPosition: closesPosition) else {
                    throw PrivateLedgerError.invalidSale
                }
            }
            dismiss()
        } catch PrivateLedgerError.invalidSale {
            self.error = "Check the units and settlement date against the ledger. A partial sale must leave units in the holding."
        } catch { self.error = "The sale could not be saved." }
    }
}

private struct PrivateLedgerEditor: View {
    @EnvironmentObject private var store: PrivateMarketsStore
    @Environment(\.dismiss) private var dismiss
    let holding: PrivateHolding
    let isValuation: Bool
    @State private var kind = PrivateCashFlow.Kind.contribution
    @State private var date = Date.now
    @State private var amount = ""
    @State private var source = ""
    @State private var method = ""
    @State private var pending = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if !isValuation {
                    Picker("Cash flow type", selection: $kind) {
                        ForEach(PrivateCashFlow.Kind.allCases.filter { $0 != .sale }, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .accessibilityIdentifier("private.ledger.kind")
                    if kind == .capitalCall {
                        Toggle("Payment pending", isOn: $pending)
                            .accessibilityIdentifier("private.ledger.paymentPending")
                    }
                }
                if !isValuation && kind == .capitalCall && pending {
                    DatePicker("Due date", selection: $date, displayedComponents: .date)
                } else {
                    DatePicker(isValuation ? "Valuation date" : "Transaction date", selection: $date, in: ...Date.now, displayedComponents: .date)
                }
                TextField("Amount (\(holding.currency))", text: $amount).keyboardType(.decimalPad)
                    .accessibilityIdentifier("private.ledger.amount")
                TextField("Source or document reference", text: $source).accessibilityIdentifier("private.ledger.source")
                if isValuation { TextField("Valuation methodology", text: $method).accessibilityIdentifier("private.ledger.method") }
                if let error { Text(error).foregroundStyle(Color.orange) }
            }
            .navigationTitle(isValuation ? "Record Valuation" : "Record Cash Flow")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).accessibilityIdentifier("private.ledger.save") }
            }
        }
    }

    private func save() {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let method = method.trimmingCharacters(in: .whitespacesAndNewlines)
        let day = Calendar.current.startOfDay(for: date)
        let settled = kind != .capitalCall || !pending
        guard let value = PrivateInput.amount(amount), isValuation || value > 0,
              !source.isEmpty, source.count <= 400, !isValuation || (!method.isEmpty && method.count <= 400),
              !settled || day <= .now else {
            error = "Enter an amount, source, and any required methodology."
            return
        }
        do {
            try store.change { state in
                guard let index = state.holdings.firstIndex(where: { $0.id == holding.id }) else {
                    throw PrivateLedgerError.holdingChanged
                }
                if isValuation {
                    guard state.holdings[index].closedOn() == nil else { throw PrivateLedgerError.holdingChanged }
                    state.holdings[index].valuations.removeAll { $0.date == day }
                    let sale = state.holdings[index].latestManualSale
                    state.holdings[index].valuations.append(.init(value: value, date: day, source: source, method: method,
                                                                  manualSaleID: sale.flatMap { day > $0.date ? $0.id : nil }))
                } else {
                    if kind.isOutflow, let exit = state.holdings[index].closedOn(), day > exit {
                        throw PrivateLedgerError.afterExit
                    }
                    state.holdings[index].cashFlows.append(.init(kind: kind, amount: value, date: day, settled: settled,
                                                               source: source))
                }
            }
            dismiss()
        } catch PrivateLedgerError.afterExit {
            self.error = "New capital records must be dated on or before the exit. A previously recorded call can still be marked paid."
        } catch { self.error = "The record could not be saved." }
    }
}

struct PrivateCapitalView: View {
    @EnvironmentObject private var auth: SupabaseAuthManager
    @EnvironmentObject private var store: PrivateMarketsStore

    @State private var reminderError: String?

    var body: some View {
        List {
            Section("Reminders") {
                Toggle("Capital call reminders", isOn: Binding(
                    get: { store.state.capitalReminders == true },
                    set: { enabled in
                        Task {
                            do { try await store.setCapitalReminders(enabled); reminderError = nil }
                            catch { reminderError = error.localizedDescription }
                        }
                    }))
                Text("Reminders are scheduled on this device for recorded upcoming calls.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let reminderError { Text(reminderError).foregroundStyle(.secondary) }
            }
            ForEach(store.independentManualHoldings) { holding in
                let flows = holding.cashFlows.filter { $0.kind == .capitalCall || $0.kind == .distribution }
                if !flows.isEmpty {
                    Section(holding.name) {
                        ForEach(flows.sorted(by: { $0.date < $1.date }), id: \.id) { flow in
                            PrivateCashFlowRow(holding: holding, flow: flow)
                        }
                    }
                }
            }
            ForEach(store.accountHoldings.filter { !$0.activity.isEmpty }) { holding in
                Section(holding.name + " · Account records") {
                    ForEach(holding.activity.sorted { $0.date > $1.date }) { flow in
                        AccountCashFlowLabel(flow: flow, currency: holding.currency)
                    }
                }
            }
            ForEach(store.providerHoldings) { position in
                let holding = position.holding
                let flows = holding.cashFlows.filter { $0.kind == .capitalCall || $0.kind == .distribution }
                let cancellations = position.cancelledCalls ?? []
                if !flows.isEmpty || !cancellations.isEmpty {
                    Section("\(holding.name) · Provider records") {
                        ForEach(flows.sorted(by: { $0.date < $1.date }), id: \.id) { flow in
                            PrivateCashFlowRow(holding: holding, flow: flow, isEditable: false)
                        }
                        ForEach(cancellations) { call in
                            PrivateCancelledCallRow(call: call, currency: holding.currency)
                        }
                    }
                }
            }
            if let error = store.providerError { Text(error).foregroundStyle(.secondary) }
            if store.loadingProviderHoldings { ProgressView("Checking provider records") }
            let hasManualActivity = store.independentManualHoldings.contains { holding in
                holding.cashFlows.contains { $0.kind == .capitalCall || $0.kind == .distribution }
            }
            let hasProviderActivity = store.providerHoldings.contains { position in
                position.calls?.isEmpty == false || position.cancelledCalls?.isEmpty == false || position.distributions?.isEmpty == false
            }
            if !hasManualActivity && !hasProviderActivity && !store.accountHoldings.contains(where: { !$0.activity.isEmpty }) {
                ContentUnavailableView("No capital calls or distributions", systemImage: "arrow.left.arrow.right",
                                       description: Text("Record cash flows on a holding to track payments and proceeds."))
            }
        }
        .navigationTitle("Capital Calls & Distributions")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: auth.userId) { await refresh() }
        .refreshable { await refresh() }
    }

    private func refresh() async {
        if let owner = auth.userId { await store.refreshInvestmentHoldings(for: owner) }
    }
}

private struct PrivateCancelledCallRow: View {
    let call: ProviderPrivateHolding.CancelledCall
    let currency: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Capital call cancelled", value: PrivateInput.money(call.amount, currency: currency))
            Text("Provider cancellation · \(call.cancelledAt.formatted(date: .abbreviated, time: .shortened))")
            Text(call.cancellationSource)
            Text("Originally due \(call.dueOn.formatted(date: .abbreviated, time: .omitted)) · \(call.source)")
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("private.capital.cancelledCall")
    }
}

private struct PrivateCashFlowRow: View {
    @EnvironmentObject private var store: PrivateMarketsStore
    let holding: PrivateHolding
    let flow: PrivateCashFlow
    var isEditable = true
    @State private var resolution: Resolution?

    private enum Resolution: String, Identifiable {
        case payment, cancellation
        var id: Self { self }
        var title: String { self == .payment ? "Record Payment" : "Record Cancellation" }
        var dateLabel: String { self == .payment ? "Date paid" : "Cancellation date" }
        var sourceLabel: String { self == .payment ? "Payment source" : "Cancellation source" }
        var value: PrivateCashFlow.CapitalCallResolution { self == .payment ? .paid : .cancelled }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(flow.kind.rawValue, value: PrivateInput.money(flow.amount, currency: holding.currency))
            Group {
                if let cancellation = flow.cancellation {
                    Text("Cancelled \(formatted(cancellation.date)) · \(cancellation.source)")
                        .accessibilityIdentifier("private.capital.manualCancellation")
                } else if let payment = flow.paymentEvidence {
                    Text("Paid \(formatted(payment.date)) · \(payment.source)")
                        .accessibilityIdentifier("private.capital.manualPayment")
                } else {
                    Text("\(flow.settled ? "Recorded" : "Due") \(formatted(flow.date)) · \(flow.source)")
                }
                if (flow.settled || flow.cancellation != nil), let due = flow.originalDueDate {
                    let notice = flow.paymentEvidence != nil || flow.cancellation != nil ? " · \(flow.source)" : ""
                    Text("Originally due \(formatted(due))\(notice)")
                        .accessibilityIdentifier("private.capital.originalNotice")
                }
            }
            .font(.footnote).foregroundStyle(.secondary)
            if let units = flow.disposedUnits {
                LabeledContent("Shares or units sold", value: units.formatted())
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let cost = flow.disposedCost {
                LabeledContent("Cost basis", value: PrivateInput.money(cost, currency: holding.currency))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if flow.isPendingCapitalCall() {
                if Calendar.current.startOfDay(for: .now) > (flow.originalDueDate ?? flow.date) {
                    Text("Overdue").font(.footnote.weight(.semibold)).foregroundStyle(.orange)
                }
                if isEditable {
                    Button("Record as paid") { resolution = .payment }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("private.capital.recordPayment")
                    Button("Record cancellation") { resolution = .cancellation }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("private.capital.recordCancellation")
                }
            }
        }
        .sheet(item: $resolution) { resolution in
            ResolutionEditor(resolution: resolution, holdingID: holding.id, flowID: flow.id)
        }
    }

    private func formatted(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .omitted) }

    private struct ResolutionEditor: View {
        @EnvironmentObject private var store: PrivateMarketsStore
        @Environment(\.dismiss) private var dismiss
        let resolution: Resolution
        let holdingID: UUID
        let flowID: UUID
        @State private var date = Date.now
        @State private var source = ""
        @State private var error: String?

        var body: some View {
            NavigationStack {
                Form {
                    DatePicker(resolution.dateLabel, selection: $date, in: ...Date.now, displayedComponents: .date)
                    TextField(resolution.sourceLabel, text: $source)
                        .accessibilityIdentifier("private.capital.resolutionSource")
                    if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
                }
                .navigationTitle(resolution.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save", action: save)
                            .disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("private.capital.resolutionSave")
                    }
                }
            }
        }

        private func save() {
            guard source.count <= 400 else {
                error = "Use a source reference of 400 characters or fewer."
                return
            }
            do {
                try store.change { state in
                    guard let holding = state.holdings.firstIndex(where: { $0.id == holdingID }),
                          let call = state.holdings[holding].cashFlows.firstIndex(where: { $0.id == flowID }),
                          state.holdings[holding].cashFlows[call].resolveCapitalCall(
                              resolution.value, date: Calendar.current.startOfDay(for: date), source: source
                          ) else { throw PrivateLedgerError.holdingChanged }
                }
                dismiss()
            } catch PrivateLedgerError.holdingChanged {
                error = "The call changed. Reopen it to review the current record."
            } catch { self.error = "The record could not be saved." }
        }
    }
}
