//
//  MockMarketData.swift
//  Stock Tracker
//
//  Created by Ihtisham Mazid on 16/12/2025.
//


//
//  MockData.swift
//  Stock Tracker
//
//  Delete this entire file when you go live / want real data only
//

import Foundation

// MARK: - Mock Market Data Provider
final class MockMarketData {
    static let shared = MockMarketData()
    
    private init() {}
    
    // MARK: - Mock Stocks
    let mockStocks: [Asset] = [
        Asset(symbol: "AAPL", name: "Apple Inc.", price: 272.54, change: -1.13, changePercent: -0.41, volume: 34751452, kind: .stock, exchange: "NASDAQ"),
        Asset(symbol: "TSLA", name: "Tesla Inc.", price: 482.65, change: 1.45, changePercent: 0.30, volume: 84147310, kind: .stock, exchange: "NASDAQ"),
        Asset(symbol: "MSFT", name: "Microsoft", price: 485.26, change: 1.27, changePercent: 0.26, volume: 15627434, kind: .stock, exchange: "NASDAQ"),
        Asset(symbol: "NVDA", name: "NVIDIA", price: 495.22, change: 12.45, changePercent: 2.58, volume: 45_100_000, kind: .stock, exchange: "NYSE"),
        Asset(symbol: "GOOGL", name: "Alphabet", price: 135.78, change: 2.11, changePercent: 1.58, volume: 31_200_000, kind: .stock, exchange: "NYSE")
    ]
    
    // MARK: - Mock Crypto
    let mockCrypto: [Asset] = [
        Asset(symbol: "BTC", name: "Bitcoin", price: 62850.0, change: -850.0, changePercent: -1.33, volume: 28_500, kind: .crypto, exchange: "Binance"),
        Asset(symbol: "ETH", name: "Ethereum", price: 3180.0, change: 95.0, changePercent: 3.08, volume: 185_000, kind: .crypto, exchange: "Binance"),
        Asset(symbol: "SOL", name: "Solana", price: 138.5, change: -5.8, changePercent: -4.02, volume: 2_100_000, kind: .crypto, exchange: "Binance")
    ]
    
    // MARK: - Mock News
    let mockNews: [NewsArticle] = [
        NewsArticle(
            title: "Apple Unveils New AI Features at WWDC 2026",
            source: "Bloomberg",
            url: "https://example.com",
            imageURL: nil,
            publishedAt: Date().addingTimeInterval(-3600),
            summary: "Apple introduced powerful new on-device AI capabilities...",
            relatedSymbols: ["AAPL"]
        ),
        NewsArticle(
            title: "Bitcoin Surpasses $63,000 as ETF Inflows Continue",
            source: "CoinDesk",
            url: "https://example.com",
            imageURL: nil,
            publishedAt: Date().addingTimeInterval(-7200),
            summary: "Institutional demand pushes BTC to new yearly highs.",
            relatedSymbols: ["BTC"]
        )
    ]
    
    // MARK: - Generate realistic-looking price history
    func generatePriceHistory(for asset: Asset, range: TimeRange) -> [PricePoint] {
        let calendar = Calendar.current
        let now = Date()
        let numPoints: Int
        let component: Calendar.Component
        
        switch range {
        case .oneDay:     numPoints = 48; component = .minute
        case .oneWeek:    numPoints = 7;  component = .day
        case .oneMonth:   numPoints = 30; component = .day
        default:          numPoints = 90; component = .day
        }
        
        let volatility = range.volatility
        var points: [PricePoint] = []
        var currentPrice = asset.price
        
        for i in 0..<numPoints {
            let date = calendar.date(byAdding: component, value: -i * (component == .minute ? 30 : 1), to: now)!
            let change = Double.random(in: -volatility...volatility)
            currentPrice = max(0.01, currentPrice * (1 + change))
            points.append(PricePoint(date: date, price: currentPrice))
        }
        
        return points.sorted { $0.date < $1.date }
    }
}
