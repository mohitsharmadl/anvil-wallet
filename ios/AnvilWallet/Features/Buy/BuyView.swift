import SwiftUI

/// BuyView lets users purchase crypto directly in-app via MoonPay's buy widget.
///
/// The view shows a chain/token picker at the top, then embeds a WKWebView
/// pointing to MoonPay's hosted buy widget URL pre-filled with the user's
/// wallet address for the selected chain.
///
/// Important: The purchase flow is handled entirely by MoonPay (a third party).
/// Anvil Wallet does not process payments or hold user funds during the purchase.
struct BuyView: View {
    @EnvironmentObject var walletService: WalletService
    @Environment(\.dismiss) private var dismiss

    @State private var selectedChain: BuyChain = .ethereum
    @State private var isWebViewLoading = true
    @State private var webViewError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Chain/token picker
                chainPicker
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                // Third-party disclaimer
                disclaimer
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)

                // WebView or error/empty state
                ZStack {
                    if let walletAddress = walletAddress(for: selectedChain) {
                        MoonPayWebView(
                            url: moonPayURL(chain: selectedChain, address: walletAddress),
                            onLoadingStateChanged: { loading in
                                isWebViewLoading = loading
                            },
                            onError: { error in
                                webViewError = error.localizedDescription
                            }
                        )
                        .id(selectedChain) // Force WebView recreation when chain changes

                        if isWebViewLoading {
                            loadingIndicator
                        }
                    } else {
                        noAddressView
                    }

                    // Error banner overlay
                    if let error = webViewError {
                        errorBanner(message: error)
                    }
                }
            }
            .background(Color.backgroundPrimary)
            .navigationTitle("Buy Crypto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.textSecondary)
                }
            }
        }
    }

    // MARK: - Chain Picker

    private var chainPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(BuyChain.allCases) { chain in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedChain = chain
                            webViewError = nil
                            isWebViewLoading = true
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(chain.color.opacity(0.15))
                                .frame(width: 24, height: 24)
                                .overlay(
                                    Text(chain.displaySymbol.prefix(2))
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(chain.color)
                                )

                            Text(chain.displayName)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(
                                    selectedChain == chain ? .textPrimary : .textSecondary
                                )
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            selectedChain == chain
                                ? Color.backgroundCard
                                : Color.backgroundSecondary
                        )
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(
                                    selectedChain == chain
                                        ? Color.accentGreen.opacity(0.5)
                                        : Color.clear,
                                    lineWidth: 1
                                )
                        )
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Disclaimer

    private var disclaimer: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundColor(.textTertiary)

            Text("You are interacting with MoonPay, a third-party service. Anvil Wallet does not process your payment.")
                .font(.caption2)
                .foregroundColor(.textTertiary)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.backgroundSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Loading Indicator

    private var loadingIndicator: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .accentGreen))
                .scaleEffect(1.2)
            Text("Loading MoonPay...")
                .font(.caption)
                .foregroundColor(.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.backgroundPrimary.opacity(0.9))
    }

    // MARK: - No Address View

    private var noAddressView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundColor(.warning)

            Text("No wallet address available for \(selectedChain.displayName).")
                .font(.subheadline)
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)

            Text("Please set up a wallet first.")
                .font(.caption)
                .foregroundColor(.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    // MARK: - Error Banner

    private func errorBanner(message: String) -> some View {
        VStack {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash")
                    .font(.caption)
                    .foregroundColor(.white)

                Text(message)
                    .font(.caption)
                    .foregroundColor(.white)
                    .lineLimit(2)

                Spacer()

                Button {
                    webViewError = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.bold())
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.error)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()
        }
    }

    // MARK: - URL Construction

    /// Builds the MoonPay buy widget URL for the selected chain and address.
    private func moonPayURL(chain: BuyChain, address: String) -> URL {
        let apiKey = Bundle.main.object(forInfoDictionaryKey: "MoonPayApiKey") as? String ?? ""
        let currencyCode = chain.moonPayCurrencyCode
        // Anvil Wallet accent green (#34D399), URL-encoded
        let colorCode = "%2334D399"

        var components = URLComponents(string: "https://buy.moonpay.com")!
        var queryItems = [
            URLQueryItem(name: "apiKey", value: apiKey),
            URLQueryItem(name: "currencyCode", value: currencyCode),
            URLQueryItem(name: "walletAddress", value: address),
            URLQueryItem(name: "colorCode", value: colorCode),
        ]

        if apiKey.isEmpty || apiKey == "YOUR_MOONPAY_API_KEY" {
            // Keep URL valid but mark integration as test-misconfigured.
            queryItems.append(URLQueryItem(name: "flow", value: "buy"))
        }

        components.queryItems = queryItems

        return components.url!

        // MARK: Transak Alternative (uncomment to use instead of MoonPay)
        //
        // Transak URL format:
        //   https://global.transak.com?apiKey={key}&cryptoCurrencyCode={token}&walletAddress={address}&network={network}
        //
        // Use `TransakApiKey` from Info.plist for production configuration.
        // let transakApiKey = "tk_test_123"
        // var transakComponents = URLComponents(string: "https://global.transak.com")!
        // transakComponents.queryItems = [
        //     URLQueryItem(name: "apiKey", value: transakApiKey),
        //     URLQueryItem(name: "cryptoCurrencyCode", value: chain.transakCurrencyCode),
        //     URLQueryItem(name: "walletAddress", value: address),
        //     URLQueryItem(name: "network", value: chain.transakNetwork),
        // ]
        // return transakComponents.url!
    }

    // MARK: - Address Lookup

    /// Returns the user's wallet address for the given buy chain, or nil if unavailable.
    private func walletAddress(for chain: BuyChain) -> String? {
        walletService.addresses[chain.walletChainId]
    }
}

