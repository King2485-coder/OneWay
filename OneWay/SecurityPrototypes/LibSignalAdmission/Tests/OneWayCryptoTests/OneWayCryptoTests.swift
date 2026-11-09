import XCTest
import LibSignalClient
@testable import OneWayCrypto

final class MemoryIdentitySecrets: IdentitySecretStore {
    var bytes: Data?
    func load() throws -> Data? { bytes }
    func save(_ bytes: Data) throws { self.bytes = bytes }
}

final class RecordingCommittedTransport: CommittedCryptoTransport {
    private let lock = NSLock()
    private(set) var sent: [CommittedOutboundEnvelope] = []

    func send(_ committed: CommittedOutboundEnvelope) throws {
        lock.lock()
        sent.append(committed)
        lock.unlock()
    }
}

final class OneWayCryptoTests: XCTestCase {
    private let context = OneWayStoreContext()
    private let aliceAddress = try! ProtocolAddress(name: "admission-alice", deviceId: 1)
    private let bobAddress = try! ProtocolAddress(name: "admission-bob", deviceId: 9)

    func testIndependentDeviceIdentities() throws {
        let identities = (0..<4).map { _ in IdentityKeyPair.generate().serialize() }
        XCTAssertEqual(Set(identities).count, 4, "each installation must have independent identity material")
    }

    func testSessionRatchetOutOfOrderReplayTamperWrongDeviceAndPersistence() throws {
        let aliceSecrets = MemoryIdentitySecrets()
        let bobSecrets = MemoryIdentitySecrets()
        let aliceBlobs = AdmissionTransactionalBlobStore()
        let bobBlobs = AdmissionTransactionalBlobStore()
        let alice = try OneWaySignalStore(identitySecrets: aliceSecrets, blobs: aliceBlobs, registrationID: 1001)
        let bob = try OneWaySignalStore(identitySecrets: bobSecrets, blobs: bobBlobs, registrationID: 1002)
        let fixture = try establishAliceToBob(alice: alice, bob: bob)

        let firstPlaintext = Data("TEST ONLY: admission message 1".utf8)
        let first = try signalEncrypt(
            message: firstPlaintext,
            for: bobAddress,
            localAddress: aliceAddress,
            sessionStore: alice,
            identityStore: alice,
            context: context
        )
        XCTAssertNotEqual(first.serialize(), firstPlaintext)
        let firstPreKey = try PreKeySignalMessage(bytes: first.serialize())
        let recovered = try signalDecryptPreKey(
            message: firstPreKey,
            from: aliceAddress,
            localAddress: bobAddress,
            sessionStore: bob,
            identityStore: bob,
            preKeyStore: bob,
            signedPreKeyStore: bob,
            kyberPreKeyStore: bob,
            context: context
        )
        XCTAssertEqual(recovered, firstPlaintext)

        XCTAssertThrowsError(try signalDecryptPreKey(
            message: firstPreKey,
            from: aliceAddress,
            localAddress: bobAddress,
            sessionStore: bob,
            identityStore: bob,
            preKeyStore: bob,
            signedPreKeyStore: bob,
            kyberPreKeyStore: bob,
            context: context
        ))

        var tampered = first.serialize()
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
        let tamperedMessage = try PreKeySignalMessage(bytes: tampered)
        XCTAssertThrowsError(try signalDecryptPreKey(
            message: tamperedMessage,
            from: aliceAddress,
            localAddress: bobAddress,
            sessionStore: bob,
            identityStore: bob,
            preKeyStore: bob,
            signedPreKeyStore: bob,
            kyberPreKeyStore: bob,
            context: context
        ))

        let charlie = try OneWaySignalStore(
            identitySecrets: MemoryIdentitySecrets(),
            blobs: AdmissionTransactionalBlobStore(),
            registrationID: 1003
        )
        XCTAssertThrowsError(try signalDecryptPreKey(
            message: firstPreKey,
            from: aliceAddress,
            localAddress: try ProtocolAddress(name: "admission-charlie", deviceId: 7),
            sessionStore: charlie,
            identityStore: charlie,
            preKeyStore: charlie,
            signedPreKeyStore: charlie,
            kyberPreKeyStore: charlie,
            context: context
        ))

        let replyPlaintext = Data("TEST ONLY: acknowledgment".utf8)
        let reply = try signalEncrypt(message: replyPlaintext, for: aliceAddress, localAddress: bobAddress,
                                      sessionStore: bob, identityStore: bob, context: context)
        XCTAssertEqual(reply.messageType, .whisper)
        XCTAssertEqual(
            try signalDecrypt(message: SignalMessage(bytes: reply.serialize()), from: bobAddress, to: aliceAddress,
                              sessionStore: alice, identityStore: alice, context: context),
            replyPlaintext
        )

        let payloads = ["two", "three", "four"].map { Data("TEST ONLY: \($0)".utf8) }
        let messages = try payloads.map {
            try signalEncrypt(message: $0, for: bobAddress, localAddress: aliceAddress,
                              sessionStore: alice, identityStore: alice, context: context)
        }
        let restartedBob = try OneWaySignalStore(
            identitySecrets: bobSecrets,
            blobs: bobBlobs,
            registrationID: 1002
        )
        for index in [2, 0, 1] {
            let signalMessage = try SignalMessage(bytes: messages[index].serialize())
            let clear = try signalDecrypt(
                message: signalMessage,
                from: aliceAddress,
                to: bobAddress,
                sessionStore: restartedBob,
                identityStore: restartedBob,
                context: context
            )
            XCTAssertEqual(clear, payloads[index])
        }
        XCTAssertNotNil(try restartedBob.loadSession(for: aliceAddress, context: context))

        let privateBytes = try bob.identityKeyPair(context: context).privateKey.serialize()
        let serverPayload = try JSONEncoder().encode(fixture.publicEnvelope)
        XCTAssertFalse(serverPayload.range(of: privateBytes) != nil,
                       "SERVER_PRIVATE_IDENTITY_KEY_BYTES_FOUND must remain false")

        let envelope = try DeterministicSignalEnvelope.encode(
            messageID: Data(repeating: 7, count: 16),
            senderDeviceID: 1,
            recipientDeviceID: 9,
            messageType: 2,
            ciphertext: messages[0].serialize()
        )
        XCTAssertNil(envelope.range(of: payloads[0]))
    }

