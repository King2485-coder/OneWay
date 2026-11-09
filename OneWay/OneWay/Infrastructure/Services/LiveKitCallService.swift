import Foundation

#if canImport(CallKit)
import CallKit
#endif
#if canImport(UIKit)
import UIKit
#endif

enum CallFailureReason: String {
    case joinFailed
    case joinTimedOut
    case remoteDeclined
    case remoteEnded
    case remoteNeverJoined
    case signalingUnavailable
    case mediaUnavailable
    case staleBackendEvent
}

private struct EndCallTransaction {
    let operationID: UUID
    let reason: CallEndReason
    let source: CallEndSource
    let startedAt: Date
}

/// Real `CallService` implementation. Composes three pieces that are usually
/// tangled together in sample code:
///
/// 1. `CallSignalingClient` — ring/answer/hangup against your backend.
/// 2. `CallTransport` — the WebRTC stack (LiveKit by default).
/// 3. `CallKitBridge` — system call UI, lock-screen, recents, audio routing.
///
/// Splitting them keeps each replaceable. Want Twilio instead of LiveKit?
/// Implement `CallTransport`. Move signalling to Supabase Realtime? Implement
/// `CallSignalingClient`. The composer here doesn't change.
@MainActor
final class LiveKitCallService: CallService {
    let transport: CallTransport
    private let signaling: CallSignalingClient
    private let bridge: CallKitBridge

    private var sessions: [UUID: CallSession] = [:]
    private var updateContinuations: [UUID: AsyncStream<CallSession>.Continuation] = [:]

    /// Pending credentials per call. Populated when an `accepted` event
    /// arrives for a call we initiated, before `transport.connect` runs.
    private var pendingCredentials: [UUID: CallCredentials] = [:]
    private var mediaConnectedCallIDs: Set<UUID> = []
    private var connectionInFlightCallIDs: Set<UUID> = []
    private var answeredCallIDs: Set<UUID> = []
    private var endingCallIDs: Set<UUID> = []
    private var endTransactions: [UUID: EndCallTransaction] = [:]
    private var completedEndTransactions: [UUID: Date] = [:]
    private var handledAnswerSourcesByCallID: [UUID: Set<CallAnswerSource>] = [:]
    private var suppressCallKitEndUntil: [UUID: Date] = [:]
    private var firstTeardownTriggerByCallID: [UUID: FirstRecipientTeardownTrigger] = [:]
    private var callIDsWithRemoteParticipant: Set<UUID> = []
    private var remoteDepartureTasks: [UUID: Task<Void, Never>] = [:]
    private var terminalStatePollingTasks: [UUID: Task<Void, Never>] = [:]

    init(transport: CallTransport,
         signaling: CallSignalingClient,
         bridge: CallKitBridge) {
        self.transport = transport
        self.signaling = signaling
        self.bridge = bridge
        wireBridge()
        Task { [signaling] in
            await signaling.start()
        }
        Task { [weak self] in await self?.observeTransport() }
        Task { [weak self] in await self?.observeSignaling() }
        Task { [weak self] in await self?.observeForegroundReconciliation() }
    }

    // MARK: - CallService

    func startCall(chatID: UUID, type: CallType) async throws -> CallSession {
        let startedAt = OneWayPerformanceLogger.mark("call.setup", metadata: "chatId=\(chatID.uuidString.lowercased()) type=\(type.rawValue)")
        let provisionalCallID = UUID()
        CallSoundSuppressionController.shared.acquire(callID: provisionalCallID, reason: "outgoing_call_setup_started")
        var session = CallSession(
            id: provisionalCallID,
            chatID: chatID,
            type: type,
            state: .connecting,
            startedAt: Date(),
            participants: [
                CallParticipant(id: UUID(),
                                displayName: "You",
                                isMuted: false,
                                isVideoEnabled: type == .video)
            ],
            muted: false,
            speakerOn: type == .video,
            cameraOn: type == .video,
            isLocal: true
        )
        sessions[provisionalCallID] = session
        publish(session)
        MediaModeCoordinator.shared.activate(mode: type == .video ? .videoCall : .audioCall, sessionId: provisionalCallID)
        let credentials: CallCredentials
        do {
            credentials = try await signaling.invite(
                chatID: chatID,
                callID: provisionalCallID,
                type: type
            )
        } catch {
            finish(provisionalCallID, state: .failed)
            _ = OneWayPerformanceLogger.finish("call.setup", startedAt: startedAt, target: .callSetup, metadata: "chatId=\(chatID.uuidString.lowercased())", cause: PrivacyLog.redact(error.localizedDescription))
            throw error
        }

        let callID = credentials.callID ?? provisionalCallID
        if callID != provisionalCallID {
            CallSoundSuppressionController.shared.transfer(from: provisionalCallID, to: callID, reason: "backend_canonical_call_id_received")
            sessions.removeValue(forKey: provisionalCallID)
            MediaModeCoordinator.shared.activate(mode: type == .video ? .videoCall : .audioCall, sessionId: callID)
            MediaModeCoordinator.shared.deactivate(mode: type == .video ? .videoCall : .audioCall, sessionId: provisionalCallID)
        }
        session = CallSession(
            id: callID,
            chatID: session.chatID,
            type: session.type,
            state: .ringing,
            startedAt: session.startedAt,
            participants: session.participants,
            muted: session.muted,
            speakerOn: session.speakerOn,
            cameraOn: session.cameraOn,
            isLocal: session.isLocal
        )
        sessions[callID] = session
        publish(session)

        do {
            // Tell the system we're starting an outbound call before any media work
            // — this is what gets the call into Recents and keeps audio alive in
            // the background.
            try await bridge.reportOutboundCallStarted(uuid: callID,
                                                       handle: oneWayCallHandle(for: type),
                                                       hasVideo: type == .video)
            session.state = .waitingForAudioActivation
            sessions[callID] = session
            publish(session)
            try await bridge.waitForAudioSessionActivation(callId: callID, timeoutSeconds: 8, lifecycleState: session.state)
            CallAudioActivationCoordinator.shared.logAudioSequence("call.livekit.connect.allowed", callId: callID, callKitUUID: callID, lifecycleState: session.state)

            // Join media early so the caller is ready as soon as the peer
            // accepts, but do not mark the call connected until the backend
            // sends the canonical `call:accepted` event.
            session.state = .joining
            sessions[callID] = session
            publish(session)

            CallAudioActivationCoordinator.shared.logAudioSequence("call.livekit.connect.started", callId: callID, callKitUUID: callID, lifecycleState: session.state)
            let media = try await transport.connect(roomURL: credentials.roomURL,
                                                    token: credentials.token,
                                                    iceServers: credentials.iceServers,
                                                    video: type == .video)
            CallAudioActivationCoordinator.shared.logAudioSequence("call.livekit.connected", callId: callID, callKitUUID: callID, lifecycleState: session.state)
            CallAudioActivationCoordinator.shared.logAudioSequence("call.audio.microphone.published", callId: callID, callKitUUID: callID, lifecycleState: session.state)
            logMediaReady(callID: callID, media: media, role: "caller")
            try? await signaling.mediaReady(
                callID: callID,
                audioPublished: media.microphonePublished,
                videoPublished: media.cameraPublished
            )
            mediaConnectedCallIDs.insert(callID)
            session.state = .connecting
            sessions[callID] = session
            publish(session)
            _ = OneWayPerformanceLogger.finish("call.setup", startedAt: startedAt, target: .callSetup, metadata: "chatId=\(chatID.uuidString.lowercased()) callId=\(callID.uuidString.lowercased())")
            return session
        } catch {
            try? await signaling.hangup(callID: callID, reason: .failed, source: .systemInterruption, operationID: UUID())
            await transport.disconnect()
            try? await bridge.endCall(uuid: callID)
            finish(callID, state: .failed)
            _ = OneWayPerformanceLogger.finish("call.setup", startedAt: startedAt, target: .callSetup, metadata: "chatId=\(chatID.uuidString.lowercased()) callId=\(callID.uuidString.lowercased())", cause: PrivacyLog.redact(error.localizedDescription))
            throw error
        }
    }

