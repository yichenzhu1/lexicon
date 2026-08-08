import CLzokay
import Foundation

/// Safe LZO1X decompression backed by the MIT-licensed lzokay implementation.
/// Older MDX files use LZO block compression.
public enum LZO1X {
    public static func decompress(_ input: Data, expectedSize: Int = 0) throws -> Data {
        guard expectedSize >= 0 else {
            throw MdxError.corruptData("negative LZO output size")
        }

        // A one-byte allocation keeps the mutable buffer pointer non-nil for
        // a valid empty output while `outputSize` still advertises zero bytes.
        var output = Data(count: max(expectedSize, 1))
        var outputSize = expectedSize
        let result = output.withUnsafeMutableBytes { destination in
            input.withUnsafeBytes { source in
                lzokay_decompress(
                    source.bindMemory(to: UInt8.self).baseAddress,
                    input.count,
                    destination.bindMemory(to: UInt8.self).baseAddress,
                    &outputSize
                )
            }
        }

        guard result == EResult_Success else {
            let reason: String
            switch result {
            case EResult_LookbehindOverrun:
                reason = "lookbehind underrun"
            case EResult_OutputOverrun:
                reason = "output overrun"
            case EResult_InputOverrun:
                reason = "input underrun"
            case EResult_InputNotConsumed:
                reason = "trailing input"
            default:
                reason = "invalid stream"
            }
            throw MdxError.corruptData("LZO \(reason)")
        }

        output.count = outputSize
        return output
    }
}
