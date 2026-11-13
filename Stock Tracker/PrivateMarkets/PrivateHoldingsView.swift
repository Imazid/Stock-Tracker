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

    static func money(_ value: Decimal?, currency: String) -> String {
        value?.formatted(.currency(code: currency)) ?? "Unavailable"
    }
}

struct PrivateHoldingsView: View {
    @EnvironmentObject private var auth: SupabaseAuthManager
    @EnvironmentObject private var store: PrivateMarketsStore
    @State private var add = false

    var body: some View {
        List {
            UnifiedPrivateAllocation()
            Section("Self-reported holdings") {
                if store.state.holdings.isEmpty {
                    ContentUnavailableView("No self-reported holdings", systemImage: "briefcase",
                                           description: Text("Add a holding from your ownership records."))
                }
                ForEach(store.state.holdings) { holding in
                    NavigationLink {
                        PrivateHoldingDetail(id: holding.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(holding.name).font(.headline)
                            Text(holding.assetClass.rawValue + " · Self-reported")
                                .font(.footnote).foregroundStyle(.secondary)
                            if let mark = holding.valuation() {
                                Text(PrivateInput.money(mark.value, currency: holding.currency) + (mark.isStale() ? " · Stale valuation" : " · Dated valuation"))
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(mark.isStale() ? Color.orange : Color.primary)
                            } else {
                                Text("No carrying value recorded").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("private.holding.row")
                }
                Button { add = true } label: { Label("Add private holding", systemImage: "plus") }
                    .accessibilityIdentifier("private.holding.add")
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
                                if let mark = holding.valuation() {
                                    Text(PrivateInput.money(mark.value, currency: holding.currency) +
                                         (mark.isStale() ? " · Stale valuation" : " · Dated valuation"))
                                        .font(.subheadline.monospacedDigit())
                                        .foregroundStyle(mark.isStale() ? Color.orange : Color.primary)
                                } else {
                                    Text("Carrying value unavailable").font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if store.loadingProviderHoldings { ProgressView("Checking provider records") }
                    if let error = store.providerError { Text(error).foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle("My Private Portfolio")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $add) { PrivateHoldingEditor() }
        .task(id: auth.userId) { await refresh() }
        .refreshable { await refresh() }
    }

    private func refresh() async {
        if let owner = auth.userId { await store.refreshProviderHoldings(for: owner) }
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

    private var publicHoldings: [PortfolioHolding] {
        market.portfolioGroups.enumerated().flatMap { index, group in
            index == market.activePortfolioIndex ? market.portfolio : group.holdings
        }
    }

    private var privateHoldings: [PrivateHolding] {
        store.state.holdings + store.providerHoldings.map(\.holding)
    }

    private var slices: [Slice] {
        var values: [String: Double] = [:]
        for holding in publicHoldings {
            let key = holding.asset.kind == .crypto ? "Crypto" : "Listed equities & ETFs"
            values[key, default: 0] += holding.currentValue
        }
        for holding in privateHoldings {
            guard let mark = holding.valuation(), let rate = market.verifiedFXRates[holding.currency] else { continue }
            values[holding.assetClass.rawValue, default: 0] += NSDecimalNumber(decimal: mark.value).doubleValue / rate
        }
        return values.filter { $0.value.isFinite && $0.value > 0 }.map { Slice(id: $0.key, usd: $0.value) }
            .sorted { $0.usd > $1.usd }
    }

    private var excluded: Int {
        privateHoldings.filter { $0.valuation() == nil || market.verifiedFXRates[$0.currency] == nil }.count
    }

    var body: some View {
        let allocation = slices
        let total = allocation.reduce(0) { $0 + $1.usd }
        let code = market.verifiedFXRates[market.preferredCurrency] != nil ? market.preferredCurrency : "USD"
        let fx = market.verifiedFXRates[code] ?? 1
        VStack(alignment: .leading, spacing: 12) {
            Text("Unified allocation").font(.headline).accessibilityAddTraits(.isHeader)
            Text("All tracked listed portfolios and this private portfolio. Private values use dated marks.")
                .font(.footnote).foregroundStyle(.secondary)
            if hide {
                Text("Portfolio values are hidden.").font(.footnote).foregroundStyle(.secondary)
            } else if allocation.isEmpty {
                Text("Allocation appears when holdings have a supported value.").font(.footnote).foregroundStyle(.secondary)
            } else {
                Text((total * fx).formatted(.currency(code: code)))
                    .font(.title2.weight(.semibold).monospacedDigit())
                Chart(allocation) { slice in
                    SectorMark(angle: .value("Value in USD", slice.usd), innerRadius: .ratio(0.72), angularInset: 2)
                        .cornerRadius(4)
                        .foregroundStyle(by: .value("Asset class", slice.id))
                }
                .chartForegroundStyleScale(range: [Color.blue, .cyan, .purple, .mint, .orange, .pink, .teal, .indigo])
                .chartLegend(.hidden)
                .frame(height: 118)
                .accessibilityHidden(true)
                ForEach(allocation) { slice in
                    LabeledContent(slice.id, value: (slice.usd / total).formatted(.percent.precision(.fractionLength(1))))
                        .font(.subheadline)
                }
            }
            if excluded > 0 {
                Text("\(excluded) private holdings excluded because a valuation or verified FX rate is unavailable.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if privateHoldings.contains(where: { $0.valuation()?.isStale() == true && market.verifiedFXRates[$0.currency] != nil }) {
                Label("Includes stale valuations where a conversion is available.", systemImage: "clock.badge.exclamationmark")
                    .font(.footnote).foregroundStyle(Color.orange)
            }
        }
        .padding(.vertical, 8)
        .accessibilityIdentifier("private.allocation")
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
                    .disabled(holding.map { !$0.valuations.isEmpty || !$0.cashFlows.isEmpty } ?? false)
                }
                Section("Ownership") {
                    TextField("Committed capital", text: $commitment).keyboardType(.decimalPad)
                    TextField("Shares or units", text: $units).keyboardType(.decimalPad)
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

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let committed = PrivateInput.amount(commitment)
        let parsedUnits = PrivateInput.amount(units)
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
                                     ownershipReviewedOn: evidenceStillApplies ? holding?.ownershipReviewedOn : nil)
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
    @State private var error: String?

    private enum Editor: String, Identifiable {
        case holding, valuation, cashFlow
        var id: String { rawValue }
    }

    private var providerPosition: ProviderPrivateHolding? {
        guard providerRecord else { return nil }
        return store.providerHoldings.first { $0.id == id }
    }

    var body: some View {
        if let holding = providerRecord ? providerPosition?.holding : store.state.holdings.first(where: { $0.id == id }) {
            List {
                overview(holding)
                if !providerRecord, let owner = auth.userId {
                    Section("Ownership evidence") {
                        NavigationLink(holding.ownershipEvidenceID == nil ? "Link a Deal Room excerpt" : "Review linked ownership evidence") {
                            PrivateOwnershipEvidenceView(holding: holding, owner: owner)
                        }
                    }
                }
                if providerPosition?.canCalculatePerformance != false {
                    performance(holding)
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
                    if !providerRecord {
                        Button("Record valuation") { editor = .valuation }.accessibilityIdentifier("private.valuation.add")
                    }
                }
                Section("Cash flows") {
                    ForEach(holding.cashFlows.sorted(by: { $0.date > $1.date }), id: \.id) { flow in
                        PrivateCashFlowRow(holding: holding, flow: flow, isEditable: !providerRecord)
                    }
                    if !providerRecord { Button("Record cash flow") { editor = .cashFlow } }
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
                }
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

    private func overview(_ holding: PrivateHolding) -> some View {
        Section("Ownership") {
            Text(providerRecord ? "Provider-confirmed ownership · Illiquid" : "Self-reported holding · Illiquid")
                .font(.footnote).foregroundStyle(.secondary)
            LabeledContent("Asset class", value: holding.assetClass.rawValue)
            if let position = providerPosition {
                LabeledContent("Provider reference", value: position.commitment.providerReference)
                LabeledContent("Ownership confirmed", value: position.confirmedAt.formatted(date: .abbreviated, time: .omitted))
                LabeledContent("Opening settled capital", value: PrivateInput.money(position.settledAmount, currency: holding.currency))
                if !position.hasCompleteActivity {
                    Text("Only recent provider activity is available.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let units = holding.units { LabeledContent("Shares or units", value: units.formatted()) }
            if let percent = holding.ownershipPercent { LabeledContent("Ownership", value: (percent / 100).formatted(.percent)) }
            if !holding.shareClass.isEmpty { LabeledContent("Share class", value: holding.shareClass) }
            if let end = holding.lockupUntil { LabeledContent("Lock-up ends", value: end.formatted(date: .abbreviated, time: .omitted)) }
            if let mark = holding.valuation() {
                LabeledContent("Latest carrying value", value: PrivateInput.money(mark.value, currency: holding.currency))
                Text(mark.isStale() ? "Stale valuation · \(mark.date.formatted(date: .abbreviated, time: .omitted))" :
                        "As of \(mark.date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.footnote).foregroundStyle(mark.isStale() ? Color.orange : Color.secondary)
            } else {
                LabeledContent("Latest carrying value", value: "Unavailable")
            }
        }
    }

    private func performance(_ holding: PrivateHolding) -> some View {
        let metrics = holding.metrics()
        return Section("Performance") {
            LabeledContent("Capital committed", value: PrivateInput.money(holding.commitment, currency: holding.currency))
            LabeledContent("Capital deployed", value: PrivateInput.money(metrics.paid, currency: holding.currency))
            LabeledContent("Returned capital and proceeds", value: PrivateInput.money(metrics.returned, currency: holding.currency))
            LabeledContent("Uncalled commitment", value: PrivateInput.money(metrics.uncalled, currency: holding.currency))
            LabeledContent("Pending calls", value: PrivateInput.money(metrics.pendingCalls, currency: holding.currency))
            LabeledContent("Total gain or loss", value: PrivateInput.money(metrics.netGain, currency: holding.currency))
            LabeledContent("Realized gain on sales", value: PrivateInput.money(metrics.realizedGain, currency: holding.currency))
            LabeledContent("Unrealized gain", value: PrivateInput.money(metrics.unrealizedGain, currency: holding.currency))
            LabeledContent(holding.assetClass.isFund ? "TVPI" : "MOIC", value: multiple(metrics.multiple))
            if holding.assetClass.isFund { LabeledContent("DPI", value: multiple(metrics.dpi)) }
            LabeledContent("XIRR", value: metrics.xirr?.formatted(.percent.precision(.fractionLength(1))) ?? "Unavailable")
        }
    }

    private func multiple(_ value: Decimal?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(2))) + "×" } ?? "Unavailable"
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
    @State private var disposedCost = ""
    @State private var pending = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if !isValuation {
                    Picker("Cash flow type", selection: $kind) {
                        ForEach(PrivateCashFlow.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    if kind == .capitalCall { Toggle("Payment pending", isOn: $pending) }
                    if kind == .sale { TextField("Cost basis of units sold", text: $disposedCost).keyboardType(.decimalPad) }
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
        let parsedCost = PrivateInput.amount(disposedCost)
        guard let value = PrivateInput.amount(amount), isValuation || value > 0,
              !source.isEmpty, source.count <= 400, !isValuation || (!method.isEmpty && method.count <= 400),
              isValuation || kind != .sale || disposedCost.isEmpty || parsedCost != nil,
              !settled || day <= .now else {
            error = "Enter an amount, source, and any required methodology."
            return
        }
        do {
            try store.change { state in
                guard let index = state.holdings.firstIndex(where: { $0.id == holding.id }) else { return }
                if isValuation {
                    state.holdings[index].valuations.removeAll { $0.date == day }
                    state.holdings[index].valuations.append(.init(value: value, date: day, source: source, method: method))
                } else {
                    state.holdings[index].cashFlows.append(.init(kind: kind, amount: value, date: day, settled: settled,
                                                               source: source, disposedCost: parsedCost))
                }
            }
            dismiss()
        } catch { self.error = "The record could not be saved." }
    }
}

struct PrivateCapitalView: View {
    @EnvironmentObject private var auth: SupabaseAuthManager
    @EnvironmentObject private var store: PrivateMarketsStore

    @State private var reminderError: String?

    private var providerHoldings: [PrivateHolding] { store.providerHoldings.map(\.holding) }

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
            ForEach(store.state.holdings) { holding in
                let flows = holding.cashFlows.filter { $0.kind == .capitalCall || $0.kind == .distribution }
                if !flows.isEmpty {
                    Section(holding.name) {
                        ForEach(flows.sorted(by: { $0.date < $1.date }), id: \.id) { flow in
                            PrivateCashFlowRow(holding: holding, flow: flow)
                        }
                    }
                }
            }
            ForEach(providerHoldings) { holding in
                let flows = holding.cashFlows.filter { $0.kind == .capitalCall || $0.kind == .distribution }
                if !flows.isEmpty {
                    Section("\(holding.name) · Provider records") {
                        ForEach(flows.sorted(by: { $0.date < $1.date }), id: \.id) { flow in
                            PrivateCashFlowRow(holding: holding, flow: flow, isEditable: false)
                        }
                    }
                }
            }
            if let error = store.providerError { Text(error).foregroundStyle(.secondary) }
            if store.loadingProviderHoldings { ProgressView("Checking provider records") }
            if !(store.state.holdings + providerHoldings).contains(where: { $0.cashFlows.contains { $0.kind == .capitalCall || $0.kind == .distribution } }) {
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
        if let owner = auth.userId { await store.refreshProviderHoldings(for: owner) }
    }
}

private struct PrivateCashFlowRow: View {
    @EnvironmentObject private var store: PrivateMarketsStore
    let holding: PrivateHolding
    let flow: PrivateCashFlow
    var isEditable = true
    @State private var error: String?
    @State private var confirmPayment = false
    @State private var paymentDate = Date.now

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(flow.kind.rawValue, value: PrivateInput.money(flow.amount, currency: holding.currency))
            Text("\(flow.settled ? "Recorded" : "Due") \(flow.date.formatted(date: .abbreviated, time: .omitted)) · \(flow.source)")
                .font(.footnote).foregroundStyle(.secondary)
            if flow.settled, let due = flow.originalDueDate {
                Text("Originally due \(due.formatted(date: .abbreviated, time: .omitted))")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if isEditable && !flow.settled { Button("Record as paid") { confirmPayment = true }.buttonStyle(.borderless) }
            if let error { Text(error).font(.footnote).foregroundStyle(Color.orange) }
        }
        .sheet(isPresented: $confirmPayment) {
            NavigationStack {
                Form {
                    DatePicker("Date paid", selection: $paymentDate, in: ...Date.now, displayedComponents: .date)
                    Button("Save payment date", action: settle)
                }
                .navigationTitle("Record payment")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { confirmPayment = false } } }
            }
            .presentationDetents([.medium])
        }
    }

    private func settle() {
        do {
            try store.change { state in
                guard let holdingIndex = state.holdings.firstIndex(where: { $0.id == holding.id }),
                      let index = state.holdings[holdingIndex].cashFlows.firstIndex(where: { $0.id == flow.id }) else { return }
                state.holdings[holdingIndex].cashFlows[index].settled = true
                state.holdings[holdingIndex].cashFlows[index].date = Calendar.current.startOfDay(for: paymentDate)
            }
            confirmPayment = false
        } catch { self.error = "The payment record could not be saved." }
    }
}
