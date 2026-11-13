//
//  ActivityTabView.swift
//  Stock Tracker
//
//  The Activity tab: open orders, order history and fills; what agents decided
//  and why; and the audit trail. Also the Pause-all sheet and Home's trading
//  summary card.
//
//  The tab is careful about three words. A *proposal* is a suggestion. An
//  *order* was placed. A *fill* actually traded. Each has its own status and
//  none is ever shown as another.
//

import SwiftUI
import TradingCore

struct ActivityTabView: View {
    @EnvironmentObject private var trading: TradingStore
    @EnvironmentObject private var router: TradingRouter
    @Environment(\.theme) private var theme

    enum Section: String, CaseIterable, Identifiable {
        case orders = "Orders"
        case decisions = "Decisions"
        case audit = "Audit"
        var id: String { rawValue }
    }

    enum OrderFilter: String, CaseIterable, Identifiable {
        case all = "All", open = "Open", filled = "Filled", cancelled = "Cancelled", rejected = "Rejected"
        var id: String { rawValue }

        func includes(_ order: Order) -> Bool {
            switch self {
            case .all: return true
            case .open: return order.status.isOpen
            case .filled: return order.status == .filled
            case .cancelled: return order.status == .canceled || order.status == .expired
            case .rejected: return order.status == .rejected
            }
        }
    }

