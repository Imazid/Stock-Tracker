import SwiftUI
import TradingCore
import UserNotifications

struct PrivateInvestorView: View {
    @EnvironmentObject private var auth: SupabaseAuthManager
    @State private var country = "AU"
    @State private var declaredClass = "unknown"
    @State private var records: [PrivateApplication] = []
    @State private var recordsOwner: UUID?
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
                    let visibleRecords = recordsOwner == auth.userId ? records : []
                    if visibleRecords.isEmpty && !busy { Text("No tracked applications").foregroundStyle(.secondary) }
                    ForEach(visibleRecords) { record in
                        NavigationLink {
                            if let owner = auth.userId {
                                PrivateApplicationDetail(record: record, owner: owner)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(record.companyName).font(.headline)
                                Text(record.displayStatus).font(.subheadline)
                                Text(PrivateInput.money(record.requestedAmount, currency: record.currency))
                                    .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("private.application.row")
                    }
                }
            }
            if let feedback { Text(feedback).foregroundStyle(.secondary) }
        }
        .navigationTitle("Investor Profile & Applications")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: auth.userId, initial: true) { _, _ in
            records = []
            recordsOwner = nil
            country = "AU"
            declaredClass = "unknown"
            feedback = nil
            busy = false
        }
        .task(id: auth.userId) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let owner = auth.userId else { return }
        busy = true
        defer { if auth.userId == owner { busy = false } }
        do {
            struct Response: Decodable { let profile: PrivateInvestorProfile? }
            async let profile: Response = PrivateMarketsAPI.request("profile", expectedUserID: owner)
            async let applications: PrivateMarketsAPI.Applications = PrivateMarketsAPI.request("applications", expectedUserID: owner)
            let (saved, tracking) = try await (profile, applications)
            try Task.checkCancellation()
            guard auth.userId == owner else { return }
            if let saved = saved.profile {
                country = saved.country
                declaredClass = saved.declaredClass
            }
            records = tracking.applications
            recordsOwner = owner
        } catch is CancellationError {
        } catch { if auth.userId == owner { feedback = error.localizedDescription } }
    }

    private func save() {
        guard let owner = auth.userId else { return }
        let fields = ["country": country.uppercased(), "declared_class": declaredClass]
        busy = true
        feedback = nil
        Task {
            defer { if auth.userId == owner { busy = false } }
            do {
                try await PrivateMarketsAPI.send("save_profile", fields, expectedUserID: owner)
                if auth.userId == owner { feedback = "Investor profile saved." }
            } catch is CancellationError {
            } catch { if auth.userId == owner { feedback = error.localizedDescription } }
        }
    }
}

private extension PrivateApplication {
    var companyName: String {
        offer?.round?.company?.name ?? PrivateProvider.directory.first { $0.id == provider }?.name ?? "Provider application"
    }

    var displayStatus: String {
        switch status {
        case "handoff": "Handoff prepared · awaiting provider"
        case "application_received": "Provider received application"
        case "withdrawal_requested": "Provider recorded a withdrawal request"
        case "confirmed": "Provider confirmed ownership"
        case "withdrawn": "Provider confirmed withdrawal"
        case "rejected": "Provider declined application"
        default: "Provider status unavailable"
        }
    }

    var withdrawalHelp: URL? {
        switch provider {
        case "birchal":
            URL(string: "https://help.birchal.com/en/articles/1709077-how-do-i-cancel-my-investment")
        case "onmarket":
            URL(string: "https://www.onmarket.com.au/help-faq/equity-crowdfunding-investing-and-allocations/how-do-i-cancel-my-application/")
        default: nil
        }
    }
}

private struct PrivateApplicationDetail: View {
    @EnvironmentObject private var auth: SupabaseAuthManager
    let record: PrivateApplication
    let owner: UUID
    @State private var refreshed: PrivateApplication?
    @State private var feedback: String?

