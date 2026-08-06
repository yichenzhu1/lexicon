import Foundation

/// RIPEMD-128 hash, used by MDict to derive the key that scrambles the
/// keyword index of "encrypted" (Encrypted=2) dictionaries.
public enum RIPEMD128 {
    // Message word selection order, left and right lines.
    private static let r: [Int] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
        7, 4, 13, 1, 10, 6, 15, 3, 12, 0, 9, 5, 2, 14, 11, 8,
        3, 10, 14, 4, 9, 15, 8, 1, 2, 7, 0, 6, 13, 11, 5, 12,
        1, 9, 11, 10, 0, 8, 12, 4, 13, 3, 7, 15, 14, 5, 6, 2,
    ]
    private static let rp: [Int] = [
        5, 14, 7, 0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12,
        6, 11, 3, 7, 0, 13, 5, 10, 14, 15, 8, 12, 4, 9, 1, 2,
        15, 5, 1, 3, 7, 14, 6, 9, 11, 8, 12, 2, 10, 0, 4, 13,
        8, 6, 4, 1, 3, 11, 15, 0, 5, 12, 2, 13, 9, 7, 10, 14,
    ]
    // Rotation amounts, left and right lines.
    private static let s: [UInt32] = [
        11, 14, 15, 12, 5, 8, 7, 9, 11, 13, 14, 15, 6, 7, 9, 8,
        7, 6, 8, 13, 11, 9, 7, 15, 7, 12, 15, 9, 11, 7, 13, 12,
        11, 13, 6, 7, 14, 9, 13, 15, 14, 8, 13, 6, 5, 12, 7, 5,
        11, 12, 14, 15, 14, 15, 9, 8, 9, 14, 5, 6, 8, 6, 5, 12,
    ]
    private static let sp: [UInt32] = [
        8, 9, 9, 11, 13, 15, 15, 5, 7, 7, 8, 11, 14, 14, 12, 6,
        9, 13, 15, 7, 12, 8, 9, 11, 7, 7, 12, 7, 6, 15, 13, 11,
        9, 7, 15, 11, 8, 6, 6, 14, 12, 13, 5, 14, 13, 13, 7, 5,
        15, 5, 8, 11, 14, 14, 6, 14, 6, 9, 12, 9, 12, 5, 15, 8,
    ]

    private static func f(_ j: Int, _ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        switch j {
        case 0 ..< 16: return x ^ y ^ z
        case 16 ..< 32: return (x & y) | (~x & z)
        case 32 ..< 48: return (x | ~y) ^ z
        default: return (x & z) | (y & ~z)
        }
    }

    private static func K(_ j: Int) -> UInt32 {
        switch j {
        case 0 ..< 16: return 0x0000_0000
        case 16 ..< 32: return 0x5A82_7999
        case 32 ..< 48: return 0x6ED9_EBA1
        default: return 0x8F1B_BCDC
        }
    }

    private static func Kp(_ j: Int) -> UInt32 {
        switch j {
        case 0 ..< 16: return 0x50A2_8BE6
        case 16 ..< 32: return 0x5C4D_D124
        case 32 ..< 48: return 0x6D70_3EF3
        default: return 0x0000_0000
        }
    }

    private static func rol(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x << n) | (x >> (32 - n))
    }

    public static func hash(_ message: Data) -> Data {
        var h: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476]

        // MD4-style padding: 0x80, zeros, then 64-bit little-endian bit length.
        var padded = message
        let bitLength = UInt64(message.count) * 8
        padded.append(0x80)
        while padded.count % 64 != 56 { padded.append(0) }
        withUnsafeBytes(of: bitLength.littleEndian) { padded.append(contentsOf: $0) }

        let base = padded.startIndex
        for blockStart in stride(from: 0, to: padded.count, by: 64) {
            var x = [UInt32](repeating: 0, count: 16)
            for i in 0 ..< 16 {
                let o = base + blockStart + i * 4
                x[i] = UInt32(padded[o]) | UInt32(padded[o + 1]) << 8
                    | UInt32(padded[o + 2]) << 16 | UInt32(padded[o + 3]) << 24
            }

            var a = h[0], b = h[1], c = h[2], d = h[3]
            var ap = h[0], bp = h[1], cp = h[2], dp = h[3]

            for j in 0 ..< 64 {
                var t = rol(a &+ f(j, b, c, d) &+ x[r[j]] &+ K(j), s[j])
                a = d; d = c; c = b; b = t
                t = rol(ap &+ f(63 - j, bp, cp, dp) &+ x[rp[j]] &+ Kp(j), sp[j])
                ap = dp; dp = cp; cp = bp; bp = t
            }

            let t = h[1] &+ c &+ dp
            h[1] = h[2] &+ d &+ ap
            h[2] = h[3] &+ a &+ bp
            h[3] = h[0] &+ b &+ cp
            h[0] = t
        }

        var digest = Data(capacity: 16)
        for word in h {
            withUnsafeBytes(of: word.littleEndian) { digest.append(contentsOf: $0) }
        }
        return digest
    }
}
