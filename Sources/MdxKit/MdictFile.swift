import Foundation

/// Reader for MDict dictionary files: `.mdx` (text entries) and `.mdd`
/// (binary resources such as images, audio and CSS).
///
/// Format reference: https://github.com/zhansliu/writemdict/blob/master/fileformat.md
public final class MdictFile {
    public struct KeyEntry: Sendable {
        public let key: String
        public let recordOffset: UInt64
    }

    public struct IndexedEntry: Sendable {
        public let key: String
        public let recordOffset: UInt64
        public let recordLength: UInt32
    }

    public struct Info: Sendable {
        public let title: String
        public let description: String
        public let encoding: MdictTextEncoding
        public let engineVersion: Double
        public let isMDD: Bool
        public let entryCount: UInt64
        public let attributes: [String: String]
    }

    public let url: URL
    public let info: Info

    private let data: Data
    private let encrypt: Int
    private let numberWidth: Int
    private let stylesheet: [String: (String, String)]

    // Keyword section geometry.
    private struct KeyBlockInfo {
        let entryCount: UInt64
        let firstKey: String
        let lastKey: String
        let compressedSize: UInt64
        let decompressedSize: UInt64
        let fileOffset: UInt64 // absolute offset of the block in the file
    }

    private var keyBlockInfos: [KeyBlockInfo] = []

    // Record section geometry.
    private struct RecordBlockTable {
        var compressedSizes: [UInt64] = []
        var decompressedSizes: [UInt64] = []
        var fileOffsets: [UInt64] = []      // absolute file offset of each block
        var decompressedStarts: [UInt64] = [] // running offset in the plain record stream
        var totalDecompressedSize: UInt64 = 0
    }

    private var recordTable = RecordBlockTable()

    // Small LRU cache of decompressed record blocks.
    private let cacheLock = NSLock()
    private var blockCache: [Int: Data] = [:]
    private var blockCacheOrder: [Int] = []
    private let blockCacheCapacity = 16

    public convenience init(path: String) throws {
        try self.init(url: URL(fileURLWithPath: path))
    }

