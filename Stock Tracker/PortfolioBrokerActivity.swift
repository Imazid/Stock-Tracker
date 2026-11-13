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
    }

    private struct Page: Decodable {
        var activities: [Activity]
        var omitted: Int
        let nextOffset: Int?
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

    var body: some View {
        Section {
            if let accounts {
                if accounts.isEmpty {
                    Text("No linked accounts. Connect a brokerage from Portfolio.")
                } else {
                    Picker("Brokerage account", selection: $accountId) {
                        ForEach(accounts) { Text($0.title).tag($0.id) }
                    }
                    .disabled(busy)
                    .onChange(of: accountId) { _, _ in
                        page = nil
                        error = nil
                    }
                    Button("Load broker activity") { Task { await loadPage(0) } }.disabled(busy)
                }
            } else {
                Button("Find linked accounts") { Task { await loadAccounts() } }.disabled(busy)
            }
            if busy { ProgressView("Loading brokerage data") }
            if let error { Text(error).foregroundStyle(.red) }
            if let page {
                if page.omitted > 0 {
                    Text("Some records had missing or unsupported data. Check your statement for complete activity.")
                        .font(.footnote)
                }
                if page.activities.isEmpty { Text("No reported cash or corporate activity in this date range.") }
                ForEach(page.activities) { activity in
                    activityRow(activity)
                }
                if let next = page.nextOffset {
                    Button("Load more activity") { Task { await loadPage(next) } }.disabled(busy)
                }
            }
        } header: {
            Text("Broker activity")
        } footer: {
            Text("Include cash that entered or left the portfolio you valued. For a transfer between included accounts, leave both entries out. Compare with transfers already entered from statements. SnapTrade refreshes activity daily. Enter non-USD flows manually after conversion at the activity date.")
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
            if let flow = activity.cashFlow, flow.date > start {
                let included = imported.contains(activity.id)
                Button(included ? "Included" : "Include transfer") {
                    var selected = flow
                    selected.snaptrade_id = activity.id
                    include(selected)
                }
                .buttonStyle(.borderless)
                .disabled(included || !canInclude)
                .accessibilityLabel(included ? "Already included" : "Include \(activity.label) on \(activity.date)")
            }
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

    private func loadPage(_ offset: Int) async {
        guard !busy, !accountId.isEmpty else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            var result: Page = try await brokerage("accountActivities", params: [
                "accountId": accountId, "startDate": start, "endDate": end, "offset": offset,
            ])
            if let prior = page, offset > 0 {
                let updatedIds = Set(result.activities.map(\.id))
                result.activities = prior.activities.filter { !updatedIds.contains($0.id) } + result.activities
                result.omitted += prior.omitted
            }
            page = result
        } catch {
            self.error = "Couldn’t load brokerage activity. Try again."
        }
    }
}
