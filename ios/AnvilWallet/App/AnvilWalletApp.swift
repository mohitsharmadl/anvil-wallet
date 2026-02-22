import SwiftUI
import UserNotifications

// MARK: - Notification Delegate

/// Handles notification delivery when the app is in the foreground,
/// and notification tap actions.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    /// Called when a notification arrives while the app is in the foreground.
    /// We show it as a banner so the user sees it even while using the app.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Called when the user taps on a notification.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Navigate to activity/notifications by posting to the router.
        // The app picks this up in onAppear/onChange as needed.
        NotificationCenter.default.post(name: .didTapNotification, object: nil)
        completionHandler()
    }
}

extension Notification.Name {
    static let didTapNotification = Notification.Name("com.anvilwallet.didTapNotification")
}

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
    @StateObject private var securityService = SecurityService.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appTheme") private var appTheme = AppTheme.system

    init() {
        SecurityBootstrap.performChecks()

        // Register notification delegate for foreground delivery and tap handling
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared

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
    @State private var inactivatedAt: Date?
    @State private var showSecurityWarning = false
    @State private var securityWarningDismissed = false
    @State private var showSessionUnlock = false
    @State private var unlockPassword = ""
    @State private var unlockError: String?
    @State private var isUnlocking = false

    var body: some Scene {
        WindowGroup {
            ZStack {
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
                    .onReceive(NotificationCenter.default.publisher(for: .didTapNotification)) { _ in
                        // Navigate to wallet tab -> notifications when a notification is tapped
                        guard router.isOnboarded else { return }
                        router.selectedTab = .wallet
                        router.walletPath.append(AppRouter.WalletDestination.notifications)
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

                        // Request notification permissions if wallet exists and not yet asked
                        await NotificationService.shared.requestPermission()
                    }

                // Screen protection blur overlay for app switcher
                if securityService.isScreenProtectionActive {
                    Rectangle()
                        .fill(Color.backgroundPrimary)
                        .ignoresSafeArea()
                }

                if showSessionUnlock {
                    Rectangle()
                        .fill(Color.backgroundPrimary.opacity(0.96))
                        .ignoresSafeArea()

                    SessionUnlockOverlay(
                        password: $unlockPassword,
                        errorMessage: $unlockError,
                        isUnlocking: $isUnlocking
                    ) {
                        await unlockSession()
                    }
                    .padding(24)
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .inactive:
                // iOS captures app-switcher snapshots during the inactive transition.
                inactivatedAt = Date()
                securityService.activateScreenProtection()
            case .background:
                backgroundedAt = Date()
                securityService.activateScreenProtection()
            case .active:
                securityService.deactivateScreenProtection()
                if let leftAppAt = backgroundedAt ?? inactivatedAt {
                    let elapsed = Date().timeIntervalSince(leftAppAt)
                    let interval = autoLockSeconds
                    if interval >= 0, elapsed >= interval {
                        walletService.clearSessionPassword()
                        if walletService.isWalletCreated {
                            showSessionUnlock = true
                            unlockPassword = ""
                            unlockError = nil
                        }
                    }
                    // interval < 0 means "never" -- don't clear
                }
                self.backgroundedAt = nil
                self.inactivatedAt = nil
            default:
                break
            }
        }
    }

    private var autoLockSeconds: TimeInterval {
        let raw = UserDefaults.standard.string(forKey: "autoLockInterval") ?? AutoLockInterval.fiveMinutes.rawValue
        return (AutoLockInterval(rawValue: raw) ?? .fiveMinutes).seconds
    }

    private func unlockSession() async {
        await MainActor.run {
            isUnlocking = true
            unlockError = nil
        }
        do {
            try await walletService.setSessionPassword(unlockPassword)
            await MainActor.run {
                isUnlocking = false
                showSessionUnlock = false
                unlockPassword = ""
                unlockError = nil
            }
        } catch {
            await MainActor.run {
                isUnlocking = false
                unlockError = "Incorrect password. Please try again."
            }
        }
    }
}

private struct SessionUnlockOverlay: View {
    @Binding var password: String
    @Binding var errorMessage: String?
    @Binding var isUnlocking: Bool
    let onUnlock: () async -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.circle.fill")
                .font(.system(size: 52))
                .foregroundColor(.accentGreen)

            Text("Session Locked")
                .font(.title3.bold())
                .foregroundColor(.textPrimary)

            Text("Re-enter your wallet password to continue.")
                .font(.body)
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)

            SecureField("Password", text: $password)
                .font(.body)
                .padding(12)
                .background(Color.backgroundCard)
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(errorMessage != nil ? Color.error : Color.border, lineWidth: 1)
                )

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.error)
            }

            Button {
                Task { await onUnlock() }
            } label: {
                if isUnlocking {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text("Unlock")
                }
            }
            .buttonStyle(PrimaryButtonStyle(isEnabled: !password.isEmpty))
            .disabled(password.isEmpty || isUnlocking)
        }
        .padding(24)
        .background(Color.backgroundCard)
        .cornerRadius(16)
    }
}
