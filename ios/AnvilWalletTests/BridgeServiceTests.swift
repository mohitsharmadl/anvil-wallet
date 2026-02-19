import XCTest
@testable import AnvilWallet

final class BridgeServiceTests: XCTestCase {

    private let service = BridgeService.shared

    // MARK: - supportedChains

    func testSupportedChainsNotEmpty() {
        XCTAssertFalse(BridgeService.supportedChains.isEmpty)
    }

    func testSupportedChainsContainsEthereum() {
        let eth = BridgeService.supportedChains.first { $0.name == "Ethereum" }
        XCTAssertNotNil(eth)
        XCTAssertEqual(eth?.chainId, 1)
    }

    func testSupportedChainsContainsPolygon() {
        let poly = BridgeService.supportedChains.first { $0.name == "Polygon" }
        XCTAssertNotNil(poly)
        XCTAssertEqual(poly?.chainId, 137)
    }

    func testSupportedChainsContainsArbitrum() {
        let arb = BridgeService.supportedChains.first { $0.name == "Arbitrum" }
        XCTAssertNotNil(arb)
        XCTAssertEqual(arb?.chainId, 42161)
    }

    func testSupportedChainsAllHavePositiveChainId() {
        for chain in BridgeService.supportedChains {
            XCTAssertGreaterThan(chain.chainId, 0, "\(chain.name) should have a positive chain ID")
        }
    }

    func testSupportedChainsAllHaveNames() {
        for chain in BridgeService.supportedChains {
            XCTAssertFalse(chain.name.isEmpty, "Chain with ID \(chain.chainId) should have a name")
        }
    }

    func testSupportedChainsHasExpectedCount() {
        // Ethereum, Polygon, Arbitrum, Optimism, Base, BSC, Avalanche
        XCTAssertEqual(BridgeService.supportedChains.count, 7)
    }

    // MARK: - nativeTokenAddress

    func testNativeTokenAddressReturnsStandardAddress() {
        let address = BridgeService.nativeTokenAddress(chainId: 1)
        XCTAssertEqual(address, "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee")
    }

    func testNativeTokenAddressSameForAllChains() {
        let ethAddress = BridgeService.nativeTokenAddress(chainId: 1)
        let polyAddress = BridgeService.nativeTokenAddress(chainId: 137)
        let arbAddress = BridgeService.nativeTokenAddress(chainId: 42161)
        XCTAssertEqual(ethAddress, polyAddress)
        XCTAssertEqual(polyAddress, arbAddress)
    }

    func testNativeTokenAddressIsLowercase() {
        let address = BridgeService.nativeTokenAddress(chainId: 1)
        XCTAssertEqual(address, address.lowercased())
    }

    func testNativeTokenAddressHas0xPrefix() {
        let address = BridgeService.nativeTokenAddress(chainId: 1)
        XCTAssertTrue(address.hasPrefix("0x"))
    }

    func testNativeTokenAddressIs42Characters() {
        let address = BridgeService.nativeTokenAddress(chainId: 1)
        XCTAssertEqual(address.count, 42, "EVM address should be 42 characters including 0x prefix")
    }

    // MARK: - formatAmount

    func testFormatAmountLargeValue() {
        let result = service.formatAmount(123.456789)
        XCTAssertEqual(result, "123.4568") // >= 1, so 4 decimal places
    }

    func testFormatAmountSmallValue() {
        let result = service.formatAmount(0.123456789)
        XCTAssertEqual(result, "0.123457") // < 1 and > 0, so 6 decimal places
    }

    func testFormatAmountZero() {
        let result = service.formatAmount(0)
        XCTAssertEqual(result, "0")
    }

    func testFormatAmountExactlyOne() {
        let result = service.formatAmount(1.0)
        XCTAssertEqual(result, "1.0000")
    }

    func testFormatAmountVerySmall() {
        let result = service.formatAmount(0.000001)
        XCTAssertEqual(result, "0.000001")
    }

    // MARK: - parseQuoteResponse

