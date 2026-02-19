import SwiftUI

/// TokenListView displays all tokens across all chains with their balances and prices.
struct TokenListView: View {
    @EnvironmentObject var walletService: WalletService
    @EnvironmentObject var router: AppRouter

    @State private var searchText = ""

    private var filteredTokens: [TokenModel] {
        if searchText.isEmpty {
            return walletService.tokens
        }
        return walletService.tokens.filter { token in
            token.name.localizedCaseInsensitiveContains(searchText) ||
            token.symbol.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            HStack {
                Text("Tokens")
                    .font(.headline)
                    .foregroundColor(.textPrimary)

                Spacer()

                Button {
                    // TODO: Add/manage tokens
                } label: {
                    Image(systemName: "plus.circle")
                        .foregroundColor(.accentGreen)
                }
            }
            .padding(.horizontal, 20)

            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.textTertiary)

                TextField("Search tokens", text: $searchText)
                    .font(.body)
                    .foregroundColor(.textPrimary)
            }
            .padding(10)
            .background(Color.backgroundCard)
            .cornerRadius(10)
            .padding(.horizontal, 20)

            // Token list
            LazyVStack(spacing: 0) {
                ForEach(filteredTokens) { token in
                    Button {
                        router.walletPath.append(
                            AppRouter.WalletDestination.tokenDetail(token: token)
                        )
                    } label: {
                        TokenRowView(token: token)
                    }

                    if token.id != filteredTokens.last?.id {
                        Divider()
                            .background(Color.separator)
                            .padding(.leading, 68)
                    }
                }
            }
            .padding(.horizontal, 20)

            if filteredTokens.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.title)
                        .foregroundColor(.textTertiary)

                    Text("No tokens found")
                        .font(.body)
                        .foregroundColor(.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            }
        }
    }
}

// MARK: - Token Row

private struct TokenRowView: View {
    let token: TokenModel

    var body: some View {
        HStack(spacing: 12) {
            TokenIconView(symbol: token.symbol, chain: token.chain, size: 40)

            // Token info
            VStack(alignment: .leading, spacing: 2) {
                Text(token.name)
                    .font(.body)
                    .foregroundColor(.textPrimary)

                Text(token.chain.capitalized)
                    .font(.caption)
                    .foregroundColor(.textTertiary)
            }

            Spacer()

            // Balance
            VStack(alignment: .trailing, spacing: 2) {
                Text(token.formattedBalance)
                    .font(.body.monospacedDigit())
                    .foregroundColor(.textPrimary)

                Text(token.formattedBalanceUsd)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.textSecondary)
            }
        }
        .padding(.vertical, 12)
    }

}

#Preview {
    ScrollView {
        TokenListView()
            .environmentObject(WalletService.shared)
            .environmentObject(AppRouter())
    }
    .background(Color.backgroundPrimary)
}
