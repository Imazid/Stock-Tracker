import SwiftUI

struct PortfolioBrokerActivity: View {
    private struct Account: Decodable, Identifiable {
        let id: String
        let name: String?
        let institution_name: String?
        let number: String?

        func title(masked: Bool = false) -> String {
            let label = (masked ? institution_name : name ?? institution_name) ?? "Brokerage account"
            guard let number, !number.isEmpty else { return label }
            return "\(label) · \(number.suffix(4))"
        }
    }

    private struct ForeignCashFlow: Decodable {
        let date: String
        let kind: PerformanceFlow.Kind
        let currency: String
        let amount: String
    }

    private struct Conversion: Decodable {
        let usdAmount: Decimal
        let fx: HistoricalCashFX
    }

    private struct Activity: Decodable, Identifiable {
        let id: String
        let date: String
        let label: String
        let amount: Decimal?
        let currency: String?
        let units: Decimal?
        let fee: Decimal?
        let symbol: String?
        let cashFlow: PerformanceFlow?
        let foreignCashFlow: ForeignCashFlow?

        var isInternalCashTransfer: Bool {
            label == "Incoming cash transfer between accounts" || label == "Outgoing cash transfer between accounts"
        }
    }

    private struct Page: Decodable {
        var activities: [Activity]
        var omitted: Int
        let nextOffset: Int?
        let snapshot: String?
        let syncedAt: String?
    }

    private struct Registration: Decodable {
        let registered: Bool
    }

    let userId: UUID
    let start: String
    let end: String
    let imported: Set<String>
    let canInclude: Bool
    private enum Review {
        case transfer((PerformanceFlow) -> Void)
        case income(selected: String?, review: (CashIncomeBrokerPayment) -> Void)
        case reinvestments((BrokerReinvestment) -> Void)
    }
    private let review: Review

    init(userId: UUID, start: String, end: String, imported: Set<String>, canInclude: Bool,
         include: @escaping (PerformanceFlow) -> Void) {
        self.userId = userId
        self.start = start
        self.end = end
        self.imported = imported
        self.canInclude = canInclude
        review = .transfer(include)
    }

    init(userId: UUID, start: String, end: String, imported: Set<String>, canInclude: Bool,
         selectedIncomeID: String?, reviewIncome: @escaping (CashIncomeBrokerPayment) -> Void) {
        self.userId = userId
        self.start = start
        self.end = end
        self.imported = imported
        self.canInclude = canInclude
        review = .income(selected: selectedIncomeID, review: reviewIncome)
    }

    init(userId: UUID, start: String, end: String, imported: Set<String>,
         reviewReinvestment: @escaping (BrokerReinvestment) -> Void) {
        self.userId = userId
        self.start = start
        self.end = end
        self.imported = imported
        canInclude = true
        review = .reinvestments(reviewReinvestment)
    }

    private var activityTitle: String {
        switch review {
        case .transfer: "Broker activity"
        case .income: "Broker-reported payments"
        case .reinvestments: "Broker-reported reinvestments"
        }
    }

    private var emptyActivityTitle: String {
        switch review {
        case .transfer: "cash or corporate activity"
        case .income: "payments"
        case .reinvestments: "reinvestments"
        }
    }

    private func matchesReview(_ activity: Activity) -> Bool {
        switch review {
        case .transfer: true
        case .income: CashIncomeKind(brokerLabel: activity.label) != nil
        case .reinvestments: activity.label == BrokerReinvestment.label
        }
    }

    @State private var accounts: [Account]?
    @State private var accountId = ""
    @State private var page: Page?
    @State private var busy = false
    @State private var error: String?
    @State private var conversions: [String: Conversion] = [:]
    @State private var lookup: String?
    @State private var failedLookup: String?