// MARK: - BuyChain Enum

/// Represents each chain/token that can be purchased through the on-ramp.
/// Maps to MoonPay and Transak currency codes and the wallet's internal chain IDs.
enum BuyChain: String, CaseIterable, Identifiable {
    case ethereum
    case bitcoin
    case solana
    case polygon
    case arbitrum
    case base
    case optimism
    case bsc
    case avalanche

    var id: String { rawValue }

    /// Human-readable chain name.
    var displayName: String {
        switch self {
        case .ethereum:  return "Ethereum"
        case .bitcoin:   return "Bitcoin"
        case .solana:    return "Solana"
        case .polygon:   return "Polygon"
        case .arbitrum:  return "Arbitrum"
        case .base:      return "Base"
        case .optimism:  return "Optimism"
        case .bsc:       return "BNB Chain"
        case .avalanche: return "Avalanche"
        }
    }

    /// Native token symbol shown in the picker.
    var displaySymbol: String {
        switch self {
        case .ethereum:  return "ETH"
        case .bitcoin:   return "BTC"
        case .solana:    return "SOL"
        case .polygon:   return "MATIC"
        case .arbitrum:  return "ETH"
        case .base:      return "ETH"
        case .optimism:  return "ETH"
        case .bsc:       return "BNB"
        case .avalanche: return "AVAX"
        }
    }

    /// MoonPay currency code for this chain's native token.
    /// See: https://docs.moonpay.com/payment-widget/getting-started
    var moonPayCurrencyCode: String {
        switch self {
        case .ethereum:  return "eth"
        case .bitcoin:   return "btc"
        case .solana:    return "sol"
        case .polygon:   return "matic"
        case .arbitrum:  return "eth_arbitrum"
        case .base:      return "eth_base"
        case .optimism:  return "eth_optimism"
        case .bsc:       return "bnb_bsc"
        case .avalanche: return "avax_cchain"
        }
    }

    /// Transak currency code (if using Transak as alternative).
    var transakCurrencyCode: String {
        switch self {
        case .ethereum:  return "ETH"
        case .bitcoin:   return "BTC"
        case .solana:    return "SOL"
        case .polygon:   return "MATIC"
        case .arbitrum:  return "ETH"
        case .base:      return "ETH"
        case .optimism:  return "ETH"
        case .bsc:       return "BNB"
        case .avalanche: return "AVAX"
        }
    }

    /// Transak network identifier (if using Transak as alternative).
    var transakNetwork: String {
        switch self {
        case .ethereum:  return "ethereum"
        case .bitcoin:   return "bitcoin"
        case .solana:    return "solana"
        case .polygon:   return "polygon"
        case .arbitrum:  return "arbitrum"
        case .base:      return "base"
        case .optimism:  return "optimism"
        case .bsc:       return "bsc"
        case .avalanche: return "avaxcchain"
        }
    }

    /// Maps to the wallet's internal chain ID for address lookup.
    var walletChainId: String {
        switch self {
        case .ethereum:  return "ethereum"
        case .bitcoin:   return "bitcoin"
        case .solana:    return "solana"
        case .polygon:   return "polygon"
        case .arbitrum:  return "arbitrum"
        case .base:      return "base"
        case .optimism:  return "optimism"
        case .bsc:       return "bsc"
        case .avalanche: return "avalanche"
        }
    }

    /// Accent color for this chain in the picker UI.
    var color: Color {
        switch self {
        case .ethereum:  return .chainEthereum
        case .bitcoin:   return .chainBitcoin
        case .solana:    return .chainSolana
        case .polygon:   return .chainPolygon
        case .arbitrum:  return .chainArbitrum
        case .base:      return .chainBase
        case .optimism:  return .error
        case .bsc:       return .warning
        case .avalanche: return .error
        }
    }
}

#Preview {
    BuyView()
        .environmentObject(WalletService.shared)
}
