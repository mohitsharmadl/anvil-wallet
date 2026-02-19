import XCTest
@testable import AnvilWallet

final class StakingServiceTests: XCTestCase {

    // MARK: - Lido Constants

    func testLidoSubmitSelectorIsCorrect() {
        // submit(address _referral) -> keccak256("submit(address)")[:4] = 0xa1903eab
        XCTAssertEqual(StakingService.lidoSubmitSelector, "a1903eab")
    }

    func testLidoSubmitSelectorLength() {
        // 4 bytes = 8 hex characters
        XCTAssertEqual(StakingService.lidoSubmitSelector.count, 8)
    }

    func testLidoContractAddressIsValid() {
        let address = StakingService.lidoContractAddress
        XCTAssertTrue(address.hasPrefix("0x"))
        XCTAssertEqual(address.count, 42, "EVM address should be 42 characters")
    }

    func testLidoContractAddressIsMainnet() {
        // Known Lido stETH contract address on Ethereum mainnet
        XCTAssertEqual(
            StakingService.lidoContractAddress,
            "0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84"
        )
    }

    // MARK: - StakingOption Model

    func testStakingOptionProperties() {
        let option = StakingService.StakingOption(
            id: "lido-eth",
            chain: "ethereum",
            protocol_: "Lido",
            tokenSymbol: "ETH",
            stakedTokenSymbol: "stETH",
            apy: 3.5,
            minAmount: 0.001,
            description: "Stake ETH via Lido"
        )
        XCTAssertEqual(option.id, "lido-eth")
        XCTAssertEqual(option.chain, "ethereum")
        XCTAssertEqual(option.protocol_, "Lido")
        XCTAssertEqual(option.tokenSymbol, "ETH")
        XCTAssertEqual(option.stakedTokenSymbol, "stETH")
        XCTAssertEqual(option.apy, 3.5, accuracy: 0.001)
        XCTAssertEqual(option.minAmount, 0.001, accuracy: 0.0001)
        XCTAssertEqual(option.description, "Stake ETH via Lido")
    }

    func testStakingOptionIdentifiable() {
        let option = StakingService.StakingOption(
            id: "test-id",
            chain: "ethereum",
            protocol_: "Test",
            tokenSymbol: "ETH",
            stakedTokenSymbol: "tETH",
            apy: 5.0,
            minAmount: 0.01,
            description: "Test"
        )
        // Identifiable conformance: id should be accessible
        XCTAssertEqual(option.id, "test-id")
    }

    // MARK: - availableOptions

    func testAvailableOptionsEmptyWhenNoApyFetched() {
        let service = StakingService.shared
        // Before any APY is fetched, both should be nil
        // (In a fresh state; we can't control this in a singleton, but we verify the logic.)
        // This tests the computed property logic: if ethApy and solApy are nil, options is empty
        // We create a synthetic test by checking the count is consistent
        let options = service.availableOptions
        // Both ethApy and solApy are initially nil, so options should be empty
        if service.ethApy == nil && service.solApy == nil {
            XCTAssertTrue(options.isEmpty)
        }
    }

    func testAvailableOptionsEthOnlyWhenEthApySet() {
        let service = StakingService.shared
        let originalEth = service.ethApy
        let originalSol = service.solApy

        service.ethApy = 3.8
        service.solApy = nil

        let options = service.availableOptions
        XCTAssertEqual(options.count, 1)
        XCTAssertEqual(options[0].id, "lido-eth")
        XCTAssertEqual(options[0].chain, "ethereum")
        XCTAssertEqual(options[0].protocol_, "Lido")
        XCTAssertEqual(options[0].tokenSymbol, "ETH")
        XCTAssertEqual(options[0].stakedTokenSymbol, "stETH")
        XCTAssertEqual(options[0].apy, 3.8, accuracy: 0.001)
        XCTAssertEqual(options[0].minAmount, 0.001, accuracy: 0.0001)

        // Restore
        service.ethApy = originalEth
        service.solApy = originalSol
    }

    func testAvailableOptionsSolOnlyWhenSolApySet() {
        let service = StakingService.shared
        let originalEth = service.ethApy
        let originalSol = service.solApy

        service.ethApy = nil
        service.solApy = 5.2

        let options = service.availableOptions
        XCTAssertEqual(options.count, 1)
        XCTAssertEqual(options[0].id, "native-sol")
        XCTAssertEqual(options[0].chain, "solana")
        XCTAssertEqual(options[0].protocol_, "Native")
        XCTAssertEqual(options[0].tokenSymbol, "SOL")
        XCTAssertEqual(options[0].stakedTokenSymbol, "Staked SOL")
        XCTAssertEqual(options[0].apy, 5.2, accuracy: 0.001)
        XCTAssertEqual(options[0].minAmount, 0.01, accuracy: 0.001)

        // Restore
        service.ethApy = originalEth
        service.solApy = originalSol
    }

    func testAvailableOptionsBothWhenBothApySet() {
        let service = StakingService.shared
        let originalEth = service.ethApy
        let originalSol = service.solApy

        service.ethApy = 3.5
        service.solApy = 5.0

        let options = service.availableOptions
        XCTAssertEqual(options.count, 2)
        XCTAssertEqual(options[0].id, "lido-eth")
        XCTAssertEqual(options[1].id, "native-sol")

        // Restore
        service.ethApy = originalEth
        service.solApy = originalSol
    }

    func testAvailableOptionsApyMatchesPublishedValue() {
        let service = StakingService.shared
        let originalEth = service.ethApy
        let originalSol = service.solApy

        service.ethApy = 4.2
        service.solApy = nil

        let options = service.availableOptions
        XCTAssertEqual(options[0].apy, 4.2, accuracy: 0.001)

        // Restore
        service.ethApy = originalEth
        service.solApy = originalSol
    }
}
