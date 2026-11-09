import Foundation
import XCTest
@testable import OneWayPhase1B2

final class RemediationSentinelTests: XCTestCase {
    func testOpaqueAttachmentAndRecoverySinks() throws {
        let sentinel = Data("ONEWAY_REMEDIATION_PRIVATE_SENTINEL_20261024".utf8)
        let key = AttachmentCipher.makeKey()
        let first = try AttachmentCipher.encrypt(sentinel, key: key)
        let second = try AttachmentCipher.encrypt(sentinel, key: key)
        XCTAssertNotEqual(first.chunks, second.chunks)
        XCTAssertNotEqual(first.sealedManifest, second.sealedManifest)
        XCTAssertThrowsError(try AttachmentCipher.decrypt(first, key: AttachmentCipher.makeKey()))
        let (recovery, _) = try RecoveryCipher.encrypt(records: [RecoveryRecord(kind: "message_history", value: sentinel)], accountID: UUID(), generation: 1, key: RecoveryCipher.makeRecoveryKey())
        let sinks = first.chunks + [first.sealedManifest, recovery.sealedArchive]
        for sink in sinks { XCTAssertNil(sink.range(of: sentinel)) }
        if let path = ProcessInfo.processInfo.environment["ONEWAY_SENTINEL_OUTPUT"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (index, sink) in sinks.enumerated() {
                try sink.write(to: directory.appendingPathComponent("encrypted-\(index).bin"))
            }
        }
    }
}
