import SwiftUI
import UserNotifications

struct PrivateInvestorView: View {
    @EnvironmentObject private var auth: SupabaseAuthManager
    @State private var country = "AU"
    @State private var declaredClass = "unknown"
    @State private var records: [PrivateApplication] = []
    @State private var busy = false
    @State private var feedback: String?

    var body: some View {
        Form {
            if auth.userId == nil {
                Text("Sign in from Account to keep an investor profile and view provider records.")
            } else {
                Section("Investor profile") {
                    TextField("Two-letter country code", text: $country)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Picker("Self-declared classification", selection: $declaredClass) {
                        Text("Undeclared").tag("unknown")
                        Text("Retail").tag("retail")
                        Text("Wholesale").tag("wholesale")
                    }
                    Button("Save profile", action: save).disabled(busy || country.utf8.count != 2)
                    Text("Your provider verifies identity, eligibility and supporting documents.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Connected accounts") {
                    NavigationLink("AngelList Link") { AngelListView() }
                    Text("Read authorised fund and capital activity from AngelList.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Provider applications") {
                    if busy && records.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(0..<3) { _ in SearchRowSkeleton() }
                        }
                        .privateLoadingLabel("Loading applications")
                    }
                    if records.isEmpty && !busy { Text("No tracked applications").foregroundStyle(.secondary) }
                    ForEach(records) { record in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(PrivateInput.money(record.requestedAmount, currency: record.currency)).font(.headline)
                            Text(PrivateProvider.directory.first { $0.id == record.provider }?.name ?? record.provider)
                            Text(label(record.status)).font(.subheadline)
                            if let ref = record.providerReference { LabeledContent("Provider reference", value: ref) }
                            if let deadline = record.coolingOffEndsAt {
                                LabeledContent("Provider withdrawal deadline",
                                               value: deadline.formatted(date: .abbreviated, time: .shortened))
                                if let provider = PrivateProvider.directory.first(where: { $0.id == record.provider }) {
                                    Link("Manage or withdraw at \(provider.name)", destination: provider.url)
                                }
                            }
                            if let date = record.confirmedAt {
                                LabeledContent("Ownership confirmed", value: date.formatted(date: .abbreviated, time: .omitted))
                            }
                        }
                    }
                }
            }
            if let feedback { Text(feedback).foregroundStyle(.secondary) }
        }
        .navigationTitle("Investor Profile & Applications")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func label(_ status: String) -> String {
        switch status {
        case "handoff": "Handoff prepared · awaiting provider"
        case "application_received": "Provider received application"
        case "confirmed": "Provider confirmed ownership"
        case "withdrawn": "Provider confirmed withdrawal"
        case "rejected": "Provider declined application"
        default: "Provider status unavailable"
        }
    }

    private func load() async {
        guard auth.userId != nil else { return }
        busy = true
        defer { busy = false }
        do {
            struct Response: Decodable { let profile: PrivateInvestorProfile? }
            let saved: Response = try await PrivateMarketsAPI.request("profile")
            let tracking: PrivateMarketsAPI.Applications = try await PrivateMarketsAPI.request("applications")
            try Task.checkCancellation()
            if let saved = saved.profile {
                country = saved.country
                declaredClass = saved.declaredClass
            }
            records = tracking.applications
        } catch is CancellationError {
        } catch { feedback = error.localizedDescription }
    }

    private func save() {
        busy = true
        feedback = nil
        Task {
            defer { busy = false }
            do {
                try await PrivateMarketsAPI.send("save_profile", ["country": country.uppercased(), "declared_class": declaredClass])
                feedback = "Investor profile saved."
            } catch { feedback = error.localizedDescription }
        }
    }
}

struct PrivateProviderHandoff: View {
    let deal: PrivateDeal
    @Environment(\.openURL) private var openURL
    @State private var amount = ""
    @State private var reviewed = false
    @State private var acknowledged = false
    @State private var busy = false
    @State private var error: String?
    @State private var ready: URL?

