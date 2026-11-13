import SwiftUI
import TradingCore

enum WorkspaceCommand: String, CaseIterable, Identifiable {
    case home, markets, portfolio, performance, agents, activity, search
    case copilot, newAgent, news, privateMarkets

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .home: "Home"
        case .markets: "Markets"
        case .portfolio: "Portfolio"
        case .performance: "Portfolio performance"
        case .agents: "Agents"
        case .activity: "Orders and activity"
        case .search: "Asset search"
        case .copilot: "Ask Copilot"
        case .newAgent: "Create an agent"
        case .news: "Market news"
        case .privateMarkets: "Private Markets"
        }
    }

    var keywords: String {
        switch self {
        case .home: "home overview dashboard"
        case .markets: "markets watchlists stocks"
        case .portfolio: "portfolio holdings investments allocation"
        case .performance: "portfolio performance analytics chart returns"
        case .agents: "agents automation strategies edit strategy backtests"
        case .activity: "orders and activity transaction history trades"
        case .search: "asset search stocks crypto etfs"
        case .copilot: "ask copilot ai research chat question"
        case .newAgent: "create an agent new strategy automation"
        case .news: "market news headlines"
        case .privateMarkets: "private markets private holdings research opportunities"
        }
    }

    var icon: String {
        switch self {
        case .home: MainTab.home.icon
        case .markets: MainTab.markets.icon
        case .portfolio: MainTab.portfolio.icon
        case .performance: "chart.line.uptrend.xyaxis"
        case .agents: MainTab.agents.icon
        case .activity: MainTab.activity.icon
        case .search: MainTab.search.icon
        case .copilot: "sparkles"
        case .newAgent: "plus"
        case .news: "newspaper"
        case .privateMarkets: MainTab.privateMarkets.icon
        }
    }
}

enum WorkspaceDestination {
    case command(WorkspaceCommand)
    case asset(Asset)
    case watchlist(UUID)
    case agent(UUID)
    case order(UUID)
    case trade(Instrument, OrderSide)
    case ask(String)
}

private struct CommandIntent {
    let term: String
    var side: OrderSide? = nil
    var question: String? = nil

    init(query: String) {
        let trimmed = query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let words = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        let rest = words.count == 2 ? String(words[1]) : ""
        switch words.first?.lowercased() {
        case "buy":
            term = rest
            side = .buy
        case "sell":
            term = rest
            side = .sell
        case "ask":
            term = ""
            question = rest
        default:
            term = trimmed
        }
    }
}

struct CommandPalette: View {
    let onSelect: (WorkspaceDestination) -> Void

    @EnvironmentObject private var marketData: MarketData
    @EnvironmentObject private var trading: TradingStore
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @StateObject private var assetSearch = SymbolSearchModel(prefetchQuotes: false)
    @ObservedObject private var recentSymbols = RecentSymbolStore.shared
    @AppStorage("recentWorkspaceCommands") private var recentCommands = ""
    @State private var query = ""
    @State private var selection: String?
    @FocusState private var searchFocused: Bool

    private struct Result: Identifiable {
        let id: String
        let title: Text
        var detail: String? = nil
        let icon: String
        let destination: WorkspaceDestination
        var symbol: SymbolHit? = nil
    }

