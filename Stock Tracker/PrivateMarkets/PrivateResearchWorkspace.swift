import PDFKit
import SwiftUI
import TradingCore
import UniformTypeIdentifiers
import Vision

struct PrivateResearchWorkspace: View {
    let deals: [PrivateDeal]
    var selectedDealID: UUID?
    var comparisonQuestion: String?
    var announcements: [PrivateCompanyUpdate] = []
    var refresh: PrivateResearchRefresh?
    var refreshOwner: UUID?
    var previousReportID: UUID?
    @EnvironmentObject private var auth: SupabaseAuthManager
    @State private var documents: [PrivateSavedItem] = []
    @State private var reports: [PrivateSavedItem] = []
    @State private var runs: [PrivateResearchRun] = []
    @State private var workspaceOwner: UUID?
    @State private var loadID = UUID()
    @State private var runRequestID = UUID()
    @State private var selectedDeals: Set<UUID> = []
    @State private var selectedDocuments: Set<UUID> = []
    @State private var selectedAnnouncements: Set<UUID> = []
    @State private var question = ""
    @State private var modelConsent = false
    @State private var excerptPermission = false
    @State private var busy = false
    @State private var loading = false
    @State private var result: PrivateResearchReport?
    @State private var runTask: Task<Void, Never>?
    @State private var error: String?

