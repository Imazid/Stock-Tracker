//
//  OnboardingCompleteScreen.swift
//  Stock Tracker
//
//  OB-100: Animated checkmark, dynamic summary, auto-dismiss.
//

import SwiftUI

struct OnboardingCompleteScreen: View {
    let onFinish: () -> Void

    @EnvironmentObject var marketData: MarketData

    private var watchlistCount: Int { marketData.watchlist.count }
    private var portfolioCount: Int { marketData.portfolio.count }

    @State private var circleProgress: CGFloat = 0
    @State private var showCheckmark = false
    @State private var textOpacity: Double = 0
    @State private var autoDismissTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Animated checkmark circle
            ZStack {
                Circle()
                    .trim(from: 0, to: circleProgress)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 100, height: 100)
                    .rotationEffect(.degrees(-90))

                if showCheckmark {
                    Image(systemName: "checkmark")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundColor(.green)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .shadow(color: .green.opacity(0.35), radius: 20)

            Spacer().frame(height: 36)

            // Headline
            VStack(spacing: 16) {
                Text("You're all set")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                // Dynamic summary
                VStack(spacing: 8) {
                    if watchlistCount > 0 {
                        summaryRow(icon: "chart.line.uptrend.xyaxis", text: "\(watchlistCount) stocks on your watchlist")
                    }
                    if portfolioCount > 0 {
                        summaryRow(icon: "briefcase.fill", text: "\(portfolioCount) holdings tracked")
                    }
                    if watchlistCount == 0 && portfolioCount == 0 {
                        summaryRow(icon: "star.fill", text: "Watchlist ready — add stocks anytime")
                    }
                }
            }
            .opacity(textOpacity)

            Spacer()

            // Tap hint
            Text("Tap anywhere to continue")
                .font(.caption)
                .foregroundColor(.white.opacity(0.30))
                .opacity(textOpacity)
                .padding(.bottom, 40)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            autoDismissTask?.cancel()
            onFinish()
        }
        .onAppear { runAnimations() }
        .onDisappear { autoDismissTask?.cancel() }
    }

    @ViewBuilder
    private func summaryRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundColor(.green)
            Text(text)
                .font(.body)
                .foregroundColor(.white.opacity(0.70))
        }
    }

    private func runAnimations() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        // Circle draws
        withAnimation(.easeOut(duration: 0.5)) {
            circleProgress = 1
        }

        // Checkmark pops in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                showCheckmark = true
            }
        }

        // Text fades in
        withAnimation(.easeOut(duration: 0.4).delay(0.6)) {
            textOpacity = 1
        }

        // Auto-dismiss after 3s
        autoDismissTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await MainActor.run { onFinish() }
        }
    }
}
