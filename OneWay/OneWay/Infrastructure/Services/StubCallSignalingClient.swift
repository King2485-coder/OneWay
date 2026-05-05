import Foundation

/// In-memory signalling client used until a real backend (Supabase Realtime,
/// websocket, custom HTTP+push) is wired in. Returns a deterministic LiveKit
/// dev-room URL so the rest of the call lifecycle compiles end-to-end without
/// network access.
///
/// Swap this for a `NetworkCallSignalingClient` once the backend exposes
/// `/api/calls/invite|accept|decline|hangup`. The protocol is intentionally
/// narrow so the replacement is mechanical.
struct StubCallSignalingClient: CallSignalingClient {
    /// Override this if you spin up a self-hosted LiveKit instance.
    static let defaultRoomURL = URL(string: "wss://oneway-dev.livekit.cloud")!

    func invite(chatID: UUID, callID: UUID, type: CallType) async throws -> CallCredentials {
        CallCredentials(roomURL: Self.defaultRoomURL, token: Self.devToken(for: callID), iceServers: [])
    }

    func accept(callID: UUID) async throws -> CallCredentials {
        CallCredentials(roomURL: Self.defaultRoomURL, token: Self.devToken(for: callID), iceServers: [])
    }

    func decline(callID: UUID) async throws {}
    func hangup(callID: UUID) async throws {}

    /// Stub never receives server-originated events — return a stream that
    /// finishes immediately so `for await` loops simply exit.
    var incomingEvents: AsyncStream<SignalingEvent> {
        AsyncStream { continuation in continuation.finish() }
    }

    /// Stand-in for a JWT minted by your token server. NEVER ship a real
    /// LiveKit secret in the client — this string just proves the wiring works.
    private static func devToken(for callID: UUID) -> String {
        "dev.\(callID.uuidString)"
    }
}
