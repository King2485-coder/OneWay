import Darwin
import Foundation

private enum ProbeError: Error, CustomStringConvertible {
    case usage
    case assertion(String)

    var description: String {
        switch self {
        case .usage: return "usage: atomicity-probe MODE DATABASE [PHASE] [MESSAGE_ID]"
        case let .assertion(message): return "atomicity assertion failed: \(message)"
        }
    }
}

private let outboundPhases = [
    "beforeSessionLoad", "afterSessionLoad", "beforeEncryption", "afterEncryption",
    "beforeRatchetPersistence", "afterRatchetPersistenceAttempt",
    "beforeOutboxPersistence", "afterOutboxPersistenceAttempt",
    "beforeTransactionCommit", "duringCommit", "immediatelyAfterCommit",
    "beforeNetworkSend", "duringNetworkSend", "immediatelyAfterNetworkSend",
    "beforeDeliveryAcknowledgement", "afterAcknowledgement",
]

private let inboundPhases = [
    "beforeReplayCheck", "afterReplayCheck", "beforeSessionLoad", "afterSessionLoad",
    "beforeDecrypt", "afterDecrypt", "beforeSessionStateWrite",
    "afterSessionStateWriteAttempt", "beforeMessagePersistence",
    "afterMessagePersistenceAttempt", "beforeReplayMarkerWrite",
    "afterReplayMarkerWriteAttempt", "beforeCommit", "duringCommit",
    "immediatelyAfterCommit", "beforeAcknowledgement", "afterAcknowledgement",
]

private let oldOutboundState = Data("outbound-generation-0".utf8)
private let newOutboundState = Data("outbound-generation-1".utf8)
private let oldInboundState = Data("inbound-generation-0".utf8)
private let newInboundState = Data("inbound-generation-1".utf8)

@inline(__always)
private func terminateIf(_ requested: String, _ current: String) {
    guard requested == current else { return }
    fflush(stdout)
    fflush(stderr)
    kill(getpid(), SIGKILL)
    _exit(137)
}

private func commitWithCrashWindow(_ transaction: AtomicBlobTransaction, phase: String, marker: String) throws {
    if phase == marker {
        DispatchQueue.global(qos: .userInitiated).async {
            usleep(100)
            kill(getpid(), SIGKILL)
        }
    }
    try transaction.commit()
    if phase == marker {
        usleep(500_000)
        kill(getpid(), SIGKILL)
    }
}

private func initialize(_ store: SQLiteAtomicCryptoStore) throws {
    let tx = try store.beginAtomicCryptoTransaction()
    do {
        try tx.write([
            "session.outbound": oldOutboundState,
            "session.inbound": oldInboundState,
        ])
        try tx.commit()
    } catch {
        tx.rollback()
        throw error
    }
}

