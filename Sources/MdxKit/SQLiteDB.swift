import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin wrapper over the system SQLite, just enough for the keyword index.
public final class SQLiteDB {
    public enum SQLiteError: LocalizedError {
        case open(String)
        case prepare(String, String)
        case step(String)

        public var errorDescription: String? {
            switch self {
            case .open(let m): return "SQLite open failed: \(m)"
            case .prepare(let sql, let m): return "SQLite prepare failed (\(m)): \(sql)"
            case .step(let m): return "SQLite step failed: \(m)"
            }
        }
    }

    private var handle: OpaquePointer?

    public init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw SQLiteError.open(message)
        }
        try exec("PRAGMA journal_mode = WAL")
        try exec("PRAGMA synchronous = NORMAL")
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
        private unowned let db: SQLiteDB

        init(stmt: OpaquePointer, db: SQLiteDB) {
            self.stmt = stmt
            self.db = db
        }

        deinit {
            sqlite3_finalize(stmt)
        }

        public func bind(_ bindings: [Binding]) throws {
            for (i, binding) in bindings.enumerated() {
                let index = Int32(i + 1)
                switch binding {
                case .int(let v): sqlite3_bind_int64(stmt, index, v)
                case .text(let v): sqlite3_bind_text(stmt, index, v, -1, sqliteTransient)
                case .blob(let v):
                    _ = v.withUnsafeBytes {
                        sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(v.count), sqliteTransient)
                    }
                case .null: sqlite3_bind_null(stmt, index)
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
            return String(cString: cString)
        }

        public func optionalText(_ column: Int) -> String? {
            sqlite3_column_type(stmt, Int32(column)) == SQLITE_NULL ? nil : text(column)
        }
    }
}
