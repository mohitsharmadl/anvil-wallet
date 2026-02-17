import SwiftUI

// MARK: - Keyboard Dismissal

extension View {
    /// Adds a tap gesture to dismiss the keyboard.
    func hideKeyboard() -> some View {
        self.onTapGesture {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil,
                from: nil,
                for: nil
            )
        }
    }
}

// MARK: - Custom Corner Radius

/// Shape that allows rounding only specific corners.
struct RoundedCornerShape: Shape {
    var radius: CGFloat
    var corners: UIRectCorner

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

extension View {
    /// Applies a corner radius to specific corners.
    ///
    /// - Parameters:
    ///   - radius: The corner radius
    ///   - corners: Which corners to round (e.g., [.topLeft, .topRight])
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCornerShape(radius: radius, corners: corners))
    }
}

// MARK: - Card Style

extension View {
    /// Applies a standard card style with rounded corners and background.
    func cardStyle() -> some View {
        self
            .padding()
            .background(Color.backgroundCard)
            .cornerRadius(16)
    }

    /// Applies a bordered card style.
    func borderedCardStyle() -> some View {
        self
            .padding()
            .background(Color.backgroundCard)
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.border, lineWidth: 1)
            )
    }
}

// MARK: - Primary Button Style

struct PrimaryButtonStyle: ButtonStyle {
    var isEnabled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                isEnabled
                    ? (configuration.isPressed ? Color.accentGreenDark : Color.accentGreen)
                    : Color.textTertiary
            )
            .cornerRadius(12)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundColor(Color.accentGreen)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color.accentGreen.opacity(0.1))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentGreen.opacity(0.3), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

// MARK: - Conditional Modifier

extension View {
    /// Applies a modifier only when a condition is true.
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

// MARK: - Loading Overlay

struct LoadingOverlay: ViewModifier {
    let isLoading: Bool
    let message: String

    func body(content: Content) -> some View {
        content
            .overlay(
                Group {
                    if isLoading {
                        ZStack {
                            Color.black.opacity(0.5)
                                .ignoresSafeArea()

                            VStack(spacing: 16) {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(1.5)

                                Text(message)
                                    .font(.subheadline)
                                    .foregroundColor(.white)
                            }
                            .padding(32)
                            .background(Color.backgroundElevated)
                            .cornerRadius(16)
                        }
                    }
                }
            )
    }
}

extension View {
    /// Shows a loading overlay with a spinner and message.
    func loadingOverlay(isLoading: Bool, message: String = "Loading...") -> some View {
        modifier(LoadingOverlay(isLoading: isLoading, message: message))
    }
}