    @State private var section: Section = .orders
    @State private var filter: OrderFilter = .all

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.l) {
                    TradingHomeBadge()
                    PausedAllBanner { router.showPauseAll = true }

                    if let problem = trading.dataProblem {
                        HStack(alignment: .firstTextBaseline) {
                            Label(problem, systemImage: "wifi.exclamationmark")
                                .font(.footnote)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Retry") { Task { await trading.refreshPrices() } }
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(DS.accent)
                        }
                        .dsCard(padding: DS.Space.m)
                        .accessibilityIdentifier("activity.dataProblem")
                    }

                    Picker("Show", selection: $section) {
                        ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("activity.section")
                    .sensoryFeedback(.selection, trigger: section)

                    ZStack(alignment: .topLeading) {
                        Group {
                            switch section {
                            case .orders: ordersList
                            case .decisions: decisionsList
                            case .audit: auditList
                            }
                        }
                        .transition(.opacity)
                    }
                    .motionSafeAnimation(DS.quick, value: section)
                }
                .padding(.horizontal, DS.Space.gutter)
                .padding(.top, DS.Space.s)
                .padding(.bottom, 60)
            }
            .refreshable { await trading.refreshPrices() }
            .dsScreenBackground()
            .navigationTitle("Activity")
            .toolbar { TradingToolbar() }
        }
        .accessibilityIdentifier("activity.screen")
    }

    // MARK: Orders

    private var ordersList: some View {
        let all = trading.orders
        let shown = all.filter(filter.includes)
        let open = shown.filter { $0.status.isOpen }
        let closed = shown.filter { !$0.status.isOpen }
        return VStack(alignment: .leading, spacing: DS.Space.l) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.s) {
                    ForEach(OrderFilter.allCases) { option in
                        let count = all.filter(option.includes).count
                        Button {
                            Haptics.select()
                            filter = option
                        } label: {
                            Text("\(option.rawValue) \(count)")
                                .font(.footnote.weight(.semibold).monospacedDigit())
                                .padding(.horizontal, DS.Space.m)
                                .frame(minHeight: 34)
                                .foregroundStyle(filter == option ? theme.invertedPrimaryText : theme.primaryText)
                                .background(Capsule().fill(filter == option ? theme.primaryText : theme.subtleFill))
                        }
                        .accessibilityLabel("\(option.rawValue), \(count)")
                        .accessibilityAddTraits(filter == option ? .isSelected : [])
                        .accessibilityIdentifier("activity.filter.\(option.rawValue)")
                    }
                }
            }

            if all.isEmpty {
                EmptyStateCard(systemImage: "list.bullet.rectangle", title: "No orders yet",
                               message: "Practice orders you or your agents place appear here, with what happened to each one.")
                    .accessibilityIdentifier("activity.empty")
            } else if shown.isEmpty {
                EmptyStateCard(systemImage: "line.3.horizontal.decrease.circle", title: "Nothing \(filter.rawValue.lowercased())",
                               message: "No orders match this filter.", primaryTitle: "Show all", primaryAction: { filter = .all })
            } else {
                if !open.isEmpty {
                    TradingSection(title: "Open", trailing: "\(open.count)") {
                        ForEach(open) { orderButton($0) }
                    }
                }
                ForEach(grouped(closed), id: \.title) { group in
                    TradingSection(title: LocalizedStringKey(group.title)) {
                        ForEach(group.orders) { orderButton($0) }
                    }
                }
            }
        }
    }

    private func orderButton(_ order: Order) -> some View {
        Button { router.order = TradingRouter.Ref(id: order.id) } label: {
            VStack(alignment: .leading, spacing: 4) {
                OrderRowView(order: order)
                if order.status == .partiallyFilled, order.quantity > 0 {
                    ProgressView(value: order.filledQuantity, total: order.quantity)
                        .tint(theme.primaryText)
                        .accessibilityLabel("Filled")
                        .accessibilityValue("\(Int((order.filledQuantity / order.quantity * 100).rounded())) percent")
                }
                if order.status == .rejected, let note = order.statusNote {
                    Text(note).font(.caption).foregroundStyle(theme.negativeColor).lineLimit(2)
                }
            }
        }
        .buttonStyle(PressableButtonStyle())
    }

    private func grouped(_ orders: [Order]) -> [(title: String, orders: [Order])] {
        let calendar = Calendar.current
        var groups: [(String, [Order])] = []
        for order in orders {
            let title: String
            if calendar.isDateInToday(order.updatedAt) { title = "Today" }
            else if calendar.isDateInYesterday(order.updatedAt) { title = "Yesterday" }
            else { title = order.updatedAt.formatted(.dateTime.day().month(.wide).year()) }
            if let last = groups.last, last.0 == title {
                groups[groups.count - 1].1.append(order)
            } else {
                groups.append((title, [order]))
            }
        }
        return groups.map { (title: $0.0, orders: $0.1) }
    }

    // MARK: Decisions

    private var decisionsList: some View {
        let proposals = trading.state.proposals.sorted { $0.createdAt > $1.createdAt }
        let signals = trading.state.signals.sorted { $0.createdAt > $1.createdAt }
        // Signals that never became a proposal (signal-only agents) still belong here.
        let proposed = Set(proposals.map(\.signalID))
        let loose = signals.filter { !proposed.contains($0.id) }
        return VStack(alignment: .leading, spacing: DS.Space.l) {
            if proposals.isEmpty && loose.isEmpty {
                EmptyStateCard(systemImage: "gearshape.2", title: "No agent decisions yet",
                               message: "When an agent sees a signal, what it proposed, which checks it passed and what happened next appear here.",
                               primaryTitle: "Go to Agents", primaryAction: { router.requestedTab = .agents })
            }
            if !proposals.isEmpty {
                TradingSection(title: "Proposed trades") {
                    ForEach(proposals.prefix(60)) { proposal in
                        Button { router.proposal = TradingRouter.Ref(id: proposal.id) } label: { ProposalRowView(proposal: proposal) }
                            .buttonStyle(PressableButtonStyle())
                    }
                }
            }
            if !loose.isEmpty {
                TradingSection(title: "Signals") {
                    ForEach(loose.prefix(60)) { signal in SignalRowView(signal: signal) }
                }
            }
        }
    }

    // MARK: Audit

    private var auditList: some View {
        let verification = trading.verifyAudit()
        let events = trading.auditNewestFirst
        return VStack(alignment: .leading, spacing: DS.Space.l) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Image(systemName: verification.isIntact ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(verification.isIntact ? theme.positiveColor : theme.negativeColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verification.isIntact ? "Record intact" : "Record has been altered")
                        .font(.subheadline.weight(.semibold))
                    Text(verification.isIntact
                         ? "\(verification.eventCount) events, each one sealed to the one before it. Nothing here can be edited or removed."
                         : "The chain breaks at event \(verification.brokenAtSequence ?? 0). Events after that point can't be trusted.")
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .dsCard()
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(verification.isIntact ? "audit.intact" : "audit.broken")

            if events.isEmpty {
                EmptyStateCard(systemImage: "checklist", title: "Nothing recorded yet",
                               message: "Every order, fill, agent change and limit change is written here as it happens.")
            } else {
                TradingSection(title: "Everything that happened") {
                    ForEach(events.prefix(200)) { event in
                        AuditRowView(event: event)
                        Divider()
                    }
                }
            }
        }
    }
}

// MARK: - Rows

