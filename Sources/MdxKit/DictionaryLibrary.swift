import Foundation

/// A dictionary registered in the library.
public struct DictionaryRecord: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let uuid: String
    public var title: String
    public let folderName: String
    public let mdxFileName: String
    public var enabled: Bool
    public var sortOrder: Int
    public let entryCount: Int
    /// Images, audio and stylesheets indexed from the dictionary's .mdd parts.
    /// Zero means the .mdd companions were not alongside the .mdx at import.
    public let resourceCount: Int

    public var hasResources: Bool { resourceCount > 0 }
}

/// Progress of a running import. `fraction` is nil while the work is not
/// countable (copying files, reading the keyword index).
public struct ImportProgress: Sendable {
    public let stage: String
    public let completed: Int
    public let total: Int

    public var fraction: Double? {
        guard total > 0 else { return nil }
        return min(1, Double(completed) / Double(total))
    }

    init(stage: String, completed: Int = 0, total: Int = 0) {
        self.stage = stage
        self.completed = completed
        self.total = total
    }
}

/// How a headword matched the query. Results are ordered by this, so a word
/// that starts with what you typed always outranks one that merely contains it.
public enum SearchMatchKind: Int, Sendable, Comparable {
    case exact = 0
    case prefix = 1
    case substring = 2
    /// Near miss offered when nothing matched literally.
    case fuzzy = 3

    public static func < (lhs: SearchMatchKind, rhs: SearchMatchKind) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One headword match from the unified search.
public struct SearchResult: Identifiable, Hashable, Sendable {
    public var id: String { normalizedKey }
    public let normalizedKey: String
    public let displayKey: String
    public let dictionaryCount: Int
    public let matchKind: SearchMatchKind

    public init(
        normalizedKey: String,
        displayKey: String,
        dictionaryCount: Int,
        matchKind: SearchMatchKind = .prefix
    ) {
        self.normalizedKey = normalizedKey
        self.displayKey = displayKey
        self.dictionaryCount = dictionaryCount
        self.matchKind = matchKind
    }
}

/// A concrete entry (word within one dictionary) ready to be read.
public struct EntryHit: Sendable {
    public let dictionaryUUID: String
    public let dictionaryTitle: String
    public let key: String
    public let recordOffset: UInt64
    public let recordLength: Int
}

/// Owns the on-disk library: imported dictionary folders plus the SQLite
/// keyword index.
///
/// Safe to use from several threads at once. Reads run on pooled SQLite
/// connections so an import cannot block them; `stateLock` guards the open-file
/// handles and the cached dictionary table.
public final class DictionaryLibrary: @unchecked Sendable {
    public let rootURL: URL
    private let pool: SQLitePool

    private let stateLock = NSLock()
    private var handles: [String: OpenDictionary] = [:]
    private var cachedRecords: [DictionaryRecord]?
    private var cachedRecordsByUUID: [String: DictionaryRecord] = [:]

    private struct OpenDictionary {
        let mdx: MdictFile
        let mdds: [MdictFile]
    }

    public var dictionariesURL: URL {
        rootURL.appendingPathComponent("Dictionaries", isDirectory: true)
    }

    public init(rootURL: URL) throws {
        self.rootURL = rootURL
        let fm = FileManager.default
        try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: rootURL.appendingPathComponent("Dictionaries", isDirectory: true),
            withIntermediateDirectories: true
        )
        pool = try SQLitePool(path: rootURL.appendingPathComponent("index.sqlite").path)
        try pool.write { db in
            try db.exec("""
            CREATE TABLE IF NOT EXISTS dictionaries (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                uuid TEXT UNIQUE NOT NULL,
                title TEXT NOT NULL,
                folder TEXT NOT NULL,
                mdxFile TEXT NOT NULL,
                enabled INTEGER NOT NULL DEFAULT 1,
                sortOrder INTEGER NOT NULL DEFAULT 0,
                entryCount INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS entries (
                dict INTEGER NOT NULL,
                key TEXT NOT NULL,
                nkey TEXT NOT NULL,
                offset INTEGER NOT NULL,
                length INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_entries_nkey ON entries(nkey);
            CREATE INDEX IF NOT EXISTS idx_entries_dict ON entries(dict, nkey);
            CREATE TABLE IF NOT EXISTS resources (
                dict INTEGER NOT NULL,
                part INTEGER NOT NULL,
                path TEXT NOT NULL,
                offset INTEGER NOT NULL,
                length INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_resources ON resources(dict, path);
            """)

            // SQLite has no ADD COLUMN IF NOT EXISTS, so check before adding.
            let columns = try db.query("PRAGMA table_info(dictionaries)") { $0.text(1) }
            if !columns.contains("resourceCount") {
                try db.exec(
                    "ALTER TABLE dictionaries ADD COLUMN resourceCount INTEGER NOT NULL DEFAULT 0"
                )
                // Existing libraries: recover the counts already indexed.
                try db.exec("""
                    UPDATE dictionaries SET resourceCount =
                        (SELECT COUNT(*) FROM resources WHERE resources.dict = dictionaries.id)
                    """)
            }
        }
    }