    /// Takes ownership of a call already created by `/calls/start`. This is
    /// used by keypad resolution and deliberately follows the same session,
    /// transport, signaling and CallKit path as every other OneWay call.
    func adoptOutgoingCall(sessionID: UUID, chatID: UUID, type: CallType) async throws -> CallSession {
        CallSoundSuppressionController.shared.acquire(callID: sessionID, reason: "outgoing_call_adopted")
        var session = CallSession(
            id: sessionID,
            chatID: chatID,
            type: type,
            state: .ringing,
            startedAt: Date(),
            participants: [
                CallParticipant(
                    id: UUID(),
                    displayName: "You",
                    isMuted: false,
                    isVideoEnabled: type == .video
                )
            ],
            muted: false,
            speakerOn: type == .video,
            cameraOn: type == .video,
            isLocal: true
        )
        sessions[sessionID] = session
        publish(session)
        MediaModeCoordinator.shared.activate(mode: type == .video ? .videoCall : .audioCall, sessionId: sessionID)

        do {
            let credentials = try await signaling.join(callID: sessionID)
            try await bridge.reportOutboundCallStarted(
                uuid: sessionID,
                handle: oneWayCallHandle(for: type),
                hasVideo: type == .video
            )
            session.state = .waitingForAudioActivation
            sessions[sessionID] = session
            publish(session)
            try await bridge.waitForAudioSessionActivation(callId: sessionID, timeoutSeconds: 8, lifecycleState: session.state)
            session.state = .joining
            sessions[sessionID] = session
            publish(session)
            let media = try await transport.connect(
                roomURL: credentials.roomURL,
                token: credentials.token,
                iceServers: credentials.iceServers,
                video: type == .video
            )
            try? await signaling.mediaReady(
                callID: sessionID,
                audioPublished: media.microphonePublished,
                videoPublished: media.cameraPublished
            )
            mediaConnectedCallIDs.insert(sessionID)
            session.state = .connecting
            sessions[sessionID] = session
            publish(session)
            return session
        } catch {
            try? await signaling.hangup(
                callID: sessionID,
                reason: .failed,
                source: .systemInterruption,
                operationID: UUID()
            )
            await transport.disconnect()
            try? await bridge.endCall(uuid: sessionID)
            finish(sessionID, state: .failed)
            throw error
        }
    }

    func answerCall(sessionID: UUID) async throws {
        try await answerIncomingCall(sessionID: sessionID, source: .inApp)
    }

    func answerIncomingCall(sessionID: UUID, source: CallAnswerSource) async throws {
        let operationID = UUID()
        CallSoundSuppressionController.shared.acquire(callID: sessionID, reason: "answer_call:\(source.rawValue)")
        handledAnswerSourcesByCallID[sessionID, default: []].insert(source)
        logCallSoundPolicyEvent("CALL_ANSWER_SOUND_GUARD_CONFIRMED", callID: sessionID, state: sessions[sessionID]?.state, detail: "suppressionActive=\(CallSoundSuppressionController.shared.isSuppressionActive)")
        logCallSoundPolicyEvent("ANSWER_CALL", callID: sessionID, state: sessions[sessionID]?.state, detail: "manualSoundPlayback=none")
        logVideoAnswer("video.answer.requested", callID: sessionID, source: source, operationID: operationID, state: sessions[sessionID]?.state)

        if answeredCallIDs.contains(sessionID) || mediaConnectedCallIDs.contains(sessionID) || sessions[sessionID]?.state == .connected {
            logVideoAnswer("video.answer.deduplicated", callID: sessionID, source: source, operationID: operationID, state: sessions[sessionID]?.state)
            return
        }
        if connectionInFlightCallIDs.contains(sessionID) {
            #if DEBUG
            print("📞 OneWay video accept ignored; connection already in flight:", PrivacyLog.shortID(sessionID.uuidString))
            #endif
            logVideoAnswer("video.answer.deduplicated", callID: sessionID, source: source, operationID: operationID, state: sessions[sessionID]?.state)
            return
        }
        guard var session = sessions[sessionID] else { return }
        MediaModeCoordinator.shared.activate(mode: session.type == .video ? .videoCall : .audioCall, sessionId: sessionID)
        answeredCallIDs.insert(sessionID)
        connectionInFlightCallIDs.insert(sessionID)
        defer { connectionInFlightCallIDs.remove(sessionID) }
        #if DEBUG
        print("📞 OneWay video accept started:", PrivacyLog.shortID(sessionID.uuidString))
        #endif
        session.state = .waitingForAudioActivation
        sessions[sessionID] = session
        publish(session)

        do {
            let credentials = try await signaling.accept(callID: sessionID)
            suppressCallKitEndUntil[sessionID] = Date().addingTimeInterval(15)
            logVideoAnswer("video.answer.backendAccepted", callID: sessionID, source: source, operationID: operationID, state: session.state)
            #if DEBUG
            print("📞 OneWay video accept credentials:", PrivacyLog.shortID(sessionID.uuidString), PrivacyLog.redactURL(credentials.roomURL))
            #endif
            logVideoAnswer("video.answer.callKitSynchronized", callID: sessionID, source: source, operationID: operationID, state: session.state)
            try await bridge.waitForAudioSessionActivation(callId: sessionID, timeoutSeconds: 8, lifecycleState: session.state)
            CallAudioActivationCoordinator.shared.logAudioSequence("call.livekit.connect.allowed", callId: sessionID, callKitUUID: sessionID, lifecycleState: session.state)
            session.state = .joining
            sessions[sessionID] = session
            publish(session)
            logVideoAnswer("video.answer.mediaConnecting", callID: sessionID, source: source, operationID: operationID, state: session.state)
            CallAudioActivationCoordinator.shared.logAudioSequence("call.livekit.connect.started", callId: sessionID, callKitUUID: sessionID, lifecycleState: session.state)
            let media = try await transport.connect(roomURL: credentials.roomURL,
                                                    token: credentials.token,
                                                    iceServers: credentials.iceServers,
                                                    video: session.type == .video)
            CallAudioActivationCoordinator.shared.logAudioSequence("call.livekit.connected", callId: sessionID, callKitUUID: sessionID, lifecycleState: session.state)
            CallAudioActivationCoordinator.shared.logAudioSequence("call.audio.microphone.published", callId: sessionID, callKitUUID: sessionID, lifecycleState: session.state)
            logMediaReady(callID: sessionID, media: media, role: "recipient")
            try? await signaling.mediaReady(
                callID: sessionID,
                audioPublished: media.microphonePublished,
                videoPublished: media.cameraPublished
            )
            mediaConnectedCallIDs.insert(sessionID)
            guard media.microphonePublished else {
                logVideoAnswer("recipient.media.notReady", callID: sessionID, source: source, operationID: operationID, state: session.state)
                mutate(sessionID) { $0.state = .connecting }
                return
            }
            logVideoAnswer("video.recipient.waitingForRemoteMedia", callID: sessionID, source: source, operationID: operationID, state: session.state)
            let remotePresent = await transport.waitForRemoteParticipant(timeoutSeconds: 30)
            guard remotePresent else {
                logVideoAnswer("video.recipient.remoteParticipantTimeout", callID: sessionID, source: source, operationID: operationID, state: session.state)
                mutate(sessionID) { $0.state = .connecting }
                return
            }
            bridge.reportConnected(uuid: sessionID)
            suppressCallKitEndUntil[sessionID] = Date().addingTimeInterval(5)
            session.state = .connected
            sessions[sessionID] = session
            publish(session)
            startTerminalStatePolling(callID: sessionID)
            logCallSoundPolicyEvent("CALL_CONNECTED_SOUND_GUARD_CONFIRMED", callID: sessionID, state: session.state, detail: "suppressionActive=\(CallSoundSuppressionController.shared.isSuppressionActive)")
            logCallSoundPolicyEvent("CALL_CONNECTED", callID: sessionID, state: session.state, detail: "manualSoundPlayback=none")
            logVideoAnswer("video.answer.completed", callID: sessionID, source: source, operationID: operationID, state: session.state)
            #if DEBUG
            print("✅ OneWay video accepted and connected:", PrivacyLog.shortID(sessionID.uuidString))
            #endif
        } catch {
            #if DEBUG
            print("❌ OneWay video accept failed:", PrivacyLog.shortID(sessionID.uuidString), PrivacyLog.redact(error.localizedDescription))
            #endif
            recordRecipientTeardownAttempt(
                callID: sessionID,
                component: "LiveKitCallService.answerIncomingCall.catch",
                reason: "answer flow threw before completion: \(error.localizedDescription)",
                endTapped: false
            )
            #if DEBUG
            if isActiveMediaState(sessions[sessionID]?.state) {
                logAutomaticCallEndBlocked(callID: sessionID, reason: .failed, source: .systemInterruption, operationID: operationID, component: "LiveKitCallService.answerIncomingCall.catch")
                mutate(sessionID) { $0.state = .reconnecting }
                return
            }
            #endif
            await transport.disconnect()
            try? await bridge.endCall(uuid: sessionID)
            answeredCallIDs.remove(sessionID)
            finish(sessionID, state: .failed)
            throw error
        }
    }