private func outbound(_ store: SQLiteAtomicCryptoStore, phase: String, messageID: String) throws {
    guard outboundPhases.contains(phase) else { throw ProbeError.assertion("unknown outbound phase \(phase)") }
    terminateIf(phase, "beforeSessionLoad")
    let tx = try store.beginAtomicCryptoTransaction()
    do {
        let loaded = try tx.read("session.outbound")
        guard loaded == oldOutboundState else { throw ProbeError.assertion("unexpected outbound pre-state") }
        terminateIf(phase, "afterSessionLoad")
        terminateIf(phase, "beforeEncryption")
        let ciphertext = Data("ciphertext:\(messageID)".utf8)
        let envelope = Data("envelope:\(messageID)".utf8) + ciphertext
        terminateIf(phase, "afterEncryption")
        terminateIf(phase, "beforeRatchetPersistence")
        try tx.write(["session.outbound": newOutboundState])
        terminateIf(phase, "afterRatchetPersistenceAttempt")
        terminateIf(phase, "beforeOutboxPersistence")
        try tx.insertOutbox(
            messageID: messageID,
            recipientDeviceID: 9,
            ciphertext: ciphertext,
            envelope: envelope,
            protocolVersion: "v0.106.0"
        )
        try tx.insertDeviceDelivery(messageID: messageID, recipientDeviceID: 9)
        try tx.audit(messageID: messageID, transition: "OUTBOUND_READY_TO_COMMIT", crashMarker: phase)
        terminateIf(phase, "afterOutboxPersistenceAttempt")
        terminateIf(phase, "beforeTransactionCommit")
        try commitWithCrashWindow(tx, phase: phase, marker: "duringCommit")
    } catch {
        tx.rollback()
        throw error
    }

    terminateIf(phase, "immediatelyAfterCommit")

    let delivery = try store.beginAtomicCryptoTransaction()
    do {
        try delivery.markDeliveryAttempt(messageID: messageID, recipientDeviceID: 9)
        try delivery.audit(messageID: messageID, transition: "DELIVERY_ATTEMPT_DURABLE", crashMarker: phase)
        try delivery.commit()
    } catch {
        delivery.rollback()
        throw error
    }

    terminateIf(phase, "beforeNetworkSend")
    let logURL = URL(fileURLWithPath: store.databaseURL.path + ".sendlog")
    guard try store.outbox(messageID: messageID) != nil else {
        throw ProbeError.assertion("NETWORK_SEND_REQUIRES_COMMITTED_CRYPTO_TRANSACTION")
    }
    try Data((messageID + "\n").utf8).write(to: logURL, options: .atomic)
    terminateIf(phase, "duringNetworkSend")
    terminateIf(phase, "immediatelyAfterNetworkSend")
    terminateIf(phase, "beforeDeliveryAcknowledgement")

    let acknowledgement = try store.beginAtomicCryptoTransaction()
    do {
        try acknowledgement.acknowledge(messageID: messageID, recipientDeviceID: 9)
        try acknowledgement.audit(messageID: messageID, transition: "OUTBOUND_ACKNOWLEDGED", crashMarker: phase)
        try acknowledgement.commit()
    } catch {
        acknowledgement.rollback()
        throw error
    }
    terminateIf(phase, "afterAcknowledgement")
}

private func verifyOutbound(_ store: SQLiteAtomicCryptoStore, messageID: String) throws {
    guard try store.integrityCheck() == "ok" else { throw ProbeError.assertion("integrity_check failed") }
    let session = try store.read("session.outbound")
    let outbox = try store.outbox(messageID: messageID)
    let sendLogExists = FileManager.default.fileExists(atPath: store.databaseURL.path + ".sendlog")

    if session == oldOutboundState {
        guard outbox == nil else { throw ProbeError.assertion("OUTBOX_EXISTS_WITH_OLD_RATCHET_STATE") }
        guard !sendLogExists else { throw ProbeError.assertion("uncommitted ciphertext reached transport") }
    } else if session == newOutboundState {
        guard let outbox else { throw ProbeError.assertion("RATCHET_ADVANCED_WITHOUT_OUTBOX") }
        guard outbox.ciphertext == Data("ciphertext:\(messageID)".utf8) else {
            throw ProbeError.assertion("committed ciphertext changed")
        }
        guard outbox.envelope.count >= outbox.ciphertext.count,
              outbox.envelope.suffix(outbox.ciphertext.count) == outbox.ciphertext else {
            throw ProbeError.assertion("committed envelope changed")
        }
    } else {
        throw ProbeError.assertion("ratchet state is neither old nor new")
    }
}

