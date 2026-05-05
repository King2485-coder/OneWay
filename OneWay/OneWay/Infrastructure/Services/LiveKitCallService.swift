import Foundation

#if canImport(CallKit)
import CallKit
#endif

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
    private let updates = AsyncStream<CallSession>.makeStream()

    /// Pending credentials per call. Populated when an `accepted` event
    /// arrives for a call we initiated, before `transport.connect` runs.
    private var pendingCredentials: [UUID: CallCredentials] = [:]

    init(transport: CallTransport,
         signaling: CallSignalingClient,
         bridge: CallKitBridge) {
        self.transport = transport
        self.signaling = signaling
        self.bridge = bridge
        wireBridge()
        Task { [weak self] in await self?.observeTransport() }
        Task { [weak self] in await self?.observeSignaling() }
    }

    // MARK: - CallService

    func startCall(chatID: UUID, type: CallType) async throws -> CallSession {
        let callID = UUID()
        var session = CallSession(
            id: callID,
            chatID: chatID,
            type: type,
            state: .ringing,
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
        sessions[callID] = session
        publish(session)

        // Tell the system we're starting an outbound call before any media work
        // — this is what gets the call into Recents and keeps audio alive in
        // the background.
        try await bridge.reportOutboundCallStarted(uuid: callID,
                                                   handle: chatID.uuidString,
                                                   hasVideo: type == .video)

        // Ask the backend for a room + token, then connect the media stack.
        let credentials = try await signaling.invite(chatID: chatID,
                                                     callID: callID,
                                                     type: type)
        session.state = .connecting
        sessions[callID] = session
        publish(session)

        try await transport.connect(roomURL: credentials.roomURL,
                                    token: credentials.token,
                                    iceServers: credentials.iceServers,
                                    video: type == .video)

        bridge.reportConnected(uuid: callID)
        session.state = .connected
        sessions[callID] = session
        publish(session)
        return session
    }

    func answerCall(sessionID: UUID) async throws {
        guard var session = sessions[sessionID] else { return }
        session.state = .connecting
        sessions[sessionID] = session
        publish(session)

        let credentials = try await signaling.accept(callID: sessionID)
        try await transport.connect(roomURL: credentials.roomURL,
                                    token: credentials.token,
                                    iceServers: credentials.iceServers,
                                    video: session.type == .video)
        bridge.reportConnected(uuid: sessionID)
        session.state = .connected
        sessions[sessionID] = session
        publish(session)
    }

    func declineCall(sessionID: UUID) async throws {
        try? await signaling.decline(callID: sessionID)
        try? await bridge.endCall(uuid: sessionID)
        finish(sessionID, state: .ended)
    }

    func endCall(sessionID: UUID) async throws {
        try? await signaling.hangup(callID: sessionID)
        try? await bridge.endCall(uuid: sessionID)
        await transport.disconnect()
        finish(sessionID, state: .ended)
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
        updates.stream
    }

    /// Push-driven incoming call: build a placeholder session before the
    /// matching `call:ringing` WebSocket event arrives. Idempotent — a later
    /// `handleIncomingRing` upgrades the record without losing CallKit state.
    func prepareIncomingCall(callID: UUID, callerID: String, hasVideo: Bool, roomName: String?) {
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
            Task { try? await self.answerCall(sessionID: uuid) }
        }
        bridge.onEnd = { [weak self] uuid in
            guard let self else { return }
            Task { try? await self.endCall(sessionID: uuid) }
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
                self.finish(id, state: .ended)
            }
        }
    }

    private func observeSignaling() async {
        for await event in signaling.incomingEvents {
            switch event {
            case .ringing(let ring):
                await handleIncomingRing(ring)
            case .accepted(let callID, let credentials):
                await handleRemoteAccepted(callID: callID, credentials: credentials)
            case .declined(let callID):
                finish(callID, state: .ended)
                try? await bridge.endCall(uuid: callID)
            case .ended(let callID, let reason):
                let state: CallConnectionState = {
                    switch reason {
                    case .missed:  return .missed
                    case .failed:  return .failed
                    case .ended:   return .ended
                    }
                }()
                finish(callID, state: state)
                try? await bridge.endCall(uuid: callID)
            case .state, .presence:
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
        sessions[ring.callID] = session
        publish(session)
        do {
            try await bridge.reportIncomingCall(uuid: ring.callID,
                                                handle: ring.callerID,
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
        if session.state == .connected {
            return
        }
        pendingCredentials[callID] = credentials
        session.state = .connecting
        sessions[callID] = session
        publish(session)
        do {
            try await transport.connect(roomURL: credentials.roomURL,
                                        token: credentials.token,
                                        iceServers: credentials.iceServers,
                                        video: session.type == .video)
            bridge.reportConnected(uuid: callID)
            mutate(callID) { $0.state = .connected }
        } catch {
            finish(callID, state: .failed)
            try? await bridge.endCall(uuid: callID)
        }
        pendingCredentials.removeValue(forKey: callID)
    }

    private func observeTransport() async {
        for await participants in transport.participantUpdates {
            // Mirror remote-participant deltas into whichever session is
            // currently connected. The simple case: at most one active call.
            guard let id = sessions.first(where: { $0.value.state == .connected })?.key else {
                continue
            }
            mutate(id) { $0.participants = participants }
        }
    }

    private func mutate(_ id: UUID, _ transform: (inout CallSession) -> Void) {
        guard var session = sessions[id] else { return }
        transform(&session)
        sessions[id] = session
        publish(session)
    }

    private func finish(_ id: UUID, state: CallConnectionState) {
        guard var session = sessions[id] else { return }
        session.state = state
        publish(session)
        sessions.removeValue(forKey: id)
    }

    private func publish(_ session: CallSession) {
        updates.continuation.yield(session)
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
}
#endif
