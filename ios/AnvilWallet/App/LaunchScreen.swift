import SwiftUI

/// A minimal SwiftUI launch screen shown while the app loads.
///
/// Mirrors the WelcomeView branding (shield icon + "Anvil" wordmark)
/// so the transition from launch to content feels seamless.
struct LaunchScreen: View {
    var body: some View {
        ZStack {
            Color.backgroundPrimary
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "shield.checkered")
                    .font(.system(size: 72, weight: .medium))
                    .foregroundColor(.accentGreen)

                Text("Anvil")
                    .font(.largeTitle.bold())
                    .foregroundColor(.textPrimary)
            }
        }
    }
}

#Preview {
    LaunchScreen()
}
