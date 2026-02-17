import SwiftUI

/// Theme color definitions for the CryptoWallet app.
///
/// Design system:
///   - Dark navy backgrounds for the primary canvas
///   - Emerald green accent for CTAs and highlights
///   - White/light gray for text
///   - Semantic colors for success, warning, error states
extension Color {

    // MARK: - Background Colors

    /// Primary background - dark navy (#0D1117)
    static let backgroundPrimary = Color(red: 0.051, green: 0.067, blue: 0.090)

    /// Secondary background - slightly lighter navy (#161B22)
    static let backgroundSecondary = Color(red: 0.086, green: 0.106, blue: 0.133)

    /// Card/surface background (#1C2128)
    static let backgroundCard = Color(red: 0.110, green: 0.129, blue: 0.157)

    /// Elevated surface (#21262D)
    static let backgroundElevated = Color(red: 0.129, green: 0.149, blue: 0.176)

    // MARK: - Accent Colors

    /// Primary accent - emerald green (#10B981)
    static let accentGreen = Color(red: 0.063, green: 0.725, blue: 0.506)

    /// Accent green pressed/dark variant (#059669)
    static let accentGreenDark = Color(red: 0.020, green: 0.588, blue: 0.412)

    /// Accent green light variant (#34D399)
    static let accentGreenLight = Color(red: 0.204, green: 0.827, blue: 0.600)

    // MARK: - Text Colors

    /// Primary text - white (#F0F6FC)
    static let textPrimary = Color(red: 0.941, green: 0.965, blue: 0.988)

    /// Secondary text - light gray (#8B949E)
    static let textSecondary = Color(red: 0.545, green: 0.580, blue: 0.620)

    /// Tertiary text - dim gray (#6E7681)
    static let textTertiary = Color(red: 0.431, green: 0.463, blue: 0.506)

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

    // MARK: - Border & Separator

    /// Border color (#30363D)
    static let border = Color(red: 0.188, green: 0.212, blue: 0.239)

    /// Separator color (slightly transparent white)
    static let separator = Color.white.opacity(0.1)
}