    func testIdentityReplacementIsObservableAndNotTrusted() throws {
        let secrets = MemoryIdentitySecrets()
        let blobs = AdmissionTransactionalBlobStore()
        let store = try OneWaySignalStore(identitySecrets: secrets, blobs: blobs, registrationID: 1)
        let first = IdentityKeyPair.generate().identityKey
        let replacement = IdentityKeyPair.generate().identityKey
        guard case .newOrUnchanged = try store.saveIdentity(first, for: bobAddress, context: context) else {
            return XCTFail("first identity was not admitted")
        }
        guard case .replacedExisting = try store.saveIdentity(replacement, for: bobAddress, context: context) else {
            return XCTFail("replacement identity was not surfaced")
        }
        XCTAssertFalse(try store.isTrustedIdentity(first, for: bobAddress, direction: .receiving, context: context))
        let restarted = try OneWaySignalStore(identitySecrets: secrets, blobs: blobs, registrationID: 1)
        XCTAssertEqual(try restarted.identity(for: bobAddress, context: context), replacement)
    }

    func testTransactionalFailureClosesBeforeCommitAndSurvivesAfterCommit() throws {
        let blobs = AdmissionTransactionalBlobStore()
        for point in [AdmissionTransactionalBlobStore.FailurePoint.diskWrite, .transactionRollback] {
            blobs.failurePoint = point
            XCTAssertThrowsError(try blobs.transaction(["state": Data([1])]))
            XCTAssertNil(try blobs.read("state"))
        }
        blobs.failurePoint = .outboxWrite
        XCTAssertThrowsError(try blobs.transaction(["outbox.pending": Data([2])]))
        XCTAssertNil(try blobs.read("outbox.pending"))
        blobs.failurePoint = .sessionStateWrite
        XCTAssertThrowsError(try blobs.transaction(["session.admission": Data([3])]))
        XCTAssertNil(try blobs.read("session.admission"))
        blobs.failurePoint = .afterCommit
        XCTAssertThrowsError(try blobs.transaction(["state": Data([4])]))
        XCTAssertEqual(try blobs.read("state"), Data([4]))
        blobs.failurePoint = nil
        try blobs.transaction(["outbox": Data([5])])
        XCTAssertEqual(try blobs.read("outbox"), Data([5]))
    }