    var body: some View {
        Section {
            if let accounts {
                if accounts.isEmpty {
                    Text("No linked accounts. Connect a brokerage from Portfolio.")
                } else {
                    Picker("Brokerage account", selection: $accountId) {
                        ForEach(accounts) { Text($0.title()).tag($0.id) }
                    }
                    .disabled(busy || lookup != nil)
                    .onChange(of: accountId) { _, _ in
                        page = nil
                        error = nil
                        conversions = [:]
                        failedLookup = nil
                    }
                    Button("Load broker activity") { Task { await loadPage(0) } }.disabled(busy || lookup != nil)
                }
            } else {
                Button("Find linked accounts") { Task { await loadAccounts() } }.disabled(busy || lookup != nil)
            }
            if busy { ProgressView("Loading brokerage data") }
            if let error { Text(error).foregroundStyle(.red) }
            if let page {
                if let stamp = page.syncedAt {
                    let date = ISO8601DateFormatter().date(from: stamp)
                        ?? (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(stamp))
                    if let date { Text("Imported \(date.formatted())").font(.footnote) }
                    Button("Fetch from broker") { Task { await loadPage(0, preferCached: false) } }
                        .disabled(busy || lookup != nil)
                }
                if page.omitted > 0 {
                    Text("Some records had missing or unsupported data. Check your statement for complete activity.")
                        .font(.footnote)
                }
                let activities = page.activities.filter(matchesReview)
                if activities.isEmpty {
                    if page.nextOffset == nil {
                        Text("No reported \(emptyActivityTitle) in this date range.")
                    } else {
                        Text("No reported \(emptyActivityTitle) on the loaded pages.")
                    }
                }
                ForEach(activities) { activity in
                    switch review {
                    case .transfer(let include): activityRow(activity, include: include)
                    case .income(let selected, let review): incomeRow(activity, selected: selected, review: review)
                    case .reinvestments(let review): reinvestmentRow(activity, review: review)
                    }
                }
                if let next = page.nextOffset {
                    Button("Load more activity") { Task { await loadPage(next) } }.disabled(busy || lookup != nil)
                }
            }
        } header: {
            Text(activityTitle)
        } footer: {
            switch review {
            case .income:
                Text("Review the reported payment and enter the cash received from your statement. Check for any previous manual entry for the same payment.")
            case .reinvestments:
                Text("Choose an event to attach its reference. Use the statement to confirm the dates, shares and amounts.")
            case .transfer:
                Text("Include cash that entered or left the portfolio you valued. For a transfer between included accounts, leave both entries out. Compare with transfers already entered from statements. SnapTrade refreshes activity daily. For foreign cash, look up an ECB reference rate or enter the USD amount from your statement.")
            }
        }
    }

