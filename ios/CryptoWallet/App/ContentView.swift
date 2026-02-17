import SwiftUI

struct ContentView: View {
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var walletService: WalletService

    var body: some View {
        Group {
            if router.isOnboarded {
                TabBarView()
            } else {
                WelcomeView()
            }
        }
        .animation(.easeInOut, value: router.isOnboarded)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppRouter())
        .environmentObject(WalletService.shared)
}
