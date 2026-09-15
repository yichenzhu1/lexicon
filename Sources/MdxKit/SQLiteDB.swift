import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin wrapper over the system SQLite, just enough for the keyword index.
public final class SQLiteDB {
    private final class ProgressCancellation {
        let isCancelled: @Sendable () -> Bool
        init(_ isCancelled: @escaping @Sendable () -> Bool) { self.isCancelled = isCancelled }
    }
    public enum SQLiteError: LocalizedError {
        case open(String)
        case prepare(String, String)
        case bind(String)
        case step(String)

        public var errorDescription: String? {
            switch self {
            case .open(let m): return "SQLite open failed: \(m)"
            case .prepare(let sql, let m): return "SQLite prepare failed (\(m)): \(sql)"
            case .bind(let m): return "SQLite binding failed: \(m)"
            case .step(let m): return "SQLite step failed: \(m)"
            }
        }
    }

    private var handle: OpaquePointer?

    /// - Parameter readOnly: opens a reader connection. WAL lets readers run
    ///   while a writer holds a transaction, but only across separate
    ///   connections, so `SQLitePool` opens several of these.
    public init(path: String, readOnly: Bool = false) throws {
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw SQLiteError.open(message)
        }
        try exec("PRAGMA busy_timeout = 5000")
        if !readOnly {
            // Journal mode persists in the database file; readers inherit it.
            try exec("PRAGMA journal_mode = WAL")
            try exec("PRAGMA synchronous = NORMAL")
        }
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    private var lastError: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
    }

    public func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.step("\(lastError) — \(sql)")
        }
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Installs a temporary SQLite VM progress callback. Returning nonzero
    /// interrupts a long scan, allowing obsolete incremental searches to stop
    /// consuming CPU instead of merely discarding their eventual result.
    public func withProgressCancellation<T>(
        _ isCancelled: @escaping @Sendable () -> Bool,
        body: () throws -> T
    ) throws -> T {
        let box = ProgressCancellation(isCancelled)
        let opaque = Unmanaged.passUnretained(box).toOpaque()
        sqlite3_progress_handler(handle, 1_000, { context in
            guard let context else { return 0 }
            return Unmanaged<ProgressCancellation>.fromOpaque(context)
                .takeUnretainedValue().isCancelled() ? 1 : 0
        }, opaque)
        defer { sqlite3_progress_handler(handle, 0, nil, nil) }
        return try withExtendedLifetime(box) { try body() }
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    public func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError.prepare(sql, lastError)
        }
        return Statement(stmt: stmt, db: self)
    }

    /// Convenience: prepare, bind, and collect all rows.
    public func query<T>(
        _ sql: String, _ bindings: [Binding] = [], row: (Statement) throws -> T
    ) throws -> [T] {
        let stmt = try prepare(sql)
        try stmt.bind(bindings)
        var results: [T] = []
        while try stmt.step() {
            results.append(try row(stmt))
        }
        return results
    }

    /// Convenience: prepare, bind, and run a statement with no result rows.
    public func run(_ sql: String, _ bindings: [Binding] = []) throws {
        let stmt = try prepare(sql)
        try stmt.bind(bindings)
        _ = try stmt.step()
    }

    public enum Binding {
        case int(Int64)
        case text(String)
        case blob(Data)
        case null
    }

    public final class Statement {
        private let stmt: OpaquePointer
        // A public prepared statement may outlive the caller's connection
        // variable. Keep the database alive through finalization and errors.
        private let db: SQLiteDB

        init(stmt: OpaquePointer, db: SQLiteDB) {
            self.stmt = stmt
            self.db = db
        }

        deinit {
            sqlite3_finalize(stmt)
        }

        public func bind(_ bindings: [Binding]) throws {
            for (i, binding) in bindings.enumerated() {
                guard let index = Int32(exactly: i + 1) else {
                    throw SQLiteError.bind("too many parameters")
                }
                let status: Int32
                switch binding {
                case .int(let v): status = sqlite3_bind_int64(stmt, index, v)
                case .text(let v):
                    status = v.withCString {
                        sqlite3_bind_text64(stmt, index, $0, UInt64(v.utf8.count), sqliteTransient, UInt8(SQLITE_UTF8))
                    }
                case .blob(let v):
                    if v.isEmpty {
                        status = sqlite3_bind_zeroblob(stmt, index, 0)
                    } else {
                        status = v.withUnsafeBytes {
                            sqlite3_bind_blob64(stmt, index, $0.baseAddress, UInt64(v.count), sqliteTransient)
                        }
                    }
                case .null: status = sqlite3_bind_null(stmt, index)
                }
                guard status == SQLITE_OK else {
                    throw SQLiteError.bind(db.lastError)
                }
            }
        }

        /// Returns true while a row is available.
        @discardableResult
        public func step() throws -> Bool {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw SQLiteError.step(db.lastError)
            }
        }

        public func reset() {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }

        public func int(_ column: Int) -> Int64 { sqlite3_column_int64(stmt, Int32(column)) }

        public func text(_ column: Int) -> String {
            guard let cString = sqlite3_column_text(stmt, Int32(column)) else { return "" }
            let bytes = UnsafeBufferPointer(start: cString, count: Int(sqlite3_column_bytes(stmt, Int32(column))))
            return String(decoding: bytes, as: UTF8.self)
        }

        public func optionalText(_ column: Int) -> String? {
            sqlite3_column_type(stmt, Int32(column)) == SQLITE_NULL ? nil : text(column)
        }
    }
}
