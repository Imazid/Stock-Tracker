//
//  PortfolioBenchmarkChart.swift
//  Stock Tracker
//

import SwiftUI
import Charts



//struct BorderedCircle: ChartSymbolShape {
//
//    static var perceptualUnitResolution: CGSize {
//        CGSize(width: 1, height: 1)
//    }
//
//    func path(in rect: CGRect, style: ChartSymbolStyle) -> Path {
//        Path { path in
//            path.addEllipse(in: rect)
//        }
//    }
//}


// MARK: - Portfolio vs Benchmark Chart
struct PortfolioBenchmarkChart: View {
    @EnvironmentObject var marketData: MarketData
    @EnvironmentObject var subscriptionManager: SubscriptionManager

    @State private var selectedRange: TimeRange = .oneYear

    private var portfolioPoints: [PricePoint] {
        marketData.portfolioHistory.map {
            PricePoint(date: $0.date, price: $0.totalValue)
        }
    }

    private var normalizedPortfolio: [PricePoint] {
        normalize(data: portfolioPoints, to: 100)
    }

    private var normalizedSP500: [PricePoint] {
        normalize(data: marketData.sp500History, to: 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
        }
        .padding()
        .background(Color.white.opacity(0.05))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: - Header
    private var header: some View {
        HStack {
            Text("Portfolio vs S&P 500")
                .font(.title3.bold())
                .foregroundColor(.white)

            Spacer()

            Picker("Range", selection: $selectedRange) {
                ForEach(subscriptionManager.currentTier.availableTimeRanges, id: \.self) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.menu)
            .tint(.blue)
        }
    }

    // MARK: - Content
    @ViewBuilder
    private var content: some View {
        if normalizedPortfolio.isEmpty || normalizedSP500.isEmpty {
            loadingView
        } else {
            chartView
            legend
        }
    }

    private var loadingView: some View {
        VStack {
            ProgressView()
                .tint(.white)

            Text("Loading benchmark data...")
                .font(.caption)
                .foregroundColor(.gray)
        }
        .frame(height: 250)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Chart
    private var chartView: some View {
        Chart {
            ForEach(normalizedPortfolio) { point in
                LineMark(
                    x: .value("Date", point.date),
                    y: .value("Value", point.price)
                )
                .foregroundStyle(.blue)
                .interpolationMethod(.catmullRom)
                //.symbol(BorderedCircle())
            }

            ForEach(normalizedSP500) { point in
                LineMark(
                    x: .value("Date", point.date),
                    y: .value("Value", point.price)
                )
                .foregroundStyle(.orange)
                .interpolationMethod(.catmullRom)
                //.symbol(BorderedCircle())
            }
        }
        .frame(height: 250)
    }

    // MARK: - Legend
    private var legend: some View {
        HStack(spacing: 20) {
            Label("Your Portfolio", systemImage: "circle.fill")
                .foregroundColor(.blue)
                .font(.caption)

            Label("S&P 500", systemImage: "circle.fill")
                .foregroundColor(.orange)
                .font(.caption)
        }
        .padding(.top, 8)
    }

    // MARK: - Helpers
    private func normalize(data: [PricePoint], to base: Double) -> [PricePoint] {
        guard let firstPrice = data.first?.price, firstPrice > 0 else {
            return []
        }

        let multiplier = base / firstPrice
        return data.map {
            PricePoint(date: $0.date, price: $0.price * multiplier)
        }
    }
}

// MARK: - Preview
#Preview {
    PortfolioBenchmarkChart()
        .environmentObject(MarketData())
        .environmentObject(SubscriptionManager.shared)
        .preferredColorScheme(.dark)
}
