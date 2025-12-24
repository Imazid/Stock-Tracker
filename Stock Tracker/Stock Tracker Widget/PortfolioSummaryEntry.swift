//
//  PortfolioSummaryEntry.swift
//  Stock Tracker
//
//  Created by Ihtisham Mazid on 11/12/2025.
//


// PortfolioSummaryWidget.swift
import WidgetKit
import SwiftUI
import Charts

struct PortfolioSummaryEntry: TimelineEntry {
    let date: Date
    let value: Double
    let change: Double
    let changePercent: Double
    let isPositive: Bool
}

struct PortfolioSummaryProvider: TimelineProvider {
    func placeholder(in context: Context) -> PortfolioSummaryEntry {
        PortfolioSummaryEntry(date: Date(), value: 52420.0, change: 1840.0, changePercent: 3.64, isPositive: true)
    }
    
    func getSnapshot(in context: Context, completion: @escaping (PortfolioSummaryEntry) -> ()) {
        let entry = PortfolioSummaryEntry(date: Date(), value: 52420.0, change: 1840.0, changePercent: 3.64, isPositive: true)
        completion(entry)
    }
    
    func getTimeline(in context: Context, completion: @escaping (Timeline<PortfolioSummaryEntry>) -> ()) {
        // Pull from shared UserDefaults (from app)
        let sharedDefaults = UserDefaults(suiteName: "group.com.cubeplay.stocktracker")
        let value = sharedDefaults?.double(forKey: "portfolioValue") ?? 52420.0
        let change = sharedDefaults?.double(forKey: "portfolioChange") ?? 1840.0
        let changePercent = sharedDefaults?.double(forKey: "portfolioChangePercent") ?? 3.64
        
        let entry = PortfolioSummaryEntry(
            date: Date(),
            value: value,
            change: change,
            changePercent: changePercent,
            isPositive: change >= 0
        )
        
        // Refresh every 5 minutes
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 5, to: Date())!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

struct PortfolioSummaryWidgetEntryView: View {
    var entry: PortfolioSummaryProvider.Entry
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Portfolio")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
                
                Text(entry.value, format: .currency(code: "USD"))
                    .font(.title2.bold())
                    .foregroundColor(.white)
                
                HStack(spacing: 6) {
                    Image(systemName: entry.isPositive ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption.bold())
                    
                    Text(abs(entry.change), format: .currency(code: "USD"))
                        .font(.headline)
                    
                    Text("(\(entry.isPositive ? "+" : "")\(String(format: "%.2f", entry.changePercent))%)")
                        .font(.caption.bold())
                }
                .foregroundColor(entry.isPositive ? .green : .red)
            }
            .padding(16)
        }
        .containerBackground(for: .widget) {
            Color.clear
        }
    }
}

struct PortfolioSummaryWidget: Widget {
    let kind: String = "PortfolioSummary"
    
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PortfolioSummaryProvider()) { entry in
            PortfolioSummaryWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Portfolio Summary")
        .description("See your total portfolio value and daily change.")
        .supportedFamilies([.systemMedium])
    }
}

// TopMoversWidget.swift
struct TopMover: Identifiable {
    let id = UUID()
    let symbol: String
    let price: Double
    let changePercent: Double
    let isPositive: Bool
}

struct TopMoversWidgetEntryView: View {
    var entry: [TopMover]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(entry.prefix(3)) { mover in
                HStack {
                    Text(mover.symbol)
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    Text(mover.price, format: .currency(code: "USD").precision(.fractionLength(2)))
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.9))
                    
                    Text("\(mover.isPositive ? "+" : "")\(String(format: "%.2f", mover.changePercent))%")
                        .font(.headline.bold())
                        .foregroundColor(mover.isPositive ? .green : .red)
                }
            }
        }
        .padding()
        .background(Color.black)
    }
}

//// WatchlistSparklineWidget.swift
//struct WatchlistSparklineEntryView: View {
//    var asset: Asset
//    
//    var body: some View {
//        HStack {
//            VStack(alignment: .leading) {
//                Text(asset.symbol)
//                    .font(.title2.bold())
//                Text(asset.name)
//                    .font(.caption)
//                    .foregroundColor(.secondary)
//            }
//            
//            Spacer()
//            
//            // Mini Sparkline
//            Chart {
//                ForEach(asset.priceHistory ?? [], id: \.date) { point in
//                    LineMark(x: .value("Time", point.date), y: .value("Price", point.price))
//                        .foregroundStyle(asset.changePercent >= 0 ? .green : .red)
//                }
//            }
//            .chartXAxis(.hidden)
//            .chartYAxis(.hidden)
//            .frame(width: 100, height: 50)
//            
//            Text(asset.price, format: .currency(code: "USD"))
//                .font(.title3.bold())
//        }
//        .padding()
//        .background(Color.black)
//    }
//}

