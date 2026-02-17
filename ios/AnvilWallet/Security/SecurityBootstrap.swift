import SwiftUI
import os.log

/// SecurityBootstrap runs all security checks at app launch.
///
/// Called from CryptoWalletApp.init() before any UI is displayed.
/// On failure, the app can either:
///   - Show a warning and let the user proceed (current behavior)
///   - Force quit the app (uncomment exit(0) for production)
///
/// The checks are intentionally non-blocking to avoid false positives
/// on legitimate devices. Each check logs its result for diagnostics.
enum SecurityBootstrap {

    private static let logger = Logger(subsystem: "com.anvilwallet", category: "Security")

    /// Shared state for UI to read check results
    @MainActor
    static var jailbreakDetected = false

    @MainActor
    static var debuggerDetected = false

    @MainActor
    static var integrityFailed = false

    @MainActor
    static var securityWarningMessage: String?

    /// Performs all security checks at launch. Called from CryptoWalletApp.init().
    ///
    /// Check order:
    ///   1. Anti-debugger: deny attachment first (before anything else happens)
    ///   2. Jailbreak detection: 6-layer check
    ///   3. App integrity: binary verification
    ///
    /// Results are stored in static properties for the UI layer to read.
    @MainActor
    static func performChecks() {
        logger.info("Starting security checks...")

        // 1. Anti-debugger: call ptrace(PT_DENY_ATTACH) immediately
        AntiDebugger.denyDebuggerAttachment()

        let debugResult = AntiDebugger.check()
        if debugResult.isBeingDebugged {
            logger.warning("Debugger detected: \(debugResult.detectedMethods.joined(separator: ", "))")
            debuggerDetected = true
        } else {
            logger.info("Anti-debugger check passed")
        }

        // 2. Jailbreak detection
        let jailbreakResult = JailbreakDetector.check()
        if jailbreakResult.isJailbroken {
            logger.warning("Jailbreak detected: \(jailbreakResult.detectedIndicators.joined(separator: ", "))")
            jailbreakDetected = true
        } else {
            logger.info("Jailbreak check passed")
        }

        // 3. App integrity
        let integrityResult = AppIntegrityChecker.check()
        if !integrityResult.isPassed {
            logger.warning("Integrity check failed: \(integrityResult.failedChecks.joined(separator: ", "))")
            integrityFailed = true
        } else {
            logger.info("App integrity check passed")
        }

        // Build warning message if any checks failed
        if jailbreakDetected || debuggerDetected || integrityFailed {
            var warnings: [String] = []

            if jailbreakDetected {
                warnings.append("This device appears to be jailbroken. Your wallet security may be compromised.")
            }
            if debuggerDetected {
                warnings.append("A debugger was detected. This could indicate a security threat.")
            }
            if integrityFailed {
                warnings.append("App integrity check failed. The app may have been modified.")
            }

            securityWarningMessage = warnings.joined(separator: "\n\n")

            logger.error("Security checks completed with warnings")

            #if !DEBUG
            if integrityFailed {
                exit(0)
            }
            #endif
        } else {
            logger.info("All security checks passed")
        }
    }
}

// MARK: - Security Warning View

/// A view that displays security warnings if any checks failed.
/// Should be shown as a sheet/alert from the root view.
struct SecurityWarningView: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 64))
                .foregroundColor(.red)

            Text("Security Warning")
                .font(.title.bold())
                .foregroundColor(.white)

            Text(message)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Text("Your funds may be at risk. We strongly recommend using a non-jailbroken device.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button(action: onDismiss) {
                Text("I Understand the Risks")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red.opacity(0.8))
                    .cornerRadius(12)
            }
            .padding(.horizontal)
        }
        .padding()
        .background(Color.backgroundPrimary)
    }
}
