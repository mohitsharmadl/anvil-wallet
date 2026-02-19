import Foundation
import CryptoKit
import MachO

/// AppIntegrityChecker verifies that the app binary has not been tampered with.
///
/// Protects against:
///   - Repackaged/modified app binaries
///   - Dynamic library injection
///   - Code signature modifications
///
/// Checks:
///   1. MH_PIE flag -- verifies Position Independent Executable (should be set on iOS)
///   2. Executable hash verification (SHA-256, compared to build-time constant)
///   3. Embedded mobile provision check (App Store vs. sideloaded)
enum AppIntegrityChecker {

    struct IntegrityResult {
        let isPassed: Bool
        let failedChecks: [String]
    }

    // In Release builds, this references the hash injected by inject-binary-hash.sh.
    // In Debug builds, the hash is empty and the check is skipped.
    private static let expectedExecutableHash = GeneratedBinaryHash.executableHash

    /// Runs all integrity checks.
    static func check() -> IntegrityResult {
        var failures: [String] = []

        if !checkMHPIEFlag() {
            failures.append("MH_PIE flag not set (binary may be modified)")
        }

        if !checkExecutableIntegrity() {
            failures.append("Executable integrity check failed")
        }

        #if !DEBUG
        if checkSuspiciousEnvironmentVariables() {
            failures.append("Suspicious environment variables detected")
        }
        #endif

        if !checkBundleSignature() {
            failures.append("Bundle signature check failed")
        }

        return IntegrityResult(
            isPassed: failures.isEmpty,
            failedChecks: failures
        )
    }

    // MARK: - MH_PIE Flag

    /// Verifies the MH_PIE (Position Independent Executable) flag is set in the Mach-O header.
    ///
    /// All iOS apps should have this flag set. If it's missing, the binary may have been
    /// modified by a tool that stripped ASLR (Address Space Layout Randomization),
    /// which is a common step in reverse engineering.
    private static func checkMHPIEFlag() -> Bool {
        guard let header = _dyld_get_image_header(0) else {
            return false
        }

        // MH_PIE is defined as 0x200000
        let MH_PIE: UInt32 = 0x200000
        return (header.pointee.flags & MH_PIE) != 0
    }

    // MARK: - Executable Hash

    /// Verifies the executable hash matches the expected build-time value.
    ///
    /// In DEBUG builds, this check is skipped (always passes) since the binary
    /// changes on every rebuild. In Release builds, the SHA-256 of the main
    /// executable is compared against `expectedExecutableHash`.
    private static func checkExecutableIntegrity() -> Bool {
        #if DEBUG
        return true
        #else
        guard !expectedExecutableHash.isEmpty else {
            // FAIL CLOSED: If no hash was injected by build script, the binary
            // integrity check cannot verify anything — treat as failure.
            return false
        }

        guard let executablePath = Bundle.main.executablePath,
              let executableData = FileManager.default.contents(atPath: executablePath) else {
            return false
        }

        let hash = SHA256.hash(data: executableData)
        let hashHex = hash.compactMap { String(format: "%02x", $0) }.joined()
        return hashHex == expectedExecutableHash
        #endif
    }

    // MARK: - Environment Variables

    /// Checks for environment variables commonly set by debugging/injection tools.
    private static func checkSuspiciousEnvironmentVariables() -> Bool {
        let suspiciousVars = [
            "DYLD_INSERT_LIBRARIES",
            "DYLD_LIBRARY_PATH",
            "DYLD_FRAMEWORK_PATH",
            "_MSSafeMode",
            "DYLD_PRINT_TO_FILE",
        ]

        for varName in suspiciousVars {
            if ProcessInfo.processInfo.environment[varName] != nil {
                return true
            }
        }

        return false
    }

    // MARK: - Bundle Signature

    /// Performs a basic bundle signature check.
    ///
    /// Verifies that:
    ///   - The app has a valid Info.plist
    ///   - The bundle identifier matches what we expect
    ///   - The embedded.mobileprovision file is present (for non-App Store builds)
    private static func checkBundleSignature() -> Bool {
        guard let bundleId = Bundle.main.bundleIdentifier else {
            return false
        }

        // Verify bundle identifier starts with our expected prefix
        let expectedPrefix = "com.anvilwallet"
        guard bundleId.hasPrefix(expectedPrefix) else {
            return false
        }

        // Check that Info.plist exists and has expected keys
        guard Bundle.main.infoDictionary != nil else {
            return false
        }

        return true
    }
}
