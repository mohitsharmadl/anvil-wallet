import SwiftUI
import UIKit

/// Theme color definitions for the CryptoWallet app.
///
/// Design system:
///   - Adaptive backgrounds that respond to light/dark mode
///   - Emerald green accent for CTAs and highlights
///   - Adaptive text colors for readability in both modes
///   - Semantic colors for success, warning, error states
extension Color {

    // MARK: - Adaptive Color Helper

    /// Creates a color that adapts between light and dark mode.
    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }

    // MARK: - Background Colors

    /// Primary background
    static let backgroundPrimary = adaptive(
        light: UIColor(red: 0.969, green: 0.969, blue: 0.980, alpha: 1),
        dark: UIColor(red: 0.051, green: 0.067, blue: 0.090, alpha: 1)
    )

    /// Secondary background
    static let backgroundSecondary = adaptive(
        light: UIColor(red: 0.949, green: 0.949, blue: 0.969, alpha: 1),
        dark: UIColor(red: 0.086, green: 0.106, blue: 0.133, alpha: 1)
    )

    /// Card/surface background
    static let backgroundCard = adaptive(
        light: UIColor.white,
        dark: UIColor(red: 0.110, green: 0.129, blue: 0.157, alpha: 1)
    )

    /// Elevated surface
    static let backgroundElevated = adaptive(
        light: UIColor(red: 0.961, green: 0.961, blue: 0.976, alpha: 1),
        dark: UIColor(red: 0.129, green: 0.149, blue: 0.176, alpha: 1)
    )

    // MARK: - Accent Colors

    /// Primary accent - emerald green (#10B981)
    static let accentGreen = Color(red: 0.063, green: 0.725, blue: 0.506)

    /// Accent green pressed/dark variant (#059669)
    static let accentGreenDark = Color(red: 0.020, green: 0.588, blue: 0.412)

    /// Accent green light variant (#34D399)
    static let accentGreenLight = Color(red: 0.204, green: 0.827, blue: 0.600)

    // MARK: - Text Colors

    /// Primary text
    static let textPrimary = adaptive(
        light: UIColor(red: 0.110, green: 0.110, blue: 0.118, alpha: 1),
        dark: UIColor(red: 0.941, green: 0.965, blue: 0.988, alpha: 1)
    )

    /// Secondary text
    static let textSecondary = adaptive(
        light: UIColor(red: 0.431, green: 0.431, blue: 0.451, alpha: 1),
        dark: UIColor(red: 0.545, green: 0.580, blue: 0.620, alpha: 1)
    )

    /// Tertiary text
    static let textTertiary = adaptive(
        light: UIColor(red: 0.557, green: 0.557, blue: 0.576, alpha: 1),
        dark: UIColor(red: 0.431, green: 0.463, blue: 0.506, alpha: 1)
    )

    // MARK: - Semantic Colors

    /// Success green (#2EA043)
    static let success = Color(red: 0.180, green: 0.627, blue: 0.263)

    /// Warning amber (#D29922)
    static let warning = Color(red: 0.824, green: 0.600, blue: 0.133)

    /// Error red (#F85149)
    static let error = Color(red: 0.973, green: 0.318, blue: 0.286)

    /// Info blue (#58A6FF)
    static let info = Color(red: 0.345, green: 0.651, blue: 1.000)

    // MARK: - Chain Colors

    /// Ethereum purple (#627EEA)
    static let chainEthereum = Color(red: 0.384, green: 0.494, blue: 0.918)

    /// Polygon purple (#8247E5)
    static let chainPolygon = Color(red: 0.510, green: 0.278, blue: 0.898)

    /// Arbitrum blue (#28A0F0)
    static let chainArbitrum = Color(red: 0.157, green: 0.627, blue: 0.941)

    /// Base blue (#0052FF)
    static let chainBase = Color(red: 0.0, green: 0.322, blue: 1.0)

    /// Solana gradient start (#9945FF)
    static let chainSolana = Color(red: 0.600, green: 0.271, blue: 1.0)

    /// Bitcoin orange (#F7931A)
    static let chainBitcoin = Color(red: 0.969, green: 0.576, blue: 0.102)

    /// Zcash gold (#F4B728)
    static let chainZcash = Color(red: 0.957, green: 0.718, blue: 0.157)

    // MARK: - Border & Separator

    /// Border color
    static let border = adaptive(
        light: UIColor(red: 0.851, green: 0.851, blue: 0.871, alpha: 1),
        dark: UIColor(red: 0.188, green: 0.212, blue: 0.239, alpha: 1)
    )

    /// Separator color
    static let separator = adaptive(
        light: UIColor.black.withAlphaComponent(0.1),
        dark: UIColor.white.withAlphaComponent(0.1)
    )
}
