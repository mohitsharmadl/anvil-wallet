import SwiftUI
import WidgetKit

// MARK: - Main Widget View (dispatches by family)

struct PortfolioWidgetView: View {
    let entry: PortfolioEntry

    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:
            SmallPortfolioView(entry: entry)
        case .systemMedium:
            MediumPortfolioView(entry: entry)
        case .systemLarge:
            LargePortfolioView(entry: entry)
        default:
            SmallPortfolioView(entry: entry)
        }
    }
}

// MARK: - Small Widget

/// Shows total portfolio balance with the Anvil Wallet branding.
/// Designed to be glanceable -- balance only, no token details.
struct SmallPortfolioView: View {
    let entry: PortfolioEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 5) {
                Image(systemName: "hammer.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))

                Text("Anvil Wallet")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }

            Spacer()

            // Balance
            if entry.hasData {
                Text(entry.formattedBalance)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            } else {
                Text("--")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
            }

            Spacer()
                .frame(height: 6)

            // Last updated
            Text(entry.lastUpdatedText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(16)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.063, green: 0.725, blue: 0.506),  // accentGreen
                    Color(red: 0.020, green: 0.588, blue: 0.412),  // accentGreenDark
                    Color(red: 0.012, green: 0.420, blue: 0.310),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}

// MARK: - Medium Widget

/// Shows total balance + top 3 token holdings with amounts.
struct MediumPortfolioView: View {
    let entry: PortfolioEntry

    private var topTokens: [WidgetData.WidgetToken] {
        Array((entry.data?.topTokens ?? []).prefix(3))
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left column: balance + account
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Image(systemName: "hammer.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))

                    Text("Anvil Wallet")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }

                Spacer()

                if entry.hasData {
                    Text(entry.data?.accountName ?? "Account 0")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))

                    Text(entry.formattedBalance)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                } else {
                    Text("Open app to sync")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }

                Spacer()

                Text(entry.lastUpdatedText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Right column: top tokens
            if !topTokens.isEmpty {
                VStack(spacing: 8) {
                    ForEach(Array(topTokens.enumerated()), id: \.offset) { _, token in
                        TokenRow(token: token)
                    }

                    if topTokens.count < 3 {
                        Spacer()
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.063, green: 0.725, blue: 0.506),
                    Color(red: 0.020, green: 0.588, blue: 0.412),
                    Color(red: 0.012, green: 0.420, blue: 0.310),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}

// MARK: - Large Widget

/// Shows total balance + top 5 tokens with detailed amounts.
struct LargePortfolioView: View {
    let entry: PortfolioEntry

    private var topTokens: [WidgetData.WidgetToken] {
        Array((entry.data?.topTokens ?? []).prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "hammer.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))

                    Text("Anvil Wallet")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }

                Spacer()

                if entry.hasData {
                    Text(entry.data?.accountName ?? "Account 0")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            Spacer()
                .frame(height: 16)

            // Balance
            if entry.hasData {
                Text("Total Balance")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))

                Text(entry.formattedBalance)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            } else {
                Text("Open Anvil Wallet to sync your portfolio")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }

            Spacer()
                .frame(height: 20)

            // Divider
            Rectangle()
                .fill(.white.opacity(0.15))
                .frame(height: 1)

            Spacer()
                .frame(height: 16)

            // Token list
            if topTokens.isEmpty && entry.hasData {
                Text("No tokens with balance")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                VStack(spacing: 12) {
                    // Column headers
                    HStack {
                        Text("TOKEN")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.4))

                        Spacer()

                        Text("BALANCE")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.4))

                        Spacer()
                            .frame(width: 60)

                        Text("VALUE")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.4))
                    }

                    ForEach(Array(topTokens.enumerated()), id: \.offset) { _, token in
                        LargeTokenRow(token: token)
                    }
                }
            }

            Spacer()

            // Footer
            Text(entry.lastUpdatedText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(16)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.063, green: 0.725, blue: 0.506),
                    Color(red: 0.030, green: 0.520, blue: 0.380),
                    Color(red: 0.012, green: 0.420, blue: 0.310),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}

// MARK: - Token Row (Medium Widget)

/// Compact token row for the medium widget -- symbol, balance, and USD value.
private struct TokenRow: View {
    let token: WidgetData.WidgetToken

    var body: some View {
        HStack(spacing: 8) {
            // Token icon circle
            ZStack {
                Circle()
                    .fill(.white.opacity(0.15))
                    .frame(width: 28, height: 28)

                Text(String(token.symbol.prefix(1)))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(token.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)

                Text(PortfolioEntry.formatTokenBalance(token.balance))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }

            Spacer()

            Text(PortfolioEntry.formatCurrency(token.balanceUsd))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }
}

// MARK: - Token Row (Large Widget)

/// Detailed token row for the large widget.
private struct LargeTokenRow: View {
    let token: WidgetData.WidgetToken

    var body: some View {
        HStack(spacing: 10) {
            // Token icon
            ZStack {
                Circle()
                    .fill(.white.opacity(0.15))
                    .frame(width: 32, height: 32)

                Text(String(token.symbol.prefix(1)))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }

            Text(token.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)

            Spacer()

            Text(PortfolioEntry.formatTokenBalance(token.balance))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)

            Spacer()
                .frame(width: 8)

            Text(PortfolioEntry.formatCurrency(token.balanceUsd))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 60, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

// MARK: - Previews

#if DEBUG
struct PortfolioWidgetView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            // Small -- with data
            SmallPortfolioView(
                entry: PortfolioEntry(date: Date(), data: .placeholder)
            )
            .previewContext(WidgetPreviewContext(family: .systemSmall))
            .previewDisplayName("Small")

            // Small -- no data
            SmallPortfolioView(
                entry: PortfolioEntry(date: Date(), data: nil)
            )
            .previewContext(WidgetPreviewContext(family: .systemSmall))
            .previewDisplayName("Small (No Data)")

            // Medium
            MediumPortfolioView(
                entry: PortfolioEntry(date: Date(), data: .placeholder)
            )
            .previewContext(WidgetPreviewContext(family: .systemMedium))
            .previewDisplayName("Medium")

            // Large
            LargePortfolioView(
                entry: PortfolioEntry(date: Date(), data: .placeholder)
            )
            .previewContext(WidgetPreviewContext(family: .systemLarge))
            .previewDisplayName("Large")
        }
    }
}
#endif
