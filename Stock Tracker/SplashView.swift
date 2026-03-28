//
//  SplashView.swift
//  Stock Tracker
//

import SwiftUI

struct SplashView: View {
    @Environment(\.colorScheme) var colorScheme
    @State private var symbolOpacity: Double = 0
    @State private var textOpacity: Double = 0

    var body: some View {
        let theme = Theme(colorScheme: colorScheme)
        ZStack {
            theme.background
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Spacer()

                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 48, weight: .thin))
                    .foregroundColor(theme.primaryText)
                    .opacity(symbolOpacity)
                    .accessibilityHidden(true)

                Text("Stock Tracker")
                    .font(.title.weight(.semibold))
                    .foregroundColor(theme.primaryText)
                    .opacity(textOpacity)

                Spacer()
                Spacer()
            }
        }
        .onAppear {
            if UIAccessibility.isReduceMotionEnabled {
                symbolOpacity = 1
                textOpacity = 1
            } else {
                withAnimation(.easeIn(duration: 0.6)) {
                    symbolOpacity = 1
                }
                withAnimation(.easeIn(duration: 0.6).delay(0.2)) {
                    textOpacity = 1
                }
            }
        }
    }
}

#Preview {
    SplashView()
}
