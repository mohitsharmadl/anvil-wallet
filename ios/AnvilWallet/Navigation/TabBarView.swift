import SwiftUI

struct TabBarView: View {
    @EnvironmentObject var router: AppRouter

    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some View {
        TabView(selection: $router.selectedTab) {
            WalletHomeView()
                .tabItem {
                    Label("Wallet", systemImage: "creditcard.fill")
                }
                .tag(AppRouter.Tab.wallet)

            SendView()
                .tabItem {
                    Label("Send", systemImage: "arrow.up.right")
                }
                .tag(AppRouter.Tab.send)

            DAppsView()
                .tabItem {
                    Label("DApps", systemImage: "square.grid.2x2.fill")
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
