import XCTest
@testable import AnvilWallet

final class AddressBookServiceTests: XCTestCase {

    private let service = AddressBookService.shared
    private static let storageKey = "com.anvilwallet.addressBook"

    override func setUp() {
        super.setUp()
        // Clear all addresses before each test
        for addr in service.allAddresses() {
            service.removeAddress(id: addr.id)
        }
    }

    override func tearDown() {
        // Clean up after tests
        for addr in service.allAddresses() {
            service.removeAddress(id: addr.id)
        }
        super.tearDown()
    }

    // MARK: - Add

    func testAddAddressReturnsTrue() {
        let result = service.addAddress(
            name: "Alice",
            address: "0x1234567890abcdef1234567890abcdef12345678",
            chain: "ethereum"
        )
        XCTAssertTrue(result)
    }

    func testAddAddressIncreasesCount() {
        let before = service.allAddresses().count
        service.addAddress(
            name: "Bob",
            address: "0xaabbccddee11223344556677889900aabbccddee",
            chain: "ethereum"
        )
        XCTAssertEqual(service.allAddresses().count, before + 1)
    }

    func testAddedAddressHasCorrectProperties() {
        service.addAddress(
            name: "Charlie",
            address: "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
            chain: "ethereum",
            notes: "Test contact"
        )
        let found = service.allAddresses().first { $0.address == "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" }
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.name, "Charlie")
        XCTAssertEqual(found?.chain, "ethereum")
        XCTAssertEqual(found?.notes, "Test contact")
    }

    // MARK: - Deduplication

    func testDuplicateAddressReturnsFalse() {
        let addr = "0x1111111111111111111111111111111111111111"
        service.addAddress(name: "First", address: addr, chain: "ethereum")
        let result = service.addAddress(name: "Second", address: addr, chain: "ethereum")
        XCTAssertFalse(result)
    }

    func testDuplicateIsCaseInsensitiveForEVM() {
        service.addAddress(
            name: "Lower",
            address: "0xaabbccddee11223344556677889900aabbccddee",
            chain: "ethereum"
        )
        let result = service.addAddress(
            name: "Upper",
            address: "0xAABBCCDDEE11223344556677889900AABBCCDDEE",
            chain: "ethereum"
        )
        XCTAssertFalse(result, "EVM addresses should be deduplicated case-insensitively")
    }

    func testSameAddressDifferentChainAllowed() {
        let addr = "0x2222222222222222222222222222222222222222"
        service.addAddress(name: "ETH", address: addr, chain: "ethereum")
        let result = service.addAddress(name: "SOL", address: addr, chain: "solana")
        XCTAssertTrue(result, "Same address on different chains should be allowed")
    }

    func testEVMChainsNormalize() {
        // polygon, arbitrum, etc. should normalize to "ethereum" for dedup
        let addr = "0x3333333333333333333333333333333333333333"
        service.addAddress(name: "Polygon", address: addr, chain: "polygon")
        let result = service.addAddress(name: "Arbitrum", address: addr, chain: "arbitrum")
        XCTAssertFalse(result, "Polygon and Arbitrum share EVM addresses, should be deduplicated")
    }

    // MARK: - Remove

    func testRemoveAddress() {
        service.addAddress(
            name: "ToRemove",
            address: "0x4444444444444444444444444444444444444444",
            chain: "ethereum"
        )
        let addr = service.allAddresses().first { $0.name == "ToRemove" }
        XCTAssertNotNil(addr)

        service.removeAddress(id: addr!.id)
        let afterRemove = service.allAddresses().first { $0.name == "ToRemove" }
        XCTAssertNil(afterRemove)
    }

    func testRemoveNonExistentIdDoesNothing() {
        let before = service.allAddresses().count
        service.removeAddress(id: UUID())
        XCTAssertEqual(service.allAddresses().count, before)
    }

    // MARK: - Update

    func testUpdateNameAndNotes() {
        service.addAddress(
            name: "Original",
            address: "0x5555555555555555555555555555555555555555",
            chain: "ethereum",
            notes: "Old notes"
        )
        let addr = service.allAddresses().first { $0.name == "Original" }!
        service.updateAddress(id: addr.id, name: "Updated", notes: "New notes")

        let updated = service.allAddresses().first { $0.id == addr.id }
        XCTAssertEqual(updated?.name, "Updated")
        XCTAssertEqual(updated?.notes, "New notes")
    }

    func testUpdateTrimsWhitespace() {
        service.addAddress(
            name: "Trimmed",
            address: "0x6666666666666666666666666666666666666666",
            chain: "ethereum"
        )
        let addr = service.allAddresses().first { $0.name == "Trimmed" }!
        service.updateAddress(id: addr.id, name: "  Padded Name  ", notes: "  Padded Notes  ")

        let updated = service.allAddresses().first { $0.id == addr.id }
        XCTAssertEqual(updated?.name, "Padded Name")
        XCTAssertEqual(updated?.notes, "Padded Notes")
    }

    // MARK: - isSaved

    func testIsSavedReturnsTrueForSavedAddress() {
        let addr = "0x7777777777777777777777777777777777777777"
        service.addAddress(name: "Saved", address: addr, chain: "ethereum")
        XCTAssertTrue(service.isSaved(address: addr, chain: "ethereum"))
    }

    func testIsSavedReturnsFalseForUnsavedAddress() {
        XCTAssertFalse(service.isSaved(address: "0x9999999999999999999999999999999999999999", chain: "ethereum"))
    }

    func testIsSavedIsCaseInsensitiveForEVM() {
        let addr = "0xaabbccddee11223344556677889900aabbccddee"
        service.addAddress(name: "Lower", address: addr, chain: "ethereum")
        XCTAssertTrue(service.isSaved(
            address: "0xAABBCCDDEE11223344556677889900AABBCCDDEE",
            chain: "ethereum"
        ))
    }

    func testIsSavedCrossChainEVM() {
        let addr = "0x8888888888888888888888888888888888888888"
        service.addAddress(name: "ETH", address: addr, chain: "ethereum")
        // Querying with "polygon" should still find it because polygon normalizes to "ethereum"
        XCTAssertTrue(service.isSaved(address: addr, chain: "polygon"))
    }

    // MARK: - Chain Filtering

    func testAddressesForChainFiltersByEVM() {
        service.addAddress(
            name: "ETH Contact",
            address: "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            chain: "ethereum"
        )
        service.addAddress(
            name: "SOL Contact",
            address: "So1anaAddress111111111111111111111111111",
            chain: "solana"
        )

        let ethAddresses = service.addresses(for: "ethereum")
        let solAddresses = service.addresses(for: "solana")

        XCTAssertTrue(ethAddresses.contains { $0.name == "ETH Contact" })
        XCTAssertFalse(ethAddresses.contains { $0.name == "SOL Contact" })
        XCTAssertTrue(solAddresses.contains { $0.name == "SOL Contact" })
        XCTAssertFalse(solAddresses.contains { $0.name == "ETH Contact" })
    }

    func testAddressesForPolygonReturnsEVMAddresses() {
        service.addAddress(
            name: "EVM Contact",
            address: "0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
            chain: "ethereum"
        )
        let polyAddresses = service.addresses(for: "polygon")
        XCTAssertTrue(polyAddresses.contains { $0.name == "EVM Contact" })
    }

    // MARK: - SavedAddress Model

    func testShortAddressTruncation() {
        let saved = SavedAddress(
            id: UUID(),
            name: "Test",
            address: "0x1234567890abcdef1234567890abcdef12345678",
            chain: "ethereum",
            notes: nil,
            dateAdded: Date()
        )
        XCTAssertEqual(saved.shortAddress, "0x1234...5678")
    }

    func testShortAddressShortInput() {
        let saved = SavedAddress(
            id: UUID(),
            name: "Test",
            address: "0x12345678",
            chain: "ethereum",
            notes: nil,
            dateAdded: Date()
        )
        // 10 chars, <= 12, returned as is
        XCTAssertEqual(saved.shortAddress, "0x12345678")
    }

    func testChainDisplayNameEthereum() {
        let saved = SavedAddress(
            id: UUID(), name: "T", address: "0x0", chain: "ethereum",
            notes: nil, dateAdded: Date()
        )
        XCTAssertEqual(saved.chainDisplayName, "Ethereum & EVM")
    }

    func testChainDisplayNameSolana() {
        let saved = SavedAddress(
            id: UUID(), name: "T", address: "addr", chain: "solana",
            notes: nil, dateAdded: Date()
        )
        XCTAssertEqual(saved.chainDisplayName, "Solana")
    }

    func testChainDisplayNameBitcoin() {
        let saved = SavedAddress(
            id: UUID(), name: "T", address: "bc1q", chain: "bitcoin",
            notes: nil, dateAdded: Date()
        )
        XCTAssertEqual(saved.chainDisplayName, "Bitcoin")
    }

    func testChainDisplayNameUnknown() {
        let saved = SavedAddress(
            id: UUID(), name: "T", address: "addr", chain: "cosmos",
            notes: nil, dateAdded: Date()
        )
        XCTAssertEqual(saved.chainDisplayName, "Cosmos")
    }

    // MARK: - Whitespace Trimming on Add

    func testAddTrimsWhitespace() {
        service.addAddress(
            name: "  Trimmed  ",
            address: "  0xCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC  ",
            chain: "ethereum",
            notes: "  Note  "
        )
        let found = service.allAddresses().last
        XCTAssertEqual(found?.name, "Trimmed")
        XCTAssertEqual(found?.address, "0xCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC")
        XCTAssertEqual(found?.notes, "Note")
    }
}
