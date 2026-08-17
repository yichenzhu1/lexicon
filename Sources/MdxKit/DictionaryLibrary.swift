import Foundation
import UniformTypeIdentifiers

/// A resource ready to be served to a dictionary page. Text resources are
/// transcoded to UTF-8 so WebKit never has to guess the MDX's legacy encoding.
public struct DictionaryResource: Sendable {
    public let data: Data
    public let mimeType: String
    public let textEncodingName: String?
    public let resolvedPath: String

    public init(
        data: Data, mimeType: String, textEncodingName: String?, resolvedPath: String
    ) {
        self.data = data
        self.mimeType = mimeType
        self.textEncodingName = textEncodingName
        self.resolvedPath = resolvedPath
    }
}

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
    public let resourceCount: Int
    /// Files served directly beside the MDX (including same-basename CSS/JS).
    public let looseResourceCount: Int

    public var totalResourceCount: Int { resourceCount + looseResourceCount }
    public var hasResources: Bool { totalResourceCount > 0 }
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

public final class ImportCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}
    public func cancel() { lock.withLock { cancelled = true } }
    public var isCancelled: Bool { lock.withLock { cancelled } }
    func check() throws { if isCancelled { throw CancellationError() } }
}

public final class SearchCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.withLock { cancelled = true } }
    public var isCancelled: Bool { lock.withLock { cancelled } }
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
    public private(set) var startupWarnings: [String] = []
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
        try fm.createDirectory(
            at: rootURL.appendingPathComponent("Dictionaries/.staging", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(
            at: rootURL.appendingPathComponent("Dictionaries/Recovery", isDirectory: true),
            withIntermediateDirectories: true
        )
        pool = try SQLitePool(path: rootURL.appendingPathComponent("index.sqlite").path)
        var previousSchemaVersion = 0
        try pool.write { db in
            previousSchemaVersion = Int(
                try db.query("PRAGMA user_version", row: { $0.int(0) }).first ?? 0
            )
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
            if !columns.contains("looseResourceCount") {
                try db.exec(
                    "ALTER TABLE dictionaries ADD COLUMN looseResourceCount INTEGER NOT NULL DEFAULT 0"
                )
            }
        }
        try reconcileFilesystem()
        if previousSchemaVersion < 4 {
            let partsRebuilt = migrateResourcePartOrdering()
            let looseCountsUpdated = refreshLooseResourceCounts()
            if partsRebuilt && looseCountsUpdated {
                try pool.write { db in try db.exec("PRAGMA user_version = 4") }
            }
        }
    }

    /// Earlier versions sorted `.mdd` filenames lexically, which can put
    /// numbered volumes before the base file. Since the resource table stores
    /// a numeric part index, changing the open order requires rebuilding those
    /// indices once or existing libraries would read offsets from the wrong
    /// file.
    @discardableResult
    private func migrateResourcePartOrdering() -> Bool {
        let rows: [(id: Int64, folder: String)]
        do {
            rows = try pool.read { db in
                try db.query("SELECT id, folder FROM dictionaries") {
                    (id: $0.int(0), folder: $0.text(1))
                }
            }
        } catch {
            startupWarnings.append("Could not inspect resource indices for migration: \(error.localizedDescription)")
            return false
        }
        var succeeded = true
        for row in rows {
            let folder = dictionariesURL.appendingPathComponent(row.folder, isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            let parts = mddFiles(in: folder)
            do {
                var count = 0
                try pool.write { db in
                    try db.transaction {
                        try db.run("DELETE FROM resources WHERE dict = ?", [.int(row.id)])
                        let insert = try db.prepare(
                            "INSERT INTO resources (dict, part, path, offset, length) VALUES (?,?,?,?,?)"
                        )
                        for (part, url) in parts.enumerated() {
                            let mdd = try MdictFile(url: url)
                            try mdd.forEachIndexedEntry { entry in
                                try insert.bind([
                                    .int(row.id), .int(Int64(part)),
                                    .text(MdictFile.normalizeResourcePath(entry.key)),
                                    .int(Int64(bitPattern: entry.recordOffset)),
                                    .int(Int64(entry.recordLength)),
                                ])
                                try insert.step(); insert.reset(); count += 1
                            }
                        }
                        try db.run(
                            "UPDATE dictionaries SET resourceCount = ? WHERE id = ?",
                            [.int(Int64(count)), .int(row.id)]
                        )
                    }
                }
            } catch {
                succeeded = false
                startupWarnings.append(
                    "Could not rebuild a dictionary's multipart resource index: \(error.localizedDescription)"
                )
            }
        }
        invalidateRecordCache()
        return succeeded
    }

    /// Same-basename CSS/JS and other loose assets are valid MDict resources;
    /// GoldenDict-NG resolves them from the MDX folder before consulting MDDs.
    /// Persist their count so the manager does not incorrectly report that a
    /// dictionary containing only loose companions has no resources.
    @discardableResult
    private func refreshLooseResourceCounts() -> Bool {
        do {
            let rows = try pool.read { db in
                try db.query("SELECT id, folder, mdxFile FROM dictionaries") {
                    (id: $0.int(0), folder: $0.text(1), mdx: $0.text(2))
                }
            }
            try pool.write { db in
                try db.transaction {
                    for row in rows {
                        let folder = dictionariesURL.appendingPathComponent(row.folder, isDirectory: true)
                        guard FileManager.default.fileExists(atPath: folder.path) else { continue }
                        let count = countLooseResources(in: folder, mdxFileName: row.mdx)
                        try db.run(
                            "UPDATE dictionaries SET looseResourceCount = ? WHERE id = ?",
                            [.int(Int64(count)), .int(row.id)]
                        )
                    }
                }
            }
            invalidateRecordCache()
            return true
        } catch {
            startupWarnings.append("Could not count loose dictionary resources: \(error.localizedDescription)")
            return false
        }
    }

    private func reconcileFilesystem() throws {
        let fm = FileManager.default
        let staging = dictionariesURL.appendingPathComponent(".staging", isDirectory: true)
        let recovery = dictionariesURL.appendingPathComponent("Recovery", isDirectory: true)
        let rows = try pool.read { db in
            try db.query("SELECT id, uuid, folder FROM dictionaries") {
                (id: $0.int(0), uuid: $0.text(1), folder: $0.text(2))
            }
        }
        let byUUID = Dictionary(uniqueKeysWithValues: rows.map { ($0.uuid.lowercased(), $0) })

        for staged in (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? [] {
            let key = staged.lastPathComponent.lowercased()
            let final = dictionariesURL.appendingPathComponent(staged.lastPathComponent, isDirectory: true)
            if byUUID[key] != nil, !fm.fileExists(atPath: final.path) {
                try fm.moveItem(at: staged, to: final)
                startupWarnings.append("Recovered an interrupted dictionary import.")
            } else {
                try? fm.removeItem(at: staged)
            }
        }

        var missingIDs: [Int64] = []
        for row in rows {
            let folder = dictionariesURL.appendingPathComponent(row.folder, isDirectory: true)
            if !fm.fileExists(atPath: folder.path) { missingIDs.append(row.id) }
        }
        for id in missingIDs { try deleteIndexRows(forDictionaryID: id) }
        if !missingIDs.isEmpty {
            startupWarnings.append("Removed \(missingIDs.count) stale dictionary index record(s) whose files were missing.")
        }

        let registeredFolders = Set(rows.map(\.folder))
        for item in (try? fm.contentsOfDirectory(at: dictionariesURL, includingPropertiesForKeys: nil)) ?? [] {
            let name = item.lastPathComponent
            guard name != ".staging", name != "Recovery", !registeredFolders.contains(name) else { continue }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: item.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let destination = recovery.appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
            try fm.moveItem(at: item, to: destination)
            startupWarnings.append("Moved an unindexed dictionary folder to Recovery instead of deleting it.")
        }
    }

    // MARK: - Normalization

    /// Search key normalization: case- and diacritic-insensitive.
    public static func normalizeKey(_ key: String) -> String {
        var isASCII = true
        var containsUppercaseASCII = false
        for byte in key.utf8 {
            if byte >= 0x80 {
                isASCII = false
                break
            }
            if byte >= 0x41, byte <= 0x5A { containsUppercaseASCII = true }
        }
        if isASCII {
            let hasEdgeWhitespace = key.first?.isWhitespace == true || key.last?.isWhitespace == true
            if !containsUppercaseASCII, !hasEdgeWhitespace { return key }
            let trimmed = hasEdgeWhitespace
                ? key.trimmingCharacters(in: .whitespacesAndNewlines) : key
            return containsUppercaseASCII ? trimmed.lowercased() : trimmed
        }
        return key.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
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
                       resourceCount, looseResourceCount
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
                    resourceCount: Int(row.int(8)),
                    looseResourceCount: Int(row.int(9))
                )
            }
        }

        stateLock.lock()
        cachedRecords = rows
        cachedRecordsByUUID = Dictionary(
            rows.map { ($0.uuid.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        stateLock.unlock()
        return rows
    }

    /// One dictionary by UUID, served from the same cache.
    private func record(uuid: String) throws -> DictionaryRecord? {
        _ = try dictionaries()
        stateLock.lock()
        defer { stateLock.unlock() }
        return cachedRecordsByUUID[uuid.lowercased()]
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

    /// Copies the MDX, its same-basename package files, and every sibling CSS
    /// or JavaScript file into the library, then indexes all keywords.
    @discardableResult
    public func importDictionary(
        from sourceMdxURL: URL,
        cancellation: ImportCancellationToken? = nil,
        progress: ((ImportProgress) -> Void)? = nil
    ) throws -> DictionaryRecord {
        let fm = FileManager.default
        let uuid = UUID().uuidString
        let finalFolder = dictionariesURL.appendingPathComponent(uuid, isDirectory: true)
        let folder = dictionariesURL.appendingPathComponent(".staging/\(uuid)", isDirectory: true)
        var registeredDictionaryID: Int64?
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        do {
            try cancellation?.check()
            progress?(ImportProgress(stage: "Copying files…"))
            let baseName = sourceMdxURL.deletingPathExtension().lastPathComponent
            let sourceDir = sourceMdxURL.deletingLastPathComponent()
            let siblings = try fm.contentsOfDirectory(
                at: sourceDir,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            var discoveredLooseCompanions = Set<String>()
            for file in siblings {
                try cancellation?.check()
                let name = file.lastPathComponent
                let ext = file.pathExtension.lowercased()
                let isPackageSibling = name == baseName || name.hasPrefix(baseName + ".")
                let isLooseCode = ext == "css" || ext == "js"
                guard isPackageSibling || isLooseCode,
                      let values = try? file.resourceValues(
                          forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                      ),
                      values.isRegularFile == true, values.isSymbolicLink != true
                else { continue }
                try fm.copyItem(at: file, to: folder.appendingPathComponent(name))
                if isLooseCode { discoveredLooseCompanions.insert(name) }
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
            var resourceCount = 0
            // Every sibling CSS/JS file belongs to this dictionary package,
            // even when its name differs from the MDX (for example,
            // oald-fork.mdx with oald.css, oaldzh.css and oald.js). Seeding
            // these paths also makes copyLooseReferences inspect CSS imports
            // and url(...) dependencies recursively.
            var looseReferences = discoveredLooseCompanions
            // Entry HTML only needs decoding when the source package actually
            // contains a loose asset that CSS discovery cannot already reach.
            // Most production dictionaries keep media in MDD volumes, so the
            // old unconditional scan redundantly decoded 600k+ entries.
            let scanEntryAssets = sourceHasPotentialLooseAssets(
                siblings, baseName: baseName
            )
            var assetOffsets = Set<UInt64>()
            let mddURLs = mddFiles(in: folder)
            let progressStride = max(2_000, expectedEntries / 100)
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
                        if entryCount % 2_000 == 0 { try cancellation?.check() }
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
                        if scanEntryAssets,
                           assetOffsets.insert(entry.recordOffset).inserted,
                           entry.recordLength <= 8 * 1_024 * 1_024,
                           let text = try? mdx.entryText(
                               at: entry.recordOffset, length: Int(entry.recordLength)
                           ) {
                            looseReferences.formUnion(EntryPageBuilder.localResourceReferences(in: text))
                        }
                        if entryCount.isMultiple(of: progressStride) {
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
                    if !mddURLs.isEmpty {
                        progress?(ImportProgress(stage: "Indexing resources…"))
                        let resourceInsert = try db.prepare(
                            "INSERT INTO resources (dict, part, path, offset, length) VALUES (?,?,?,?,?)"
                        )
                        for (part, mddURL) in mddURLs.enumerated() {
                            let mdd = try MdictFile(url: mddURL)
                            try mdd.forEachIndexedEntry { entry in
                                if resourceCount % 2_000 == 0 { try cancellation?.check() }
                                try resourceInsert.bind([
                                    .int(dictID), .int(Int64(part)),
                                    .text(MdictFile.normalizeResourcePath(entry.key)),
                                    .int(Int64(bitPattern: entry.recordOffset)),
                                    .int(Int64(entry.recordLength)),
                                ])
                                try resourceInsert.step()
                                resourceInsert.reset()
                                resourceCount += 1
                            }
                        }
                        try db.run(
                            "UPDATE dictionaries SET resourceCount = ? WHERE id = ?",
                            [.int(Int64(resourceCount)), .int(dictID)]
                        )
                    }
                    return dictID
                }
            }
            registeredDictionaryID = dictID

            try cancellation?.check()
            progress?(ImportProgress(stage: "Copying referenced assets…"))
            let missingLooseReferences = try copyLooseReferences(
                looseReferences, sourceDirectory: sourceDir, destinationDirectory: folder,
                dictionaryEncoding: mdx.info.encoding, cancellation: cancellation
            )
            var unresolved: [String] = []
            for path in missingLooseReferences {
                let normalized = MdictFile.normalizeResourcePath(path)
                let indexed = try resourceLocation(
                    sql: "SELECT part, offset, length, path FROM resources WHERE dict = ? AND path = ? LIMIT 1",
                    bindings: [.int(dictID), .text(normalized)]
                ) != nil
                if !indexed { unresolved.append(path) }
            }
            if !unresolved.isEmpty {
                let preview = unresolved.sorted().prefix(5).joined(separator: ", ")
                progress?(ImportProgress(
                    stage: "Warning: \(unresolved.count) referenced local asset(s) were not found (\(preview))"
                ))
            }
            let looseResourceCount = countLooseResources(in: folder, mdxFileName: mdxFileName)
            try pool.write { db in
                try db.run(
                    "UPDATE dictionaries SET looseResourceCount = ? WHERE id = ?",
                    [.int(Int64(looseResourceCount)), .int(dictID)]
                )
            }
            try fm.moveItem(at: folder, to: finalFolder)
            try? pool.write { db in try db.exec("PRAGMA wal_checkpoint(PASSIVE)") }
            invalidateRecordCache()
            return DictionaryRecord(
                id: dictID, uuid: uuid, title: mdx.info.title, folderName: uuid,
                mdxFileName: mdxFileName, enabled: true, sortOrder: nextOrder,
                entryCount: entryCount, resourceCount: resourceCount,
                looseResourceCount: looseResourceCount
            )
        } catch {
            // Entry indexing commits before resource indexing begins. If a
            // damaged sibling MDD fails later, remove that already-committed
            // row and its entries as well as the copied folder.
            if let registeredDictionaryID {
                try? deleteIndexRows(forDictionaryID: registeredDictionaryID)
            }
            try? fm.removeItem(at: folder)
            try? fm.removeItem(at: finalFolder)
            invalidateRecordCache()
            throw error
        }
    }

    private func copyLooseReferences(
        _ references: Set<String>,
        sourceDirectory: URL,
        destinationDirectory: URL,
        dictionaryEncoding: MdictTextEncoding,
        cancellation: ImportCancellationToken?
    ) throws -> Set<String> {
        let fm = FileManager.default
        let sourceRoot = sourceDirectory.resolvingSymlinksInPath().standardizedFileURL
        var queue = Array(references)
        var visited = Set<String>()
        var missing = Set<String>()
        while let relative = queue.popLast() {
            try cancellation?.check()
            guard visited.insert(relative).inserted else { continue }
            let source = sourceDirectory.appendingPathComponent(relative)
                .resolvingSymlinksInPath().standardizedFileURL
            guard source.path.hasPrefix(sourceRoot.path + "/"),
                  let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true
            else { missing.insert(relative); continue }
            let destination = destinationDirectory.appendingPathComponent(relative)
            if !fm.fileExists(atPath: destination.path) {
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: destination)
            }
            guard source.pathExtension.lowercased() == "css",
                  let data = try? Data(contentsOf: source)
            else { continue }
            let css = Self.decodeTextResource(data, dictionaryEncoding: dictionaryEncoding)
            let base = (relative as NSString).deletingLastPathComponent
            for nested in EntryPageBuilder.localCSSResourceReferences(in: css) {
                let combined = (base as NSString).appendingPathComponent(nested)
                queue.append((combined as NSString).standardizingPath)
            }
        }
        return missing
    }

    /// True when entry HTML might point at a loose file that is neither part
    /// of the same-basename MDX package nor discoverable through sibling CSS.
    /// Hidden files and alternate nested CSS/JS themes do not justify decoding
    /// every dictionary entry merely to prove they are unused.
    private func sourceHasPotentialLooseAssets(
        _ siblings: [URL], baseName: String
    ) -> Bool {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        let intrinsicallyDiscoveredExtensions: Set<String> = ["mdx", "mdd", "css", "js"]

        for sibling in siblings where !sibling.lastPathComponent.hasPrefix(".") {
            guard let values = try? sibling.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true
            else { continue }

            if values.isRegularFile == true {
                let name = sibling.lastPathComponent
                let isPackageSibling = name == baseName || name.hasPrefix(baseName + ".")
                if !isPackageSibling,
                   !intrinsicallyDiscoveredExtensions.contains(sibling.pathExtension.lowercased()) {
                    return true
                }
                continue
            }

            guard values.isDirectory == true,
                  let enumerator = fm.enumerator(
                      at: sibling,
                      includingPropertiesForKeys: Array(keys),
                      options: [.skipsHiddenFiles, .skipsPackageDescendants]
                  )
            else { continue }
            for case let candidate as URL in enumerator {
                guard let candidateValues = try? candidate.resourceValues(forKeys: keys),
                      candidateValues.isRegularFile == true,
                      candidateValues.isSymbolicLink != true
                else { continue }
                if !intrinsicallyDiscoveredExtensions.contains(candidate.pathExtension.lowercased()) {
                    return true
                }
            }
        }
        return false
    }

    /// Removes a dictionary from Lexicon's index without touching its files.
    /// The app is responsible for moving the folder to the system Trash first.
    public func unregisterDictionary(_ record: DictionaryRecord) throws {
        try deleteIndexRows(forDictionaryID: record.id)
        stateLock.lock()
        handles.removeValue(forKey: record.uuid.lowercased())
        stateLock.unlock()
        invalidateRecordCache()
    }

    private func deleteIndexRows(forDictionaryID id: Int64) throws {
        try pool.write { db in
            try db.transaction {
                try db.run("DELETE FROM entries WHERE dict = ?", [.int(id)])
                try db.run("DELETE FROM resources WHERE dict = ?", [.int(id)])
                try db.run("DELETE FROM dictionaries WHERE id = ?", [.int(id)])
            }
            try db.exec("PRAGMA wal_checkpoint(PASSIVE)")
        }
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
            try db.exec("PRAGMA wal_checkpoint(PASSIVE)")
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
    public func search(
        matching query: String, limit: Int = 60,
        cancellation: SearchCancellationToken? = nil
    ) throws -> [SearchResult] {
        let normalized = Self.normalizeKey(query)
        guard !normalized.isEmpty else { return [] }
        if cancellation?.isCancelled == true { throw CancellationError() }

        var seen = Set<String>()
        var results: [SearchResult] = []

        for match in try prefixMatches(normalized, limit: limit)
        where seen.insert(match.normalizedKey).inserted {
            results.append(match)
        }
        if results.count >= limit { return Array(results.prefix(limit)) }
        if cancellation?.isCancelled == true { throw CancellationError() }

        for match in try substringMatches(
            normalized, limit: limit - results.count, cancellation: cancellation
        )
        where seen.insert(match.normalizedKey).inserted {
            results.append(match)
        }
        if !results.isEmpty { return Array(results.prefix(limit)) }

        // Nothing matched literally, so offer the closest headwords instead of
        // a dead end.
        return try fuzzyMatches(normalized, limit: min(limit, 12), cancellation: cancellation)
    }

    /// Fast indexed phase used to update the UI before substring/fuzzy
    /// completion. It never performs a table scan.
    public func searchPrefix(matching query: String, limit: Int = 60) throws -> [SearchResult] {
        let normalized = Self.normalizeKey(query)
        guard !normalized.isEmpty else { return [] }
        return try prefixMatches(normalized, limit: limit)
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
    private func substringMatches(
        _ normalized: String, limit: Int, cancellation: SearchCancellationToken?
    ) throws -> [SearchResult] {
        guard limit > 0 else { return [] }
        let pattern = Self.escapedLikePattern(normalized)
        return try pool.read { db in
            try db.withProgressCancellation({ cancellation?.isCancelled ?? false }) {
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
                        normalizedKey: row.text(0), displayKey: row.text(1),
                        dictionaryCount: Int(row.int(2)), matchKind: .substring
                    )
                }
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
    private func fuzzyMatches(
        _ normalized: String, limit: Int, cancellation: SearchCancellationToken?
    ) throws -> [SearchResult] {
        guard !normalized.isEmpty else { return [] }
        let queryLength = normalized.count
        let bucketLength = queryLength >= 6 ? 2 : 1
        let bucket = String(normalized.prefix(bucketLength))
        let tolerance = queryLength <= 4 ? 1 : 2
        let candidates = try pool.read { db in
            try db.withProgressCancellation({ cancellation?.isCancelled ?? false }) {
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
        let canonicalUUID = uuid.lowercased()
        if let open = handles[canonicalUUID] {
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
        if let existing = handles[canonicalUUID] { return existing }
        handles[canonicalUUID] = open
        return open
    }

    private func mddFiles(in folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        )) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "mdd" }
            .sorted {
                let lhs = Self.mddPartNumber($0.lastPathComponent)
                let rhs = Self.mddPartNumber($1.lastPathComponent)
                return lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
            }
    }

    /// MDict volumes are base.mdd, base.1.mdd, base.2.mdd, ... . A lexical
    /// sort puts base.10 before base.2 and can also put numbered parts before
    /// the base volume.
    private static func mddPartNumber(_ name: String) -> (Int, String) {
        let stem = (name as NSString).deletingPathExtension
        let suffix = (stem as NSString).pathExtension
        if let number = Int(suffix) { return (number + 1, name.lowercased()) }
        return (0, name.lowercased())
    }

    private func countLooseResources(in folder: URL, mdxFileName: String) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var count = 0
        for case let file as URL in enumerator {
            guard file.lastPathComponent != mdxFileName,
                  !["mdx", "mdd"].contains(file.pathExtension.lowercased()),
                  let values = try? file.resourceValues(
                      forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                  ),
                  values.isRegularFile == true, values.isSymbolicLink != true
            else { continue }
            count += 1
        }
        return count
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

    /// Fetches a resource (image/audio/CSS/JS) for one dictionary. Exact loose
    /// files take precedence, followed by deterministic MDD parts and bounded
    /// compatibility fallbacks.
    public func resource(path: String, dictionaryUUID: String) throws -> DictionaryResource? {
        let normalized = MdictFile.normalizeResourcePath(path)
        guard let record = try record(uuid: dictionaryUUID) else {
            return nil
        }

        // GoldenDict-NG checks the MDX's containing folder before its MDD
        // volumes. This is important for repacks that intentionally override
        // an embedded stylesheet or script with a same-named loose companion.
        let folder = folderURL(for: record)
        let fileName = (normalized as NSString).lastPathComponent
        var looseCandidates = [normalized]
        if !fileName.isEmpty, fileName != normalized {
            looseCandidates.append(fileName)
        }
        for candidate in looseCandidates {
            if let data = looseFile(named: candidate, in: folder) {
                return makeResource(data: data, path: candidate, record: record)
            }
        }

        if let resolved = try indexedResourceFollowingRedirects(
            exactPath: normalized, record: record
        ) {
            return makeResource(data: resolved.data, path: resolved.path, record: record)
        }

        // Extension-less audio references (OALD: "sound://_apple" while the
        // MDD stores "_apple#_uss_2.mp3"): complete by prefix.
        if !((normalized as NSString).lastPathComponent.contains(".")) {
            if let resolved = try indexedResource(prefix: normalized, record: record) {
                if let target = resourceRedirectTarget(resolved.data),
                   let redirected = try indexedResourceFollowingRedirects(
                       exactPath: MdictFile.normalizeResourcePath(target), record: record
                   ) {
                    return makeResource(data: redirected.data, path: redirected.path, record: record)
                }
                return makeResource(data: resolved.data, path: resolved.path, record: record)
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
            if let data = looseFile(named: baseNameFallback, in: folder) {
                return makeResource(data: data, path: baseNameFallback, record: record)
            }
            if let resolved = try indexedResourceFollowingRedirects(
                exactPath: baseNameFallback, record: record
            ) {
                return makeResource(data: resolved.data, path: resolved.path, record: record)
            }
        }
        return nil
    }

    private func looseFile(named name: String, in folder: URL) -> Data? {
        let fileURL = folder.appendingPathComponent(name)
        // Prevent both `..` traversal and a copied symbolic link from escaping
        // the dictionary folder.
        let resolvedFolder = folder.resolvingSymlinksInPath().standardizedFileURL
        let resolvedFile = fileURL.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedFile.path.hasPrefix(resolvedFolder.path + "/") else {
            return nil
        }
        return try? Data(contentsOf: resolvedFile)
    }

    /// Validates the host component of a per-dictionary `dict://` URL.
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
        let path: String?
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
                part: statement.int(0), offset: statement.int(1), length: statement.int(2),
                path: statement.optionalText(3)
            )
        }
    }

    private struct ResolvedResource {
        let data: Data
        let path: String
    }

    private func indexedResource(exactPath: String, record: DictionaryRecord) throws -> ResolvedResource? {
        let location = try resourceLocation(
            sql: "SELECT part, offset, length, path FROM resources WHERE dict = ? AND path = ? ORDER BY part, rowid LIMIT 1",
            bindings: [.int(record.id), .text(exactPath)]
        )
        guard let location else { return nil }
        guard let data = try readResource(location, uuid: record.uuid) else { return nil }
        return ResolvedResource(data: data, path: exactPath)
    }

    private func indexedResourceFollowingRedirects(
        exactPath: String, record: DictionaryRecord
    ) throws -> ResolvedResource? {
        var path = exactPath
        var visited = Set<String>()
        for _ in 0 ..< 8 {
            guard visited.insert(path).inserted,
                  let resource = try indexedResource(exactPath: path, record: record)
            else { return nil }
            guard let target = resourceRedirectTarget(resource.data) else { return resource }
            path = MdictFile.normalizeResourcePath(target)
        }
        return nil
    }

    private func resourceRedirectTarget(_ data: Data) -> String? {
        let decoded = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16LittleEndian)
        guard let decoded else { return nil }
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("@@@LINK=") else { return nil }
        return String(trimmed.dropFirst("@@@LINK=".count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0\r\n \t"))
    }

    /// First resource whose path starts with `prefix` followed by '#' or '.'
    /// (used to complete extension-less sound references).
    private func indexedResource(prefix: String, record: DictionaryRecord) throws -> ResolvedResource? {
        var escaped = prefix
        for (symbol, replacement) in [("\\", "\\\\"), ("%", "\\%"), ("_", "\\_")] {
            escaped = escaped.replacingOccurrences(of: symbol, with: replacement)
        }
        let location = try resourceLocation(
            sql: """
                SELECT part, offset, length, path FROM resources
                WHERE dict = ? AND (path LIKE ? ESCAPE '\\' OR path LIKE ? ESCAPE '\\')
                ORDER BY part, path, rowid LIMIT 1
                """,
            bindings: [.int(record.id), .text(escaped + "#%"), .text(escaped + ".%")]
        )
        guard let location else { return nil }
        guard let data = try readResource(location, uuid: record.uuid) else { return nil }
        // Prefix completion is used for audio. Keep the requested prefix when
        // SQLite's small location helper does not project the path itself.
        return ResolvedResource(data: data, path: location.path ?? prefix)
    }

    private func makeResource(
        data: Data, path: String, record: DictionaryRecord
    ) -> DictionaryResource {
        let mime = Self.mimeType(forPath: path)
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "css" || ext == "js" || ext == "html" || ext == "htm" || ext == "json" {
            let encoding = (try? openDictionary(uuid: record.uuid).mdx.info.encoding) ?? .utf8
            var text = Self.decodeTextResource(data, dictionaryEncoding: encoding)
            if ext == "css" {
                // The bytes are UTF-8 from this point on. Keeping a legacy
                // @charset declaration would make WebKit reinterpret them.
                text = Self.replacingCSSCharsetWithUTF8(text)
                text = EntryPageBuilder.rewriteCSSReferences(text)
            }
            return DictionaryResource(
                data: Data(text.utf8), mimeType: mime,
                textEncodingName: "utf-8", resolvedPath: path
            )
        }
        return DictionaryResource(
            data: data, mimeType: mime, textEncodingName: nil, resolvedPath: path
        )
    }

    private static func decodeTextResource(
        _ data: Data, dictionaryEncoding: MdictTextEncoding
    ) -> String {
        // Check four-byte BOMs first because UTF-32LE begins with the UTF-16LE
        // prefix. GoldenDict-NG performs the same BOM-first CSS decoding.
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            return String(data: Data(data.dropFirst(4)), encoding: .utf32LittleEndian) ?? ""
        }
        if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return String(data: Data(data.dropFirst(4)), encoding: .utf32BigEndian) ?? ""
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: Data(data.dropFirst(3)), encoding: .utf8) ?? ""
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: Data(data.dropFirst(2)), encoding: .utf16LittleEndian) ?? ""
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: Data(data.dropFirst(2)), encoding: .utf16BigEndian) ?? ""
        }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        return (try? dictionaryEncoding.decode(data))
            ?? String(decoding: data, as: UTF8.self)
    }

    private static func replacingCSSCharsetWithUTF8(_ css: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?i)^(?:\uFEFF)?\s*@charset\s+[\"'][^\"']+[\"']\s*;"#
        ) else { return css }
        let range = NSRange(css.startIndex..., in: css)
        guard regex.firstMatch(in: css, range: range) != nil else { return css }
        return regex.stringByReplacingMatches(
            in: css, range: range, withTemplate: #"@charset "UTF-8";"#
        )
    }

    public static func mimeType(forPath path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        if let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType {
            return mime
        }
        switch ext {
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js": return "text/javascript"
        case "json": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "ogg", "oga": return "audio/ogg"
        case "spx": return "audio/speex"
        case "mp4": return "video/mp4"
        default: return "application/octet-stream"
        }
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
