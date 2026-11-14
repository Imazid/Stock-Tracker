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

    #if DEBUG
    func restoreTestSession(accessToken: String, refreshToken: String) async {
        authState = .signingIn
        do {
            let session = try await withAccountDeadline {
                try await SupabaseManager.auth.setSession(accessToken: accessToken, refreshToken: refreshToken)
            }
            cloudUser = session.user
            authState = .signedIn
        } catch {
            fail(error, context: "Local test session")
        }
    }
    #endif

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
    var deletionUsesApple: Bool { cloudUser?.identities?.contains { $0.provider == "apple" } == true }

    struct DeletionReceipt: Decodable {
        let deleted: Bool
        let brokerDeletionQueued: Bool
    }

    private struct DeletionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func deleteAccount(owner: UUID, password: String, authenticatorCode: String?) async throws -> DeletionReceipt {
        guard userId == owner, let base = URL(string: SecretsConfig.supabaseURL) else {
            throw DeletionError(message: "Sign in again to delete your account.")
        }
        if let authenticatorCode {
            let factors = try await SupabaseManager.auth.mfa.listFactors()
            if let factor = factors.totp.first(where: { $0.status == .verified }) {
                try await SupabaseManager.auth.mfa.challengeAndVerify(
                    params: MFAChallengeAndVerifyParams(factorId: factor.id, code: authenticatorCode)
                )
            }
        }
        var body: [String: Any] = ["confirm": true]
        if deletionUsesApple {
            guard appleSignInContinuation == nil else { throw DeletionError(message: AuthCopy.tryAgain) }
            let authorization = try await requestAppleCredential(nonce: generateNonce())
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let data = credential.authorizationCode,
                  let code = String(data: data, encoding: .utf8), !code.isEmpty else {
                throw DeletionError(message: "Apple did not return an authorization code. Try again.")
            }
            body["appleCode"] = code
        } else {
            body["password"] = password
        }

        let session = try await SupabaseManager.auth.session
        guard userId == owner, session.user.id == owner else {
            throw DeletionError(message: "Your account changed. Open Account settings to try again.")
        }
        var request = URLRequest(url: base.appending(path: "functions/v1/account-deletion"), timeoutInterval: 40)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SecretsConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer " + session.accessToken, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let receipt = try? JSONDecoder().decode(DeletionReceipt.self, from: data), receipt.deleted else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let error = json?["error"] as? [String: Any]
            throw DeletionError(message: error?["message"] as? String ?? "Account deletion could not be confirmed. Try again.")
        }
        return receipt
    }

    func finishAccountDeletion(owner: UUID) async {
        guard userId == owner else { return }
        DataPersistenceManager.shared.clearSyncCredentials()
        try? await withAccountDeadline(seconds: 5) {
            try await SupabaseManager.auth.signOut(scope: .local)
        }
        if userId == owner {
            cloudUser = nil
            authState = .signedOut
        }
    }

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
