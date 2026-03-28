//
//  PortfolioViewModel.swift
//  Stock Tracker
//
//  Owns portfolio filter/sort state and computes filteredHoldings via Combine,
//  so the heavy sort/filter logic runs only when its inputs change — not on
//  every SwiftUI body re-evaluation.
//

import Foundation
import Combine

// MARK: - Sort Option (moved out of PortfolioView so ViewModel can own it)

enum PortfolioSortOption: String, CaseIterable {
    case valueDescending = "Highest Value"
    case valueAscending  = "Lowest Value"
    case gainDescending  = "Best Performers"
    case nameAZ          = "Name A-Z"
}

// MARK: - PortfolioViewModel

@MainActor
final class PortfolioViewModel: ObservableObject {

    @Published var selectedFilter: AssetKind = .stock
    @Published var sortBy: PortfolioSortOption = .valueDescending
    @Published var showAll: Bool = true
    @Published private(set) var filteredHoldings: [PortfolioHolding] = []

    private var cancellables = Set<AnyCancellable>()

    /// Call once from PortfolioView.onAppear to wire up reactive updates.
    func observe(_ marketData: MarketData) {
        guard cancellables.isEmpty else { return }   // idempotent

        Publishers.CombineLatest4(
            marketData.$portfolio,
            $selectedFilter,
            $sortBy,
            $showAll
        )
        .map { portfolio, filter, sort, showAll -> [PortfolioHolding] in
            let filtered: [PortfolioHolding] = showAll
                ? portfolio
                : portfolio.filter { $0.asset.kind == filter }
            return filtered.sorted { lhs, rhs in
                switch sort {
                case .valueDescending: return lhs.currentValue > rhs.currentValue
                case .valueAscending:  return lhs.currentValue < rhs.currentValue
                case .gainDescending:  return lhs.profitLossPercent > rhs.profitLossPercent
                case .nameAZ:          return lhs.asset.name < rhs.asset.name
                }
            }
        }
        .receive(on: DispatchQueue.main)
        .assign(to: &$filteredHoldings)
    }
}
