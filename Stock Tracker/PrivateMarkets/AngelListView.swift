import SwiftUI
import TradingCore

struct AngelListView: View {
    @EnvironmentObject private var auth: SupabaseAuthManager
    @EnvironmentObject private var store: PrivateMarketsStore
    private let link = AngelListLink.shared
    @State private var connected = false
    @State private var busy = false
    @State private var tools: [AngelListLink.Tool] = []
    @State private var error: String?
    @State private var showDisconnect = false

    var body: some View {
        List {
            Section {
                Text("Connect through AngelList to read the fund records your account can access. Access is stored in this device’s Keychain.")
                    .font(.footnote).foregroundStyle(.secondary)
                if auth.userId == nil {
                    Text("Sign in to Stock Tracker first.")
                } else if connected {
                    Button("Refresh available records") { refresh() }.disabled(busy)
                    Button("Disconnect AngelList", role: .destructive) { showDisconnect = true }.disabled(busy)
                } else {
                    Button("Connect AngelList") { connect() }.disabled(busy)
                }
                if busy { ProgressView() }
                if let error { Text(error).foregroundStyle(.secondary) }
            }
            if connected {
                Section("Authorized fund records") {
                    if tools.isEmpty && !busy { Text("AngelList has no compatible records available for this connection.") }
                    ForEach(tools) { tool in
                        if let owner = auth.userId {
                            NavigationLink(tool.title) { AngelListRecordView(link: link, tool: tool, owner: owner) }
                        }
                    }
                }
            }
        }
        .navigationTitle("AngelList Link")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Disconnect AngelList?", isPresented: $showDisconnect, titleVisibility: .visible) {
            Button("Disconnect AngelList", role: .destructive, action: disconnect)
        } message: {
            Text("This removes saved AngelList statements and their values from this device’s portfolio.")
        }
        .task(id: auth.userId) {
            tools = []
            connected = auth.userId.map(link.isConnected) ?? false
            if connected { refresh() }
        }
    }

    private func connect() {
        perform { owner in
            try await link.connect(owner) { auth.userId == owner }
            guard auth.userId == owner else { return }
            connected = true
            tools = try await link.tools(owner)
        }
    }

    private func refresh() {
        perform { owner in
            let available = try await link.tools(owner)
            guard auth.userId == owner else { return }
            tools = available
        }
    }

    private func disconnect() {
        perform { owner in
            try store.removeAngelListSnapshots(owner: owner)
            try await link.disconnect(owner)
            guard auth.userId == owner else { return }
            connected = false
            tools = []
        }
    }

    private func perform(_ operation: @escaping (UUID) async throws -> Void) {
        guard let owner = auth.userId, !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do { try await operation(owner) }
            catch { if auth.userId == owner { self.error = error.localizedDescription } }
        }
    }
}

private struct AngelListRecordView: View {
    @EnvironmentObject private var auth: SupabaseAuthManager
    let link: AngelListLink
    let tool: AngelListLink.Tool
    let owner: UUID
    @State private var fields: [String: String] = [:]
    @State private var result: AngelListLink.Records?
    @State private var fetchedAt: Date?
    @State private var error: String?
    @State private var busy = false

    private var offersStatementReview: Bool {
        tool.id == "get_capital_account" || tool.id == "list_capital_accounts"
    }

