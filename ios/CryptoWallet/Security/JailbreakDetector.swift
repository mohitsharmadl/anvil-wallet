import Foundation
import UIKit
import MachO

/// JailbreakDetector performs a 6-layer jailbreak detection check.
///
/// A jailbroken device has a compromised security model -- an attacker could:
///   - Hook into our process and intercept key material
///   - Read Keychain items outside the app sandbox
///   - Inject malicious dylibs to modify wallet behavior
///   - Disable Secure Enclave biometric requirements
///
/// We check for jailbreak indicators and warn the user, but allow them
/// to proceed (some legitimate users have jailbroken devices for research).
enum JailbreakDetector {

    struct DetectionResult {
        let isJailbroken: Bool
        let detectedIndicators: [String]
    }

    /// Runs all 6 layers of jailbreak detection.
    ///
    /// - Returns: DetectionResult with overall status and which checks triggered
    static func check() -> DetectionResult {
        var indicators: [String] = []

        // Layer 1: Check for jailbreak-related files
        if checkJailbreakFiles() {
            indicators.append("Jailbreak files detected")
        }

        // Layer 2: Check for suspicious symbolic links
        if checkSuspiciousSymlinks() {
            indicators.append("Suspicious symlinks detected")
        }

        // Layer 3: Check write access to protected paths
        if checkWriteAccess() {
            indicators.append("Write access to protected paths")
        }

        // Layer 4: Check for suspicious dyld images
        if checkSuspiciousDyldImages() {
            indicators.append("Suspicious dyld images loaded")
        }

        // Layer 5: Check fork() behavior
        if checkForkBehavior() {
            indicators.append("fork() succeeded (should fail in sandbox)")
        }

        // Layer 6: Check for Cydia URL scheme
        if checkCydiaURLScheme() {
            indicators.append("Cydia URL scheme available")
        }

        return DetectionResult(
            isJailbroken: !indicators.isEmpty,
            detectedIndicators: indicators
        )
    }

    // MARK: - Layer 1: Jailbreak Files

    /// Checks for the presence of common jailbreak files and directories.
    private static func checkJailbreakFiles() -> Bool {
        let suspiciousPaths = [
            "/Applications/Cydia.app",
            "/Applications/Sileo.app",
            "/Applications/Zebra.app",
            "/Applications/FlyJB.app",
            "/Applications/Substitute.app",
            "/Library/MobileSubstrate/MobileSubstrate.dylib",
            "/Library/MobileSubstrate/DynamicLibraries",
            "/usr/sbin/sshd",
            "/usr/bin/sshd",
            "/usr/libexec/sftp-server",
            "/etc/apt",
            "/etc/apt/sources.list.d/",
            "/private/var/lib/apt/",
            "/private/var/lib/cydia",
            "/private/var/mobile/Library/SBSettings/Themes",
            "/private/var/stash",
            "/private/var/tmp/cydia.log",
            "/var/cache/apt",
            "/var/lib/apt",
            "/var/log/syslog",
            "/bin/bash",
            "/bin/sh",
            "/usr/sbin/frida-server",
            "/usr/bin/cycript",
            "/usr/local/bin/cycript",
            "/usr/lib/libcycript.dylib",
            "/var/binpack",
            "/var/checkra1n.dmg",
        ]

        for path in suspiciousPaths {
            if FileManager.default.fileExists(atPath: path) {
                return true
            }
        }

        return false
    }

    // MARK: - Layer 2: Suspicious Symlinks

    /// Checks for suspicious symbolic links that are common on jailbroken devices.
    /// Jailbreaks often create symlinks to move system files around.
    private static func checkSuspiciousSymlinks() -> Bool {
        let symlinkPaths = [
            "/var/lib/undecimus/apt",
            "/Applications",
            "/Library/Ringtones",
            "/Library/Wallpaper",
            "/usr/arm-apple-darwin9",
            "/usr/include",
            "/usr/libexec",
            "/usr/share",
        ]

        for path in symlinkPaths {
            var isSymlink = ObjCBool(false)
            if FileManager.default.fileExists(atPath: path, isDirectory: &isSymlink) {
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: path)
                    if let fileType = attributes[.type] as? FileAttributeType,
                       fileType == .typeSymbolicLink {
                        return true
                    }
                } catch {
                    continue
                }
            }
        }

        return false
    }

    // MARK: - Layer 3: Write Access

    /// Attempts to write to a protected directory.
    /// On a non-jailbroken device, this should always fail due to the sandbox.
    private static func checkWriteAccess() -> Bool {
        let testPath = "/private/jailbreak_test_\(UUID().uuidString)"

        do {
            try "test".write(toFile: testPath, atomically: true, encoding: .utf8)
            // If we got here, the write succeeded -- device is jailbroken
            try? FileManager.default.removeItem(atPath: testPath)
            return true
        } catch {
            // Write failed (expected on non-jailbroken)
            return false
        }
    }

    // MARK: - Layer 4: Suspicious Dyld Images

    /// Checks loaded dynamic libraries for known jailbreak-related frameworks.
    private static func checkSuspiciousDyldImages() -> Bool {
        let suspiciousLibraries = [
            "SubstrateLoader",
            "MobileSubstrate",
            "TweakInject",
            "libhooker",
            "substitute",
            "Cephei",
            "FridaGadget",
            "frida-agent",
            "cynject",
            "libcycript",
            "SSLKillSwitch",
            "SSLKillSwitch2",
            "FlyJB",
        ]

        let imageCount = _dyld_image_count()
        for i in 0..<imageCount {
            guard let imageName = _dyld_get_image_name(i) else { continue }
            let name = String(cString: imageName)

            for suspicious in suspiciousLibraries {
                if name.lowercased().contains(suspicious.lowercased()) {
                    return true
                }
            }
        }

        return false
    }

    // MARK: - Layer 5: Fork Behavior

    /// Attempts to call fork(). On a non-jailbroken device, fork() should fail
    /// because the app sandbox restricts process creation.
    private static func checkForkBehavior() -> Bool {
        let pid = fork()
        if pid >= 0 {
            // fork() succeeded -- device is likely jailbroken
            if pid > 0 {
                // We're in the parent; kill the child process
                kill(pid, SIGTERM)
            }
            return true
        }
        // fork() failed (expected on non-jailbroken)
        return false
    }

    // MARK: - Layer 6: Cydia URL Scheme

    /// Checks if the Cydia URL scheme is registered, indicating Cydia is installed.
    @MainActor
    private static func checkCydiaURLScheme() -> Bool {
        guard let url = URL(string: "cydia://package/com.example.package") else {
            return false
        }
        return UIApplication.shared.canOpenURL(url)
    }
}
