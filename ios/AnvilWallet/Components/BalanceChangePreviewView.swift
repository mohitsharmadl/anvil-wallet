import SwiftUI

/// Displays predicted balance changes as "+500 USDC" (green) / "-0.15 ETH" (red) rows.
struct BalanceChangePreviewView: View {
    let changes: [BalanceChangeSimulator.BalanceChange]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.caption)
                    .foregroundColor(.textSecondary)
                Text("Balance Changes")
                    .font(.subheadline.bold())
                    .foregroundColor(.textSecondary)
            }

            ForEach(changes) { change in
                HStack(spacing: 8) {
                    // Direction icon
                    Image(systemName: change.isGasFee ? "fuelpump.fill" : (change.isOutgoing ? "arrow.up.right" : "arrow.down.left"))
                        .font(.caption)
                        .foregroundColor(change.isOutgoing ? .error : .success)
                        .frame(width: 20)

                    // Token info
                    if change.isGasFee {
                        Text("Gas Fee")
                            .font(.subheadline)
                            .foregroundColor(.textSecondary)
                    } else {
                        Text(change.tokenSymbol)
                            .font(.subheadline)
                            .foregroundColor(.textPrimary)
                    }

                    Spacer()

                    // Amount
                    if !change.amount.isEmpty && change.amount != "0" {
                        Text("\(change.isOutgoing ? "-" : "+")\(change.amount)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundColor(change.isOutgoing ? .error : .success)
                    } else if change.isGasFee {
                        Text("(estimated)")
                            .font(.caption)
                            .foregroundColor(.textTertiary)
                    }
                }
            }
        }
        .padding()
        .background(Color.backgroundCard)
        .cornerRadius(16)
        .padding(.horizontal, 20)
    }
}
