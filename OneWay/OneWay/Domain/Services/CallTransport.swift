import Foundation

struct TurnServerConfiguration: Codable, Equatable, Sendable {
    let urls: [String]
    let username: String?
    let credential: String?
}

struct CallMediaConnectionResult: Sendable, Equatable {
    let microphonePublished: Bool
    let cameraPublished: Bool
}

struct CallSignalingSnapshot: Sendable, Equatable {
    let callID: UUID
    let status: String
    let endedByUserId: String?
    let operationId: String?
    let sessionVersion: Int?
    let endedAt: String?
}

/// Provider-agnostic abstraction for the *media* side of a call (mic, camera,
/// peer connection). Implementations hide WebRTC stack details so we can swap
/// LiveKit / Twilio / Daily without touching the call lifecycle code.
@MainActor
protocol CallTransport: AnyObject {
    /// Connect to a call room. URL + JWT come from your token server (or
    /// directly from a `CallSignalingClient`).
    func connect(roomURL: URL, token: String, iceServers: [TurnServerConfiguration], video: Bool) async throws -> CallMediaConnectionResult

    /// Enable / disable the local microphone.
    func setMicrophoneEnabled(_ enabled: Bool) async throws

    /// Enable / disable the local camera.
    func setCameraEnabled(_ enabled: Bool) async throws

    /// Toggle front / back camera.
    func switchCamera() async throws

    /// Tear down the room.
    func disconnect() async

    /// Wait until at least one remote participant is present in the media
    /// room. Backend acceptance is not enough for a connected call.
    func waitForRemoteParticipant(timeoutSeconds: TimeInterval) async -> Bool

    /// Updates from the underlying transport (remote-participant joins/leaves,
    /// mute changes). The `CallService` mirrors these into `CallSession`.
    var participantUpdates: AsyncStream<[CallParticipant]> { get }
}

/// Ring / answer / hangup signalling between two devices. Backed by your
/// backend (HTTP + push), Supabase Realtime, a websocket, etc. Kept separate
/// from `CallTransport` so the media stack is interchangeable.
protocol CallSignalingClient: Sendable {
    func start() async
    func stop() async

    /// Tell the peer "I'm calling you", returns the room credentials to
    /// connect the local media to.
    func invite(chatID: UUID, callID: UUID, type: CallType) async throws -> CallCredentials

    /// Local user accepted an inbound call — get credentials to join.
    func accept(callID: UUID) async throws -> CallCredentials

    /// Fetch authoritative LiveKit join credentials for the stored backend
    /// CallSession. This separates "invitation accepted" from "media joined."
    func join(callID: UUID) async throws -> CallCredentials

    /// Tell the backend local media publication has completed. The backend
    /// uses this to move the authoritative CallSession to connected only when
    /// both participants have audio ready.
    func mediaReady(callID: UUID, audioPublished: Bool, videoPublished: Bool) async throws

    /// Local user declined an inbound call before answering.
    func decline(callID: UUID) async throws

    /// Local user ended a connected (or outbound-ringing) call.
    func hangup(callID: UUID) async throws
    func hangup(callID: UUID, reason: CallEndReason, source: CallEndSource, operationID: UUID) async throws

    /// Fetch authoritative backend state for reconnect/foreground recovery.
    func fetchSnapshot(callID: UUID) async throws -> CallSignalingSnapshot

    /// Push channel for events the *server* originates: incoming rings,
    /// remote accepted/declined/ended, presence. Implementations that don't
    /// have a real backend (the stub) return an empty stream that never
    /// produces values — that's intentional and lets `LiveKitCallService`
    /// observe unconditionally without branching on backend kind.
    var incomingEvents: AsyncStream<SignalingEvent> { get }
}

extension CallSignalingClient {
    func start() async {}
    func stop() async {}
    func join(callID: UUID) async throws -> CallCredentials {
        try await accept(callID: callID)
    }
    func mediaReady(callID: UUID, audioPublished: Bool, videoPublished: Bool) async throws {}
    func hangup(callID: UUID, reason: CallEndReason, source: CallEndSource, operationID: UUID) async throws {
        try await hangup(callID: callID)
    }
    func fetchSnapshot(callID: UUID) async throws -> CallSignalingSnapshot {
        CallSignalingSnapshot(
            callID: callID,
            status: "unknown",
            endedByUserId: nil,
            operationId: nil,
            sessionVersion: nil,
            endedAt: nil
        )
    }
}

/// Server-originated event delivered through `CallSignalingClient.incomingEvents`.
/// Mirrors the WebSocket event taxonomy without importing networking types
/// into the domain layer.
enum SignalingEvent: Sendable, Equatable {
    /// A remote user invited *us* to a call. Includes everything we need to
    /// drive CallKit ringing UI without doing another round-trip.
    case ringing(IncomingRing)
    /// The other party accepted a call we initiated. Carries the room URL +
    /// token so the caller can join immediately.
    case accepted(callID: UUID, credentials: CallCredentials)
    /// The other party declined our outbound call.
    case declined(callID: UUID)
    /// Either side hung up, or the call timed out / failed / was missed.
    case ended(callID: UUID, reason: EndReason, metadata: EndMetadata)
    /// Generic state push — used to recover after a reconnect.
    case state(callID: UUID, status: String)
    /// A connected counterparty came online or went offline.
    case presence(userID: String, online: Bool)
    /// Encrypted WebRTC signalling payload relay (offer/answer/ice).
    case signal(CallSignal)

    enum EndReason: String, Sendable, Equatable {
        case ended
        case missed
        case failed
    }

    struct EndMetadata: Sendable, Equatable {
        let endedByUserId: String?
        let operationId: String?
        let sessionVersion: Int?
        let endedAt: String?

        static let empty = EndMetadata(
            endedByUserId: nil,
            operationId: nil,
            sessionVersion: nil,
            endedAt: nil
        )
    }

    struct IncomingRing: Sendable, Equatable {
        let callID: UUID
        let callerID: String
        let hasVideo: Bool
        /// Some backends (the OneWay one does) include the room name in the
        /// invite so the callee can immediately request a token. Other
        /// backends only hand out credentials on `accept`.
        let roomName: String?
    }

    struct CallSignal: Sendable, Equatable {
        enum Kind: String, Sendable, Equatable {
            case offer
            case answer
            case ice
        }

        let callID: UUID
        let fromUserID: String
        let kind: Kind
        /// Base64-encoded encrypted payload (AES-GCM combined).
        let ciphertextB64: String
        /// Base64 Curve25519 public keys (rawRepresentation).
        let senderEphemeralPubB64: String?
        let senderIdentityPubB64: String?
    }
}

struct CallCredentials: Sendable, Equatable {
    let roomURL: URL
    let token: String
    let iceServers: [TurnServerConfiguration]
    let callID: UUID?
    let participantIdentity: String?

    init(
        roomURL: URL,
        token: String,
        iceServers: [TurnServerConfiguration],
        callID: UUID? = nil,
        participantIdentity: String? = nil
    ) {
        self.roomURL = roomURL
        self.token = token
        self.iceServers = iceServers
        self.callID = callID
        self.participantIdentity = participantIdentity
    }
}
