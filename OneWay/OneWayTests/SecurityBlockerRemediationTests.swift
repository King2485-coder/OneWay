import XCTest
@testable import CipherChat

final class SecurityBlockerRemediationTests: XCTestCase {
    func testLegacyTokenMigratesThenDeletesInsecureCopy() {
        var legacy: String? = "private-token"
        var stored: String?
        let result = AuthTokenStore.migrateLegacyCredential(
            loadLegacy: { legacy },
            storeSecurely: { stored = $0; return true },
            eraseLegacy: { legacy = nil }
        )

        XCTAssertEqual(result, "private-token")
        XCTAssertEqual(stored, "private-token")
        XCTAssertNil(legacy)
    }

    func testLegacyTokenIsDeletedAndRejectedWhenKeychainWriteFails() {
        var legacy: String? = "private-token"
        let result = AuthTokenStore.migrateLegacyCredential(
            loadLegacy: { legacy },
            storeSecurely: { _ in false },
            eraseLegacy: { legacy = nil }
        )

        XCTAssertNil(result)
        XCTAssertNil(legacy)
    }

    func testUnavailableCryptoFailsClosed() async {
        let service = UnavailableCryptoService()
        do {
            _ = try await service.ensureIdentity()
            XCTFail("Unavailable crypto must not manufacture an identity.")
        } catch let error as OneWayCryptoUnavailableError {
            XCTAssertEqual(error, .cryptoNotImplemented)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUnavailableBackupCannotCreateArtifact() async {
        let service = UnavailableBackupService()
        do {
            _ = try await service.createBackup()
            XCTFail("Unavailable backup must not create a fake secure artifact.")
        } catch let error as OneWayBackupUnavailableError {
            XCTAssertEqual(error, .notSecureForE2EE)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFutureEnvelopeContainsNoPlaintextBodyField() throws {
        let envelope = E2EEMessageEnvelopeV1(
            contentMode: .e2eeV1,
            protocolVersion: 1,
            messageID: UUID(),
            conversationID: UUID(),
            groupID: nil,
            senderUserID: "sender",
            senderDeviceID: UUID(),
            recipientDeviceIDs: [UUID()],
            ciphertext: "opaque-ciphertext",
            encryptedAttachmentManifestReferences: [],
            createdAt: Date(timeIntervalSince1970: 0),
            contentType: "message",
            protocolMetadata: [:],
            replayID: "replay-identifier-0001"
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any])

        XCTAssertNil(object["body"])
        XCTAssertNil(object["attachmentBytes"])
        XCTAssertEqual(object["contentMode"] as? String, "E2EE_V1")
    }
}
