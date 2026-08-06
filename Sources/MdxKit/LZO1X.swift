import Foundation

/// LZO1X decompressor, ported from the reference implementation
/// (rasky/go-lzo, itself derived from the original LZO code by
/// Markus F.X.J. Oberhumer). Older MDX files use LZO block compression.
public enum LZO1X {
    private static let m2MaxOffset = 0x0800

    public static func decompress(_ input: Data, expectedSize: Int = 0) throws -> Data {
        let src = [UInt8](input)
        var ip = 0
        var out = [UInt8]()
        out.reserveCapacity(expectedSize)

        func u8() throws -> Int {
            guard ip < src.count else { throw MdxError.corruptData("LZO input underrun") }
            defer { ip += 1 }
            return Int(src[ip])
        }

        func u16le() throws -> Int {
            guard ip + 1 < src.count else { throw MdxError.corruptData("LZO input underrun") }
            defer { ip += 2 }
            return Int(src[ip]) | (Int(src[ip + 1]) << 8)
        }

        func literals(_ n: Int) throws {
            guard ip + n <= src.count else { throw MdxError.corruptData("LZO input underrun") }
            out.append(contentsOf: src[ip ..< ip + n])
            ip += n
        }

        /// Reads the run-length extension: zero bytes add 255 each, the first
        /// non-zero byte adds its value plus `base`.
        func readMulti(_ base: Int) throws -> Int {
            var total = 0
            while true {
                let v = try u8()
                if v == 0 {
                    total += 255
                } else {
                    return total + v + base
                }
            }
        }

        func copyMatch(_ mPos: Int, _ n: Int) throws {
            guard mPos >= 0, mPos < out.count else {
                throw MdxError.corruptData("LZO lookbehind underrun")
            }
            if mPos + n > out.count {
                // Overlapping copy must be done byte by byte.
                var p = mPos
                for _ in 0 ..< n {
                    out.append(out[p])
                    p += 1
                }
            } else {
                out.append(contentsOf: out[mPos ..< mPos + n])
            }
        }

        enum State {
            case beginLoop, firstLiteralRun, match, copyMatch, matchDone, matchNext, matchEnd
        }

        var t = 0
        var mPos = 0
        var last2: UInt8 = 0
        var inst = try u8()
        var state: State

        if inst > 17 {
            t = inst - 17
            if t < 4 {
                state = .matchNext
            } else {
                try literals(t)
                state = .firstLiteralRun
            }
        } else {
            state = .beginLoop
        }

        while true {
            switch state {
            case .beginLoop:
                t = inst
                if t >= 16 { state = .match; break }
                if t == 0 { t = try readMulti(15) }
                try literals(t + 3)
                state = .firstLiteralRun

            case .firstLiteralRun:
                inst = try u8()
                last2 = UInt8(inst)
                t = inst
                if t >= 16 { state = .match; break }
                mPos = out.count - (1 + m2MaxOffset)
                mPos -= t >> 2
                mPos -= try u8() << 2
                try copyMatch(mPos, 3)
                state = .matchDone

            case .match:
                t = inst
                last2 = UInt8(inst)
                if t >= 64 {
                    mPos = out.count - 1
                    mPos -= (t >> 2) & 7
                    mPos -= try u8() << 3
                    t = (t >> 5) - 1
                    state = .copyMatch
                } else if t >= 32 {
                    t &= 31
                    if t == 0 { t = try readMulti(31) }
                    mPos = out.count - 1
                    let v16 = try u16le()
                    mPos -= v16 >> 2
                    last2 = UInt8(v16 & 0xFF)
                    state = .copyMatch
                } else if t >= 16 {
                    mPos = out.count - ((t & 8) << 11)
                    t &= 7
                    if t == 0 { t = try readMulti(7) }
                    let v16 = try u16le()
                    mPos -= v16 >> 2
                    if mPos == out.count {
                        // End-of-stream marker.
                        return Data(out)
                    }
                    mPos -= 0x4000
                    last2 = UInt8(v16 & 0xFF)
                    state = .copyMatch
                } else {
                    mPos = out.count - 1
                    mPos -= t >> 2
                    mPos -= try u8() << 2
                    try copyMatch(mPos, 2)
                    state = .matchDone
                }

            case .copyMatch:
                try copyMatch(mPos, t + 2)
                state = .matchDone

            case .matchDone:
                t = Int(last2 & 3)
                state = t == 0 ? .matchEnd : .matchNext

            case .matchNext:
                try literals(t)
                inst = try u8()
                state = .match

            case .matchEnd:
                inst = try u8()
                state = .beginLoop
            }
        }
    }
}
