import SwiftUI

@main
struct AnvilWalletApp: App {
    @StateObject private var router = AppRouter()
    @StateObject private var walletService = WalletService.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        SecurityBootstrap.performChecks()

        // Initialize WalletConnect (Reown SDK)
        // Project ID is injected via Secrets.xcconfig → Info.plist at build time.
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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(router)
                .environmentObject(walletService)
                .preferredColorScheme(.dark)
                .onAppear {
                    router.isOnboarded = walletService.isWalletCreated
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
                    // interval < 0 means "never" — don't clear
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
