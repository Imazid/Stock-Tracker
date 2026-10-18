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

// MARK: - Copy

/// What account screens say when the service can't be used.
enum AuthCopy {
    static let unavailable = "Accounts are unavailable right now. Everything you've set up stays on this iPhone, and you can sign in later from Settings."
    static let offline = "You're offline. Connect to the internet and try again."
    static let tryAgain = "Something went wrong. Please try again."
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

    /// For custom "Continue with Apple" buttons (onboarding): presents Apple's sheet
    /// itself. One call = one attempt; a second tap while one is running is ignored.
    func signInWithApple() async {
        guard authState != .signingIn, appleSignInContinuation == nil else { return }
        guard await accountServiceReady() else { return }
        authState = .signingIn

        do {
            let nonce = generateNonce()
            currentNonce = nonce
            let authorization = try await requestAppleCredential(nonce: nonce)
            await exchangeAppleCredential(authorization, nonce: nonce)
        } catch {
            fail(error, context: "Apple sign-in")
        }
    }

    /// For SwiftUI's `SignInWithAppleButton`: fills in the request it is about to send.
    /// The button presents Apple's sheet; `completeAppleSignIn` takes the result.
    func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = generateNonce()
        currentNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(nonce)
    }

    func completeAppleSignIn(_ result: Result<ASAuthorization, Error>) async {
        guard authState != .signingIn else { return }
        switch result {
        case .failure(let error):
            fail(error, context: "Apple sign-in")
        case .success(let authorization):
            guard let nonce = currentNonce else {
                authState = .error(AuthCopy.tryAgain)
                return
            }
            guard await accountServiceReady() else { return }
            authState = .signingIn
            await exchangeAppleCredential(authorization, nonce: nonce)
        }
    }

    /// Swaps Apple's id_token for a Supabase session.
    private func exchangeAppleCredential(_ authorization: ASAuthorization, nonce: String) async {
        guard
            let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
            let tokenData = credential.identityToken,
            let idToken = String(data: tokenData, encoding: .utf8)
        else {
            authState = .error("Apple didn't return a sign-in token. Please try again.")
            return
        }
        do {
            let session = try await withAccountDeadline {
                try await SupabaseManager.auth.signInWithIdToken(
                    credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce)
                )
            }
            cloudUser = session.user
            authState = .signedIn
            AppLogger.sync.info("Signed in with Apple: \(session.user.email ?? session.user.id.uuidString)")
        } catch {
            fail(error, context: "Apple sign-in")
        }
    }

    // MARK: - Sign in with Email

    func signIn(email: String, password: String) async {
        guard authState != .signingIn else { return }
        guard await accountServiceReady() else { return }
        authState = .signingIn
        do {
            let session = try await withAccountDeadline {
                try await SupabaseManager.auth.signIn(email: email, password: password)
            }
            cloudUser = session.user
            authState = .signedIn
            AppLogger.sync.info("Signed in with email: \(session.user.email ?? "unknown")")
        } catch {
            fail(error, context: "Email sign-in")
        }
    }

    // MARK: - Sign up with Email

    func signUp(email: String, password: String) async {
        guard authState != .signingIn else { return }
        guard await accountServiceReady() else { return }
        authState = .signingIn
        do {
            let response = try await withAccountDeadline {
                try await SupabaseManager.auth.signUp(email: email, password: password)
            }
            cloudUser = response.user
            // No session yet = the project wants the email confirmed first.
            authState = response.session == nil
                ? .error("Check your email to confirm your account, then sign in.")
                : .signedIn
            AppLogger.sync.info("Signed up: \(response.user.email ?? "unknown")")
        } catch {
            fail(error, context: "Email sign-up")
        }
    }

    // MARK: - Account service availability

    /// Checks the account service before an attempt, so a dead or unreachable
    /// backend is reported in plain words straight away — never a hang.
    private func accountServiceReady() async -> Bool {
        switch await AccountService.shared.check() {
        case .offline:
            authState = .error(AuthCopy.offline)
            return false
        case .unavailable:
            authState = .error(AuthCopy.unavailable)
            return false
        default:
            return true
        }
    }

    private func fail(_ error: Error, context: String) {
        AppLogger.sync.error("\(context) failed: \(error)")
        if let auth = error as? ASAuthorizationError, auth.code == .canceled {
            authState = .signedOut   // the person closed Apple's sheet — not an error
            return
        }
        AccountService.shared.noteFailure(error)
        if error is AccountServiceError {
            authState = .error(AuthCopy.unavailable)
        } else if AccountService.shared.status == .offline {
            authState = .error(AuthCopy.offline)
        } else if AccountService.shared.status == .unavailable {
            authState = .error(AuthCopy.unavailable)
        } else {
            authState = .error(error.localizedDescription)
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
        // ASAuthorizationController asks on the main thread.
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            if let window = scene?.keyWindow { return window }
            if let scene { return UIWindow(windowScene: scene) }
            return ASPresentationAnchor()
        }
    }
}
