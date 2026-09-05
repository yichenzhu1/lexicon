import Foundation

/// Sequential big-endian reader over a Data value.
/// Offsets are relative to the start of the provided data, independent of
/// the underlying Data's startIndex (safe to use with slices).
struct DataReader {
    private let data: Data
    private let base: Int
    private(set) var offset: Int

    init(_ data: Data, at offset: Int = 0) {
        self.data = data
        self.base = data.startIndex
        self.offset = offset
    }

    var remaining: Int { data.count - offset }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, offset + count <= data.count else {
            throw MdxError.truncatedFile("skip \(count) at \(offset)")
        }
        offset += count
    }

    mutating func read(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else {
            throw MdxError.truncatedFile("read \(count) at \(offset), size \(data.count)")
        }
        let start = base + offset
        offset += count
        return data.subdata(in: start ..< start + count)
    }

    mutating func readUInt8() throws -> UInt8 {
        guard offset + 1 <= data.count else { throw MdxError.truncatedFile("u8 at \(offset)") }
        let v = data[base + offset]
        offset += 1
        return v
    }

    mutating func readUInt16BE() throws -> UInt16 {
        let d = try read(2)
        return d.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).bigEndian }
    }

    mutating func readUInt32BE() throws -> UInt32 {
        let d = try read(4)
        return d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
    }

    mutating func readUInt64BE() throws -> UInt64 {
        let d = try read(8)
        return d.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).bigEndian }
    }

    /// Reads a format-version-dependent integer: 4 bytes for v1, 8 bytes for v2.
    mutating func readNumber(width: Int) throws -> UInt64 {
        if width == 8 { return try readUInt64BE() }
        return UInt64(try readUInt32BE())
    }
}
