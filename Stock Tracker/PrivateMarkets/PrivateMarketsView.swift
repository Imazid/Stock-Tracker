import SwiftUI

enum PrivateDestination: String, CaseIterable, Identifiable {
    case discovery = "Discover Deals"
    case explorer = "Startup Explorer"
    case research = "AI Investment Research"
    case room = "Deal Room"
    case portfolio = "My Private Portfolio"
    case rounds = "Funding Rounds"
    case capital = "Capital Calls & Distributions"
    case updates = "Company Updates"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .discovery: "magnifyingglass"
        case .explorer: "building.2"
        case .research: "sparkles"
        case .room: "folder"
        case .portfolio: "briefcase"
        case .rounds: "clock.arrow.circlepath"
        case .capital: "arrow.left.arrow.right"
        case .updates: "bell"
        }
    }
}

struct PrivateMarketsView: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var auth: SupabaseAuthManager
    @EnvironmentObject private var store: PrivateMarketsStore
    @EnvironmentObject private var router: TradingRouter
    @State private var path: [PrivateDestination] = []
    @State private var deals: [PrivateDeal] = []
    @State private var catalogError: String?
    @State private var loading = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if let error = store.storageError {
                        VStack(alignment: .leading) {
                            Text(error)
                            Button("Retry storage") { store.retryStorage() }
                        }
                        .privatePanel()
                    }
                    VStack(spacing: 2) {
                        ForEach(PrivateDestination.allCases.filter { $0 != .updates }) { destination in
                            NavigationLink(value: destination) {
                                HStack(spacing: 14) {
                                    Image(systemName: destination.icon)
                                        .foregroundStyle(destination == .research ? Color.purple : Color.cyan)
                                        .frame(width: 36, height: 36)
                                        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
                                        .accessibilityHidden(true)
                                    Text(destination.rawValue).font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary).accessibilityHidden(true)
                                }
                                .padding(.vertical, 7)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("private.destination.\(destination.icon)")
                            if destination != .capital { Divider().padding(.leading, 50) }
                        }
                    }
                    .privatePanel()
                    VStack(spacing: 12) {
                        NavigationLink {
                            PrivateInvestorView()
                        } label: { Label("Investor profile & applications", systemImage: "person.text.rectangle").frame(maxWidth: .infinity, alignment: .leading) }
                    }
                    .privatePanel()
                    if !deals.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Recently verified").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                            ForEach(deals.prefix(3)) { deal in
                                NavigationLink { PrivateDealDetail(deal: deal) } label: { PrivateDealRow(deal: deal) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, DS.Space.gutter)
                .padding(.vertical, 14)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("Private Markets")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { router.showCopilot = true } label: { Image(systemName: "text.bubble") }
                        .accessibilityLabel("Ask the copilot")
                        .accessibilityIdentifier("trading.copilot")
                    NavigationLink(value: PrivateDestination.updates) { Image(systemName: "bell") }
                        .accessibilityLabel("Company updates")
                        .accessibilityIdentifier("private.companyUpdates")
                }
            }
            .navigationDestination(for: PrivateDestination.self) { destination in
                switch destination {
                case .discovery, .explorer, .rounds:
                    PrivateDiscoveryView(title: destination.rawValue, deals: deals, loading: loading,
                                         error: catalogError, refresh: load, groupCompanies: destination == .explorer,
                                         showFundingHistory: destination == .rounds)
                case .research:
                    PrivateResearchWorkspace(deals: deals)
                case .room:
                    PrivateDealRoom()
                case .portfolio:
                    PrivateHoldingsView()
                case .capital:
                    PrivateCapitalView()
                case .updates:
                    PrivateUpdatesView()
                }
            }
            .refreshable { await load() }
        }
        .id(auth.userId)
        .onChange(of: auth.userId) { _, _ in path.removeAll() }
        .onChange(of: router.requestedPrivateDestination, initial: true) { _, destination in
            if let destination {
                path = [destination]
                router.requestedPrivateDestination = nil
            }
        }
        .task(id: auth.userId) { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "building.2.crop.circle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.cyan)
                .accessibilityHidden(true)
            Text("Private Markets")
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
            Text("Research companies, follow funding rounds, and track your private holdings.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background {
            RoundedRectangle(cornerRadius: 23)
                .fill(LinearGradient(colors: [Color(red: 0.05, green: 0.11, blue: 0.24),
                                              Color(red: 0.14, green: 0.10, blue: 0.30),
                                              Color(red: 0.05, green: 0.19, blue: 0.22)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }

    private func load() async {
        deals = []
        catalogError = nil
        loading = true
        defer { if !Task.isCancelled { loading = false } }
        do {
            let response: PrivateMarketsAPI.Catalog = try await PrivateMarketsAPI.request("catalog")
            try Task.checkCancellation()
            deals = response.deals
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { catalogError = error.localizedDescription }
        }
    }
}

private struct PrivateDiscoveryView: View {
    let title: String
    let deals: [PrivateDeal]
    let loading: Bool
    let error: String?
    let refresh: () async -> Void
    let groupCompanies: Bool
    let showFundingHistory: Bool

    @EnvironmentObject private var auth: SupabaseAuthManager
    @EnvironmentObject private var store: PrivateMarketsStore
    @State private var watchlistError: String?
    @State private var search = ""
    @State private var category = ""
    @State private var country = ""
    @State private var investorJurisdiction = ""
    @State private var sector = ""
    @State private var stage = ""
    @State private var status = ""
    @State private var eligibility = ""
    @State private var currency = ""
    @State private var maxMinimum = ""
    @State private var maxValuation = ""
    @State private var minTarget = ""
    @State private var maxTarget = ""
    @State private var hasTraction = false
    @State private var following = false
    @State private var showFilters = false

    private var filtered: [PrivateDeal] {
        let now = Date.now
        return deals.filter { deal in
            let matchesSearch = search.isEmpty || [
                deal.company.name, deal.company.sector, deal.company.country, deal.company.location ?? "",
                deal.company.description ?? "", deal.round.stage, deal.sourceName, deal.round.listing?.symbol ?? ""
            ].contains { $0.localizedCaseInsensitiveContains(search) }
            return matchesSearch && (category.isEmpty || deal.category == category) &&
                (country.isEmpty || deal.company.country == country) && (sector.isEmpty || deal.company.sector == sector) &&
                (investorJurisdiction.isEmpty || deal.jurisdictions.contains(investorJurisdiction)) &&
                (stage.isEmpty || deal.round.stage == stage) && (status.isEmpty || deal.displayedStatus(at: now) == status) &&
                (eligibility.isEmpty || deal.eligibility == eligibility) && (currency.isEmpty || deal.round.currency == currency) &&
                matches(deal.minimum, upper: maxMinimum) && matches(deal.round.valuation, upper: maxValuation) &&
                matches(deal.round.target, lower: minTarget, upper: maxTarget) &&
                (!hasTraction || deal.round.traction?.isEmpty == false || deal.company.financials?.isEmpty == false) &&
                (!following || store.state.follows.contains { $0.id == deal.company.id })
        }
    }

    private func matches(_ value: Decimal?, lower: String = "", upper: String) -> Bool {
        guard !lower.isEmpty || !upper.isEmpty else { return true }
        guard let value, !currency.isEmpty else { return false }
        let minimum = lower.isEmpty ? true : PrivateInput.amount(lower).map { value >= $0 } ?? false
        let maximum = upper.isEmpty ? true : PrivateInput.amount(upper).map { value <= $0 } ?? false
        return minimum && maximum
    }

    private var amountIssue: String? {
        let entries = [maxMinimum, maxValuation, minTarget, maxTarget].filter { !$0.isEmpty }
        if entries.contains(where: { PrivateInput.amount($0) == nil }) { return "Enter valid amounts in the selected currency." }
        if let low = PrivateInput.amount(minTarget), let high = PrivateInput.amount(maxTarget), low > high {
            return "The minimum raise target exceeds the maximum."
        }
        return nil
    }

    var body: some View {
        List {
            Section {
                Toggle("Following", isOn: $following)
                Button { showFilters = true } label: { Label("Filters", systemImage: "line.3.horizontal.decrease") }
                    .accessibilityIdentifier("private.discover.filters")
                if !investorJurisdiction.isEmpty {
                    LabeledContent("Investor jurisdiction", value: countryName(investorJurisdiction))
                }
                if auth.userId != nil {
                    NavigationLink { PrivateDiscoverySearchView() } label: {
                        Label("Search the catalogue with AI", systemImage: "sparkle.magnifyingglass")
                    }
                }
                if !groupCompanies, !loading, Set(filtered.map(\.round.id)).count > 1 {
                    NavigationLink("Compare funding rounds") {
                        PrivateRoundComparison(deals: filtered)
                    }
                    .accessibilityIdentifier("private.funding.compare")
                }
            }
            if showFundingHistory, !loading, error == nil {
                let listings = filtered.filter { $0.round.listing != nil }.sorted(by: listingOrder)
                if !listings.isEmpty {
                    Section("IPO milestones") {
                        ForEach(listings) { deal in
                            NavigationLink { PrivateDealDetail(deal: deal) } label: { PrivateFundingRoundRow(deal: deal) }
                                .accessibilityIdentifier("private.funding.listing.\(deal.round.listing?.symbol ?? "")")
                        }
                    }
                }
            }
            Section(groupCompanies ? "Companies" : showFundingHistory ? "Published rounds" : "Opportunities") {
                if loading {
                    VStack(spacing: DS.Space.l) {
                        ForEach(0..<3) { _ in
                            HStack(alignment: .top, spacing: DS.Space.m) {
                                SkeletonBlock(width: 36, height: 36, cornerRadius: 11)
                                SkeletonBlock(height: 12)
                            }
                        }
                    }
                    .padding(.vertical, DS.Space.s)
                    .privateLoadingLabel("Loading opportunities")
                } else if let error {
                    Text(error).foregroundStyle(.secondary)
                    Button("Retry") { Task { await refresh() } }
                } else if filtered.isEmpty {
                    Text(deals.isEmpty ? "No opportunities are published in the catalogue yet." : "No opportunities match these filters.")
                        .foregroundStyle(.secondary)
                } else if groupCompanies {
                    let companies = Dictionary(grouping: filtered, by: { $0.company.id })
                    let sorted = companies.keys.sorted { (companies[$0]?.first?.company.name ?? "") < (companies[$1]?.first?.company.name ?? "") }
                    ForEach(sorted, id: \.self) { id in
                        if let rounds = companies[id], let company = rounds.first?.company {
                            NavigationLink(company.name) {
                                PrivateCompanyFundingHistory(company: company,
                                                             rounds: deals.filter { $0.company.id == id })
                            }
                            .accessibilityIdentifier("private.explorer.company.\(id.uuidString)")
                        }
                    }
                } else if showFundingHistory {
                    let rounds = filtered.filter { $0.round.listing == nil }.sorted(by: fundingRoundOrder)
                    ForEach(rounds) { deal in
                        NavigationLink { PrivateDealDetail(deal: deal) } label: { PrivateFundingRoundRow(deal: deal) }
                    }
                } else {
                    ForEach(filtered) { deal in
                        NavigationLink { PrivateDealDetail(deal: deal) } label: { PrivateDealRow(deal: deal) }
                    }
                }
            }
            if following, !store.state.follows.isEmpty {
                Section("Watchlist") {
                    ForEach(store.state.follows) { company in
                        if company.source.privateSourceIsSafe {
                            Link(company.name, destination: company.source)
                                .swipeActions {
                                    Button("Unfollow", role: .destructive) {
                                        do { try store.change { $0.follows.removeAll { $0.id == company.id } } }
                                        catch { watchlistError = "The watchlist could not be saved." }
                                    }
                                }
                        }
                    }
                    if let watchlistError { Text(watchlistError).foregroundStyle(Color.orange) }
                }
            }
            Section("Provider websites") {
                ForEach(PrivateProvider.directory) { provider in
                    Link(destination: provider.url) {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(provider.name, systemImage: "arrow.up.right.square")
                                .font(.headline)
                            Text(provider.categories).font(.subheadline).foregroundStyle(.primary)
                            Text(provider.access).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Company, symbol, sector or provider")
        .refreshable { await refresh() }
        .onChange(of: currency) { _, _ in clearAmounts() }
        .sheet(isPresented: $showFilters) {
            NavigationStack {
                Form {
                    Section("Opportunity") {
                        picker("Category", selection: $category, values: deals.map(\.category))
                        picker("Stage", selection: $stage, values: deals.map(\.round.stage))
                        picker("Sector", selection: $sector, values: deals.map(\.company.sector))
                        picker("Company country", selection: $country, values: deals.map(\.company.country), valueLabel: countryName)
                        picker("Investor jurisdiction", selection: $investorJurisdiction,
                               values: deals.flatMap(\.jurisdictions), valueLabel: countryName)
                            .accessibilityIdentifier("private.discover.investorJurisdiction")
                        picker("Status", selection: $status, values: deals.map(\.displayedStatus))
                        picker("Eligibility", selection: $eligibility, values: deals.map(\.eligibility))
                        Toggle("Disclosed traction", isOn: $hasTraction)
                    }
                    Section("Amounts") {
                        picker("Currency", selection: $currency, values: deals.map(\.round.currency), valueLabel: { $0 })
                            .accessibilityIdentifier("private.discover.currency")
                        Group {
                            TextField("Maximum minimum investment", text: $maxMinimum)
                            TextField("Minimum raise target", text: $minTarget)
                                .accessibilityIdentifier("private.discover.targetMin")
                            TextField("Maximum raise target", text: $maxTarget)
                                .accessibilityIdentifier("private.discover.targetMax")
                            TextField("Maximum valuation", text: $maxValuation)
                        }
                        .keyboardType(.decimalPad)
                        .disabled(currency.isEmpty)
                        if let amountIssue { Text(amountIssue).foregroundStyle(.red) }
                    }
                    Button("Clear filters") {
                        category = ""; stage = ""; sector = ""; country = ""; status = ""; eligibility = ""
                        currency = ""; investorJurisdiction = ""; clearAmounts(); hasTraction = false
                    }
                }
                .navigationTitle("Filters")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showFilters = false }.disabled(amountIssue != nil)
                    }
                }
            }
        }
    }

    private func clearAmounts() {
        maxMinimum = ""; maxValuation = ""; minTarget = ""; maxTarget = ""
    }

    private func countryName(_ code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }

    private func picker(_ label: String, selection: Binding<String>, values: [String],
                        valueLabel: @escaping (String) -> String = { $0.capitalized }) -> some View {
        Picker(label, selection: selection) {
            Text("Any").tag("")
            ForEach(Set(values).sorted(), id: \.self) { Text(valueLabel($0)).tag($0) }
        }
    }
}

private struct PrivateDiscoverySearchView: View {
    private struct Results: Decodable {
        struct Criteria: Decodable {
            let countries, sectors, categories, statuses, eligibility, providers, unsupported: [String]
            let investorJurisdictions: [String]?
            let stages: [String]?
            let company, currency: String
            let maxMinimum, maxValuation: Decimal
            let minRaiseTarget, maxRaiseTarget: Decimal?
            let disclosedTraction: Bool
        }
        let criteria: Criteria
        let deals: [PrivateDeal]
        let matchedCount: Int
        let scannedAll: Bool
    }

    @EnvironmentObject private var auth: SupabaseAuthManager
    @State private var question = ""
    @State private var answer: Results?
    @State private var submitted: String?
    @State private var error: String?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        List {
            Section("Catalogue search") {
                TextField("Ask about a company, stage or sector", text: $question,
                          prompt: Text("Find closed Australian healthcare rounds"), axis: .vertical)
                    .lineLimit(2...4)
                    .accessibilityIdentifier("private.discover.question")
                Button("Search published opportunities", action: search)
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || question.utf16.count > 600 || searchTask != nil)
                if searchTask != nil { ProgressView("Checking published opportunities") }
                if let error { Text(error).foregroundStyle(.secondary) }
            }
            if let answer {
                Section("Interpreted filters") {
                    if let submitted { Text(submitted).font(.footnote).foregroundStyle(.secondary) }
                    filters(answer.criteria)
                }
                Section("Published results") {
                    if !answer.criteria.unsupported.isEmpty {
                        Text("Refine the highlighted filters to search the catalogue.")
                    } else if answer.deals.isEmpty {
                        Text("No published opportunities match these filters.")
                    }
                    if !answer.scannedAll { Text("This search checked the 500 most recently verified records.").font(.footnote) }
                    if answer.matchedCount > answer.deals.count {
                        Text("Showing \(answer.deals.count) of \(answer.matchedCount) matches.").font(.footnote)
                    }
                    ForEach(answer.deals) { deal in
                        NavigationLink { PrivateDealDetail(deal: deal) } label: { PrivateDealRow(deal: deal) }
                    }
                }
            }
        }
        .navigationTitle("Catalogue Search")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { searchTask?.cancel() }
    }

    @ViewBuilder
    private func filters(_ criteria: Results.Criteria) -> some View {
        let lists = [
            ("Company country", criteria.countries), ("Investor jurisdiction", criteria.investorJurisdictions ?? []),
            ("Sector", criteria.sectors), ("Category", criteria.categories), ("Stage", criteria.stages ?? []),
            ("Status", criteria.statuses), ("Eligibility", criteria.eligibility), ("Source", criteria.providers),
        ]
        ForEach(lists.filter { !$0.1.isEmpty }, id: \.0) { label, values in
            LabeledContent(label, value: values.joined(separator: ", "))
        }
        if !criteria.company.isEmpty { LabeledContent("Company", value: criteria.company) }
        if !criteria.currency.isEmpty { LabeledContent("Currency", value: criteria.currency) }
        if criteria.maxMinimum > 0 { LabeledContent("Maximum minimum investment", value: criteria.maxMinimum.formatted()) }
        if criteria.maxValuation > 0 { LabeledContent("Maximum valuation", value: criteria.maxValuation.formatted()) }
        if let low = criteria.minRaiseTarget, low > 0 { LabeledContent("Minimum raise target", value: low.formatted()) }
        if let high = criteria.maxRaiseTarget, high > 0 { LabeledContent("Maximum raise target", value: high.formatted()) }
        if criteria.disclosedTraction { Text("Disclosed traction required") }
        ForEach(criteria.unsupported, id: \.self) { Label($0, systemImage: "exclamationmark.circle").foregroundStyle(.secondary) }
    }

    private func search() {
        guard let owner = auth.userId, searchTask == nil else { return }
        let query = question.trimmingCharacters(in: .whitespacesAndNewlines)
        answer = nil
        error = nil
        searchTask = Task {
            defer { searchTask = nil }
            do {
                let result: Results = try await PrivateMarketsAPI.request("discover", ["question": query], expectedUserID: owner)
                try Task.checkCancellation()
                guard auth.userId == owner else { return }
                submitted = query
                answer = result
            } catch is CancellationError {
            } catch {
                if auth.userId == owner { self.error = error.localizedDescription }
            }
        }
    }
}

private struct PrivateDealRow: View {
    let deal: PrivateDeal
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let url = deal.company.logoUrl, url.privateSourceIsSafe {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image { image.resizable().scaledToFit().padding(4) }
                        else { logoPlaceholder }
                    }
                } else {
                    logoPlaceholder
                }
            }
                .frame(width: 36, height: 36)
                .background(.cyan.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(deal.company.name).font(.headline)
                Text("\(deal.category) · \(deal.company.sector) · \(deal.company.country)")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("\(deal.displayedStatus) · \(deal.sourceName)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(deal.displayedStatus == "Open at verification" ? Color.green : Color.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var logoPlaceholder: some View {
        Image(systemName: "building.2").foregroundStyle(Color.cyan)
    }
}

private func fundingRoundOrder(_ lhs: PrivateDeal, _ rhs: PrivateDeal) -> Bool {
    let leftStatus = lhs.displayedStatus
    let rightStatus = rhs.displayedStatus
    let leftActive = leftStatus == "Open at verification" || leftStatus == "Expression of interest"
    let rightActive = rightStatus == "Open at verification" || rightStatus == "Expression of interest"
    if leftActive != rightActive { return leftActive }
    if leftActive, lhs.round.closesAt != rhs.round.closesAt {
        return (lhs.round.closesAt ?? .distantFuture) < (rhs.round.closesAt ?? .distantFuture)
    }
    if lhs.round.announcedOn != rhs.round.announcedOn {
        return (lhs.round.announcedOn ?? .distantPast) > (rhs.round.announcedOn ?? .distantPast)
    }
    return lhs.id.uuidString < rhs.id.uuidString
}

private func listingOrder(_ lhs: PrivateDeal, _ rhs: PrivateDeal) -> Bool {
    guard let left = lhs.round.listing, let right = rhs.round.listing else { return fundingRoundOrder(lhs, rhs) }
    if left.hasUpcomingQuotation != right.hasUpcomingQuotation { return left.hasUpcomingQuotation }
    let leftDay = left.quotationOn ?? ""
    let rightDay = right.quotationOn ?? ""
    if leftDay != rightDay { return left.hasUpcomingQuotation ? leftDay < rightDay : leftDay > rightDay }
    return lhs.id.uuidString < rhs.id.uuidString
}

private struct PrivateFundingRoundRow: View {
    let deal: PrivateDeal

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(deal.round.stage).font(.headline)
            Text(deal.company.name).font(.subheadline)
            Text(deal.displayedStatus).font(.footnote).foregroundStyle(.secondary)
            if let listing = deal.round.listing {
                Text("\(listing.exchange) \(listing.symbol) · \(listing.displayStatus)")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                if let date = listing.quotationOn { Text(PrivateDeal.Round.Listing.formattedDay(date)).font(.footnote) }
            }
            if let date = deal.round.announcedOn {
                LabeledContent("Announced", value: date.formatted(date: .abbreviated, time: .omitted))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let raised = deal.round.raised {
                LabeledContent("Capital raised", value: PrivateInput.money(raised, currency: deal.round.currency))
                    .font(.footnote.monospacedDigit())
            }
            if let valuation = deal.round.valuation {
                LabeledContent("Reported valuation", value: PrivateInput.money(valuation, currency: deal.round.currency))
                    .font(.footnote.monospacedDigit())
            }
        }
        .padding(.vertical, DS.Space.xs)
        .accessibilityElement(children: .combine)
    }
}

