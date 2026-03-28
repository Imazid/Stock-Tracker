//
//  EventCalendarWidget.swift
//  Stock Tracker Widget
//
//  Earnings/dividend/split calendar widget.
//  Families: systemSmall, systemMedium, accessoryRectangular
//  Premium gating: Free = 1 event, Pro/Black = full calendar
//  Tap target: stocktracker://calendar
//

import WidgetKit
import SwiftUI

// MARK: - Entry

struct EventCalendarEntry: TimelineEntry {
    let date: Date
    let data: WidgetCalendarData
    let isPremium: Bool
}

// MARK: - Provider

struct EventCalendarProvider: TimelineProvider {
    func placeholder(in context: Context) -> EventCalendarEntry {
        EventCalendarEntry(date: Date(), data: .placeholder, isPremium: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (EventCalendarEntry) -> Void) {
        let data = context.isPreview ? WidgetCalendarData.placeholder : (WidgetCalendarData.read() ?? .placeholder)
        let premium = WidgetPremiumData.read()?.isPremium ?? false
        completion(EventCalendarEntry(date: Date(), data: data, isPremium: context.isPreview ? true : premium))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<EventCalendarEntry>) -> Void) {
        let data = WidgetCalendarData.read() ?? .placeholder
        let premium = WidgetPremiumData.read()?.isPremium ?? false
        let entry = EventCalendarEntry(date: Date(), data: data, isPremium: premium)
        let next = Calendar.current.date(byAdding: .minute, value: 60, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - Entry View

struct EventCalendarEntryView: View {
    let entry: EventCalendarEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemMedium:         EventCalendarMediumView(entry: entry)
        case .accessoryRectangular: EventCalendarAccessoryRectangular(entry: entry)
        default:                    EventCalendarSmallView(entry: entry)
        }
    }
}

// MARK: - Small (next event card)

struct EventCalendarSmallView: View {
    let entry: EventCalendarEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetHeaderRow(icon: "calendar", title: "Events")

            Spacer()

            if let event = entry.data.events.first {
                let ec = event.eventColor
                let color = Color(red: ec.r, green: ec.g, blue: ec.b)

                // Date display
                VStack(spacing: 0) {
                    Text(event.date, format: .dateTime.day())
                        .font(WidgetFont.displaySmall(.bold))
                        .foregroundColor(WidgetColor.textPrimary)
                    Text(event.date, format: .dateTime.month(.abbreviated))
                        .font(WidgetFont.microSmall(.semibold))
                        .foregroundColor(WidgetColor.textSecondary)
                }

                HStack(spacing: 4) {
                    Image(systemName: event.eventIcon)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(color)
                    Text(event.symbol)
                        .font(WidgetFont.microLarge(.bold))
                        .foregroundColor(WidgetColor.textPrimary)
                }

                Text(event.eventType.capitalized)
                    .font(WidgetFont.microTiny(.semibold))
                    .foregroundColor(color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Text("No Events")
                    .font(WidgetFont.secondaryMedium(.semibold))
                    .foregroundColor(WidgetColor.textTertiary)
                MicroLabel(text: "Check back later")
            }
        }
        .padding(WidgetSpacing.paddingSmall)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(WidgetDeepLink.calendar)
        .widgetContainerBG()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Next event: \(entry.data.events.first?.symbol ?? "none")")
    }
}

// MARK: - Medium (next 3 events)

struct EventCalendarMediumView: View {
    let entry: EventCalendarEntry

    private var visibleEvents: [WidgetCalendarEvent] {
        let events = entry.data.events
        return entry.isPremium ? Array(events.prefix(3)) : Array(events.prefix(1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetSpacing.rowGapCompact) {
            WidgetHeaderRow(
                icon: "calendar", title: "Upcoming Events",
                trailing: "\(entry.data.events.count)", trailingColor: WidgetColor.textSecondary
            )

            if visibleEvents.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Image(systemName: "calendar.badge.exclamationmark")
                            .font(.title2)
                            .foregroundColor(WidgetColor.textTertiary)
                        Text("No upcoming events")
                            .font(WidgetFont.microLarge())
                            .foregroundColor(WidgetColor.textTertiary)
                    }
                    Spacer()
                }
                Spacer()
            } else {
                ForEach(visibleEvents) { event in
                    eventRow(event)
                }

                if !entry.isPremium && entry.data.events.count > 1 {
                    HStack(spacing: 4) {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 9))
                            .foregroundColor(WidgetColor.premium)
                        Text("Upgrade for full calendar")
                            .font(WidgetFont.microTiny(.semibold))
                            .foregroundColor(WidgetColor.premium)
                    }
                }
            }
        }
        .padding(WidgetSpacing.paddingMedium)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(entry.isPremium ? WidgetDeepLink.calendar : WidgetDeepLink.paywall)
        .widgetContainerBG()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Events calendar, \(entry.data.events.count) upcoming")
    }

    private func eventRow(_ event: WidgetCalendarEvent) -> some View {
        let ec = event.eventColor
        let color = Color(red: ec.r, green: ec.g, blue: ec.b)

        return HStack(spacing: 10) {
            // Date column
            VStack(spacing: 0) {
                Text(event.date, format: .dateTime.day())
                    .font(WidgetFont.secondaryMedium(.bold))
                    .foregroundColor(WidgetColor.textPrimary)
                Text(event.date, format: .dateTime.month(.abbreviated))
                    .font(WidgetFont.microTiny(.semibold))
                    .foregroundColor(WidgetColor.textSecondary)
            }
            .frame(width: 32)

            Rectangle().fill(color).frame(width: 2, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 1))

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(event.symbol)
                        .font(WidgetFont.microLarge(.bold))
                        .foregroundColor(WidgetColor.textPrimary)
                    Text(event.eventType.capitalized)
                        .font(WidgetFont.microTiny(.semibold))
                        .foregroundColor(color)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(color.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                if let detail = event.detail {
                    MicroLabel(text: detail)
                }
            }

            Spacer()

            Image(systemName: event.eventIcon)
                .font(.system(size: 14))
                .foregroundColor(color.opacity(0.6))
        }
        .padding(6)
        .glassCard()
    }
}

// MARK: - Lock Screen: Accessory Rectangular

struct EventCalendarAccessoryRectangular: View {
    let entry: EventCalendarEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let event = entry.data.events.first {
                HStack(spacing: 4) {
                    Image(systemName: event.eventIcon)
                        .font(.caption2.weight(.bold))
                        .widgetAccentable()
                    Text(event.symbol)
                        .font(.caption2.weight(.bold))
                }
                Text(event.date, format: .dateTime.month().day())
                    .font(.caption.weight(.semibold))
                Text(event.eventType.capitalized)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                Text("No Events")
                    .font(.caption.weight(.semibold))
                Text("Check back later")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .widgetURL(WidgetDeepLink.calendar)
        .containerBackground(.clear, for: .widget)
    }
}

// MARK: - Widget Declaration

struct EventCalendarWidget: Widget {
    let kind: String = "EventCalendarWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: EventCalendarProvider()) { entry in
            EventCalendarEntryView(entry: entry)
        }
        .configurationDisplayName("Event Calendar")
        .description("Upcoming earnings, dividends, and splits.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}
