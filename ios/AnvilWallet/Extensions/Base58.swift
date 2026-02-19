import Foundation

/// Base58 encoding and decoding for Solana addresses and transaction data.
///
/// Uses the Bitcoin/Solana alphabet: `123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz`
/// (no 0, O, I, l to avoid visual ambiguity).
enum Base58 {
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

    // Reverse lookup table: ASCII byte -> alphabet index (255 = invalid)
    private static let decodeTable: [UInt8] = {
        var table = [UInt8](repeating: 255, count: 128)
        for (index, char) in alphabet.enumerated() {
            table[Int(char.asciiValue!)] = UInt8(index)
        }
        return table
    }()

    /// Decodes a Base58-encoded string to raw bytes.
    /// Returns nil if the string contains characters not in the Base58 alphabet.
    static func decode(_ string: String) -> Data? {
        var result: [UInt8] = [0]
        for char in string {
            guard let ascii = char.asciiValue, ascii < 128 else { return nil }
            let charIndex = decodeTable[Int(ascii)]
            guard charIndex != 255 else { return nil }

            var carry = Int(charIndex)
            for j in stride(from: result.count - 1, through: 0, by: -1) {
                carry += 58 * Int(result[j])
                result[j] = UInt8(carry % 256)
                carry /= 256
            }
            while carry > 0 {
                result.insert(UInt8(carry % 256), at: 0)
                carry /= 256
            }
        }

        // Add leading zeros
        let leadingZeros = string.prefix(while: { $0 == "1" }).count
        let zeros = [UInt8](repeating: 0, count: leadingZeros)
        // Remove leading zero from bignum result
        let stripped = result.drop(while: { $0 == 0 })
        return Data(zeros + stripped)
    }

    /// Encodes raw bytes to a Base58 string.
    static func encode(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }

        // Count leading zeros
        let leadingZeros = data.prefix(while: { $0 == 0 }).count

        // Convert to base58 using repeated division (skip leading zeros already counted)
        var bytes = [UInt8](data.dropFirst(leadingZeros))
        var result: [UInt8] = []

        while !bytes.isEmpty {
            var remainder = 0
            var next: [UInt8] = []
            for byte in bytes {
                let accumulator = remainder * 256 + Int(byte)
                let digit = accumulator / 58
                remainder = accumulator % 58
                if !next.isEmpty || digit > 0 {
                    next.append(UInt8(digit))
                }
            }
            result.insert(UInt8(remainder), at: 0)
            bytes = next
        }

        // Add leading '1's for each leading zero byte
        let prefix = String(repeating: "1", count: leadingZeros)
        let encoded = result.map { alphabet[Int($0)] }
        return prefix + String(encoded)
    }
}

// MARK: - Data Hex Initializer

extension Data {
    /// Creates Data from a hex string (with or without "0x" prefix).
    init?(hexString: String) {
        let hex = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
}
