import Auth
import Foundation
import OSLog
import SwiftUI
import TradingCore

private enum CompanyAlertKind: String, Decodable, Identifiable {
    case above = "price_above", below = "price_below", volume = "volume_above"
    case filing, insider, news

    var id: Self { self }
    var title: LocalizedStringResource {
        switch self {
        case .above: "Price at or above"
        case .below: "Price at or below"
        case .volume: "Session volume at or above"
        case .filing: "New SEC filing"
        case .insider: "New ownership filing"
        case .news: "New company news"
        }
    }

    var usesThreshold: Bool { self == .above || self == .below || self == .volume }
}

private struct CompanyAlertsInbox: Decodable {
    struct Rule: Identifiable, Decodable {
        let id: UUID
        let kind: CompanyAlertKind
        let threshold: Decimal?
        let currency: String?
        let lastCheckedAt: Date?
        let lastProblem: String?
    }

    let alerts: [Rule]
    let events: [CompanyAlertEvent]
    let monitoring: Bool
    let availableKinds: [CompanyAlertKind]
}

private struct CompanyAlertEvent: Decodable, Identifiable {
    struct Listing: Decodable { let instrumentId: String }
    let id: Int64
    let title: String
    let url: URL?
    let occurredAt: Date
    let companyResearchAlerts: Listing?

    var listing: Instrument? {
        guard let id = companyResearchAlerts?.instrumentId else { return nil }
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let venue = Venue(rawValue: String(parts[0])), venue != .crypto,
              !parts[1].isEmpty else { return nil }
        return .listed(String(parts[1]), on: venue)
    }

    var sourceURL: URL? {
        guard let url, url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}

private enum CompanyAlertsService {
    private struct Response<Value: Decodable>: Decodable { let data: Value }
    private struct Acknowledgement: Decodable { let ok: Bool }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { value in
            let container = try value.singleValueContainer()
            let date = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = formatter.date(from: date) { return parsed }
            formatter.formatOptions = [.withInternetDateTime]
            if let parsed = formatter.date(from: date) { return parsed }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid alert timestamp.")
        }
        return decoder
    }

    static func read(_ instrument: Instrument, owner: UUID) async throws -> CompanyAlertsInbox {
        try await call(instrument, owner: owner, operation: "read")
    }

    static func create(_ instrument: Instrument, owner: UUID, kind: CompanyAlertKind, threshold: Decimal?) async throws {
        var fields: [String: Any] = ["kind": kind.rawValue]
        if let threshold { fields["threshold"] = NSDecimalNumber(decimal: threshold) }
        let response: Acknowledgement = try await call(instrument, owner: owner, operation: "create", fields: fields)
        guard response.ok else { throw URLError(.badServerResponse) }
    }

    static func remove(_ instrument: Instrument, owner: UUID, id: UUID) async throws {
        let response: Acknowledgement = try await call(instrument, owner: owner, operation: "remove", fields: ["id": id.uuidString])
        guard response.ok else { throw URLError(.badServerResponse) }
    }

    static func recent(owner: UUID) async throws -> [CompanyAlertEvent] {
        try await call(["action": "companyAlertActivity"], owner: owner)
    }

    private static func call<Value: Decodable>(
        _ instrument: Instrument, owner: UUID, operation: String, fields: [String: Any] = [:]
    ) async throws -> Value {
        var body = fields
        body["action"] = "companyAlerts"
        body["instrumentId"] = instrument.id
        body["operation"] = operation
        return try await call(body, owner: owner)
    }

    private static func call<Value: Decodable>(_ body: [String: Any], owner: UUID) async throws -> Value {
        let data = try await SecureBackend.invoke("market-workspace", body: body, expectedUserID: owner)
        try Task.checkCancellation()
        guard SupabaseManager.auth.currentUser?.id == owner else { throw CancellationError() }
        return try decoder().decode(Response<Value>.self, from: data).data
    }
}

struct CompanyAlertsScreen: View {
    let instrument: Instrument
    let owner: UUID

    @Environment(\.locale) private var locale
    @FocusState private var thresholdFocused: Bool
    @State private var inbox: CompanyAlertsInbox?
    @State private var kind = CompanyAlertKind.above
    @State private var thresholdText = ""
    @State private var loading = false
    @State private var saving = false
    @State private var error: String?
    @State private var removal: CompanyAlertsInbox.Rule?

    private var activeAccount: Bool { SupabaseManager.auth.currentUser?.id == owner }

    private var threshold: Decimal? {
        guard let value = try? Decimal(thresholdText.trimmingCharacters(in: .whitespacesAndNewlines),
                                       format: .number.locale(locale), lenient: false),
              value > 0, value <= 1_000_000_000_000_000 else { return nil }
        return value
    }