    func testKeychainRoundTrip() throws {
        let account = "admission-\(UUID().uuidString)"
        let keychain = KeychainIdentitySecretStore(service: "is.oneway.security.libsignal-admission", account: account)
        let sentinel = Data((0..<64).map(UInt8.init))
        try keychain.save(sentinel)
        XCTAssertEqual(try keychain.load(), sentinel)
    }

    func testMultiDeviceFanoutAndRevocationExcludesFutureDelivery() throws {
        let alicePhone = try OneWaySignalStore(identitySecrets: MemoryIdentitySecrets(), blobs: AdmissionTransactionalBlobStore(), registrationID: 2001)
        let aliceTablet = try OneWaySignalStore(identitySecrets: MemoryIdentitySecrets(), blobs: AdmissionTransactionalBlobStore(), registrationID: 2002)
        let bobPhone = try OneWaySignalStore(identitySecrets: MemoryIdentitySecrets(), blobs: AdmissionTransactionalBlobStore(), registrationID: 3001)
        let bobTablet = try OneWaySignalStore(identitySecrets: MemoryIdentitySecrets(), blobs: AdmissionTransactionalBlobStore(), registrationID: 3002)
        let alicePhoneAddress = try ProtocolAddress(name: "alice", deviceId: 1)
        let bobPhoneAddress = try ProtocolAddress(name: "bob", deviceId: 9)
        let bobTabletAddress = try ProtocolAddress(name: "bob", deviceId: 10)

        let identityBytes = try [alicePhone, aliceTablet, bobPhone, bobTablet].map {
            try $0.identityKeyPair(context: context).serialize()
        }
        XCTAssertEqual(Set(identityBytes).count, 4)

        try establishAliceToBob(
            alice: alicePhone, bob: bobPhone, aliceAddress: alicePhoneAddress,
            bobAddress: bobPhoneAddress, recipientDeviceID: 9, idOffset: 0
        )
        try establishAliceToBob(
            alice: alicePhone, bob: bobTablet, aliceAddress: alicePhoneAddress,
            bobAddress: bobTabletAddress, recipientDeviceID: 10, idOffset: 100
        )

        let logicalPlaintext = Data("TEST ONLY: per-device fanout".utf8)
        var deliveries: [UInt32: CiphertextMessage] = [:]
        for (deviceID, address) in [(UInt32(9), bobPhoneAddress), (UInt32(10), bobTabletAddress)] {
            deliveries[deviceID] = try signalEncrypt(
                message: logicalPlaintext, for: address, localAddress: alicePhoneAddress,
                sessionStore: alicePhone, identityStore: alicePhone, context: context
            )
        }
        XCTAssertEqual(deliveries.count, 2)
        XCTAssertNotEqual(deliveries[9]?.serialize(), deliveries[10]?.serialize())
        XCTAssertEqual(
            try signalDecryptPreKey(
                message: PreKeySignalMessage(bytes: try XCTUnwrap(deliveries[9]).serialize()),
                from: alicePhoneAddress, localAddress: bobPhoneAddress,
                sessionStore: bobPhone, identityStore: bobPhone, preKeyStore: bobPhone,
                signedPreKeyStore: bobPhone, kyberPreKeyStore: bobPhone, context: context
            ),
            logicalPlaintext
        )
        XCTAssertEqual(
            try signalDecryptPreKey(
                message: PreKeySignalMessage(bytes: try XCTUnwrap(deliveries[10]).serialize()),
                from: alicePhoneAddress, localAddress: bobTabletAddress,
                sessionStore: bobTablet, identityStore: bobTablet, preKeyStore: bobTablet,
                signedPreKeyStore: bobTablet, kyberPreKeyStore: bobTablet, context: context
            ),
            logicalPlaintext
        )

        var activeBobDevices: [UInt32: ProtocolAddress] = [9: bobPhoneAddress, 10: bobTabletAddress]
        activeBobDevices.removeValue(forKey: 10)
        var postRevocationDeliveries: [UInt32: CiphertextMessage] = [:]
        for (deviceID, address) in activeBobDevices {
            postRevocationDeliveries[deviceID] = try signalEncrypt(
                message: Data("TEST ONLY: after revocation".utf8), for: address,
                localAddress: alicePhoneAddress, sessionStore: alicePhone,
                identityStore: alicePhone, context: context
            )
        }
        XCTAssertEqual(Set(postRevocationDeliveries.keys), Set([UInt32(9)]))
        XCTAssertNil(postRevocationDeliveries[10], "revocation cannot erase old plaintext, but must exclude future delivery")
    }

