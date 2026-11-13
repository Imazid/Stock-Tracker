import SwiftUI

struct PortfolioBrokerActivity: View {
    private struct Account: Decodable, Identifiable {
        let id: String
        let name: String?
        let institution_name: String?
        let number: String?

        var title: String {
            let label = name ?? institution_name ?? "Brokerage account"
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
    let include: (PerformanceFlow) -> Void

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
                        ForEach(accounts) { Text($0.title).tag($0.id) }
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
                if page.activities.isEmpty { Text("No reported cash or corporate activity in this date range.") }
                ForEach(page.activities) { activity in
                    activityRow(activity)
                }
                if let next = page.nextOffset {
                    Button("Load more activity") { Task { await loadPage(next) } }.disabled(busy || lookup != nil)
                }
            }
        } header: {
            Text("Broker activity")
        } footer: {
            Text("Include cash that entered or left the portfolio you valued. For a transfer between included accounts, leave both entries out. Compare with transfers already entered from statements. SnapTrade refreshes activity daily. For foreign cash, look up an ECB reference rate or enter the USD amount from your statement.")
        }
    }

    private func activityRow(_ activity: Activity) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text([activity.label, activity.symbol].compactMap { $0 }.joined(separator: " · "))
            let amount = activity.amount.map { "\($0.formatted()) \(activity.currency ?? "")" }
            let units = activity.units.flatMap { $0 == 0 ? nil : "\($0.formatted()) units" }
            let fee = activity.fee.flatMap { $0 == 0 ? nil : "Fee \($0.formatted()) \(activity.currency ?? "")" }
            Text([activity.date, amount, units, fee].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
            let converted = conversions[activity.id]
            let included = imported.contains(activity.id)
            if let converted {
                Text("\(converted.usdAmount.formatted(.currency(code: "USD"))) · \(converted.fx.details)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if failedLookup == activity.id {
                Text("Historical exchange rate unavailable. You can enter the USD amount manually.")
                    .font(.caption).foregroundStyle(.red)
            }
            if activity.date > start, let foreign = activity.foreignCashFlow, converted == nil, !included {
                Button(lookup == activity.id ? "Looking up rate…" : "Look up USD value") {
                    Task { await convert(activity.id, foreign) }
                }
                .buttonStyle(.borderless)
                .disabled(busy || lookup != nil || !canInclude)
            }
            if activity.date > start && (activity.cashFlow != nil || converted != nil || included) {
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
