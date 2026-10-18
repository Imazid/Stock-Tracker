//
//  OnboardingIntroSteps.swift
//  Stock Tracker
//
//  Welcome → Markets → Follow.
//

import SwiftUI

// MARK: - Welcome

struct OnboardingWelcomeStep: View {
    @EnvironmentObject private var viewModel: OnboardingViewModel
    @Environment(\.onboardingFinish) private var finish
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showSignIn = false

    var body: some View {
        VStack(spacing: 0) {
            LogoField()
                // At accessibility text sizes the words need the room (bullets truncated).
                .frame(height: typeSize.isAccessibilitySize ? 150 : 300)
                .mask(
                    LinearGradient(
                        stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.25),
                                .init(color: .black, location: 0.7), .init(color: .clear, location: 1)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .accessibilityHidden(true)

            ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white))
                    Text("Stock Tracker")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .accessibilityElement(children: .combine)

                Text("All your markets.\nOne calm place.")
                    .font(DS.display(.largeTitle))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                VStack(alignment: .leading, spacing: DS.Space.m) {
                    WelcomeBullet(icon: "waveform.path.ecg", text: "Live ASX, US and crypto prices")
                    WelcomeBullet(icon: "briefcase", text: "Every broker in one portfolio")
                    WelcomeBullet(icon: "bell.badge", text: "Alerts only when it matters")
                }
            }
            .padding(.horizontal, DS.Space.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)

            Spacer(minLength: DS.Space.l)

            VStack(spacing: DS.Space.xs) {
                Button("Get started") {
                    Haptics.tap()
                    viewModel.next()
                }
                .buttonStyle(PrimaryPillButtonStyle())
                .accessibilityIdentifier("onboarding.getStarted")

                Button("I already have an account") {
                    Haptics.tap()
                    showSignIn = true
                }
                .buttonStyle(QuietTextButtonStyle(onDark: true))

                Text("General information only — not financial advice.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, DS.Space.xs)
            }
            .padding(.horizontal, DS.Space.gutter)
            .padding(.bottom, DS.Space.s)
        }
        .sheet(isPresented: $showSignIn) {
            OnboardingSignInSheet(onSignedIn: {
                showSignIn = false
                viewModel.accountLabel = "Signed in"
                finish()
            })
            .presentationDetents([.large])
            .presentationCornerRadius(DS.Radius.sheet)
        }
    }
}

private struct WelcomeBullet: View {
    let icon: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.10)))
                .accessibilityHidden(true)
            Text(text)
                .font(.body)
                .foregroundStyle(.white.opacity(0.86))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Three rows of real logos drifting at different speeds — ASX and Wall St side by side.