struct ProposalRowView: View {
    let proposal: TradeProposal
    @EnvironmentObject private var trading: TradingStore
    @Environment(\.theme) private var theme

    private var tint: Color {
        switch proposal.status {
        case .blocked, .failed: return theme.negativeColor
        case .submitted: return theme.positiveColor
        case .pending: return theme.primaryText
        default: return theme.secondaryText
        }
    }

    var body: some View {
        let agent = trading.agent(proposal.agentID)?.name ?? "An agent"
        let currency = proposal.instrument.currency
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(agent).font(.caption.weight(.semibold)).foregroundStyle(theme.secondaryText)
                Spacer()
                Text(TradingFormat.time(proposal.createdAt)).font(.caption).foregroundStyle(theme.secondaryText)
            }
            Text("\(proposal.side == .buy ? "Buy" : "Sell") \(TradingFormat.units(proposal.quantity, proposal.instrument)) · about \(TradingFormat.money(proposal.notional, currency))")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.primaryText)
            StatusLabel(systemImage: proposal.status.glyph, text: proposal.status.displayName, tint: tint, compact: true)
            if proposal.status == .blocked || proposal.status == .failed, let note = proposal.resolutionNote {
                Text(note).font(.caption).foregroundStyle(theme.secondaryText).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("proposal.row.\(proposal.instrument.symbol).\(proposal.status.rawValue)")
    }
}

struct SignalRowView: View {
    let signal: TradingSignal
    @EnvironmentObject private var trading: TradingStore
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(trading.agent(signal.agentID)?.name ?? "An agent").font(.caption.weight(.semibold)).foregroundStyle(theme.secondaryText)
                Spacer()
                Text(TradingFormat.time(signal.createdAt)).font(.caption).foregroundStyle(theme.secondaryText)
            }
            Text("\(signal.action.rawValue.capitalized) signal · \(signal.instrument.symbol)")
                .font(.subheadline.weight(.semibold))
            Text(signal.headline).font(.footnote).foregroundStyle(theme.secondaryText).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("signal.row.\(signal.instrument.symbol).\(signal.action.rawValue)")
    }
}

struct AuditRowView: View {
    let event: AuditEvent
    @Environment(\.theme) private var theme

    private var actor: String {
        switch event.actor {
        case .user: return "You"
        case .agent: return "Agent"
        case .system: return "System"
        case .copilot: return "Copilot"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(event.kind.title).font(.subheadline.weight(.semibold))
                if event.mode == .paper { PracticeChip(compact: true) }
                Spacer()
                Text("#\(event.sequence)").font(.caption2.monospacedDigit()).foregroundStyle(theme.secondaryText)
            }
            Text(event.summary).font(.footnote).foregroundStyle(theme.secondaryText).fixedSize(horizontal: false, vertical: true)
            Text("\(actor) · \(event.time.formatted(date: .abbreviated, time: .standard))")
                .font(.caption2)
                .foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("audit.row.\(event.kind.rawValue)")
    }
}

// MARK: - Order detail

/// One order: its status in a sentence, how much has filled, the timeline, the numbers,
/// why it was placed and — if it was refused — exactly why.
struct OrderDetailView: View {
    let orderID: UUID

    @EnvironmentObject private var trading: TradingStore
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var confirmCancel = false

