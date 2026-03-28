//
//  SupabaseAuthManager.swift
//  Stock Tracker
//
//  Manages cloud identity (Supabase Auth) independently of the local
//  biometric lock (AuthManager). A user can be:
//    - Biometrically locked but cloud-signed-in  (common on relaunch)
//    - Biometrically unlocked but cloud-signed-out  (guest mode)
//    - Both locked and signed out
//
//  Sign-in methods:
//    1. Sign in with Apple  (ASAuthorization → Supabase id_token exchange)
//    2. Email / Password    (standard Supabase signIn / signUp)
//
//  The supabase-swift SDK stores the session in its own Keychain item
//  automatically — we do not need to serialise it manually.
//

import Foundation
import Supabase
import AuthenticationServices
import OSLog
import Combine
import CryptoKit

// MARK: - Auth State

enum CloudAuthState: Equatable {
    case signedOut
    case signingIn
    case signedIn
    case error(String)
}

// MARK: - SupabaseAuthManager

@MainActor
final class SupabaseAuthManager: NSObject, ObservableObject {

    // MARK: Published

    @Published var cloudUser: User?
    @Published var authState: CloudAuthState = .signedOut
    @Published var needsMFAChallenge: Bool = false

    // MARK: Private

    private var appleSignInContinuation: CheckedContinuation<ASAuthorization, Error>?
    private var currentNonce: String?
    private var cancellables = Set<AnyCancellable>()

    // MARK: Init

    override init() {
        super.init()
        // Observe Supabase auth state changes (SDK fires events on session restore)
        Task { await listenToAuthEvents() }
    }

    // MARK: - Session restore

    /// Call once on app launch (inside StockCryptoTrackerApp.init).
    /// supabase-swift automatically restores a persisted session; this
    /// method just ensures our @Published state reflects it.
    func restoreSessionIfNeeded() {
        Task {
            do {
                let session = try await SupabaseManager.auth.session
                cloudUser = session.user
                authState = .signedIn
                AppLogger.sync.info("Session restored for user \(session.user.email ?? "unknown")")
                // Check if MFA challenge is needed
                if let aal = try? await SupabaseManager.auth.mfa.getAuthenticatorAssuranceLevel() {
                    if aal.currentLevel == "aal1" && aal.nextLevel == "aal2" {
                        needsMFAChallenge = true
                    }
                }
            } catch {
                // No stored session — user is signed out (normal on first launch)
                cloudUser = nil
                authState = .signedOut
            }
        }
    }

    // MARK: - Sign in with Apple

