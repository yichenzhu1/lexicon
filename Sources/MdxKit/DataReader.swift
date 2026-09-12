import Foundation

/// Sequential big-endian reader over a Data value.
/// Offsets are relative to the start of the provided data, independent of
/// the underlying Data's startIndex (safe to use with slices).
struct DataReader {
    private let data: Data
    private(set) var offset = 0

    init(_ data: Data) {
        self.data = data
    }

    var remaining: Int { data.count - offset }

    mutating func skip(_ count: Int) throws {
        _ = try takeRange(count)
    }

    mutating func read(_ count: Int) throws -> Data {
        let range = try takeRange(count)
        return data[range]
    }

    /// Validate once before arithmetic or indexing. Slices share the original
    /// storage; reading a field must not allocate a new buffer.
    private mutating func takeRange(_ count: Int) throws -> Range<Int> {
        guard count >= 0, count <= remaining else {
            throw MdxError.truncatedFile("read \(count) at \(offset), size \(data.count)")
        }
        let start = data.startIndex + offset
        offset += count
        return start ..< start + count
    }

    private mutating func readInteger<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let position = offset
        try skip(MemoryLayout<T>.size)
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: position, as: T.self).bigEndian }
    }

    mutating func readUInt8() throws -> UInt8 {
        try readInteger(UInt8.self)
    }

    mutating func readUInt16BE() throws -> UInt16 {
        try readInteger(UInt16.self)
    }

    mutating func readUInt32BE() throws -> UInt32 {
        try readInteger(UInt32.self)
    }

    mutating func readUInt64BE() throws -> UInt64 {
        try readInteger(UInt64.self)
    }

    /// Reads a format-version-dependent integer: 4 bytes for v1, 8 bytes for v2.
    mutating func readNumber(width: Int) throws -> UInt64 {
        if width == 8 { return try readUInt64BE() }
        return UInt64(try readUInt32BE())
    }

    /// Scan code units directly, then return one slice instead of allocating
    /// and appending a Data value for every character in every headword.
    mutating func readNullTerminated(unitWidth: Int) throws -> Data {
        let start = offset
        let end: Int? = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var cursor = start
            while data.count - cursor >= unitWidth {
                if bytes[cursor] == 0 && (unitWidth == 1 || bytes[cursor + 1] == 0) {
                    return cursor
                }
                cursor += unitWidth
            }
            return nil
        }
        guard let end else { throw MdxError.corruptData("unterminated key string") }
        offset = end + unitWidth
        return data[data.startIndex + start ..< data.startIndex + end]
    }
}