    public init(url: URL) throws {
        self.url = url
        self.data = try Data(contentsOf: url, options: .mappedIfSafe)

        // --- Header ---
        var reader = DataReader(data)
        let headerLength = Int(try reader.readUInt32BE())
        let headerBytes = try reader.read(headerLength)
        let storedAdler = try reader.read(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } // little-endian
        guard Adler32.checksum(headerBytes) == storedAdler else {
            throw MdxError.badChecksum("header")
        }

        var headerText = try MdictTextEncoding.utf16le.decode(headerBytes)
        headerText = headerText.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        let attributes = Self.parseAttributes(headerText)

        let versionString = attributes["GeneratedByEngineVersion"] ?? "2.0"
        let engineVersion = Double(versionString) ?? 2.0
        guard engineVersion < 3.0 else {
            throw MdxError.unsupportedVersion("engine \(versionString) (MdxBuilder 4.x); please rebuild with MdxBuilder 3.x")
        }
        numberWidth = engineVersion >= 2.0 ? 8 : 4

        switch attributes["Encrypted"] {
        case nil, "", "No": encrypt = 0
        case "Yes": encrypt = 1
        case let other?: encrypt = Int(other) ?? 0
        }

        let isMDD = url.pathExtension.lowercased() == "mdd"
        let encoding: MdictTextEncoding = isMDD
            ? .utf16le
            : MdictTextEncoding.from(headerValue: attributes["Encoding"] ?? "")

        stylesheet = Self.parseStylesheet(attributes["StyleSheet"])

        var entryCount: UInt64 = 0

        // --- Keyword section ---
        if encrypt & 1 != 0 {
            throw MdxError.unsupportedEncryption("this dictionary requires a registration code (Encrypted=1)")
        }

        let numKeyBlocks: UInt64
        let keyIndexDecompressedLength: UInt64
        let keyIndexCompressedLength: UInt64
        let keyBlocksLength: UInt64

        if numberWidth == 8 {
            let headerStart = reader.offset
            numKeyBlocks = try reader.readUInt64BE()
            entryCount = try reader.readUInt64BE()
            keyIndexDecompressedLength = try reader.readUInt64BE()
            keyIndexCompressedLength = try reader.readUInt64BE()
            keyBlocksLength = try reader.readUInt64BE()
            let headerData = data.subdata(in: data.startIndex + headerStart ..< data.startIndex + reader.offset)
            let checksum = try reader.readUInt32BE()
            guard Adler32.checksum(headerData) == checksum else {
                throw MdxError.badChecksum("keyword section header")
            }
        } else {
            numKeyBlocks = try reader.readNumber(width: 4)
            entryCount = try reader.readNumber(width: 4)
            keyIndexDecompressedLength = 0
            keyIndexCompressedLength = try reader.readNumber(width: 4)
            keyBlocksLength = try reader.readNumber(width: 4)
        }

        let keyIndexData = try reader.read(Int(keyIndexCompressedLength))
        let keyIndexPlain: Data
        if numberWidth == 8 {
            keyIndexPlain = try BlockCompression.decompress(
                block: keyIndexData,
                decompressedSize: Int(keyIndexDecompressedLength),
                encryptedIndex: encrypt & 2 != 0
            )
        } else {
            keyIndexPlain = keyIndexData // v1: stored plain
        }

        // Parse the keyword index into per-block geometry.
        let keyBlocksStart = UInt64(reader.offset)
        var indexReader = DataReader(keyIndexPlain)
        var infos: [KeyBlockInfo] = []
        infos.reserveCapacity(Int(numKeyBlocks))
        var runningOffset = keyBlocksStart
        for _ in 0 ..< numKeyBlocks {
            let blockEntryCount = try indexReader.readNumber(width: numberWidth)
            let firstKey = try Self.readIndexText(&indexReader, width: numberWidth, encoding: encoding)
            let lastKey = try Self.readIndexText(&indexReader, width: numberWidth, encoding: encoding)
            let compSize = try indexReader.readNumber(width: numberWidth)
            let decompSize = try indexReader.readNumber(width: numberWidth)
            infos.append(KeyBlockInfo(
                entryCount: blockEntryCount,
                firstKey: firstKey,
                lastKey: lastKey,
                compressedSize: compSize,
                decompressedSize: decompSize,
                fileOffset: runningOffset
            ))
            runningOffset += compSize
        }
        keyBlockInfos = infos
        try reader.skip(Int(keyBlocksLength))

        // --- Record section ---
        let numRecordBlocks = try reader.readNumber(width: numberWidth)
        _ = try reader.readNumber(width: numberWidth) // total entries, same as keyword section
        let recordIndexLength = try reader.readNumber(width: numberWidth)
        _ = try reader.readNumber(width: numberWidth) // total record block bytes
        guard recordIndexLength == numRecordBlocks * UInt64(numberWidth) * 2 else {
            throw MdxError.corruptData("record index size mismatch")
        }

        var table = RecordBlockTable()
        table.compressedSizes.reserveCapacity(Int(numRecordBlocks))
        table.decompressedSizes.reserveCapacity(Int(numRecordBlocks))
        for _ in 0 ..< numRecordBlocks {
            table.compressedSizes.append(try reader.readNumber(width: numberWidth))
            table.decompressedSizes.append(try reader.readNumber(width: numberWidth))
        }
        var fileOffset = UInt64(reader.offset)
        var plainOffset: UInt64 = 0
        for i in 0 ..< Int(numRecordBlocks) {
            table.fileOffsets.append(fileOffset)
            table.decompressedStarts.append(plainOffset)
            fileOffset += table.compressedSizes[i]
            plainOffset += table.decompressedSizes[i]
        }
        table.totalDecompressedSize = plainOffset
        recordTable = table

        info = Info(
            title: Self.unescapeXML(attributes["Title"] ?? url.deletingPathExtension().lastPathComponent),
            description: Self.unescapeXML(attributes["Description"] ?? ""),
            encoding: encoding,
            engineVersion: engineVersion,
            isMDD: isMDD,
            entryCount: entryCount,
            attributes: attributes
        )
    }

    // MARK: - Keys

    /// Decompresses all key blocks and returns every (key, record offset) pair
    /// in file order. Used at import time.
    public func allKeys() throws -> [KeyEntry] {
        var result: [KeyEntry] = []
        result.reserveCapacity(Int(info.entryCount))
        let encoding = info.encoding
        for block in keyBlockInfos {
            let start = data.startIndex + Int(block.fileOffset)
            let compressed = data.subdata(in: start ..< start + Int(block.compressedSize))
            let plain = try BlockCompression.decompress(
                block: compressed,
                decompressedSize: Int(block.decompressedSize)
            )
            var r = DataReader(plain)
            while r.remaining > numberWidth {
                let offset = try r.readNumber(width: numberWidth)
                let keyData = try Self.readNullTerminated(&r, unitWidth: encoding.unitWidth)
                let key = try encoding.decode(keyData)
                result.append(KeyEntry(key: key, recordOffset: offset))
            }
        }
        return result
    }