    func declineCall(sessionID: UUID) async throws {
        try? await signaling.decline(callID: sessionID)
        try? await bridge.endCall(uuid: sessionID)
        finish(sessionID, state: .ended)
    }

    func endCall(sessionID: UUID) async throws {
        try await endCall(sessionID: sessionID, reason: .localHangup, source: .inCallButton)
    }

    func endCall(sessionID: UUID, reason: CallEndReason, source: CallEndSource) async throws {
        let operationID = UUID()
        CallSoundSuppressionController.shared.acquire(callID: sessionID, reason: "end_call_guard:\(reason.rawValue):\(source.rawValue)")
        logCallSoundPolicyEvent("CALL_END_SOUND_GUARD_CONFIRMED", callID: sessionID, state: sessions[sessionID]?.state, detail: "source=\(source.rawValue) suppressionActive=\(CallSoundSuppressionController.shared.isSuppressionActive)")
        logCallSoundPolicyEvent("CALL_ENDED", callID: sessionID, state: sessions[sessionID]?.state, detail: "reason=\(reason.rawValue) source=\(source.rawValue) manualSoundPlayback=none")
        recordRecipientTeardownAttempt(
            callID: sessionID,
            component: "LiveKitCallService.endCall",
            reason: "\(reason.rawValue):\(source.rawValue)",
            endTapped: source == .inCallButton || source == .notificationAction
        )
        if shouldBlockAutomaticEnd(callID: sessionID, reason: reason, source: source) {
            logAutomaticCallEndBlocked(callID: sessionID, reason: reason, source: source, operationID: operationID, component: "LiveKitCallService.endCall")
            return
        }
        if source == .callKit, shouldSuppressTransientCallKitEnd(callID: sessionID) {
            logVideoEnd("video.end.ignored", callID: sessionID, reason: reason, source: source, operationID: operationID, state: sessions[sessionID]?.state)
            return
        }
        if let completedAt = completedEndTransactions[sessionID],
           Date().timeIntervalSince(completedAt) < 30 {
            logDuplicateEndIgnored(
                callID: sessionID,
                reason: reason,
                source: source,
                attemptedOperationID: operationID,
                existingTransaction: EndCallTransaction(operationID: operationID, reason: reason, source: source, startedAt: completedAt)
            )
            logUnifiedEnd("DUPLICATE_END_JOINED_EXISTING_TRANSACTION", callID: sessionID, source: source, reason: reason, operationID: operationID, endedByUserId: nil, state: sessions[sessionID]?.state)
            return
        }
        if endingCallIDs.contains(sessionID) {
            if let transaction = endTransactions[sessionID] {
                logDuplicateEndIgnored(
                    callID: sessionID,
                    reason: reason,
                    source: source,
                    attemptedOperationID: operationID,
                    existingTransaction: transaction
                )
            }
            logUnifiedEnd("DUPLICATE_END_JOINED_EXISTING_TRANSACTION", callID: sessionID, source: source, reason: reason, operationID: operationID, endedByUserId: nil, state: sessions[sessionID]?.state)
            logVideoEnd("video.end.deduplicated", callID: sessionID, reason: reason, source: source, operationID: operationID, state: sessions[sessionID]?.state)
            return
        }
        logUnifiedEnd("UNIFIED_END_REQUESTED", callID: sessionID, source: source, reason: reason, operationID: operationID, endedByUserId: AuthTokenStore.shared.currentUserID(), state: sessions[sessionID]?.state)
        endingCallIDs.insert(sessionID)
        endTransactions[sessionID] = EndCallTransaction(operationID: operationID, reason: reason, source: source, startedAt: Date())
        logUnifiedEnd("UNIFIED_END_TRANSACTION_CREATED", callID: sessionID, source: source, reason: reason, operationID: operationID, endedByUserId: AuthTokenStore.shared.currentUserID(), state: sessions[sessionID]?.state)
        logVideoEnd("video.end.requested", callID: sessionID, reason: reason, source: source, operationID: operationID, state: sessions[sessionID]?.state)

        if sessions[sessionID] != nil {
            mutate(sessionID) { $0.state = .ended }
        }

        // Start the authoritative backend hang-up before disconnecting LiveKit.
        // The backend fans `call:ended` out to both participants, so this keeps
        // the other phone from waiting on local media teardown to finish.
        async let initialBackendHangup: Void = signaling.hangup(
            callID: sessionID,
            reason: reason,
            source: source,
            operationID: operationID
        )

        await stopLocalMedia(callID: sessionID, reason: reason, source: source, operationID: operationID)
        logUnifiedEnd("UNIFIED_END_LIVEKIT_COMPLETED", callID: sessionID, source: source, reason: reason, operationID: operationID, endedByUserId: AuthTokenStore.shared.currentUserID(), state: sessions[sessionID]?.state)

        do {
            try await initialBackendHangup
        } catch {
            // Reuse the operation ID so the server treats this as an
            // idempotent replay if the first response was lost after commit.
            logUnifiedEnd("UNIFIED_END_BACKEND_RETRY", callID: sessionID, source: source, reason: reason, operationID: operationID, endedByUserId: AuthTokenStore.shared.currentUserID(), state: sessions[sessionID]?.state)
            try? await signaling.hangup(
                callID: sessionID,
                reason: reason,
                source: source,
                operationID: operationID
            )
        }
        logUnifiedEnd("UNIFIED_END_BACKEND_SENT", callID: sessionID, source: source, reason: reason, operationID: operationID, endedByUserId: AuthTokenStore.shared.currentUserID(), state: sessions[sessionID]?.state)
        logVideoEnd("video.end.backendUpdated", callID: sessionID, reason: reason, source: source, operationID: operationID, state: sessions[sessionID]?.state)
        if source != .callKit {
            try? await bridge.terminateLocalCallKit(callID: sessionID, source: source, operationID: operationID)
            logVideoEnd("video.end.callKitEnded", callID: sessionID, reason: reason, source: source, operationID: operationID, state: sessions[sessionID]?.state)
        } else {
            logUnifiedEnd("UNIFIED_END_CALLKIT_COMPLETED", callID: sessionID, source: source, reason: reason, operationID: operationID, endedByUserId: AuthTokenStore.shared.currentUserID(), state: sessions[sessionID]?.state)
        }
        finish(sessionID, state: .ended)
        logUnifiedEnd("UNIFIED_END_UI_DISMISSED", callID: sessionID, source: source, reason: reason, operationID: operationID, endedByUserId: AuthTokenStore.shared.currentUserID(), state: nil)
        endingCallIDs.remove(sessionID)
        endTransactions.removeValue(forKey: sessionID)
        completedEndTransactions[sessionID] = Date()
        logUnifiedEnd("UNIFIED_END_COMPLETED", callID: sessionID, source: source, reason: reason, operationID: operationID, endedByUserId: AuthTokenStore.shared.currentUserID(), state: nil)
        logVideoEnd("video.end.completed", callID: sessionID, reason: reason, source: source, operationID: operationID, state: nil)
    }

    func toggleMute(sessionID: UUID, isMuted: Bool) async throws {
        try await transport.setMicrophoneEnabled(!isMuted)
        try await bridge.setMuted(uuid: sessionID, muted: isMuted)
        mutate(sessionID) { $0.muted = isMuted }
    }

