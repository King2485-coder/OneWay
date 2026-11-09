import CryptoKit
import Foundation

public enum PrototypeCryptoError: Error, Equatable {
    case invalidFormat
    case integrityFailure
    case rollback
    case prohibitedRecoveryRecord
}

public struct AttachmentEnvelope: Codable, Sendable {
    public let version: UInt8
    public let objectID: UUID
    public var sealedManifest: Data
    public var chunks: [Data]
}

private struct AttachmentManifest: Codable {
    let version: UInt8
    let objectID: UUID
    let plaintextSize: Int
    let plaintextSHA256: Data
    let chunkSize: Int
    let chunkCiphertextSHA256: [Data]
}

public enum AttachmentCipher {
    public static let version: UInt8 = 1
    public static let defaultChunkSize = 1_048_576

    public static func makeKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    public static func encrypt(
        _ plaintext: Data,
        key: SymmetricKey,
        objectID: UUID = UUID(),
        chunkSize: Int = defaultChunkSize
    ) throws -> AttachmentEnvelope {
        guard chunkSize > 0 else { throw PrototypeCryptoError.invalidFormat }
        let count = max(1, (plaintext.count + chunkSize - 1) / chunkSize)
        var chunks: [Data] = []
        for index in 0..<count {
            let lower = min(index * chunkSize, plaintext.count)
            let upper = min(lower + chunkSize, plaintext.count)
            let chunk = plaintext.subdata(in: lower..<upper)
            let sealed = try AES.GCM.seal(
                chunk,
                using: key,
                authenticating: chunkAAD(objectID: objectID, index: index, count: count)
            )
            guard let combined = sealed.combined else { throw PrototypeCryptoError.invalidFormat }
            chunks.append(combined)
        }

        let manifest = AttachmentManifest(
            version: version,
            objectID: objectID,
            plaintextSize: plaintext.count,
            plaintextSHA256: Data(SHA256.hash(data: plaintext)),
            chunkSize: chunkSize,
            chunkCiphertextSHA256: chunks.map { Data(SHA256.hash(data: $0)) }
        )
        let encodedManifest = try canonicalEncoder.encode(manifest)
        let sealedManifest = try AES.GCM.seal(
            encodedManifest,
            using: key,
            authenticating: manifestAAD(objectID: objectID)
        )
        guard let combinedManifest = sealedManifest.combined else { throw PrototypeCryptoError.invalidFormat }
        return AttachmentEnvelope(version: version, objectID: objectID, sealedManifest: combinedManifest, chunks: chunks)
    }

    public static func decrypt(_ envelope: AttachmentEnvelope, key: SymmetricKey) throws -> Data {
        guard envelope.version == version else { throw PrototypeCryptoError.invalidFormat }
        let manifestBox = try AES.GCM.SealedBox(combined: envelope.sealedManifest)
        let manifestBytes: Data
        do {
            manifestBytes = try AES.GCM.open(
                manifestBox,
                using: key,
                authenticating: manifestAAD(objectID: envelope.objectID)
            )
        } catch { throw PrototypeCryptoError.integrityFailure }

        guard let manifest = try? JSONDecoder().decode(AttachmentManifest.self, from: manifestBytes),
              manifest.version == version,
              manifest.objectID == envelope.objectID,
              manifest.chunkCiphertextSHA256.count == envelope.chunks.count else {
            throw PrototypeCryptoError.invalidFormat
        }

        for (index, chunk) in envelope.chunks.enumerated() {
            guard Data(SHA256.hash(data: chunk)) == manifest.chunkCiphertextSHA256[index] else {
                throw PrototypeCryptoError.integrityFailure
            }
        }

        var plaintext = Data()
        for (index, chunk) in envelope.chunks.enumerated() {
            do {
                let box = try AES.GCM.SealedBox(combined: chunk)
                plaintext.append(try AES.GCM.open(
                    box,
                    using: key,
                    authenticating: chunkAAD(objectID: envelope.objectID, index: index, count: envelope.chunks.count)
                ))
            } catch { throw PrototypeCryptoError.integrityFailure }
        }
        guard plaintext.count == manifest.plaintextSize,
              Data(SHA256.hash(data: plaintext)) == manifest.plaintextSHA256 else {
            throw PrototypeCryptoError.integrityFailure
        }
        return plaintext
    }

    private static var canonicalEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func manifestAAD(objectID: UUID) -> Data {
        Data("OneWay.Attachment.Manifest|v1|\(objectID.uuidString.lowercased())".utf8)
    }

    private static func chunkAAD(objectID: UUID, index: Int, count: Int) -> Data {
        Data("OneWay.Attachment.Chunk|v1|\(objectID.uuidString.lowercased())|\(index)|\(count)".utf8)
    }
}