private struct LogoField: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let rows: [[PickedAsset]] = {
        let a = OnboardingCatalog.asx, u = OnboardingCatalog.us, c = OnboardingCatalog.crypto, e = OnboardingCatalog.etfs
        return [
            [u[0], a[0], u[1], a[1], u[2], c[0], a[2], u[6]],
            [u[3], a[7], c[1], u[4], a[6], u[5], c[2], a[3]],
            [u[9], a[11], u[10], a[12], u[11], e[0], u[8], a[8]]
        ]
    }()

    private let logo: CGFloat = 58
    private let gap: CGFloat = 16

    var body: some View {
        // GeometryReader pins the width so the (very wide) rows can't stretch the page.
        GeometryReader { proxy in
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            VStack(spacing: gap) {
                ForEach(Array(Self.rows.enumerated()), id: \.offset) { index, row in
                    let rowWidth = CGFloat(row.count) * (logo + gap)
                    let speed = [14.0, 9.0, 12.0][index]
                    let direction: CGFloat = index.isMultiple(of: 2) ? -1 : 1
                    let travel = reduceMotion ? 0 : CGFloat((t * speed).truncatingRemainder(dividingBy: Double(rowWidth)))
                    HStack(spacing: gap) {
                        ForEach(0..<2, id: \.self) { _ in
                            ForEach(row) { asset in
                                TickerLogo(symbol: asset.symbol, kind: asset.kind, exchange: asset.exchange, size: logo)
                            }
                        }
                    }
                    .fixedSize()
                    .offset(x: direction * travel - (direction > 0 ? rowWidth : 0))
                    .frame(width: proxy.size.width, alignment: .leading)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        }
        .clipped()
    }
}

// MARK: - Markets

struct OnboardingMarketsStep: View {
    @EnvironmentObject private var viewModel: OnboardingViewModel

    var body: some View {
        OnboardingPage(
            title: "What do you want to track?",
            subtitle: "We'll tailor prices, market hours and suggestions. Choose as many as you like."
        ) {
            VStack(spacing: DS.Space.m) {
                ForEach(MarketChoice.allCases) { market in
                    OnboardingChoiceRow(
                        title: market.title,
                        subtitle: market.subtitle,
                        isSelected: viewModel.markets.contains(market)
                    ) {
                        Text(market.badge).font(.system(size: 22))
                    } action: {
                        Haptics.select()
                        dsAnimate(DS.quick) {
                            if viewModel.markets.contains(market) {
                                viewModel.markets.remove(market)
                            } else {
                                viewModel.markets.insert(market)
                            }
                        }
                    }
                    .accessibilityIdentifier("onboarding.market.\(market.rawValue)")
                }
            }

            VStack(alignment: .leading, spacing: DS.Space.m) {
                Text("Show values in")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                CurrencyToggle(selection: $viewModel.currency)
            }
        } footer: {
            Button("Continue") {
                Haptics.tap()
                viewModel.next()
            }
            .buttonStyle(PrimaryPillButtonStyle())
            .disabled(viewModel.markets.isEmpty)
            .accessibilityIdentifier("onboarding.continue")
        }
    }
}

private struct CurrencyToggle: View {
    @Binding var selection: String
    private let options: [(code: String, label: LocalizedStringKey)] = [("AUD", "A$ AUD"), ("USD", "US$ USD")]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.code) { option in
                let isOn = selection == option.code
                Button {
                    Haptics.select()
                    dsAnimate(DS.quick) { selection = option.code }
                } label: {
                    Text(option.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isOn ? .black : .white.opacity(0.8))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Capsule().fill(isOn ? Color.white : Color.clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }
}

// MARK: - Follow (stock picker)

struct OnboardingFollowStep: View {
    @EnvironmentObject private var viewModel: OnboardingViewModel

    @State private var category: PickerCategory = .popular
    @State private var query = ""
    @State private var searchState: SearchState = .idle
    @FocusState private var searchFocused: Bool

    enum PickerCategory: String, Identifiable {
        case popular, asx, us, etfs, crypto
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .popular: return "Popular"
            case .asx:     return "ASX"
            case .us:      return "US"
            case .etfs:    return "ETFs"
            case .crypto:  return "Crypto"
            }
        }
    }

    enum SearchState: Equatable {
        case idle, loading, results([PickedAsset]), empty, failed
    }

    private var categories: [PickerCategory] {
        var out: [PickerCategory] = [.popular]
        if viewModel.markets.contains(.asx) { out.append(.asx) }
        if viewModel.markets.contains(.us) { out.append(.us) }
        if viewModel.markets.contains(.asx) || viewModel.markets.contains(.us) { out.append(.etfs) }
        if viewModel.markets.contains(.crypto) { out.append(.crypto) }
        return out
    }

    private var listed: [PickedAsset] {
        let m = viewModel.markets
        switch category {
        case .popular:
            var lists: [[PickedAsset]] = []
            if m.contains(.asx) { lists.append(Array(OnboardingCatalog.asx.prefix(6))) }
            if m.contains(.us) || m.isEmpty { lists.append(Array(OnboardingCatalog.us.prefix(6))) }
            if m.contains(.crypto) { lists.append(Array(OnboardingCatalog.crypto.prefix(3))) }
            // Interleave so every chosen market shows up near the top.
            var out: [PickedAsset] = []
            for i in 0..<(lists.map(\.count).max() ?? 0) {
                for list in lists where i < list.count { out.append(list[i]) }
            }
            return out
        case .asx:    return OnboardingCatalog.asx
        case .us:     return OnboardingCatalog.us
        case .crypto: return OnboardingCatalog.crypto
        case .etfs:
            return OnboardingCatalog.etfs.filter {
                ($0.exchange == "ASX" && m.contains(.asx)) || ($0.exchange == "US" && m.contains(.us))
            }
        }
    }

    var body: some View {
        OnboardingPage(
            title: "Pick a few to follow",
            subtitle: "They'll go on your watchlist with live prices. You can change this any time."
        ) {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                searchField

                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    categoryChips
                    assetList(listed)
                } else {
                    searchResults
                }
            }
        } footer: {
            // While typing, give results the room; the footer returns with the keyboard down.
            if !searchFocused {
            if viewModel.hitWatchlistLimit, let limit = viewModel.watchlistLimit {
                InlineNote(icon: "info.circle", text: "The free plan follows up to \(limit). Remove one to swap, or upgrade any time in Settings.")
                    .transition(.opacity)
            }
            if !viewModel.picks.isEmpty {
                PickedSummary(picks: viewModel.picks)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Button(viewModel.picks.isEmpty ? "Continue" : "Continue with \(viewModel.picks.count)") {
                Haptics.tap()
                searchFocused = false
                viewModel.next()
            }
            .buttonStyle(PrimaryPillButtonStyle())
            .disabled(viewModel.picks.isEmpty)
            .accessibilityIdentifier("onboarding.continue")

            if viewModel.picks.isEmpty {
                Button("Skip for now") {
                    searchFocused = false
                    viewModel.next()
                }
                .buttonStyle(QuietTextButtonStyle(onDark: true))
            }
            }
        }
        .task(id: query) { await runSearch() }
    }

    // MARK: Pieces

    private var searchField: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.5))
            TextField("", text: $query, prompt: Text("Search any company or coin").foregroundStyle(.white.opacity(0.4)))
                .foregroundStyle(.white)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
                .accessibilityIdentifier("onboarding.search")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, DS.Space.m)
        .frame(minHeight: 48)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.08)))
    }

    private var categoryChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: DS.Space.s) {
                ForEach(categories) { cat in
                    let isOn = cat == category
                    Button {
                        Haptics.select()
                        dsAnimate(DS.quick) { category = cat }
                    } label: {
                        Text(cat.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isOn ? .black : .white.opacity(0.85))
                            .padding(.horizontal, DS.Space.l)
                            .frame(minHeight: 36)
                            .background(Capsule().fill(isOn ? Color.white : Color.white.opacity(0.08)))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
        .onChange(of: viewModel.markets) { _, _ in
            if !categories.contains(category) { category = .popular }
        }
    }

    private func assetList(_ assets: [PickedAsset]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(assets) { asset in
                PickRow(asset: asset, isPicked: viewModel.isPicked(asset)) {
                    viewModel.toggle(asset)
                }
                if asset != assets.last {
                    Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 56)
                }
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        switch searchState {
        case .idle, .loading:
            HStack(spacing: DS.Space.m) {
                ProgressView().tint(.white)
                Text("Searching…").foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, minHeight: 80)
        case .results(let assets):
            assetList(assets)
        case .empty:
            InlineNote(icon: "magnifyingglass", text: "No matches for “\(query)”. Try a ticker like CBA or AAPL.")
        case .failed:
            InlineNote(icon: "wifi.exclamationmark", text: "Search isn't available right now. Pick from the list, or try again in a moment.")
        }
    }

    // MARK: Search

    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { searchState = .idle; return }
        searchState = .loading
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }

        // Curated matches first — instant and offline-friendly. They're shown right away;
        // live results join when (if) they arrive. (They used to wait for the live search,
        // so a slow or rate-limited Yahoo left "Searching…" up even for Telstra.)
        let all = OnboardingCatalog.asx + OnboardingCatalog.us + OnboardingCatalog.etfs + OnboardingCatalog.crypto
        let needle = trimmed.lowercased()
        var found = all.filter { $0.symbol.lowercased().hasPrefix(needle) || $0.name.lowercased().contains(needle) }
        if !found.isEmpty { searchState = .results(ranked(found, query: trimmed)) }

        var failed = false
        // A deadline, so every search ends in results, "no matches" or "not available".
        if let stocks = await SymbolSearchModel.withDeadline(seconds: 10, {
            try? await APIService.shared.fetchSymbolSearch(query: trimmed, kind: .stock)
        }) {
            found += stocks.prefix(15).compactMap { result in
                let isASX = result.exchange.contains("ASX") || result.exchange.contains("Australian") || result.id.hasSuffix(".AX")
                // Quotes work for US and ASX listings only — skip other exchanges
                // rather than mislabel them as US.
                // (Yahoo puts the exchange name in `region`, Alpha Vantage the country,
                // so currency is the consistent signal.)
                let isUS = !isASX && result.currency == "USD" && !result.symbol.contains(".")
                guard isASX || isUS else { return nil }
                let symbol = result.symbol.replacingOccurrences(of: ".AX", with: "")
                return PickedAsset(symbol: symbol, name: result.name, kind: .stock, exchange: isASX ? "ASX" : "US")
            }
        } else {
            failed = true
        }
        if viewModel.markets.contains(.crypto) {
            if let coins = await SymbolSearchModel.withDeadline(seconds: 8, {
                try? await APIService.shared.fetchSymbolSearch(query: trimmed, kind: .crypto)
            }) {
                found += coins.prefix(6).map {
                    PickedAsset(symbol: $0.symbol.uppercased(), name: $0.name, kind: .crypto, exchange: "", coinID: $0.id)
                }
            }
        }
        guard !Task.isCancelled else { return }

        let unique = ranked(found, query: trimmed)
        if !unique.isEmpty {
            searchState = .results(unique)
        } else {
            searchState = failed ? .failed : .empty
        }
    }

    /// De-duplicated by listing and by company name ("Shopify Inc." vs "SHOPIFY INC"), then
    /// ordered like the app's main search (exact ticker, ticker prefix, name…).
    private func ranked(_ found: [PickedAsset], query: String) -> [PickedAsset] {
        var seen = Set<String>()
        let deduped = found.filter { asset in
            let nameKey = asset.kind.rawValue + asset.exchange
                + asset.name.lowercased().filter { $0.isLetter || $0.isNumber }
            return seen.insert(asset.id).inserted && seen.insert(nameKey).inserted
        }
        return deduped.enumerated()
            .sorted { a, b in
                let sa = SymbolRanking.score(SymbolHit(picked: a.element), query: query)
                let sb = SymbolRanking.score(SymbolHit(picked: b.element), query: query)
                return (sa, a.offset) < (sb, b.offset)
            }
            .map(\.element)
    }
}

