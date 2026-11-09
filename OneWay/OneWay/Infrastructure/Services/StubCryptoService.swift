import Foundation

enum OneWayCryptoUnavailableError: LocalizedError, Equatable {
    case cryptoNotImplemented

    var errorDescription: String? {
        "Secure message encryption is not implemented. Plaintext fallback is prohibited."
    }
}

/// Explicit fail-closed placeholder until an approved protocol implementation
/// is integrated. Encoding is never represented as encryption capability.
actor UnavailableCryptoService: CryptoService {
    func ensureIdentity() async throws -> CryptoIdentity {
        throw OneWayCryptoUnavailableError.cryptoNotImplemented
    }

    func encrypt(message: PlaintextMessage, for recipient: UserProfile, context: MessageContext) async throws -> EncryptedMessage {
        _ = (message, recipient, context)
        throw OneWayCryptoUnavailableError.cryptoNotImplemented
    }

    func decrypt(_ message: EncryptedMessage) async throws -> PlaintextMessage {
        _ = message
        throw OneWayCryptoUnavailableError.cryptoNotImplemented
    }

    func groupSession(for groupID: UUID) async throws -> GroupCryptoSession {
        _ = groupID
        throw OneWayCryptoUnavailableError.cryptoNotImplemented
    }
}
