//
//  QuickActions.swift
//  Stock Tracker
//
//  Home Screen quick actions (long-press the app icon): Search, Price alerts,
//  Portfolio, Watchlist. Each item's type is a stocktracker:// URL, so it goes
//  through the same router as widget taps (`handleWidgetDeepLink`).
//  The items themselves are static, in Stock-Tracker-Info.plist.
//

import UIKit
import Combine

@MainActor
final class QuickActionRouter: ObservableObject {
    static let shared = QuickActionRouter()
    /// The deep link to open; the app clears it once handled.
    @Published var pending: URL?

    func handle(_ item: UIApplicationShortcutItem) {
        pending = URL(string: item.type)
    }
}

/// Bridges UIKit quick actions and APNs registration into the SwiftUI app.
final class QuickActionAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Cold launch from a quick action.
        if let item = options.shortcutItem {
            MainActor.assumeIsolated { QuickActionRouter.shared.handle(item) }
        }
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = QuickActionSceneDelegate.self
        return configuration
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated { PrivateMarketsStore.shared.receivedPushToken(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        MainActor.assumeIsolated { PrivateMarketsStore.shared.pushRegistrationFailed() }
    }
}

final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    // App already running.
    func windowScene(_ windowScene: UIWindowScene,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        MainActor.assumeIsolated { QuickActionRouter.shared.handle(shortcutItem) }
        completionHandler(true)
    }
}
