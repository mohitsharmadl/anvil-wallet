import UIKit

/// Centralized haptic feedback service for consistent tactile responses.
///
/// Wraps UIKit feedback generators with semantic methods so call sites
/// read clearly: `Haptic.impact(.light)`, `Haptic.success()`, etc.
enum Haptic {

    // MARK: - Impact

    /// Triggers an impact haptic at the given style (light, medium, heavy, rigid, soft).
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }

    // MARK: - Notification

    /// Triggers a success notification haptic.
    static func success() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
    }

    /// Triggers a warning notification haptic.
    static func warning() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.warning)
    }

    /// Triggers an error notification haptic.
    static func error() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.error)
    }

    // MARK: - Selection

    /// Triggers a light selection tap (e.g. segment picker changes).
    static func selection() {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }
}
