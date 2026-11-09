import Foundation
import SQLite3

public protocol TransactionalBlobStore: AnyObject {
    func read(_ key: String) throws -> Data?
    func transaction(_ updates: [String: Data?]) throws
}

public enum DurableAtomicStoreError: Error, CustomStringConvertible {
    case sqlite(operation: String, code: Int32, message: String)
    case transactionClosed
    case duplicateReplay
    case malformedState(String)
    case durabilityUncertain(String)

    public var description: String {
        switch self {
        case let .sqlite(operation, code, message):
            return "SQLite \(operation) failed (\(code)): \(message)"
        case .transactionClosed:
            return "atomic crypto transaction is already closed"
        case .duplicateReplay:
            return "duplicate replay identity"
        case let .malformedState(message):
            return "malformed durable crypto state: \(message)"
        case let .durabilityUncertain(message):
            return "durability is uncertain: \(message)"
        }
    }
}

public enum OutboxDeliveryStatus: String, Codable, Sendable {
    case ready = "READY"
    case sentUnknown = "SENT_UNKNOWN"
    case acknowledged = "ACKNOWLEDGED"
}

public struct DurableOutboxRecord: Equatable, Sendable {
    public let messageID: String
    public let recipientDeviceID: UInt32
    public let ciphertext: Data
    public let envelope: Data
    public let retryCount: Int
    public let deliveryAttemptCount: Int
    public let status: OutboxDeliveryStatus
    public let protocolVersion: String
    public let acknowledged: Bool
}

public struct DurableInboxRecord: Equatable, Sendable {
    public let messageID: String
    public let senderDeviceID: UInt32
    public let ciphertext: Data
    public let plaintext: Data
    public let acknowledgementEligible: Bool
}

/// A committed-only transport value. Raw ciphertext cannot be sent through the
/// OneWay atomic transport API; only this value, constructed after COMMIT, is accepted.
public struct CommittedOutboundEnvelope: Equatable, Sendable {
    public let messageID: String
    public let recipientDeviceID: UInt32
    public let ciphertext: Data
    public let envelope: Data
    public let protocolVersion: String

    init(record: DurableOutboxRecord) {
        messageID = record.messageID
        recipientDeviceID = record.recipientDeviceID
        ciphertext = record.ciphertext
        envelope = record.envelope
        protocolVersion = record.protocolVersion
    }
}

public protocol CommittedCryptoTransport {
    func send(_ committed: CommittedOutboundEnvelope) throws
}

public protocol AtomicBlobTransaction: AnyObject {
    var transactionID: String { get }
    func read(_ key: String) throws -> Data?
    func write(_ updates: [String: Data?]) throws
    func outbox(messageID: String) throws -> DurableOutboxRecord?
    func insertOutbox(
        messageID: String,
        recipientDeviceID: UInt32,
        ciphertext: Data,
        envelope: Data,
        protocolVersion: String
    ) throws
    func insertReplay(messageID: String, senderDeviceID: UInt32) throws
    func replayExists(messageID: String, senderDeviceID: UInt32) throws -> Bool
    func insertInbox(
        messageID: String,
        senderDeviceID: UInt32,
        ciphertext: Data,
        plaintext: Data,
        acknowledgementEligible: Bool
    ) throws
    func insertDeviceDelivery(messageID: String, recipientDeviceID: UInt32) throws
    func markDeliveryAttempt(messageID: String, recipientDeviceID: UInt32) throws
    func acknowledge(messageID: String, recipientDeviceID: UInt32) throws
    func audit(messageID: String?, transition: String, crashMarker: String?) throws
    func commit() throws
    func rollback()
}

public protocol AtomicTransactionalBlobStore: TransactionalBlobStore {
    func beginAtomicCryptoTransaction() throws -> AtomicBlobTransaction
}

