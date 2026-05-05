import Foundation
import CryptoKit
#if canImport(Security)
import Security
#endif

/// Call-signalling crypto helpers.
///
/// Goals:
/// - Encrypt **all** SDP + ICE payloads end-to-end (server only relays).
/// - Keep long-term identity keys on-device (Keychain).
/// - Use ephemeral per-call keys for forward secrecy (best-effort MVP).
///
/// Notes:
/// - This is **not** a full Signal/X3DH + Double Ratchet implementation.
///   It is a minimal, production-minded ECDH + HKDF + AES-GCM scheme for
///   call signalling payload confidentiality.
/// - Identity verification is TOFU: the first time we see a peer identity
///   key we cache it; if it changes later, treat as a security event.
final class CallIdentityKeyStore: @unchecked Sendable {
    static let shared = CallIdentityKeyStore()

    private let service = "OneWay.CallCrypto"
    private let account = "identityKeyAgreement"

    private var cachedKey: Curve25519.KeyAgreement.PrivateKey?
    private let lock = NSLock()

    private init() {}

    func identityKey() -> Curve25519.KeyAgreement.PrivateKey {
        lock.lock()
        defer { lock.unlock() }

        if let cachedKey { return cachedKey }
        if let data = readKeychain(),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) {
            cachedKey = key
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        _ = writeKeychain(key.rawRepresentation)
        cachedKey = key
        return key
    }

    func identityPublicKeyB64() -> String {
        identityKey().publicKey.rawRepresentation.base64EncodedString()
    }

    // MARK: - Keychain

    #if canImport(Security)
    private func writeKeychain(_ data: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attrs as CFDictionary, nil)
        return status == errSecSuccess
    }

    private func readKeychain() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }
    #else
    private func writeKeychain(_ data: Data) -> Bool { _ = data; return false }
    private func readKeychain() -> Data? { nil }
    #endif
}

/// Per-call crypto state.
///
/// Initial offer/answer encryption uses Identity<->Ephemeral (so the receiver
/// can decrypt before learning the peer's ephemeral key).
///
/// Once both sides know each other's ephemeral public keys, we switch to an
/// Ephemeral<->Ephemeral key for ICE candidate encryption.
struct CallCryptoSession: Sendable {
    enum Phase: Sendable {
        case initial // identity<->ephemeral
        case established // ephemeral<->ephemeral
    }

    let callID: UUID
    let localIdentity: Curve25519.KeyAgreement.PrivateKey
    let localEphemeral: Curve25519.KeyAgreement.PrivateKey

    /// Cached when we first receive a peer signal.
    var remoteIdentityPublic: Curve25519.KeyAgreement.PublicKey?
    /// Cached once peer shares their ephemeral key.
    var remoteEphemeralPublic: Curve25519.KeyAgreement.PublicKey?

    var phase: Phase {
        remoteEphemeralPublic == nil ? .initial : .established
    }

    init(callID: UUID) {
        self.callID = callID
        self.localIdentity = CallIdentityKeyStore.shared.identityKey()
        self.localEphemeral = Curve25519.KeyAgreement.PrivateKey()
        self.remoteIdentityPublic = nil
        self.remoteEphemeralPublic = nil
    }

    var localEphemeralPublicB64: String {
        localEphemeral.publicKey.rawRepresentation.base64EncodedString()
    }

    var localIdentityPublicB64: String {
        localIdentity.publicKey.rawRepresentation.base64EncodedString()
    }

    mutating func setRemoteIdentityPublicB64(_ b64: String) throws {
        guard let data = Data(base64Encoded: b64) else { throw CryptoError.badKey }
        remoteIdentityPublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: data)
    }

    mutating func setRemoteEphemeralPublicB64(_ b64: String) throws {
        guard let data = Data(base64Encoded: b64) else { throw CryptoError.badKey }
        remoteEphemeralPublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: data)
    }

    func encryptOfferOrAnswer(_ plaintext: Data) throws -> String {
        // Requires remote identity public key (so receiver can decrypt before
        // exchanging ephemerals).
        guard let remoteIdentityPublic else { throw CryptoError.missingPeerKey }
        let shared = try localEphemeral.sharedSecretFromKeyAgreement(with: remoteIdentityPublic)
        let key = deriveKey(shared: shared, purpose: "oneway-call-signal-initial")
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw CryptoError.sealFailed }
        return combined.base64EncodedString()
    }

    func decryptOfferOrAnswer(ciphertextB64: String, peerEphemeralPubB64: String) throws -> Data {
        guard let cipher = Data(base64Encoded: ciphertextB64),
              let peerEphemeral = Data(base64Encoded: peerEphemeralPubB64) else {
            throw CryptoError.badCiphertext
        }
        let peerEphemeralKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerEphemeral)
        let shared = try localIdentity.sharedSecretFromKeyAgreement(with: peerEphemeralKey)
        let key = deriveKey(shared: shared, purpose: "oneway-call-signal-initial")
        let box = try AES.GCM.SealedBox(combined: cipher)
        return try AES.GCM.open(box, using: key)
    }

    func encryptICE(_ plaintext: Data) throws -> String {
        guard let remoteEphemeralPublic else { throw CryptoError.missingPeerKey }
        let shared = try localEphemeral.sharedSecretFromKeyAgreement(with: remoteEphemeralPublic)
        let key = deriveKey(shared: shared, purpose: "oneway-call-signal-ice")
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw CryptoError.sealFailed }
        return combined.base64EncodedString()
    }

    func decryptICE(ciphertextB64: String, peerEphemeralPubB64: String) throws -> Data {
        guard let cipher = Data(base64Encoded: ciphertextB64),
              let peerEphemeral = Data(base64Encoded: peerEphemeralPubB64) else {
            throw CryptoError.badCiphertext
        }
        let peerEphemeralKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerEphemeral)
        let shared = try localEphemeral.sharedSecretFromKeyAgreement(with: peerEphemeralKey)
        let key = deriveKey(shared: shared, purpose: "oneway-call-signal-ice")
        let box = try AES.GCM.SealedBox(combined: cipher)
        return try AES.GCM.open(box, using: key)
    }

    private func deriveKey(shared: SharedSecret, purpose: String) -> SymmetricKey {
        // Stable per-call salt binds keys to this call id.
        let salt = Data(callID.uuidString.utf8)
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data(purpose.utf8),
            outputByteCount: 32
        )
    }

    enum CryptoError: Error {
        case missingPeerKey
        case badKey
        case badCiphertext
        case sealFailed
    }
}
