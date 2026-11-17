import XCTest
import SQLite3
@testable import IWordStorage

final class SQLiteStoreTests: XCTestCase {
    func testBackupCapturesWALAndRestoreReplacesWholeState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStore(url: root.appendingPathComponent("live.sqlite"))
        try store.commit(operationID: "before", changes: [StoreChange(.wordState, key: "original", value: 1)], events: [JournalEvent(kind: "BEFORE")])
        let snapshot = root.appendingPathComponent("snapshot.sqlite")
        try store.backup(to: snapshot)
        let readonly = try SQLiteStore(url: snapshot, readOnly: true)
        XCTAssertEqual(try readonly.records(.wordState, as: Int.self), [1])
        XCTAssertEqual(try readonly.events().map(\.kind), ["BEFORE"])
        try store.commit(operationID: "after", changes: [StoreChange(.wordState, key: "new", value: 2), StoreChange(.budget, key: "day", value: 3)], events: [JournalEvent(kind: "AFTER")])
        try store.restore(from: snapshot)
        XCTAssertEqual(try store.records(.wordState, as: Int.self), [1])
        XCTAssertEqual(try store.records(.budget, as: Int.self), [])
        XCTAssertEqual(try store.events().map(\.kind), ["BEFORE"])
        XCTAssertFalse(try store.commit(operationID: "before", changes: [], events: []))
    }
    func testCorruptAndNewerSnapshotsNeverReplaceLiveStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SQLiteStore(url: root.appendingPathComponent("live.sqlite"))
        try store.commit(operationID: "safe", changes: [StoreChange(.wordState, key: "sentinel", value: 42)], events: [])
        let bad = root.appendingPathComponent("bad.sqlite")
        try Data("not sqlite".utf8).write(to: bad)
        XCTAssertThrowsError(try store.restore(from: bad))
        let newer = root.appendingPathComponent("newer.sqlite")
        try store.backup(to: newer)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(newer.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA user_version=2", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        XCTAssertThrowsError(try store.restore(from: newer))
        XCTAssertEqual(try store.records(.wordState, as: Int.self), [42])
    }
    func testAtomicRollbackAndIdempotentRetrySurviveReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("study.sqlite")
        var store: SQLiteStore? = try SQLiteStore(url: url)
        let event = JournalEvent(kind: "rate", operationID: "first")
        XCTAssertTrue(try store!.commit(operationID: "first", changes: [StoreChange(.wordState, key: "word", value: 1)], events: [event]))
        XCTAssertFalse(try store!.commit(operationID: "first", changes: [StoreChange(.wordState, key: "word", value: 99)], events: [event]))
        // Duplicate event forces a failure after the state row has been changed; neither may commit.
        XCTAssertThrowsError(try store!.commit(operationID: "second", changes: [StoreChange(.wordState, key: "word", value: 2)], events: [event]))
        XCTAssertEqual(try store!.records(.wordState, as: Int.self), [1])
        store = nil
        store = try SQLiteStore(url: url)
        XCTAssertEqual(try store!.records(.wordState, as: Int.self), [1])
        XCTAssertEqual(try store!.events().count, 1)
        XCTAssertTrue(try store!.commit(operationID: "second", changes: [StoreChange(.wordState, key: "word", value: 2)], events: [JournalEvent(kind: "retry")]))
        XCTAssertEqual(try store!.records(.wordState, as: Int.self), [2])
    }
}
