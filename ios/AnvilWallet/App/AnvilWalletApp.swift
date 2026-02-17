import SwiftUI

@main
struct AnvilWalletApp: App {
    @StateObject private var router = AppRouter()
    @StateObject private var walletService = WalletService.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        SecurityBootstrap.performChecks()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(router)
                .environmentObject(walletService)
                .preferredColorScheme(.dark)
                .onAppear {
                    router.isOnboarded = walletService.isWalletCreated
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                walletService.clearSessionPassword()
            }
        }
    }
}
