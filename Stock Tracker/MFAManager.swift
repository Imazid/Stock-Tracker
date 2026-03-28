//
//  MFAManager.swift
//  Stock Tracker
//
//  Manages TOTP-based Multi-Factor Authentication (MFA) via the Supabase
//  Swift SDK. Handles factor enrollment, QR code generation, challenge
//  verification, and unenrollment.
//
//  Usage:
//    - Inject as @StateObject / @EnvironmentObject or use MFAManager.shared
//    - Call checkMFAStatus() on sign-in to determine if MFA verification is
//      required (AAL1 → AAL2 step-up)
//    - Use enrollTOTP() to begin enrollment, then verifyEnrollment(code:)
//      to confirm the authenticator setup
//    - Use verifyChallenge(code:) at login time when needsMFAVerification()
//      returns true
//

import Foundation
import Supabase
import OSLog
import Combine
import CoreImage.CIFilterBuiltins
import UIKit

// MARK: - MFA State

enum MFAState: Equatable {
    case idle
    case enrolling
    case challenging
    case verifying
    case verified
    case error(String)
}

// MARK: - MFAManager

@MainActor
final class MFAManager: ObservableObject {

    // MARK: Singleton

    static let shared = MFAManager()

    // MARK: Published

    @Published var mfaState: MFAState = .idle
    @Published var qrCodeImage: UIImage?
    @Published var enrollSecret: String?
    @Published var enrollFactorId: String?
    @Published var verifiedFactors: [Factor] = []
    @Published var isMFAEnabled: Bool = false
    @Published var currentAAL: AuthMFAGetAuthenticatorAssuranceLevelResponse?

    // MARK: Init

    private init() {}

    // MARK: - Check MFA Status

    /// Refreshes the list of enrolled factors and the current assurance level.
    /// Call after sign-in or whenever the MFA state may have changed.
    func checkMFAStatus() async {
        do {
            let factors = try await SupabaseManager.auth.mfa.listFactors()

            // Filter to verified TOTP factors
            let verified = factors.totp.filter { $0.status == .verified }
            verifiedFactors = verified
            isMFAEnabled = !verified.isEmpty

            let aal = try await SupabaseManager.auth.mfa.getAuthenticatorAssuranceLevel()
            currentAAL = aal

            AppLogger.security.info("MFA status check — verified factors: \(verified.count), current AAL: \(aal.currentLevel ?? "nil"), next AAL: \(aal.nextLevel ?? "nil")")
        } catch {
            AppLogger.security.error("MFA status check failed: \(error)")
            mfaState = .error("Failed to check MFA status: \(error.localizedDescription)")
        }
    }

    // MARK: - Enroll TOTP

    /// Begins TOTP enrollment. Generates a QR code image from the returned
    /// TOTP URI that the user can scan with an authenticator app.
    func enrollTOTP() async {
        mfaState = .enrolling

        do {
            let response = try await SupabaseManager.auth.mfa.enroll(
                params: MFATotpEnrollParams(
                    issuer: "Stock Tracker",
                    friendlyName: "Stock Tracker"
                )
            )

            enrollFactorId = response.id
            enrollSecret = response.totp?.secret

            // Generate QR code from the TOTP URI
            if let uri = response.totp?.uri {
                qrCodeImage = generateQRCode(from: uri)
            }

            AppLogger.security.info("TOTP factor enrolled (pending verification). Factor ID: \(response.id)")
        } catch {
            mfaState = .error("Enrollment failed: \(error.localizedDescription)")
            AppLogger.security.error("TOTP enrollment failed: \(error)")
        }
    }

    // MARK: - Verify Enrollment

