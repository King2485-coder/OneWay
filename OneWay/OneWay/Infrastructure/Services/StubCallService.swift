import Foundation

@MainActor
final class StubCallService: CallService {
    private var activeSessions: [UUID: CallSession] = [:]

    func startCall(chatID: UUID, type: CallType) async throws -> CallSession {
        let session = CallSession(
            id: UUID(),
            chatID: chatID,
            type: type,
            networkType: .oneWayNative,
            state: .ringing,
            startedAt: Date(),
            participants: [CallParticipant(id: UUID(), displayName: "You", isMuted: false, isVideoEnabled: type == .video)],
            muted: false,
            speakerOn: type == .video,
            cameraOn: type == .video,
            isLocal: true
        )
        activeSessions[session.id] = session
        return session
    }

    func answerCall(sessionID: UUID) async throws {
        update(sessionID) { session in
            var updated = session
            updated.state = .connected
            return updated
        }
    }

    func declineCall(sessionID: UUID) async throws {
        activeSessions.removeValue(forKey: sessionID)
    }

    func endCall(sessionID: UUID) async throws {
        activeSessions.removeValue(forKey: sessionID)
    }

    func toggleMute(sessionID: UUID, isMuted: Bool) async throws {
        update(sessionID) { session in
            var updated = session
            updated.muted = isMuted
            return updated
        }
    }

    func toggleSpeaker(sessionID: UUID, isOn: Bool) async throws {
        update(sessionID) { session in
            var updated = session
            updated.speakerOn = isOn
            return updated
        }
    }

    func toggleCamera(sessionID: UUID, isOn: Bool) async throws {
        update(sessionID) { session in
            var updated = session
            updated.cameraOn = isOn
            return updated
        }
    }

    func switchCamera(sessionID: UUID) async throws {
        // No-op in stub; would toggle front/back in real implementation
        _ = sessionID
    }

    func observeActiveCalls() -> AsyncStream<CallSession> {
        AsyncStream { continuation in
            activeSessions.values.forEach { continuation.yield($0) }
        }
    }

    private func update(_ id: UUID, transform: (CallSession) -> CallSession) {
        guard let session = activeSessions[id] else { return }
        activeSessions[id] = transform(session)
    }
}
