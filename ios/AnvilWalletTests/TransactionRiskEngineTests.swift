import XCTest
@testable import AnvilWallet

final class TransactionRiskEngineTests: XCTestCase {

    private let engine = TransactionRiskEngine.shared

    // MARK: - Helper

    private func makeTx(to: String, hash: String = "0xabc") -> TransactionModel {
        TransactionModel(
            id: UUID(),
            hash: hash,
            chain: "ethereum",
            from: "0x1111111111111111111111111111111111111111",
            to: to,
            amount: "1.0",
            fee: "0.001",
            status: .confirmed,
            timestamp: Date(),
            tokenSymbol: "ETH",
            tokenDecimals: 18,
            contractAddress: nil
        )
    }

    // MARK: - Rule 1: New Address

    func testNewAddressWarning() {
        let result = engine.assess(
            to: "0xNEWADDRESS",
            amount: "1.0",
            tokenSymbol: "ETH",
            tokenBalance: 10.0,
            tokenDecimals: 18,
            contractAddress: nil,
            previousTransactions: []
        )
        XCTAssertTrue(result.findings.contains { $0.title == "New Address" })
        XCTAssertGreaterThanOrEqual(result.overallLevel, .warning)
    }

    func testKnownAddressNoWarning() {
        let addr = "0xKNOWN"
        let pastTx = makeTx(to: addr)
        let result = engine.assess(
            to: addr,
            amount: "1.0",
            tokenSymbol: "ETH",
            tokenBalance: 10.0,
            tokenDecimals: 18,
            contractAddress: nil,
            previousTransactions: [pastTx]
        )
        XCTAssertFalse(result.findings.contains { $0.title == "New Address" })
    }

    // MARK: - Rule 2: Large Amount

    func testLargeAmountWarning() {
        let result = engine.assess(
            to: "0xSOME",
            amount: "8.0",
            tokenSymbol: "ETH",
            tokenBalance: 10.0,
            tokenDecimals: 18,
            contractAddress: nil,
            previousTransactions: [makeTx(to: "0xSOME")]
        )
        XCTAssertTrue(result.findings.contains { $0.title == "Large Transfer" })
    }

    func testSmallAmountNoWarning() {
        let result = engine.assess(
            to: "0xSOME",
            amount: "1.0",
            tokenSymbol: "ETH",
            tokenBalance: 10.0,
            tokenDecimals: 18,
            contractAddress: nil,
            previousTransactions: [makeTx(to: "0xSOME")]
        )
        XCTAssertFalse(result.findings.contains { $0.title == "Large Transfer" })
    }

    // MARK: - Rule 3: Unlimited Approval (WC)

    func testUnlimitedApprovalDanger() {
        // approve(spender, type(uint256).max)
        let spenderPadded = String(repeating: "0", count: 24) + "aabbccdd11223344556677889900aabbccddeeff"
        let maxUint = String(repeating: "f", count: 64)
        let calldata = "0x095ea7b3" + spenderPadded + maxUint

        let result = engine.assessWCTransaction(
            to: "0xTokenContract",
            value: "0x0",
            data: calldata,
            previousTransactions: [makeTx(to: "0xTokenContract")]
        )
        XCTAssertTrue(result.findings.contains { $0.title == "Unlimited Token Approval" })
        XCTAssertEqual(result.overallLevel, .danger)
    }

    func testLimitedApprovalWarning() {
        let spenderPadded = String(repeating: "0", count: 24) + "aabbccdd11223344556677889900aabbccddeeff"
        let limitedAmount = String(repeating: "0", count: 48) + String(repeating: "a", count: 16)
        let calldata = "0x095ea7b3" + spenderPadded + limitedAmount

        let result = engine.assessWCTransaction(
            to: "0xTokenContract",
            value: "0x0",
            data: calldata,
            previousTransactions: [makeTx(to: "0xTokenContract")]
        )
        XCTAssertTrue(result.findings.contains { $0.title == "Token Approval" })
        XCTAssertFalse(result.findings.contains { $0.title == "Unlimited Token Approval" })
    }

