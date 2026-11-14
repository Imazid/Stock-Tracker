//
//  SnapTradeConnectionView.swift
//  Stock Tracker
//
//  Broker & exchange connections via SnapTrade (read-only).
//  Not connected: what you get, a grid of popular brokers to start from in one
//  tap, and the promises (after Yahoo Finance's "Link broker" and Copilot /
//  Rocket Money's linking screens on Mobbin). Connected: one card per
//  institution with its status, last update and accounts (after Origin and
//  Lloyds' connected accounts), what the last sync added, and a review for
//  positions the broker no longer reports. Syncs import on their own; nothing
//  is removed without asking.
//

import SwiftUI
import SafariServices

enum SnapTradeAutoMode {
    case broker, crypto
}

// MARK: - Connection screen

struct SnapTradeConnectionView: View {
    @EnvironmentObject private var marketData: MarketData
    @ObservedObject private var vm = SnapTradeViewModel.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    private let autoMode: SnapTradeAutoMode?
    @State private var showPicker = false
    @State private var confirmDisconnect = false
    @State private var confirmRemovals = false
    @State private var confetti = 0

    init(autoMode: SnapTradeAutoMode? = nil) {
        self.autoMode = autoMode
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    if vm.hasLinkedAccounts {
                        connectedContent
                    } else {
                        introContent
                    }
                }
                .padding(DS.Space.gutter)
                .motionSafeAnimation(DS.spring, value: vm.hasLinkedAccounts)
            }
            .dsScreenBackground()
            .overlay { if vm.isLoading { loadingOverlay } }
            // Bursts from the "Added N holdings" banner.
            .overlay { ConfettiBurst(trigger: confetti, origin: UnitPoint(x: 0.5, y: 0.3)).ignoresSafeArea() }
            .onChange(of: vm.lastImport) { _, summary in
                // Holdings just arrived from a broker — worth a moment.
                if (summary?.added ?? 0) > 0 {
                    Haptics.success()
                    confetti += 1
                }
            }
            .navigationTitle("Brokers & exchanges")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("broker.done")
                }
            }
            .sheet(isPresented: $showPicker) {
                InstitutionPickerSheet(initialFilter: autoMode) { slug in
                    Task { await vm.connectBroker(broker: slug) }
                }
            }
            .sheet(isPresented: $vm.showConnectionView) {
                if let url = vm.connectionURL {
                    SafariView(url: url)
                        .ignoresSafeArea()
                        .onDisappear { Task { await vm.syncAll() } }
                }
            }
            .alert(vm.errorTitle, isPresented: $vm.showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(vm.errorMessage ?? "Something went wrong. Please try again.")
            }
            .confirmationDialog(removalTitle, isPresented: $confirmRemovals, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    vm.confirmPendingRemovals()
                    Haptics.success()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("They and their transactions leave your portfolio. Holdings you added yourself aren't affected.")
            }
            .confirmationDialog("Disconnect your brokers?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) { Task { await vm.disconnect() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The connection is removed at SnapTrade, so nothing can read your broker any more. Holdings already in your portfolio stay, but stop updating.")
            }
            .onAppear {
                if autoMode != nil && !vm.hasLinkedAccounts {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showPicker = true }
                }
            }
            .task { await vm.loadDirectory() }
        }
    }

    // MARK: - Not connected

    private var introContent: some View {
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            hero
            if vm.isAuthenticated {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    InlineNote(icon: "hourglass",
                               text: "Your last connection wasn't finished. Pick your broker again to complete signing in.")
                    // Clears the half-made connection at SnapTrade too.
                    Button("Start over") { Task { await vm.disconnect() } }
                        .buttonStyle(QuietTextButtonStyle())
                        .accessibilityIdentifier("broker.startOver")
                }
            }
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text("Popular")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: DS.Space.s), GridItem(.flexible())],
                          spacing: DS.Space.s) {
                    ForEach(Array(popular.enumerated()), id: \.element.id) { index, institution in
                        popularTile(institution).staggeredAppear(index + 2)
                    }
                }
                Button("See all brokers and exchanges") {
                    Haptics.tap()
                    showPicker = true
                }
                .buttonStyle(SecondaryPillButtonStyle())
                .padding(.top, DS.Space.xs)
                .accessibilityIdentifier("broker.seeAll")
            }
            promises
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: -10) {
                ForEach(popular.prefix(3)) { institution in
                    InstitutionTile(name: institution.name, size: 48, logoURL: institution.logoURL)
                        .overlay(RoundedRectangle(cornerRadius: 48 * 0.28, style: .continuous)
                            .strokeBorder(theme.background, lineWidth: 3))
                }
            }
            .accessibilityHidden(true)
            Text("Bring in what you own")
                .font(DS.display(.title))
                .foregroundStyle(theme.primaryText)
                .accessibilityAddTraits(.isHeader)
            Text("Connect your broker or exchange. Your holdings, what you paid and what they're worth come in on their own and stay up to date.")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.s) {
                badge("eye", "Read-only")
                badge("lock.fill", "Secure sign-in")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("broker.hero")
    }

    private func badge(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(theme.primaryText)
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, 6)
            .background(Capsule().fill(theme.subtleFill))
    }

    private func popularTile(_ institution: InstitutionPickerSheet.Institution) -> some View {
        Button {
            Haptics.tap()
            Task { await vm.connectBroker(broker: institution.slug) }
        } label: {
            HStack(spacing: DS.Space.s) {
                InstitutionTile(name: institution.name, size: 36, logoURL: institution.logoURL)
                VStack(alignment: .leading, spacing: 1) {
                    Text(institution.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(2)
                        .minimumScaleFactor(0.9)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(institution.kindLabel)
                        .font(.caption2)
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(DS.Space.m)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(theme.cardBackground))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(theme.cardBorder.opacity(0.5), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.97))
        .accessibilityLabel("Connect \(institution.name)")
        .accessibilityIdentifier("broker.popular.\(institution.slug)")
    }

    /// Six to start from, for where the person invests (CommSec and Stake first for ASX
    /// investors). Only institutions SnapTrade currently lists, and none in maintenance.
    private var popular: [InstitutionPickerSheet.Institution] {
        let au = InstitutionPickerSheet.prefersAustralia
        let ibkr = "INTERACTIVE-BROKERS-FLEX"
        let slugs: [String]
        switch autoMode {
        case .crypto: slugs = ["COINBASE", "KRAKEN", "BINANCE"]
        case .broker: slugs = au ? ["COMMSEC", "STAKEAUS", ibkr, "MOOMOO", "ETORO", "SCHWAB"]
                                 : ["ROBINHOOD", "SCHWAB", "FIDELITY", ibkr, "WEBULL", "PUBLIC"]
        case nil:     slugs = au ? ["COMMSEC", "STAKEAUS", ibkr, "MOOMOO", "COINBASE", "KRAKEN"]
                                 : ["ROBINHOOD", "SCHWAB", "FIDELITY", ibkr, "COINBASE", "KRAKEN"]
        }
        let all = InstitutionPickerSheet.catalog(from: vm.directory)
        return slugs.compactMap { slug in all.first { $0.slug == slug && !$0.inMaintenance } }
    }

    private var promises: some View {
        VStack(alignment: .leading, spacing: 0) {
            promise(icon: "eye", title: "Read-only", detail: "Stock Tracker can see your positions. It can never trade or move money.")
            promise(icon: "lock.shield", title: "Secure sign-in", detail: "You sign in on your broker's own page through SnapTrade. We never see your password.")
            promise(icon: "arrow.triangle.2.circlepath", title: "Stays up to date", detail: "New positions come in each time you sync. Holdings you added yourself are never changed.")
        }
        .dsCard()
    }

    private func promise(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(DS.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, DS.Space.s)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Connected

    private var connectedContent: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            statusHeader
            if let summary = vm.lastImport {
                importBanner(summary)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if !vm.pendingRemovals.isEmpty {
                removalCard
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
            ForEach(Array(vm.institutions.enumerated()), id: \.element) { index, name in
                institutionCard(name).staggeredAppear(index + 1)
            }
            positionsSection
            Button("Connect another broker") {
                Haptics.tap()
                showPicker = true
            }
            .buttonStyle(SecondaryPillButtonStyle())
            .accessibilityIdentifier("broker.connect")
            Button("Disconnect", role: .destructive) { confirmDisconnect = true }
                .font(.body.weight(.medium))
                .foregroundStyle(theme.negativeColor)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("broker.disconnect")
        }
    }

    private var statusHeader: some View {
        HStack(alignment: .center, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Connected")
                    .font(DS.display(.title2))
                    .foregroundStyle(theme.primaryText)
                Text(syncLine)
                    .font(.subheadline)
                    .foregroundStyle(vm.lastSyncFailed ? theme.negativeColor : theme.secondaryText)
            }
            Spacer()
            Button {
                Haptics.tap()
                Task { await vm.syncAll() }
            } label: {
                Label("Sync now", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DS.accent)
                    .padding(.horizontal, DS.Space.m)
                    .frame(minHeight: 36)
                    .background(Capsule().fill(DS.accent.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .disabled(vm.isLoading)
            .accessibilityIdentifier("broker.sync")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("broker.connected")
    }

    private var syncLine: String {
        let accounts = vm.accounts.count == 1 ? "1 account" : "\(vm.accounts.count) accounts"
        if vm.lastSyncFailed { return "\(accounts) · Last sync failed" }
        guard let synced = vm.lastSyncedAt else { return "\(accounts) · Not synced yet" }
        return "\(accounts) · \(SnapTradeViewModel.syncedText(synced))"
    }

    private func importBanner(_ summary: SnapTradeViewModel.SyncSummary) -> some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(theme.positiveColor)
                .symbolEffect(.bounce, options: .nonRepeating, value: confetti)
            VStack(alignment: .leading, spacing: 2) {
                Text(importHeadline(summary))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                Text(importDetail(summary))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .dsCard(padding: DS.Space.m)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("broker.import")
    }

    private func importHeadline(_ s: SnapTradeViewModel.SyncSummary) -> String {
        if s.added > 0 { return s.added == 1 ? "Added 1 holding to your portfolio" : "Added \(s.added) holdings to your portfolio" }
        if s.updated > 0 { return s.updated == 1 ? "Updated 1 holding" : "Updated \(s.updated) holdings" }
        return "Your portfolio is up to date"
    }

    private func importDetail(_ s: SnapTradeViewModel.SyncSummary) -> String {
        var parts: [String] = []
        if s.overLimit > 0 {
            parts.append("\(s.overLimit) not added — your plan's holding limit was reached.")
        }
        if !s.skipped.isEmpty {
            parts.append("You already track \(s.skipped.joined(separator: ", ")) yourself, so \(s.skipped.count == 1 ? "it was" : "they were") left alone.")
        }
        if !s.review.isEmpty {
            parts.append("Review older combined positions for \(s.review.joined(separator: ", ")). Check their history before removing them and syncing again.")
        }
        if parts.isEmpty { parts.append("Shares and average cost come from your broker and update each time you sync.") }
        return parts.joined(separator: " ")
    }

    private var removalCard: some View {
        let symbols = vm.pendingRemovals.map { holding in
            [holding.asset.symbol, vm.institution(for: holding)].compactMap { $0 }.joined(separator: " · ")
        }
        return VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(alignment: .top, spacing: DS.Space.m) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(symbols.joined(separator: ", ")) \(symbols.count == 1 ? "is" : "are") no longer at your broker")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Sold or moved? Remove \(symbols.count == 1 ? "it" : "them") from your portfolio, or keep tracking \(symbols.count == 1 ? "it" : "them") yourself.")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: DS.Space.s) {
                Button("Remove") { confirmRemovals = true }
                    .buttonStyle(PrimaryPillButtonStyle())
                    .accessibilityIdentifier("broker.removals.remove")
                Button("Keep") {
                    Haptics.tap()
                    vm.keepPendingRemovals()
                }
                .buttonStyle(SecondaryPillButtonStyle())
                .accessibilityIdentifier("broker.removals.keep")
            }
        }
        .dsCard(padding: DS.Space.m)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("broker.removals")
    }

    private var removalTitle: String {
        let n = vm.pendingRemovals.count
        return n == 1 ? "Remove \(vm.pendingRemovals[0].asset.symbol)?" : "Remove \(n) holdings?"
    }

    private func institutionCard(_ name: String) -> some View {
        let accounts = vm.accounts.filter { $0.institutionName == name }
        return VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.m) {
                InstitutionTile(name: name, size: 44, logoURL: vm.logoURL(for: name))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DS.Space.s) {
                        Text(vm.displayName(forInstitution: name)).font(.headline).foregroundStyle(theme.primaryText)
                        statusPill
                    }
                    Text(updatedLine)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: 0)
            }
            ForEach(accounts) { account in
                Divider().overlay(theme.cardBorder.opacity(0.4))
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(theme.primaryText)
                        Text([account.accountType, account.maskedAccountNumber, account.positionsStatus?.label]
                            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(theme.secondaryText)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(account.balance?.total.map(display) ?? "—")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(theme.primaryText)
                        if let cash = account.balance?.cash, cash.amount > 0 {
                            Text("Cash \(display(cash))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .dsCard(padding: DS.Space.m)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("broker.institution.\(name)")
    }

    private var statusPill: some View {
        let failed = vm.lastSyncFailed
        return Text(failed ? "Needs attention" : "Active")
            .font(.caption2.weight(.bold))
            .foregroundStyle(failed ? Color.orange : theme.positiveColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill((failed ? Color.orange : theme.positiveColor).opacity(0.14)))
    }

    private var updatedLine: String {
        guard let synced = vm.lastSyncedAt else { return "Not synced yet" }
        return SnapTradeViewModel.syncedText(synced)
    }

    // MARK: Positions

    private var positionsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("Positions").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Text("\(vm.holdings.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
            }
            if vm.holdings.isEmpty {
                Text("No positions found yet. Sync again once your broker finishes linking.")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(vm.holdings.enumerated()), id: \.element.id) { index, position in
                        positionRow(position).staggeredAppear(index + 3)
                        if position.id != vm.holdings.last?.id {
                            Divider().overlay(theme.cardBorder.opacity(0.4)).padding(.leading, 44)
                        }
                    }
                }
                .dsCard(padding: DS.Space.m)
            }
        }
    }

    private func positionRow(_ position: BrokerHolding) -> some View {
        let tracked = trackedHolding(for: position)
        let institution = vm.accounts.first { $0.id == position.accountId }
            .map { vm.displayName(forInstitution: $0.institutionName) } ?? ""
        // Same wording as the portfolio: shares for stocks/ETFs, the coin for crypto.
        let units = tracked?.asset.unitsText(position.quantity) ?? {
            let q = formatQuantity(position.quantity)
            if vm.isCrypto(position) { return "\(q) \(position.symbol)" }
            return position.quantity == 1 ? "1 share" : "\(q) shares"
        }()
        return HStack(spacing: DS.Space.m) {
            TickerLogo(symbol: tracked?.asset.symbol ?? position.symbol,
                       kind: tracked?.asset.kind ?? .stock,
                       exchange: tracked?.asset.exchange ?? "", size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(tracked?.asset.symbol ?? position.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                Text([units, institution].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            // The live value the portfolio shows; the broker's figure only for positions not imported.
            Text(tracked.map { marketData.formatPrice($0.currentValue) }
                 ?? display(Money(amount: position.marketValue, currency: position.currency)))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(theme.primaryText)
        }
        .padding(.vertical, DS.Space.s)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("broker.position.\(tracked?.asset.symbol ?? position.symbol)")
    }

    private func trackedHolding(for position: BrokerHolding) -> PortfolioHolding? {
        vm.trackedHolding(for: position, in: marketData.portfolio)
    }

    /// A broker amount in the display currency, with an explicit A$ / US$ like everywhere else.
    private func display(_ money: Money) -> String {
        guard let factor = FXRates.shared.toUSDFactor(from: money.currency) else { return money.formattedAmount }
        return marketData.formatPrice(money.amount * factor)
    }

    private var loadingOverlay: some View {
        VStack(spacing: DS.Space.m) {
            ProgressView()
            Text(vm.loadingMessage.isEmpty ? "Working…" : vm.loadingMessage)
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
        }
        .padding(DS.Space.xl)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).fill(theme.cardBackground))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
}

/// Type-erased button style so a single Button can switch styles.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

// MARK: - Institution picker

struct InstitutionPickerSheet: View {
    var initialFilter: SnapTradeAutoMode? = nil
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @ObservedObject private var vm = SnapTradeViewModel.shared
    @State private var query = ""

    struct Institution: Identifiable {
        let name: String
        let slug: String
        let region: String
        var isExchange = false
        /// SnapTrade's logo for it (live directory only).
        var logoURL: URL? = nil
        var inMaintenance = false
        var id: String { slug }
        var kindLabel: String { isExchange ? "Crypto exchange" : "Stock broker" }
    }

    /// Region for institutions we know (the live directory doesn't say).
    static func knownRegion(for name: String) -> String? {
        (brokers + exchanges).first { name.localizedCaseInsensitiveContains($0.name) || $0.name.localizedCaseInsensitiveContains(name) }?.region
    }

    /// Fallback when SnapTrade's live directory can't be loaded. Slugs are SnapTrade's own
    /// (checked against GET /brokerages on 2026-10-18 — "IBKR", "ALPACA", CoinSpot, CoinJar,
    /// Gemini and Binance US were never valid and failed with "Requested broker … does not exist").
    static let brokers: [Institution] = [
        .init(name: "CommSec", slug: "COMMSEC", region: "Australia"),
        .init(name: "Stake Australia", slug: "STAKEAUS", region: "Australia"),
        .init(name: "Interactive Brokers", slug: "INTERACTIVE-BROKERS-FLEX", region: "Global"),
        .init(name: "moomoo", slug: "MOOMOO", region: "Global"),
        .init(name: "eToro", slug: "ETORO", region: "Global"),
        .init(name: "Trading212", slug: "TRADING212", region: "Global"),
        .init(name: "Schwab", slug: "SCHWAB", region: "US"),
        .init(name: "Fidelity", slug: "FIDELITY", region: "US"),
        .init(name: "E*Trade", slug: "ETRADE", region: "US"),
        .init(name: "Robinhood", slug: "ROBINHOOD", region: "US"),
        .init(name: "Webull US", slug: "WEBULL", region: "US"),
        .init(name: "Public", slug: "PUBLIC", region: "US"),
        .init(name: "Vanguard US", slug: "VANGUARD", region: "US")
    ]

    static let exchanges: [Institution] = [
        .init(name: "Coinbase", slug: "COINBASE", region: "Global", isExchange: true),
        .init(name: "Kraken", slug: "KRAKEN", region: "Global", isExchange: true),
        .init(name: "Binance", slug: "BINANCE", region: "Global", isExchange: true)
    ]

    /// Test institutions (SnapTrade Sandbox, paper / practice accounts): DEBUG builds only.
    static func isTestInstitution(_ slug: String) -> Bool {
        slug == "SANDBOX" || slug.hasSuffix("-PAPER") || slug.hasSuffix("-PRACTICE")
    }

    /// What to offer: SnapTrade's live list when loaded, else the fallback.
    static func catalog(from directory: [Institution]) -> [Institution] {
        let base = directory.isEmpty ? brokers + exchanges : directory
        #if DEBUG
        return base
        #else
        return base.filter { !isTestInstitution($0.slug) }
        #endif
    }

    /// ASX is the home market (set in onboarding), or the iPhone is set to Australia.
    static var prefersAustralia: Bool {
        if let market = UserDefaults.standard.string(forKey: "preferredMarket"), market == "AU" { return true }
        return Locale.current.region?.identifier == "AU"
    }

    /// Local institutions first, then global, then the rest.
    private static func ordered(_ list: [Institution]) -> [Institution] {
        let home = prefersAustralia ? "Australia" : "US"
        func rank(_ i: Institution) -> Int { i.region == home ? 0 : (i.region == "Global" ? 1 : 2) }
        return list.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    private func filtered(_ list: [Institution]) -> [Institution] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let sorted = Self.ordered(list)
        guard !q.isEmpty else { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                let all = Self.catalog(from: vm.directory)
                let brokers = filtered(all.filter { !$0.isExchange })
                let exchanges = filtered(all.filter { $0.isExchange })
                if initialFilter != .crypto && !brokers.isEmpty {
                    Section("Stock brokers") { ForEach(brokers) { row($0) } }
                }
                if initialFilter != .broker && !exchanges.isEmpty {
                    Section("Crypto exchanges") { ForEach(exchanges) { row($0) } }
                }
                if brokers.isEmpty && exchanges.isEmpty {
                    Text("No match. Connections go through SnapTrade, which doesn't support that one yet — you can still add its holdings yourself.")
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryText)
                }
                Section {
                    Text("Connections are read-only and run through SnapTrade. You'll sign in on your broker's own page.")
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryText)
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .dsScreenBackground()
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search brokers and exchanges")
            .navigationTitle("Choose your broker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task { await vm.loadDirectory() }
        }
    }

    private func row(_ institution: Institution) -> some View {
        Button {
            Haptics.tap()
            dismiss()
            onSelect(institution.slug)
        } label: {
            HStack(spacing: DS.Space.m) {
                InstitutionTile(name: institution.name, size: 36, logoURL: institution.logoURL)
                VStack(alignment: .leading, spacing: 2) {
                    Text(institution.name).font(.body.weight(.semibold)).foregroundStyle(theme.primaryText)
                    if institution.inMaintenance {
                        Text("Down for maintenance — try again later").font(.caption).foregroundStyle(.orange)
                    } else {
                        Text(institution.region.isEmpty ? institution.kindLabel : institution.region)
                            .font(.caption).foregroundStyle(theme.secondaryText)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.secondaryText.opacity(0.6))
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(institution.inMaintenance)
        .accessibilityIdentifier("broker.pick.\(institution.slug)")
    }
}

/// A broker's tile: SnapTrade's logo for it when there is one, else a monogram.
struct InstitutionTile: View {
    let name: String
    var size: CGFloat = 36
    var logoURL: URL? = nil

    var body: some View {
        Group {
            if let logoURL {
                AsyncImage(url: logoURL) { phase in
                    if let image = phase.image {
                        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                            .fill(Color.white)
                            .overlay(image.resizable().scaledToFit().padding(size * 0.14))
                            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                                .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
                    } else {
                        monogram
                    }
                }
            } else {
                monogram
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var monogram: some View {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        return RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(TickerLogo.tint(for: name).gradient)
            .overlay(
                Text(letters.isEmpty ? "?" : letters)
                    .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            )
    }
}

// MARK: - Safari View

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        config.barCollapsingEnabled = true
        let safari = SFSafariViewController(url: url, configuration: config)
        safari.dismissButtonStyle = .close
        return safari
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
