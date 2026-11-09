import CryptoKit
import Foundation
import XCTest
@testable import OneWayPhase1B2

final class AttachmentEnvelopeTests: XCTestCase {
    func testTextImageAndVideoSizedRoundTrip() throws {
        let fixtures = [
            Data("OneWay private attachment".utf8),
            Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) + Data(repeating: 0x7a, count: 200_000),
            Data(repeating: 0x5a, count: 64 * 1_048_576),
        ]
        for fixture in fixtures {
            let key = AttachmentCipher.makeKey()
            let envelope = try AttachmentCipher.encrypt(fixture, key: key)
            let restored = try AttachmentCipher.decrypt(envelope, key: key)
            XCTAssertEqual(Data(SHA256.hash(data: restored)), Data(SHA256.hash(data: fixture)))
        }
    }

    func testChunkManifestOrderingAndWrongKeyTamperingFails() throws {
        let key = AttachmentCipher.makeKey()
        let fixture = deterministicData(count: 3_500_000)
        let original = try AttachmentCipher.encrypt(fixture, key: key)

        var chunkTamper = original
        chunkTamper.chunks[0][20] ^= 1
        XCTAssertThrowsError(try AttachmentCipher.decrypt(chunkTamper, key: key))

        var manifestTamper = original
        manifestTamper.sealedManifest[20] ^= 1
        XCTAssertThrowsError(try AttachmentCipher.decrypt(manifestTamper, key: key))

        var reordered = original
        reordered.chunks.swapAt(0, 1)
        XCTAssertThrowsError(try AttachmentCipher.decrypt(reordered, key: key))

        XCTAssertThrowsError(try AttachmentCipher.decrypt(original, key: AttachmentCipher.makeKey()))
    }

    private func deterministicData(count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: ($0 &* 31) &+ 17) })
    }
}
