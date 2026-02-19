import Foundation
import WidgetKit

// MARK: - Shared Widget Data Model

/// Data structure shared between the main app and the widget extension.
/// Both sides encode/decode this via the shared App Group UserDefaults.
///
/// This file lives in the main app target. The widget extension has its own
/// identical copy (WidgetData.swift) to avoid cross-target dependencies.
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
}

// MARK: - Widget Data Provider

/// Writes portfolio data to the shared App Group UserDefaults so the
/// WidgetKit extension can read it.
///
/// Usage: Call `updateWidgetData(tokens:accountName:)` after every
/// balance/price refresh in WalletService.
final class WidgetDataProvider {

    static let shared = WidgetDataProvider()

    /// App Group suite name. Must match the App Group capability
    /// configured on both the main app target and the widget extension target.
    static let suiteName = "group.com.anvilwallet.shared"

    /// UserDefaults key for the encoded widget data.
    private static let widgetDataKey = "com.anvilwallet.widgetData"

    private let encoder = JSONEncoder()

    private init() {}

    /// Encodes the current portfolio state and writes it to shared UserDefaults.
    /// Then tells WidgetKit to reload all timelines so the widget picks up the new data.
    ///
    /// - Parameters:
    ///   - tokens: The current token list (with balances and prices populated).
    ///   - accountName: The display name of the active account.
    func updateWidgetData(tokens: [TokenModel], accountName: String) {
        guard let defaults = UserDefaults(suiteName: Self.suiteName) else { return }

        // Sort by USD value descending, take top 5
        let sorted = tokens
            .filter { $0.balanceUsd > 0 }
            .sorted { $0.balanceUsd > $1.balanceUsd }
            .prefix(5)

        let widgetTokens = sorted.map { token in
            WidgetData.WidgetToken(
                symbol: token.symbol,
                balance: token.balance,
                balanceUsd: token.balanceUsd,
                priceUsd: token.priceUsd
            )
        }

        let totalBalance = tokens.reduce(0) { $0 + $1.balanceUsd }

        let data = WidgetData(
            totalBalanceUsd: totalBalance,
            topTokens: widgetTokens,
            lastUpdated: Date(),
            accountName: accountName
        )

        if let encoded = try? encoder.encode(data) {
            defaults.set(encoded, forKey: Self.widgetDataKey)
        }

        // Tell WidgetKit to refresh
        WidgetCenter.shared.reloadAllTimelines()
    }
}