    var body: some View {
        if auth.userId == owner {
            let record = refreshed ?? self.record
            List {
                Section("Application") {
                    Text(record.displayStatus).font(.headline).accessibilityIdentifier("private.application.status")
                    if let stage = record.offer?.round?.stage { LabeledContent("Funding round", value: stage) }
                    LabeledContent("Requested amount", value: PrivateInput.money(record.requestedAmount, currency: record.currency))
                    if let reference = record.providerReference { LabeledContent("Provider reference", value: reference) }
                    if let date = record.providerEventAt { dated("Latest provider update", date) }
                }
                Section("Timeline") {
                    dated("Handoff prepared", record.acknowledgedAt)
                    if let date = record.providerReceivedAt { dated("Application received", date) }
                    if let date = record.withdrawalRequestedAt { dated("Withdrawal requested", date) }
                    if let date = record.withdrawalDeclinedAt { dated("Withdrawal declined by provider", date) }
                    if let date = record.withdrawnAt { dated("Withdrawal confirmed", date) }
                    if let date = record.confirmedAt { dated("Ownership confirmed", date) }
                }
                if record.status == "application_received" || record.status == "withdrawal_requested" {
                    Section("Withdrawal") {
                        if let deadline = record.coolingOffEndsAt {
                            dated("Deadline reported by provider", deadline)
                            if deadline <= .now {
                                Text("The recorded deadline has passed. Check your provider for any other withdrawal options.")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Check your provider account for any deadline and the steps to withdraw.")
                                .foregroundStyle(.secondary)
                        }
                        if record.status == "withdrawal_requested" {
                            Text("Awaiting the provider’s decision on your request. Check the provider account for refund information.")
                                .foregroundStyle(.secondary)
                        }
                        if let help = record.withdrawalHelp {
                            Link("Open provider withdrawal instructions", destination: help)
                                .accessibilityIdentifier("private.application.withdrawalHelp")
                        }
                    }
                }
                if let feedback { Text(feedback).foregroundStyle(.secondary) }
            }
            .navigationTitle(record.companyName)
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await refresh() }
        } else {
            ContentUnavailableView("Application unavailable", systemImage: "doc.text")
        }
    }

    private func dated(_ label: String, _ date: Date) -> some View {
        LabeledContent(label, value: date.formatted(date: .abbreviated, time: .shortened))
    }

    private func refresh() async {
        feedback = nil
        do {
            let reply: PrivateMarketsAPI.Applications = try await PrivateMarketsAPI.request("applications", expectedUserID: owner)
            guard auth.userId == owner else { return }
            if let latest = reply.applications.first(where: { $0.id == record.id }) { refreshed = latest }
        } catch is CancellationError {
        } catch { if auth.userId == owner { feedback = error.localizedDescription } }
    }
}

struct PrivateProviderHandoff: View {
    let deal: PrivateDeal
    @EnvironmentObject private var auth: SupabaseAuthManager
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
        .onChange(of: auth.userId) { _, _ in
            ready = nil
            error = nil
        }
    }

    private func prepare() {
        guard let owner = auth.userId, let value = PrivateInput.amount(amount), let document = deal.offerDocumentUrl else { return }
        busy = true
        error = nil
        ready = nil
        Task {
            defer { busy = false }
            do {
                let result: PrivateMarketsAPI.Handoff = try await PrivateMarketsAPI.request("handoff", [
                    "opportunity_id": deal.id.uuidString, "amount": NSDecimalNumber(decimal: value).stringValue,
                    "document_url": document.absoluteString, "acknowledged": reviewed && acknowledged
                ], expectedUserID: owner)
                guard auth.userId == owner else { return }
                guard result.handoffUrl.privateSourceIsSafe else {
                    error = "The provider link could not be verified."
                    return
                }
                if reviewed, acknowledged, PrivateInput.amount(amount) == value {
                    ready = result.handoffUrl
                }
            } catch is CancellationError {
            } catch { if auth.userId == owner { self.error = error.localizedDescription } }
        }
    }
}

struct PrivateUpdatesView: View {
    @EnvironmentObject private var auth: SupabaseAuthManager
    @EnvironmentObject private var store: PrivateMarketsStore
    @State private var updates: [PrivateCompanyUpdate] = []
    @State private var digests: [PrivateSavedItem] = []
    @State private var error: String?
    @State private var loading = false
    @State private var savingMonitor = false
    @State private var savingNotifications = false

