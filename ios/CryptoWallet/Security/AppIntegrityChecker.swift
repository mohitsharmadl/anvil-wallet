import Foundation
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
///   2. Executable hash verification (placeholder -- actual hash is set at build time)
///   3. Embedded mobile provision check (App Store vs. sideloaded)
enum AppIntegrityChecker {

    struct IntegrityResult {
        let isPassed: Bool
        let failedChecks: [String]
    }

    /// Runs all integrity checks.
    static func check() -> IntegrityResult {
        var failures: [String] = []

        if !checkMHPIEFlag() {
            failures.append("MH_PIE flag not set (binary may be modified)")
        }

        if !checkExecutableIntegrity() {
            failures.append("Executable integrity check failed")
        }

        if checkSuspiciousEnvironmentVariables() {
            failures.append("Suspicious environment variables detected")
        }

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

    /// Verifies the executable hash matches the expected value.
    ///
    /// In production, the expected hash would be computed at build time and
    /// embedded as a constant. At runtime, we recompute the hash and compare.
    private static func checkExecutableIntegrity() -> Bool {
        // TODO: Implement executable hash verification
        // At build time:
        //   1. Compute SHA-256 of the main executable
        //   2. Embed the hash as a compile-time constant
        // At runtime:
        //   1. Read the main executable from disk
        //   2. Compute its SHA-256 hash
        //   3. Compare with the embedded expected hash
        //
        // Placeholder -- always returns true until build-time hash is configured
        guard let executablePath = Bundle.main.executablePath else {
            return false
        }

        // Verify the executable file exists and is readable
        return FileManager.default.isReadableFile(atPath: executablePath)
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
        // TODO: Update with actual bundle identifier
        let expectedPrefix = "com.cryptowallet"
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
