//
//  TradingNavigation.swift
//  Stock Tracker
//
//  How the trading screens are reached from anywhere: one router that tabs,
//  cards and notifications ask, and one place (the root) that presents what was
//  asked for. Also the Markets tab, which holds the watchlist and the news.
//

import SwiftUI
import Combine
import TradingCore

enum MarketsSection: String, CaseIterable, Identifiable {
    case watchlist = "Watchlist"
    case search = "Search"
    case news = "News"
    var id: String { rawValue }
}

@MainActor
final class TradingRouter: ObservableObject {
    static let shared = TradingRouter()

    struct Ticket: Identifiable {
        let id = UUID()
        let instrument: Instrument
        let side: OrderSide
        var ledgerID: UUID?
    }

    struct NewAgent: Identifiable {
        let id = UUID()
        var prefill: Instrument?
        var prompt: String?
    }

    struct Ref: Identifiable, Equatable {
        let id: UUID
    }

    /// Set to move to a tab; the root clears it once it has switched.
    @Published var requestedTab: MainTab?
    @Published var marketsSection: MarketsSection = .watchlist
    @Published var ticket: Ticket?
    @Published var newAgent: NewAgent?
    @Published var agent: Ref?
    @Published var proposal: Ref?
    @Published var order: Ref?
    /// A practice portfolio's page. Presented from the root: a sheet owned by a row of the
    /// Portfolio tab's lazy list closed itself (and the order ticket on top of it) whenever
    /// the list redrew after a trade.
    @Published var practicePortfolio: Ref?
    @Published var showCopilot = false
    @Published var showPauseAll = false

    /// Opens the order ticket. Only for use from a tab's own screen; a view already inside
    /// a sheet should present the ticket itself.
    func trade(_ instrument: Instrument, side: OrderSide, ledgerID: UUID? = nil) {
        ticket = Ticket(instrument: instrument, side: side, ledgerID: ledgerID)
    }

    func createAgent(prefill: Instrument? = nil, prompt: String? = nil) {
        newAgent = NewAgent(prefill: prefill, prompt: prompt)
    }

    /// From a notification tap.
    func open(route: String, proposalID: UUID?, orderID: UUID?) {
        if route == "approvals" {
            requestedTab = .agents
            if let proposalID, TradingStore.shared.proposal(proposalID)?.status == .pending {
                proposal = Ref(id: proposalID)
            }
        } else {
            requestedTab = .activity
            if let orderID { order = Ref(id: orderID) }
        }
    }
}

/// Presents whatever the router was asked for, from the root of the app.
struct TradingRootSheets: ViewModifier {
    @EnvironmentObject private var router: TradingRouter
    @EnvironmentObject private var trading: TradingStore

    func body(content: Content) -> some View {
        content
            .sheet(item: $router.ticket) { ticket in
                OrderTicketView(instrument: ticket.instrument, side: ticket.side, ledgerID: ticket.ledgerID)
            }
            .sheet(item: $router.newAgent) { request in
                CreateAgentFlow(prefill: request.prefill, prompt: request.prompt)
            }
            .sheet(item: $router.agent) { ref in
                NavigationStack { AgentDetailView(agentID: ref.id) }
            }
            .sheet(item: $router.proposal) { ref in
                ProposalReviewSheet(proposalID: ref.id)
            }
            .sheet(item: $router.order) { ref in
                NavigationStack { OrderDetailView(orderID: ref.id) }
            }
            .sheet(item: $router.practicePortfolio) { ref in
                NavigationStack { PracticePortfolioDetailView(ledgerID: ref.id) }
            }
            .sheet(isPresented: $router.showPauseAll) {
                PauseAllSheet()
            }
            .sheet(isPresented: $router.showCopilot) {
                CopilotView()
            }
    }
}

// MARK: - Markets tab

/// Watchlist, search and news under one tab.
struct MarketsTabView: View {
    @EnvironmentObject private var router: TradingRouter
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $router.marketsSection) {
                ForEach(MarketsSection.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, DS.Space.gutter)
            .padding(.top, DS.Space.s)
            .padding(.bottom, DS.Space.s)
            .accessibilityIdentifier("markets.section")

            ZStack {
                Group {
                    switch router.marketsSection {
                    case .watchlist: AppleStocksWatchlistView()
                    case .search: StockSearchView()
                    case .news: NewsView()
                    }
                }
                .transition(.opacity)
            }
            .motionSafeAnimation(DS.quick, value: router.marketsSection)
        }
        .dsScreenBackground()
    }
}

// MARK: - Shared top-bar items

/// The Practice marker and the copilot button, for the top bar of every trading tab.
struct TradingToolbar: ToolbarContent {
    @EnvironmentObject private var router: TradingRouter

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            PracticeChip()
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                router.marketsSection = .search
                router.requestedTab = .markets
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .accessibilityLabel("Search stocks and crypto")
            .accessibilityIdentifier("trading.search")
            Button {
                Haptics.tap()
                router.showCopilot = true
            } label: {
                Image(systemName: "text.bubble")
            }
            .accessibilityLabel("Ask the copilot")
            .accessibilityIdentifier("trading.copilot")
        }
    }
}