    // MARK: - Normalization

    /// Search key normalization: case- and diacritic-insensitive.
    public static func normalizeKey(_ key: String) -> String {
        key.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Records

    /// The registered dictionaries, in the user's order.
    ///
    /// Cached: every resource request resolves a UUID against this table, so
    /// an entry page with a dozen images used to run a dozen full scans.
    /// Invalidated by each mutation below.
    public func dictionaries() throws -> [DictionaryRecord] {
        stateLock.lock()
        if let cached = cachedRecords {
            stateLock.unlock()
            return cached
        }
        stateLock.unlock()

        let rows = try pool.read { db in
            try db.query(
                """
                SELECT id, uuid, title, folder, mdxFile, enabled, sortOrder, entryCount,
                       resourceCount
                FROM dictionaries ORDER BY sortOrder, id
                """
            ) { row in
                DictionaryRecord(
                    id: row.int(0),
                    uuid: row.text(1),
                    title: row.text(2),
                    folderName: row.text(3),
                    mdxFileName: row.text(4),
                    enabled: row.int(5) != 0,
                    sortOrder: Int(row.int(6)),
                    entryCount: Int(row.int(7)),
                    resourceCount: Int(row.int(8))
                )
            }
        }

        stateLock.lock()
        cachedRecords = rows
        cachedRecordsByUUID = Dictionary(rows.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        stateLock.unlock()
        return rows
    }

    /// One dictionary by UUID, served from the same cache.
    private func record(uuid: String) throws -> DictionaryRecord? {
        _ = try dictionaries()
        stateLock.lock()
        defer { stateLock.unlock() }
        return cachedRecordsByUUID[uuid]
    }

    private func invalidateRecordCache() {
        stateLock.lock()
        cachedRecords = nil
        cachedRecordsByUUID = [:]
        stateLock.unlock()
    }

    public func folderURL(for record: DictionaryRecord) -> URL {
        dictionariesURL.appendingPathComponent(record.folderName, isDirectory: true)
    }

    // MARK: - Import

    /// Copies the .mdx (and every sibling file sharing its base name, e.g.
    /// .mdd parts, .css, .js) into the library and indexes all keywords.
    @discardableResult
    public func importDictionary(
        from sourceMdxURL: URL,
        progress: ((ImportProgress) -> Void)? = nil
    ) throws -> DictionaryRecord {
        let fm = FileManager.default
        let uuid = UUID().uuidString
        let folder = dictionariesURL.appendingPathComponent(uuid, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        do {
            progress?(ImportProgress(stage: "Copying files…"))
            let baseName = sourceMdxURL.deletingPathExtension().lastPathComponent
            let sourceDir = sourceMdxURL.deletingLastPathComponent()
            let siblings = (try? fm.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: nil)) ?? []
            for file in siblings {
                let name = file.lastPathComponent
                guard name == baseName || name.hasPrefix(baseName + ".") else { continue }
                try fm.copyItem(at: file, to: folder.appendingPathComponent(name))
            }

            let mdxFileName = sourceMdxURL.lastPathComponent
            let mdx = try MdictFile(url: folder.appendingPathComponent(mdxFileName))

            progress?(ImportProgress(stage: "Reading keywords…"))

            var nextOrder = 0
            let maxOrder = try pool.read { db in
                try db.query("SELECT MAX(sortOrder) FROM dictionaries", row: { $0.int(0) }).first
            }
            if let maxOrder { nextOrder = Int(maxOrder) + 1 }

            // Entries stream straight into SQLite; materializing them first
            // would hold every headword of a large dictionary in memory. The
            // running count is therefore only known as we go, so the row is
            // inserted with a zero count and corrected at the end.
            // The header's entry count makes this a determinate bar.
            let expectedEntries = Int(min(mdx.info.entryCount, UInt64(Int.max)))
            progress?(ImportProgress(stage: "Indexing entries", completed: 0, total: expectedEntries))
            var entryCount = 0
            let dictID: Int64 = try pool.write { db in
                try db.transaction {
                    try db.run(
                        "INSERT INTO dictionaries (uuid, title, folder, mdxFile, enabled, sortOrder, entryCount) VALUES (?,?,?,?,1,?,0)",
                        [.text(uuid), .text(mdx.info.title), .text(uuid), .text(mdxFileName),
                         .int(Int64(nextOrder))]
                    )
                    let dictID = db.lastInsertRowID
                    let insert = try db.prepare(
                        "INSERT INTO entries (dict, key, nkey, offset, length) VALUES (?,?,?,?,?)"
                    )
                    try mdx.forEachIndexedEntry { entry in
                        try insert.bind([
                            .int(dictID),
                            .text(entry.key),
                            .text(Self.normalizeKey(entry.key)),
                            .int(Int64(bitPattern: entry.recordOffset)),
                            .int(Int64(entry.recordLength)),
                        ])
                        try insert.step()
                        insert.reset()
                        entryCount += 1
                        if entryCount % 2_000 == 0 {
                            progress?(ImportProgress(
                                stage: "Indexing entries",
                                completed: entryCount,
                                total: expectedEntries
                            ))
                        }
                    }
                    try db.run(
                        "UPDATE dictionaries SET entryCount = ? WHERE id = ?",
                        [.int(Int64(entryCount)), .int(dictID)]
                    )
                    return dictID
                }
            }

            // Index resources from every .mdd part.
            var resourceCount = 0
            let mddURLs = mddFiles(in: folder)
            if !mddURLs.isEmpty {
                progress?(ImportProgress(stage: "Indexing resources…"))
                try pool.write { db in
                    try db.transaction {
                        let insert = try db.prepare(
                            "INSERT INTO resources (dict, part, path, offset, length) VALUES (?,?,?,?,?)"
                        )
                        for (part, mddURL) in mddURLs.enumerated() {
                            let mdd = try MdictFile(url: mddURL)
                            try mdd.forEachIndexedEntry { entry in
                                try insert.bind([
                                    .int(dictID),
                                    .int(Int64(part)),
                                    .text(MdictFile.normalizeResourcePath(entry.key)),
                                    .int(Int64(bitPattern: entry.recordOffset)),
                                    .int(Int64(entry.recordLength)),
                                ])
                                try insert.step()
                                insert.reset()
                                resourceCount += 1
                            }
                        }
                    }
                    try db.run(
                        "UPDATE dictionaries SET resourceCount = ? WHERE id = ?",
                        [.int(Int64(resourceCount)), .int(dictID)]
                    )
                }
            }

            invalidateRecordCache()
            return DictionaryRecord(
                id: dictID, uuid: uuid, title: mdx.info.title, folderName: uuid,
                mdxFileName: mdxFileName, enabled: true, sortOrder: nextOrder,
                entryCount: entryCount, resourceCount: resourceCount
            )
        } catch {
            try? fm.removeItem(at: folder)
            invalidateRecordCache()
            throw error
        }
    }

    /// Removes a dictionary from Lexicon's index without touching its files.
    /// The app is responsible for moving the folder to the system Trash first.
    public func unregisterDictionary(_ record: DictionaryRecord) throws {
        try pool.write { db in
            try db.transaction {
                try db.run("DELETE FROM entries WHERE dict = ?", [.int(record.id)])
                try db.run("DELETE FROM resources WHERE dict = ?", [.int(record.id)])
                try db.run("DELETE FROM dictionaries WHERE id = ?", [.int(record.id)])
            }
        }
        stateLock.lock()
        handles.removeValue(forKey: record.uuid)
        stateLock.unlock()
        invalidateRecordCache()
    }

    /// Renames a dictionary as shown in the app. The dictionary's own files are
    /// untouched; only the library's label changes.
    public func setTitle(_ title: String, for record: DictionaryRecord) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try pool.write { db in
            try db.run(
                "UPDATE dictionaries SET title = ? WHERE id = ?",
                [.text(trimmed), .int(record.id)]
            )
        }
        invalidateRecordCache()
    }

    public func setEnabled(_ enabled: Bool, for record: DictionaryRecord) throws {
        try pool.write { db in
            try db.run(
                "UPDATE dictionaries SET enabled = ? WHERE id = ?",
                [.int(enabled ? 1 : 0), .int(record.id)]
            )
        }
        invalidateRecordCache()
    }

    /// Persists a full reordering (array of records in the desired order).
    public func reorder(_ records: [DictionaryRecord]) throws {
        try pool.write { db in
            try db.transaction {
                for (index, record) in records.enumerated() {
                    try db.run(
                        "UPDATE dictionaries SET sortOrder = ? WHERE id = ?",
                        [.int(Int64(index)), .int(record.id)]
                    )
                }
            }
        }
        invalidateRecordCache()
    }

    // MARK: - Search

    /// Unified search across all enabled dictionaries, in tiers: exact and
    /// prefix matches first (an indexed range scan), then substring matches,
    /// and — only when nothing matched literally — near misses.
    ///
    /// Each tier runs only if the previous ones left room, so the common case
    /// costs exactly what the old prefix-only search did.
    public func search(matching query: String, limit: Int = 60) throws -> [SearchResult] {
        let normalized = Self.normalizeKey(query)
        guard !normalized.isEmpty else { return [] }

        var seen = Set<String>()
        var results: [SearchResult] = []

        for match in try prefixMatches(normalized, limit: limit)
        where seen.insert(match.normalizedKey).inserted {
            results.append(match)
        }
        if results.count >= limit { return Array(results.prefix(limit)) }

        for match in try substringMatches(normalized, limit: limit - results.count)
        where seen.insert(match.normalizedKey).inserted {
            results.append(match)
        }
        if !results.isEmpty { return Array(results.prefix(limit)) }

        // Nothing matched literally, so offer the closest headwords instead of
        // a dead end.
        return try fuzzyMatches(normalized, limit: min(limit, 12))
    }

    /// Exact and prefix matches, served by `idx_entries_nkey` as a range scan.
    private func prefixMatches(_ normalized: String, limit: Int) throws -> [SearchResult] {
        // SQLite compares TEXT byte-wise, so the upper bound has to sort above
        // every UTF-8 continuation of the prefix. U+FFFF (EF BF BF) does not:
        // it would drop headwords whose next character is astral, such as
        // emoji or CJK Extension B. U+10FFFF (F4 8F BF BF) is the maximum
        // scalar and therefore the maximum encoding.
        let upper = normalized + "\u{10FFFF}"
        return try pool.read { db in
            try db.query(
                """
                SELECT e.nkey, MIN(e.key), COUNT(DISTINCT e.dict)
                FROM entries e
                JOIN dictionaries d ON d.id = e.dict AND d.enabled = 1
                WHERE e.nkey >= ? AND e.nkey < ?
                GROUP BY e.nkey
                ORDER BY e.nkey
                LIMIT ?
                """,
                [.text(normalized), .text(upper), .int(Int64(limit))]
            ) { row in
                let key = row.text(0)
                return SearchResult(
                    normalizedKey: key,
                    displayKey: row.text(1),
                    dictionaryCount: Int(row.int(2)),
                    matchKind: key == normalized ? .exact : .prefix
                )
            }
        }
    }

    /// Headwords containing the query somewhere other than the start.
    ///
    /// No index can serve this, so it is only reached when the prefix tier came
    /// up short, and the LIMIT bounds how much of the scan SQLite performs.
    private func substringMatches(_ normalized: String, limit: Int) throws -> [SearchResult] {
        guard limit > 0 else { return [] }
        let pattern = Self.escapedLikePattern(normalized)
        return try pool.read { db in
            try db.query(
                """
                SELECT e.nkey, MIN(e.key), COUNT(DISTINCT e.dict)
                FROM entries e
                JOIN dictionaries d ON d.id = e.dict AND d.enabled = 1
                WHERE e.nkey LIKE ? ESCAPE '\\' AND e.nkey NOT LIKE ? ESCAPE '\\'
                GROUP BY e.nkey
                ORDER BY length(e.nkey), e.nkey
                LIMIT ?
                """,
                [.text("%" + pattern + "%"), .text(pattern + "%"), .int(Int64(limit))]
            ) { row in
                SearchResult(
                    normalizedKey: row.text(0),
                    displayKey: row.text(1),
                    dictionaryCount: Int(row.int(2)),
                    matchKind: .substring
                )
            }
        }
    }

    /// Near misses, ranked by edit distance.
    ///
    /// Candidates come from an indexed range of headwords sharing the query's
    /// opening characters, narrowed further by length. Longer queries use a
    /// two-character bucket: with a one-character bucket a dictionary whose
    /// headwords share an opening letter degenerates into a full-table scan.
    ///
    /// The cost is that a typo inside the bucket prefix is not caught. That is
    /// the trade for never scanning the whole table to produce a suggestion.
    private func fuzzyMatches(_ normalized: String, limit: Int) throws -> [SearchResult] {
        guard !normalized.isEmpty else { return [] }
        let queryLength = normalized.count
        let bucketLength = queryLength >= 6 ? 2 : 1
        let bucket = String(normalized.prefix(bucketLength))
        let tolerance = queryLength <= 4 ? 1 : 2
        let candidates = try pool.read { db in
            try db.query(
                """
                SELECT e.nkey, MIN(e.key), COUNT(DISTINCT e.dict)
                FROM entries e
                JOIN dictionaries d ON d.id = e.dict AND d.enabled = 1
                WHERE e.nkey >= ? AND e.nkey < ?
                  AND length(e.nkey) BETWEEN ? AND ?
                GROUP BY e.nkey
                LIMIT 4000
                """,
                [
                    .text(bucket), .text(bucket + "\u{10FFFF}"),
                    .int(Int64(max(1, queryLength - tolerance))),
                    .int(Int64(queryLength + tolerance)),
                ]
            ) { row in
                (key: row.text(0), display: row.text(1), count: Int(row.int(2)))
            }
        }

        // Fold the query once. Building `[Character]` per candidate dominated
        // this loop: grapheme breaking is far more expensive than the distance.
        let queryScalars = Array(normalized.unicodeScalars)
        let scored = candidates.compactMap { candidate -> (Int, SearchResult)? in
            let candidateScalars = Array(candidate.key.unicodeScalars)
            guard abs(candidateScalars.count - queryScalars.count) <= tolerance else { return nil }
            let distance = Self.editDistance(queryScalars, candidateScalars, limit: tolerance)
            guard distance <= tolerance else { return nil }
            return (distance, SearchResult(
                normalizedKey: candidate.key,
                displayKey: candidate.display,
                dictionaryCount: candidate.count,
                matchKind: .fuzzy
            ))
        }
        return scored
            .sorted { ($0.0, $0.1.normalizedKey) < ($1.0, $1.1.normalizedKey) }
            .prefix(limit)
            .map(\.1)
    }

    private static func escapedLikePattern(_ value: String) -> String {
        var escaped = value
        for (symbol, replacement) in [("\\", "\\\\"), ("%", "\\%"), ("_", "\\_")] {
            escaped = escaped.replacingOccurrences(of: symbol, with: replacement)
        }
        return escaped
    }

    /// Levenshtein distance, abandoned as soon as it exceeds `limit`.
    public static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        editDistance(Array(a.unicodeScalars), Array(b.unicodeScalars), limit: limit)
    }

