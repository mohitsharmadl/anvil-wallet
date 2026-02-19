import WidgetKit

/// Timeline entry that WidgetKit uses to render the portfolio widget.
struct PortfolioEntry: TimelineEntry {
    let date: Date
    let data: WidgetData?

    /// Whether this entry has real portfolio data from the app.
    var hasData: Bool { data != nil }

    /// Total portfolio balance formatted as currency string.
    var formattedBalance: String {
        guard let data else { return "$--" }
        return Self.formatCurrency(data.totalBalanceUsd)
    }

    /// Relative time string for "last updated" display.
    var lastUpdatedText: String {
        guard let data else { return "Open app to sync" }

        let elapsed = Date().timeIntervalSince(data.lastUpdated)

        if elapsed < 60 {
            return "Just now"
        } else if elapsed < 3600 {
            let mins = Int(elapsed / 60)
            return "\(mins)m ago"
        } else if elapsed < 86400 {
            let hours = Int(elapsed / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(elapsed / 86400)
            return "\(days)d ago"
        }
    }

    // MARK: - Formatting Helpers

    static func formatCurrency(_ value: Double) -> String {
        if value < 0.01 && value > 0 {
            return "<$0.01"
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "$0.00"
    }

    static func formatTokenBalance(_ balance: Double) -> String {
        if balance == 0 { return "0" }
        if balance < 0.0001 { return "<0.0001" }
        if balance >= 1_000_000 {
            return String(format: "%.1fM", balance / 1_000_000)
        }
        if balance >= 1_000 {
            return String(format: "%.1fK", balance / 1_000)
        }
        if balance >= 1 {
            return String(format: "%.4f", balance)
        }
        return String(format: "%.4f", balance)
    }
}
