import Foundation
import SQLite3

public enum StoreTable: String, CaseIterable {
    case profile = "iw_profile", content = "iw_content", wordState = "iw_word_state"
    case session = "iw_session", budget = "iw_budget"
}

public struct StoreChange {
    public let table: StoreTable
    public let key: String
    public let payload: Data
    public init<T: Encodable>(_ table: StoreTable, key: String, value: T) throws {
        self.table = table; self.key = key; self.payload = try JSONEncoder().encode(value)
    }
}

public struct JournalEvent: Codable, Identifiable {
    public var id: String
    public var operationID: String
    public var occurredAt: Date
    public var kind: String
    public var fields: [String: String]
    public init(kind: String, fields: [String: String] = [:], operationID: String = UUID().uuidString, occurredAt: Date = Date()) {
        self.id = UUID().uuidString; self.operationID = operationID
        self.occurredAt = occurredAt; self.kind = kind; self.fields = fields
    }
}

public struct StorageError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// One serial connection. A learning command and all its events share one durable transaction.
public final class SQLiteStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let databaseURL: URL
    private let readOnly: Bool

    /// A read-only store never creates or migrates a database. It is intended for validating an imported snapshot.
    public init(url: URL, readOnly: Bool = false) throws {
        self.databaseURL = url
        self.readOnly = readOnly
        if !readOnly {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            sqlite3_close(db); db = nil; throw StorageError(message: message)
        }
        do {
            sqlite3_busy_timeout(db, 5000)
            if readOnly {
                try validateSupportedSchema()
            } else {
                try execute("PRAGMA journal_mode=WAL")
                try execute("PRAGMA synchronous=FULL")
                let version = try integer("PRAGMA user_version")
                guard version <= 1 else { throw StorageError(message: "数据来自较新的 App，请先升级，不要覆盖档案。") }
                if version == 0 {
                    try execute("BEGIN IMMEDIATE")
                    do {
                        for table in StoreTable.allCases {
                            try execute("CREATE TABLE \(table.rawValue) (record_key TEXT PRIMARY KEY, payload BLOB NOT NULL)")
                        }
                        try execute("CREATE TABLE iw_operation (operation_id TEXT PRIMARY KEY)")
                        try execute("CREATE TABLE iw_event (sequence INTEGER PRIMARY KEY AUTOINCREMENT, event_id TEXT NOT NULL UNIQUE, occurred_at REAL NOT NULL, payload BLOB NOT NULL)")
                        try execute("PRAGMA user_version=1")
                        try execute("COMMIT")
                    } catch { try? execute("ROLLBACK"); throw error }
                }
                try validateSupportedSchema()
            }
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }

    public func records<T: Decodable>(_ table: StoreTable, as type: T.Type) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        return try readData("SELECT payload FROM \(table.rawValue) ORDER BY record_key").map { try JSONDecoder().decode(type, from: $0) }
    }
    public func events() throws -> [JournalEvent] {
        lock.lock(); defer { lock.unlock() }
        return try readData("SELECT payload FROM iw_event ORDER BY sequence").map { try JSONDecoder().decode(JournalEvent.self, from: $0) }
    }

    /// Copies a consistent SQLite/WAL snapshot without replacing the live database file.
    public func backup(to url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        guard url.standardizedFileURL != databaseURL.standardizedFileURL else {
            throw StorageError(message: "备份目标不能是正在使用的数据库。")
        }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw StorageError(message: "备份目标已存在，拒绝覆盖。")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let destination = try openWritableDatabase(at: url)
            do {
                try copyDatabase(from: db, to: destination)
                try makeStandaloneSnapshot(destination)
                sqlite3_close(destination)
            } catch {
                sqlite3_close(destination)
                throw error
            }
            // Re-open without migration: a backup must itself be a complete supported database.
            _ = try SQLiteStore(url: url, readOnly: true)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Validates the source before touching the current store, then restores via SQLite's backup API.
    /// A private rollback snapshot protects the current connection if copying the source fails midway.
    public func restore(from url: URL) throws {
        guard !readOnly else { throw StorageError(message: "只读数据库不能恢复档案。") }
        guard url.standardizedFileURL != databaseURL.standardizedFileURL else {
            throw StorageError(message: "不能从当前数据库恢复。")
        }
        let source = try SQLiteStore(url: url, readOnly: true)
        lock.lock(); defer { lock.unlock() }
        let rollbackURL = databaseURL.deletingLastPathComponent().appendingPathComponent(".restore-rollback-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: rollbackURL) }
        do {
            let rollback = try openWritableDatabase(at: rollbackURL)
            do {
                try copyDatabase(from: db, to: rollback)
                try makeStandaloneSnapshot(rollback)
                sqlite3_close(rollback)
            } catch {
                sqlite3_close(rollback)
                throw error
            }
            do {
                try copyDatabase(from: source.db, to: db)
                try validateSupportedSchema()
            } catch {
                // sqlite3_backup updates the destination transactionally; retaining this explicit snapshot
                // also protects us from future SQLite behavior changes or an interrupted copy.
                let rollbackSource = try SQLiteStore(url: rollbackURL, readOnly: true)
                try copyDatabase(from: rollbackSource.db, to: db)
                throw error
            }
        } catch {
            throw error
        }
    }

    /// Returns false for an already committed operation; retries must reuse the operation ID.
    @discardableResult public func commit(operationID: String, changes: [StoreChange], events: [JournalEvent]) throws -> Bool {
        guard !readOnly else { throw StorageError(message: "只读数据库不能写入。") }
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            let operation = try prepare("INSERT OR IGNORE INTO iw_operation(operation_id) VALUES (?)")
            sqlite3_bind_text(operation, 1, operationID, -1, transient)
            do { try step(operation) } catch { sqlite3_finalize(operation); throw error }
            sqlite3_finalize(operation)
            if sqlite3_changes(db) == 0 { try execute("ROLLBACK"); return false }
            for change in changes {
                let statement = try prepare("INSERT INTO \(change.table.rawValue)(record_key,payload) VALUES (?,?) ON CONFLICT(record_key) DO UPDATE SET payload=excluded.payload")
                sqlite3_bind_text(statement, 1, change.key, -1, transient)
                bind(change.payload, to: statement, index: 2)
                do { try step(statement) } catch { sqlite3_finalize(statement); throw error }
                sqlite3_finalize(statement)
            }
            for event in events {
                let statement = try prepare("INSERT INTO iw_event(event_id,occurred_at,payload) VALUES (?,?,?)")
                sqlite3_bind_text(statement, 1, event.id, -1, transient)
                sqlite3_bind_double(statement, 2, event.occurredAt.timeIntervalSince1970)
                do {
                    bind(try JSONEncoder().encode(event), to: statement, index: 3)
                    try step(statement)
                } catch { sqlite3_finalize(statement); throw error }
                sqlite3_finalize(statement)
            }
            try execute("COMMIT"); return true
        } catch { try? execute("ROLLBACK"); throw error }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func integer(_ sql: String) throws -> Int {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int(statement, 0))
    }
    private func text(_ sql: String) throws -> String {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { throw failure() }
        return String(cString: value)
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        return statement
    }
    private func step(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    private func bind(_ data: Data, to statement: OpaquePointer, index: Int32) {
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transient) }
    }
    private func readData(_ sql: String) throws -> [Data] {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        var result: [Data] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW, let pointer = sqlite3_column_blob(statement, 0) else { throw failure() }
            result.append(Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, 0))))
        }
    }
    private func validateSupportedSchema() throws {
        let version = try integer("PRAGMA user_version")
        guard version == 1 else {
            throw StorageError(message: version > 1 ? "数据来自较新的 App，请先升级，不要覆盖档案。" : "档案数据库版本不受支持。")
        }
        guard try text("PRAGMA quick_check") == "ok" else { throw StorageError(message: "档案数据库完整性校验失败。") }
        guard try integer("SELECT count(*) FROM sqlite_master WHERE type IN ('trigger','view')") == 0 else {
            throw StorageError(message: "档案含有不受支持的数据库对象。")
        }
        let expected = Set(StoreTable.allCases.map(\.rawValue) + ["iw_operation", "iw_event"])
        let statement = try prepare("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
        defer { sqlite3_finalize(statement) }
        var tables: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 0) else { throw failure() }
            tables.insert(String(cString: name))
        }
        guard tables == expected else { throw StorageError(message: "档案数据库表结构不受支持。") }
        for table in StoreTable.allCases {
            try validateColumns(table.rawValue, expected: ["record_key", "payload"])
        }
        try validateColumns("iw_operation", expected: ["operation_id"])
        try validateColumns("iw_event", expected: ["sequence", "event_id", "occurred_at", "payload"])
    }
    private func validateColumns(_ table: String, expected: [String]) throws {
        let statement = try prepare("PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(statement) }
        var columns: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 1) else { throw failure() }
            columns.append(String(cString: name))
        }
        guard columns == expected else { throw StorageError(message: "档案数据库字段结构不受支持。") }
    }
    /// The copied header inherits WAL mode. Convert the detached copy to a single-file journal
    /// before read-only validation or archiving, so it never depends on transient WAL/SHM files.
    private func makeStandaloneSnapshot(_ connection: OpaquePointer) throws {
        guard sqlite3_exec(connection, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else {
            throw StorageError(message: String(cString: sqlite3_errmsg(connection)))
        }
    }
    private func openWritableDatabase(at url: URL) throws -> OpaquePointer {
        var destination: OpaquePointer?
        guard sqlite3_open_v2(url.path, &destination, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let destination else {
            let message = destination.map { String(cString: sqlite3_errmsg($0)) } ?? "无法创建备份数据库"
            sqlite3_close(destination)
            throw StorageError(message: message)
        }
        sqlite3_busy_timeout(destination, 5000)
        return destination
    }
    /// SQLite's online-backup API is the only copy mechanism used for live connections and WAL snapshots.
    private func copyDatabase(from source: OpaquePointer?, to destination: OpaquePointer?) throws {
        guard let source, let destination, let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw StorageError(message: destination.map { String(cString: sqlite3_errmsg($0)) } ?? "无法初始化数据库复制")
        }
        var code: Int32 = SQLITE_OK
        var retries = 0
        repeat {
            code = sqlite3_backup_step(backup, 128)
            if code == SQLITE_BUSY || code == SQLITE_LOCKED {
                retries += 1
                sqlite3_sleep(20)
            }
        } while (code == SQLITE_OK || code == SQLITE_BUSY || code == SQLITE_LOCKED) && retries < 100
        let finishCode = sqlite3_backup_finish(backup)
        guard code == SQLITE_DONE, finishCode == SQLITE_OK else {
            throw StorageError(message: String(cString: sqlite3_errmsg(destination)))
        }
    }
    private func failure() -> StorageError { StorageError(message: String(cString: sqlite3_errmsg(db))) }
}
