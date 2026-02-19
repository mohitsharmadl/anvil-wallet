import XCTest
@testable import AnvilWallet

final class BalanceChangeSimulatorTests: XCTestCase {

    // MARK: - In-App Simulation

    func testNativeSendShowsAmountAndFee() {
        let changes = BalanceChangeSimulator.simulate(
            amount: "1.5",
            tokenSymbol: "ETH",
            isERC20: false,
            estimatedFee: "0.003",
            nativeSymbol: "ETH"
        )
        XCTAssertEqual(changes.count, 2)
        // First: token outflow
        XCTAssertEqual(changes[0].tokenSymbol, "ETH")
        XCTAssertEqual(changes[0].amount, "1.5")
        XCTAssertTrue(changes[0].isOutgoing)
        XCTAssertFalse(changes[0].isGasFee)
        // Second: gas fee
        XCTAssertEqual(changes[1].tokenSymbol, "ETH")
        XCTAssertTrue(changes[1].isGasFee)
    }

    func testERC20SendShowsTokenAndNativeFee() {
        let changes = BalanceChangeSimulator.simulate(
            amount: "500",
            tokenSymbol: "USDC",
            isERC20: true,
            estimatedFee: "0.002",
            nativeSymbol: "ETH"
        )
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes[0].tokenSymbol, "USDC")
        XCTAssertEqual(changes[0].amount, "500")
        XCTAssertEqual(changes[1].tokenSymbol, "ETH")
        XCTAssertTrue(changes[1].isGasFee)
    }

    func testZeroAmountNoOutflow() {
        let changes = BalanceChangeSimulator.simulate(
            amount: "0",
            tokenSymbol: "ETH",
            isERC20: false,
            estimatedFee: "0.001",
            nativeSymbol: "ETH"
        )
        // Only gas fee, no token outflow
        XCTAssertEqual(changes.count, 1)
        XCTAssertTrue(changes[0].isGasFee)
    }

    // MARK: - WC Simulation: Native Transfer

    func testWCNativeTransfer() {
        let changes = BalanceChangeSimulator.simulateWC(
            to: "0xRecipient",
            value: "0xDE0B6B3A7640000", // 1 ETH in wei
            data: nil,
            chainSymbol: "ETH"
        )
        // Native value + gas
        let nonGas = changes.filter { !$0.isGasFee }
        XCTAssertEqual(nonGas.count, 1)
        XCTAssertEqual(nonGas[0].tokenSymbol, "ETH")
        XCTAssertTrue(nonGas[0].isOutgoing)
    }

    // MARK: - WC Simulation: ERC-20 transfer selector

    func testWCERC20Transfer() {
        // transfer(0xRecipient, 1000000) — USDC with 6 decimals
        let recipient = String(repeating: "0", count: 24) + "aabbccdd11223344556677889900aabbccddeeff"
        let amount = String(repeating: "0", count: 58) + "0f4240" // 1000000 = 0xf4240
        let calldata = "0xa9059cbb" + recipient + amount

        let changes = BalanceChangeSimulator.simulateWC(
            to: "0xTokenContract",
            value: "0x0",
            data: calldata,
            chainSymbol: "ETH"
        )
        let erc20Changes = changes.filter { $0.tokenSymbol == "ERC-20" }
        XCTAssertEqual(erc20Changes.count, 1)
        XCTAssertTrue(erc20Changes[0].isOutgoing)
    }

    // MARK: - WC Simulation: Approve selector

    func testWCApproveUnlimited() {
        let spender = String(repeating: "0", count: 24) + "aabbccdd11223344556677889900aabbccddeeff"
        let maxUint = String(repeating: "f", count: 64)
        let calldata = "0x095ea7b3" + spender + maxUint

        let changes = BalanceChangeSimulator.simulateWC(
            to: "0xTokenContract",
            value: "0x0",
            data: calldata,
            chainSymbol: "ETH"
        )
        let approvalChanges = changes.filter { $0.tokenSymbol.contains("Approval") }
        XCTAssertEqual(approvalChanges.count, 1)
        XCTAssertEqual(approvalChanges[0].tokenSymbol, "Unlimited Approval")
        XCTAssertFalse(approvalChanges[0].isOutgoing)
    }

    func testWCApproveLimited() {
        let spender = String(repeating: "0", count: 24) + "aabbccdd11223344556677889900aabbccddeeff"
        let limitedAmount = String(repeating: "0", count: 48) + String(repeating: "a", count: 16)
        let calldata = "0x095ea7b3" + spender + limitedAmount

        let changes = BalanceChangeSimulator.simulateWC(
            to: "0xTokenContract",
            value: "0x0",
            data: calldata,
            chainSymbol: "ETH"
        )
        let approvalChanges = changes.filter { $0.tokenSymbol.contains("Approval") }
        XCTAssertEqual(approvalChanges.count, 1)
        XCTAssertEqual(approvalChanges[0].tokenSymbol, "Token Approval")
    }

    // MARK: - WC Simulation: Unknown Selector

    func testWCUnknownSelector() {
        let calldata = "0xdeadbeef" + String(repeating: "0", count: 64)

        let changes = BalanceChangeSimulator.simulateWC(
            to: "0xContract",
            value: "0x0",
            data: calldata,
            chainSymbol: "ETH"
        )
        let contractChanges = changes.filter { $0.tokenSymbol == "Contract Interaction" }
        XCTAssertEqual(contractChanges.count, 1)
    }

    // MARK: - WC Simulation: Always has gas

    func testWCAlwaysIncludesGas() {
        let changes = BalanceChangeSimulator.simulateWC(
            to: "0xSome",
            value: "0x0",
            data: nil,
            chainSymbol: "MATIC"
        )
        let gasChanges = changes.filter { $0.isGasFee }
        XCTAssertEqual(gasChanges.count, 1)
        XCTAssertEqual(gasChanges[0].tokenSymbol, "MATIC")
    }

    // MARK: - Malformed Calldata

    func testWCTruncatedTransferCalldataNoERC20Change() {
        // transfer selector but truncated — only 40 hex chars instead of 128
        let calldata = "0xa9059cbb" + String(repeating: "0", count: 40)

        let changes = BalanceChangeSimulator.simulateWC(
            to: "0xContract",
            value: "0x0",
            data: calldata,
            chainSymbol: "ETH"
        )
        // Should NOT produce an ERC-20 change (calldata too short)
        let erc20 = changes.filter { $0.tokenSymbol == "ERC-20" }
        XCTAssertTrue(erc20.isEmpty)
        // Should still have gas
        XCTAssertTrue(changes.contains { $0.isGasFee })
    }

    func testWCEmptyDataNoDecodeAttempt() {
        let changes = BalanceChangeSimulator.simulateWC(
            to: "0xContract",
            value: "0x1",
            data: "0x",
            chainSymbol: "ETH"
        )
        // No contract interaction change — data too short to have a selector
        let contractChanges = changes.filter { $0.tokenSymbol == "Contract Interaction" }
        XCTAssertTrue(contractChanges.isEmpty)
    }

    func testWCSelectorOnlyNoArgs() {
        // Just a 4-byte selector with no arguments
        let calldata = "0xa9059cbb"

        let changes = BalanceChangeSimulator.simulateWC(
            to: "0xContract",
            value: "0x0",
            data: calldata,
            chainSymbol: "ETH"
        )
        // transfer selector present but no arguments — should not produce ERC-20 entry
        let erc20 = changes.filter { $0.tokenSymbol == "ERC-20" }
        XCTAssertTrue(erc20.isEmpty)
    }

    // MARK: - Decimal Precision

    func testLargeWeiValueDoesNotLosePrecision() {
        // 100 ETH = 100 * 10^18 = 0x56BC75E2D63100000
        let changes = BalanceChangeSimulator.simulateWC(
            to: "0xSome",
            value: "0x56BC75E2D63100000",
            data: nil,
            chainSymbol: "ETH"
        )
        let valueChanges = changes.filter { !$0.isGasFee && $0.tokenSymbol == "ETH" }
        XCTAssertEqual(valueChanges.count, 1)
        // Should parse to ~100.0000 ETH
        guard let parsed = Double(valueChanges[0].amount) else {
            XCTFail("Amount should be a valid number")
            return
        }
        XCTAssertEqual(parsed, 100.0, accuracy: 0.001)
    }
}
