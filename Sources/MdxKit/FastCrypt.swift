import Foundation

/// MDict's byte-swap scrambling applied to the keyword index when the header
/// declares Encrypted=2. The key is ripemd128(checksum + 0x3695 LE).
enum FastCrypt {
    static func decrypt(_ data: Data, key: Data) -> Data {
        var output = [UInt8](repeating: 0, count: data.count)
        let input = [UInt8](data)
        let keyBytes = [UInt8](key)
        var previous: UInt8 = 0x36
        for i in 0 ..< input.count {
            var t = (input[i] >> 4) | (input[i] << 4)
            t = t ^ previous ^ UInt8(truncatingIfNeeded: i) ^ keyBytes[i % keyBytes.count]
            previous = input[i]
            output[i] = t
        }
        return Data(output)
    }

    /// Derives the scrambling key for an encrypted keyword index block.
    /// `checksum` is bytes 4..<8 of the compressed block (the adler32 field).
    static func indexKey(checksum: Data) -> Data {
        var seed = checksum
        seed.append(contentsOf: [0x95, 0x36, 0x00, 0x00]) // 0x3695 little-endian UInt32
        return RIPEMD128.hash(seed)
    }
}
