import SwiftUI
import UIKit

/// ScreenshotProtection prevents sensitive wallet data from being captured
/// in screenshots or the app switcher thumbnail.
///
/// Two protection mechanisms:
///   1. UITextField `isSecureTextEntry` overlay trick:
///      When a UITextField has isSecureTextEntry=true, iOS prevents its contents
///      from appearing in screenshots. We overlay a transparent secure text field
///      on top of sensitive content to inherit this protection.
///
///   2. Background blur:
///      When the app moves to background (app switcher), we overlay a blur
///      to prevent the app snapshot from showing sensitive data.
final class ScreenshotProtection: ObservableObject {

    static let shared = ScreenshotProtection()

    @Published var isAppInBackground = false

    private init() {
        setupNotifications()
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isAppInBackground = true
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isAppInBackground = false
        }

        // Detect screenshots
        NotificationCenter.default.addObserver(
            forName: UIApplication.userDidTakeScreenshotNotification,
            object: nil,
            queue: .main
        ) { _ in
            // Log the event -- in production, could show a warning
            print("[Security] Screenshot detected")
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Secure Text Field (Screenshot Protection)

/// A UIViewRepresentable that creates an invisible secure text field.
/// When layered on top of content, it prevents that content from appearing
/// in screenshots and screen recordings.
struct SecureScreenView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let secureField = UITextField()
        secureField.isSecureTextEntry = true
        secureField.isUserInteractionEnabled = false

        // Make the text field invisible but active for screenshot protection
        let containerView = UIView()
        containerView.addSubview(secureField)
        secureField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            secureField.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            secureField.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            secureField.topAnchor.constraint(equalTo: containerView.topAnchor),
            secureField.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])

        // Get the secure container layer from the text field
        if let secureLayer = secureField.layer.sublayers?.first {
            containerView.layer.addSublayer(secureLayer)
        }

        return containerView
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - View Modifiers

/// Modifier that adds screenshot protection to a view.
struct ScreenshotProtectionModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .overlay(
                SecureScreenView()
                    .allowsHitTesting(false)
            )
    }
}

/// Modifier that blurs content when the app is in background.
struct BackgroundBlurModifier: ViewModifier {
    @ObservedObject private var protection = ScreenshotProtection.shared

    func body(content: Content) -> some View {
        content
            .overlay(
                Group {
                    if protection.isAppInBackground {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .ignoresSafeArea()
                            .transition(.opacity)
                    }
                }
            )
            .animation(.easeInOut(duration: 0.2), value: protection.isAppInBackground)
    }
}

extension View {
    /// Prevents the content of this view from appearing in screenshots.
    func screenshotProtected() -> some View {
        modifier(ScreenshotProtectionModifier())
    }

    /// Blurs this view when the app enters the background (app switcher).
    func blurOnBackground() -> some View {
        modifier(BackgroundBlurModifier())
    }
}
