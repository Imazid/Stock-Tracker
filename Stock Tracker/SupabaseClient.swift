//
//  SupabaseClient.swift
//  Stock Tracker
//
//  Single point of entry for the supabase-swift SDK.
//
//  SETUP:
//    1. In Xcode: File > Add Package Dependencies
//       URL: https://github.com/supabase/supabase-swift
//       Version: Up to Next Major from 2.0.0
//       Add library "Supabase" to the "Stock Tracker" target only.
//    2. Fill in SupabaseURL and SupabaseAnonKey in Config/Secrets.plist
//

import Supabase
import OSLog
import Foundation

enum SupabaseManager {

    // MARK: - Singleton client

    static let client: SupabaseClient = {
        guard
            !SecretsConfig.supabaseURL.isEmpty,
            !SecretsConfig.supabaseAnonKey.isEmpty,
            let url = URL(string: SecretsConfig.supabaseURL)
        else {
            AppLogger.sync.error("Supabase credentials missing — sync disabled. Fill in SupabaseURL/SupabaseAnonKey in Config/Secrets.plist.")
            return SupabaseClient(
                supabaseURL: URL(string: "https://placeholder.supabase.co")!,
                supabaseKey: "placeholder"
            )
        }
        return SupabaseClient(supabaseURL: url, supabaseKey: SecretsConfig.supabaseAnonKey)
    }()

    // MARK: - Convenience passthroughs

    /// Auth client — use for sign-in, sign-up, session management.
    static var auth: AuthClient { client.auth }

    /// Whether real credentials are configured (non-placeholder).
    static var isConfigured: Bool {
        !SecretsConfig.supabaseURL.isEmpty &&
        !SecretsConfig.supabaseAnonKey.isEmpty &&
        SecretsConfig.supabaseURL != "https://placeholder.supabase.co"
    }
}
