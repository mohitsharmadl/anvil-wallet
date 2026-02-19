import XCTest
@testable import AnvilWallet

final class Base58Tests: XCTestCase {

    // MARK: - Data(hexString:) Extension

    func testHexStringValidWithPrefix() {
        let data = Data(hexString: "0xdeadbeef")
        XCTAssertNotNil(data)
        XCTAssertEqual(data?.count, 4)
        XCTAssertEqual(data, Data([0xde, 0xad, 0xbe, 0xef]))
    }

    func testHexStringValidWithoutPrefix() {
        let data = Data(hexString: "deadbeef")
        XCTAssertNotNil(data)
        XCTAssertEqual(data?.count, 4)
        XCTAssertEqual(data, Data([0xde, 0xad, 0xbe, 0xef]))
    }

    func testHexStringOddLengthReturnsNil() {
        let data = Data(hexString: "0xabc")
        XCTAssertNil(data, "Odd-length hex string should return nil")
    }

    func testHexStringOddLengthWithoutPrefixReturnsNil() {
        let data = Data(hexString: "abc")
        XCTAssertNil(data, "Odd-length hex string without prefix should return nil")
    }

    func testHexStringEmptyString() {
        let data = Data(hexString: "")
        XCTAssertNotNil(data)
        XCTAssertEqual(data?.count, 0)
    }

    func testHexStringJustPrefix() {
        let data = Data(hexString: "0x")
        XCTAssertNotNil(data)
        XCTAssertEqual(data?.count, 0)
    }

    func testHexStringInvalidCharactersReturnsNil() {
        let data = Data(hexString: "0xGGHH")
        XCTAssertNil(data, "Invalid hex characters should return nil")
    }

    func testHexStringMixedCaseValid() {
        let lower = Data(hexString: "0xaabbccdd")
        let upper = Data(hexString: "0xAABBCCDD")
        XCTAssertNotNil(lower)
        XCTAssertNotNil(upper)
        XCTAssertEqual(lower, upper)
    }

    func testHexStringAllZeros() {
        let data = Data(hexString: "0x0000")
        XCTAssertNotNil(data)
        XCTAssertEqual(data, Data([0x00, 0x00]))
    }

    func testHexStringLongInput() {
        // 32 bytes (Ethereum hash)
        let hex = "0x" + String(repeating: "ab", count: 32)
        let data = Data(hexString: hex)
        XCTAssertNotNil(data)
        XCTAssertEqual(data?.count, 32)
    }

    func testHexStringSingleByte() {
        let data = Data(hexString: "ff")
        XCTAssertNotNil(data)
        XCTAssertEqual(data, Data([0xff]))
    }

    func testHexStringSpacesReturnsNil() {
        let data = Data(hexString: "de ad")
        XCTAssertNil(data, "Hex string with spaces should return nil")
    }

    // MARK: - Base58 Encode/Decode Roundtrip

    func testRoundtripSimple() {
        let original = Data([0x01, 0x02, 0x03, 0x04])
        let encoded = Base58.encode(original)
        let decoded = Base58.decode(encoded)
        XCTAssertEqual(decoded, original)
    }

    func testRoundtripLargeData() {
        let original = Data((0..<64).map { UInt8($0) })
        let encoded = Base58.encode(original)
        let decoded = Base58.decode(encoded)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Base58 Known Solana Address

    func testDecodeSolanaAddress() {
        // Known Solana system program address: 11111111111111111111111111111111
        let address = "11111111111111111111111111111111"
        let decoded = Base58.decode(address)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.count, 32, "Solana addresses are 32 bytes")
        // All zeros (each '1' in Base58 represents a leading zero byte)
        XCTAssertEqual(decoded, Data(repeating: 0, count: 32))
    }

    func testRoundtripSolanaAddress() {
        // A real Solana address
        let address = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
        let decoded = Base58.decode(address)
        XCTAssertNotNil(decoded)
        let reencoded = Base58.encode(decoded!)
        XCTAssertEqual(reencoded, address)
    }

    // MARK: - Base58 Leading Zeros

    func testLeadingZeroBytes() {
        // Data starting with zero bytes
        let original = Data([0x00, 0x00, 0x01, 0x02])
        let encoded = Base58.encode(original)
        XCTAssertTrue(encoded.hasPrefix("11"), "Leading zero bytes should map to leading '1's")
        let decoded = Base58.decode(encoded)
        XCTAssertEqual(decoded, original)
    }

    func testAllZeroBytes() {
        let original = Data([0x00, 0x00, 0x00])
        let encoded = Base58.encode(original)
        XCTAssertEqual(encoded, "111")
        let decoded = Base58.decode(encoded)
        XCTAssertEqual(decoded, original)
    }

    func testSingleZeroByte() {
        let original = Data([0x00])
        let encoded = Base58.encode(original)
        XCTAssertEqual(encoded, "1")
        let decoded = Base58.decode(encoded)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Base58 Invalid Characters

    func testDecodeInvalidCharacterZero() {
        // '0' is not in the Base58 alphabet
        let result = Base58.decode("0InvalidBase58")
        XCTAssertNil(result)
    }

    func testDecodeInvalidCharacterO() {
        // 'O' (uppercase oh) is not in the Base58 alphabet
        let result = Base58.decode("OOOOO")
        XCTAssertNil(result)
    }

    func testDecodeInvalidCharacterI() {
        // 'I' (uppercase i) is not in the Base58 alphabet
        let result = Base58.decode("IIIII")
        XCTAssertNil(result)
    }

    func testDecodeInvalidCharacterl() {
        // 'l' (lowercase L) is not in the Base58 alphabet
        let result = Base58.decode("lllll")
        XCTAssertNil(result)
    }

    func testDecodeInvalidNonASCII() {
        let result = Base58.decode("abc\u{00FF}def")
        XCTAssertNil(result)
    }

    // MARK: - Base58 Empty Data

    func testEncodeEmptyData() {
        let encoded = Base58.encode(Data())
        XCTAssertEqual(encoded, "")
    }

    func testDecodeEmptyString() {
        let decoded = Base58.decode("")
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.count, 0)
    }

    // MARK: - Base58 Known Vectors

    func testEncodeKnownVector() {
        // "Hello World" in Base58
        let data = "Hello World".data(using: .utf8)!
        let encoded = Base58.encode(data)
        XCTAssertEqual(encoded, "JxF12TrwUP45BMd")
    }

    func testDecodeKnownVector() {
        let decoded = Base58.decode("JxF12TrwUP45BMd")
        XCTAssertNotNil(decoded)
        XCTAssertEqual(String(data: decoded!, encoding: .utf8), "Hello World")
    }
}