    private func activityRow(_ activity: Activity, include: @escaping (PerformanceFlow) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text([activity.label, activity.symbol].compactMap { $0 }.joined(separator: " · "))
            let amount = activity.amount.map { "\($0.formatted()) \(activity.currency ?? "")" }
            let units = activity.units.flatMap { $0 == 0 ? nil : "\($0.formatted()) units" }
            let fee = activity.fee.flatMap { $0 == 0 ? nil : "Fee \($0.formatted()) \(activity.currency ?? "")" }
            Text([activity.date, amount, units, fee].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
            let internalTransfer = activity.isInternalCashTransfer
            let converted = internalTransfer ? nil : conversions[activity.id]
            let included = imported.contains(activity.id)
            if internalTransfer {
                Text(included
                    ? "Already included. Remove it from the period if both accounts were in your valuations."
                    : "Leave this out when both accounts are in your valuations. Use a manual entry if cash crossed the portfolio boundary.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let converted {
                Text("\(converted.usdAmount.formatted(.currency(code: "USD"))) · \(converted.fx.details)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if failedLookup == activity.id {
                Text("Historical exchange rate unavailable. You can enter the USD amount manually.")
                    .font(.caption).foregroundStyle(.red)
            }
            if !internalTransfer, activity.date > start, let foreign = activity.foreignCashFlow, converted == nil, !included {
                Button(lookup == activity.id ? "Looking up rate…" : "Look up USD value") {
                    Task { await convert(activity.id, foreign) }
                }
                .buttonStyle(.borderless)
                .disabled(busy || lookup != nil || !canInclude)
            }
            if !internalTransfer && activity.date > start && (activity.cashFlow != nil || converted != nil || included) {
                Button(included ? "Included" : "Include transfer") {
                    if var flow = activity.cashFlow {
                        flow.snaptrade_id = activity.id
                        include(flow)
                    } else if let foreign = activity.foreignCashFlow, let converted {
                        include(PerformanceFlow(date: foreign.date, kind: foreign.kind, amount: converted.usdAmount,
                            snaptrade_id: activity.id, fx: converted.fx))
                    }
                }
                .buttonStyle(.borderless)
                .disabled(included || !canInclude)
                .accessibilityLabel(included ? "Already included" : "Include \(activity.label) on \(activity.date)")
            }
        }
    }

    private func incomeRow(_ activity: Activity, selected: String?,
                           review: @escaping (CashIncomeBrokerPayment) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text([activity.label, activity.symbol].compactMap { $0 }.joined(separator: " · "))
            Text(activity.date).font(.caption).foregroundStyle(.secondary)
            if let amount = activity.amount, amount > 0, CashIncomeDraft.amount(amount.description) != nil,
               let currency = activity.currency, currency.wholeMatch(of: /[A-Z]{3}/) != nil,
               let kind = CashIncomeKind(brokerLabel: activity.label) {
                Text("Reported \(cashIncomeMoney(amount.description, currency))").font(.caption).foregroundStyle(.secondary)
                let included = imported.contains(activity.id)
                Button(included ? "Already recorded" : selected == activity.id ? "Selected" : "Review payment") {
                    let account = accounts?.first(where: { $0.id == accountId })?.title(masked: true) ?? ""
                    review(CashIncomeBrokerPayment(id: activity.id, date: activity.date, kind: kind, symbol: activity.symbol,
                                                   amount: amount.description, currency: currency, account: String(account.prefix(100))))
                }
                .buttonStyle(.borderless)
                .disabled(included || selected == activity.id || busy || !canInclude)
            } else {
                Text("Check the statement for a cash payment or reversal.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func reinvestmentRow(_ activity: Activity, review: @escaping (BrokerReinvestment) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text([activity.label, activity.symbol].compactMap { $0 }.joined(separator: " · "))
            let amount = activity.amount.map { "\($0.formatted()) \(activity.currency ?? "")" }
            let units = activity.units.map { "\($0.description) units" }
            Text([activity.date, amount, units].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            if let reportedUnits = activity.units, reportedUnits < 0 {
                Text("Check this possible reversal against your statement.").font(.caption).foregroundStyle(.secondary)
            } else {
                let included = imported.contains(activity.id)
                Button(included ? "Already recorded" : "Review reinvestment") {
                    review(BrokerReinvestment(id: activity.id, date: activity.date, symbol: activity.symbol,
                                              currency: activity.currency, amount: activity.amount?.description,
                                              units: activity.units?.description))
                }
                .buttonStyle(.borderless)
                .disabled(included || busy)
            }
        }
    }

    private func convert(_ id: String, _ foreign: ForeignCashFlow) async {
        guard lookup == nil, !busy else { return }
        lookup = id
        failedLookup = nil
        defer { lookup = nil }
        do {
            let data = try await SecureBackend.invoke("market-workspace", body: [
                "action": "historicalFx", "date": foreign.date, "currency": foreign.currency, "amount": foreign.amount,
            ], expectedUserID: userId)
            struct Response: Decodable { let data: Conversion }
            conversions[id] = try JSONDecoder().decode(Response.self, from: data).data
        } catch {
            failedLookup = id
        }
    }

    private func brokerage<Response: Decodable>(_ operation: String, params: [String: Any] = [:]) async throws -> Response {
        let data = try await SecureBackend.invoke("snaptrade-proxy", body: ["operation": operation, "params": params], expectedUserID: userId)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func loadAccounts() async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let status: Registration = try await brokerage("status")
            let linked: [Account] = status.registered ? try await brokerage("listAccounts") : []
            accountId = linked.first?.id ?? ""
            accounts = linked
        } catch {
            self.error = "Couldn’t load brokerage accounts. Try again."
        }
    }

    private func loadPage(_ offset: Int, preferCached: Bool = true) async {
        guard !busy, lookup == nil, !accountId.isEmpty else { return }
        busy = true
        error = nil
        defer { busy = false }
        if offset == 0 {
            conversions = [:]
            failedLookup = nil
        }
        do {
            var params: [String: Any] = [
                "accountId": accountId, "startDate": start, "endDate": end, "offset": offset, "preferCached": preferCached,
            ]
            if offset > 0, let snapshot = page?.snapshot { params["snapshot"] = snapshot }
            var result: Page = try await brokerage("accountActivities", params: params)
            if let prior = page, offset > 0 {
                let updatedIds = Set(result.activities.map(\.id))
                result.activities = prior.activities.filter { !updatedIds.contains($0.id) } + result.activities
                result.omitted += prior.omitted
            }
            page = result
        } catch let failure as SecureBackend.FunctionError where failure.code == "ACTIVITY_SNAPSHOT_CHANGED" {
            self.error = "Broker activity changed. Reload from the first page."
        } catch {
            self.error = "Couldn’t load brokerage activity. Try again."
        }
    }
}
