import Foundation
import SQLite3

public enum CrashPoint: Sendable {
    case none
    case beforeTransaction
    case duringTransaction
    case afterCommit
}

public enum TransactionPrototypeError: Error { case injected, sqlite(String) }

public final class TransactionalCryptoStore: @unchecked Sendable {
    private var db: OpaquePointer?

    public init(path: String) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw TransactionPrototypeError.sqlite("open") }
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=FULL")
        try exec("PRAGMA foreign_keys=ON")
        try exec("CREATE TABLE IF NOT EXISTS protocol_state (session TEXT PRIMARY KEY, generation INTEGER NOT NULL, opaque_state BLOB NOT NULL)")
        try exec("CREATE TABLE IF NOT EXISTS outbox (message_id TEXT PRIMARY KEY, session TEXT NOT NULL, exact_envelope BLOB NOT NULL, status TEXT NOT NULL)")
        try exec("CREATE TABLE IF NOT EXISTS replay (replay_id TEXT PRIMARY KEY, opaque_message BLOB NOT NULL)")
    }

    deinit { sqlite3_close(db) }

    public func commitSend(
        session: String,
        nextGeneration: Int64,
        opaqueState: Data,
        messageID: String,
        exactEnvelope: Data,
        crashPoint: CrashPoint = .none
    ) throws {
        if crashPoint == .beforeTransaction { throw TransactionPrototypeError.injected }
        try exec("BEGIN IMMEDIATE")
        do {
            try bindAndStep(
                "INSERT INTO protocol_state(session,generation,opaque_state) VALUES(?,?,?) ON CONFLICT(session) DO UPDATE SET generation=excluded.generation, opaque_state=excluded.opaque_state",
                [.text(session), .int(nextGeneration), .blob(opaqueState)]
            )
            if crashPoint == .duringTransaction { throw TransactionPrototypeError.injected }
            try bindAndStep(
                "INSERT INTO outbox(message_id,session,exact_envelope,status) VALUES(?,?,?,'READY')",
                [.text(messageID), .text(session), .blob(exactEnvelope)]
            )
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        if crashPoint == .afterCommit { throw TransactionPrototypeError.injected }
    }

    public func commitReceive(replayID: String, opaqueMessage: Data, crashPoint: CrashPoint = .none) throws -> Bool {
        if crashPoint == .beforeTransaction { throw TransactionPrototypeError.injected }
        try exec("BEGIN IMMEDIATE")
        do {
            if try scalarInt("SELECT COUNT(*) FROM replay WHERE replay_id=?", [.text(replayID)]) > 0 {
                try exec("COMMIT")
                return false
            }
            if crashPoint == .duringTransaction { throw TransactionPrototypeError.injected }
            try bindAndStep("INSERT INTO replay(replay_id,opaque_message) VALUES(?,?)", [.text(replayID), .blob(opaqueMessage)])
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
        if crashPoint == .afterCommit { throw TransactionPrototypeError.injected }
        return true
    }

    public func markSentUnknown(_ messageID: String) throws {
        try bindAndStep("UPDATE outbox SET status='SENT_UNKNOWN' WHERE message_id=?", [.text(messageID)])
    }

    public func acknowledge(_ messageID: String) throws {
        try bindAndStep("UPDATE outbox SET status='ACKED' WHERE message_id=?", [.text(messageID)])
    }

    public func generation(session: String) throws -> Int64 {
        try scalarInt("SELECT COALESCE(MAX(generation),0) FROM protocol_state WHERE session=?", [.text(session)])
    }

    public func outboxEnvelope(messageID: String) throws -> Data? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT exact_envelope FROM outbox WHERE message_id=?", -1, &statement, nil) == SQLITE_OK else { throw TransactionPrototypeError.sqlite("prepare") }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, messageID, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard let bytes = sqlite3_column_blob(statement, 0) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    public func status(messageID: String) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT status FROM outbox WHERE message_id=?", -1, &statement, nil) == SQLITE_OK else { throw TransactionPrototypeError.sqlite("prepare") }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, messageID, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }

    private enum Value { case text(String), int(Int64), blob(Data) }

    private func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw TransactionPrototypeError.sqlite(message)
        }
    }

    private func bindAndStep(_ sql: String, _ values: [Value]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw TransactionPrototypeError.sqlite("prepare") }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw TransactionPrototypeError.sqlite(String(cString: sqlite3_errmsg(db))) }
    }

    private func scalarInt(_ sql: String, _ values: [Value]) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw TransactionPrototypeError.sqlite("prepare") }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw TransactionPrototypeError.sqlite("row") }
        return sqlite3_column_int64(statement, 0)
    }

    private func bind(_ values: [Value], to statement: OpaquePointer?) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let .text(text): sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
            case let .int(number): sqlite3_bind_int64(statement, index, number)
            case let .blob(data):
                _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) }
            }
            guard sqlite3_errcode(db) == SQLITE_OK else { throw TransactionPrototypeError.sqlite("bind") }
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