    var body: some View {
        List {
            Section("Monitoring") {
                Toggle("Collect alerts while this device is offline", isOn: Binding(
                    get: { store.state.monitorEnabled == true },
                    set: { changeMonitor(enabled: $0, eligible: store.state.monitorEligible == true) }))
                    .disabled(auth.userId == nil || savingMonitor)
                    .accessibilityIdentifier("private.monitor.enable")
                if store.state.monitorEnabled == true {
                    Toggle("New rounds matching my verified eligibility", isOn: Binding(
                        get: { store.state.monitorEligible == true },
                        set: { changeMonitor(enabled: true, eligible: $0) }))
                        .disabled(savingMonitor)
                        .accessibilityIdentifier("private.monitor.eligible")
                    Toggle("Summarise new announcements daily", isOn: Binding(
                        get: { store.state.monitorDigest == true },
                        set: { changeMonitor(enabled: true, eligible: store.state.monitorEligible == true, digest: $0) }))
                        .disabled(savingMonitor)
                        .accessibilityIdentifier("private.monitor.digest")
                    Text("Sends published announcements for tracked companies to the AI provider. Summaries use your daily research quota.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text("Online monitoring shares the catalogue company IDs you track with your Stock Tracker account.")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("Notify me about company updates", isOn: Binding(
                    get: { store.state.notify }, set: setNotifications))
                    .disabled(auth.userId == nil || savingNotifications)
                Text(store.remotePushActive ? "Push notifications are active on this device." :
                    "Device notifications appear when iOS permits the app to refresh.")
                    .font(.footnote).foregroundStyle(.secondary)
                if savingMonitor { ProgressView("Saving monitoring preferences") }
                if let error = store.monitorError { Text(error).foregroundStyle(.secondary) }
            }
            if store.state.monitorEnabled == true, auth.userId != nil {
                Section("Monitoring inbox") {
                    if store.monitorAlerts.isEmpty && !loading && !savingMonitor {
                        Text("No alerts collected yet.").foregroundStyle(.secondary)
                    }
                    ForEach(store.monitorAlerts) { alert in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(alert.title).font(.headline)
                            Text("\(alert.companyName) · \(alert.occurredAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.footnote).foregroundStyle(.secondary)
                            Text(alert.significance)
                            if let url = alert.sourceUrl, url.privateSourceIsSafe { Link("Read source", destination: url) }
                            if let source = alert.sourceLabel { Text(source).font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            if store.state.monitorDigest == true, auth.userId != nil {
                Section("AI monitoring summaries") {
                    if digests.isEmpty && !loading && !savingMonitor {
                        Text("A summary appears after the next scheduled run with new announcements.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(digests) { item in
                        NavigationLink {
                            PrivateSavedReportView(item: item)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(item.title)
                                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
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
                } else if store.state.follows.isEmpty && store.providerHoldings.isEmpty &&
                            !store.state.holdings.contains(where: { $0.catalogueCompanyID != nil }) && !loading {
                    Text("Follow a company or link a manual holding to a catalogue company.")
                } else if updates.isEmpty && !loading {
                    Text("No verified updates are published for the companies you track.")
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
                        if let source = item.sourceLabel { Text(source).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                if let error { Text(error).foregroundStyle(Color.orange) }
            }
        }
        .navigationTitle("Company Updates")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: auth.userId) {
            updates = []
            digests = []
            await load()
        }
        .task(id: store.state.monitorEnabled) {
            if let owner = auth.userId, store.state.monitorEnabled == true {
                await store.refreshMonitor(for: owner)
            }
        }
        .refreshable { await load() }
    }

    private func load() async {
        guard let id = auth.userId else { return }
        error = nil
        loading = true
        defer { loading = false }
        do {
            await store.refreshProviderHoldings(for: id)
            await store.refreshMonitor(for: id)
            let refreshed = try await store.checkUpdates(for: id)
            guard auth.userId == id else { return }
            updates = refreshed
            try await loadDigests(owner: id)
        }
        catch is CancellationError {
        } catch { self.error = error.localizedDescription }
    }

    private func loadDigests(owner: UUID) async throws {
        guard auth.userId == owner, store.state.monitorDigest == true else { return }
        let list: PrivateMarketsAPI.Items = try await PrivateMarketsAPI.request("monitor_digests", expectedUserID: owner)
        guard auth.userId == owner, store.state.monitorDigest == true else { return }
        digests = list.items
    }

    private func changeMonitor(enabled: Bool, eligible: Bool, digest: Bool? = nil) {
        guard let owner = auth.userId else { return }
        let summarise = digest ?? (store.state.monitorDigest == true)
        savingMonitor = true
        Task {
            defer { savingMonitor = false }
            do {
                try await store.setMonitor(enabled: enabled, eligible: eligible, digest: summarise, owner: owner)
                if digest == true { try await loadDigests(owner: owner) }
            }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }

    private func setNotifications(_ enabled: Bool) {
        guard let userID = auth.userId else { return }
        savingNotifications = true
        Task {
            defer { savingNotifications = false }
            do {
                if enabled {
                    let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                    guard allowed else { error = "Allow notifications in iOS Settings to receive updates."; return }
                }
                guard auth.userId == userID else { return }
                try await store.setUpdateNotifications(enabled, owner: userID)
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }
}