    var body: some View {
        Form {
            if !tool.description.isEmpty {
                Text(tool.description).font(.footnote).foregroundStyle(.secondary)
            }
            if !tool.fields.isEmpty {
                Section("Record filters") {
                    ForEach(tool.fields) { field in
                        VStack(alignment: .leading, spacing: 4) {
                            TextField(field.title + (field.required ? " (required)" : ""),
                                      text: Binding(get: { fields[field.id, default: ""] }, set: { fields[field.id] = $0 }))
                                .autocorrectionDisabled().textInputAutocapitalization(.never)
                            if let detail = field.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            Section {
                Button("Read records", action: load).disabled(busy || auth.userId != owner)
                if busy { ProgressView() }
                if let error { Text(error).foregroundStyle(.secondary) }
            }
            if let result, let fetchedAt, auth.userId == owner {
                Section("AngelList records") {
                    Text("Retrieved \(fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.footnote).foregroundStyle(.secondary)
                    if offersStatementReview {
                        ForEach(result.statements) { row in
                            NavigationLink {
                                AngelListSnapshotEditor(record: row, fetchedAt: fetchedAt, owner: owner,
                                                        connectionID: result.connectionID)
                            } label: {
                                Label("Review \(row.id)", systemImage: "doc.text.magnifyingglass")
                            }
                        }
                        if result.statements.isEmpty {
                            Text("Open a structured capital account response to review fields for your portfolio.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    DisclosureGroup("View response") {
                        Text(result.text).font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle(tool.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func load() {
        busy = true
        result = nil
        error = nil
        Task {
            defer { busy = false }
            do {
                let response = try await link.call(tool, arguments: fields, owner: owner)
                guard auth.userId == owner, link.isCurrentConnection(response.connectionID, owner: owner) else { return }
                result = response
                fetchedAt = .now
            } catch {
                if auth.userId == owner { self.error = error.localizedDescription }
            }
        }
    }
}

private struct AngelListSnapshotEditor: View {
    @EnvironmentObject private var auth: SupabaseAuthManager
    @EnvironmentObject private var store: PrivateMarketsStore
    @Environment(\.dismiss) private var dismiss

    let record: PrivateFundSnapshot.Record
    let fetchedAt: Date
    let owner: UUID
    let connectionID: String

    @State private var selection: [Field: String] = [:]
    @State private var kind: PrivateAssetClass = .ventureFund
    @State private var replacesManualHoldingID: UUID?
    @State private var confirmed = false
    @State private var error: String?

    private enum Field: String, CaseIterable, Identifiable {
        case reference = "Capital account ID"
        case name = "Fund or vehicle name"
        case currency = "Currency code"
        case date = "Statement date"
        case netAssetValue = "Net asset value (NAV)"
        case commitment = "Capital committed"
        case paidIn = "Paid-in capital"
        case distributions = "Distributions received"

        var id: String { rawValue }
    }

    private var draft: PrivateFundSnapshot? {
        let keys = selection.values.filter { !$0.isEmpty }
        guard Set(keys).count == keys.count, let reference = value(.reference), let name = value(.name),
              let currency = value(.currency), let date = value(.date) else { return nil }
        return PrivateFundSnapshot.make(reference: reference, name: name, assetClass: kind, currency: currency, asOf: date,
                                        netAssetValue: value(.netAssetValue), commitment: value(.commitment),
                                        paidIn: value(.paidIn), distributions: value(.distributions),
                                        replacesManualHoldingID: replacesManualHoldingID, retrievedAt: fetchedAt)
    }

    var body: some View {
        Form {
            if auth.userId == owner {
                Section {
                    Text("Choose fields from one capital account. Use the account’s own balance and statement date.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Picker("Investment type", selection: $kind) {
                        ForEach(PrivateAssetClass.allCases.filter(\.isFund), id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }
                Section("Statement identity") {
                    selector(.reference)
                    selector(.name)
                    selector(.currency)
                    selector(.date)
                    Text("Use the same capital account ID when reviewing a newer statement.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Reported balances") {
                    selector(.netAssetValue)
                    selector(.commitment)
                    selector(.paidIn)
                    selector(.distributions)
                    Text("Choose amounts in whole currency units, such as dollars. A dated NAV can appear in your unified allocation.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !store.independentManualHoldings.isEmpty {
                    Section("Portfolio allocation") {
                        Picker("Same position already tracked", selection: $replacesManualHoldingID) {
                            Text("None").tag(nil as UUID?)
                            ForEach(store.independentManualHoldings) { holding in
                                Text("\(holding.name) · \(holding.currency)").tag(Optional(holding.id))
                            }
                        }
                        Text("Allocation uses the latest available valuation for a linked position. Your manual holding and cash flows stay available.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Toggle("This capital account belongs to me or my investing entity", isOn: $confirmed)
                    Text("Stock Tracker saves these selected fields on this device.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let draft {
                        Button("Save to My Private Portfolio") { save(draft) }
                            .disabled(!confirmed)
                    } else {
                        Text("Select four identity fields and at least one balance. Dates must use the statement date and amounts must be plain numbers.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let error { Text(error).foregroundStyle(.orange) }
                }
            }
        }
        .navigationTitle("Review Capital Account")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: kind) { _, _ in confirmed = false }
        .onChange(of: replacesManualHoldingID) { _, _ in confirmed = false }
    }

    private func selector(_ field: Field) -> some View {
        Picker(field.rawValue, selection: Binding(
            get: { selection[field] ?? "" },
            set: { selection[field] = $0; confirmed = false; error = nil }
        )) {
            Text("Select field").tag("")
            ForEach(record.fields) { source in
                Text("\(source.id) · \(source.value)").tag(source.id)
            }
        }
    }

    private func value(_ field: Field) -> String? {
        guard let id = selection[field] else { return nil }
        return record.fields.first { $0.id == id }?.value
    }

    private func save(_ snapshot: PrivateFundSnapshot) {
        guard auth.userId == owner, confirmed else { return }
        do {
            try store.saveAngelListSnapshot(snapshot, owner: owner, connectionID: connectionID)
            dismiss()
        } catch is CancellationError {
        } catch { self.error = error.localizedDescription }
    }
}
