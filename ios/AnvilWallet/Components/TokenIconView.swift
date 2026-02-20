import SwiftUI
import UIKit

/// Displays a token's logo image from the asset catalog, falling back to a
/// colored circle with the first letter of the symbol if no image exists.
struct TokenIconView: View {
    let symbol: String
    let chain: String
    var size: CGFloat = 40

    /// Maps token symbol to asset catalog image name under Tokens/.
    private var assetName: String? {
        switch symbol.uppercased() {
        case "ETH": return "Tokens/token-eth"
        case "BTC": return "Tokens/token-btc"
        case "SOL": return "Tokens/token-sol"
        case "ZEC": return "Tokens/token-zec"
        case "USDC": return "Tokens/token-usdc"
        case "USDT": return "Tokens/token-usdt"
        default: return nil
        }
    }

    var body: some View {
        if let assetName, let uiImage = UIImage(named: assetName) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(chainColor(for: chain))
                .frame(width: size, height: size)
                .overlay(
                    Text(fallbackLabel)
                        .font(size >= 36 ? .headline.bold() : .caption.bold())
                        .foregroundColor(.white)
                )
        }
    }

    private var fallbackLabel: String {
        switch symbol.uppercased() {
        case "ZEC":
            return "Z"
        default:
            return String(symbol.prefix(1))
        }
    }

    private func chainColor(for chain: String) -> Color {
        switch chain {
        case "ethereum": return .chainEthereum
        case "polygon": return .chainPolygon
        case "arbitrum": return .chainArbitrum
        case "base": return .chainBase
        case "solana": return .chainSolana
        case "bitcoin": return .chainBitcoin
        case "zcash", "zcash_testnet": return .chainZcash
        default: return .textTertiary
        }
    }
}