private struct PrivateCompanyFundingHistory: View {
    let company: PrivateDeal.Company
    let rounds: [PrivateDeal]
    @EnvironmentObject private var auth: SupabaseAuthManager

    var body: some View {
        let history = rounds.sorted(by: fundingRoundOrder)
        List {
            Section {
                if let description = company.description { Text(description) }
                if company.sourceUrl.privateSourceIsSafe { Link("Company source", destination: company.sourceUrl) }
            }
            Section("Funding history") {
                ForEach(history) { deal in
                    NavigationLink { PrivateDealDetail(deal: deal) } label: { PrivateFundingRoundRow(deal: deal) }
                            .accessibilityIdentifier("private.funding.round.\(deal.round.stage)")
                }
            }
            PrivateCompanyFinancialsSections(company: company)
            if Set(history.map(\.round.id)).count > 1 {
                Section {
                    NavigationLink("Compare funding rounds") {
                        PrivateRoundComparison(deals: history, preselectRecentRounds: true)
                    }
                    .accessibilityIdentifier("private.funding.compare")
                }
            }
        }
        .navigationTitle(company.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PrivateRoundComparison: View {
    let deals: [PrivateDeal]?
    static let defaultQuestion = "Compare the selected funding rounds qualitatively. Explain the reported valuation basis and any gaps in the financing, dilution and investor rights. Keep amounts in the source citations. Use the word reported or undisclosed for each company. Keep dates and amounts out of the text."
    var question = PrivateRoundComparison.defaultQuestion
    var preselectRecentRounds = false
    @EnvironmentObject private var auth: SupabaseAuthManager
    @State private var catalog: [PrivateDeal] = []
    @State private var selection: [UUID] = []
    @State private var configuredSelection = false
    @State private var showPicker = false
    @State private var search = ""
    @State private var loading = false
    @State private var error: String?

    private var rounds: [PrivateDeal] {
        var seen: Set<UUID> = []
        return (deals ?? catalog).sorted(by: fundingRoundOrder).filter { seen.insert($0.round.id).inserted }
    }

    var body: some View {
        let available = rounds
        let selected = selection.compactMap { id in available.first { $0.round.id == id } }
        List {
            Section("Selected rounds") {
                if loading { ProgressView("Loading rounds") }
                if let error {
                    Text(error).foregroundStyle(.secondary)
                    Button("Retry") { Task { await load() } }
                }
                if selected.count < 2 { Text("Select two or three published rounds to compare.").foregroundStyle(.secondary) }
                Button("Choose rounds") { showPicker = true }
                    .disabled(available.isEmpty)
                    .accessibilityIdentifier("private.comparison.choose")
                if selected.count > 1 {
                    if auth.userId != nil {
                        NavigationLink("Research selected rounds") {
                            PrivateResearchWorkspace(deals: selected, comparisonQuestion: question)
                        }
                        .accessibilityIdentifier("private.comparison.research")
                    } else {
                        Text("Sign in from Account to ask AI about these rounds.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                ForEach(selected) { deal in
                    comparisonRow(deal)
                }
                if selected.count > 1, Set(selected.map(\.round.currency)).count > 1 {
                    Text("Figures use their original currencies.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Compare Funding Rounds")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPicker) { roundPicker(available) }
        .task {
            if deals == nil, catalog.isEmpty, error == nil { await load() }
            if preselectRecentRounds, !configuredSelection {
                selection = rounds.prefix(3).map(\.round.id)
                configuredSelection = true
            }
        }
    }

    private func roundPicker(_ available: [PrivateDeal]) -> some View {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = available.filter { deal in
            query.isEmpty || "\(deal.company.name) \(deal.round.stage) \(deal.round.listing?.symbol ?? "")".localizedCaseInsensitiveContains(query)
        }
        return NavigationStack {
            List {
                Section("\(selection.count) of 3 selected") {
                    if matches.isEmpty { Text("No published rounds match this search.").foregroundStyle(.secondary) }
                    ForEach(matches) { deal in
                        let isSelected = selection.contains(deal.round.id)
                        Button {
                            if isSelected { selection.removeAll { $0 == deal.round.id } }
                            else if selection.count < 3 { selection.append(deal.round.id) }
                        } label: {
                            Label("\(deal.company.name) · \(deal.round.stage)", systemImage: isSelected ? "checkmark.circle.fill" : "circle")
                        }
                        .disabled(!isSelected && selection.count == 3)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .accessibilityIdentifier("private.comparison.round.\(deal.round.id.uuidString)")
                    }
                }
            }
            .navigationTitle("Choose Rounds")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Company or round")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showPicker = false }
                        .accessibilityIdentifier("private.comparison.done")
                }
            }
        }
    }

    private func comparisonRow(_ deal: PrivateDeal) -> some View {
        let round = deal.round
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("\(deal.company.name) · \(round.stage)").font(.headline)
            if let date = round.announcedOn {
                LabeledContent("Announced", value: date.formatted(date: .abbreviated, time: .omitted))
            }
            LabeledContent("Round status", value: deal.displayedStatus)
            LabeledContent("Capital raised", value: round.raised.map { Self.amount($0, currency: round.currency) } ?? "Undisclosed")
            LabeledContent("Reported valuation", value: round.valuation.map { Self.amount($0, currency: round.currency) } ?? "Undisclosed")
            LabeledContent("Valuation basis", value: round.valuationMethod ?? "Undisclosed")
            if round.shareClasses.isEmpty { LabeledContent("Share class and rights", value: "Undisclosed") }
            else {
                ForEach(Array(round.shareClasses.enumerated()), id: \.offset) { _, share in
                    Text(share.name).font(.subheadline.weight(.semibold))
                    Text(share.rights).font(.footnote)
                    if share.sourceUrl.privateSourceIsSafe { Link("Read share-class source", destination: share.sourceUrl) }
                }
            }
            if round.sourceUrl.privateSourceIsSafe { Link("Read round source", destination: round.sourceUrl) }
            Button("Remove \(deal.company.name) \(round.stage) from comparison", role: .destructive) {
                selection.removeAll { $0 == round.id }
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, DS.Space.xs)
    }

    private static func amount(_ amount: Decimal, currency: String) -> String {
        "\(currency) \(amount.formatted(.number.precision(.fractionLength(0...4))))"
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let published: PrivateMarketsAPI.Catalog = try await PrivateMarketsAPI.request("catalog")
            try Task.checkCancellation()
            catalog = published.deals
        } catch is CancellationError {
        } catch { self.error = error.localizedDescription }
    }
}

private struct PrivateCompanyFinancialsSections: View {
    let company: PrivateDeal.Company

    var body: some View {
        let records = company.financials ?? []
        if !records.isEmpty {
            Section("Disclosed financials") {
                ForEach(records) { record in
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        Text(record.reportingPeriod).font(.headline)
                        Text(record.assurance == .audited ? "Audited financial statements" : "Issuer-reported figures")
                            .font(.footnote).foregroundStyle(.secondary)
                        financialAmount("Revenue", record.revenue, record.currency)
                        financialAmount("Annual recurring revenue", record.annualRecurringRevenue, record.currency)
                        if let growth = annualRevenueGrowth(record, records: records) {
                            LabeledContent("Year-over-year revenue change", value: growth.formatted(.percent.precision(.fractionLength(1))))
                        }
                        financialAmount("Net profit or loss", record.netProfitLoss, record.currency)
                        financialAmount("Net operating cash flow", record.operatingCashFlow, record.currency)
                        financialAmount("Cash and cash equivalents", record.cashAndEquivalents, record.currency)
                        LabeledContent("Disclosure published", value: PrivateDeal.Round.Listing.formattedDay(record.publishedOn))
                            .font(.footnote).foregroundStyle(.secondary)
                        if record.sourceUrl.privateSourceIsSafe { Link("Read financial disclosure", destination: record.sourceUrl) }
                    }
                    .padding(.vertical, DS.Space.xs)
                }
            }
        }
    }

    @ViewBuilder
    private func financialAmount(_ label: String, _ amount: Decimal?, _ currency: String) -> some View {
        if let amount { LabeledContent(label, value: PrivateInput.money(amount, currency: currency)) }
    }

    private func annualRevenueGrowth(_ current: PrivateDeal.Company.Financials, records: [PrivateDeal.Company.Financials]) -> Decimal? {
        guard current.periodKind == .financialYear, current.assurance == .audited, let revenue = current.revenue,
              let year = Int(current.periodEndOn.prefix(4)) else { return nil }
        let priorDate = String(year - 1) + current.periodEndOn.dropFirst(4)
        guard let prior = records.first(where: {
            $0.periodEndOn == priorDate && $0.periodKind == .financialYear && $0.assurance == .audited && $0.currency == current.currency
        })?.revenue, prior > 0 else { return nil }
        return revenue / prior - 1
    }
}

struct PrivateDealDetail: View {
    let deal: PrivateDeal
    var reviewedFromReport = false
    @EnvironmentObject private var store: PrivateMarketsStore
    @EnvironmentObject private var auth: SupabaseAuthManager
    @State private var error: String?
    private var followed: Bool { store.state.follows.contains { $0.id == deal.company.id } }

    var body: some View {
        List {
            Section {
                PrivateDealRow(deal: deal)
                if let description = deal.company.description { Text(description) }
                if let location = deal.company.location { LabeledContent("Location", value: location) }
                if let founders = deal.company.founders, !founders.isEmpty { LabeledContent("Founders", value: founders.joined(separator: ", ")) }
                if let investors = deal.company.investors, !investors.isEmpty { LabeledContent("Disclosed investors", value: investors.joined(separator: ", ")) }
                Button {
                    do { try store.toggleFollow(deal) } catch { self.error = error.localizedDescription }
                } label: { Label(followed ? "Unfollow company" : "Follow company", systemImage: followed ? "bookmark.fill" : "bookmark") }
            }
            Section("Funding terms") {
                LabeledContent("Stage", value: deal.round.stage)
                if let date = deal.round.announcedOn {
                    LabeledContent("Announced", value: date.formatted(date: .abbreviated, time: .omitted))
                }
                if deal.provider != "issuer" {
                    LabeledContent("Eligibility", value: deal.eligibility.capitalized)
                    LabeledContent("Investor jurisdictions", value: deal.jurisdictions.isEmpty
                        ? "Undisclosed" : deal.jurisdictions.map { Locale.current.localizedString(forRegionCode: $0) ?? $0 }.joined(separator: ", "))
                    LabeledContent("Minimum", value: PrivateInput.money(deal.minimum, currency: deal.round.currency))
                }
                LabeledContent("Raise target", value: PrivateInput.money(deal.round.target, currency: deal.round.currency))
                LabeledContent("Capital raised", value: PrivateInput.money(deal.round.raised, currency: deal.round.currency))
                LabeledContent("Valuation", value: PrivateInput.money(deal.round.valuation, currency: deal.round.currency))
                if let method = deal.round.valuationMethod { LabeledContent("Valuation basis", value: method) }
                if let traction = deal.round.traction { LabeledContent("Traction", value: traction) }
                if let deadline = deal.round.closesAt { LabeledContent("Deadline", value: deadline.formatted(date: .abbreviated, time: .shortened)) }
                ForEach(Array(deal.round.shareClasses.enumerated()), id: \.offset) { _, share in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(share.name).font(.headline)
                        Text(share.rights)
                        if share.sourceUrl.privateSourceIsSafe { Link("Share-class source", destination: share.sourceUrl) }
                    }
                }
            }
            if let listing = deal.round.listing {
                Section("IPO milestones") {
                    LabeledContent(listing.quotationStatus == .listed ? "Listed symbol" : "Proposed symbol",
                                   value: "\(listing.exchange) \(listing.symbol)")
                    if let expectedClose = listing.expectedOfferCloseOn {
                        LabeledContent("Expected offer close", value: PrivateDeal.Round.Listing.formattedDay(expectedClose))
                    }
                    if let date = listing.quotationOn {
                        LabeledContent(listing.quotationStatus.label, value: PrivateDeal.Round.Listing.formattedDay(date))
                    }
                    if listing.displayStatus != listing.quotationStatus.label || listing.quotationOn == nil {
                        Text(listing.displayStatus).font(.footnote).foregroundStyle(.secondary)
                    }
                    LabeledContent("Listing source verified", value: listing.verifiedAt.formatted(date: .abbreviated, time: .shortened))
                    if listing.sourceUrl.privateSourceIsSafe { Link("Read listing source", destination: listing.sourceUrl) }
                }
            }
            PrivateCompanyFinancialsSections(company: deal.company)
            Section("Sources") {
                LabeledContent("Verified", value: deal.verifiedAt.formatted(date: .abbreviated, time: .shortened))
                if deal.sourceUrl.privateSourceIsSafe { Link("Read source", destination: deal.sourceUrl) }
                if deal.company.sourceUrl.privateSourceIsSafe { Link("Company source", destination: deal.company.sourceUrl) }
                if deal.round.sourceUrl.privateSourceIsSafe { Link("Funding round source", destination: deal.round.sourceUrl) }
                if let document = deal.offerDocumentUrl, document.privateSourceIsSafe { Link("Read offer document", destination: document) }
            }
            Section("Research & applications") {
                NavigationLink("Research this opportunity") { PrivateResearchWorkspace(deals: [deal], selectedDealID: deal.id) }
                NavigationLink("Model exit scenarios") { PrivateScenarioCalculator(round: deal.round) }
                    .accessibilityIdentifier("private.deal.scenarios")
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    if deal.displayedStatus(at: context.date) == "Open at verification", auth.userId != nil,
                       deal.offerDocumentUrl?.privateSourceIsSafe == true {
                        NavigationLink("Provider application readiness") { PrivateProviderHandoff(deal: deal) }
                            .accessibilityIdentifier("private.deal.applicationReadiness")
                    } else if reviewedFromReport {
                        Text("Provider application readiness is unavailable for this round.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("private.deal.applicationUnavailable")
                    }
                }
                Text("Private investments can be illiquid and may lose their full value.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(deal.company.name)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Private Markets", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
}

extension View {
    func privateLoadingLabel(_ label: LocalizedStringKey) -> some View {
        accessibilityElement(children: .ignore).accessibilityLabel(label)
    }

    func privatePanel() -> some View {
        padding(16)
            .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 19))
            .overlay {
                RoundedRectangle(cornerRadius: 19).strokeBorder(.primary.opacity(0.07))
            }
    }
}