    /// All keys with their record lengths resolved from the next distinct
    /// record offset. Record blocks are storage chunks rather than entry
    /// boundaries, so an entry is allowed to continue into a later block.
    public func indexedEntries() throws -> [IndexedEntry] {
        let keys = try allKeys()
        let sortedOffsets = Set(keys.map(\.recordOffset)).sorted()
        var endByOffset: [UInt64: UInt64] = [:]
        endByOffset.reserveCapacity(sortedOffsets.count)
        for (i, offset) in sortedOffsets.enumerated() {
            let next = i + 1 < sortedOffsets.count ? sortedOffsets[i + 1] : recordTable.totalDecompressedSize
            endByOffset[offset] = next
        }
        return keys.map { entry in
            let end = endByOffset[entry.recordOffset] ?? entry.recordOffset
            return IndexedEntry(
                key: entry.key,
                recordOffset: entry.recordOffset,
                recordLength: UInt32(min(end - entry.recordOffset, UInt64(UInt32.max)))
            )
        }
    }

    // MARK: - Records

    /// Reads plain bytes from the logical decompressed record stream. A
    /// length-bounded read may span any number of compressed record blocks.
    /// When `length` is nil, reads to the end of the containing block.
    public func recordData(at offset: UInt64, length: Int? = nil) throws -> Data {
        guard let blockIndex = recordBlockIndex(containing: offset) else {
            throw MdxError.corruptData("record offset \(offset) out of range")
        }
        let firstBlock = try decompressedRecordBlock(blockIndex)
        let blockStart = recordTable.decompressedStarts[blockIndex]
        let local = Int(offset - blockStart)
        guard local <= firstBlock.count else {
            throw MdxError.corruptData("record offset beyond block")
        }

        guard let length else {
            return firstBlock.subdata(in: firstBlock.startIndex + local ..< firstBlock.endIndex)
        }
        guard length >= 0 else {
            throw MdxError.corruptData("negative record length")
        }

        var result = Data()
        result.reserveCapacity(length)
        var remaining = length
        var currentBlockIndex = blockIndex
        var currentLocalOffset = local

        while remaining > 0, currentBlockIndex < recordTable.decompressedStarts.count {
            let plain = currentBlockIndex == blockIndex
                ? firstBlock
                : try decompressedRecordBlock(currentBlockIndex)
            let available = plain.count - currentLocalOffset
            if available > 0 {
                let count = min(remaining, available)
                let start = plain.startIndex + currentLocalOffset
                result.append(plain[start ..< start + count])
                remaining -= count
            }
            currentBlockIndex += 1
            currentLocalOffset = 0
        }
        return result
    }

    /// Decoded text of an MDX entry, with stylesheet substitution applied and
    /// trailing terminators removed.
    public func entryText(at offset: UInt64, length: Int? = nil) throws -> String {
        var raw = try recordData(at: offset, length: length)
        if length == nil {
            raw = Self.truncateAtTerminator(raw, unitWidth: info.encoding.unitWidth)
        }
        var text = try info.encoding.decode(raw)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        if !stylesheet.isEmpty {
            text = Self.applyStylesheet(text, stylesheet: stylesheet)
        }
        return text
    }

    /// Convenience exact lookup that scans key blocks (linear; meant for tests
    /// and one-off use — the app queries its SQLite index instead).
    public func lookup(_ word: String) throws -> String? {
        for entry in try indexedEntries() where entry.key == word {
            return try entryText(
                at: entry.recordOffset, length: Int(entry.recordLength)
            )
        }
        return nil
    }

    /// MDD resource paths use backslashes and are case-insensitive; this maps
    /// them (and href-style paths) to a canonical comparable form.
    public static func normalizeResourcePath(_ path: String) -> String {
        var p = path.replacingOccurrences(of: "\\", with: "/").lowercased()
        while p.hasPrefix("/") { p.removeFirst() }
        return p
    }

    /// Convenience MDD resource lookup by path (linear scan; the app uses its
    /// SQLite index instead).
    public func resourceData(path: String) throws -> Data? {
        let target = Self.normalizeResourcePath(path)
        for entry in try indexedEntries()
        where Self.normalizeResourcePath(entry.key) == target {
            return try recordData(at: entry.recordOffset, length: Int(entry.recordLength))
        }
        return nil
    }

    // MARK: - Record block helpers