    var body: some View {
        Group {
            if let order = trading.order(orderID) {
                content(order)
            } else {
                ContentUnavailableView("Order not found", systemImage: "doc.questionmark",
                                       description: Text("This order is no longer in the history."))
            }
        }
        .dsScreenBackground()
        .navigationTitle("Order")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) { PracticeChip() }
        }
    }

    private func headline(_ order: Order) -> String {
        let what = "\(TradingFormat.orderTitle(order.type, order.side)) of \(order.instrument.name)"
        switch order.status {
        case .pendingSubmit: return "\(what), being sent."
        case .accepted: return "\(what), waiting to trade."
        case .partiallyFilled: return "\(what), partly filled."
        case .filled: return "\(what), filled."
        case .canceled: return order.filledQuantity > 0 ? "\(what), part filled then cancelled." : "\(what), cancelled."
        case .rejected: return "\(what), refused."
        case .expired: return "\(what), expired."
        }
    }

    private func content(_ order: Order) -> some View {
        let currency = order.instrument.currency
        let fills = trading.fills(for: order.id)
        let events = trading.state.audit.events.filter { $0.orderID == order.id }
        let proposal = trading.proposal(order.source.proposalID)
        return ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    InstrumentLabel(instrument: order.instrument, logoSize: 40)
                    Text(headline(order))
                        .font(DS.display(.title2))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("order.headline")
                    StatusLabel(systemImage: order.status.glyph, text: order.status.displayName)
                }

                if order.quantity > 0, order.status != .rejected {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: min(order.filledQuantity, order.quantity), total: order.quantity)
                            .tint(theme.primaryText)
                        Text("Filled \(TradingFormat.quantity(order.filledQuantity, order.instrument)) of \(TradingFormat.units(order.quantity, order.instrument)) · \(Int((order.filledQuantity / order.quantity * 100).rounded()))%")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(theme.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                }

                if let note = order.statusNote, order.status != .filled {
                    Text(note)
                        .font(.footnote)
                        .padding(DS.Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                            .strokeBorder(order.status == .rejected ? theme.negativeColor : theme.cardBorder, lineWidth: 1))
                        .accessibilityIdentifier("order.note")
                }

                VStack(spacing: DS.Space.m) {
                    TradingRow(label: "Account", value: TradingFormat.accountName(trading.ledger(order.ledgerID)?.name))
                    TradingRow(label: "Order type", value: order.type.displayName)
                    TradingRow(label: "Good for", value: order.timeInForce.displayName)
                    TradingRow(label: "Quantity", value: TradingFormat.units(order.quantity, order.instrument))
                    if let limit = order.limitPrice { TradingRow(label: "Limit price", value: TradingFormat.price(limit, currency)) }
                    if let stop = order.stopPrice { TradingRow(label: "Stop price", value: TradingFormat.price(stop, currency)) }
                    TradingRow(label: "Price when checked", value: TradingFormat.price(order.referencePrice, currency))
                    if order.filledQuantity > 0 {
                        Divider()
                        TradingRow(label: "Average fill price", value: TradingFormat.price(order.averageFillPrice, currency))
                        TradingRow(label: "Fees", value: TradingFormat.money(order.fees, currency))
                        TradingRow(label: order.side == .buy ? "Total paid" : "Total received",
                                   value: TradingFormat.money(order.side == .buy ? order.filledNotional + order.fees : order.filledNotional - order.fees, currency),
                                   emphasised: true)
                        if let realized = fills.compactMap(\.realizedPnL).reduce(nil as Double?, { ($0 ?? 0) + $1 }) {
                            TradingRow(label: "Realised profit", value: TradingFormat.signedMoney(realized, currency))
                        }
                    }
                    if let expiry = order.expiresAt, order.status.isOpen {
                        TradingRow(label: "Expires", value: TradingFormat.time(expiry))
                    }
                }
                .dsCard()

                TradingSection(title: "Why") {
                    if let agent = trading.agent(order.source.agentID) {
                        Text("Placed by \(agent.name) (strategy version \(proposal?.strategyVersion ?? agent.strategyVersion)).")
                            .font(.subheadline)
                        if let proposal {
                            Text(proposal.headline).font(.footnote).foregroundStyle(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            if let signal = trading.signal(proposal.signalID), !signal.evidence.isEmpty {
                                EvidenceList(evidence: signal.evidence)
                            }
                        }
                    } else if order.source.isAgent {
                        Text("Placed by an agent that has since been deleted.").font(.subheadline)
                    } else {
                        Text("Placed by you.").font(.subheadline)
                    }
                }

                if !events.isEmpty {
                    TradingSection(title: "Timeline") {
                        ForEach(events) { event in
                            HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
                                Text(event.time.formatted(date: .omitted, time: .standard))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(theme.secondaryText)
                                    .frame(width: 76, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.kind.title).font(.subheadline.weight(.semibold))
                                    Text(event.summary).font(.footnote).foregroundStyle(theme.secondaryText)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Order ID").font(.caption).foregroundStyle(theme.secondaryText)
                    Text(order.id.uuidString).font(.caption.monospaced()).textSelection(.enabled)
                }

                if order.status.isOpen {
                    Button("Cancel order", role: .destructive) { confirmCancel = true }
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .accessibilityIdentifier("order.cancel")
                        .confirmationDialog("Cancel this order?", isPresented: $confirmCancel, titleVisibility: .visible) {
                            Button("Cancel order", role: .destructive) { Task { try? await trading.cancelOrder(order.id) } }
                            Button("Keep it", role: .cancel) {}
                        } message: {
                            Text(order.filledQuantity > 0 ? "The part that already filled stays. The rest won't trade." : "It won't trade.")
                        }
                }

                PracticeNote()
            }
            .padding(.horizontal, DS.Space.gutter)
            .padding(.vertical, DS.Space.l)
        }
        .accessibilityIdentifier("order.detail")
    }
}