    var body: some View {
        Form {
            Section("Provider requirements") {
                LabeledContent("Provider", value: deal.sourceName)
                LabeledContent("Minimum", value: PrivateInput.money(deal.minimum, currency: deal.round.currency))
                NavigationLink("Investor profile & applications") { PrivateInvestorView() }
                if let url = deal.offerDocumentUrl, url.privateSourceIsSafe {
                    Link("Read the current offer document", destination: url)
                }
                Toggle("I reviewed the offer document", isOn: $reviewed)
                Toggle("I understand that I could lose the full investment and may be unable to sell", isOn: $acknowledged)
            }
            Section("Requested amount") {
                TextField("Amount (\(deal.round.currency))", text: $amount).keyboardType(.decimalPad)
                Text("Your provider verifies eligibility, accepts applications and confirms ownership.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Check readiness", action: prepare)
                    .disabled(busy || !reviewed || !acknowledged || (PrivateInput.amount(amount) ?? 0) <= 0)
                if busy { ProgressView("Checking requirements") }
                if let ready { Button("Open \(deal.sourceName) application") { openURL(ready) } }
                if let error { Text(error).foregroundStyle(Color.orange) }
            }
        }
        .navigationTitle("Provider Application")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: amount) { _, _ in ready = nil }
        .onChange(of: reviewed) { _, _ in ready = nil }
        .onChange(of: acknowledged) { _, _ in ready = nil }
    }

    private func prepare() {
        guard let value = PrivateInput.amount(amount), let document = deal.offerDocumentUrl else { return }
        busy = true
        error = nil
        ready = nil
        Task {
            defer { busy = false }
            do {
                let result: PrivateMarketsAPI.Handoff = try await PrivateMarketsAPI.request("handoff", [
                    "opportunity_id": deal.id.uuidString, "amount": NSDecimalNumber(decimal: value).stringValue,
                    "document_url": document.absoluteString, "acknowledged": reviewed && acknowledged
                ])
                guard result.handoffUrl.privateSourceIsSafe else {
                    error = "The provider link could not be verified."
                    return
                }
                if reviewed, acknowledged, PrivateInput.amount(amount) == value {
                    ready = result.handoffUrl
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct PrivateUpdatesView: View {
    @EnvironmentObject private var auth: SupabaseAuthManager
    @EnvironmentObject private var store: PrivateMarketsStore
    @State private var updates: [PrivateCompanyUpdate] = []
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        List {
            Section("Notifications") {
                Toggle("Notify me about company updates", isOn: Binding(
                    get: { store.state.notify }, set: setNotifications))
                    .disabled(auth.userId == nil)
                Text("Stock Tracker checks verified updates when iOS permits background refresh.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Company updates") {
                if loading {
                    VStack(spacing: 0) {
                        ForEach(0..<3) { _ in SearchRowSkeleton() }
                    }
                    .privateLoadingLabel("Checking updates")
                }
                if auth.userId == nil {
                    Text("Sign in from Account to check followed companies.")
                } else if store.state.follows.isEmpty && store.providerHoldings.isEmpty && !loading {
                    Text("Follow a company from its opportunity page.")
                } else if updates.isEmpty && !loading {
                    Text("No verified updates are published for your followed companies or provider holdings.")
                }
                let announcements = updates.filter { $0.kind == "announcement" }
                if !announcements.isEmpty {
                    NavigationLink("Summarise published announcements") {
                        PrivateResearchWorkspace(deals: [], announcements: announcements)
                    }
                }
                ForEach(updates) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.headline)
                        if item.kind == "open_round" || item.kind == "interest" {
                            Text(item.kind == "open_round" ? "Funding round" : "Expression of interest")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        Text("\(item.company.name) · \(item.publishedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text(item.significance)
                        if item.sourceUrl.privateSourceIsSafe { Link("Read source", destination: item.sourceUrl) }
                    }
                }
                if let error { Text(error).foregroundStyle(Color.orange) }
            }
        }
        .navigationTitle("Company Updates")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let id = auth.userId else { return }
        error = nil
        loading = true
        defer { loading = false }
        do {
            await store.refreshProviderHoldings(for: id)
            updates = try await store.checkUpdates(for: id)
        }
        catch is CancellationError {
        } catch { self.error = error.localizedDescription }
    }

    private func setNotifications(_ enabled: Bool) {
        guard let userID = auth.userId else { return }
        Task {
            do {
                if enabled {
                    let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                    guard allowed else { error = "Allow notifications in iOS Settings to receive updates."; return }
                }
                guard auth.userId == userID else { return }
                try store.change { $0.notify = enabled }
            } catch { self.error = error.localizedDescription }
        }
    }
}