    var body: some View {
        List {
            Section("Scenario calculator") {
                NavigationLink("Ownership, dilution and exit scenarios") {
                    PrivateScenarioCalculator(round: deals.count == 1 ? deals.first?.round : nil)
                }
            }
            if auth.userId == nil {
                Section("Research") {
                    Text("Sign in from Account to run and save AI research.")
                    Text("The scenario calculator works on this device.")
                }
            } else if let owner = auth.userId, workspaceOwner == owner {
                Section("Research question") {
                    TextField("Ask about a company, valuation or risk", text: $question, axis: .vertical)
                        .lineLimit(2...5)
                        .accessibilityIdentifier("private.research.question")
                    Text("Choose up to three sources. The committee runs five specialist reviews and a synthesis.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let refresh, refresh.unavailableSources > 0 {
                    Section { Text("Some original sources are no longer available. Review the sources before running the update.") }
                }
                if refresh?.revisionTrackingAvailable == false {
                    Section { Text("This report was saved before source revision tracking. Review the current sources for changes.") }
                }
                if let changes = refresh?.sourceChanges, !changes.isEmpty {
                    Section("What changed") {
                        ForEach(changes) { change in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(change.title).font(.headline)
                                ForEach(change.fields) { field in
                                    DisclosureGroup(field.field) {
                                        LabeledContent("Previous", value: field.previous ?? "Undisclosed")
                                        LabeledContent("Current", value: field.current ?? "Undisclosed")
                                    }
                                    .accessibilityIdentifier("private.research.sourceChange.\(field.field)")
                                }
                            }
                        }
                    }
                }
                if refresh != nil, deals.isEmpty, announcements.isEmpty, documents.isEmpty,
                   refresh?.newerAnnouncements.isEmpty == true {
                    Section { Text("No sources are available for this report. Choose new evidence in AI Investment Research.") }
                }
                if !deals.isEmpty {
                    Section("Published opportunities") {
                        ForEach(deals) { deal in
                            Toggle(isOn: selection(deal.id, in: $selectedDeals)) {
                                sourceLabel("\(deal.company.name) · \(deal.round.stage)", revised: refresh?.changedDealIds?.contains(deal.id) == true)
                            }
                        }
                    }
                }
                if !announcements.isEmpty {
                    Section("Published company updates") {
                        ForEach(announcements) { item in
                            Toggle(isOn: selection(item.id, in: $selectedAnnouncements)) {
                                sourceLabel("\(item.company.name) · \(item.title)", revised: refresh?.changedAnnouncementIds?.contains(item.id) == true)
                            }
                        }
                    }
                }
                if let refresh, !refresh.newerAnnouncements.isEmpty {
                    Section("Published since the previous report") {
                        if sourceCount >= 3 { Text("Deselect a source to include a newer update.").font(.footnote) }
                        ForEach(refresh.newerAnnouncements) { item in
                            Toggle("\(item.company.name) · \(item.title)",
                                   isOn: selection(item.id, in: $selectedAnnouncements))
                        }
                    }
                }
                Section("Private excerpts") {
                    if loading {
                        VStack(spacing: 0) {
                            ForEach(0..<3) { _ in SearchRowSkeleton() }
                        }
                        .privateLoadingLabel("Loading saved sources")
                    }
                    if documents.isEmpty && !loading {
                        Text("Add authorized text in the Deal Room.").foregroundStyle(.secondary)
                    }
                    ForEach(documents) { item in
                        Toggle(item.title, isOn: selection(item.id, in: $selectedDocuments))
                    }
                    if !selectedDocuments.isEmpty {
                        Toggle("I have permission to send these private excerpts to the approved AI provider", isOn: $excerptPermission)
                            .accessibilityIdentifier("private.research.excerptPermission")
                    }
                }
                Section {
                    Toggle("Send my question and selected sources to OpenAI or Google Gemini", isOn: $modelConsent)
                        .disabled(busy)
                        .accessibilityIdentifier("private.research.modelConsent")
                    Button("Ask a question") { run("question") }.disabled(!canRun)
                    Button("Run Investment Committee") { run("committee") }.disabled(!canRun)
                    if busy { SkeletonBlock(height: 12).privateLoadingLabel("Analyzing sources") }
                    if let result {
                        NavigationLink("Open latest report") { PrivateSavedReportView(id: result.id, owner: owner, cachedReport: result) }
                    }
                }
                if !runs.isEmpty {
                    Section("Recent research runs") {
                        ForEach(runs) { run in
                            VStack(alignment: .leading, spacing: 5) {
                                if run.status == "running" {
                                    ProgressView("Research in progress")
                                        .accessibilityIdentifier("private.research.run.running")
                                } else {
                                    Text(run.failureMessage ?? "The research run could not finish.")
                                        .accessibilityIdentifier("private.research.run.failed")
                                }
                                Text(run.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else if loading {
                    Section { ProgressView("Checking recent research") }
                }
                Section("Saved reports") {
                    if reports.isEmpty && !loading { Text("No saved reports").foregroundStyle(.secondary) }
                    ForEach(reports) { item in
                        NavigationLink(item.title) { PrivateSavedReportView(id: item.id, owner: owner) }
                            .swipeActions {
                                Button("Delete", role: .destructive) {
                                    guard let owner = auth.userId else { return }
                                    Task {
                                        do {
                                            try await PrivateMarketsAPI.send("delete_report", ["id": item.id.uuidString], expectedUserID: owner)
                                            guard auth.userId == owner else { return }
                                            reports.removeAll { $0.id == item.id }
                                            if result?.id == item.id { result = nil }
                                            await load(quietly: true)
                                        } catch is CancellationError {
                                        } catch { if auth.userId == owner { self.error = error.localizedDescription } }
                                    }
                                }
                            }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(Color.orange) } }
            }
        }
        .onDisappear { runTask?.cancel() }
        .onChange(of: selectedDocuments) { _, _ in excerptPermission = false }
        .navigationTitle("AI Investment Research")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: auth.userId) {
            if workspaceOwner != auth.userId {
                runTask?.cancel()
                loadID = UUID()
                runRequestID = UUID()
                documents = []
                reports = []
                runs = []
                selectedDeals = []
                selectedDocuments = []
                selectedAnnouncements = []
                question = ""
                modelConsent = false
                excerptPermission = false
                result = nil
                busy = false
                loading = false
                error = nil
                if let refreshOwner, refreshOwner != auth.userId { return }
                if let refresh {
                    question = refresh.question
                    selectedDeals = Set(refresh.deals.map(\.id))
                    selectedAnnouncements = Set(refresh.announcements.map(\.id))
                    documents = refresh.documents
                } else if let comparisonQuestion {
                    selectedDeals = Set(deals.prefix(3).map(\.id))
                    question = comparisonQuestion
                } else if !announcements.isEmpty {
                    selectedAnnouncements = Set(announcements.prefix(3).map(\.id))
                    question = "Summarise these published company updates. Explain what changed, what the sources disclose about dilution, and what remains unanswered."
                } else if let selectedDealID { selectedDeals.insert(selectedDealID) }
                workspaceOwner = auth.userId
            }
            await load()
        }
        .task(id: runs.filter { $0.status == "running" }.map(\.id)) {
            guard let owner = auth.userId, workspaceOwner == owner else { return }
            while !Task.isCancelled, auth.userId == owner, runs.contains(where: { $0.status == "running" }) {
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
                await load(quietly: true)
            }
        }
        .refreshable { await load() }
    }

    private var sourceCount: Int { selectedDeals.count + selectedDocuments.count + selectedAnnouncements.count }

    private func sourceLabel(_ title: String, revised: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            if revised {
                Text("Updated since this report").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var canRun: Bool {
        !busy && modelConsent && sourceCount > 0 && sourceCount <= 3 &&
            !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && question.utf16.count <= 1_000 &&
            (selectedDocuments.isEmpty || excerptPermission)
    }

    private func selection(_ id: UUID, in set: Binding<Set<UUID>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(id) }, set: { selected in
            if selected, sourceCount < 3 {
                set.wrappedValue.insert(id)
            } else if !selected {
                set.wrappedValue.remove(id)
            }
        })
    }

    private func load(quietly: Bool = false) async {
        guard let owner = auth.userId, owner == workspaceOwner, !quietly || !loading else { return }
        let requestID = UUID()
        loadID = requestID
        if !quietly {
            loading = true
            error = nil
        }
        defer { if loadID == requestID { loading = false } }
        do {
            let runList: [PrivateResearchRun]
            do {
                let response: PrivateMarketsAPI.ResearchRuns = try await PrivateMarketsAPI.request("research_runs", expectedUserID: owner)
                runList = response.runs
            } catch let error as SecureBackend.FunctionError where error.code == "INVALID_ACTION" {
                // A backend still rolling out this action can continue to serve saved research.
                runList = []
            }
            // An omitted completed run already has a saved report in the same database transaction.
            let reportList: PrivateMarketsAPI.Items = try await PrivateMarketsAPI.request("reports", expectedUserID: owner)
            let documentList: PrivateMarketsAPI.Items? = quietly || refresh != nil ? nil :
                try await PrivateMarketsAPI.request("documents", expectedUserID: owner)
            try Task.checkCancellation()
            guard auth.userId == owner, loadID == requestID else { return }
            reports = reportList.items
            runs = runList
            if let documentList {
                documents = documentList.items
                selectedDocuments.formIntersection(documents.map(\.id))
            }
        } catch is CancellationError {
        } catch { if auth.userId == owner, loadID == requestID { self.error = error.localizedDescription } }
    }

    private func run(_ mode: String) {
        guard let owner = auth.userId, canRun else { return }
        var fields: [String: Any] = [
            "mode": mode, "question": question, "document_ids": selectedDocuments.map(\.uuidString),
            "opportunity_ids": selectedDeals.map(\.uuidString), "model_consent": modelConsent, "ai_consent": excerptPermission,
            "announcement_ids": selectedAnnouncements.map(\.uuidString)
        ]
        if let previousReportID { fields["previous_report_id"] = previousReportID.uuidString }
        modelConsent = false
        excerptPermission = false
        let requestID = UUID()
        runRequestID = requestID
        error = nil
        busy = true
        runTask = Task {
            defer { if runRequestID == requestID { busy = false } }
            do {
                let report: PrivateResearchReport
                if mode == "committee" {
                    report = try await runCommittee(fields, owner: owner)
                } else {
                    report = try await PrivateMarketsAPI.request("research", fields, expectedUserID: owner)
                }
                try Task.checkCancellation()
                guard auth.userId == owner, runRequestID == requestID else { return }
                result = report
                await load()
            } catch is CancellationError {
            } catch {
                if auth.userId == owner, runRequestID == requestID {
                    let message = error.localizedDescription
                    await load(quietly: true)
                    if auth.userId == owner, runRequestID == requestID { self.error = message }
                }
            }
        }
    }

    private func runCommittee(_ fields: [String: Any], owner: UUID) async throws -> PrivateResearchReport {
        struct Started: Decodable { let id: UUID }
        struct Status: Decodable { let status: String; let failureMessage: String? }
        var request = fields
        request["background"] = true
        let run: Started = try await PrivateMarketsAPI.request("research", request, expectedUserID: owner)
        let target = ["id": run.id.uuidString]
        for _ in 0..<60 {
            try await Task.sleep(for: .seconds(3))
            let progress: Status = try await PrivateMarketsAPI.request("research_status", target, expectedUserID: owner)
            if progress.status == "complete" { return try await PrivateMarketsAPI.request("report", target, expectedUserID: owner) }
            if progress.status == "failed", let message = progress.failureMessage {
                throw SecureBackend.FunctionError(status: 502, code: "COMMITTEE_UNAVAILABLE", message: message)
            }
            if progress.status == "failed" { break }
        }
        throw SecureBackend.FunctionError(status: 502, code: "COMMITTEE_UNAVAILABLE",
                                          message: "The committee could not finish. Try again or ask one research question.")
    }

}

struct PrivateSavedReportView: View {
    let id: UUID
    let owner: UUID
    var cachedReport: PrivateResearchReport?
    @EnvironmentObject private var auth: SupabaseAuthManager
    @State private var report: PrivateResearchReport?
    @State private var error: String?

    var body: some View {
        Group {
            if auth.userId != owner { ContentUnavailableView("Report unavailable", systemImage: "doc.text") }
            else if let report { PrivateReportView(report: report, owner: owner) }
            else if let error { ContentUnavailableView("Report unavailable", systemImage: "exclamationmark.circle", description: Text(error)) }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.xl) {
                        SkeletonBlock(width: 180, height: 28)
                        ForEach(0..<3) { _ in SkeletonBlock(height: 12) }
                    }
                    .padding(DS.Space.gutter)
                    .privateLoadingLabel("Opening report")
                }
            }
        }
        .task(id: auth.userId) {
            report = nil
            error = nil
            guard auth.userId == owner else { return }
            if let cachedReport {
                report = cachedReport
                return
            }
            do {
                let response: PrivateResearchReport = try await PrivateMarketsAPI.request(
                    "report", ["id": id.uuidString], expectedUserID: owner)
                try Task.checkCancellation()
                if auth.userId == owner { report = response }
            } catch is CancellationError {
            }
            catch { if auth.userId == owner { self.error = error.localizedDescription } }
        }
    }
}

private struct PrivateReportView: View {
    let report: PrivateResearchReport
    let owner: UUID
    var body: some View {
        List {
            Section("Question") {
                Text(report.question)
                Text("AI-generated research · \(report.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if report.refreshAvailable == true {
                Section {
                    NavigationLink("Review current funding terms") {
                        PrivateResearchRoundReview(reportID: report.id, owner: owner)
                    }
                    .accessibilityIdentifier("private.research.reviewRounds")
                    NavigationLink("Review sources for an updated report") {
                        PrivateResearchRefreshView(reportId: report.id, owner: owner)
                    }
                    .accessibilityIdentifier("private.research.refresh")
                }
            }
            if let previous = report.previousReportId {
                Section {
                    NavigationLink("Open previous report") { PrivateSavedReportView(id: previous, owner: owner) }
                }
            }
            if let committee = report.committee {
                section(committee)
                Section {
                    NavigationLink("Model exit scenarios") { PrivateScenarioCalculator() }
                }
            }
            ForEach(report.findings) { section($0) }
            Section("Sources") {
                ForEach(report.sources) { source in
                    if let url = source.url, url.privateSourceIsSafe { Link(source.title, destination: url) }
                    else { Text(source.title) }
                }
                Text(report.models.joined(separator: ", ")).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(report.committee == nil ? "Research Answer" : "Investment Committee")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section(_ finding: PrivateResearchReport.Finding) -> some View {
        Section(finding.title) {
            Text(finding.analysis)
            LabeledContent("Evidence confidence", value: finding.confidence.capitalized)
            if let bull = finding.bull { LabeledContent("Bull assumption", value: bull) }
            if let base = finding.base { LabeledContent("Base assumption", value: base) }
            if let bear = finding.bear { LabeledContent("Bear assumption", value: bear) }
            ForEach(Array(finding.evidence.enumerated()), id: \.offset) { _, citation in
                let source = report.sources.first { $0.id == citation.source }
                VStack(alignment: .leading, spacing: 4) {
                    Text(source?.title ?? citation.source).font(.caption.weight(.semibold))
                    Text(citation.quote).font(.subheadline)
                }
            }
            ForEach(Array(finding.missing.enumerated()), id: \.offset) { _, missing in
                Label(missing, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            }
            ForEach(Array(finding.questions.enumerated()), id: \.offset) { _, question in
                Label(question, systemImage: "questionmark.bubble")
            }
        }
    }
}

private struct PrivateResearchRoundReview: View {
    let reportID: UUID
    let owner: UUID
    @EnvironmentObject private var auth: SupabaseAuthManager
    @State private var deals: [PrivateDeal]?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        List {
            if auth.userId != owner {
                ContentUnavailableView("Report unavailable", systemImage: "doc.text")
            } else if let error {
                ContentUnavailableView {
                    Label("Funding terms unavailable", systemImage: "exclamationmark.circle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await load() } }
                }
            } else if let deals {
                if deals.isEmpty {
                    ContentUnavailableView("No published rounds in this report", systemImage: "doc.text.magnifyingglass")
                        .accessibilityIdentifier("private.research.noRounds")
                } else {
                    ForEach(deals) { deal in
                        NavigationLink {
                            PrivateDealDetail(deal: deal, reviewedFromReport: true)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(deal.company.name).font(.headline)
                                Text(deal.round.stage).font(.subheadline)
                                Text(deal.displayedStatus).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("private.research.round")
                    }
                }
            } else {
                ProgressView("Checking published funding terms")
            }
        }
        .navigationTitle("Reported Funding Rounds")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: auth.userId) {
            await load()
        }
        .refreshable { await load() }
    }

    private func load() async {
        guard auth.userId == owner, !loading else { return }
        loading = true
        defer { loading = false }
        error = nil
        do {
            let response: PrivateResearchRefresh = try await PrivateMarketsAPI.request(
                "research_refresh", ["id": reportID.uuidString], expectedUserID: owner)
            try Task.checkCancellation()
            guard auth.userId == owner else { return }
            let order = response.deals.sorted {
                ($0.company.name, $0.round.stage, $0.id.uuidString) < ($1.company.name, $1.round.stage, $1.id.uuidString)
            }
            deals = order
        } catch is CancellationError {
        } catch { if auth.userId == owner { self.error = error.localizedDescription } }
    }
}

private struct PrivateResearchRefreshView: View {
    let reportId: UUID
    let owner: UUID
    @EnvironmentObject private var auth: SupabaseAuthManager
    @State private var refresh: PrivateResearchRefresh?
    @State private var error: String?

    var body: some View {
        Group {
            if auth.userId != owner {
                ContentUnavailableView("Report unavailable", systemImage: "doc.text")
            } else if let refresh {
                PrivateResearchWorkspace(deals: refresh.deals, announcements: refresh.announcements,
                                         refresh: refresh, refreshOwner: owner, previousReportID: reportId)
            } else if let error {
                ContentUnavailableView("Sources unavailable", systemImage: "doc.text", description: Text(error))
            } else {
                ProgressView("Checking research sources")
            }
        }
        .task(id: auth.userId) {
            refresh = nil
            error = nil
            guard auth.userId == owner else { return }
            do {
                let response: PrivateResearchRefresh = try await PrivateMarketsAPI.request(
                    "research_refresh", ["id": reportId.uuidString], expectedUserID: owner)
                try Task.checkCancellation()
                if auth.userId == owner { refresh = response }
            } catch is CancellationError {
            } catch { if auth.userId == owner { self.error = error.localizedDescription } }
        }
    }
}

struct PrivateScenarioCalculator: View {
    @State private var useExistingStake: Bool
    @State private var existingStake: String
    @State private var investment: String
    @State private var postMoney: String
    @State private var nextRaise: String
    @State private var nextPost: String
    @State private var bear = ""
    @State private var base = ""
    @State private var bull = ""
    @State private var modelPreference = false
    @State private var shareClass: PrivateMath.ExitShareClass = .common
    @State private var preferredOwnership = ""
    @State private var preferenceAmount = ""
    @State private var participating = false
    @FocusState private var focusedInput: String?
    private let round: PrivateDeal.Round?

    init(question: PrivateScenarioQuestion? = nil, round: PrivateDeal.Round? = nil) {
        self.round = round
        let dilution = question?.calculatesDilution == true
        func input(_ amount: Decimal?) -> String {
            amount?.formatted(.number.grouping(.never).precision(.fractionLength(0...8))) ?? ""
        }
        _useExistingStake = State(initialValue: dilution)
        _existingStake = State(initialValue: input(question?.existingOwnership.map { $0 * 100 }))
        _investment = State(initialValue: input(question?.investment))
        let publishedPostMoney = round?.valuationMethod?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "post-money"
            ? round?.valuation : nil
        _postMoney = State(initialValue: dilution ? "" : input(question?.postMoney ?? publishedPostMoney))
        _nextRaise = State(initialValue: input(question?.newCapital))
        _nextPost = State(initialValue: dilution ? input(question?.postMoney) : "")
    }

    private var startingOwnership: Decimal? {
        if useExistingStake {
            guard let share = PrivateInput.amount(existingStake), share <= 100 else { return nil }
            return share / 100
        }
        guard let amount = PrivateInput.amount(investment), let post = PrivateInput.amount(postMoney) else { return nil }
        return PrivateMath.ownership(investment: amount, postMoney: post, nextRoundPostMoney: nil, nextRoundRaise: nil)
    }

    private var finalOwnership: Decimal? {
        if nextRaise.isEmpty && nextPost.isEmpty { return startingOwnership }
        guard let startingOwnership,
              let raise = PrivateInput.amount(nextRaise), let next = PrivateInput.amount(nextPost) else { return nil }
        return PrivateMath.dilutedOwnership(startingOwnership, newCapital: raise, postMoney: next)
    }

    var body: some View {
        Form {
            if let round {
                Section("Published round") {
                    LabeledContent(round.company.name, value: round.stage)
                    LabeledContent("Currency", value: round.currency)
                    if let valuation = round.valuation {
                        LabeledContent(round.valuationMethod ?? "Disclosed valuation", value: PrivateInput.money(valuation, currency: round.currency))
                    }
                    if round.sourceUrl.privateSourceIsSafe { Link("Read funding round source", destination: round.sourceUrl) }
                }
            }
            Section("Initial investment") {
                Toggle("Start with an ownership percentage", isOn: $useExistingStake)
                if useExistingStake {
                    input("Existing ownership (%)", $existingStake)
                } else {
                    input("Investment amount", $investment)
                    input("Post-money valuation", $postMoney)
                }
                LabeledContent("Initial ownership", value: Self.percent(startingOwnership))
            }
            Section("Next round") {
                input("New capital raised", $nextRaise)
                input("Next post-money valuation", $nextPost)
                LabeledContent("Ownership after round", value: Self.percent(finalOwnership))
                Text("Assumes you do not participate in the new round and there are no option pool changes or conversions.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Payout terms") {
                Toggle("Model a preferred share class", isOn: $modelPreference)
                    .accessibilityIdentifier("private.scenario.preference")
                if modelPreference {
                    Picker("Your share class", selection: $shareClass) {
                        Text("Common").tag(PrivateMath.ExitShareClass.common)
                        Text("Preferred").tag(PrivateMath.ExitShareClass.preferred)
                    }
                    input("Preferred ownership at exit (%)", $preferredOwnership)
                    input("Total liquidation preference", $preferenceAmount)
                    Toggle("Participating preferred", isOn: $participating)
                    Text("Enter the preferred class’s share of fully diluted equity and its total payout preference in the same currency. Use terms from the investment documents.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text(modelPreference
                     ? "Use exit equity value after debt. The model assumes equal terms within one preferred class and uncapped participation when enabled. Fees and taxes are excluded."
                     : "Exit proceeds are pro rata. Use one currency throughout. Fees and taxes are excluded.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Assumed exit equity values") {
                scenario("Bear", $bear)
                scenario("Base", $base)
                scenario("Bull", $bull)
            }
        }
        .navigationTitle("Scenario Calculator")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedInput = nil }
            }
        }
    }

    private func input(_ title: String, _ value: Binding<String>) -> some View {
        TextField(title, text: value).keyboardType(.decimalPad).focused($focusedInput, equals: title)
    }

    private func scenario(_ title: String, _ value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            input(title + " exit value", value)
            if let share = finalOwnership, let exit = PrivateInput.amount(value.wrappedValue), let proceeds = proceeds(share: share, exit: exit) {
                let multiple = !useExistingStake ? PrivateInput.amount(investment).flatMap { $0 > 0 ? proceeds / $0 : nil } : nil
                let amount = proceeds.formatted(.number.precision(.fractionLength(2)))
                Text(multiple.map { "Proceeds \(amount) · \($0.formatted(.number.precision(.fractionLength(2))))×" } ?? "Proceeds \(amount)")
                    .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityIdentifier("private.scenario.\(title.lowercased()).proceeds")
            } else if !value.wrappedValue.isEmpty && modelPreference {
                Text("Check ownership and payout terms.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func proceeds(share: Decimal, exit: Decimal) -> Decimal? {
        guard modelPreference else { return share * exit }
        guard let preferred = PrivateInput.amount(preferredOwnership), let preference = PrivateInput.amount(preferenceAmount) else { return nil }
        return PrivateMath.exitProceeds(equityValue: exit, ownership: share, shareClass: shareClass,
                                       preferredOwnership: preferred / 100, liquidationPreference: preference,
                                       participating: participating)
    }

    static func percent(_ value: Decimal?) -> String {
        value?.formatted(.percent.precision(.fractionLength(2...4))) ?? "Unavailable"
    }
}

struct PrivateDealRoom: View {
    private struct Draft: Identifiable { let id: UUID }

    @EnvironmentObject private var auth: SupabaseAuthManager
    @EnvironmentObject private var store: PrivateMarketsStore
    @State private var items: [PrivateSavedItem] = []
    @State private var itemsOwner: UUID?
    @State private var loading = false
    @State private var draft: Draft?
    @State private var error: String?

    var body: some View {
        List {
            Section("Your authorized excerpts") {
                if auth.userId == nil {
                    Text("Sign in from Account to store private research excerpts.")
                } else if let owner = auth.userId {
                    let availableItems = itemsOwner == owner ? items : []
                    if loading {
                        VStack(spacing: 0) {
                            ForEach(0..<3) { _ in SearchRowSkeleton() }
                        }
                        .privateLoadingLabel("Loading documents")
                    }
                    if availableItems.isEmpty && !loading { Text("No excerpts saved").foregroundStyle(.secondary) }
                    ForEach(availableItems) { item in
                        NavigationLink {
                            PrivateExcerptView(item: item, owner: owner)
                        } label: {
                            LabeledContent(item.title, value: item.createdAt.formatted(date: .abbreviated, time: .omitted))
                        }
                            .swipeActions {
                                Button("Delete", role: .destructive) {
                                    guard let owner = auth.userId else { return }
                                    Task {
                                        do {
                                            try await PrivateMarketsAPI.send("delete_document", ["id": item.id.uuidString], expectedUserID: owner)
                                            guard auth.userId == owner else { return }
                                            items.removeAll { $0.id == item.id }
                                            try store.removeOwnershipEvidence(item.id, owner: owner)
                                        } catch is CancellationError {
                                        } catch { if auth.userId == owner { self.error = error.localizedDescription } }
                                    }
                                }
                            }
                    }
                    Button("Add research excerpt") { draft = Draft(id: owner) }
                }
                if let error { Text(error).foregroundStyle(Color.orange) }
            }
            Section("Provider deal rooms") {
                ForEach(PrivateProvider.directory) { provider in
                    Link(provider.name, destination: provider.url)
                }
                Text("Provider accounts and invitations control access to their documents.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Deal Room")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $draft, onDismiss: { Task { await load() } }) { draft in
            PrivateExcerptEditor(owner: draft.id)
        }
        .task(id: auth.userId) {
            items = []
            itemsOwner = nil
            loading = false
            error = nil
            draft = nil
            await load()
        }
        .refreshable { await load() }
    }

    private func load() async {
        guard let owner = auth.userId else { return }
        loading = true
        error = nil
        defer { if auth.userId == owner { loading = false } }
        do {
            let response: PrivateMarketsAPI.Items = try await PrivateMarketsAPI.request("documents", expectedUserID: owner)
            try Task.checkCancellation()
            guard auth.userId == owner else { return }
            items = response.items
            itemsOwner = owner
        } catch is CancellationError {
        } catch { if auth.userId == owner { self.error = error.localizedDescription } }
    }
}

private struct PrivateExcerptView: View {
    let item: PrivateSavedItem
    let owner: UUID
    @EnvironmentObject private var auth: SupabaseAuthManager
    @State private var excerpt: String?
    @State private var error: String?

    var body: some View {
        Group {
            if auth.userId != owner {
                ContentUnavailableView("Excerpt unavailable", systemImage: "doc.text")
            } else if let excerpt {
                ScrollView {
                    Text(excerpt).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
                }
            } else if let error {
                ContentUnavailableView("Excerpt unavailable", systemImage: "doc.text", description: Text(error))
            } else {
                ProgressView("Opening excerpt")
            }
        }
        .navigationTitle(auth.userId == owner ? item.title : "Deal Room")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: auth.userId) {
            excerpt = nil
            error = nil
            guard auth.userId == owner else { return }
            struct Response: Decodable { let excerpt: String }
            do {
                let response: Response = try await PrivateMarketsAPI.request("document", ["id": item.id.uuidString], expectedUserID: owner)
                try Task.checkCancellation()
                guard auth.userId == owner else { return }
                excerpt = response.excerpt
            } catch is CancellationError {
            } catch {
                if auth.userId == owner { self.error = error.localizedDescription }
            }
        }
    }
}

struct PrivateOwnershipEvidenceView: View {
    let holding: PrivateHolding
    let owner: UUID
    @EnvironmentObject private var store: PrivateMarketsStore
    @EnvironmentObject private var auth: SupabaseAuthManager
    @State private var items: [PrivateSavedItem] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            if let current = store.state.holdings.first(where: { $0.id == holding.id }), let id = current.ownershipEvidenceID {
                Section("Linked evidence") {
                    NavigationLink("Open ownership excerpt") {
                        review(id: id, title: "Ownership excerpt", reviewed: current.ownershipReviewedOn)
                    }
                    .accessibilityIdentifier("private.ownership.linked")
                    Button("Unlink excerpt", role: .destructive) { update(nil) }
                }
            }
            Section("Choose an excerpt") {
                if loading { ProgressView("Loading your Deal Room") }
                else if items.isEmpty { Text("Add an authorized ownership excerpt in Deal Room first.") }
                ForEach(items) { item in
                    NavigationLink(item.title) { review(id: item.id, title: item.title, reviewed: nil) }
                        .accessibilityIdentifier("private.ownership.excerpt")
                }
            }
            if let error { Text(error).foregroundStyle(.secondary) }
        }
        .navigationTitle("Ownership Evidence")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func review(id: UUID, title: String, reviewed: Date?) -> some View {
        PrivateOwnershipReviewView(id: id, title: title, owner: owner, reviewed: reviewed) {
            try store.updateOwnershipEvidence(for: holding.id, owner: owner, documentID: id)
        }
    }

    private func update(_ documentID: UUID?) {
        do { try store.updateOwnershipEvidence(for: holding.id, owner: owner, documentID: documentID) }
        catch { self.error = error.localizedDescription }
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let response: PrivateMarketsAPI.Items = try await PrivateMarketsAPI.request("documents", expectedUserID: owner)
            try Task.checkCancellation()
            if auth.userId == owner { items = response.items }
        } catch is CancellationError {
        } catch { self.error = error.localizedDescription }
    }
}

private struct PrivateOwnershipReviewView: View {
    let id: UUID
    let title: String
    let owner: UUID
    let reviewed: Date?
    let attach: () throws -> Void
    @EnvironmentObject private var auth: SupabaseAuthManager
    @Environment(\.dismiss) private var dismiss
    @State private var excerpt: String?
    @State private var acknowledged = false
    @State private var error: String?

    var body: some View {
        List {
            if let excerpt {
                Section("Excerpt") { Text(excerpt).textSelection(.enabled) }
                Section("Review") {
                    if let reviewed {
                        LabeledContent("Reviewed by you", value: reviewed.formatted(date: .abbreviated, time: .omitted))
                    }
                    Toggle("I checked the excerpt against this holding", isOn: $acknowledged)
                        .accessibilityIdentifier("private.ownership.reviewed")
                    Text("Your review records supporting evidence for a self-reported holding.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Save evidence review") {
                        do { try attach(); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                    .disabled(!acknowledged)
                }
            } else if error == nil {
                ProgressView("Opening excerpt")
            }
            if let error { Text(error).foregroundStyle(.secondary) }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            struct Document: Decodable { let excerpt: String }
            do {
                let response: Document = try await PrivateMarketsAPI.request("document", ["id": id.uuidString], expectedUserID: owner)
                try Task.checkCancellation()
                if auth.userId == owner { excerpt = response.excerpt }
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct PrivateExcerptEditor: View {
    let owner: UUID
    @EnvironmentObject private var auth: SupabaseAuthManager
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var excerpt = ""
    @State private var authorized = false
    @State private var importing = false
    @State private var extraction: Task<Void, Never>?
    @State private var usedOCR = false
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if auth.userId == owner {
                    TextField("Document and page or section", text: $title)
                    TextField("Text excerpt", text: $excerpt, axis: .vertical).lineLimit(6...12)
                    Text("\(excerpt.utf16.count) / 4,500 characters").font(.footnote).foregroundStyle(.secondary)
                    Button("Extract text from PDF or text file") { importing = true }.disabled(extraction != nil || saving)
                    if extraction != nil { ProgressView("Extracting text on this device") }
                    if usedOCR {
                        Text("Review the recognized text against the scan before saving, especially dates and amounts.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Toggle("I have permission to store this excerpt", isOn: $authorized)
                    Text("Only the selected text is saved. Remove personal identifiers and confidential material outside your permission.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if saving { ProgressView("Encrypting and saving") }
                    if let error { Text(error).foregroundStyle(Color.orange) }
                }
            }
            .navigationTitle("Research Excerpt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(auth.userId != owner || !authorized || saving || extraction != nil || !(40...4_500).contains(excerpt.utf16.count) ||
                                  title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.utf16.count > 160)
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .plainText]) { result in
                extraction = Task {
                    defer { extraction = nil }
                    await readFile(result)
                }
            }
            .onDisappear { extraction?.cancel() }
        }
    }

    private func readFile(_ result: Result<URL, Error>) async {
        do {
            let url = try result.get()
            let worker = Task.detached(priority: .userInitiated) { try PrivateExcerptImport.read(url) }
            let imported = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()
            if title.isEmpty { title = String(imported.name.prefix(160)) }
            excerpt = imported.text
            usedOCR = imported.usedOCR
            authorized = false
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = "No readable text was extracted. Use an unlocked PDF or UTF-8 file under 10 MB, or paste an excerpt."
        }
    }

    private func save() {
        guard auth.userId == owner else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await PrivateMarketsAPI.send("save_document", ["title": title, "excerpt": excerpt, "authorized": authorized],
                                                 expectedUserID: owner)
                if auth.userId == owner { dismiss() }
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }
}

private enum PrivateExcerptImport {
    nonisolated static func read(_ url: URL) throws -> (name: String, text: String, usedOCR: Bool) {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, size <= 10 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        try Task.checkCancellation()
        let name = url.deletingPathExtension().lastPathComponent
        var text = ""
        var usedOCR = false
        if url.pathExtension.lowercased() == "pdf" {
            guard let pdf = PDFDocument(url: url), !pdf.isLocked else { throw CocoaError(.fileReadNoPermission) }
            var scansAttempted = 0
            for index in 0..<min(pdf.pageCount, 50) {
                try Task.checkCancellation()
                guard let page = pdf.page(at: index) else { continue }
                var extracted = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if extracted.isEmpty, scansAttempted < 8, let reference = page.pageRef {
                    scansAttempted += 1
                    extracted = (try? recognize(reference)) ?? ""
                    usedOCR = usedOCR || !extracted.isEmpty
                }
                if !extracted.isEmpty {
                    if !text.isEmpty { text += "\n\n" }
                    text += "[Page \(index + 1)]\n" + extracted
                }
                if text.utf16.count >= 4_500 { break }
            }
        } else {
            text = try String(contentsOf: url, encoding: .utf8)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return (name, String(decoding: text.utf16.prefix(4_500), as: UTF16.self), usedOCR)
    }

    nonisolated private static func recognize(_ page: CGPDFPage) throws -> String {
        let box = page.getBoxRect(.cropBox)
        guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else { return "" }
        let rotated = page.rotationAngle % 180 != 0
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        let scale = 2_400 / max(size.width, size.height)
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return "" }
        canvas.setFillColor(gray: 1, alpha: 1)
        canvas.fill(rect)
        canvas.concatenate(page.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
        canvas.drawPDFPage(page)
        guard let image = canvas.makeImage() else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
