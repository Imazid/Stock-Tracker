//
//  NetworkMonitor.swift
//  Stock Tracker
//
//  Publishes real-time network reachability using NWPathMonitor.
//  Inject as an @EnvironmentObject or observe via the shared singleton.
//
//  Usage (SwiftUI):
//    @EnvironmentObject var network: NetworkMonitor
//    if !network.isConnected { OfflineBanner() }
//

import Network
import OSLog
import SwiftUI
import Combine

@MainActor
final class NetworkMonitor: ObservableObject {

    static let shared = NetworkMonitor()

    @Published private(set) var isConnected: Bool = true
    @Published private(set) var connectionType: ConnectionType = .wifi

    enum ConnectionType: String {
        case wifi     = "Wi-Fi"
        case cellular = "Cellular"
        case wired    = "Wired"
        case other    = "Other"
        case none     = "No Connection"
    }

    private let monitor = NWPathMonitor()
    private let queue   = DispatchQueue(label: "com.stocktracker.networkMonitor", qos: .utility)

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            let type: ConnectionType
            if path.usesInterfaceType(.wifi)      { type = .wifi }
            else if path.usesInterfaceType(.cellular) { type = .cellular }
            else if path.usesInterfaceType(.wiredEthernet) { type = .wired }
            else if connected                     { type = .other }
            else                                  { type = .none }

            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasConnected = self.isConnected
                self.isConnected    = connected
                self.connectionType = type
                if !wasConnected && connected {
                    AppLogger.general.info("Network restored (\(type.rawValue))")
                } else if wasConnected && !connected {
                    AppLogger.general.warning("Network lost")
                }
            }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}

// MARK: - Reusable offline banner

struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
            Text("No Internet Connection")
                .font(.subheadline.weight(.medium))
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.85))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Reusable retry view

struct RetryView: View {
    let message: String
    let action: () async -> Void

    @State private var isRetrying = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundColor(.orange)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button {
                isRetrying = true
                Task {
                    await action()
                    isRetrying = false
                }
            } label: {
                if isRetrying {
                    ProgressView()
                        .padding(.horizontal, 24)
                } else {
                    Text("Tap to Retry")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 24)
                        .padding(.vertical, 8)
                }
            }
            .buttonStyle(.bordered)
            .disabled(isRetrying)
        }
        .padding()
    }
}