    /// Verifies the newly enrolled TOTP factor by challenging and verifying
    /// with a code from the user's authenticator app.
    /// - Parameter code: The 6-digit TOTP code.
    func verifyEnrollment(code: String) async {
        guard let factorId = enrollFactorId else {
            mfaState = .error("No factor pending verification. Enroll first.")
            AppLogger.security.error("verifyEnrollment called without a pending factor ID.")
            return
        }

        mfaState = .verifying

        do {
            // Challenge and verify in one call
            try await SupabaseManager.auth.mfa.challengeAndVerify(
                params: MFAChallengeAndVerifyParams(
                    factorId: factorId,
                    code: code
                )
            )

            mfaState = .verified
            AppLogger.security.info("TOTP enrollment verified successfully for factor \(factorId).")

            // Refresh MFA status to reflect the newly verified factor
            await checkMFAStatus()
        } catch {
            mfaState = .error("Verification failed: \(error.localizedDescription)")
            AppLogger.security.error("TOTP enrollment verification failed: \(error)")
        }
    }

    // MARK: - Verify Challenge (Login-time MFA)

    /// Verifies MFA at login time when the user already has an enrolled TOTP
    /// factor and needs to step up from AAL1 to AAL2.
    /// - Parameter code: The 6-digit TOTP code.
    func verifyChallenge(code: String) async {
        guard let factor = verifiedFactors.first else {
            mfaState = .error("No verified TOTP factor found.")
            AppLogger.security.error("verifyChallenge called but no verified TOTP factors exist.")
            return
        }

        mfaState = .challenging

        do {
            try await SupabaseManager.auth.mfa.challengeAndVerify(
                params: MFAChallengeAndVerifyParams(
                    factorId: factor.id,
                    code: code
                )
            )

            mfaState = .verified
            AppLogger.security.info("MFA challenge verified — stepped up to AAL2.")

            // Refresh AAL after successful verification
            await checkMFAStatus()
        } catch {
            mfaState = .error("Challenge verification failed: \(error.localizedDescription)")
            AppLogger.security.error("MFA challenge verification failed: \(error)")
        }
    }

    // MARK: - Unenroll TOTP

    /// Removes all verified TOTP factors, effectively disabling MFA.
    func unenrollTOTP() async {
        let factorsToRemove = verifiedFactors

        guard !factorsToRemove.isEmpty else {
            AppLogger.security.info("unenrollTOTP called but no factors to remove.")
            return
        }

        do {
            for factor in factorsToRemove {
                try await SupabaseManager.auth.mfa.unenroll(
                    params: MFAUnenrollParams(factorId: factor.id)
                )
                AppLogger.security.info("Unenrolled TOTP factor: \(factor.id)")
            }

            mfaState = .idle
            resetEnrollment()

            // Refresh MFA status
            await checkMFAStatus()

            AppLogger.security.info("All TOTP factors unenrolled. MFA disabled.")
        } catch {
            mfaState = .error("Unenroll failed: \(error.localizedDescription)")
            AppLogger.security.error("TOTP unenroll failed: \(error)")
        }
    }

    // MARK: - Needs MFA Verification

    /// Returns `true` if the user is at AAL1 but needs AAL2 (i.e., MFA is
    /// enrolled but the current session has not yet completed the second factor).
    func needsMFAVerification() -> Bool {
        guard let aal = currentAAL else { return false }
        return aal.currentLevel == "aal1" && aal.nextLevel == "aal2"
    }

    // MARK: - Reset Enrollment

    /// Clears transient enrollment state (factor ID, secret, QR image) and
    /// returns to idle. Does NOT unenroll from Supabase.
    func resetEnrollment() {
        enrollFactorId = nil
        enrollSecret = nil
        qrCodeImage = nil
        mfaState = .idle
    }

    // MARK: - QR Code Generation

    /// Generates a `UIImage` containing a QR code for the given TOTP URI.
    /// Uses CoreImage's built-in QR code generator with medium error correction.
    private func generateQRCode(from uri: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(uri.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else {
            AppLogger.security.error("CIFilter.qrCodeGenerator produced no output for TOTP URI.")
            return nil
        }

        // Scale up from the native tiny size to a usable resolution
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 8, y: 8))

        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            AppLogger.security.error("Failed to create CGImage from scaled QR code CIImage.")
            return nil
        }

        return UIImage(cgImage: cgImage)
    }
}
