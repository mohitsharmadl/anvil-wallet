import Foundation

/// Data structure shared between the main app and the widget extension.
/// This is a standalone copy -- the widget extension cannot import the main app target.
///
/// Must stay in sync with the identical definition in
/// `AnvilWallet/Services/WidgetDataProvider.swift`.
struct WidgetData: Codable {
    let totalBalanceUsd: Double
    let topTokens: [WidgetToken]
    let lastUpdated: Date
    let accountName: String

    struct WidgetToken: Codable {
        let symbol: String
        let balance: Double
        let balanceUsd: Double
        let priceUsd: Double
    }

    /// Reads the latest widget data from the shared App Group UserDefaults.
    /// Returns nil if no data has been written yet (e.g., first launch).
    static func load() -> WidgetData? {
        guard let defaults = UserDefaults(suiteName: "group.com.anvilwallet.shared"),
              let data = defaults.data(forKey: "com.anvilwallet.widgetData") else {
            return nil
        }
        return try? JSONDecoder().decode(WidgetData.self, from: data)
    }

    // MARK: - Preview / Placeholder Data

    static let placeholder = WidgetData(
        totalBalanceUsd: 12_345.67,
        topTokens: [
            WidgetToken(symbol: "ETH", balance: 2.5, balanceUsd: 7_500.00, priceUsd: 3_000.00),
            WidgetToken(symbol: "BTC", balance: 0.05, balanceUsd: 3_250.00, priceUsd: 65_000.00),
            WidgetToken(symbol: "SOL", balance: 10.0, balanceUsd: 1_500.00, priceUsd: 150.00),
            WidgetToken(symbol: "USDC", balance: 95.67, balanceUsd: 95.67, priceUsd: 1.00),
        ],
        lastUpdated: Date(),
        accountName: "Account 0"
    )
}