    var body: some View {
        List {
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("companyAlerts.error")
                    Button("Refresh alerts") { Task { await load() } }
                        .disabled(loading || saving)
                }
            }
            if let inbox {
                if inbox.monitoring {
                    if let selected = inbox.availableKinds.contains(kind) ? kind : inbox.availableKinds.first {
                        editor(selected, options: inbox.availableKinds)
                    }
                } else {
                    Section { Text("Scheduled checks are temporarily unavailable.").foregroundStyle(.secondary) }
                }
                Section("Saved rules") {
                    if inbox.alerts.isEmpty { Text("No company alerts for this listing.").foregroundStyle(.secondary) }
                    ForEach(inbox.alerts) { rule in
                        ruleRow(rule)
                    }
                }
                Section("Recent triggers") {
                    if inbox.events.isEmpty { Text("No triggers yet.").foregroundStyle(.secondary) }
                    ForEach(inbox.events) { event in
                        if let url = event.sourceURL {
                            Link(destination: url) { CompanyAlertEventLabel(event: event) }
                        } else {
                            CompanyAlertEventLabel(event: event)
                        }
                    }
                }
            } else if error == nil {
                ProgressView("Loading alerts…")
            }
        }
        .navigationTitle("\(instrument.symbol) Alerts")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .task { await load() }
        .refreshable { await load() }
        .alert("Remove company alert?", isPresented: Binding(
            get: { removal != nil },
            set: { if !$0 { removal = nil } }
        ), presenting: removal) { rule in
            Button("Remove alert", role: .destructive) {
                Task {
                    await change(remove: rule.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This also removes its triggers from Activity.")
        }
    }

    private func editor(_ selected: CompanyAlertKind, options: [CompanyAlertKind]) -> some View {
        Section {
            Picker("Trigger", selection: Binding(get: { selected }, set: { kind = $0 })) {
                ForEach(options) { option in Text(option.title).tag(option) }
            }
            .accessibilityIdentifier("companyAlerts.kind")
            if selected.usesThreshold {
                TextField(selected == .volume ? "Threshold (shares)" : "Threshold (\(instrument.currency))", text: $thresholdText)
                    .keyboardType(.decimalPad)
                    .focused($thresholdFocused)
                    .accessibilityIdentifier("companyAlerts.threshold")
            }
            Button("Add alert") {
                let value = selected.usesThreshold ? threshold : nil
                thresholdFocused = false
                Task { await change(add: selected, threshold: value) }
            }
            .disabled(loading || saving || (selected.usesThreshold && threshold == nil))
            .accessibilityIdentifier("companyAlerts.add")
        } header: {
            Text("New alert")
        } footer: {
            Text("Scheduled triggers appear here and in Activity. Prices use the listing’s currency.")
        }
    }

    private func ruleRow(_ rule: CompanyAlertsInbox.Rule) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(rule.kind.title)
            if let threshold = rule.threshold {
                Text("\(threshold.formatted()) \(rule.currency ?? "shares")").monospacedDigit()
                    .accessibilityIdentifier("companyAlerts.savedThreshold")
            }
            if let problem = rule.lastProblem {
                Text(problem).font(.footnote).foregroundStyle(.secondary)
            } else if let checkedAt = rule.lastCheckedAt {
                Text("Checked \(checkedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Waiting for the first check").font(.footnote).foregroundStyle(.secondary)
            }
            Button("Remove alert", role: .destructive) { removal = rule }
                .font(.footnote)
                .buttonStyle(.borderless)
                .disabled(saving || loading)
                .accessibilityIdentifier("companyAlerts.remove")
        }
    }

    private func load() async {
        guard activeAccount, !loading, !saving else { return }
        loading = true
        error = nil
        defer { loading = false }
        do { inbox = try await CompanyAlertsService.read(instrument, owner: owner) }
        catch is CancellationError {}
        catch { self.error = (error as? SecureBackend.FunctionError)?.message ?? "Couldn’t load company alerts." }
    }

    private func change(add kind: CompanyAlertKind? = nil, threshold: Decimal? = nil, remove id: UUID? = nil) async {
        guard activeAccount, !saving, !loading else { return }
        saving = true
        error = nil
        defer { saving = false }
        do {
            if let kind {
                try await CompanyAlertsService.create(instrument, owner: owner, kind: kind, threshold: threshold)
                thresholdText = ""
            } else if let id {
                try await CompanyAlertsService.remove(instrument, owner: owner, id: id)
            }
        } catch is CancellationError {
            return
        } catch {
            self.error = (error as? SecureBackend.FunctionError)?.message ?? "Couldn’t update the alert. Refresh to check its status."
            return
        }
        do { inbox = try await CompanyAlertsService.read(instrument, owner: owner) }
        catch is CancellationError {}
        catch { self.error = "The alert was updated. Refresh to load the latest history." }
    }
}

private struct CompanyAlertEventLabel: View {
    let event: CompanyAlertEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(event.title)
            Text(event.occurredAt.formatted(date: .abbreviated, time: .shortened))
                .font(.footnote).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("companyAlerts.event.\(event.id)")
    }
}

struct CompanyAlertActivity: View {
    let owner: UUID
    @State private var events: [CompanyAlertEvent]?
    @State private var failed = false
    @State private var loading = false

    var body: some View {
        List {
            if failed {
                Text("Couldn’t load recent company alerts.").foregroundStyle(.secondary)
                Button("Try again") { Task { await load() } }.disabled(loading)
            }
            if let events {
                if events.isEmpty {
                    ContentUnavailableView("No company alerts yet", systemImage: "bell",
                                           description: Text("Set a rule in Company alerts on a stock or fund."))
                }
                ForEach(events) { event in
                    if let listing = event.listing {
                        NavigationLink {
                            CompanyAlertsScreen(instrument: listing, owner: owner)
                        } label: {
                            CompanyAlertEventLabel(event: event)
                        }
                    } else {
                        CompanyAlertEventLabel(event: event)
                    }
                }
            } else if !failed {
                ProgressView("Loading recent triggers…")
            }
        }
        .navigationTitle("Company alerts")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        failed = false
        defer { loading = false }
        do { events = try await CompanyAlertsService.recent(owner: owner) }
        catch is CancellationError {}
        catch {
            let errorCode = (error as? SecureBackend.FunctionError)?.code ?? String((error as NSError).code)
            AppLogger.sync.notice("Company alert history fetch failed with code \(errorCode, privacy: .public)")
            failed = true
        }
    }
}
