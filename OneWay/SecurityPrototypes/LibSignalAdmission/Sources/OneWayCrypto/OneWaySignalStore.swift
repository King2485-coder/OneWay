import Foundation
import LibSignalClient
import Security

public enum OneWayStoreError: Error {
    case missingIdentity
    case missingRecord
    case injectedFailure
    case keychain(OSStatus)
}

public struct OneWayStoreContext: StoreContext, Sendable {
    public init() {}
}

/// Test implementation with atomic copy-on-write commits and deterministic failure hooks.
public final class AdmissionTransactionalBlobStore: TransactionalBlobStore {
    public enum FailurePoint {
        case diskWrite
        case transactionRollback
        case outboxWrite
        case sessionStateWrite
        case afterCommit
    }
    private var values: [String: Data] = [:]
    public var failurePoint: FailurePoint?

    public init() {}

    public func read(_ key: String) throws -> Data? { values[key] }

    public func transaction(_ updates: [String: Data?]) throws {
        if failurePoint == .diskWrite || failurePoint == .transactionRollback {
            throw OneWayStoreError.injectedFailure
        }
        if failurePoint == .outboxWrite, updates.keys.contains(where: { $0.hasPrefix("outbox") }) {
            throw OneWayStoreError.injectedFailure
        }
        if failurePoint == .sessionStateWrite, updates.keys.contains(where: { $0.hasPrefix("session.") }) {
            throw OneWayStoreError.injectedFailure
        }
        var candidate = values
        for (key, value) in updates { candidate[key] = value }
        values = candidate
        if failurePoint == .afterCommit { throw OneWayStoreError.injectedFailure }
    }
}

public protocol IdentitySecretStore: AnyObject {
    func load() throws -> Data?
    func save(_ bytes: Data) throws
}

/// Apple Keychain adapter for the long-lived identity key pair. No private key is
/// placed in UserDefaults, plist, SQLite, logs, transport payloads, or fixtures.
public final class KeychainIdentitySecretStore: IdentitySecretStore {
    private let service: String
    private let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    public func load() throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw OneWayStoreError.keychain(status)
        }
        return data
    }

    public func save(_ bytes: Data) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attrs: [CFString: Any] = [
            kSecValueData: bytes,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let update = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if update == errSecItemNotFound {
            var add = query
            add.merge(attrs) { _, new in new }
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw OneWayStoreError.keychain(status) }
        } else if update != errSecSuccess {
            throw OneWayStoreError.keychain(update)
        }
    }
}

