import CryptoKit
import Foundation

public struct RecoveryRecord: Codable, Equatable, Sendable {
    public let kind: String
    public let value: Data

    public init(kind: String, value: Data) {
        self.kind = kind
        self.value = value
    }
}

public struct RecoveryEnvelope: Codable, Sendable {
    public let version: UInt8
    public let accountID: UUID
    public let generation: UInt64
    public var sealedArchive: Data
}

public struct RecoveryAnchor: Equatable, Sendable {
    public let generation: UInt64
    public let envelopeDigest: Data

    public init(generation: UInt64, envelopeDigest: Data) {
        self.generation = generation
        self.envelopeDigest = envelopeDigest
    }
}

private struct RecoveryArchive: Codable {
    let records: [RecoveryRecord]
}

public enum RecoveryCipher {
    public static let version: UInt8 = 1
    private static let prohibitedKinds: Set<String> = [
        "live_ratchet_state", "prekey_private", "message_key", "nonce_state", "session_state",
    ]

    public static func makeRecoveryKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    public static func encrypt(
        records: [RecoveryRecord],
        accountID: UUID,
        generation: UInt64,
        key: SymmetricKey
    ) throws -> (RecoveryEnvelope, RecoveryAnchor) {
        guard generation > 0 else { throw PrototypeCryptoError.invalidFormat }
        guard records.allSatisfy({ !prohibitedKinds.contains($0.kind) }) else {
            throw PrototypeCryptoError.prohibitedRecoveryRecord
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let archive = try encoder.encode(RecoveryArchive(records: records))
        let sealed = try AES.GCM.seal(archive, using: key, authenticating: aad(accountID: accountID, generation: generation))
        guard let combined = sealed.combined else { throw PrototypeCryptoError.invalidFormat }
        let envelope = RecoveryEnvelope(version: version, accountID: accountID, generation: generation, sealedArchive: combined)
        return (envelope, anchor(for: envelope))
    }

    public static func restore(
        _ envelope: RecoveryEnvelope,
        key: SymmetricKey,
        trustedAnchor: RecoveryAnchor
    ) throws -> [RecoveryRecord] {
        guard envelope.version == version else { throw PrototypeCryptoError.invalidFormat }
        let digest = envelopeDigest(envelope)
        guard envelope.generation >= trustedAnchor.generation else { throw PrototypeCryptoError.rollback }
        if envelope.generation == trustedAnchor.generation,
           digest != trustedAnchor.envelopeDigest {
            throw PrototypeCryptoError.rollback
        }
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(
                AES.GCM.SealedBox(combined: envelope.sealedArchive),
                using: key,
                authenticating: aad(accountID: envelope.accountID, generation: envelope.generation)
            )
        } catch { throw PrototypeCryptoError.integrityFailure }
        guard let archive = try? JSONDecoder().decode(RecoveryArchive.self, from: plaintext),
              archive.records.allSatisfy({ !prohibitedKinds.contains($0.kind) }) else {
            throw PrototypeCryptoError.invalidFormat
        }
        return archive.records
    }

    public static func anchor(for envelope: RecoveryEnvelope) -> RecoveryAnchor {
        RecoveryAnchor(generation: envelope.generation, envelopeDigest: envelopeDigest(envelope))
    }

    private static func aad(accountID: UUID, generation: UInt64) -> Data {
        Data("OneWay.Recovery|v1|\(accountID.uuidString.lowercased())|\(generation)".utf8)
    }

    private static func envelopeDigest(_ envelope: RecoveryEnvelope) -> Data {
        var data = aad(accountID: envelope.accountID, generation: envelope.generation)
        data.append(envelope.sealedArchive)
        return Data(SHA256.hash(data: data))
    }
}