    func testTenThousandMessageThroughput() throws {
        let identityStart = CFAbsoluteTimeGetCurrent()
        let alice = try OneWaySignalStore(identitySecrets: MemoryIdentitySecrets(), blobs: AdmissionTransactionalBlobStore(), registrationID: 4001)
        let bob = try OneWaySignalStore(identitySecrets: MemoryIdentitySecrets(), blobs: AdmissionTransactionalBlobStore(), registrationID: 4002)
        let identitySeconds = CFAbsoluteTimeGetCurrent() - identityStart

        let sessionStart = CFAbsoluteTimeGetCurrent()
        try establishAliceToBob(alice: alice, bob: bob)
        let bootstrap = try signalEncrypt(
            message: Data("TEST ONLY: bootstrap".utf8), for: bobAddress, localAddress: aliceAddress,
            sessionStore: alice, identityStore: alice, context: context
        )
        _ = try signalDecryptPreKey(
            message: PreKeySignalMessage(bytes: bootstrap.serialize()), from: aliceAddress,
            localAddress: bobAddress, sessionStore: bob, identityStore: bob,
            preKeyStore: bob, signedPreKeyStore: bob, kyberPreKeyStore: bob, context: context
        )
        let reply = try signalEncrypt(
            message: Data("TEST ONLY: reply".utf8), for: aliceAddress, localAddress: bobAddress,
            sessionStore: bob, identityStore: bob, context: context
        )
        _ = try signalDecrypt(
            message: SignalMessage(bytes: reply.serialize()), from: bobAddress, to: aliceAddress,
            sessionStore: alice, identityStore: alice, context: context
        )
        let sessionSeconds = CFAbsoluteTimeGetCurrent() - sessionStart

        let message = Data(repeating: 0x5a, count: 256)
        let throughputStart = CFAbsoluteTimeGetCurrent()
        var encryptionSeconds = 0.0
        var decryptionSeconds = 0.0
        for _ in 0..<10_000 {
            let encryptionStart = CFAbsoluteTimeGetCurrent()
            let ciphertext = try signalEncrypt(
                message: message, for: bobAddress, localAddress: aliceAddress,
                sessionStore: alice, identityStore: alice, context: context
            )
            encryptionSeconds += CFAbsoluteTimeGetCurrent() - encryptionStart
            let decryptionStart = CFAbsoluteTimeGetCurrent()
            let clear = try signalDecrypt(
                message: SignalMessage(bytes: ciphertext.serialize()), from: aliceAddress, to: bobAddress,
                sessionStore: bob, identityStore: bob, context: context
            )
            decryptionSeconds += CFAbsoluteTimeGetCurrent() - decryptionStart
            XCTAssertEqual(clear, message)
        }
        let throughputSeconds = CFAbsoluteTimeGetCurrent() - throughputStart
        let persistenceStart = CFAbsoluteTimeGetCurrent()
        let record = try XCTUnwrap(alice.loadSession(for: bobAddress, context: context))
        for _ in 0..<1_000 { try alice.storeSession(record, for: bobAddress, context: context) }
        let persistenceSeconds = CFAbsoluteTimeGetCurrent() - persistenceStart
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print("LIBSIGNAL_PERF identity_s=\(identitySeconds) session_s=\(sessionSeconds) messages=10000 throughput_s=\(throughputSeconds) msg_per_s=\(10_000 / throughputSeconds) encrypt_mean_ms=\(encryptionSeconds / 10) decrypt_mean_ms=\(decryptionSeconds / 10) persistence_1000_s=\(persistenceSeconds) persistence_mean_ms=\(persistenceSeconds) peak_rss_bytes=\(usage.ru_maxrss)")
    }