// MARK: - Pause all

/// Stops every agent at once. Stopping is one confirmed tap; it says exactly what stops and
/// what carries on. Starting again is the careful direction: each agent is resumed by hand.
struct PauseAllSheet: View {
    @EnvironmentObject private var trading: TradingStore
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var cancelled: Int?
    @State private var problem: String?

    var body: some View {
        let openAgentOrders = trading.openOrders.filter { $0.source.isAgent }.count
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    if trading.isKillSwitchOn {
                        pausedBody
                    } else {
                        Text("Pause all agents?")
                            .font(DS.display(.largeTitle))
                            .accessibilityAddTraits(.isHeader)
                        VStack(alignment: .leading, spacing: DS.Space.m) {
                            line("pause.circle", "\(trading.activeAgentCount) running agent\(trading.activeAgentCount == 1 ? "" : "s") stop checking the market and placing orders.")
                            line("slash.circle", openAgentOrders == 0 ? "No agent orders are open." : "\(openAgentOrders) open agent order\(openAgentOrders == 1 ? " is" : "s are") cancelled.")
                            line("hand.raised", "Proposals waiting for approval expire.")
                            line("briefcase", "Positions are not sold. Closing them stays your call.")
                            line("person", "Orders you place yourself still work.")
                        }
                        Text("You can turn this off at any time. Agents stay paused until you resume each one.")
                            .font(.footnote)
                            .foregroundStyle(theme.secondaryText)
                    }
                    if let problem {
                        Text(problem).font(.footnote).foregroundStyle(theme.negativeColor)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("pauseAll.problem")
                    }
                }
                .padding(.horizontal, DS.Space.gutter)
                .padding(.vertical, DS.Space.xl)
            }
            .dsScreenBackground()
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: DS.Space.s) {
                    if trading.isKillSwitchOn {
                        Button("Turn off pause-all") {
                            Task {
                                do {
                                    try await trading.releaseKillSwitch()
                                    Haptics.tap()
                                    dismiss()
                                } catch {
                                    problem = error.localizedDescription
                                }
                            }
                        }
                        .buttonStyle(PrimaryPillButtonStyle())
                        .accessibilityIdentifier("pauseAll.release")
                    } else {
                        Button("Pause all") {
                            Task {
                                do {
                                    cancelled = try await trading.engageKillSwitch()
                                    Haptics.warning()
                                    UIAccessibility.post(notification: .announcement, argument: "All agents paused")
                                } catch {
                                    problem = error.localizedDescription
                                }
                            }
                        }
                        .buttonStyle(PrimaryPillButtonStyle())
                        .accessibilityIdentifier("pauseAll.confirm")
                    }
                    Button(trading.isKillSwitchOn ? "Done" : "Cancel") { dismiss() }
                        .buttonStyle(QuietTextButtonStyle())
                        .accessibilityIdentifier("pauseAll.dismiss")
                }
                .padding(.horizontal, DS.Space.gutter)
                .padding(.vertical, DS.Space.m)
            }
        }
        .presentationDetents([.large])
        .accessibilityIdentifier("pauseAll.sheet")
    }

    private var pausedBody: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Image(systemName: "pause.circle.fill").font(.system(size: 36)).accessibilityHidden(true)
            Text("All agents are paused")
                .font(DS.display(.largeTitle))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("pauseAll.pausedTitle")
            if let cancelled {
                Text(cancelled == 0 ? "No orders needed cancelling." : "\(cancelled) open order\(cancelled == 1 ? " was" : "s were") cancelled.")
                    .font(.body)
            }
            Text("No agent can place an order while this is on. Turning it off does not restart anything: go to Agents and resume the ones you want running.")
                .font(.body)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func line(_ systemImage: String, _ text: String) -> some View {
        Label {
            Text(text).font(.body).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).frame(width: 24)
        }
    }
}

// MARK: - Home card

