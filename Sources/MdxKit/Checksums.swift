import Foundation

public enum Adler32 {
    public static func checksum(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        // Process in chunks so the modulo is applied before overflow.
        let modulus: UInt32 = 65521
        var iterator = data.makeIterator()
        var pending = data.count
        while pending > 0 {
            let chunk = min(pending, 3800)
            for _ in 0 ..< chunk {
                guard let byte = iterator.next() else { break }
                a &+= UInt32(byte)
                b &+= a
            }
            a %= modulus
            b %= modulus
            pending -= chunk
        }
        return (b << 16) | a
    }
}