    func testDurableOutboundRatchetCiphertextOutboxAndRetryCommitTogether() throws {
        let (durable, directory) = try makeDurableStore()
        defer { durable.closeForTesting(); try? FileManager.default.removeItem(at: directory) }
        let alice = try OneWaySignalStore(
            identitySecrets: MemoryIdentitySecrets(), blobs: durable, registrationID: 5001
        )
        let bob = try OneWaySignalStore(
            identitySecrets: MemoryIdentitySecrets(), blobs: AdmissionTransactionalBlobStore(), registrationID: 5002
        )
        try establishAliceToBob(alice: alice, bob: bob)
        let coordinator = OneWayAtomicMessageCoordinator(store: durable)
        let messageID = "durable-outbound-1"
        var encryptionCount = 0

        let committed = try coordinator.commitOutbound(
            messageID: messageID,
            recipientDeviceID: 9,
            encrypt: { atomicContext in
                encryptionCount += 1
                return try signalEncrypt(
                    message: Data("TEST ONLY: durable outbound".utf8),
                    for: self.bobAddress,
                    localAddress: self.aliceAddress,
                    sessionStore: alice,
                    identityStore: alice,
                    context: atomicContext
                ).serialize()
            },
            makeEnvelope: { ciphertext in
                try DeterministicSignalEnvelope.encode(
                    messageID: Data(repeating: 0x31, count: 16),
                    senderDeviceID: 1,
                    recipientDeviceID: 9,
                    messageType: 2,
                    ciphertext: ciphertext
                )
            }
        )

        XCTAssertEqual(encryptionCount, 1)
        let row = try XCTUnwrap(durable.outbox(messageID: messageID))
        XCTAssertEqual(row.ciphertext, committed.ciphertext)
        XCTAssertEqual(row.envelope, committed.envelope)
        XCTAssertNotNil(try alice.loadSession(for: bobAddress, context: context))

        let duplicate = try coordinator.commitOutbound(
            messageID: messageID,
            recipientDeviceID: 9,
            encrypt: { _ in
                encryptionCount += 1
                return Data("must-not-run".utf8)
            },
            makeEnvelope: { $0 }
        )
        XCTAssertEqual(encryptionCount, 1, "duplicate UUID must not advance the ratchet")
        XCTAssertEqual(duplicate, committed)

        let retry = try XCTUnwrap(coordinator.retryOutbound(messageID: messageID))
        XCTAssertEqual(retry, committed, "retry must reuse committed ciphertext")
        let transport = RecordingCommittedTransport()
        try coordinator.sendCommitted(retry, using: transport)
        XCTAssertEqual(transport.sent, [committed])
        XCTAssertEqual(try durable.outbox(messageID: messageID)?.status, .sentUnknown)
        try coordinator.acknowledgeOutbound(messageID: messageID, recipientDeviceID: 9)
        XCTAssertEqual(try durable.outbox(messageID: messageID)?.status, .acknowledged)
    }

