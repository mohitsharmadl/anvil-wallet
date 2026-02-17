import SwiftUI

struct TabBarView: View {
    @EnvironmentObject var router: AppRouter

    var body: some View {
        TabView(selection: $router.selectedTab) {
            WalletHomeView()
                .tabItem {
                    Label("Wallet", systemImage: "wallet.pass.fill")
                }
                .tag(AppRouter.Tab.wallet)

            SendView()
                .tabItem {
                    Label("Send", systemImage: "paperplane.fill")
                }
                .tag(AppRouter.Tab.send)

            DAppsView()
                .tabItem {
                    Label("DApps", systemImage: "globe")
                }
                .tag(AppRouter.Tab.dapps)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(AppRouter.Tab.settings)
        }
        .tint(Color.accentGreen)
    }
}

#Preview {
    TabBarView()
        .environmentObject(AppRouter())
        .environmentObject(WalletService.shared)
}
