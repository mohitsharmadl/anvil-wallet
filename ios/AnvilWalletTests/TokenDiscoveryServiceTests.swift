import XCTest
@testable import AnvilWallet

final class TokenDiscoveryServiceTests: XCTestCase {

    private let service = TokenDiscoveryService.shared
    private let testSuite = "com.anvilwallet.discoveredTokens."

    override func tearDown() {
        // Clean up any keys written during tests
        for addr in ["0xaaaa", "0xbbbb", "0xAAAA", "0xCcCc"] {
            service.clearPersistedTokens(for: addr)
        }
        super.tearDown()
    }

    // MARK: - Key Scoping

    func testPersistenceKeyIsScopedToAddress() {
        // Write tokens for address A, verify address B sees nothing
        let tokenA = TokenDiscoveryService.DiscoveredToken(
            contractAddress: "0xtoken1",
            symbol: "TKA",
            name: "Token A",
            decimals: 18,
            chain: "ethereum"
        )
        let data = try! JSONEncoder().encode([tokenA])
        let keyA = testSuite + "0xaaaa"
        UserDefaults.standard.set(data, forKey: keyA)

        let loadedA = service.loadPersistedTokens(for: "0xaaaa")
        let loadedB = service.loadPersistedTokens(for: "0xbbbb")

        XCTAssertEqual(loadedA.count, 1)
        XCTAssertEqual(loadedA[0].symbol, "TKA")
        XCTAssertTrue(loadedB.isEmpty, "Different address should not see address A's tokens")
    }

    func testPersistenceKeyIsCaseInsensitive() {
        let token = TokenDiscoveryService.DiscoveredToken(
            contractAddress: "0xtoken2",
            symbol: "TKB",
            name: "Token B",
            decimals: 6,
            chain: "ethereum"
        )
        let data = try! JSONEncoder().encode([token])
        let key = testSuite + "0xcccc" // lowercased
        UserDefaults.standard.set(data, forKey: key)

        // Load with mixed-case address
        let loaded = service.loadPersistedTokens(for: "0xCcCc")
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].symbol, "TKB")
    }

    func testClearRemovesOnlyScopedTokens() {
        let tokenA = TokenDiscoveryService.DiscoveredToken(
            contractAddress: "0xtoken1",
            symbol: "TKA",
            name: "Token A",
            decimals: 18,
            chain: "ethereum"
        )
        let tokenB = TokenDiscoveryService.DiscoveredToken(
            contractAddress: "0xtoken2",
            symbol: "TKB",
            name: "Token B",
            decimals: 6,
            chain: "ethereum"
        )

        let dataA = try! JSONEncoder().encode([tokenA])
        let dataB = try! JSONEncoder().encode([tokenB])
        UserDefaults.standard.set(dataA, forKey: testSuite + "0xaaaa")
        UserDefaults.standard.set(dataB, forKey: testSuite + "0xbbbb")

        // Clear only address A
        service.clearPersistedTokens(for: "0xaaaa")

        XCTAssertTrue(service.loadPersistedTokens(for: "0xaaaa").isEmpty)
        XCTAssertEqual(service.loadPersistedTokens(for: "0xbbbb").count, 1,
                       "Address B tokens should survive clearing address A")
    }

    func testLoadReturnsEmptyForUnknownAddress() {
        let loaded = service.loadPersistedTokens(for: "0x_never_stored_anything_here")
        XCTAssertTrue(loaded.isEmpty)
    }

    func testRoundTripMultipleTokens() {
        let tokens = [
            TokenDiscoveryService.DiscoveredToken(
                contractAddress: "0xusdc", symbol: "USDC", name: "USD Coin",
                decimals: 6, chain: "ethereum"
            ),
            TokenDiscoveryService.DiscoveredToken(
                contractAddress: "0xdai", symbol: "DAI", name: "Dai Stablecoin",
                decimals: 18, chain: "ethereum"
            ),
        ]
        let data = try! JSONEncoder().encode(tokens)
        UserDefaults.standard.set(data, forKey: testSuite + "0xaaaa")

        let loaded = service.loadPersistedTokens(for: "0xaaaa")
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(Set(loaded.map(\.symbol)), Set(["USDC", "DAI"]))
    }
}