    func toggleSpeaker(sessionID: UUID, isOn: Bool) async throws {
        // AVAudioSession route override. Kept inside `CallTransport` for now;
        // wire to `try AVAudioSession.sharedInstance().overrideOutputAudioPort(...)`
        // when you want a real speakerphone toggle.
        mutate(sessionID) { $0.speakerOn = isOn }
    }

    func toggleCamera(sessionID: UUID, isOn: Bool) async throws {
        try await transport.setCameraEnabled(isOn)
        mutate(sessionID) { $0.cameraOn = isOn }
    }

    func switchCamera(sessionID: UUID) async throws {
        try await transport.switchCamera()
    }

    func observeActiveCalls() -> AsyncStream<CallSession> {
        let observerID = UUID()
        return AsyncStream { continuation in
            sessions.values.forEach { continuation.yield($0) }
            updateContinuations[observerID] = continuation
            continuation.onTermination = { [weak self] _ in
                guard let service = self else { return }
                Task { @MainActor in
                    service.removeUpdateContinuation(observerID)
                }
            }
        }
    }

    /// Push-driven incoming call: build a placeholder session before the
    /// matching `call:ringing` WebSocket event arrives. Idempotent — a later
    /// `handleIncomingRing` upgrades the record without losing CallKit state.
    func prepareIncomingCall(callID: UUID, callerID: String, hasVideo: Bool, roomName: String?) {
        CallSoundSuppressionController.shared.acquire(callID: callID, reason: "incoming_voip_push_recognized")
        if sessions[callID] != nil { return }
        let chatID = UUID(uuidString: callerID) ?? UUID()
        let session = CallSession(
            id: callID,
            chatID: chatID,
            type: hasVideo ? .video : .voice,
            state: .ringing,
            startedAt: Date(),
            participants: [],
            muted: false,
            speakerOn: hasVideo,
            cameraOn: hasVideo,
            isLocal: false
        )
        sessions[callID] = session
        publish(session)
    }

    func cancelPendingIncomingCall(callID: UUID) {
        finish(callID, state: .failed)
    }

    // MARK: - Internals

    private func wireBridge() {
        bridge.onAnswer = { [weak self] uuid in
            guard let self else { return }
            do {
                try await self.answerIncomingCall(sessionID: uuid, source: .callKit)
            } catch {
                #if DEBUG
                print("❌ OneWay CallKit answer failed:", PrivacyLog.shortID(uuid.uuidString), PrivacyLog.redact(error.localizedDescription))
                #endif
            }
        }
        bridge.onEnd = { [weak self] uuid in
            guard let self else { return }
            if self.shouldSuppressTransientCallKitEnd(callID: uuid) {
                #if DEBUG
                print(
                    "video.call.end.ignored",
                    "callId=\(PrivacyLog.shortID(uuid.uuidString))",
                    "source=callKit",
                    "reason=transient_callkit_end_during_connect",
                    "state=\(self.sessions[uuid]?.state.rawValue ?? "nil")",
                    "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
                )
                #endif
                return
            }
            try? await self.endCall(sessionID: uuid, reason: .localHangup, source: .callKit)
        }
        bridge.onMute = { [weak self] uuid, muted in
            guard let self else { return }
            Task { try? await self.toggleMute(sessionID: uuid, isMuted: muted) }
        }
        bridge.onProviderReset = { [weak self] in
            guard let self else { return }
            // System killed all calls (e.g. the OS reset the provider). Drop
            // every active session so the UI doesn't hold a ghost. Snapshot
            // the keys first — `finish` mutates the dictionary.
            for id in Array(self.sessions.keys) {
                if self.isActiveMediaState(self.sessions[id]?.state) {
                    self.logAutomaticCallEndBlocked(callID: id, reason: .failed, source: .systemInterruption, operationID: UUID(), component: "CallKitBridge.providerDidReset")
                    continue
                }
                self.finish(id, state: .ended)
            }
        }
    }

    private func observeSignaling() async {
        for await event in signaling.incomingEvents {
            logSignalingEvent("call.signaling.event.received", event: event, rejectionReason: nil)
            switch event {
            case .ringing(let ring):
                await handleIncomingRing(ring)
            case .accepted(let callID, let credentials):
                logSignalingEvent("call.signaling.event.validated", event: event, rejectionReason: nil)
                await handleRemoteAccepted(callID: callID, credentials: credentials)
            case .declined(let callID):
                guard validateBackendTerminalEvent(callID: callID, reason: .remoteDeclined, event: event) else { continue }
                logSignalingEvent("call.signaling.event.applied", event: event, rejectionReason: nil)
                await handleValidatedBackendTerminalEvent(
                    callID: callID,
                    endReason: .declined,
                    finalState: .ended,
                    event: event
                )
            case .ended(let callID, let reason, let metadata):
                if metadata.endedByUserId == nil,
                   metadata.operationId?.caseInsensitiveCompare(endTransactions[callID]?.operationID.uuidString ?? "") != .orderedSame {
                    await reconcileBackendState(callID: callID, trigger: "call_ended_missing_endedByUserId")
                    continue
                }
                let failureReason: CallFailureReason = {
                    switch reason {
                    case .missed: return .remoteNeverJoined
                    case .failed: return .signalingUnavailable
                    case .ended: return .remoteEnded
                    }
                }()
                guard decideBackendEndEvent(callID: callID, reason: failureReason, metadata: metadata, event: event) else { continue }
                let state: CallConnectionState = {
                    switch reason {
                    case .missed:  return .missed
                    case .failed:  return .failed
                    case .ended:   return .ended
                    }
                }()
                logBackendEndMetadata(callID: callID, metadata: metadata)
                logSignalingEvent("call.signaling.event.applied", event: event, rejectionReason: nil)
                await handleValidatedBackendTerminalEvent(
                    callID: callID,
                    endReason: .remoteHangup,
                    finalState: state,
                    event: event
                )
            case .state(let callID, let status):
                if isTerminalBackendStatus(status) {
                    await reconcileBackendState(callID: callID, trigger: "terminal_state_event:\(status)")
                }
            case .presence:
                // Informational only — UI surfaces presence elsewhere.
                break
            case .signal:
                // LiveKit handles media negotiation internally; ignore raw
                // WebRTC signalling relays when using the LiveKit transport.
                break
            }
        }
    }

    /// A remote user is calling us. Build a session record, surface CallKit's
    /// system ring, but DO NOT auto-join LiveKit. The user must accept first;
    /// `bridge.onAnswer` will run `answerCall` which fetches credentials.
    private func handleIncomingRing(_ ring: SignalingEvent.IncomingRing) async {
        CallSoundSuppressionController.shared.acquire(callID: ring.callID, reason: "incoming_ring_event_received")
        if sessions[ring.callID] != nil {
            return
        }

        #if DEBUG
        print("📞 OneWay incoming ring:", PrivacyLog.shortID(ring.callID.uuidString), "caller:", PrivacyLog.shortID(ring.callerID), "video:", ring.hasVideo)
        #endif
        let chatID = UUID(uuidString: ring.callerID) ?? UUID()
        let session = CallSession(
            id: ring.callID,
            chatID: chatID,
            type: ring.hasVideo ? .video : .voice,
            state: .ringing,
            startedAt: Date(),
            participants: [],
            muted: false,
            speakerOn: ring.hasVideo,
            cameraOn: ring.hasVideo,
            isLocal: false
        )
        MediaModeCoordinator.shared.activate(mode: ring.hasVideo ? .videoCall : .audioCall, sessionId: ring.callID)
        sessions[ring.callID] = session
        publish(session)
        do {
            try await bridge.reportIncomingCall(uuid: ring.callID,
                                                handle: oneWayCallHandle(for: ring.hasVideo ? .video : .voice),
                                                hasVideo: ring.hasVideo)
        } catch {
            // CallKit refused the report (rare — e.g. provider not configured).
            // Drop the session quietly so the user isn't stuck looking at a
            // phantom ringing UI.
            finish(ring.callID, state: .failed)
        }
    }

