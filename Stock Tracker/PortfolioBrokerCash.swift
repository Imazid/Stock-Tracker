import SwiftUI

struct PortfolioBrokerCash: View {
    let userId: UUID
    let hidesValues: Bool

    private struct Report: Decodable {
        let accounts: [Account]
        let duplicatesSkipped: Int
    }

    private struct Account: Decodable, Identifiable {
        let id: String
        let label: String
        let paper: Bool
        let status: String
        let syncedAt: String?
        let incomplete: Bool?
        let balances: [Balance]
    }

    private struct Balance: Decodable, Identifiable {
        let currency: String
        let amount: String?
        var id: String { currency }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var report: Report?
    @State private var loading = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            List {
                if loading { ProgressView("Checking cash balances") }
                if failed {
                    Section {
                        Text(report == nil ? "Couldn’t load brokerage cash." : "The balance check failed. Showing the previous result.")
                        Button("Try again") { Task { await load() } }
                    }
                }
                if let report {
                    ForEach(report.accounts) { account in
                        Section {
                            if account.balances.isEmpty {
                                Text("Cash balance unavailable.").foregroundStyle(.secondary)
                            }
                            ForEach(account.balances) { balance in
                                LabeledContent(balance.currency) {
                                    Text(balance.amount.map { hidesValues ? "••••" : cashIncomeMoney($0, balance.currency) } ?? "Unavailable")
                                        .monospacedDigit()
                                }
                                .accessibilityIdentifier("portfolio.brokerCash.balance.\(account.id).\(balance.currency)")
                            }
                            if account.incomplete == true {
                                Text("Some balance amounts are unavailable.").font(.footnote).foregroundStyle(.secondary)
                            }
                        } header: {
                            Text(account.paper ? "\(account.label) · Paper account" : account.label)
                        } footer: {
                            Text(syncLabel(account))
                        }
                    }
                    Section {
                        if report.accounts.isEmpty {
                            Text("No linked investment accounts with open status.")
                        } else {
                            Text("SnapTrade cash can include money-market funds. Holdings and saved returns use their own records.")
                            if report.duplicatesSkipped > 0 {
                                Text("Duplicate connections identified by the broker are shown once.")
                            }
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Brokerage cash")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Check balances", systemImage: "arrow.clockwise") { Task { await load() } }
                        .disabled(loading)
                }
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func syncLabel(_ account: Account) -> String {
        let prefix = account.status == "disconnected" ? "Disconnected · " : ""
        let date = account.syncedAt.flatMap { try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0) }
        return prefix + (date.map { "Last balance sync \($0.formatted(date: .abbreviated, time: .shortened))" }
            ?? "Balance sync time unavailable")
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        failed = false
        defer { loading = false }
        do {
            let data = try await SecureBackend.invoke("snaptrade-proxy", body: ["operation": "portfolioCash"], expectedUserID: userId)
            try Task.checkCancellation()
            report = try JSONDecoder().decode(Report.self, from: data)
        } catch is CancellationError {
        } catch {
            failed = true
        }
    }
}
