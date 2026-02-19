import WidgetKit
import SwiftUI

/// The portfolio balance widget configuration.
///
/// Supports three sizes:
///   - **Small**: Total balance + branding
///   - **Medium**: Balance + top 3 tokens
///   - **Large**: Balance + top 5 tokens with detailed amounts
struct PortfolioWidget: Widget {

    /// Widget kind identifier. Must be unique per widget in the extension.
    let kind = "com.anvilwallet.portfolio-widget"

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: kind,
            provider: PortfolioProvider()
        ) { entry in
            PortfolioWidgetView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Portfolio Balance")
        .description("View your Anvil Wallet portfolio balance at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}