    private struct GroupedResults: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let rows: [Result]
    }

    private var intent: CommandIntent { CommandIntent(query: query) }

    private var groups: [GroupedResults] {
        let intent = intent
        if let question = intent.question {
            if question.isEmpty {
                return [GroupedResults(id: "commands", title: "Commands", rows: [row(for: .copilot)])]
            }
            let result = Result(id: "ask", title: Text("Ask Copilot"), detail: question,
                                icon: "sparkles", destination: .ask(question))
            return [GroupedResults(id: "copilot", title: "Copilot", rows: [result])]
        }

        if let side = intent.side {
            let rows = assetRows(term: intent.term, side: side)
            return rows.isEmpty ? [] : [GroupedResults(id: "trade", title: "Practice trading", rows: rows)]
        }

        if intent.term.isEmpty {
            let recent = recentCommands.split(separator: ",").compactMap { WorkspaceCommand(rawValue: String($0)) }
            let recentRows = recent.map { row(for: $0) } + recentSymbols.items.prefix(3).compactMap { assetRow($0, side: nil) }
            let actions: [WorkspaceCommand] = [.copilot, .newAgent, .performance, .activity]
            return [
                GroupedResults(id: "recent", title: "Recent", rows: recentRows),
                GroupedResults(id: "suggested", title: "Suggested", rows: actions.filter { !recent.contains($0) }.map { row(for: $0) }),
                GroupedResults(id: "navigation", title: "Navigation", rows: WorkspaceCommand.allCases
                    .filter { !recent.contains($0) && !actions.contains($0) }.map { row(for: $0) })
            ].filter { !$0.rows.isEmpty }
        }

        let commandRows = ranked(WorkspaceCommand.allCases, term: intent.term, text: \.keywords).map { row(for: $0) }
        let watchlists = ranked(marketData.watchlistGroups, term: intent.term, text: \.name).prefix(6).map {
            Result(id: "list:\($0.id)", title: Text($0.name), icon: "star", destination: .watchlist($0.id))
        }
        let agents = ranked(trading.agents, term: intent.term, text: \.name).prefix(6).map {
            Result(id: "agent:\($0.id)", title: Text($0.name), detail: $0.statusText,
                   icon: "gearshape.2", destination: .agent($0.id))
        }
        let orders = ranked(Array(trading.orders.prefix(50)), term: intent.term) {
            "\($0.instrument.symbol) \($0.side.rawValue.capitalized)"
        }.prefix(5).map {
            Result(id: "order:\($0.id)", title: Text("\($0.side.rawValue.capitalized) \($0.instrument.symbol)"),
                   detail: "\($0.status.displayName) · \(TradingFormat.time($0.createdAt))", icon: "list.bullet.rectangle", destination: .order($0.id))
        }
        return [
            GroupedResults(id: "commands", title: "Commands", rows: commandRows),
            GroupedResults(id: "assets", title: "Assets", rows: assetRows(term: intent.term, side: nil)),
            GroupedResults(id: "lists", title: "Watchlists", rows: watchlists),
            GroupedResults(id: "agents", title: "Agents", rows: agents),
            GroupedResults(id: "orders", title: "Recent orders", rows: orders)
        ].filter { !$0.rows.isEmpty }
    }

    private var pendingAssets: Bool {
        let intent = intent
        return intent.question == nil && !intent.term.isEmpty
            && (assetSearch.query != intent.term || assetSearch.phase == .searching)
    }

    var body: some View {
        let groups = groups
        let rows = groups.flatMap(\.rows)
        let selected = rows.first(where: { $0.id == selection }) ?? rows.first

        NavigationStack {
            VStack(spacing: 0) {
                searchField
                    .onSubmit { if let selected { run(selected) } }
                    .onKeyPress(.escape) {
                        dismiss()
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        moveSelection(in: rows, from: selected?.id, by: 1)
                        return rows.isEmpty ? .ignored : .handled
                    }
                    .onKeyPress(.upArrow) {
                        moveSelection(in: rows, from: selected?.id, by: -1)
                        return rows.isEmpty ? .ignored : .handled
                    }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: DS.Space.l) {
                            ForEach(groups) { group in
                                resultGroup(group, selected: selected?.id)
                            }
                            if pendingAssets {
                                VStack(spacing: 0) {
                                    ForEach(0..<3) { _ in SearchRowSkeleton() }
                                }
                                .loadingSkeleton("Searching for assets")
                                .accessibilityIdentifier("commands.loading")
                            } else if groups.isEmpty {
                                emptyState
                            }
                        }
                        .padding(DS.Space.l)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: selection) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
            .background {
                theme.background.opacity(0.96).ignoresSafeArea()
            }
            .navigationTitle("Command palette")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.escape, modifiers: [])
                }
            }
        }
        .onChange(of: query) { _, _ in
            selection = nil
            assetSearch.query = intent.term
        }
        .task { searchFocused = true }
        .accessibilityIdentifier("commands.palette")
    }

    private var searchField: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: "command")
                .foregroundStyle(theme.intelligenceTint)
                .accessibilityHidden(true)
            TextField("Search assets and commands", text: $query)
                .focused($searchFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.go)
                .accessibilityIdentifier("commands.query")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Clear query")
            }
        }
        .padding(.leading, DS.Space.l)
        .padding(.trailing, DS.Space.xs)
        .frame(minHeight: 48)
        .background(theme.secondaryBackground, in: RoundedRectangle(cornerRadius: DS.Radius.chip))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.chip)
                .strokeBorder(searchFocused ? DS.accent.opacity(0.7) : theme.cardBorder, lineWidth: 1)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.top, DS.Space.s)
    }

    private func resultGroup(_ group: GroupedResults, selected: String?) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(group.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.secondaryText)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, DS.Space.m)
            ForEach(group.rows) { result in
                Button { run(result) } label: {
                    HStack(spacing: DS.Space.m) {
                        Image(systemName: result.icon)
                            .foregroundStyle(result.icon == "sparkles" ? theme.intelligenceTint : theme.secondaryText)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            result.title.font(.subheadline.weight(.medium)).foregroundStyle(theme.primaryText)
                            if let detail = result.detail {
                                Text(detail).font(.caption).foregroundStyle(theme.secondaryText).lineLimit(2)
                            }
                        }
                        Spacer(minLength: DS.Space.xs)
                        if result.id == selected {
                            Image(systemName: "return")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(DS.accent)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, DS.Space.m)
                    .padding(.vertical, DS.Space.xs)
                    .frame(minHeight: 44)
                    .background(result.id == selected ? theme.cardBackground : .clear,
                                in: RoundedRectangle(cornerRadius: DS.Radius.chip))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("commands.result.\(result.id)")
                .id(result.id)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if intent.side != nil && intent.term.isEmpty {
            Text("Enter a ticker or asset name to prepare a practice order.")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
        } else if assetSearch.phase == .failed {
            InlineRetryNote(text: "Asset search is unavailable.") { assetSearch.retry() }
        } else {
            ContentUnavailableView.search(text: query)
        }
    }

    private func row(for command: WorkspaceCommand) -> Result {
        Result(id: command.id, title: Text(command.title), icon: command.icon, destination: .command(command))
    }

    private func assetRows(term: String, side: OrderSide?) -> [Result] {
        guard !term.isEmpty else { return [] }
        let cached = marketData.watchlistGroups.flatMap(\.assets) + marketData.portfolio.map(\.asset)
        let tracked = cached.map { asset in
            let exchange = QuoteService.isASX(asset) ? "ASX" : asset.exchange
            return SymbolHit(symbol: asset.symbol, name: asset.name, kind: asset.kind, exchange: exchange)
        }
        let local = tracked + recentSymbols.items + (OnboardingCatalog.us + OnboardingCatalog.asx + OnboardingCatalog.crypto)
            .map { SymbolHit(picked: $0) }
        let matching = ranked(local, term: term) { "\($0.symbol) \($0.name)" }
        let remote = assetSearch.query == term && assetSearch.phase != .searching ? assetSearch.hits : []
        var seen: Set<String> = []
        let merged = (matching + remote).filter { seen.insert($0.id).inserted }
            .enumerated()
            .sorted { (SymbolRanking.score($0.element, query: term), $0.offset)
                    < (SymbolRanking.score($1.element, query: term), $1.offset) }
            .map(\.element)
        return Array(merged.lazy.compactMap { assetRow($0, side: side) }.prefix(7))
    }

    private func assetRow(_ hit: SymbolHit, side: OrderSide?) -> Result? {
        let known = marketData.watchlist + marketData.portfolio.map(\.asset) + marketData.watchlistGroups.flatMap(\.assets)
        let asset = known.first(where: { $0.price > 0 && hit.matches($0) }) ?? hit.placeholderAsset()
        if let side {
            guard let instrument = Instrument(asset: asset) else { return nil }
            return Result(id: hit.id, title: Text("\(side.rawValue.capitalized) \(hit.symbol)"),
                          detail: "\(hit.name) · \(hit.badge)", icon: "arrow.left.arrow.right",
                          destination: .trade(instrument, side), symbol: hit)
        }
        return Result(id: hit.id, title: Text(hit.symbol), detail: "\(hit.name) · \(hit.badge)",
                      icon: "chart.xyaxis.line", destination: .asset(asset), symbol: hit)
    }

    private func ranked<Value>(_ values: [Value], term: String, text: (Value) -> String) -> [Value] {
        values.enumerated().compactMap { index, value in
            matchScore(text(value), term: term).map { (index, value, $0) }
        }
        .sorted { ($0.2, $0.0) < ($1.2, $1.0) }
        .map { $0.1 }
    }

    private func matchScore(_ text: String, term: String) -> Int? {
        let candidate = text.lowercased()
        let query = term.lowercased()
        if candidate.hasPrefix(query) { return 0 }
        if candidate.contains(query) { return 1 }
        let words = candidate.split(whereSeparator: \.isWhitespace)
        let tokens = query.split(whereSeparator: \.isWhitespace)
        if tokens.allSatisfy({ token in words.contains(where: { $0.hasPrefix(token) }) }) { return 2 }
        guard !query.contains(where: \.isWhitespace), query.count >= 3 else { return nil }
        return words.contains { word in
            var remaining = query[...]
            for letter in word where letter == remaining.first { remaining = remaining.dropFirst() }
            return remaining.isEmpty
        } ? 3 : nil
    }

    private func moveSelection(in rows: [Result], from id: String?, by offset: Int) {
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == id } ?? 0
        selection = rows[(index + offset + rows.count) % rows.count].id
    }

    private func run(_ result: Result) {
        Haptics.tap()
        if let symbol = result.symbol { recentSymbols.record(symbol) }
        if case .command(let command) = result.destination {
            let old = recentCommands.split(separator: ",").map(String.init).filter { $0 != command.id }
            recentCommands = ([command.id] + old.prefix(3)).joined(separator: ",")
        }
        onSelect(result.destination)
    }
}

struct WorkspaceCommandButton: View {
    @EnvironmentObject private var router: TradingRouter
    @Environment(\.theme) private var theme
    var expanded = false

    var body: some View {
        Button {
            Haptics.tap()
            router.showCommands = true
        } label: {
            if expanded {
                HStack(spacing: DS.Space.m) {
                    Image(systemName: "magnifyingglass").foregroundStyle(theme.intelligenceTint)
                    Text("Search assets and commands")
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryText)
                    Spacer(minLength: DS.Space.xs)
                }
                .padding(.horizontal, DS.Space.l)
                .frame(minHeight: 48)
                .dsCard(padding: 0)
                .contentShape(Rectangle())
            } else {
                Image(systemName: "command")
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(PressableButtonStyle())
        .keyboardShortcut("k", modifiers: .command)
        .accessibilityLabel("Open command palette")
        .accessibilityHint("Search stocks, crypto and actions")
        .accessibilityIdentifier("commands.open")
    }
}
