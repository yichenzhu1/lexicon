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
}

/// One headword match from the unified search.
public struct SearchResult: Identifiable, Hashable, Sendable {
    public var id: String { normalizedKey }
    public let normalizedKey: String
    public let displayKey: String
    public let dictionaryCount: Int
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
                SELECT id, uuid, title, folder, mdxFile, enabled, sortOrder, entryCount
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
                    entryCount: Int(row.int(7))
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
        progress: ((String) -> Void)? = nil
    ) throws -> DictionaryRecord {
        let fm = FileManager.default
        let uuid = UUID().uuidString
        let folder = dictionariesURL.appendingPathComponent(uuid, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        do {
            progress?("Copying files…")
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

            progress?("Reading keywords…")

            var nextOrder = 0
            let maxOrder = try pool.read { db in
                try db.query("SELECT MAX(sortOrder) FROM dictionaries", row: { $0.int(0) }).first
            }
            if let maxOrder { nextOrder = Int(maxOrder) + 1 }

            // Entries stream straight into SQLite; materializing them first
            // would hold every headword of a large dictionary in memory. The
            // running count is therefore only known as we go, so the row is
            // inserted with a zero count and corrected at the end.
            progress?("Indexing entries…")
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
                        if entryCount % 20_000 == 0 {
                            progress?("Indexing \(entryCount) entries…")
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
            let mddURLs = mddFiles(in: folder)
            if !mddURLs.isEmpty {
                progress?("Indexing resources…")
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
                            }
                        }
                    }
                }
            }

            invalidateRecordCache()
            return DictionaryRecord(
                id: dictID, uuid: uuid, title: mdx.info.title, folderName: uuid,
                mdxFileName: mdxFileName, enabled: true, sortOrder: nextOrder,
                entryCount: entryCount
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

    /// Unified prefix search across all enabled dictionaries.
    public func search(prefix: String, limit: Int = 60) throws -> [SearchResult] {
        let normalized = Self.normalizeKey(prefix)
        guard !normalized.isEmpty else { return [] }
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
                SearchResult(
                    normalizedKey: row.text(0),
                    displayKey: row.text(1),
                    dictionaryCount: Int(row.int(2))
                )
            }
        }
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