    /// The callee accepted a call we placed. In most flows the caller is
    /// already connected to the LiveKit room (we connected during `startCall`)
    /// — in that case this is purely informational. We only attempt to
    /// connect if no session has reached `.connected` yet (defensive against
    /// retries after a transient failure).
    private func handleRemoteAccepted(callID: UUID, credentials: CallCredentials) async {
        guard var session = sessions[callID] else { return }
        #if DEBUG
        print("📞 OneWay remote accepted:", PrivacyLog.shortID(callID.uuidString), PrivacyLog.redactURL(credentials.roomURL))
        #endif
        if session.state == .connected {
            return
        }
        if connectionInFlightCallIDs.contains(callID) {
            #if DEBUG
            print("📞 OneWay remote accepted ignored; connection already in flight:", PrivacyLog.shortID(callID.uuidString))
            #endif
            return
        }
        connectionInFlightCallIDs.insert(callID)
        defer { connectionInFlightCallIDs.remove(callID) }
        pendingCredentials[callID] = credentials
        session.state = .connecting
        sessions[callID] = session
        publish(session)
        do {
            if !mediaConnectedCallIDs.contains(callID) {
                suppressCallKitEndUntil[callID] = Date().addingTimeInterval(15)
                let media = try await transport.connect(roomURL: credentials.roomURL,
                                                        token: credentials.token,
                                                        iceServers: credentials.iceServers,
                                                        video: session.type == .video)
                logMediaReady(callID: callID, media: media, role: "caller")
                try? await signaling.mediaReady(
                    callID: callID,
                    audioPublished: media.microphonePublished,
                    videoPublished: media.cameraPublished
                )
                mediaConnectedCallIDs.insert(callID)
                guard media.microphonePublished else {
                    mutate(callID) { $0.state = .reconnecting }
                    pendingCredentials.removeValue(forKey: callID)
                    return
                }
            }
            logVideoEnd("video.caller.waitingForRemoteMedia", callID: callID, reason: .localHangup, source: .backendEvent, operationID: UUID(), state: session.state)
            let remotePresent = await transport.waitForRemoteParticipant(timeoutSeconds: 30)
            guard remotePresent else {
                #if DEBUG
                print(
                    "video.caller.remoteParticipantTimeout",
                    "callId=\(PrivacyLog.shortID(callID.uuidString))",
                    "state=\(sessions[callID]?.state.rawValue ?? "nil")",
                    "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
                )
                #endif
                mutate(callID) { $0.state = .reconnecting }
                pendingCredentials.removeValue(forKey: callID)
                return
            }
            bridge.reportConnected(uuid: callID)
            suppressCallKitEndUntil[callID] = Date().addingTimeInterval(5)
            mutate(callID) { $0.state = .connected }
            startTerminalStatePolling(callID: callID)
            logCallSoundPolicyEvent("CALL_CONNECTED_SOUND_GUARD_CONFIRMED", callID: callID, state: sessions[callID]?.state, detail: "suppressionActive=\(CallSoundSuppressionController.shared.isSuppressionActive)")
            logCallSoundPolicyEvent("CALL_CONNECTED", callID: callID, state: sessions[callID]?.state, detail: "manualSoundPlayback=none")
        } catch {
            #if DEBUG
            print("❌ OneWay remote accepted connect failed:", PrivacyLog.shortID(callID.uuidString), PrivacyLog.redact(error.localizedDescription))
            #endif
            recordRecipientTeardownAttempt(
                callID: callID,
                component: "LiveKitCallService.handleRemoteAccepted.catch",
                reason: "remote accepted media connect failed: \(error.localizedDescription)",
                endTapped: false
            )
            finish(callID, state: .failed)
            try? await bridge.endCall(uuid: callID)
        }
        pendingCredentials.removeValue(forKey: callID)
    }

    private func observeTransport() async {
        for await participants in transport.participantUpdates {
            // Mirror remote-participant deltas into whichever session is
            // currently connected. The simple case: at most one active call.
            guard let id = sessions.first(where: { element in
                let session = element.value
                return session.state == .connecting
                    || session.state == .connected
                    || session.state == .reconnecting
            })?.key else {
                continue
            }
            mutate(id) { $0.participants = participants }
            if participants.isEmpty {
                guard callIDsWithRemoteParticipant.contains(id),
                      sessions[id]?.state == .connected else {
                    continue
                }
                scheduleRemoteDepartureFallback(callID: id)
            } else {
                callIDsWithRemoteParticipant.insert(id)
                remoteDepartureTasks.removeValue(forKey: id)?.cancel()
            }
        }
    }