private struct PickRow: View {
    let asset: PickedAsset
    let isPicked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.m) {
                TickerLogo(symbol: asset.symbol, kind: asset.kind, exchange: asset.exchange, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(asset.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(asset.symbol) · \(asset.marketLabel)")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: DS.Space.s)
                HStack(spacing: 4) {
                    if isPicked { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
                    Text(isPicked ? "Added" : "Add")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isPicked ? .black : .white)
                .padding(.horizontal, DS.Space.m)
                .frame(minWidth: 72, minHeight: 34)
                .background(Capsule().fill(isPicked ? Color.white : Color.white.opacity(0.10)))
            }
            .padding(.vertical, DS.Space.s + 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle(scale: 0.99))
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(asset.name), \(asset.symbol)")
        .accessibilityValue(isPicked ? "Added" : "Not added")
        .accessibilityHint(isPicked ? "Double-tap to remove" : "Double-tap to add to your watchlist")
        .accessibilityIdentifier("onboarding.pick.\(asset.symbol)")
    }
}

/// Overlapping logos of what's been picked, above the Continue button.
private struct PickedSummary: View {
    let picks: [PickedAsset]

    var body: some View {
        HStack(spacing: DS.Space.m) {
            HStack(spacing: -10) {
                ForEach(picks.suffix(5)) { pick in
                    TickerLogo(symbol: pick.symbol, kind: pick.kind, exchange: pick.exchange, size: 28)
                        .overlay(Circle().strokeBorder(Color.black, lineWidth: 2))
                }
            }
            Text(picks.count == 1 ? "1 on your watchlist" : "\(picks.count) on your watchlist")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.75))
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}

struct InlineNote: View {
    let icon: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Image(systemName: icon)
                .foregroundStyle(.white.opacity(0.6))
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}
