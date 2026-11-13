//
//  ReferAndEarnView.swift
//  Stock Tracker
//
//  Refer a friend: your invite code, Share, how it works, and who joined —
//  after Cal AI / Ubank / TheFork on Mobbin (code field with copy, one big
//  Share, numbered "how it works"). Every load ends in something the screen can
//  show: the code, "sign in first", or "unavailable right now" with Retry.
//  It never shows a placeholder code or invented numbers.
//

import SwiftUI
import OSLog

struct ReferAndEarnView: View {

    @EnvironmentObject var referralManager: ReferralManager
    @EnvironmentObject private var supabaseAuthManager: SupabaseAuthManager
    @EnvironmentObject private var marketData: MarketData
    @EnvironmentObject private var alertManager: PriceAlertManager
    @Environment(\.theme) private var theme

    @State private var copied = false
    @State private var copiedLink = false
    @State private var showAccount = false

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Space.xl) {
                hero
                content
            }
            .padding(.horizontal, DS.Space.gutter)
            .padding(.top, DS.Space.s)
            .padding(.bottom, DS.Space.xxl)
        }
        .dsScreenBackground()
        .navigationTitle("Refer a friend")
        .navigationBarTitleDisplayMode(.inline)
        .task { await referralManager.refresh() }
        .refreshable { await referralManager.refresh() }
        .sheet(isPresented: $showAccount, onDismiss: {
            Task { await referralManager.refresh() }
        }) {
            AccountView()
                .environmentObject(supabaseAuthManager)
                .environmentObject(SyncManager.shared)
                .environmentObject(MFAManager.shared)
                .environmentObject(marketData)
                .environmentObject(alertManager)
        }
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: DS.Space.m) {
            Image(systemName: "gift.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(DS.accent)
                .frame(width: 72, height: 72)
                .background(Circle().fill(DS.accent.opacity(0.14)))
                .accessibilityHidden(true)
            Text("Invite friends to Stock Tracker")
                .font(DS.display(.title2, weight: .semibold))
                .foregroundStyle(theme.primaryText)
                .multilineTextAlignment(.center)
            Text("Share your code. When a friend signs up with it and adds their first holding, it counts as one of your referrals.")
                .font(.subheadline)
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, DS.Space.m)
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        switch referralManager.loadState {
        case .idle, .loading:
            HStack(spacing: DS.Space.m) {
                ProgressView()
                Text("Getting your invite code…")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
            }
            .frame(maxWidth: .infinity, minHeight: 96)
            .dsCard()
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("referrals.loading")

        case .unavailable:
            EmptyStateCard(
                systemImage: "icloud.slash",
                title: "Referrals are unavailable right now",
                message: "We can't reach Stock Tracker's account service, so invite codes can't be created or checked. Everything else in the app works as normal.",
                primaryTitle: "Try again",
                primaryAction: retry
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("referrals.unavailable")

        case .offline:
            EmptyStateCard(
                systemImage: "wifi.slash",
                title: "You're offline",
                message: "Connect to the internet to see your invite code.",
                primaryTitle: "Try again",
                primaryAction: retry
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("referrals.unavailable")

        case .failed:
            EmptyStateCard(
                systemImage: "exclamationmark.triangle",
                title: "Your invite code didn't load",
                message: "Something went wrong on our side. Try again in a moment.",
                primaryTitle: "Try again",
                primaryAction: retry
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("referrals.unavailable")

        case .signedOut:
            EmptyStateCard(
                systemImage: "person.crop.circle.badge.plus",
                title: "Sign in to invite friends",
                message: "Your invite code belongs to your account, so we can tell when a friend joins with it.",
                primaryTitle: "Sign in",
                primaryAction: { showAccount = true }
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("referrals.signin")

        case .ready:
            if let code = referralManager.myCode?.code {
                codeCard(code)
                howItWorksCard
                statsCard(referralManager.stats)
                if let referrals = referralManager.stats?.referrals, !referrals.isEmpty {
                    activityCard(referrals)
                }
            }
        }
    }

    private func retry() {
        Task { await referralManager.refresh() }
    }

    // MARK: - Code

    private func codeCard(_ code: String) -> some View {
        VStack(spacing: DS.Space.l) {
            HStack(spacing: DS.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your invite code")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(theme.secondaryText)
                    Text(code)
                        .font(.system(size: 26, weight: .bold, design: .monospaced))
                        .kerning(2)
                        .foregroundStyle(theme.primaryText)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("referrals.code")
                }
                Spacer(minLength: DS.Space.s)
                Button {
                    UIPasteboard.general.string = code
                    Haptics.success()
                    flash($copied)
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                        .padding(.horizontal, DS.Space.m)
                        .frame(minHeight: 44)
                        .background(Capsule().fill(theme.background.opacity(0.7)))
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel(copied ? "Code copied" : "Copy code")
                .accessibilityIdentifier("referrals.copy")
            }
            .padding(DS.Space.l)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                    .strokeBorder(theme.cardBorder, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            )

            ShareLink(item: referralManager.shareText) {
                Label("Share invite", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(PrimaryPillButtonStyle())
            .accessibilityIdentifier("referrals.share")

            if let url = referralManager.shareURL {
                Button {
                    UIPasteboard.general.string = url.absoluteString
                    Haptics.success()
                    flash($copiedLink)
                } label: {
                    Label(copiedLink ? "Link copied" : "Copy invite link", systemImage: copiedLink ? "checkmark" : "link")
                }
                .buttonStyle(SecondaryPillButtonStyle())
            }
        }
        .dsCard()
    }

    private func flash(_ flag: Binding<Bool>) {
        dsAnimate(DS.quick) { flag.wrappedValue = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            dsAnimate(DS.quick) { flag.wrappedValue = false }
        }
    }

    // MARK: - How it works

    private var howItWorksCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("How it works")
                .font(.headline)
                .foregroundStyle(theme.primaryText)
                .padding(.bottom, DS.Space.l)
            step(1, title: "Share your code", detail: "Send it by message, email or anywhere you like.", last: false)
            step(2, title: "They create an account", detail: "Your friend enters the code when they sign up.", last: false)
            step(3, title: "They add a holding", detail: "Once they set up a portfolio with their first holding, the referral counts.", last: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    private func step(_ number: Int, title: LocalizedStringKey, detail: LocalizedStringKey, last: Bool) -> some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            VStack(spacing: 0) {
                Text("\(number)")
                    .font(.footnote.weight(.bold).monospacedDigit())
                    .foregroundStyle(DS.accent)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(DS.accent.opacity(0.14)))
                if !last {
                    Rectangle()
                        .fill(theme.cardBorder)
                        .frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, 4)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, last ? 0 : DS.Space.l)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Stats

    private func statsCard(_ stats: ReferralStats?) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text("Your referrals")
                .font(.headline)
                .foregroundStyle(theme.primaryText)
            if let stats {
                HStack(spacing: 0) {
                    statItem(stats.totalReferred, "Joined")
                    Divider().frame(height: 32)
                    statItem(stats.pendingCount, "In progress")
                    Divider().frame(height: 32)
                    statItem(stats.qualifiedCount + stats.rewardedCount, "Counted")
                }
                if stats.totalReferred == 0 {
                    Text("No one has joined with your code yet.")
                        .font(.footnote)
                        .foregroundStyle(theme.secondaryText)
                }
            } else {
                Text("Your referral numbers couldn't be loaded. Pull down to try again.")
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
        .accessibilityIdentifier("referrals.stats")
    }

    private func statItem(_ value: Int, _ label: LocalizedStringKey) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(DS.money(24, weight: .semibold))
                .foregroundStyle(theme.primaryText)
            Text(label)
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Activity

    private func activityCard(_ referrals: [Referral]) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text("Activity")
                .font(.headline)
                .foregroundStyle(theme.primaryText)
            ForEach(referrals) { referral in
                referralRow(referral)
                if referral.id != referrals.last?.id { Divider() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    private func referralRow(_ referral: Referral) -> some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: "person.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 36, height: 36)
                .background(Circle().fill(theme.background.opacity(0.7)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Friend · joined \(referral.createdAt.formatted(.dateTime.day().month()))")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(theme.primaryText)
                Text(progressText(referral))
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: DS.Space.s)
            Text(statusLabel(referral.status))
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusColor(referral.status))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(statusColor(referral.status).opacity(0.12)))
        }
        .accessibilityElement(children: .combine)
    }

    private func progressText(_ referral: Referral) -> String {
        if referral.firstHoldingAt != nil { return "Added their first holding" }
        if referral.portfolioCreatedAt != nil { return "Set up a portfolio · no holdings yet" }
        if referral.signedUpAt != nil { return "Signed up · no portfolio yet" }
        return "Invited"
    }

    private func statusLabel(_ status: ReferralStatus) -> String {
        switch status {
        case .pending: return "In progress"
        case .qualified, .rewarded: return "Counted"
        case .expired: return "Expired"
        case .blocked: return "Not eligible"
        }
    }

    private func statusColor(_ status: ReferralStatus) -> Color {
        switch status {
        case .pending: return theme.warningColor
        case .qualified, .rewarded: return theme.positiveColor
        case .expired, .blocked: return theme.secondaryText
        }
    }
}