    /// Scalar-array form, so callers comparing one query against many
    /// candidates fold each string exactly once.
    static func editDistance(
        _ lhs: [Unicode.Scalar], _ rhs: [Unicode.Scalar], limit: Int
    ) -> Int {
        if abs(lhs.count - rhs.count) > limit { return limit + 1 }
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        var previous = Array(0 ... rhs.count)
        var current = [Int](repeating: 0, count: rhs.count + 1)
        for i in 1 ... lhs.count {
            current[0] = i
            var rowBest = current[0]
            for j in 1 ... rhs.count {
                let substitution = previous[j - 1] + (lhs[i - 1] == rhs[j - 1] ? 0 : 1)
                current[j] = min(substitution, previous[j] + 1, current[j - 1] + 1)
                rowBest = min(rowBest, current[j])
            }
            // Every later row can only grow, so this row settles the question.
            if rowBest > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }

    /// All entries for a headword, one or more per enabled dictionary,
    /// ordered by the user's dictionary order.
    public func entries(forNormalizedKey nkey: String) throws -> [EntryHit] {
        try pool.read { db in
            try db.query(
                """
                SELECT d.uuid, d.title, e.key, e.offset, e.length
                FROM entries e
                JOIN dictionaries d ON d.id = e.dict AND d.enabled = 1
                WHERE e.nkey = ?
                ORDER BY d.sortOrder, d.id, e.offset
                """,
                [.text(nkey)]
            ) { row in
                EntryHit(
                    dictionaryUUID: row.text(0),
                    dictionaryTitle: row.text(1),
                    key: row.text(2),
                    recordOffset: UInt64(bitPattern: row.int(3)),
                    recordLength: Int(row.int(4))
                )
            }
        }
    }

    // MARK: - Content access

    private func openDictionary(uuid: String) throws -> OpenDictionary {
        stateLock.lock()
        if let open = handles[uuid] {
            stateLock.unlock()
            return open
        }
        stateLock.unlock()

        guard let record = try record(uuid: uuid) else {
            throw MdxError.corruptData("unknown dictionary \(uuid)")
        }
        let folder = folderURL(for: record)
        let mdx = try MdictFile(url: folder.appendingPathComponent(record.mdxFileName))
        let mdds = try mddFiles(in: folder).map { try MdictFile(url: $0) }
        let open = OpenDictionary(mdx: mdx, mdds: mdds)

        stateLock.lock()
        defer { stateLock.unlock() }
        // Another thread may have opened the same dictionary meanwhile. Keep a
        // single instance so its decompressed-block cache stays shared.
        if let existing = handles[uuid] { return existing }
        handles[uuid] = open
        return open
    }

    private func mddFiles(in folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        )) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "mdd" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Reads and decodes an entry, following @@@LINK= redirects (bounded).
    public func entryText(for hit: EntryHit) throws -> String {
        var current = hit
        for _ in 0 ..< 8 {
            let open = try openDictionary(uuid: current.dictionaryUUID)
            let text = try open.mdx.entryText(
                at: current.recordOffset, length: current.recordLength
            )
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("@@@LINK=") else { return text }
            let target = String(trimmed.dropFirst("@@@LINK=".count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0\r\n \t"))
            let candidates = try entries(forNormalizedKey: Self.normalizeKey(target))
            guard let next = candidates.first(where: { $0.dictionaryUUID == current.dictionaryUUID })
            else { return text }
            current = next
        }
        return "" // redirect loop
    }

    /// Fetches a resource (image/audio/CSS/JS) for a dictionary: first from
    /// its indexed .mdd parts, then via fallbacks, then from loose files in
    /// the dictionary folder.
    public func resource(path: String, dictionaryUUID: String) throws -> Data? {
        let normalized = MdictFile.normalizeResourcePath(path)
        guard let record = try record(uuid: dictionaryUUID) else {
            return nil
        }

        if let data = try indexedResource(exactPath: normalized, record: record) {
            return data
        }

        // Extension-less audio references (OALD: "sound://_apple" while the
        // MDD stores "_apple#_uss_2.mp3"): complete by prefix.
        if !((normalized as NSString).lastPathComponent.contains(".")) {
            if let data = try indexedResource(prefix: normalized, record: record) {
                return data
            }
        }

        // Loose files with the exact requested name (e.g. Dict.css shipped
        // beside Dict.mdx, or a user-provided custom.css theme). These must
        // win over the base-name heuristic below.
        let folder = folderURL(for: record)
        let fileName = (normalized as NSString).lastPathComponent
        var candidates = [normalized]
        if !fileName.isEmpty, fileName != normalized {
            // Entries sometimes reference "somedir/style.css" while the css
            // sits next to the mdx.
            candidates.append(fileName)
        }
        for candidate in candidates {
            if let data = looseFile(named: candidate, in: folder) {
                return data
            }
        }

        // Repacked dictionaries whose entries reference the original CSS/JS
        // name (e.g. "mw_now.css") while the shipped file follows the mdx
        // base name ("mw.css"): fall back to "<mdx base>.<ext>".
        let ext = (normalized as NSString).pathExtension
        let mdxBase = (record.mdxFileName as NSString).deletingPathExtension.lowercased()
        let baseNameFallback = "\(mdxBase).\(ext)"
        let isOptionalOverride = fileName == "custom.css" || fileName == "custom.js"
        if !isOptionalOverride,
           (ext == "css" || ext == "js"), normalized != baseNameFallback {
            if let data = try indexedResource(exactPath: baseNameFallback, record: record) {
                return data
            }
            if let data = looseFile(named: baseNameFallback, in: folder) {
                return data
            }
        }
        return nil
    }

    private func looseFile(named name: String, in folder: URL) -> Data? {
        let fileURL = folder.appendingPathComponent(name)
        // Prevent path traversal outside the dictionary folder.
        guard fileURL.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") else {
            return nil
        }
        return try? Data(contentsOf: fileURL)
    }

    /// Last-resort lookup for requests that lost their dictionary context
    /// (JS-generated absolute paths): searches every enabled dictionary in
    /// the user's order.
    public func resourceSearchingAllDictionaries(path: String) throws -> Data? {
        for record in try dictionaries() where record.enabled {
            if let data = try resource(path: path, dictionaryUUID: record.uuid) {
                return data
            }
        }
        return nil
    }

    public func isKnownDictionaryUUID(_ uuid: String) -> Bool {
        do {
            return try record(uuid: uuid) != nil
        } catch {
            return false
        }
    }

    /// Location of one resource: which .mdd part, and where inside it.
    private struct ResourceLocation {
        let part: Int64
        let offset: Int64
        let length: Int64
    }

    /// Single-row resource lookup. Written against `prepare`/`step` rather than
    /// the generic `query` helper: nesting two generic closures here costs the
    /// type checker more than it is worth.
    private func resourceLocation(
        sql: String, bindings: [SQLiteDB.Binding]
    ) throws -> ResourceLocation? {
        try pool.read { db -> ResourceLocation? in
            let statement = try db.prepare(sql)
            try statement.bind(bindings)
            guard try statement.step() else { return nil }
            return ResourceLocation(
                part: statement.int(0), offset: statement.int(1), length: statement.int(2)
            )
        }
    }

    private func indexedResource(exactPath: String, record: DictionaryRecord) throws -> Data? {
        let location = try resourceLocation(
            sql: "SELECT part, offset, length FROM resources WHERE dict = ? AND path = ? LIMIT 1",
            bindings: [.int(record.id), .text(exactPath)]
        )
        guard let location else { return nil }
        return try readResource(location, uuid: record.uuid)
    }

    /// First resource whose path starts with `prefix` followed by '#' or '.'
    /// (used to complete extension-less sound references).
    private func indexedResource(prefix: String, record: DictionaryRecord) throws -> Data? {
        var escaped = prefix
        for (symbol, replacement) in [("\\", "\\\\"), ("%", "\\%"), ("_", "\\_")] {
            escaped = escaped.replacingOccurrences(of: symbol, with: replacement)
        }
        let location = try resourceLocation(
            sql: """
                SELECT part, offset, length FROM resources
                WHERE dict = ? AND (path LIKE ? ESCAPE '\\' OR path LIKE ? ESCAPE '\\')
                ORDER BY path LIMIT 1
                """,
            bindings: [.int(record.id), .text(escaped + "#%"), .text(escaped + ".%")]
        )
        guard let location else { return nil }
        return try readResource(location, uuid: record.uuid)
    }

    private func readResource(_ location: ResourceLocation, uuid: String) throws -> Data? {
        let open = try openDictionary(uuid: uuid)
        let part = Int(location.part)
        guard part >= 0, part < open.mdds.count else { return nil }
        return try open.mdds[part].recordData(
            at: UInt64(bitPattern: location.offset), length: Int(location.length)
        )
    }
}
