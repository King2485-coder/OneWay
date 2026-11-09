import Foundation
import XCTest
@testable import OneWayPhase1B2

final class RecoveryEnvelopeTests: XCTestCase {
    func testRestoreWrongKeyTamperAndRollback() throws {
        let accountID = UUID()
        let key = RecoveryCipher.makeRecoveryKey()
        let records = [RecoveryRecord(kind: "message_history", value: Data("ciphertext-derived local history".utf8))]
        let (generation1, _) = try RecoveryCipher.encrypt(records: records, accountID: accountID, generation: 1, key: key)
        let (generation2, anchor2) = try RecoveryCipher.encrypt(records: records, accountID: accountID, generation: 2, key: key)

        XCTAssertEqual(try RecoveryCipher.restore(generation2, key: key, trustedAnchor: anchor2), records)
        XCTAssertThrowsError(try RecoveryCipher.restore(generation2, key: RecoveryCipher.makeRecoveryKey(), trustedAnchor: anchor2))

        var tampered = generation2
        tampered.sealedArchive[20] ^= 1
        XCTAssertThrowsError(try RecoveryCipher.restore(tampered, key: key, trustedAnchor: anchor2))
        XCTAssertThrowsError(try RecoveryCipher.restore(generation1, key: key, trustedAnchor: anchor2)) { error in
            XCTAssertEqual(error as? PrototypeCryptoError, .rollback)
        }
    }

    func testLiveRatchetStateCannotEnterRecoveryArchive() throws {
        XCTAssertThrowsError(try RecoveryCipher.encrypt(
            records: [RecoveryRecord(kind: "live_ratchet_state", value: Data([1]))],
            accountID: UUID(),
            generation: 1,
            key: RecoveryCipher.makeRecoveryKey()
        )) { error in
            XCTAssertEqual(error as? PrototypeCryptoError, .prohibitedRecoveryRecord)
        }
    }
}
