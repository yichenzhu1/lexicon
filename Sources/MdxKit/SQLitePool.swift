import Foundation

/// Connection pool over one SQLite database file.
///
/// WAL journaling lets a writer and any number of readers proceed at the same
/// time — but only across *separate* connections. Sharing one full-mutex
/// connection instead serializes them, so a bulk import would hold the
/// connection through its transaction and stall every search behind it.
///
/// One writer connection serializes writes among themselves; readers borrow a
/// connection from the pool for the duration of a call.
public final class SQLitePool: @unchecked Sendable {
    private let path: String
    private let writer: SQLiteDB
    private let writeLock = NSLock()

    private let readerLock = NSLock()
    private var idleReaders: [SQLiteDB] = []
    /// Readers beyond this are closed on return rather than kept around; the
    /// app's concurrent readers are the main thread plus the dict:// handler.
    private let maxIdleReaders = 4

    public init(path: String) throws {
        self.path = path
        // Creates the file if needed, so read-only connections can open it.
        writer = try SQLiteDB(path: path)
    }

    /// Runs `body` against the writer connection, serialized against other
    /// writers. Schema changes and transactions belong here.
    public func write<T>(_ body: (SQLiteDB) throws -> T) throws -> T {
        writeLock.lock()
        defer { writeLock.unlock() }
        return try body(writer)
    }

    /// Runs `body` against a borrowed reader connection.
    public func read<T>(_ body: (SQLiteDB) throws -> T) throws -> T {
        let reader = try borrowReader()
        defer { releaseReader(reader) }
        return try body(reader)
    }

    private func borrowReader() throws -> SQLiteDB {
        readerLock.lock()
        if let reader = idleReaders.popLast() {
            readerLock.unlock()
            return reader
        }
        readerLock.unlock()
        return try SQLiteDB(path: path, readOnly: true)
    }

    private func releaseReader(_ reader: SQLiteDB) {
        readerLock.lock()
        if idleReaders.count < maxIdleReaders {
            idleReaders.append(reader)
        }
        readerLock.unlock()
    }
}
