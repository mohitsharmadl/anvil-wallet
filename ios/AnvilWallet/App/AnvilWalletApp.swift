import SwiftUI

// MARK: - App Theme

/// User-selectable appearance theme. Persisted via @AppStorage.
enum AppTheme: String, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil      // Follow device setting
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@main
struct AnvilWalletApp: App {
    @StateObject private var router = AppRouter()
    @StateObject private var walletService = WalletService.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appTheme") private var appTheme = AppTheme.system

    init() {
        SecurityBootstrap.performChecks()

        // Initialize WalletConnect (Reown SDK)
        // Project ID is injected via Secrets.xcconfig -> Info.plist at build time.
        // See ios/Secrets.xcconfig.example for setup instructions.
        let projectId = Bundle.main.object(forInfoDictionaryKey: "ReownProjectID") as? String ?? ""
        #if !DEBUG
        if projectId.isEmpty || projectId == "YOUR_REOWN_PROJECT_ID" {
            fatalError("Ship blocker: set REOWN_PROJECT_ID in ios/Secrets.xcconfig (see Secrets.xcconfig.example)")
        }
        #endif
        WalletConnectService.shared.configure(projectId: projectId)
    }

    @State private var backgroundedAt: Date?
    @State private var showSecurityWarning = false
    @State private var securityWarningDismissed = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(router)
                .environmentObject(walletService)
                .preferredColorScheme(appTheme.colorScheme)
                .onAppear {
                    router.isOnboarded = walletService.isWalletCreated
                    // Show security warning sheet if any checks failed
                    if SecurityBootstrap.securityWarningMessage != nil && !securityWarningDismissed {
                        showSecurityWarning = true
                    }
                }
                .sheet(isPresented: $showSecurityWarning) {
                    if let message = SecurityBootstrap.securityWarningMessage {
                        SecurityWarningView(message: message) {
                            securityWarningDismissed = true
                            showSecurityWarning = false
                        }
                        .interactiveDismissDisabled() // Force user to tap "I Understand"
                    }
                }
                .task {
                    guard walletService.isWalletCreated else { return }
                    try? await walletService.refreshBalances()
                    try? await walletService.refreshPrices()
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                backgroundedAt = Date()
            case .active:
                if let backgroundedAt {
                    let elapsed = Date().timeIntervalSince(backgroundedAt)
                    let interval = autoLockSeconds
                    if interval >= 0, elapsed >= interval {
                        walletService.clearSessionPassword()
                    }
                    // interval < 0 means "never" -- don't clear
                }
                self.backgroundedAt = nil
            default:
                break
            }
        }
    }

    private var autoLockSeconds: TimeInterval {
        let raw = UserDefaults.standard.string(forKey: "autoLockInterval") ?? AutoLockInterval.fiveMinutes.rawValue
        return (AutoLockInterval(rawValue: raw) ?? .fiveMinutes).seconds
    }
}