    func testParseQuoteResponseValidJSON() throws {
        let json: [String: Any] = [
            "result": [
                "routes": [
                    [
                        "usedBridgeNames": ["Stargate"],
                        "toAmount": "1000000000000000000",
                        "serviceTime": 300,
                        "outputValueInUsd": 2500.0,
                        "totalGasFeesInUsd": 5.0,
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let routes = try service.parseQuoteResponse(data: data, decimals: 18)
        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(routes[0].bridgeName, "Stargate")
        XCTAssertEqual(routes[0].estimatedOutputAmount, 1.0, accuracy: 0.0001)
        XCTAssertEqual(routes[0].estimatedGasUsd, 5.0, accuracy: 0.01)
        XCTAssertEqual(routes[0].estimatedTimeMinutes, 5)
    }

    func testParseQuoteResponseMultipleRoutes() throws {
        let json: [String: Any] = [
            "result": [
                "routes": [
                    [
                        "usedBridgeNames": ["Stargate"],
                        "toAmount": "1000000000000000000",
                        "serviceTime": 300,
                        "outputValueInUsd": 2500.0,
                        "totalGasFeesInUsd": 5.0,
                    ],
                    [
                        "usedBridgeNames": ["Hop"],
                        "toAmount": "990000000000000000",
                        "serviceTime": 600,
                        "outputValueInUsd": 2475.0,
                        "totalGasFeesInUsd": 3.0,
                    ],
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let routes = try service.parseQuoteResponse(data: data, decimals: 18)
        XCTAssertEqual(routes.count, 2)
        XCTAssertEqual(routes[1].bridgeName, "Hop")
        XCTAssertEqual(routes[1].estimatedTimeMinutes, 10)
    }

    func testParseQuoteResponseEmptyRoutes() throws {
        let json: [String: Any] = [
            "result": [
                "routes": [] as [[String: Any]]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let routes = try service.parseQuoteResponse(data: data, decimals: 18)
        XCTAssertTrue(routes.isEmpty)
    }

    func testParseQuoteResponseMissingResult() throws {
        let json: [String: Any] = ["status": "ok"]
        let data = try JSONSerialization.data(withJSONObject: json)
        let routes = try service.parseQuoteResponse(data: data, decimals: 18)
        XCTAssertTrue(routes.isEmpty)
    }

    func testParseQuoteResponseMissingRoutes() throws {
        let json: [String: Any] = [
            "result": [
                "someOtherKey": "value"
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let routes = try service.parseQuoteResponse(data: data, decimals: 18)
        XCTAssertTrue(routes.isEmpty)
    }

    func testParseQuoteResponseMalformedJSON() throws {
        let data = "not json".data(using: .utf8)!
        // JSONSerialization will throw, which parseQuoteResponse lets propagate
        XCTAssertThrowsError(try service.parseQuoteResponse(data: data, decimals: 18))
    }

    func testParseQuoteResponseMultipleBridgeNames() throws {
        let json: [String: Any] = [
            "result": [
                "routes": [
                    [
                        "usedBridgeNames": ["Stargate", "Hop"],
                        "toAmount": "1000000",
                        "serviceTime": 180,
                        "outputValueInUsd": 1.0,
                        "totalGasFeesInUsd": 0.5,
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let routes = try service.parseQuoteResponse(data: data, decimals: 6)
        XCTAssertEqual(routes[0].bridgeName, "Stargate + Hop")
    }

    func testParseQuoteResponseMinTimeIsOne() throws {
        let json: [String: Any] = [
            "result": [
                "routes": [
                    [
                        "usedBridgeNames": ["Fast"],
                        "toAmount": "1000000",
                        "serviceTime": 10, // 10 seconds -> 0 minutes, but min is 1
                        "outputValueInUsd": 1.0,
                        "totalGasFeesInUsd": 0.1,
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let routes = try service.parseQuoteResponse(data: data, decimals: 6)
        XCTAssertEqual(routes[0].estimatedTimeMinutes, 1, "Minimum time should be 1 minute")
    }

    func testParseQuoteResponseMissingGasDefaultsToZero() throws {
        let json: [String: Any] = [
            "result": [
                "routes": [
                    [
                        "usedBridgeNames": ["Bridge"],
                        "toAmount": "1000000",
                        "serviceTime": 120,
                        "outputValueInUsd": 1.0,
                        // No totalGasFeesInUsd
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let routes = try service.parseQuoteResponse(data: data, decimals: 6)
        XCTAssertEqual(routes[0].estimatedGasUsd, 0, accuracy: 0.001)
    }

    func testParseQuoteResponseWithSixDecimals() throws {
        let json: [String: Any] = [
            "result": [
                "routes": [
                    [
                        "usedBridgeNames": ["Across"],
                        "toAmount": "5000000", // 5.0 with 6 decimals
                        "serviceTime": 60,
                        "outputValueInUsd": 5.0,
                        "totalGasFeesInUsd": 1.0,
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let routes = try service.parseQuoteResponse(data: data, decimals: 6)
        XCTAssertEqual(routes[0].estimatedOutputAmount, 5.0, accuracy: 0.0001)
    }

    // MARK: - BridgeRoute Model

    func testBridgeRouteHasUniqueIds() {
        let route1 = BridgeService.BridgeRoute(
            bridgeName: "A",
            estimatedOutputAmount: 1.0,
            estimatedOutputFormatted: "1.0000",
            estimatedGasUsd: 0.5,
            estimatedTimeMinutes: 5,
            outputSymbol: "ETH",
            routeJSON: [:]
        )
        let route2 = BridgeService.BridgeRoute(
            bridgeName: "A",
            estimatedOutputAmount: 1.0,
            estimatedOutputFormatted: "1.0000",
            estimatedGasUsd: 0.5,
            estimatedTimeMinutes: 5,
            outputSymbol: "ETH",
            routeJSON: [:]
        )
        XCTAssertNotEqual(route1.id, route2.id)
    }

    // MARK: - BridgeError

    func testBridgeErrorDescriptions() {
        XCTAssertNotNil(BridgeService.BridgeError.buildTxFailed.errorDescription)
        XCTAssertNotNil(BridgeService.BridgeError.invalidTxData.errorDescription)
    }
}