    private func recordBlockIndex(containing offset: UInt64) -> Int? {
        let starts = recordTable.decompressedStarts
        guard !starts.isEmpty, offset < recordTable.totalDecompressedSize else { return nil }
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    private func decompressedRecordBlock(_ index: Int) throws -> Data {
        cacheLock.lock()
        if let cached = blockCache[index] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let start = data.startIndex + Int(recordTable.fileOffsets[index])
        let end = start + Int(recordTable.compressedSizes[index])
        guard end <= data.endIndex else { throw MdxError.truncatedFile("record block \(index)") }
        let plain = try BlockCompression.decompress(
            block: data.subdata(in: start ..< end),
            decompressedSize: Int(recordTable.decompressedSizes[index])
        )

        cacheLock.lock()
        blockCache[index] = plain
        blockCacheOrder.append(index)
        if blockCacheOrder.count > blockCacheCapacity {
            let evicted = blockCacheOrder.removeFirst()
            blockCache.removeValue(forKey: evicted)
        }
        cacheLock.unlock()
        return plain
    }

    // MARK: - Parsing helpers

    private static func parseAttributes(_ headerXML: String) -> [String: String] {
        var attributes: [String: String] = [:]
        let pattern = #"(\w+)="(.*?)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return attributes
        }
        let ns = headerXML as NSString
        for match in regex.matches(in: headerXML, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1))
            let value = ns.substring(with: match.range(at: 2))
            attributes[name] = value
        }
        return attributes
    }

    private static func unescapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#13;", with: "\r")
            .replacingOccurrences(of: "&#10;", with: "\n")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Header StyleSheet attribute: lines in groups of three
    /// (number, opening text, closing text).
    private static func parseStylesheet(_ value: String?) -> [String: (String, String)] {
        guard let value, !value.isEmpty else { return [:] }
        let lines = unescapeXML(value).components(separatedBy: "\n")
        var sheet: [String: (String, String)] = [:]
        var i = 0
        while i < lines.count {
            let number = lines[i].trimmingCharacters(in: .whitespaces)
            guard !number.isEmpty else { break }
            let begin = i + 1 < lines.count ? lines[i + 1] : ""
            let end = i + 2 < lines.count ? lines[i + 2] : ""
            sheet[number] = (begin, end)
            i += 3
        }
        return sheet
    }

    /// Replaces MDict `` `N` `` style markers with the stylesheet's begin/end
    /// text pairs.
    public static func applyStylesheet(_ text: String, stylesheet: [String: (String, String)]) -> String {
        guard let regex = try? NSRegularExpression(pattern: "`(\\d+)`") else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var result = ns.substring(to: matches[0].range.location)
        for (i, match) in matches.enumerated() {
            let number = ns.substring(with: match.range(at: 1))
            let segmentStart = match.range.location + match.range.length
            let segmentEnd = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
            let segment = ns.substring(with: NSRange(location: segmentStart, length: segmentEnd - segmentStart))
            let (begin, end) = stylesheet[number] ?? ("", "")
            if segment.hasSuffix("\n") {
                result += begin + segment.trimmingCharacters(in: .newlines) + end + "\r\n"
            } else {
                result += begin + segment + end
            }
        }
        return result
    }

    /// Reads a length-prefixed key string from the keyword index.
    private static func readIndexText(
        _ reader: inout DataReader, width: Int, encoding: MdictTextEncoding
    ) throws -> String {
        let sizeUnits: Int
        if width == 8 {
            sizeUnits = Int(try reader.readUInt16BE())
        } else {
            sizeUnits = Int(try reader.readUInt8())
        }
        let terminatorUnits = width == 8 ? 1 : 0
        let bytes = try reader.read(sizeUnits * encoding.unitWidth)
        try reader.skip(terminatorUnits * encoding.unitWidth)
        return try encoding.decode(bytes)
    }

    /// Reads bytes up to (and consuming) a null terminator of the given width.
    private static func readNullTerminated(_ reader: inout DataReader, unitWidth: Int) throws -> Data {
        var bytes = Data()
        while reader.remaining >= unitWidth {
            let unit = try reader.read(unitWidth)
            if unit.allSatisfy({ $0 == 0 }) { return bytes }
            bytes.append(unit)
        }
        throw MdxError.corruptData("unterminated key string")
    }

    /// Cuts the data at the first null terminator (aligned for UTF-16).
    private static func truncateAtTerminator(_ data: Data, unitWidth: Int) -> Data {
        let bytes = [UInt8](data)
        var i = 0
        while i + unitWidth <= bytes.count {
            if unitWidth == 1 {
                if bytes[i] == 0 { return data.prefix(i) }
                i += 1
            } else {
                if bytes[i] == 0 && bytes[i + 1] == 0 { return data.prefix(i) }
                i += 2
            }
        }
        return data
    }
}