/// Production-equivalent candidate storage for libsignal session state, exact
/// ciphertext/outbox state, replay markers, inbox commits, acknowledgements, and
/// per-device delivery state. One SQLite connection and BEGIN IMMEDIATE provide
/// the single durable commit boundary.
public final class SQLiteAtomicCryptoStore: AtomicTransactionalBlobStore, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var db: OpaquePointer?
    private var failCommitForTesting = false
    public let databaseURL: URL

    public init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            let code = db.map(sqlite3_errcode) ?? SQLITE_CANTOPEN
            if let db { sqlite3_close_v2(db) }
            db = nil
            throw DurableAtomicStoreError.sqlite(operation: "open", code: code, message: message)
        }
        sqlite3_extended_result_codes(db, 1)

        do {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA secure_delete=ON")
            try execute("PRAGMA temp_store=MEMORY")
            try execute("PRAGMA busy_timeout=5000")
            try execute("PRAGMA wal_autocheckpoint=1000")
            try execute("""
                CREATE TABLE IF NOT EXISTS protocol_state (
                    key TEXT PRIMARY KEY NOT NULL,
                    value BLOB NOT NULL
                )
                """)
            try execute("""
                CREATE TABLE IF NOT EXISTS outbox (
                    message_id TEXT PRIMARY KEY NOT NULL,
                    recipient_device_id INTEGER NOT NULL,
                    ciphertext BLOB NOT NULL,
                    envelope BLOB NOT NULL,
                    retry_count INTEGER NOT NULL DEFAULT 0,
                    delivery_attempt_count INTEGER NOT NULL DEFAULT 0,
                    status TEXT NOT NULL CHECK(status IN ('READY','SENT_UNKNOWN','ACKNOWLEDGED')),
                    protocol_version TEXT NOT NULL,
                    acknowledged INTEGER NOT NULL DEFAULT 0 CHECK(acknowledged IN (0,1)),
                    created_at_ms INTEGER NOT NULL
                )
                """)
            try execute("""
                CREATE TABLE IF NOT EXISTS device_delivery (
                    message_id TEXT NOT NULL,
                    recipient_device_id INTEGER NOT NULL,
                    status TEXT NOT NULL CHECK(status IN ('READY','SENT_UNKNOWN','ACKNOWLEDGED')),
                    attempt_count INTEGER NOT NULL DEFAULT 0,
                    acknowledged INTEGER NOT NULL DEFAULT 0 CHECK(acknowledged IN (0,1)),
                    PRIMARY KEY(message_id, recipient_device_id),
                    FOREIGN KEY(message_id) REFERENCES outbox(message_id) ON DELETE CASCADE
                )
                """)
            try execute("""
                CREATE TABLE IF NOT EXISTS replay (
                    message_id TEXT NOT NULL,
                    sender_device_id INTEGER NOT NULL,
                    committed_at_ms INTEGER NOT NULL,
                    PRIMARY KEY(message_id, sender_device_id)
                )
                """)
            try execute("""
                CREATE TABLE IF NOT EXISTS inbox (
                    message_id TEXT NOT NULL,
                    sender_device_id INTEGER NOT NULL,
                    ciphertext BLOB NOT NULL,
                    plaintext BLOB NOT NULL,
                    acknowledgement_eligible INTEGER NOT NULL CHECK(acknowledgement_eligible IN (0,1)),
                    committed_at_ms INTEGER NOT NULL,
                    PRIMARY KEY(message_id, sender_device_id),
                    FOREIGN KEY(message_id, sender_device_id)
                        REFERENCES replay(message_id, sender_device_id) ON DELETE RESTRICT
                        DEFERRABLE INITIALLY DEFERRED
                )
                """)
            try execute("""
                CREATE TABLE IF NOT EXISTS transaction_audit (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    transaction_id TEXT NOT NULL,
                    message_id TEXT,
                    transition TEXT NOT NULL,
                    crash_marker TEXT,
                    commit_result TEXT,
                    created_at_ms INTEGER NOT NULL
                )
                """)
        } catch {
            if let db { sqlite3_close_v2(db) }
            db = nil
            throw error
        }

        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: databaseURL.path
        )
#if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: databaseURL.path
        )