/// Home's summary of practice money, running agents and anything waiting for a decision.
struct HomeTradingSection: View {
    @EnvironmentObject private var trading: TradingStore
    @EnvironmentObject private var router: TradingRouter
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "Agents and practice", actionTitle: trading.agents.isEmpty ? nil : "See all",
                          action: trading.agents.isEmpty ? nil : { router.requestedTab = .agents })

            if !trading.hasAnything {
                // One compact row, not a second big empty card under the portfolio's.
                Button {
                    Haptics.tap()
                    router.createAgent()
                } label: {
                    HStack(spacing: DS.Space.m) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(LinearGradient(colors: [DS.accentFill, theme.glowSecondary],
                                                                     startPoint: .topLeading, endPoint: .bottomTrailing)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Put a strategy to work")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(theme.primaryText)
                            Text("Describe it in a sentence; an agent trades it with practice money and shows every decision.")
                                .font(.footnote)
                                .foregroundStyle(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: DS.Space.s)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(theme.secondaryText)
                    }
                    .dsCard()
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Create an agent. Describe a strategy in a sentence and an agent trades it with practice money.")
                .accessibilityIdentifier("home.trading.empty")
            } else {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("Practice money").font(.subheadline).foregroundStyle(theme.secondaryText)
                                PracticeChip(compact: true)
                            }
                            MoneyText(text: TradingFormat.money(trading.practiceEquity(currency: "USD"), "USD"), size: 30)
                                .contentTransition(.numericText())
                                .accessibilityIdentifier("home.trading.equity")
                            // Other currencies are listed as they are, never converted and added up.
                            let others = Currencies.supported.filter { $0 != "USD" }
                                .map { ($0, trading.practiceEquity(currency: $0)) }.filter { $0.1 > 0 }
                            if !others.isEmpty {
                                Text("and " + others.map { TradingFormat.money($0.1, $0.0) }.joined(separator: " · "))
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(theme.secondaryText)
                            }
                        }
                        Spacer()
                    }

                    if trading.isKillSwitchOn {
                        PausedAllBanner { router.showPauseAll = true }
                    } else {
                        HStack {
                            StatusLabel(systemImage: trading.activeAgentCount > 0 ? "play.circle.fill" : "pause.circle",
                                        text: "\(trading.activeAgentCount) of \(trading.agents.count) agent\(trading.agents.count == 1 ? "" : "s") running")
                            Spacer()
                            if trading.activeAgentCount > 0 {
                                Button("Pause all") { router.showPauseAll = true }
                                    .font(.footnote.weight(.semibold))
                                    .padding(.horizontal, DS.Space.m)
                                    .frame(minHeight: 34)
                                    .overlay(Capsule().strokeBorder(theme.primaryText.opacity(0.5), lineWidth: 1))
                                    .foregroundStyle(theme.primaryText)
                                    .accessibilityIdentifier("home.trading.pauseAll")
                            }
                        }
                    }

                    if !trading.pendingProposals.isEmpty {
                        Button {
                            router.requestedTab = .agents
                        } label: {
                            HStack {
                                Label("\(trading.pendingProposals.count) trade\(trading.pendingProposals.count == 1 ? "" : "s") waiting for your decision", systemImage: "hand.raised")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(theme.primaryText)
                            .frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("home.trading.approvals")
                    }
                }
                .dsCard()
                .accessibilityIdentifier("home.trading.card")
                if trading.orders.contains(where: { $0.mode == .paper }) {
                    recentOrders
                }
            }
        }
    }

    private var recentOrders: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader(title: "Recent practice orders", actionTitle: "See all",
                          action: { router.requestedTab = .activity })
            VStack(spacing: 0) {
                ForEach(trading.orders.filter { $0.mode == .paper }.prefix(3)) { order in
                    Button {
                        Haptics.tap()
                        router.order = TradingRouter.Ref(id: order.id)
                    } label: {
                        HStack(spacing: DS.Space.m) {
                            InstrumentLabel(instrument: order.instrument, logoSize: 32)
                            Spacer(minLength: DS.Space.xs)
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(TradingFormat.orderTitle(order.type, order.side))
                                    .font(.caption.weight(.semibold))
                                Text(order.status.displayName)
                                    .font(.caption)
                                    .foregroundStyle(theme.secondaryText)
                            }
                        }
                        .foregroundStyle(theme.primaryText)
                        .padding(.vertical, DS.Space.xs)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .dsCard(padding: DS.Space.m)
        }
        .accessibilityIdentifier("home.trading.recentOrders")
    }

}