    /// `call:ended` is the authoritative end signal, but a phone can miss that
    /// WebSocket event while LiveKit still immediately reports that its peer
    /// left the room. After a short grace period, reconcile once more and then
    /// tear down the surviving phone through the same CallKit/media/UI path.
    /// The guard requiring a previously-present remote participant prevents an
    /// empty room during initial connection from being mistaken for a hangup.
    private func scheduleRemoteDepartureFallback(callID: UUID) {
        remoteDepartureTasks.removeValue(forKey: callID)?.cancel()
        remoteDepartureTasks[callID] = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reconcileBackendState(callID: callID, trigger: "livekit_remote_participant_departed")
            guard self.sessions[callID] != nil else {
                self.remoteDepartureTasks.removeValue(forKey: callID)
                return
            }

            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled,
                  self.callIDsWithRemoteParticipant.contains(callID),
                  self.sessions[callID]?.state == .connected else {
                self.remoteDepartureTasks.removeValue(forKey: callID)
                return
            }

            await self.reconcileBackendState(callID: callID, trigger: "livekit_remote_participant_departed_grace_expired")
            guard self.sessions[callID]?.state == .connected else {
                self.remoteDepartureTasks.removeValue(forKey: callID)
                return
            }

            let operationID = UUID()
            try? await self.signaling.hangup(
                callID: callID,
                reason: .remoteHangup,
                source: .remoteBackendEvent,
                operationID: operationID
            )
            let event = SignalingEvent.ended(
                callID: callID,
                reason: .ended,
                metadata: .init(
                    endedByUserId: nil,
                    operationId: operationID.uuidString,
                    sessionVersion: nil,
                    endedAt: ISO8601DateFormatter().string(from: Date())
                )
            )
            await self.handleValidatedBackendTerminalEvent(
                callID: callID,
                endReason: .remoteHangup,
                finalState: .ended,
                event: event
            )
            self.remoteDepartureTasks.removeValue(forKey: callID)
        }
    }

    /// WebSocket delivery can be interrupted by a proxy, a background network
    /// transition, or a transient hosting-provider handshake failure. While a call is
    /// connected, poll the authoritative call record as a low-frequency safety
    /// net so a terminal backend state always tears down the other phone.
    private func startTerminalStatePolling(callID: UUID) {
        terminalStatePollingTasks.removeValue(forKey: callID)?.cancel()
        terminalStatePollingTasks[callID] = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled,
                      self.sessions[callID]?.state == .connected,
                      !self.endingCallIDs.contains(callID) else {
                    break
                }
                await self.reconcileBackendState(callID: callID, trigger: "connected_call_terminal_poll")
                if self.sessions[callID] == nil { break }
            }
            self.terminalStatePollingTasks.removeValue(forKey: callID)
        }
    }

    private func observeForegroundReconciliation() async {
        #if canImport(UIKit)
        for await _ in NotificationCenter.default.notifications(named: UIApplication.willEnterForegroundNotification) {
            await reconcileActiveCalls(trigger: "app_foreground")
        }
        #endif
    }

    private func reconcileActiveCalls(trigger: String) async {
        for callID in Array(sessions.keys) {
            await reconcileBackendState(callID: callID, trigger: trigger)
        }
    }

    private func reconcileBackendState(callID: UUID, trigger: String) async {
        guard sessions[callID] != nil else { return }
        do {
            let snapshot = try await signaling.fetchSnapshot(callID: callID)
            #if DEBUG
            print(
                "CALL_END_RECONCILIATION_FETCHED",
                "callId=\(PrivacyLog.shortID(callID.uuidString))",
                "trigger=\(trigger)",
                "status=\(snapshot.status)",
                "endedByUserId=\(PrivacyLog.shortID(snapshot.endedByUserId))",
                "operationId=\(PrivacyLog.shortID(snapshot.operationId))",
                "sessionVersion=\(snapshot.sessionVersion.map(String.init) ?? "nil")",
                "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
            )
            #endif
            guard isTerminalBackendStatus(snapshot.status) else { return }
            let metadata = SignalingEvent.EndMetadata(
                endedByUserId: snapshot.endedByUserId,
                operationId: snapshot.operationId,
                sessionVersion: snapshot.sessionVersion,
                endedAt: snapshot.endedAt
            )
            let reason: SignalingEvent.EndReason = snapshot.status == "failed" ? .failed : snapshot.status == "missed" ? .missed : .ended
            let event = SignalingEvent.ended(callID: callID, reason: reason, metadata: metadata)
            let failureReason: CallFailureReason = snapshot.status == "failed" ? .signalingUnavailable : snapshot.status == "missed" ? .remoteNeverJoined : .remoteEnded
            guard decideBackendEndEvent(callID: callID, reason: failureReason, metadata: metadata, event: event) else { return }
            let finalState: CallConnectionState = snapshot.status == "failed" ? .failed : snapshot.status == "missed" ? .missed : .ended
            await handleValidatedBackendTerminalEvent(
                callID: callID,
                endReason: .remoteHangup,
                finalState: finalState,
                event: event
            )
        } catch {
            #if DEBUG
            print(
                "CALL_END_RECONCILIATION_FAILED",
                "callId=\(PrivacyLog.shortID(callID.uuidString))",
                "trigger=\(trigger)",
                "error=\(PrivacyLog.redact(error.localizedDescription))",
                "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
            )
            #endif
        }
    }

    private func isTerminalBackendStatus(_ status: String) -> Bool {
        switch status.lowercased() {
        case "ended", "missed", "failed", "declined":
            return true
        default:
            return false
        }
    }

    private func oneWayCallHandle(for type: CallType) -> String {
        type == .video ? "OneWay Video" : "OneWay Voice"
    }

    private func mutate(_ id: UUID, _ transform: (inout CallSession) -> Void) {
        guard var session = sessions[id] else { return }
        transform(&session)
        sessions[id] = session
        publish(session)
    }

    private func finish(_ id: UUID, state: CallConnectionState) {
        guard var session = sessions[id] else { return }
        recordRecipientTeardownAttempt(
            callID: id,
            component: "LiveKitCallService.finish",
            reason: "finish(\(state.rawValue))",
            endTapped: false
        )
        session.state = state
        publish(session)
        sessions.removeValue(forKey: id)
        mediaConnectedCallIDs.remove(id)
        connectionInFlightCallIDs.remove(id)
        pendingCredentials.removeValue(forKey: id)
        answeredCallIDs.remove(id)
        handledAnswerSourcesByCallID.removeValue(forKey: id)
        suppressCallKitEndUntil.removeValue(forKey: id)
        callIDsWithRemoteParticipant.remove(id)
        remoteDepartureTasks.removeValue(forKey: id)?.cancel()
        terminalStatePollingTasks.removeValue(forKey: id)?.cancel()
        MediaModeCoordinator.shared.deactivate(mode: session.type == .video ? .videoCall : .audioCall, sessionId: id)
        Task { @MainActor in
            await CallSoundSuppressionController.shared.releaseAfterTeardown(callID: id, reason: "LiveKitCallService.finish(\(state.rawValue))")
        }
    }

    private func publish(_ session: CallSession) {
        for continuation in updateContinuations.values {
            continuation.yield(session)
        }
    }

    private func removeUpdateContinuation(_ id: UUID) {
        updateContinuations.removeValue(forKey: id)
    }

    private func shouldSuppressTransientCallKitEnd(callID: UUID) -> Bool {
        guard let until = suppressCallKitEndUntil[callID], until > Date() else {
            suppressCallKitEndUntil.removeValue(forKey: callID)
            return false
        }
        guard let session = sessions[callID] else { return false }
        switch session.state {
        case .waitingForAudioActivation, .joining, .connecting, .connected, .reconnecting:
            return true
        case .ringing, .ended, .failed, .missed:
            return false
        }
    }

    private func shouldBlockAutomaticEnd(callID: UUID, reason: CallEndReason, source: CallEndSource) -> Bool {
        #if DEBUG
        guard isActiveMediaState(sessions[callID]?.state) else { return false }
        switch source {
        case .inCallButton, .notificationAction, .backendEvent, .remoteBackendEvent, .backendReconciliation:
            return false
        case .callKit, .systemInterruption:
            return true
        }
        #else
        return false
        #endif
    }

    private func isActiveMediaState(_ state: CallConnectionState?) -> Bool {
        switch state {
        case .waitingForAudioActivation, .joining, .connecting, .connected, .reconnecting:
            return true
        case .ringing, .ended, .failed, .missed, .none:
            return false
        }
    }

    private func validateBackendTerminalEvent(callID: UUID, reason: CallFailureReason, event: SignalingEvent) -> Bool {
        guard let session = sessions[callID] else {
            logSignalingEvent("call.signaling.event.rejected", event: event, rejectionReason: "no_active_session")
            return false
        }
        if reason == .remoteNeverJoined, session.state == .connecting || session.state == .ringing {
            logSignalingEvent("call.signaling.event.rejected", event: event, rejectionReason: "STALE_RINGING_TIMER_IGNORED")
            return false
        }
        logSignalingEvent("call.signaling.event.validated", event: event, rejectionReason: nil)
        return true
    }

    private func decideBackendEndEvent(
        callID: UUID,
        reason: CallFailureReason,
        metadata: SignalingEvent.EndMetadata,
        event: SignalingEvent
    ) -> Bool {
        let currentUserID = AuthTokenStore.shared.currentUserID()
        let localOperationID = endTransactions[callID]?.operationID.uuidString
        let eventOperationID = metadata.operationId
        let endedByMe = metadata.endedByUserId?.caseInsensitiveCompare(currentUserID) == .orderedSame
        let matchesLocalOperation = localOperationID.flatMap { local in
            eventOperationID?.caseInsensitiveCompare(local) == .orderedSame
        } ?? false
        let activeState = sessions[callID]?.state.rawValue ?? "nil"
        logCallEndDecisionEvent(
            "CALL_END_EVENT_RECEIVED",
            callID: callID,
            currentUserID: currentUserID,
            endedByUserId: metadata.endedByUserId,
            localOperationID: localOperationID,
            eventOperationID: eventOperationID,
            activeState: activeState,
            localEndInProgress: endingCallIDs.contains(callID),
            sessionVersion: nil,
            eventVersion: metadata.sessionVersion
        )

        guard sessions[callID] != nil else {
            logCallEndDecisionEvent(
                "CALL_END_EVENT_STALE_REJECTED",
                callID: callID,
                currentUserID: currentUserID,
                endedByUserId: metadata.endedByUserId,
                localOperationID: localOperationID,
                eventOperationID: eventOperationID,
                activeState: activeState,
                localEndInProgress: endingCallIDs.contains(callID),
                sessionVersion: nil,
                eventVersion: metadata.sessionVersion
            )
            logSignalingEvent("call.signaling.event.rejected", event: event, rejectionReason: "wrong_or_inactive_call_id")
            return false
        }

        if matchesLocalOperation || endedByMe {
            logCallEndDecisionEvent(
                "CALL_END_EVENT_LOCAL_ECHO_IGNORED",
                callID: callID,
                currentUserID: currentUserID,
                endedByUserId: metadata.endedByUserId,
                localOperationID: localOperationID,
                eventOperationID: eventOperationID,
                activeState: activeState,
                localEndInProgress: endingCallIDs.contains(callID),
                sessionVersion: nil,
                eventVersion: metadata.sessionVersion
            )
            logVideoEnd("video.end.backendEchoIgnored", callID: callID, reason: .remoteHangup, source: .backendEvent, operationID: UUID(), state: sessions[callID]?.state)
            return false
        }

        guard validateBackendTerminalEvent(callID: callID, reason: reason, event: event) else {
            logCallEndDecisionEvent(
                "CALL_END_EVENT_STALE_REJECTED",
                callID: callID,
                currentUserID: currentUserID,
                endedByUserId: metadata.endedByUserId,
                localOperationID: localOperationID,
                eventOperationID: eventOperationID,
                activeState: activeState,
                localEndInProgress: endingCallIDs.contains(callID),
                sessionVersion: nil,
                eventVersion: metadata.sessionVersion
            )
            return false
        }

        logCallEndDecisionEvent(
            "CALL_END_EVENT_REMOTE_APPLIED",
            callID: callID,
            currentUserID: currentUserID,
            endedByUserId: metadata.endedByUserId,
            localOperationID: localOperationID,
            eventOperationID: eventOperationID,
            activeState: activeState,
            localEndInProgress: endingCallIDs.contains(callID),
            sessionVersion: nil,
            eventVersion: metadata.sessionVersion
        )
        return true
    }

    private func handleValidatedBackendTerminalEvent(
        callID: UUID,
        endReason: CallEndReason,
        finalState: CallConnectionState,
        event: SignalingEvent
    ) async {
        let operationID = UUID()
        let remoteEndedByUserID: String? = {
            if case .ended(_, _, let metadata) = event {
                return metadata.endedByUserId
            }
            return nil
        }()
        if let completedAt = completedEndTransactions[callID],
           Date().timeIntervalSince(completedAt) < 30 {
            logDuplicateEndIgnored(
                callID: callID,
                reason: endReason,
                source: .remoteBackendEvent,
                attemptedOperationID: operationID,
                existingTransaction: EndCallTransaction(operationID: operationID, reason: endReason, source: .remoteBackendEvent, startedAt: completedAt)
            )
            return
        }
        if endingCallIDs.contains(callID) {
            if let transaction = endTransactions[callID] {
                logDuplicateEndIgnored(
                    callID: callID,
                    reason: endReason,
                    source: .remoteBackendEvent,
                    attemptedOperationID: operationID,
                    existingTransaction: transaction
                )
            }
            logUnifiedEnd("DUPLICATE_END_JOINED_EXISTING_TRANSACTION", callID: callID, source: .remoteBackendEvent, reason: endReason, operationID: operationID, endedByUserId: remoteEndedByUserID, state: sessions[callID]?.state)
            return
        }
        logUnifiedEnd("UNIFIED_END_REMOTE_EVENT_RECEIVED", callID: callID, source: .remoteBackendEvent, reason: endReason, operationID: operationID, endedByUserId: remoteEndedByUserID, state: sessions[callID]?.state)
        CallSoundSuppressionController.shared.acquire(callID: callID, reason: "remote_backend_end_guard:\(endReason.rawValue)")
        logCallSoundPolicyEvent("CALL_END_SOUND_GUARD_CONFIRMED", callID: callID, state: sessions[callID]?.state, detail: "source=remoteBackendEvent suppressionActive=\(CallSoundSuppressionController.shared.isSuppressionActive)")
        logUnifiedEnd("UNIFIED_END_REQUESTED", callID: callID, source: .remoteBackendEvent, reason: endReason, operationID: operationID, endedByUserId: remoteEndedByUserID, state: sessions[callID]?.state)
        endingCallIDs.insert(callID)
        endTransactions[callID] = EndCallTransaction(operationID: operationID, reason: endReason, source: .remoteBackendEvent, startedAt: Date())
        logUnifiedEnd("UNIFIED_END_TRANSACTION_CREATED", callID: callID, source: .remoteBackendEvent, reason: endReason, operationID: operationID, endedByUserId: remoteEndedByUserID, state: sessions[callID]?.state)
        printRemoteEndLog("REMOTE_CALL_END_RECEIVED", callID: callID, operationID: operationID, state: sessions[callID]?.state)
        logVideoEnd(
            "video.end.backendTerminalQueued",
            callID: callID,
            reason: endReason,
            source: .remoteBackendEvent,
            operationID: operationID,
            state: sessions[callID]?.state
        )
        let didReportCallKitEnded = bridge.reportRemoteCallEnded(callID: callID)
        if !didReportCallKitEnded {
            logVideoEnd(
                "video.end.remote.callKitReportFailed",
                callID: callID,
                reason: endReason,
                source: .remoteBackendEvent,
                operationID: operationID,
                state: sessions[callID]?.state
            )
        }
        logVideoEnd(
            "video.end.remote.callKitProviderReportedEnded",
            callID: callID,
            reason: endReason,
            source: .remoteBackendEvent,
            operationID: operationID,
            state: sessions[callID]?.state
        )
        await stopLocalMedia(callID: callID, reason: endReason, source: .remoteBackendEvent, operationID: operationID)
        logUnifiedEnd("UNIFIED_END_LIVEKIT_COMPLETED", callID: callID, source: .remoteBackendEvent, reason: endReason, operationID: operationID, endedByUserId: remoteEndedByUserID, state: sessions[callID]?.state)
        logCallSoundPolicyEvent("CALL_ENDED", callID: callID, state: sessions[callID]?.state, detail: "reason=\(endReason.rawValue) source=remoteBackendEvent manualSoundPlayback=none")
        printRemoteEndLog("REMOTE_CALL_END_APPLIED", callID: callID, operationID: operationID, state: finalState)
        finish(callID, state: finalState)
        printRemoteEndLog("REMOTE_CALL_UI_DISMISSED", callID: callID, operationID: operationID, state: nil)
        logUnifiedEnd("UNIFIED_END_UI_DISMISSED", callID: callID, source: .remoteBackendEvent, reason: endReason, operationID: operationID, endedByUserId: remoteEndedByUserID, state: nil)
        endingCallIDs.remove(callID)
        endTransactions.removeValue(forKey: callID)
        completedEndTransactions[callID] = Date()
        printRemoteEndLog("REMOTE_CALL_END_COMPLETED", callID: callID, operationID: operationID, state: nil)
        logUnifiedEnd("UNIFIED_END_COMPLETED", callID: callID, source: .remoteBackendEvent, reason: endReason, operationID: operationID, endedByUserId: remoteEndedByUserID, state: nil)
        logVideoEnd(
            "video.end.backendTerminalApplied",
            callID: callID,
            reason: endReason,
            source: .remoteBackendEvent,
            operationID: operationID,
            state: finalState
        )
    }

    private func logSignalingEvent(_ name: String, event: SignalingEvent, rejectionReason: String?) {
        #if DEBUG
        let detail: (callID: UUID?, type: String) = {
            switch event {
            case .ringing(let ring): return (ring.callID, "ringing")
            case .accepted(let callID, _): return (callID, "accepted")
            case .declined(let callID): return (callID, "declined")
            case .ended(let callID, let reason, let metadata):
                return (callID, "ended:\(reason):version=\(metadata.sessionVersion.map(String.init) ?? "nil")")
            case .state(let callID, let status): return (callID, "state:\(status)")
            case .presence(let userID, let online): return (nil, "presence:\(PrivacyLog.shortID(userID)):\(online)")
            case .signal: return (nil, "signal")
            }
        }()
        let activeState = detail.callID.flatMap { sessions[$0]?.state.rawValue } ?? "nil"
        print(
            name,
            "eventType=\(detail.type)",
            "callId=\(PrivacyLog.shortID(detail.callID?.uuidString))",
            "activeState=\(activeState)",
            "mediaConnected=\(detail.callID.map { mediaConnectedCallIDs.contains($0) } ?? false)",
            "ending=\(detail.callID.map { endingCallIDs.contains($0) } ?? false)",
            "rejectionReason=\(rejectionReason ?? "none")",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }

    private func logBackendEndMetadata(callID: UUID, metadata: SignalingEvent.EndMetadata) {
        #if DEBUG
        print(
            "call.ended.metadata",
            "callId=\(PrivacyLog.shortID(callID.uuidString))",
            "endedByUserId=\(PrivacyLog.shortID(metadata.endedByUserId))",
            "operationId=\(PrivacyLog.shortID(metadata.operationId))",
            "sessionVersion=\(metadata.sessionVersion.map(String.init) ?? "nil")",
            "endedAt=\(metadata.endedAt ?? "nil")",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }

    private func logCallEndDecisionEvent(
        _ name: String,
        callID: UUID,
        currentUserID: String,
        endedByUserId: String?,
        localOperationID: String?,
        eventOperationID: String?,
        activeState: String,
        localEndInProgress: Bool,
        sessionVersion: Int?,
        eventVersion: Int?
    ) {
        #if DEBUG
        print(
            name,
            "callId=\(PrivacyLog.shortID(callID.uuidString))",
            "currentUserId=\(PrivacyLog.shortID(currentUserID))",
            "endedByUserId=\(PrivacyLog.shortID(endedByUserId))",
            "localOperationId=\(PrivacyLog.shortID(localOperationID))",
            "eventOperationId=\(PrivacyLog.shortID(eventOperationID))",
            "activeState=\(activeState)",
            "localEndInProgress=\(localEndInProgress)",
            "sessionVersion=\(sessionVersion.map(String.init) ?? "nil")",
            "eventVersion=\(eventVersion.map(String.init) ?? "nil")",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }

    private func printRemoteEndLog(_ name: String, callID: UUID, operationID: UUID, state: CallConnectionState?) {
        #if DEBUG
        print(
            name,
            "callId=\(PrivacyLog.shortID(callID.uuidString))",
            "operationId=\(PrivacyLog.shortID(operationID.uuidString))",
            "state=\(state?.rawValue ?? "nil")",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }

    private func logDuplicateEndIgnored(
        callID: UUID,
        reason: CallEndReason,
        source: CallEndSource,
        attemptedOperationID: UUID,
        existingTransaction: EndCallTransaction
    ) {
        #if DEBUG
        print(
            "DUPLICATE_END_IGNORED",
            "callId=\(PrivacyLog.shortID(callID.uuidString))",
            "attemptedReason=\(reason.rawValue)",
            "attemptedSource=\(source.rawValue)",
            "attemptedOperationId=\(PrivacyLog.shortID(attemptedOperationID.uuidString))",
            "existingReason=\(existingTransaction.reason.rawValue)",
            "existingSource=\(existingTransaction.source.rawValue)",
            "existingOperationId=\(PrivacyLog.shortID(existingTransaction.operationID.uuidString))",
            "ageMs=\(Int(Date().timeIntervalSince(existingTransaction.startedAt) * 1000))",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }

    private func logUnifiedEnd(
        _ event: String,
        callID: UUID,
        source: CallEndSource,
        reason: CallEndReason,
        operationID: UUID,
        endedByUserId: String?,
        state: CallConnectionState?
    ) {
        #if DEBUG
        let callKitUUID = bridge.callKitUUID(for: callID) ?? callID
        print(
            event,
            "callId=\(PrivacyLog.shortID(callID.uuidString))",
            "callKitUUID=\(callKitUUID.uuidString)",
            "currentUser=\(PrivacyLog.shortID(AuthTokenStore.shared.currentUserID()))",
            "endedByUserId=\(PrivacyLog.shortID(endedByUserId))",
            "source=\(source.rawValue)",
            "reason=\(reason.rawValue)",
            "operationId=\(PrivacyLog.shortID(operationID.uuidString))",
            "lifecycleState=\(state?.rawValue ?? "nil")",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }

    private func logAutomaticCallEndBlocked(
        callID: UUID,
        reason: CallEndReason,
        source: CallEndSource,
        operationID: UUID,
        component: String,
        file: StaticString = #fileID,
        function: StaticString = #function,
        line: UInt = #line
    ) {
        #if DEBUG
        print(
            "AUTOMATIC_CALL_END_BLOCKED",
            "callId=\(PrivacyLog.shortID(callID.uuidString))",
            "role=\((sessions[callID]?.isLocal ?? false) ? "caller" : "recipient")",
            "state=\(sessions[callID]?.state.rawValue ?? "nil")",
            "reason=\(reason.rawValue)",
            "source=\(source.rawValue)",
            "component=\(component)",
            "file=\(file)",
            "function=\(function)",
            "line=\(line)",
            "operationId=\(PrivacyLog.shortID(operationID.uuidString))",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }

    private func stopLocalMedia(callID: UUID, reason: CallEndReason, source: CallEndSource, operationID: UUID) async {
        recordRecipientTeardownAttempt(
            callID: callID,
            component: "LiveKitCallService.stopLocalMedia",
            reason: "\(reason.rawValue):\(source.rawValue)",
            endTapped: source == .inCallButton || source == .notificationAction
        )
        try? await transport.setCameraEnabled(false)
        try? await transport.setMicrophoneEnabled(false)
        await transport.disconnect()
        mediaConnectedCallIDs.remove(callID)
        logVideoEnd("video.end.mediaStopped", callID: callID, reason: reason, source: source, operationID: operationID, state: sessions[callID]?.state)
    }

    private func logVideoAnswer(_ event: String, callID: UUID, source: CallAnswerSource, operationID: UUID, state: CallConnectionState?) {
        #if DEBUG
        print(
            event,
            "callId=\(PrivacyLog.shortID(callID.uuidString))",
            "source=\(source.rawValue)",
            "operationId=\(PrivacyLog.shortID(operationID.uuidString))",
            "state=\(state?.rawValue ?? "nil")",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }

    private func logCallSoundPolicyEvent(_ event: String, callID: UUID, state: CallConnectionState?, detail: String) {
        #if DEBUG
        print(
            event,
            "callId=\(PrivacyLog.shortID(callID.uuidString))",
            "state=\(state?.rawValue ?? "nil")",
            "detail=\(detail)",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }

    private func logVideoEnd(_ event: String, callID: UUID, reason: CallEndReason, source: CallEndSource, operationID: UUID, state: CallConnectionState?) {
        #if DEBUG
        print(
            event,
            "callId=\(PrivacyLog.shortID(callID.uuidString))",
            "reason=\(reason.rawValue)",
            "source=\(source.rawValue)",
            "operationId=\(PrivacyLog.shortID(operationID.uuidString))",
            "state=\(state?.rawValue ?? "nil")",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }

    private func logMediaReady(callID: UUID, media: CallMediaConnectionResult, role: String) {
        #if DEBUG
        print(
            "video.call.media.ready",
            "callId=\(PrivacyLog.shortID(callID.uuidString))",
            "role=\(role)",
            "microphonePublished=\(media.microphonePublished)",
            "cameraPublished=\(media.cameraPublished)",
            "transportObject=\(ObjectIdentifier(transport))",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }

    private func recordRecipientTeardownAttempt(
        callID: UUID,
        component: String,
        reason: String,
        endTapped: Bool,
        file: StaticString = #fileID,
        function: StaticString = #function,
        line: UInt = #line
    ) {
        #if DEBUG
        guard let session = sessions[callID], session.isLocal == false else { return }
        guard firstTeardownTriggerByCallID[callID] == nil else { return }
        let trigger = FirstRecipientTeardownTrigger(
            callID: callID,
            state: session.state.rawValue,
            sourceFile: "\(file)",
            function: "\(function)",
            lineNumber: line,
            component: component,
            reason: reason,
            callKitUUID: callID.uuidString,
            transportObject: "\(ObjectIdentifier(transport))",
            endTapped: endTapped,
            timestamp: Date()
        )
        firstTeardownTriggerByCallID[callID] = trigger
        print(trigger.logLine)
        #endif
    }
}

private struct FirstRecipientTeardownTrigger {
    let callID: UUID
    let state: String
    let sourceFile: String
    let function: String
    let lineNumber: UInt
    let component: String
    let reason: String
    let callKitUUID: String
    let transportObject: String
    let endTapped: Bool
    let timestamp: Date

    var logLine: String {
        [
            "FirstRecipientTeardownTrigger",
            "callId=\(PrivacyLog.shortID(callID.uuidString))",
            "state=\(state)",
            "sourceFile=\(sourceFile)",
            "function=\(function)",
            "lineNumber=\(lineNumber)",
            "component=\(component)",
            "reason=\(PrivacyLog.redact(reason))",
            "callKitUUID=\(PrivacyLog.shortID(callKitUUID))",
            "transportObject=\(transportObject)",
            "endTapped=\(endTapped)",
            "timestamp=\(ISO8601DateFormatter().string(from: timestamp))"
        ].joined(separator: " ")
    }
}

#if canImport(LiveKit)
import LiveKit

extension LiveKitCallService {
    /// Expose the underlying LiveKit room for SwiftUI rendering.
    /// This is intentionally not part of the generic `CallService` protocol.
    func currentLiveKitRoom() -> Room? {
        (transport as? LiveKitTransport)?.currentRoom()
    }

    var liveKitRoomUpdates: AsyncStream<Void> {
        (transport as? LiveKitTransport)?.roomUpdates ?? AsyncStream { _ in }
    }
}
#endif
