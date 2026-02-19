import WidgetKit
import SwiftUI

/// Main entry point for the Anvil Wallet widget extension.
///
/// This bundles all widgets provided by the extension. Currently includes:
///   - PortfolioWidget: Shows portfolio balance in small/medium/large sizes
///
/// Additional widgets (e.g., single-token price, gas tracker) can be added
/// to the WidgetBundle body in the future.
@main
struct AnvilWalletWidgetBundle: WidgetBundle {
    var body: some Widget {
        PortfolioWidget()
    }
}
