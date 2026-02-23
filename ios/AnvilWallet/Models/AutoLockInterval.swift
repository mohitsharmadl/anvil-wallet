import Foundation

/// Configurable auto-lock timeout intervals. Persisted via UserDefaults.
enum AutoLockInterval: String, CaseIterable {
    case immediately = "Immediately"
    case oneMinute = "1 minute"
    case fiveMinutes = "5 minutes"
    case fifteenMinutes = "15 minutes"
    case never = "Never"

    var seconds: TimeInterval {
        switch self {
        case .immediately: return 0
        case .oneMinute: return 60
        case .fiveMinutes: return 300
        case .fifteenMinutes: return 900
        case .never: return -1 // negative means never lock
        }
    }
}
