//
//  SecurityManager.swift
//  Stock Tracker
//
//  Central security manager: jailbreak detection, screenshot protection,
//  secure logging, and device integrity checks.
//

import Foundation
import UIKit
import Combine
import CryptoKit
import OSLog

// MARK: - Security Manager

@MainActor
final class SecurityManager: ObservableObject {
    static let shared = SecurityManager()

    @Published var isDeviceCompromised: Bool = false
    @Published var showJailbreakWarning: Bool = false

    /// Privacy overlay view for app switcher screenshot protection
    private var privacyOverlayWindow: UIWindow?

    private init() {
        isDeviceCompromised = detectCompromisedDevice()
    }

    // MARK: - Jailbreak Detection

    /// Multi-signal jailbreak detection.
    /// Returns true if ANY indicator of a compromised device is found.
    nonisolated func detectCompromisedDevice() -> Bool {
        #if targetEnvironment(simulator)
        return false // Skip in simulator
        #else

        // 1. Check for known jailbreak files (only highly specific paths — no /bin/bash
        //    or /usr/bin/ssh which can exist legitimately in some iOS configurations)
        let suspiciousPaths = [
            "/Applications/Cydia.app",
            "/Applications/Sileo.app",
            "/Applications/Zebra.app",
            "/Library/MobileSubstrate/MobileSubstrate.dylib",
            "/etc/apt",
            "/private/var/lib/apt/",
            "/private/var/lib/cydia",
            "/private/var/stash",
            "/private/var/tmp/cydia.log",
            "/var/cache/apt",
            "/var/lib/cydia"
        ]

        for path in suspiciousPaths {
            if FileManager.default.fileExists(atPath: path) {
                SecureLogger.warning("Suspicious path detected: \(path)")
                return true
            }
        }

        // 2. Check if app can write outside sandbox
        let testPath = "/private/jailbreak_test_\(UUID().uuidString)"
        do {
            try "test".write(toFile: testPath, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(atPath: testPath)
            SecureLogger.warning("Write outside sandbox succeeded")
            return true
        } catch {
            // Expected to fail on non-jailbroken devices
        }

        // 3. Check if Cydia URL scheme is registered
        if let url = URL(string: "cydia://package/com.test") {
            if UIApplication.shared.canOpenURL(url) {
                SecureLogger.warning("Cydia URL scheme available")
                return true
            }
        }

        // 4. Check for suspicious environment variables
        // Skipped in DEBUG builds: Xcode's debugger can set DYLD_INSERT_LIBRARIES
        // legitimately, causing false positives during development.
        #if !DEBUG
        if let _ = getenv("DYLD_INSERT_LIBRARIES") {
            SecureLogger.warning("DYLD_INSERT_LIBRARIES detected")
            return true
        }
        #endif

        return false
        #endif
    }

    // MARK: - Screenshot Protection (App Switcher)

    /// Call when app enters background to hide sensitive financial data
    func enableScreenshotProtection() {
        guard privacyOverlayWindow == nil else { return }

        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else { return }

        let window = UIWindow(windowScene: windowScene)
        window.windowLevel = .alert + 1

        let blurEffect = UIBlurEffect(style: .dark)
        let blurView = UIVisualEffectView(effect: blurEffect)
        blurView.frame = window.bounds
        blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // Add app icon/branding on top of blur
        let iconView = UIImageView(image: UIImage(systemName: "chart.line.uptrend.xyaxis.circle.fill"))
        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        iconView.frame = CGRect(x: 0, y: 0, width: 80, height: 80)
        iconView.center = blurView.center

        let controller = UIViewController()
        controller.view.addSubview(blurView)
        controller.view.addSubview(iconView)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 80),
            iconView.heightAnchor.constraint(equalToConstant: 80)
        ])

        window.rootViewController = controller
        window.isHidden = false

        privacyOverlayWindow = window
    }

    /// Call when app enters foreground to remove privacy overlay
    func disableScreenshotProtection() {
        privacyOverlayWindow?.isHidden = true
        privacyOverlayWindow = nil
    }

    // MARK: - Debugger Detection

    /// Check if a debugger is attached (anti-tampering)
    nonisolated static func isDebuggerAttached() -> Bool {
        #if DEBUG
        return false // Allow debugging in debug builds
        #else
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]

        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0 else { return false }

        return (info.kp_proc.p_flag & P_TRACED) != 0
        #endif
    }
}

// MARK: - Secure Logger

/// Logging utility that strips sensitive data before logging.
/// Routes to AppLogger (OSLog) — visible in Console.app in both Debug and Release.
enum SecureLogger {

    static func info(_ message: String, file: String = #file, line: Int = #line) {
        AppLogger.security.info("\((file as NSString).lastPathComponent):\(line) \(message, privacy: .public)")
    }

    static func warning(_ message: String, file: String = #file, line: Int = #line) {
        AppLogger.security.warning("\((file as NSString).lastPathComponent):\(line) \(message, privacy: .public)")
    }

    static func error(_ message: String, file: String = #file, line: Int = #line) {
        let redacted = redactSensitiveData(message)
        AppLogger.security.error("\((file as NSString).lastPathComponent):\(line) \(redacted, privacy: .public)")
    }

    /// Redact known sensitive patterns from log messages
    private static func redactSensitiveData(_ message: String) -> String {
        var redacted = message

        // Redact API keys (common patterns)
        let patterns = [
            "(?i)(api[_-]?key|apikey|secret|token|password|authorization)\\s*[:=]\\s*\\S+",
            "(?i)Bearer\\s+\\S+",
            "sk-[a-zA-Z0-9-]+",
            "PK[A-Z0-9]{10,}"
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                redacted = regex.stringByReplacingMatches(
                    in: redacted,
                    range: NSRange(redacted.startIndex..., in: redacted),
                    withTemplate: "[REDACTED]"
                )
            }
        }

        return redacted
    }
}

// MARK: - Input Sanitizer

enum InputSanitizer {

    /// Sanitize user input before sending to external APIs (AI, search, etc.)
    static func sanitizeForAPI(_ input: String) -> String {
        var sanitized = input
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Limit length to prevent abuse
        if sanitized.count > 2000 {
            sanitized = String(sanitized.prefix(2000))
        }

        // Remove potential control characters
        sanitized = sanitized.unicodeScalars
            .filter { !$0.properties.isDefaultIgnorableCodePoint && ($0.value >= 32 || $0 == "\n" || $0 == "\t") }
            .map { String($0) }
            .joined()

        return sanitized
    }

    /// Sanitize search query input
    static func sanitizeSearchQuery(_ query: String) -> String {
        let sanitized = query
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Limit search query length
        guard sanitized.count <= 100 else {
            return String(sanitized.prefix(100))
        }

        return sanitized
    }

    /// Sanitize symbol input (only allow alphanumeric and common symbol chars)
    static func sanitizeSymbol(_ symbol: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-^"))
        return String(symbol.unicodeScalars.filter { allowed.contains($0) })
            .prefix(10)
            .uppercased()
    }
}
