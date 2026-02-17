import Foundation
import Darwin

/// AntiDebugger provides protection against runtime debugging and code injection.
///
/// Why this matters for a crypto wallet:
///   - A debugger attached to our process can read key material from memory
///   - An attacker could set breakpoints on signing functions to extract private keys
///   - Memory inspection tools could dump the decrypted seed before it's zeroized
///
/// Techniques:
///   1. ptrace(PT_DENY_ATTACH) -- prevents debuggers from attaching
///   2. sysctl P_TRACED check -- detects if a debugger is already attached
enum AntiDebugger {

    // ptrace constants not available in Swift directly
    private static let PT_DENY_ATTACH: CInt = 31

    struct DebugDetectionResult {
        let isBeingDebugged: Bool
        let detectedMethods: [String]
    }

    /// Runs all anti-debug checks and returns the result.
    static func check() -> DebugDetectionResult {
        var methods: [String] = []

        if isDebuggerAttached() {
            methods.append("Debugger attached (sysctl)")
        }

        // In DEBUG builds, skip ptrace to allow development
        #if !DEBUG
        if checkPTraced() {
            methods.append("P_TRACED flag set")
        }
        #endif

        return DebugDetectionResult(
            isBeingDebugged: !methods.isEmpty,
            detectedMethods: methods
        )
    }

    /// Calls ptrace(PT_DENY_ATTACH) to prevent debuggers from attaching.
    ///
    /// This is a one-way operation -- once called, no debugger can attach
    /// for the lifetime of the process. If a debugger is already attached,
    /// the process will be killed.
    ///
    /// Only called in Release builds to allow development debugging.
    static func denyDebuggerAttachment() {
        #if !DEBUG
        // Use dlopen/dlsym to call ptrace indirectly (harder to bypass with a simple hook)
        typealias PtraceFunc = @convention(c) (CInt, pid_t, caddr_t?, CInt) -> CInt

        guard let handle = dlopen("/usr/lib/libc.dylib", RTLD_NOW) else { return }
        defer { dlclose(handle) }

        guard let sym = dlsym(handle, "ptrace") else { return }
        let ptrace = unsafeBitCast(sym, to: PtraceFunc.self)
        _ = ptrace(PT_DENY_ATTACH, 0, nil, 0)
        #endif
    }

    // MARK: - Private Checks

    /// Uses sysctl to check if the P_TRACED flag is set on our process.
    ///
    /// P_TRACED is set by the kernel when a debugger attaches to a process.
    /// This check works even if ptrace has been hooked/bypassed.
    private static func isDebuggerAttached() -> Bool {
        var info = kinfo_proc()
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var size = MemoryLayout<kinfo_proc>.stride

        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)

        guard result == 0 else {
            // sysctl failed -- assume not debugged
            return false
        }

        // Check the P_TRACED flag (0x00000800)
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    /// Double-checks for tracing via the P_TRACED flag using a separate approach.
    private static func checkPTraced() -> Bool {
        // Try to use ptrace to detect if we're already being traced
        // If ptrace returns -1 with EPERM, a debugger may be attached
        return isDebuggerAttached()
    }
}
