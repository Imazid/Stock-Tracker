//
//  Stock_Tracker_WidgetLiveActivity.swift
//  Stock Tracker Widget
//
//  Live Activity for real-time stock price tracking on Lock Screen and Dynamic Island.
//

import ActivityKit
import WidgetKit
import SwiftUI

// MARK: - Attributes

struct StockLiveActivityAttributes: ActivityAttributes {
    let symbol: String
    let companyName: String

    struct ContentState: Codable, Hashable {
        var price: Double
        var change: Double
        var changePercent: Double
        var isMarketOpen: Bool
        var lastUpdated: Date

        var isPositive: Bool { changePercent >= 0 }
        var accentColor: String { isPositive ? "green" : "red" }
    }
}

// MARK: - Live Activity Widget

struct Stock_Tracker_WidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: StockLiveActivityAttributes.self) { context in

            // MARK: Lock Screen / Notification Banner
            lockScreenView(context: context)
                .activityBackgroundTint(Color(red: 0.05, green: 0.07, blue: 0.18))
                .activitySystemActionForegroundColor(.white)

        } dynamicIsland: { context in
            DynamicIsland {

                // MARK: Expanded
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.symbol)
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        Text(context.attributes.companyName)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    .padding(.leading, 4)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    let color: Color = context.state.isPositive ? .green : .red
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(context.state.price, format: .currency(code: "USD").precision(.fractionLength(2)))
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        HStack(spacing: 3) {
                            Image(systemName: context.state.isPositive ? "arrow.up.right" : "arrow.down.right")
                                .font(.system(size: 9, weight: .bold))
                            Text("\(context.state.isPositive ? "+" : "")\(String(format: "%.2f", context.state.changePercent))%")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .foregroundColor(color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(color.opacity(0.2))
                        .cornerRadius(6)
                    }
                    .padding(.trailing, 4)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Change")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.5))
                            let changeColor: Color = context.state.isPositive ? .green : .red
                            Text(context.state.change, format: .currency(code: "USD").sign(strategy: .always()))
                                .font(.caption.weight(.bold))
                                .foregroundColor(changeColor)
                        }

                        Spacer()

                        HStack(spacing: 4) {
                            Circle()
                                .fill(context.state.isMarketOpen ? Color.green : Color.red)
                                .frame(width: 6, height: 6)
                            Text(context.state.isMarketOpen ? "Market Open" : "Market Closed")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.6))
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 1) {
                            Text("Updated")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.5))
                            Text(context.state.lastUpdated, style: .relative)
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.6))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                }

            } compactLeading: {

                // MARK: Compact Leading
                HStack(spacing: 4) {
                    let color: Color = context.state.isPositive ? .green : .red
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color.opacity(0.25))
                        .frame(width: 28, height: 18)
                        .overlay(
                            Text(String(context.attributes.symbol.prefix(4)))
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(color)
                        )
                }

            } compactTrailing: {

                // MARK: Compact Trailing
                let color: Color = context.state.isPositive ? .green : .red
                HStack(spacing: 2) {
                    Image(systemName: context.state.isPositive ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 8, weight: .bold))
                    Text("\(context.state.isPositive ? "+" : "")\(String(format: "%.1f", context.state.changePercent))%")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundColor(color)

            } minimal: {

                // MARK: Minimal
                let color: Color = context.state.isPositive ? .green : .red
                Image(systemName: context.state.isPositive ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(color)
            }
            .widgetURL(URL(string: "stocktracker://stock/\(context.attributes.symbol)"))
            .keylineTint(context.state.isPositive ? .green : .red)
        }
    }

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<StockLiveActivityAttributes>) -> some View {
        let color: Color = context.state.isPositive ? .green : .red
        HStack(spacing: 16) {
            // Symbol badge
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(color.opacity(0.2))
                        .frame(width: 52, height: 52)
                    Text(String(context.attributes.symbol.prefix(4)))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(color)
                }
                HStack(spacing: 3) {
                    Circle()
                        .fill(context.state.isMarketOpen ? Color.green : Color.orange)
                        .frame(width: 5, height: 5)
                    Text(context.state.isMarketOpen ? "Open" : "Closed")
                        .font(.system(size: 8))
                        .foregroundColor(.white.opacity(0.6))
                }
            }

            // Price info
            VStack(alignment: .leading, spacing: 3) {
                Text(context.attributes.companyName)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
                Text(context.state.price, format: .currency(code: "USD").precision(.fractionLength(2)))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                HStack(spacing: 5) {
                    Image(systemName: context.state.isPositive ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 10, weight: .bold))
                    Text(context.state.change, format: .currency(code: "USD").sign(strategy: .always()).precision(.fractionLength(2)))
                        .font(.subheadline.weight(.semibold))
                    Text("(\(context.state.isPositive ? "+" : "")\(String(format: "%.2f", context.state.changePercent))%)")
                        .font(.subheadline)
                }
                .foregroundColor(color)
            }

            Spacer()

            // Time since update
            VStack(alignment: .trailing, spacing: 3) {
                Text("Updated")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.45))
                Text(context.state.lastUpdated, style: .relative)
                    .font(.caption2.weight(.medium))
                    .foregroundColor(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