private func inbound(_ store: SQLiteAtomicCryptoStore, phase: String, messageID: String) throws {
    guard inboundPhases.contains(phase) else { throw ProbeError.assertion("unknown inbound phase \(phase)") }
    let ciphertext = Data("inbound-ciphertext:\(messageID)".utf8)
    let plaintext = Data("test-only-plaintext:\(messageID)".utf8)
    terminateIf(phase, "beforeReplayCheck")
    let tx = try store.beginAtomicCryptoTransaction()
    do {
        guard try !tx.replayExists(messageID: messageID, senderDeviceID: 1) else {
            throw ProbeError.assertion("unexpected replay marker")
        }
        terminateIf(phase, "afterReplayCheck")
        terminateIf(phase, "beforeSessionLoad")
        guard try tx.read("session.inbound") == oldInboundState else {
            throw ProbeError.assertion("unexpected inbound pre-state")
        }
        terminateIf(phase, "afterSessionLoad")
        terminateIf(phase, "beforeDecrypt")
        _ = plaintext
        terminateIf(phase, "afterDecrypt")
        terminateIf(phase, "beforeSessionStateWrite")
        try tx.write(["session.inbound": newInboundState])
        terminateIf(phase, "afterSessionStateWriteAttempt")
        terminateIf(phase, "beforeMessagePersistence")
        try tx.insertInbox(
            messageID: messageID,
            senderDeviceID: 1,
            ciphertext: ciphertext,
            plaintext: plaintext,
            acknowledgementEligible: true
        )
        terminateIf(phase, "afterMessagePersistenceAttempt")
        terminateIf(phase, "beforeReplayMarkerWrite")
        try tx.insertReplay(messageID: messageID, senderDeviceID: 1)
        terminateIf(phase, "afterReplayMarkerWriteAttempt")
        try tx.audit(messageID: messageID, transition: "INBOUND_READY_TO_COMMIT", crashMarker: phase)
        terminateIf(phase, "beforeCommit")
        try commitWithCrashWindow(tx, phase: phase, marker: "duringCommit")
    } catch {
        tx.rollback()
        throw error
    }
    terminateIf(phase, "immediatelyAfterCommit")
    terminateIf(phase, "beforeAcknowledgement")

    let acknowledgement = try store.beginAtomicCryptoTransaction()
    do {
        try acknowledgement.audit(messageID: messageID, transition: "INBOUND_ACKNOWLEDGED", crashMarker: phase)
        try acknowledgement.commit()
    } catch {
        acknowledgement.rollback()
        throw error
    }
    terminateIf(phase, "afterAcknowledgement")
}

private func verifyInbound(_ store: SQLiteAtomicCryptoStore, messageID: String) throws {
    guard try store.integrityCheck() == "ok" else { throw ProbeError.assertion("integrity_check failed") }
    let session = try store.read("session.inbound")
    let replay = try store.replayExists(messageID: messageID, senderDeviceID: 1)
    let inbox = try store.inbox(messageID: messageID, senderDeviceID: 1)
    if session == oldInboundState {
        guard !replay else { throw ProbeError.assertion("replay marker committed without ratchet") }
        guard inbox == nil else { throw ProbeError.assertion("plaintext committed without ratchet") }
    } else if session == newInboundState {
        guard replay else { throw ProbeError.assertion("ratchet committed without replay marker") }
        guard let inbox else { throw ProbeError.assertion("ratchet committed without inbox message") }
        guard inbox.plaintext == Data("test-only-plaintext:\(messageID)".utf8) else {
            throw ProbeError.assertion("plaintext commit mismatch")
        }
        guard inbox.acknowledgementEligible else {
            throw ProbeError.assertion("acknowledgement eligibility missing")
        }
    } else {
        throw ProbeError.assertion("inbound ratchet state is neither old nor new")
    }
}

private func tenThousand(_ store: SQLiteAtomicCryptoStore) throws {
    for index in 0..<10_000 {
        let messageID = "soak-message-\(index)"
        let tx = try store.beginAtomicCryptoTransaction()
        do {
            var generation = UInt64(index + 1).littleEndian
            try tx.write(["session.soak": Data(bytes: &generation, count: MemoryLayout<UInt64>.size)])
            let ciphertext = Data("soak-ciphertext:\(index)".utf8)
            try tx.insertOutbox(
                messageID: messageID,
                recipientDeviceID: UInt32(9 + (index % 2)),
                ciphertext: ciphertext,
                envelope: ciphertext,
                protocolVersion: "v0.106.0"
            )
            try tx.insertDeviceDelivery(
                messageID: messageID,
                recipientDeviceID: UInt32(9 + (index % 2))
            )
            try tx.commit()
        } catch {
            tx.rollback()
            throw error
        }
    }
    guard try store.integrityCheck() == "ok" else { throw ProbeError.assertion("10k integrity") }
    for index in 0..<10_000 {
        guard try store.outbox(messageID: "soak-message-\(index)") != nil else {
            throw ProbeError.assertion("lost committed outbox row \(index)")
        }
    }
}

