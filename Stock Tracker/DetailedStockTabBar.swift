//
//  DetailedStockTabBar.swift
//  Stock Tracker
//
//  Horizontally scrolling tab bar with an animated underline indicator.
//  Used in AppleStocksDetailView to switch between insight sections.
//

import SwiftUI

// MARK: - Tab Enum

enum DetailedStockTab: String, CaseIterable {
    case overview   = "Overview"
    case financials = "Financials"
    case earnings   = "Earnings"
    case holders    = "Holders"
    case analysis   = "Analysis"
}

// MARK: - Tab Bar View

struct DetailedStockTabBar: View {
    @Binding var selectedTab: DetailedStockTab
    @Namespace private var ns
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(DetailedStockTab.allCases, id: \.self) { tab in
                    tabButton(tab)
                }
            }
            .padding(.horizontal, 16)
        }
        .background(colorScheme == .dark ? Color(red: 0.03, green: 0.03, blue: 0.03) : Color(red: 0.98, green: 0.97, blue: 0.96))
    }

    @ViewBuilder
    private func tabButton(_ tab: DetailedStockTab) -> some View {
        let isSelected = selectedTab == tab

        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 0) {
                Text(tab.rawValue)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .primary : .secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)

                // Animated underline
                if isSelected {
                    Rectangle()
                        .fill(Color.primary)
                        .frame(height: 2)
                        .matchedGeometryEffect(id: "tabUnderline", in: ns)
                } else {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(height: 2)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