    // MARK: - Rule 4: Known Phishing

    func testKnownPhishingDanger() {
        // 0x0000000000000000000000000000000000000000 is in the blocklist
        let result = engine.assess(
            to: "0x0000000000000000000000000000000000000000",
            amount: "1.0",
            tokenSymbol: "ETH",
            tokenBalance: 10.0,
            tokenDecimals: 18,
            contractAddress: nil,
            previousTransactions: []
        )
        XCTAssertTrue(result.findings.contains { $0.title == "Known Phishing Address" })
        XCTAssertEqual(result.overallLevel, .danger)
    }

    func testCleanAddressNotFlagged() {
        let result = engine.assess(
            to: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045",
            amount: "1.0",
            tokenSymbol: "ETH",
            tokenBalance: 10.0,
            tokenDecimals: 18,
            contractAddress: nil,
            previousTransactions: [makeTx(to: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045")]
        )
        XCTAssertFalse(result.findings.contains { $0.title == "Known Phishing Address" })
    }

    // MARK: - Rule 5: Zero-Value Transfer

    func testZeroValueWarning() {
        let result = engine.assess(
            to: "0xSOME",
            amount: "0",
            tokenSymbol: "ETH",
            tokenBalance: 10.0,
            tokenDecimals: 18,
            contractAddress: nil,
            previousTransactions: [makeTx(to: "0xSOME")]
        )
        XCTAssertTrue(result.findings.contains { $0.title == "Zero-Value Transfer" })
    }

    // MARK: - Safe Transaction

    func testSafeTransactionNoFindings() {
        let addr = "0xSAFE"
        let result = engine.assess(
            to: addr,
            amount: "1.0",
            tokenSymbol: "ETH",
            tokenBalance: 10.0,
            tokenDecimals: 18,
            contractAddress: nil,
            previousTransactions: [makeTx(to: addr)]
        )
        XCTAssertEqual(result.overallLevel, .safe)
        XCTAssertTrue(result.findings.isEmpty)
    }

    // MARK: - Precedence: Danger overrides Warning

    func testDangerOverridesWarning() {
        // Phishing address (danger) + new address (warning) + zero-value (warning)
        let result = engine.assess(
            to: "0x0000000000000000000000000000000000000000",
            amount: "0",
            tokenSymbol: "ETH",
            tokenBalance: 10.0,
            tokenDecimals: 18,
            contractAddress: nil,
            previousTransactions: []
        )
        // Should have findings from multiple rules
        XCTAssertTrue(result.findings.contains { $0.title == "Known Phishing Address" })
        XCTAssertTrue(result.findings.contains { $0.title == "New Address" })
        // Overall must be danger, not warning
        XCTAssertEqual(result.overallLevel, .danger)
    }

    func testMultipleWarningsStayWarning() {
        // New address (warning) + large amount (warning) — no danger
        let result = engine.assess(
            to: "0xNEVERSEEN",
            amount: "8.0",
            tokenSymbol: "ETH",
            tokenBalance: 10.0,
            tokenDecimals: 18,
            contractAddress: nil,
            previousTransactions: []
        )
        XCTAssertTrue(result.findings.contains { $0.title == "New Address" })
        XCTAssertTrue(result.findings.contains { $0.title == "Large Transfer" })
        XCTAssertEqual(result.overallLevel, .warning)
    }

    // MARK: - WC: Zero-Value + No Data

    func testWCZeroValueNoDataWarning() {
        let result = engine.assessWCTransaction(
            to: "0xSOME",
            value: "0x0",
            data: nil,
            previousTransactions: [makeTx(to: "0xSOME")]
        )
        XCTAssertTrue(result.findings.contains { $0.title == "Zero-Value Transfer" })
    }

    // MARK: - WC: Contract Creation

    func testWCContractCreationWarning() {
        let result = engine.assessWCTransaction(
            to: nil,
            value: "0x0",
            data: "0x6060604052",
            previousTransactions: []
        )
        XCTAssertTrue(result.findings.contains { $0.title == "Contract Creation" })
    }
}
