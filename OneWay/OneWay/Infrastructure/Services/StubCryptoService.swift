import Foundation

actor StubCryptoService: CryptoService {
    func ensureIdentity() async throws -> CryptoIdentity {
        CryptoIdentity(fingerprint: "STUB-FPR-\(UUID().uuidString.prefix(8))")
    }

    func encrypt(message: PlaintextMessage, for recipient: UserProfile, context: MessageContext) async throws -> EncryptedMessage {
        let fakeCipher = Data(message.body.utf8).base64EncodedData()
        let payload = EncryptedPayload(ciphertext: fakeCipher, nonce: Data(UUID().uuidString.utf8), associatedData: nil)
        return EncryptedMessage(
            id: message.id,
            chatID: message.chatID,
            senderID: message.senderID,
            encryptedBody: payload,
            attachment: message.attachment,
            sentAt: Date(),
            expiresAt: message.expiresAt
        )
    }

    func decrypt(_ message: EncryptedMessage) async throws -> PlaintextMessage {
        let body = String(data: message.encryptedBody.ciphertext, encoding: .utf8) ?? "[ciphertext]"
        return PlaintextMessage(
            id: message.id,
            chatID: message.chatID,
            senderID: message.senderID,
            body: body,
            attachment: message.attachment,
            expiresAt: message.expiresAt
        )
    }

    func groupSession(for groupID: UUID) async throws -> GroupCryptoSession {
        GroupCryptoSession(groupID: groupID, epoch: 1)
    }
}
