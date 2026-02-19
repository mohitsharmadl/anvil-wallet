import SwiftUI

final class AppRouter: ObservableObject {
    @Published var isOnboarded: Bool = false
    @Published var selectedTab: Tab = .wallet
    @Published var onboardingPath = NavigationPath()
    @Published var walletPath = NavigationPath()
    @Published var sendPath = NavigationPath()

    enum Tab: Int, CaseIterable {
        case wallet = 0
        case send = 1
        case dapps = 2
        case settings = 3
    }

    enum OnboardingDestination: Hashable {
        case createWallet
        case importWallet
        case backupMnemonic(words: [String])
        case verifyMnemonic(words: [String])
        case setPassword(mnemonic: String)
    }

    enum WalletDestination: Hashable {
        case tokenDetail(token: TokenModel)
        case nftDetail(nft: NFTModel)
        case chainPicker
        case receive(chain: String, address: String)
        case activity
        case notifications
    }

    enum SendDestination: Hashable {
        case confirmTransaction(transaction: TransactionModel)
        case transactionResult(txHash: String, success: Bool, chain: String)
        case qrScanner
    }

    // MARK: - Navigation Helpers

    func completeOnboarding() {
        isOnboarded = true
        onboardingPath = NavigationPath()
    }

    func resetToOnboarding() {
        isOnboarded = false
        onboardingPath = NavigationPath()
    }

    func navigateToTab(_ tab: Tab) {
        selectedTab = tab
    }
}