    func testDurableInboundRatchetReplayPlaintextAndAckEligibilityCommitTogether() throws {
        let alice = try OneWaySignalStore(
            identitySecrets: MemoryIdentitySecrets(), blobs: AdmissionTransactionalBlobStore(), registrationID: 5101
        )
        let (durable, directory) = try makeDurableStore()
        defer { durable.closeForTesting(); try? FileManager.default.removeItem(at: directory) }
        let bob = try OneWaySignalStore(
            identitySecrets: MemoryIdentitySecrets(), blobs: durable, registrationID: 5102
        )
        try establishAliceToBob(alice: alice, bob: bob)
        let plaintext = Data("TEST ONLY: durable inbound".utf8)
        let ciphertext = try signalEncrypt(
            message: plaintext,
            for: bobAddress,
            localAddress: aliceAddress,
            sessionStore: alice,
            identityStore: alice,
            context: context
        )
        let serialized = ciphertext.serialize()
        let coordinator = OneWayAtomicMessageCoordinator(store: durable)
        var decryptCount = 0

        let result = try coordinator.commitInbound(
            messageID: "durable-inbound-1",
            senderDeviceID: 1,
            ciphertext: serialized,
            decrypt: { atomicContext in
                decryptCount += 1
                return try signalDecryptPreKey(
                    message: PreKeySignalMessage(bytes: serialized),
                    from: self.aliceAddress,
                    localAddress: self.bobAddress,
                    sessionStore: bob,
                    identityStore: bob,
                    preKeyStore: bob,
                    signedPreKeyStore: bob,
                    kyberPreKeyStore: bob,
                    context: atomicContext
                )
            }
        )
        XCTAssertEqual(result, .committed(CommittedInboundMessage(
            messageID: "durable-inbound-1", senderDeviceID: 1, plaintext: plaintext
        )))
        XCTAssertEqual(decryptCount, 1)
        XCTAssertTrue(try durable.replayExists(messageID: "durable-inbound-1", senderDeviceID: 1))
        let inbox = try XCTUnwrap(durable.inbox(messageID: "durable-inbound-1", senderDeviceID: 1))
        XCTAssertEqual(inbox.plaintext, plaintext)
        XCTAssertTrue(inbox.acknowledgementEligible)

        let duplicate = try coordinator.commitInbound(
            messageID: "durable-inbound-1",
            senderDeviceID: 1,
            ciphertext: serialized,
            decrypt: { _ in
                decryptCount += 1
                return plaintext
            }
        )
        XCTAssertEqual(duplicate, .duplicate)
        XCTAssertEqual(decryptCount, 1, "replay must be rejected before ratchet mutation")
    }

    func testDurableStoreConfigurationAndRestartRecovery() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oneway-atomic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("crypto.sqlite3")

        do {
            let store = try SQLiteAtomicCryptoStore(databaseURL: url)
            XCTAssertEqual(try store.journalMode().lowercased(), "wal")
            XCTAssertEqual(try store.synchronousMode(), 2, "SQLite FULL is numeric value 2")
            let tx = try store.beginAtomicCryptoTransaction()
            try tx.write(["session.restart": Data([7, 8, 9])])
            try tx.insertOutbox(
                messageID: "restart-1", recipientDeviceID: 9,
                ciphertext: Data([1, 2]), envelope: Data([3, 4]), protocolVersion: "test"
            )
            try tx.insertDeviceDelivery(messageID: "restart-1", recipientDeviceID: 9)
            try tx.commit()
            try store.checkpoint()
            XCTAssertEqual(try store.integrityCheck(), "ok")
        }

