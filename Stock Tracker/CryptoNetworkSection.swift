import SwiftUI

struct CryptoNetworkSection: View {
    let coin: CoinFacts?
    let state: AssetDetailViewModel.LoadState
    let retry: () async -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        DetailSection(title: "Network information", identifier: "detail.crypto.network") {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                if let coin {
                    Link("Data powered by CoinGecko", destination: coin.sourceURL)
                        .font(.footnote)
                        .foregroundStyle(DS.accent)
                        .accessibilityIdentifier("detail.crypto.source")
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        marketTimestamp(coin.marketDate, now: context.date)
                    }
                    Text("Traded value covers exchanges tracked by CoinGecko. Execution liquidity depends on the venue and order size.")
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryText)
                    if let launchedOn = coin.launchedOn {
                        LedgerRow(label: "Launch date", value: launchedOn)
                    }
                    if !coin.platforms.isEmpty {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: DS.Space.m) {
                                ForEach(coin.platforms) { platform in
                                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                                        Text(platform.name).font(.subheadline.weight(.semibold))
                                        Text(platform.contract)
                                            .font(.caption.monospaced())
                                            .textSelection(.enabled)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .accessibilityElement(children: .combine)
                                    .accessibilityIdentifier("detail.crypto.platform.\(platform.id)")
                                }
                            }
                            .padding(.top, DS.Space.m)
                        } label: {
                            Text("Token contracts by network")
                                .frame(minHeight: 44, alignment: .leading)
                        }
                        .accessibilityIdentifier("detail.crypto.platforms")
                    }
                    ForEach(coin.explorers, id: \.self) { url in
                        Link(destination: url) {
                            Label("Explorer on \(url.host() ?? url.absoluteString)", systemImage: "arrow.up.right")
                                .multilineTextAlignment(.leading)
                                .frame(minHeight: 44, alignment: .leading)
                        }
                        .foregroundStyle(DS.accent)
                    }
                    if coin.launchedOn == nil && coin.platforms.isEmpty && coin.explorers.isEmpty {
                        Text("Network details are unavailable.").foregroundStyle(theme.secondaryText)
                    }
                }
                if state == .failed {
                    Text(coin == nil ? "CoinGecko token research is temporarily unavailable." : "Refresh failed. Showing the last available research.")
                        .foregroundStyle(theme.secondaryText)
                    Button("Retry token research") { Task { await retry() } }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("detail.crypto.retry")
                } else if coin == nil {
                    if state == .loading {
                        ProgressView("Loading token research")
                    } else {
                        Text("Research is unavailable for this token.").foregroundStyle(theme.secondaryText)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsCard()
        }
    }

    private func marketTimestamp(_ date: Date?, now: Date) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if let date {
                Text("Market data as of \(date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().timeZone()))")
                if now.timeIntervalSince(date) > 15 * 60 {
                    Text("Stale market data").fontWeight(.semibold)
                }
            } else {
                Text("Market timestamp unavailable")
            }
        }
        .font(.footnote)
        .foregroundStyle(theme.secondaryText)
        .accessibilityIdentifier("detail.crypto.timestamp")
    }
}
