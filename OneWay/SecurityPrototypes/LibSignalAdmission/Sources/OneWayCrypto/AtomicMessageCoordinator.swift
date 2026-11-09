import Foundation
import LibSignalClient

/// Store context supplied to every libsignal callback for one message. Session,
/// identity, prekey, and Kyber writes are staged on the same SQLite transaction
/// as the outbox/replay/message rows.
public final class OneWayAtomicStoreContext: StoreContext, @unchecked Sendable {
    public let transaction: AtomicBlobTransaction

    public init(transaction: AtomicBlobTransaction) {
        self.transaction = transaction
    }
}

public struct CommittedInboundMessage: Equatable, Sendable {
    public let messageID: String
    public let senderDeviceID: UInt32
    public let plaintext: Data
}

public enum AtomicInboundResult: Equatable, Sendable {
    case committed(CommittedInboundMessage)
    case duplicate
}

/// Caller-owned atomic boundary around the pinned libsignal API. The encryption
/// and decryption closures must call libsignal with the supplied StoreContext.
public final class OneWayAtomicMessageCoordinator: @unchecked Sendable {
    private let store: SQLiteAtomicCryptoStore
    private let protocolVersion: String

    public init(store: SQLiteAtomicCryptoStore, protocolVersion: String = OneWayCryptoAdmission.pinnedVersion) {
        self.store = store
        self.protocolVersion = protocolVersion
    }

    /// Loads/advances libsignal state, persists the exact ciphertext/envelope,
    /// and creates outbox/device rows in one durable transaction. A duplicate
    /// message UUID returns the already-committed ciphertext without re-encryption.
    public func commitOutbound(
        messageID: String,
        recipientDeviceID: UInt32,
        encrypt: (StoreContext) throws -> Data,
        makeEnvelope: (Data) throws -> Data
    ) throws -> CommittedOutboundEnvelope {
        let transaction = try store.beginAtomicCryptoTransaction()
        do {
            if let existing = try transaction.outbox(messageID: messageID) {
                transaction.rollback()
                return CommittedOutboundEnvelope(record: existing)
            }

            let context = OneWayAtomicStoreContext(transaction: transaction)
            try transaction.audit(messageID: messageID, transition: "OUTBOUND_BEGIN", crashMarker: nil)
            let ciphertext = try encrypt(context)
            let envelope = try makeEnvelope(ciphertext)
            try transaction.insertOutbox(
                messageID: messageID,
                recipientDeviceID: recipientDeviceID,
                ciphertext: ciphertext,
                envelope: envelope,
                protocolVersion: protocolVersion
            )
            try transaction.insertDeviceDelivery(
                messageID: messageID,
                recipientDeviceID: recipientDeviceID
            )
            try transaction.audit(messageID: messageID, transition: "OUTBOUND_READY_TO_COMMIT", crashMarker: nil)
            try transaction.commit()
        } catch {
            transaction.rollback()
            throw error
        }

        guard let committed = try store.outbox(messageID: messageID) else {
            throw DurableAtomicStoreError.durabilityUncertain(
                "commit returned but the outbox record is not recoverable"
            )
        }
        return CommittedOutboundEnvelope(record: committed)
    }

    /// Returns only previously committed ciphertext. Retry never invokes
    /// libsignal and therefore cannot advance the ratchet a second time.
    public func retryOutbound(messageID: String) throws -> CommittedOutboundEnvelope? {
        try store.outbox(messageID: messageID).map(CommittedOutboundEnvelope.init(record:))
    }

    /// NETWORK_SEND_REQUIRES_COMMITTED_CRYPTO_TRANSACTION.
    public func sendCommitted(
        _ committed: CommittedOutboundEnvelope,
        using transport: CommittedCryptoTransport
    ) throws {
        let transaction = try store.beginAtomicCryptoTransaction()
        do {
            guard let durable = try transaction.outbox(messageID: committed.messageID),
                  durable.ciphertext == committed.ciphertext,
                  durable.envelope == committed.envelope,
                  durable.recipientDeviceID == committed.recipientDeviceID else {
                throw DurableAtomicStoreError.durabilityUncertain(
                    "transport value does not match committed outbox state"
                )
            }
            try transaction.markDeliveryAttempt(
                messageID: committed.messageID,
                recipientDeviceID: committed.recipientDeviceID
            )
            try transaction.audit(
                messageID: committed.messageID,
                transition: "DELIVERY_ATTEMPT_DURABLE",
                crashMarker: nil
            )
            try transaction.commit()
        } catch {
            transaction.rollback()
            throw error
        }
        try transport.send(committed)
    }

    public func acknowledgeOutbound(messageID: String, recipientDeviceID: UInt32) throws {
        let transaction = try store.beginAtomicCryptoTransaction()
        do {
            try transaction.acknowledge(messageID: messageID, recipientDeviceID: recipientDeviceID)
            try transaction.audit(messageID: messageID, transition: "OUTBOUND_ACKNOWLEDGED", crashMarker: nil)
            try transaction.commit()
        } catch {
            transaction.rollback()
            throw error
        }
    }

    /// Replay marker, advanced libsignal state, plaintext commit, and ack
    /// eligibility commit together. Plaintext is returned only after COMMIT.
    public func commitInbound(
        messageID: String,
        senderDeviceID: UInt32,
        ciphertext: Data,
        decrypt: (StoreContext) throws -> Data
    ) throws -> AtomicInboundResult {
        let transaction = try store.beginAtomicCryptoTransaction()
        do {
            if try transaction.replayExists(messageID: messageID, senderDeviceID: senderDeviceID) {
                transaction.rollback()
                return .duplicate
            }
            let context = OneWayAtomicStoreContext(transaction: transaction)
            try transaction.audit(messageID: messageID, transition: "INBOUND_BEGIN", crashMarker: nil)
            let plaintext = try decrypt(context)
            try transaction.insertInbox(
                messageID: messageID,
                senderDeviceID: senderDeviceID,
                ciphertext: ciphertext,
                plaintext: plaintext,
                acknowledgementEligible: true
            )
            try transaction.insertReplay(messageID: messageID, senderDeviceID: senderDeviceID)
            try transaction.audit(messageID: messageID, transition: "INBOUND_READY_TO_COMMIT", crashMarker: nil)
            try transaction.commit()
            return .committed(CommittedInboundMessage(
                messageID: messageID,
                senderDeviceID: senderDeviceID,
                plaintext: plaintext
            ))
        } catch {
            transaction.rollback()
            throw error
        }
    }
}