    func signInWithApple() async {
        guard SupabaseManager.isConfigured else {
            authState = .error("Supabase not configured. Add credentials to Secrets.plist.")
            return
        }
        authState = .signingIn

        do {
            // 1. Generate and store a cryptographic nonce
            let nonce = generateNonce()
            currentNonce = nonce

            // 2. Request Apple credential
            let appleCredential = try await requestAppleCredential(nonce: nonce)
            guard
                let appleIDCredential = appleCredential.credential as? ASAuthorizationAppleIDCredential,
                let idTokenData = appleIDCredential.identityToken,
                let idTokenString = String(data: idTokenData, encoding: .utf8)
            else {
                authState = .error("Apple credential invalid. Please try again.")
                return
            }

            // 3. Exchange Apple id_token for a Supabase session
            let session = try await SupabaseManager.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(
                    provider: .apple,
                    idToken: idTokenString,
                    nonce: nonce
                )
            )
            cloudUser = session.user
            authState = .signedIn
            AppLogger.sync.info("Signed in with Apple: \(session.user.email ?? session.user.id.uuidString)")

        } catch {
            authState = .error(error.localizedDescription)
            AppLogger.sync.error("Apple sign-in failed: \(error)")
        }
    }

    // MARK: - Sign in with Email

    func signIn(email: String, password: String) async {
        guard SupabaseManager.isConfigured else {
            authState = .error("Supabase not configured. Add credentials to Secrets.plist.")
            return
        }
        authState = .signingIn
        do {
            let session = try await SupabaseManager.auth.signIn(email: email, password: password)
            cloudUser = session.user
            authState = .signedIn
            AppLogger.sync.info("Signed in with email: \(session.user.email ?? "unknown")")
        } catch {
            authState = .error(error.localizedDescription)
            AppLogger.sync.error("Email sign-in failed: \(error)")
        }
    }

    // MARK: - Sign up with Email

    func signUp(email: String, password: String) async {
        guard SupabaseManager.isConfigured else {
            authState = .error("Supabase not configured. Add credentials to Secrets.plist.")
            return
        }
        authState = .signingIn
        do {
            let response = try await SupabaseManager.auth.signUp(email: email, password: password)
            cloudUser = response.user
            authState = response.user != nil ? .signedIn : .signedOut
            if response.session == nil {
                // Email confirmation required
                authState = .error("Check your email to confirm your account, then sign in.")
            }
            let email = response.user.email ?? "unknown"
            AppLogger.sync.info("Signed up: \(email)")
        } catch {
            authState = .error(error.localizedDescription)
            AppLogger.sync.error("Email sign-up failed: \(error)")
        }
    }

    // MARK: - Password Reset

    func sendPasswordReset(email: String) async throws {
        try await SupabaseManager.auth.resetPasswordForEmail(email)
    }

    // MARK: - Sign out

    func signOut() async {
        do {
            try await SupabaseManager.auth.signOut()
        } catch {
            AppLogger.sync.error("Sign-out error (continuing anyway): \(error)")
        }
        // Clear sync session metadata; local portfolio/watchlist data is preserved
        DataPersistenceManager.shared.clearSyncCredentials()
        cloudUser = nil
        authState = .signedOut
        AppLogger.sync.info("User signed out. Local data intact.")
    }

    // MARK: - Convenience

    var userId: UUID? { cloudUser?.id }
    var userEmail: String? { cloudUser?.email }
    var isSignedIn: Bool { cloudUser != nil }

    // MARK: - Auth event listener

    private func listenToAuthEvents() async {
        for await (event, session) in SupabaseManager.auth.authStateChanges {
            await MainActor.run {
                switch event {
                case .signedIn, .tokenRefreshed, .userUpdated:
                    self.cloudUser = session?.user
                    self.authState = session != nil ? .signedIn : .signedOut
                case .signedOut, .passwordRecovery:
                    self.cloudUser = nil
                    self.authState = .signedOut
                default:
                    break
                }
            }
        }
    }

    // MARK: - Apple Sign-In helpers

    private func requestAppleCredential(nonce: String) async throws -> ASAuthorization {
        try await withCheckedThrowingContinuation { continuation in
            self.appleSignInContinuation = continuation

            let provider = ASAuthorizationAppleIDProvider()
            let request = provider.createRequest()
            request.requestedScopes = [.fullName, .email]
            request.nonce = sha256(nonce)

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    private func generateNonce(length: Int = 32) -> String {
        precondition(length > 0)
        var randomBytes = [UInt8](repeating: 0, count: length)
        let errorCode = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        guard errorCode == errSecSuccess else { fatalError("Unable to generate nonce.") }
        return randomBytes.map { String(format: "%02x", $0) }.joined()
    }

    private func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - ASAuthorizationControllerDelegate

extension SupabaseAuthManager: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        Task { @MainActor in
            appleSignInContinuation?.resume(returning: authorization)
            appleSignInContinuation = nil
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        Task { @MainActor in
            appleSignInContinuation?.resume(throwing: error)
            appleSignInContinuation = nil
        }
    }
}

// MARK: - ASAuthorizationControllerPresentationContextProviding

extension SupabaseAuthManager: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // Returns the key window — works for both scenes and single-window apps
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.keyWindow ?? UIWindow()
    }
}
