import Foundation
import XCTest
@testable import OneWayPhase1B2

final class TransactionalStoreTests: XCTestCase {
    func testFailureBeforeAndDuringTransactionCannotAdvanceStateOrCreateOutbox() throws {
        let store = try makeStore()
        for point in [CrashPoint.beforeTransaction, .duringTransaction] {
            XCTAssertThrowsError(try store.commitSend(
                session: "alice-bob", nextGeneration: 1, opaqueState: Data([1]),
                messageID: UUID().uuidString, exactEnvelope: Data([9]), crashPoint: point
            ))
            XCTAssertEqual(try store.generation(session: "alice-bob"), 0)
        }
    }

    func testAfterCommitAndNetworkUncertaintyRetryExactCiphertext() throws {
        let store = try makeStore()
        let envelope = Data((0..<256).map(UInt8.init))
        XCTAssertThrowsError(try store.commitSend(
            session: "alice-bob", nextGeneration: 7, opaqueState: Data([7]),
            messageID: "m1", exactEnvelope: envelope, crashPoint: .afterCommit
        ))
        XCTAssertEqual(try store.generation(session: "alice-bob"), 7)
        XCTAssertEqual(try store.outboxEnvelope(messageID: "m1"), envelope)

        try store.markSentUnknown("m1")
        XCTAssertEqual(try store.status(messageID: "m1"), "SENT_UNKNOWN")
        XCTAssertEqual(try store.outboxEnvelope(messageID: "m1"), envelope)
        try store.acknowledge("m1")
        XCTAssertEqual(try store.status(messageID: "m1"), "ACKED")
    }

    func testReceiveReplayIsAtomicAndIdempotent() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try store.commitReceive(replayID: "r1", opaqueMessage: Data([1]), crashPoint: .duringTransaction))
        XCTAssertTrue(try store.commitReceive(replayID: "r1", opaqueMessage: Data([1])))
        XCTAssertFalse(try store.commitReceive(replayID: "r1", opaqueMessage: Data([1])))
    }

    private func makeStore() throws -> TransactionalCryptoStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try TransactionalCryptoStore(path: directory.appendingPathComponent("crypto.sqlite").path)
    }
}