        let restarted = try SQLiteAtomicCryptoStore(databaseURL: url)
        defer { restarted.closeForTesting(); try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(try restarted.read("session.restart"), Data([7, 8, 9]))
        XCTAssertEqual(try restarted.outbox(messageID: "restart-1")?.envelope, Data([3, 4]))
        XCTAssertEqual(try restarted.integrityCheck(), "ok")
    }

    func testConcurrentAtomicTransactionsSerializeSameSession() throws {
        for iterations in [2, 10, 100] {
            let (durable, directory) = try makeDurableStore()
            defer { durable.closeForTesting(); try? FileManager.default.removeItem(at: directory) }
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "is.oneway.atomic-concurrency.\(iterations)", attributes: .concurrent)
            let resultLock = NSLock()
            var errors: [Error] = []

            for index in 0..<iterations {
                group.enter()
                queue.async {
                    defer { group.leave() }
                    do {
                        let tx = try durable.beginAtomicCryptoTransaction()
                        let currentData = try tx.read("session.concurrent")
                        let current = currentData.flatMap { UInt64(String(decoding: $0, as: UTF8.self)) } ?? 0
                        let next = Data(String(current + 1).utf8)
                        try tx.write(["session.concurrent": next])
                        try tx.insertOutbox(
                            messageID: "concurrent-\(iterations)-\(index)", recipientDeviceID: 9,
                            ciphertext: Data([UInt8(index % 251)]), envelope: Data([UInt8(index % 251)]),
                            protocolVersion: "test"
                        )
                        try tx.insertDeviceDelivery(
                            messageID: "concurrent-\(iterations)-\(index)", recipientDeviceID: 9
                        )
                        try tx.commit()
                    } catch {
                        resultLock.lock()
                        errors.append(error)
                        resultLock.unlock()
                    }
                }
            }
            group.wait()
            XCTAssertTrue(errors.isEmpty, "\(iterations)-way transaction errors: \(errors)")
            let value = try XCTUnwrap(durable.read("session.concurrent"))
            XCTAssertEqual(UInt64(String(decoding: value, as: UTF8.self)), UInt64(iterations))
            for index in 0..<iterations {
                XCTAssertNotNil(try durable.outbox(messageID: "concurrent-\(iterations)-\(index)"))
            }
        }
    }

    func testMalformedPersistedSessionFailsClosed() throws {
        let (durable, directory) = try makeDurableStore()
        defer { durable.closeForTesting(); try? FileManager.default.removeItem(at: directory) }
        let store = try OneWaySignalStore(
            identitySecrets: MemoryIdentitySecrets(), blobs: durable, registrationID: 5201
        )
        try durable.transaction(["session.\(bobAddress)": Data([0xff, 0x00, 0x01])])
        XCTAssertThrowsError(try store.loadSession(for: bobAddress, context: context))
        XCTAssertEqual(try durable.integrityCheck(), "ok")
    }

    func testMultiDeviceTransactionsIsolateOneDeviceFailure() throws {
        let (durable, directory) = try makeDurableStore()
        defer { durable.closeForTesting(); try? FileManager.default.removeItem(at: directory) }

        let phone = try durable.beginAtomicCryptoTransaction()
        try phone.write(["session.bob.9": Data("phone-next".utf8)])
        try phone.insertOutbox(
            messageID: "fanout-phone", recipientDeviceID: 9,
            ciphertext: Data("phone-ciphertext".utf8), envelope: Data("phone-envelope".utf8),
            protocolVersion: "test"
        )
        try phone.insertDeviceDelivery(messageID: "fanout-phone", recipientDeviceID: 9)
        try phone.commit()

        let tablet = try durable.beginAtomicCryptoTransaction()
        try tablet.write(["session.bob.10": Data("tablet-next".utf8)])
        try tablet.insertOutbox(
            messageID: "fanout-tablet", recipientDeviceID: 10,
            ciphertext: Data("tablet-ciphertext".utf8), envelope: Data("tablet-envelope".utf8),
            protocolVersion: "test"
        )
        try tablet.insertDeviceDelivery(messageID: "fanout-tablet", recipientDeviceID: 10)
        tablet.rollback()

        XCTAssertEqual(try durable.read("session.bob.9"), Data("phone-next".utf8))
        XCTAssertNotNil(try durable.outbox(messageID: "fanout-phone"))
        XCTAssertNil(try durable.read("session.bob.10"))
        XCTAssertNil(try durable.outbox(messageID: "fanout-tablet"))
    }

    private func makeDurableStore() throws -> (SQLiteAtomicCryptoStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oneway-atomic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (
            try SQLiteAtomicCryptoStore(databaseURL: directory.appendingPathComponent("crypto.sqlite3")),
            directory
        )
    }

    @discardableResult
    private func establishAliceToBob(
        alice: OneWaySignalStore,
        bob: OneWaySignalStore,
        aliceAddress: ProtocolAddress? = nil,
        bobAddress: ProtocolAddress? = nil,
        recipientDeviceID: UInt32 = 9,
        idOffset: UInt32 = 0
    ) throws
        -> (publicEnvelope: PublicPreKeyEnvelope, bundle: PreKeyBundle)
    {
        let aliceAddress = aliceAddress ?? self.aliceAddress
        let bobAddress = bobAddress ?? self.bobAddress
        let preKeyID = 4570 + idOffset
        let signedPreKeyID = 3006 + idOffset
        let kyberPreKeyID = 8888 + idOffset
        let preKey = PrivateKey.generate()
        let signed = PrivateKey.generate()
        let kyber = KEMKeyPair.generate()
        let identityPair = try bob.identityKeyPair(context: context)
        let signedSignature = identityPair.privateKey.generateSignature(message: signed.publicKey.serialize())
        let kyberSignature = identityPair.privateKey.generateSignature(message: kyber.publicKey.serialize())
        let bundle = try PreKeyBundle(
            registrationId: try bob.localRegistrationId(context: context),
            deviceId: recipientDeviceID,
            prekeyId: preKeyID,
            prekey: preKey.publicKey,
            signedPrekeyId: signedPreKeyID,
            signedPrekey: signed.publicKey,
            signedPrekeySignature: signedSignature,
            identity: identityPair.identityKey,
            kyberPrekeyId: kyberPreKeyID,
            kyberPrekey: kyber.publicKey,
            kyberPrekeySignature: kyberSignature
        )
        try processPreKeyBundle(bundle, for: bobAddress, ourAddress: aliceAddress,
                                sessionStore: alice, identityStore: alice, context: context)
        try bob.storePreKey(PreKeyRecord(id: preKeyID, privateKey: preKey), id: preKeyID, context: context)
        try bob.storeSignedPreKey(
            SignedPreKeyRecord(id: signedPreKeyID, timestamp: 42_000, privateKey: signed, signature: signedSignature),
            id: signedPreKeyID, context: context
        )
        try bob.storeKyberPreKey(
            KyberPreKeyRecord(id: kyberPreKeyID, timestamp: 42_000, keyPair: kyber, signature: kyberSignature),
            id: kyberPreKeyID, context: context
        )
        return (PublicPreKeyEnvelope(
            deviceID: recipientDeviceID,
            registrationID: try bob.localRegistrationId(context: context),
            identityPublicKey: identityPair.identityKey.serialize(),
            signedPreKeyPublic: signed.publicKey.serialize(),
            signedPreKeySignature: signedSignature,
            kyberPreKeyPublic: kyber.publicKey.serialize(),
            kyberPreKeySignature: kyberSignature
        ), bundle)
    }
}