public final class OneWaySignalStore: IdentityKeyStore, PreKeyStore, SignedPreKeyStore,
    KyberPreKeyStore, SessionStore
{
    private let identitySecrets: IdentitySecretStore
    private let blobs: TransactionalBlobStore
    private let registrationID: UInt32

    public init(identitySecrets: IdentitySecretStore, blobs: TransactionalBlobStore, registrationID: UInt32) throws {
        self.identitySecrets = identitySecrets
        self.blobs = blobs
        self.registrationID = registrationID
        if try identitySecrets.load() == nil {
            try identitySecrets.save(IdentityKeyPair.generate().serialize())
        }
    }

    public func identityKeyPair(context: StoreContext) throws -> IdentityKeyPair {
        guard let bytes = try identitySecrets.load() else { throw OneWayStoreError.missingIdentity }
        return try IdentityKeyPair(bytes: bytes)
    }

    public func localRegistrationId(context: StoreContext) throws -> UInt32 { registrationID }

    public func saveIdentity(_ identity: IdentityKey, for address: ProtocolAddress, context: StoreContext) throws -> IdentityChange {
        let key = identityKey(address)
        let previous = try readBlob(key, context: context).map(IdentityKey.init(bytes:))
        try writeBlobs([key: identity.serialize()], context: context)
        return previous == nil || previous == identity ? .newOrUnchanged : .replacedExisting
    }

    public func isTrustedIdentity(_ identity: IdentityKey, for address: ProtocolAddress, direction: Direction, context: StoreContext) throws -> Bool {
        try self.identity(for: address, context: context).map { $0 == identity } ?? true
    }

    public func identity(for address: ProtocolAddress, context: StoreContext) throws -> IdentityKey? {
        try readBlob(identityKey(address), context: context).map(IdentityKey.init(bytes:))
    }

    public func loadPreKey(id: UInt32, context: StoreContext) throws -> PreKeyRecord {
        guard let bytes = try readBlob("prekey.\(id)", context: context) else { throw OneWayStoreError.missingRecord }
        return try PreKeyRecord(bytes: bytes)
    }

    public func storePreKey(_ record: PreKeyRecord, id: UInt32, context: StoreContext) throws {
        try writeBlobs(["prekey.\(id)": record.serialize()], context: context)
    }

    public func removePreKey(id: UInt32, context: StoreContext) throws {
        try writeBlobs(["prekey.\(id)": nil], context: context)
    }

    public func loadSignedPreKey(id: UInt32, context: StoreContext) throws -> SignedPreKeyRecord {
        guard let bytes = try readBlob("signed.\(id)", context: context) else { throw OneWayStoreError.missingRecord }
        return try SignedPreKeyRecord(bytes: bytes)
    }

    public func storeSignedPreKey(_ record: SignedPreKeyRecord, id: UInt32, context: StoreContext) throws {
        try writeBlobs(["signed.\(id)": record.serialize()], context: context)
    }

    public func loadKyberPreKey(id: UInt32, context: StoreContext) throws -> KyberPreKeyRecord {
        guard let bytes = try readBlob("kyber.\(id)", context: context) else { throw OneWayStoreError.missingRecord }
        return try KyberPreKeyRecord(bytes: bytes)
    }

    public func storeKyberPreKey(_ record: KyberPreKeyRecord, id: UInt32, context: StoreContext) throws {
        try writeBlobs(["kyber.\(id)": record.serialize()], context: context)
    }

    public func markKyberPreKeyUsed(id: UInt32, signedPreKeyId: UInt32, baseKey: PublicKey, context: StoreContext) throws {
        let key = "kyber-used.\(id).\(signedPreKeyId).\(baseKey.serialize().base64EncodedString())"
        if try readBlob(key, context: context) != nil { throw SignalError.invalidMessage("reused base key") }
        try writeBlobs([key: Data([1])], context: context)
    }

    public func loadSession(for address: ProtocolAddress, context: StoreContext) throws -> SessionRecord? {
        guard let bytes = try readBlob(sessionKey(address), context: context) else { return nil }
        return try SessionRecord(bytes: bytes)
    }

    public func loadExistingSessions(for addresses: [ProtocolAddress], context: StoreContext) throws -> [SessionRecord] {
        try addresses.map {
            guard let session = try loadSession(for: $0, context: context) else {
                throw SignalError.sessionNotFound("\($0)")
            }
            return session
        }
    }

    public func storeSession(_ record: SessionRecord, for address: ProtocolAddress, context: StoreContext) throws {
        try writeBlobs([sessionKey(address): record.serialize()], context: context)
    }

    private func readBlob(_ key: String, context: StoreContext) throws -> Data? {
        if let atomic = context as? OneWayAtomicStoreContext {
            return try atomic.transaction.read(key)
        }
        return try blobs.read(key)
    }

    private func writeBlobs(_ updates: [String: Data?], context: StoreContext) throws {
        if let atomic = context as? OneWayAtomicStoreContext {
            try atomic.transaction.write(updates)
        } else {
            try blobs.transaction(updates)
        }
    }

    private func sessionKey(_ address: ProtocolAddress) -> String { "session.\(address)" }
    private func identityKey(_ address: ProtocolAddress) -> String { "identity.\(address)" }
}