private func holdLock(_ store: SQLiteAtomicCryptoStore, seconds: UInt32) throws {
    let tx = try store.beginAtomicCryptoTransaction()
    try tx.write(["test.lock-holder": Data([1])])
    print("LOCK_HELD")
    fflush(stdout)
    sleep(seconds)
    tx.rollback()
}

private func diskFull(_ store: SQLiteAtomicCryptoStore) throws {
    try store.limitPageCountForTesting(try store.pageCountForTesting())
    let tx = try store.beginAtomicCryptoTransaction()
    do {
        try tx.write(["session.disk-full": Data(repeating: 0x5a, count: 2 * 1024 * 1024)])
        try tx.insertOutbox(
            messageID: "disk-full", recipientDeviceID: 9,
            ciphertext: Data(repeating: 0x33, count: 512 * 1024),
            envelope: Data(repeating: 0x44, count: 512 * 1024), protocolVersion: "test"
        )
        try tx.commit()
        throw ProbeError.assertion("disk-full transaction unexpectedly committed")
    } catch {
        tx.rollback()
    }
    guard try store.read("session.disk-full") == nil,
          try store.outbox(messageID: "disk-full") == nil else {
        throw ProbeError.assertion("disk-full left partial state")
    }
}

private func syncFailure(_ store: SQLiteAtomicCryptoStore) throws {
    store.injectCommitFailureForTesting(true)
    let tx = try store.beginAtomicCryptoTransaction()
    do {
        try tx.write(["session.sync-failure": Data([1])])
        try tx.insertOutbox(
            messageID: "sync-failure", recipientDeviceID: 9,
            ciphertext: Data([2]), envelope: Data([3]), protocolVersion: "test"
        )
        try tx.commit()
        throw ProbeError.assertion("sync-failure transaction unexpectedly committed")
    } catch {
        tx.rollback()
    }
    store.injectCommitFailureForTesting(false)
    guard try store.read("session.sync-failure") == nil,
          try store.outbox(messageID: "sync-failure") == nil else {
        throw ProbeError.assertion("sync failure left partial state")
    }
}

@main
private enum AtomicityProbe {
  static func main() {
    do {
      let arguments = CommandLine.arguments
      guard arguments.count >= 3 else { throw ProbeError.usage }
      let mode = arguments[1]
      let databaseURL = URL(fileURLWithPath: arguments[2])
      let store = try SQLiteAtomicCryptoStore(databaseURL: databaseURL)
      switch mode {
    case "initialize":
        try initialize(store)
    case "outbound":
        guard arguments.count == 5 else { throw ProbeError.usage }
        try outbound(store, phase: arguments[3], messageID: arguments[4])
    case "verify-outbound":
        guard arguments.count == 4 else { throw ProbeError.usage }
        try verifyOutbound(store, messageID: arguments[3])
    case "inbound":
        guard arguments.count == 5 else { throw ProbeError.usage }
        try inbound(store, phase: arguments[3], messageID: arguments[4])
    case "verify-inbound":
        guard arguments.count == 4 else { throw ProbeError.usage }
        try verifyInbound(store, messageID: arguments[3])
    case "ten-thousand":
        try tenThousand(store)
    case "config":
        print("journal_mode=\(try store.journalMode()) synchronous=\(try store.synchronousMode()) integrity=\(try store.integrityCheck())")
    case "checkpoint":
        try store.checkpoint()
        print("checkpoint=ok integrity=\(try store.integrityCheck())")
    case "hold-lock":
        let seconds = arguments.count > 3 ? UInt32(arguments[3]) ?? 8 : 8
        try holdLock(store, seconds: seconds)
    case "disk-full":
        try diskFull(store)
    case "sync-failure":
        try syncFailure(store)
      default:
          throw ProbeError.usage
      }
    } catch {
      fputs("\(error)\n", stderr)
      exit(2)
    }
  }
}