#endif
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    /// Test cleanup hook. Production owns this store for the process lifetime.
    func closeForTesting() {
        lock.lock()
        defer { lock.unlock() }
        if let db {
            sqlite3_close_v2(db)
            self.db = nil
        }
    }

    func injectCommitFailureForTesting(_ enabled: Bool) {
        lock.lock()
        failCommitForTesting = enabled
        lock.unlock()
    }

    func limitPageCountForTesting(_ count: Int64) throws {
        lock.lock()
        defer { lock.unlock() }
        try execute("PRAGMA max_page_count=\(count)")
    }

    func pageCountForTesting() throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return try scalarInt("PRAGMA page_count", [])
    }

    public static func defaultDatabaseURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("OneWay", isDirectory: true)
            .appendingPathComponent("Crypto", isDirectory: true)
            .appendingPathComponent("libsignal-atomic.sqlite3", isDirectory: false)
    }

    public func read(_ key: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return try readBlob(key)
    }

    public func transaction(_ updates: [String: Data?]) throws {
        let tx = try beginAtomicCryptoTransaction()
        do {
            try tx.write(updates)
            try tx.commit()
        } catch {
            tx.rollback()
            throw error
        }
    }

    public func beginAtomicCryptoTransaction() throws -> AtomicBlobTransaction {
        lock.lock()
        do {
            try execute("BEGIN IMMEDIATE")
            return Transaction(store: self)
        } catch {
            lock.unlock()
            throw error
        }
    }

    public func outbox(messageID: String) throws -> DurableOutboxRecord? {
        lock.lock()
        defer { lock.unlock() }
        return try fetchOutbox(messageID: messageID)
    }

    public func inbox(messageID: String, senderDeviceID: UInt32) throws -> DurableInboxRecord? {
        lock.lock()
        defer { lock.unlock() }
        return try fetchInbox(messageID: messageID, senderDeviceID: senderDeviceID)
    }

    public func replayExists(messageID: String, senderDeviceID: UInt32) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return try scalarInt(
            "SELECT COUNT(*) FROM replay WHERE message_id=? AND sender_device_id=?",
            [.text(messageID), .int(Int64(senderDeviceID))]
        ) > 0
    }

    public func integrityCheck() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        return try scalarText("PRAGMA integrity_check", []) ?? "missing"
    }

    public func journalMode() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        return try scalarText("PRAGMA journal_mode", []) ?? "unknown"
    }

    public func synchronousMode() throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return try scalarInt("PRAGMA synchronous", [])
    }

    public func checkpoint() throws {
        lock.lock()
        defer { lock.unlock() }
        var logFrames: Int32 = 0
        var checkpointedFrames: Int32 = 0
        let result = sqlite3_wal_checkpoint_v2(
            db, nil, SQLITE_CHECKPOINT_FULL, &logFrames, &checkpointedFrames
        )
        guard result == SQLITE_OK else { throw sqliteError("wal_checkpoint", code: result) }
    }

    fileprivate final class Transaction: AtomicBlobTransaction {
        let transactionID = UUID().uuidString
        private weak var store: SQLiteAtomicCryptoStore?
        private var closed = false

        init(store: SQLiteAtomicCryptoStore) {
            self.store = store
        }

        deinit {
            if !closed { rollback() }
        }

        func read(_ key: String) throws -> Data? {
            try requireStore().readBlob(key)
        }

        func write(_ updates: [String: Data?]) throws {
            let store = try requireStore()
            for (key, value) in updates {
                if let value {
                    try store.run(
                        "INSERT INTO protocol_state(key,value) VALUES(?,?) " +
                        "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                        [.text(key), .blob(value)]
                    )
                } else {
                    try store.run("DELETE FROM protocol_state WHERE key=?", [.text(key)])
                }
            }
        }

        func outbox(messageID: String) throws -> DurableOutboxRecord? {
            try requireStore().fetchOutbox(messageID: messageID)
        }

        func insertOutbox(
            messageID: String,
            recipientDeviceID: UInt32,
            ciphertext: Data,
            envelope: Data,
            protocolVersion: String
        ) throws {
            try requireStore().run(
                """
                INSERT INTO outbox(
                    message_id,recipient_device_id,ciphertext,envelope,retry_count,
                    delivery_attempt_count,status,protocol_version,acknowledged,created_at_ms
                ) VALUES(?,?,?,?,0,0,'READY',?,0,?)
                """,
                [
                    .text(messageID), .int(Int64(recipientDeviceID)), .blob(ciphertext),
                    .blob(envelope), .text(protocolVersion), .int(Self.nowMilliseconds()),
                ]
            )
        }

        func insertReplay(messageID: String, senderDeviceID: UInt32) throws {
            do {
                try requireStore().run(
                    "INSERT INTO replay(message_id,sender_device_id,committed_at_ms) VALUES(?,?,?)",
                    [.text(messageID), .int(Int64(senderDeviceID)), .int(Self.nowMilliseconds())]
                )
            } catch let error as DurableAtomicStoreError {
                if case let .sqlite(_, code, _) = error,
                   code == SQLITE_CONSTRAINT || (code & 0xff) == SQLITE_CONSTRAINT {
                    throw DurableAtomicStoreError.duplicateReplay
                }
                throw error
            }
        }

        func replayExists(messageID: String, senderDeviceID: UInt32) throws -> Bool {
            try requireStore().scalarInt(
                "SELECT COUNT(*) FROM replay WHERE message_id=? AND sender_device_id=?",
                [.text(messageID), .int(Int64(senderDeviceID))]
            ) > 0
        }

        func insertInbox(
            messageID: String,
            senderDeviceID: UInt32,
            ciphertext: Data,
            plaintext: Data,
            acknowledgementEligible: Bool
        ) throws {
            try requireStore().run(
                """
                INSERT INTO inbox(
                    message_id,sender_device_id,ciphertext,plaintext,
                    acknowledgement_eligible,committed_at_ms
                ) VALUES(?,?,?,?,?,?)
                """,
                [
                    .text(messageID), .int(Int64(senderDeviceID)), .blob(ciphertext),
                    .blob(plaintext), .int(acknowledgementEligible ? 1 : 0),
                    .int(Self.nowMilliseconds()),
                ]
            )
        }

        func insertDeviceDelivery(messageID: String, recipientDeviceID: UInt32) throws {
            try requireStore().run(
                """
                INSERT INTO device_delivery(
                    message_id,recipient_device_id,status,attempt_count,acknowledged
                ) VALUES(?,?,'READY',0,0)
                """,
                [.text(messageID), .int(Int64(recipientDeviceID))]
            )
        }

        func markDeliveryAttempt(messageID: String, recipientDeviceID: UInt32) throws {
            let store = try requireStore()
            try store.run(
                """
                UPDATE outbox SET delivery_attempt_count=delivery_attempt_count+1,
                    retry_count=retry_count+1,status='SENT_UNKNOWN'
                WHERE message_id=?
                """,
                [.text(messageID)]
            )
            guard sqlite3_changes(store.db) == 1 else {
                throw DurableAtomicStoreError.malformedState("missing outbox during delivery attempt")
            }
            try store.run(
                """
                UPDATE device_delivery SET attempt_count=attempt_count+1,status='SENT_UNKNOWN'
                WHERE message_id=? AND recipient_device_id=?
                """,
                [.text(messageID), .int(Int64(recipientDeviceID))]
            )
        }

        func acknowledge(messageID: String, recipientDeviceID: UInt32) throws {
            let store = try requireStore()
            try store.run(
                "UPDATE outbox SET status='ACKNOWLEDGED',acknowledged=1 WHERE message_id=?",
                [.text(messageID)]
            )
            guard sqlite3_changes(store.db) == 1 else {
                throw DurableAtomicStoreError.malformedState("missing outbox during acknowledgement")
            }
            try store.run(
                """
                UPDATE device_delivery SET status='ACKNOWLEDGED',acknowledged=1
                WHERE message_id=? AND recipient_device_id=?
                """,
                [.text(messageID), .int(Int64(recipientDeviceID))]
            )
        }

        func audit(messageID: String?, transition: String, crashMarker: String?) throws {
            try requireStore().run(
                """
                INSERT INTO transaction_audit(
                    transaction_id,message_id,transition,crash_marker,commit_result,created_at_ms
                ) VALUES(?,?,?,?,NULL,?)
                """,
                [
                    .text(transactionID), messageID.map(Value.text) ?? .null,
                    .text(transition), crashMarker.map(Value.text) ?? .null,
                    .int(Self.nowMilliseconds()),
                ]
            )
        }

        func commit() throws {
            let store = try requireStore()
            if store.failCommitForTesting {
                throw DurableAtomicStoreError.sqlite(
                    operation: "injected pre-commit sync failure",
                    code: SQLITE_IOERR,
                    message: "test-only durable-write failure"
                )
            }
            do {
                try store.execute("COMMIT")
                closed = true
                store.lock.unlock()
            } catch {
                // SQLite may have committed even when the caller cannot determine the
                // result. Fail closed and force recovery to inspect durable state.
                try? store.execute("ROLLBACK")
                closed = true
                store.lock.unlock()
                throw DurableAtomicStoreError.durabilityUncertain(String(describing: error))
            }
        }

        func rollback() {
            guard !closed, let store else { return }
            try? store.execute("ROLLBACK")
            closed = true
            store.lock.unlock()
        }

        private func requireStore() throws -> SQLiteAtomicCryptoStore {
            guard !closed, let store else { throw DurableAtomicStoreError.transactionClosed }
            return store
        }

        private static func nowMilliseconds() -> Int64 {
            Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        }
    }

    fileprivate enum Value {
        case text(String)
        case int(Int64)
        case blob(Data)
        case null
    }

    fileprivate func readBlob(_ key: String) throws -> Data? {
        var statement: OpaquePointer?
        try prepare("SELECT value FROM protocol_state WHERE key=?", into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind([.text(key)], to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw sqliteError("read protocol state", code: result) }
        return columnData(statement, index: 0)
    }

    fileprivate func fetchOutbox(messageID: String) throws -> DurableOutboxRecord? {
        var statement: OpaquePointer?
        try prepare(
            """
            SELECT message_id,recipient_device_id,ciphertext,envelope,retry_count,
                   delivery_attempt_count,status,protocol_version,acknowledged
            FROM outbox WHERE message_id=?
            """,
            into: &statement
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(messageID)], to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw sqliteError("read outbox", code: result) }
        guard
            let id = columnText(statement, index: 0),
            let ciphertext = columnData(statement, index: 2),
            let envelope = columnData(statement, index: 3),
            let statusText = columnText(statement, index: 6),
            let status = OutboxDeliveryStatus(rawValue: statusText),
            let version = columnText(statement, index: 7)
        else { throw DurableAtomicStoreError.malformedState("outbox row") }
        return DurableOutboxRecord(
            messageID: id,
            recipientDeviceID: UInt32(sqlite3_column_int64(statement, 1)),
            ciphertext: ciphertext,
            envelope: envelope,
            retryCount: Int(sqlite3_column_int64(statement, 4)),
            deliveryAttemptCount: Int(sqlite3_column_int64(statement, 5)),
            status: status,
            protocolVersion: version,
            acknowledged: sqlite3_column_int64(statement, 8) == 1
        )
    }

    fileprivate func fetchInbox(messageID: String, senderDeviceID: UInt32) throws -> DurableInboxRecord? {
        var statement: OpaquePointer?
        try prepare(
            """
            SELECT message_id,sender_device_id,ciphertext,plaintext,acknowledgement_eligible
            FROM inbox WHERE message_id=? AND sender_device_id=?
            """,
            into: &statement
        )
        defer { sqlite3_finalize(statement) }
        try bind([.text(messageID), .int(Int64(senderDeviceID))], to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw sqliteError("read inbox", code: result) }
        guard
            let id = columnText(statement, index: 0),
            let ciphertext = columnData(statement, index: 2),
            let plaintext = columnData(statement, index: 3)
        else { throw DurableAtomicStoreError.malformedState("inbox row") }
        return DurableInboxRecord(
            messageID: id,
            senderDeviceID: UInt32(sqlite3_column_int64(statement, 1)),
            ciphertext: ciphertext,
            plaintext: plaintext,
            acknowledgementEligible: sqlite3_column_int64(statement, 4) == 1
        )
    }

    fileprivate func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? currentErrorMessage
            sqlite3_free(error)
            throw DurableAtomicStoreError.sqlite(operation: sql, code: result, message: message)
        }
    }

    fileprivate func run(_ sql: String, _ values: [Value]) throws {
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw sqliteError("step", code: result) }
    }

    fileprivate func scalarInt(_ sql: String, _ values: [Value]) throws -> Int64 {
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else { throw sqliteError("scalar int", code: result) }
        return sqlite3_column_int64(statement, 0)
    }

    fileprivate func scalarText(_ sql: String, _ values: [Value]) throws -> String? {
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else { throw sqliteError("scalar text", code: result) }
        return columnText(statement, index: 0)
    }

    private func prepare(_ sql: String, into statement: inout OpaquePointer?) throws {
        let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard result == SQLITE_OK else { throw sqliteError("prepare", code: result) }
    }

    private func bind(_ values: [Value], to statement: OpaquePointer?) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case let .text(text):
                result = sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
            case let .int(number):
                result = sqlite3_bind_int64(statement, index, number)
            case let .blob(data):
                result = data.withUnsafeBytes {
                    sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT)
                }
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw sqliteError("bind", code: result) }
        }
    }

    private func columnText(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private func columnData(_ statement: OpaquePointer?, index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0 else { return Data() }
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: count)
    }

    private var currentErrorMessage: String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "database unavailable"
    }

    private func sqliteError(_ operation: String, code: Int32) -> DurableAtomicStoreError {
        DurableAtomicStoreError.sqlite(operation: operation, code: code, message: currentErrorMessage)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
