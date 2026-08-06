import Compression
import Foundation

/// Every compressed unit in an MDX/MDD file (keyword index, keyword blocks,
/// record blocks) shares the same framing:
///   4 bytes compression type | 4 bytes adler32 of the plain data | payload
enum BlockCompression {
    /// Ceiling on a single decompressed block, so a corrupt size field cannot
    /// request an unbounded allocation. Real blocks are far below this.
    static let maxDecompressedBlockSize = 1 << 30 // 1 GiB

    /// Decompresses one framed block.
    /// - Parameters:
    ///   - block: the full framed block (including the 8-byte header).
    ///   - decompressedSize: expected plain size, known from the section tables.
    ///   - encryptedIndex: true for the keyword index of Encrypted=2 files.
    static func decompress(
        block: Data,
        decompressedSize: Int,
        encryptedIndex: Bool = false
    ) throws -> Data {
        guard block.count >= 8 else { throw MdxError.truncatedFile("compressed block") }
        // `decompressedSize` originates in the file's section tables; callers
        // bound it, and this backstops the buffer allocations below.
        guard decompressedSize >= 0, decompressedSize <= maxDecompressedBlockSize else {
            throw MdxError.corruptData("implausible decompressed block size \(decompressedSize)")
        }
        let base = block.startIndex
        let compType = block.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } // stored little-endian on disk
        let checksumBytes = block.subdata(in: base + 4 ..< base + 8)
        let checksum = checksumBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }

        var payload = block.subdata(in: base + 8 ..< base + block.count)
        if encryptedIndex {
            payload = FastCrypt.decrypt(payload, key: FastCrypt.indexKey(checksum: checksumBytes))
        }

        let plain: Data
        switch compType {
        case 0x0000_0000:
            plain = payload
        case 0x0000_0001:
            plain = try LZO1X.decompress(payload, expectedSize: decompressedSize)
        case 0x0000_0002:
            plain = try inflateZlib(payload, decompressedSize: decompressedSize)
        default:
            throw MdxError.unsupportedCompression(compType)
        }

        guard plain.count == decompressedSize else {
            throw MdxError.corruptData("expected \(decompressedSize) bytes, got \(plain.count)")
        }
        guard Adler32.checksum(plain) == checksum else {
            throw MdxError.badChecksum("block content")
        }
        return plain
    }

    /// Inflates a zlib stream (2-byte header + raw deflate + 4-byte adler32)
    /// using the Compression framework's raw-deflate decoder.
    private static func inflateZlib(_ data: Data, decompressedSize: Int) throws -> Data {
        guard data.count > 2 else { throw MdxError.truncatedFile("zlib stream") }
        let deflate = data.subdata(in: data.startIndex + 2 ..< data.startIndex + data.count)
        var output = Data(count: decompressedSize)
        let written = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            deflate.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let dstPtr = dst.baseAddress, let srcPtr = src.baseAddress else { return 0 }
                return compression_decode_buffer(
                    dstPtr.assumingMemoryBound(to: UInt8.self), decompressedSize,
                    srcPtr.assumingMemoryBound(to: UInt8.self), deflate.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == decompressedSize else {
            throw MdxError.corruptData("zlib inflate produced \(written) of \(decompressedSize) bytes")
        }
        return output
    }
}
