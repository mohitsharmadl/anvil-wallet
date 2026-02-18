import SwiftUI

@main
struct AnvilWalletApp: App {
    @StateObject private var router = AppRouter()
    @StateObject private var walletService = WalletService.shared
    @Environment(\.scenePhase) private var scenePhase

    private static let reownProjectId = "YOUR_REOWN_PROJECT_ID"

    init() {
        SecurityBootstrap.performChecks()

        // Initialize WalletConnect (Reown SDK)
        // Replace with your Reown project ID from https://cloud.reown.com
        #if !DEBUG
        if Self.reownProjectId == "YOUR_REOWN_PROJECT_ID" {
            fatalError("Ship blocker: replace YOUR_REOWN_PROJECT_ID with a real Reown project ID")
        }
        #endif
        WalletConnectService.shared.configure(projectId: Self.reownProjectId)
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
