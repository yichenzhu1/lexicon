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
        let compressedSize: UInt64
        let decompressedSize: UInt64
        let fileOffset: UInt64 // absolute offset of the block in the file
    }

    private var keyBlockInfos: [KeyBlockInfo] = []

    // Record section geometry.
    private struct RecordBlock {
        let fileRange: Range<Int>
        let decompressedSize: Int
        let streamOffset: UInt64
    }

    private var recordBlocks: [RecordBlock] = []
    private var recordStreamSize: UInt64 = 0

    // Small LRU cache of decompressed record blocks. `blockCacheOrder` runs
    // least- to most-recently used.
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
            let headerData = data[data.startIndex + headerStart ..< data.startIndex + reader.offset]
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

        let keyIndexData = try reader.read(
            Self.checked(keyIndexCompressedLength, max: data.count, "keyword index size")
        )
        let keyIndexPlain: Data
        if numberWidth == 8 {
            keyIndexPlain = try BlockCompression.decompress(
                block: keyIndexData,
                decompressedSize: Self.checked(
                    keyIndexDecompressedLength,
                    max: Self.maxBlockSize,
                    "keyword index decompressed size"
                ),
                encryptedIndex: encrypt & 2 != 0
            )
        } else {
            keyIndexPlain = keyIndexData // v1: stored plain
        }

        // Parse the keyword index into per-block geometry. Each block costs at
        // least three numbers plus two key-length prefixes in the index, which
        // bounds the block count by the index we just read.
        let minBytesPerKeyBlock = 3 * numberWidth + 2
        let keyBlockCount = try Self.checked(
            numKeyBlocks,
            max: keyIndexPlain.count / minBytesPerKeyBlock,
            "key block count"
        )

        let keyBlocksStart = UInt64(reader.offset)
        var indexReader = DataReader(keyIndexPlain)
        var infos: [KeyBlockInfo] = []
        infos.reserveCapacity(keyBlockCount)
        var runningOffset = keyBlocksStart
        var indexedKeyCount: UInt64 = 0
        for _ in 0 ..< keyBlockCount {
            let blockEntryCount = try indexReader.readNumber(width: numberWidth)
            indexedKeyCount = try Self.checkedSum(
                indexedKeyCount, blockEntryCount, max: entryCount, "keyword entry count"
            )
            try Self.skipIndexText(&indexReader, width: numberWidth, encoding: encoding)
            try Self.skipIndexText(&indexReader, width: numberWidth, encoding: encoding)
            let compSize = try indexReader.readNumber(width: numberWidth)
            let decompSize = try indexReader.readNumber(width: numberWidth)
            guard decompSize <= UInt64(Self.maxBlockSize) else {
                throw MdxError.corruptData("key block decompressed size out of range (\(decompSize))")
            }
            infos.append(KeyBlockInfo(
                entryCount: blockEntryCount,
                compressedSize: compSize,
                decompressedSize: decompSize,
                fileOffset: runningOffset
            ))
            // Keeps every block's [fileOffset, fileOffset + compressedSize)
            // inside the file, so `allKeys` can slice without re-checking.
            runningOffset = try Self.checkedSum(
                runningOffset, compSize, max: UInt64(data.count), "key block extent"
            )
        }
        let declaredKeyBlocksEnd = try Self.checkedSum(
            keyBlocksStart, keyBlocksLength, max: UInt64(data.count), "key blocks extent"
        )
        guard runningOffset == declaredKeyBlocksEnd else {
            throw MdxError.corruptData("key block sizes do not match declared total")
        }
        guard indexedKeyCount == entryCount else {
            throw MdxError.corruptData("keyword entry count mismatch")
        }
        keyBlockInfos = infos
        try reader.skip(Self.checked(keyBlocksLength, max: data.count, "key blocks length"))

        // --- Record section ---
        let numRecordBlocks = try reader.readNumber(width: numberWidth)
        let recordEntryCount = try reader.readNumber(width: numberWidth)
        let recordIndexLength = try reader.readNumber(width: numberWidth)
        let declaredRecordBytes = try reader.readNumber(width: numberWidth)
        guard recordEntryCount == entryCount else {
            throw MdxError.corruptData("record entry count mismatch")
        }

        // Equivalent to `recordIndexLength == numRecordBlocks * numberWidth * 2`,
        // but division cannot overflow the way that multiplication can.
        let bytesPerRecordBlock = UInt64(numberWidth) * 2
        guard recordIndexLength % bytesPerRecordBlock == 0,
              recordIndexLength / bytesPerRecordBlock == numRecordBlocks
        else {
            throw MdxError.corruptData("record index size mismatch")
        }
        let recordBlockCount = try Self.checked(
            numRecordBlocks,
            max: reader.remaining / (numberWidth * 2),
            "record block count"
        )

        let recordBlocksStart = try Self.checkedSum(
            UInt64(reader.offset), recordIndexLength, max: UInt64(data.count), "record index extent"
        )
        var fileOffset = recordBlocksStart
        var plainOffset: UInt64 = 0
        var blocks: [RecordBlock] = []
        blocks.reserveCapacity(recordBlockCount)
        for _ in 0 ..< recordBlockCount {
            let compressedSize = try reader.readNumber(width: numberWidth)
            let decompressedSize = try Self.checked(
                reader.readNumber(width: numberWidth),
                max: Self.maxBlockSize, "record block decompressed size"
            )
            let end = try Self.checkedSum(
                fileOffset, compressedSize, max: UInt64(data.count), "record block extent"
            )
            blocks.append(RecordBlock(
                fileRange: Int(fileOffset) ..< Int(end),
                decompressedSize: decompressedSize,
                streamOffset: plainOffset
            ))
            fileOffset = end
            plainOffset = try Self.checkedSum(
                plainOffset, UInt64(decompressedSize),
                max: UInt64(Int.max), "record stream size"
            )
        }
        guard fileOffset - recordBlocksStart == declaredRecordBytes else {
            throw MdxError.corruptData("record block sizes do not match declared total")
        }
        recordBlocks = blocks
        recordStreamSize = plainOffset

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

    /// Reserve hint that never takes the header's entry count at face value:
    /// on disk a key costs at least a record offset plus a terminator, so the
    /// file size caps how many can exist.
    private var plausibleEntryCount: Int {
        let ceiling = data.count / (numberWidth + info.encoding.unitWidth)
        return Int(min(info.entryCount, UInt64(ceiling)))
    }

    /// Streams every (key, record offset) pair in file order, holding only one
    /// decompressed key block at a time.
    private func forEachKey(_ body: (Data, UInt64) throws -> Void) throws {
        let encoding = info.encoding
        for block in keyBlockInfos {
            // init bounded every block's extent by the file size.
            let start = data.startIndex + Int(block.fileOffset)
            let compressed = data[start ..< start + Int(block.compressedSize)]
            let plain = try BlockCompression.decompress(
                block: compressed,
                decompressedSize: Int(block.decompressedSize)
            )
            var r = DataReader(plain)
            var entryCount: UInt64 = 0
            while r.remaining > 0 {
                guard entryCount < block.entryCount else {
                    throw MdxError.corruptData("key block contains more entries than declared")
                }
                let offset = try r.readNumber(width: numberWidth)
                let keyData = try r.readNullTerminated(unitWidth: encoding.unitWidth)
                try body(keyData, offset)
                entryCount += 1
            }
            guard entryCount == block.entryCount else {
                throw MdxError.corruptData("key block entry count mismatch")
            }
        }
    }

    /// Decompresses all key blocks and returns every (key, record offset) pair
    /// in file order.
    public func allKeys() throws -> [KeyEntry] {
        var result: [KeyEntry] = []
        result.reserveCapacity(plausibleEntryCount)
        try forEachKey { key, offset in
            result.append(KeyEntry(key: try info.encoding.decode(key), recordOffset: offset))
        }
        return result
    }

    /// Streams every key with its record length resolved from the next distinct
    /// record offset. Record blocks are storage chunks rather than entry
    /// boundaries, so an entry is allowed to continue into a later block.
    ///
    /// Two passes over the key blocks keep only the offset table resident.
    /// Collecting the keys up front instead would hold every headword string in
    /// memory at once, which dominates the cost of importing a large
    /// dictionary.
    public func forEachIndexedEntry(_ body: (IndexedEntry) throws -> Void) throws {
        var boundaries: [UInt64] = []
        boundaries.reserveCapacity(plausibleEntryCount)
        var ordered = true
        try forEachKey { _, offset in
            if let previous = boundaries.last, offset < previous { ordered = false }
            boundaries.append(offset)
        }

        // Normal dictionaries already have ordered offsets. Sort only when
        // necessary, then compact duplicate boundaries in the same buffer.
        if !ordered { boundaries.sort() }
        var count = 0
        for index in boundaries.indices {
            let offset = boundaries[index]
            if count == 0 || boundaries[count - 1] != offset {
                boundaries[count] = offset
                count += 1
            }
        }
        boundaries.removeLast(boundaries.count - count)

        let streamEnd = recordStreamSize
        var boundaryCursor = 0
        try forEachKey { key, offset in
            // MDX keyword records normally appear in record-stream order. Walk
            // the boundary table linearly in that common case instead of doing
            // a binary search for every one of hundreds of thousands of keys.
            // A malformed or unusual out-of-order offset falls back safely.
            if ordered {
                while boundaryCursor < boundaries.count, boundaries[boundaryCursor] <= offset {
                    boundaryCursor += 1
                }
            } else {
                boundaryCursor = Self.firstBoundaryIndex(after: offset, in: boundaries)
            }
            let end = boundaryCursor < boundaries.count ? boundaries[boundaryCursor] : streamEnd
            // A corrupt offset past the end of the stream yields an empty
            // record rather than underflowing.
            let length = end > offset ? end - offset : 0
            try body(IndexedEntry(
                key: try info.encoding.decode(key),
                recordOffset: offset,
                recordLength: UInt32(min(length, UInt64(UInt32.max)))
            ))
        }
    }

    /// All keys with their record lengths, collected into an array.
    public func indexedEntries() throws -> [IndexedEntry] {
        var result: [IndexedEntry] = []
        result.reserveCapacity(plausibleEntryCount)
        try forEachIndexedEntry { result.append($0) }
        return result
    }

    /// Index of the first boundary strictly greater than `offset`.
    private static func firstBoundaryIndex(after offset: UInt64, in boundaries: [UInt64]) -> Int {
        var lo = 0, hi = boundaries.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if boundaries[mid] <= offset { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    // MARK: - Records

    /// Reads plain bytes from the logical decompressed record stream. A
    /// length-bounded read may span any number of compressed record blocks.
    /// When `length` is nil, reads to the end of the containing block.
    public func recordData(at offset: UInt64, length: Int? = nil) throws -> Data {
        guard let blockIndex = recordBlockIndex(containing: offset) else {
            throw MdxError.corruptData("record offset \(offset) out of range")
        }
        if let length {
            guard length >= 0 else { throw MdxError.corruptData("negative record length") }
            guard UInt64(length) <= recordStreamSize - offset else {
                throw MdxError.truncatedFile("record data at \(offset), length \(length) exceeds stream")
            }
        }
        let firstBlock = try decompressedRecordBlock(blockIndex)
        let blockStart = recordBlocks[blockIndex].streamOffset
        let local = Int(offset - blockStart)

        guard let length else {
            return firstBlock.subdata(in: firstBlock.startIndex + local ..< firstBlock.endIndex)
        }
        if length <= firstBlock.count - local {
            let start = firstBlock.startIndex + local
            return firstBlock.subdata(in: start ..< start + length)
        }

        var result = Data()
        result.reserveCapacity(length)
        var remaining = length
        var currentBlockIndex = blockIndex
        var currentLocalOffset = local

        while remaining > 0 {
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
        guard !recordBlocks.isEmpty, offset < recordStreamSize else { return nil }
        var lo = 0, hi = recordBlocks.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if recordBlocks[mid].streamOffset <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    private func decompressedRecordBlock(_ index: Int) throws -> Data {
        cacheLock.lock()
        if let cached = blockCache[index] {
            touchCachedBlock(index)
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        // The immutable table was validated once when the file was opened.
        let block = recordBlocks[index]
        let plain = try BlockCompression.decompress(
            block: data[block.fileRange],
            decompressedSize: block.decompressedSize
        )

        cacheLock.lock()
        blockCache[index] = plain
        touchCachedBlock(index)
        while blockCacheOrder.count > blockCacheCapacity {
            blockCache.removeValue(forKey: blockCacheOrder.removeFirst())
        }
        cacheLock.unlock()
        return plain
    }

    /// Moves a block to the most-recently-used end. Callers hold `cacheLock`.
    private func touchCachedBlock(_ index: Int) {
        if let position = blockCacheOrder.firstIndex(of: index) {
            blockCacheOrder.remove(at: position)
        }
        blockCacheOrder.append(index)
    }

    // MARK: - Header field validation

    /// Every size and count below comes straight off disk. The v2 keyword
    /// header is adler32-protected but the record header is not, and v1
    /// protects neither — so a merely corrupt file (not just a crafted one)
    /// can present absurd values. These helpers turn that into a thrown
    /// `MdxError` instead of a Swift runtime trap.

    /// Upper bound for one decompressed block. Real MDX blocks are well under
    /// a megabyte; this only stops a corrupt size field from requesting an
    /// unbounded allocation.
    private static let maxBlockSize = BlockCompression.maxDecompressedBlockSize

    /// Converts a file-supplied count or offset to `Int`, rejecting anything
    /// that cannot describe a real region of a `limit`-byte file.
    private static func checked(
        _ value: UInt64, max limit: Int, _ field: String
    ) throws -> Int {
        guard limit >= 0, let converted = Int(exactly: value), converted <= limit else {
            throw MdxError.corruptData("\(field) out of range (\(value))")
        }
        return converted
    }

    /// Adds two file-supplied sizes, failing instead of trapping on overflow.
    private static func checkedSum(
        _ base: UInt64, _ increment: UInt64, max limit: UInt64, _ field: String
    ) throws -> UInt64 {
        let (sum, overflowed) = base.addingReportingOverflow(increment)
        guard !overflowed, sum <= limit else {
            throw MdxError.corruptData("\(field) overflows (\(base) + \(increment))")
        }
        return sum
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

    /// The index's first/last keys are unused; consume their framing without
    /// allocating and decoding strings just to discard them.
    private static func skipIndexText(
        _ reader: inout DataReader, width: Int, encoding: MdictTextEncoding
    ) throws {
        let sizeUnits: Int
        if width == 8 {
            sizeUnits = Int(try reader.readUInt16BE())
        } else {
            sizeUnits = Int(try reader.readUInt8())
        }
        let terminatorUnits = width == 8 ? 1 : 0
        try reader.skip((sizeUnits + terminatorUnits) * encoding.unitWidth)
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
