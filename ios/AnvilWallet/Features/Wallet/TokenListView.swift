import SwiftUI

/// TokenListView displays all tokens across all chains with their balances and prices.
struct TokenListView: View {
    @EnvironmentObject var walletService: WalletService
    @EnvironmentObject var router: AppRouter

    @State private var searchText = ""
    @State private var showAddToken = false

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
        VStack(alignment: .leading, spacing: 16) {
            // Section header
            HStack {
                Text("Tokens")
                    .font(.title3.bold())
                    .foregroundColor(.textPrimary)

                Spacer()

                Button {
                    showAddToken = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundColor(.accentGreen)
                }
            }
            .padding(.horizontal, 20)

            // Search bar
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline)
                    .foregroundColor(.textTertiary)

                TextField("Search tokens", text: $searchText)
                    .font(.subheadline)
                    .foregroundColor(.textPrimary)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.subheadline)
                            .foregroundColor(.textTertiary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.backgroundCard)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 20)

            // Token list
            VStack(spacing: 4) {
                ForEach(filteredTokens) { token in
                    Button {
                        router.walletPath.append(
                            AppRouter.WalletDestination.tokenDetail(token: token)
                        )
                    } label: {
                        TokenRowView(token: token)
                    }
                    .buttonStyle(ScaleButtonStyle())
                }
            }
            .padding(.horizontal, 20)

            if filteredTokens.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.largeTitle)
                        .foregroundColor(.textTertiary)

                    Text("No tokens found")
                        .font(.subheadline)
                        .foregroundColor(.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
            }
        }
        .sheet(isPresented: $showAddToken) {
            AddTokenView()
        }
    }
}

// MARK: - Token Row

private struct TokenRowView: View {
    let token: TokenModel

    var body: some View {
        HStack(spacing: 14) {
            // Token icon
            TokenIconView(symbol: token.symbol, chain: token.chain, size: 44)

            // Token info
            VStack(alignment: .leading, spacing: 3) {
                Text(token.symbol)
                    .font(.body.weight(.semibold))
                    .foregroundColor(.textPrimary)

                Text(token.name)
                    .font(.caption)
                    .foregroundColor(.textTertiary)
            }

            Spacer()

            // Balance
            VStack(alignment: .trailing, spacing: 3) {
                Text(token.formattedBalance)
                    .font(.body.weight(.medium).monospacedDigit())
                    .foregroundColor(.textPrimary)

                Text(token.formattedBalanceUsd)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.textSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.backgroundCard)
        .clipShape(RoundedRectangle(cornerRadius: 16))
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
