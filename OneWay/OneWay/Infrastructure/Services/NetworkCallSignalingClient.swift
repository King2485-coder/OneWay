import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Real signalling client. Talks to the OneWay backend over:
///   - `POST /api/calls/invite|accept|decline|hangup` for state mutations
///   - `POST /api/livekit/token` to mint a LiveKit JWT for the room
///   - `wss://…/ws/calls` for server-originated events (incoming rings,
///     remote accept/decline/end, presence)
///
/// The actor isolates every mutation of the WebSocket task and the cached
/// continuations. REST calls happen on URLSession's own queues; results hop
/// back to the actor when they update state.
///
/// `CallSignalingClient` is `Sendable`; we satisfy that by being an actor.
/// Swift's compiler treats actor types as `Sendable` by construction.
actor NetworkCallSignalingClient: CallSignalingClient {

    // MARK: - Public API

    enum Failure: Error, LocalizedError {
        case missingAuth
        case http(status: Int, code: String?)
        case decoding(Error)
        case underlying(Error)
        case noWebSocket

        var errorDescription: String? {
            switch self {
            case .missingAuth: return "Not signed in."
            case .http(let s, let code):
                if let code { return "Backend rejected request (\(s) \(code))." }
                return "Backend rejected request (\(s))."
            case .decoding(let e): return "Could not decode server response: \(e.localizedDescription)"
            case .underlying(let e): return e.localizedDescription
            case .noWebSocket: return "No WebSocket connection."
            }
        }
    }

    /// - Parameters:
    ///   - baseURL: API base. Used for both REST and to derive the WebSocket URL.
    ///     HTTPS IP literals are normalized to the local HTTP dev backend to avoid
    ///     raw-IP TLS certificate failures during Debug LAN testing.
    ///   - userID: the local user's id. Sent as `Bearer dev:<id>` until real
    ///     auth is in.
    ///   - session: injectable for tests.
    init(baseURL: URL,
         userID: String,
         session: URLSession = .signalingDefault) {
        self.baseURL = Self.canonicalBaseURL(baseURL)
        self.userID = userID
        self.session = session
        let (stream, continuation) = AsyncStream<SignalingEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        self.incomingStream = stream
        self.eventContinuation = continuation
        Task { [weak self] in await self?.observeAppLifecycle() }
    }


    private static func canonicalBaseURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(),
              components.scheme?.lowercased() == "https" else {
            return url
        }

        if isIPLiteralHost(host) {
            // The local nginx certificate is issued for oneway.is, so iOS rejects
            // wss://<LAN IP>. For raw-IP Debug LAN testing, use the same HTTP
            // Node backend endpoint as APIConfig; makeWebSocketURL will derive ws://.
            components.scheme = "http"
            components.port = 3000
            components.path = ""
            components.query = nil
            components.fragment = nil
            return components.url ?? url
        }

        guard isLegacyAPIHost(host) else { return url }

        components.host = canonicalSignalingHost
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url ?? url
    }

    private static let canonicalSignalingHost = "oneway.is"

    private static var legacyAPIHost: String {
        "api." + canonicalSignalingHost
    }

    private static func isLegacyAPIHost(_ host: String) -> Bool {
        host == legacyAPIHost
    }

    private static func isIPLiteralHost(_ host: String) -> Bool {
        if isIPv4Literal(host) { return true }
        return host.contains(":") && host.allSatisfy { character in
            character.isHexDigit || character == ":" || character == "."
        }
    }

    private static func isIPv4Literal(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }

        return octets.allSatisfy { octet in
            guard !octet.isEmpty,
                  octet.allSatisfy({ $0.isNumber }),
                  let value = Int(octet) else {
                return false
            }
            return (0...255).contains(value)
        }
    }

    // Listen for foreground/background transitions and force a fresh
    // WebSocket on resume. iOS suspends sockets eagerly when backgrounded;
    // pretending a stale one is fine results in missed `call:ringing`
    // events. PushKit covers the closed-app case, so dropping the WS while
    // backgrounded is safe.
    private func observeAppLifecycle() async {
        #if canImport(UIKit)
        let didEnterBackground = NotificationCenter.default.notifications(named: UIApplication.didEnterBackgroundNotification)
        let willEnterForeground = NotificationCenter.default.notifications(named: UIApplication.willEnterForegroundNotification)
        async let bg: () = {
            for await _ in didEnterBackground { await self.handleBackground() }
        }()
        async let fg: () = {
            for await _ in willEnterForeground { await self.handleForeground() }
        }()
        _ = await (bg, fg)
        #endif
    }

    private func handleBackground() async {
        receiveTask?.cancel()
        receiveTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
    }

    private func handleForeground() async {
        guard isStarted else { return }
        attempt = 0
        connectWebSocket()
    }

    // CallSignalingClient — REST surface ---------------------------------

    nonisolated var incomingEvents: AsyncStream<SignalingEvent> { incomingStream }

    func invite(chatID: UUID, callID: UUID, type: CallType) async throws -> CallCredentials {
        ensureWebSocketStarted()
        let body: [String: Any] = [
            "calleeId": chatID.uuidString,
            "hasVideo": type == .video
        ]
        let envelope: CallEnvelope = try await postJSON("/api/calls/invite", body: body)
        // Mint our own LiveKit token for the freshly-created room. We do
        // this here so a successful invite always returns *connect-ready*
        // credentials, matching the existing `CallSignalingClient` contract.
        return try await mintToken(roomName: envelope.call.roomName)
    }

    func accept(callID: UUID) async throws -> CallCredentials {
        ensureWebSocketStarted()
        let body: [String: Any] = ["callId": callID.uuidString]
        let envelope: CallEnvelope = try await postJSON("/api/calls/accept", body: body)
        return try await mintToken(roomName: envelope.call.roomName)
    }

    func decline(callID: UUID) async throws {
        let body: [String: Any] = ["callId": callID.uuidString]
        let _: CallEnvelope = try await postJSON("/api/calls/decline", body: body)
    }

    func hangup(callID: UUID) async throws {
        let body: [String: Any] = ["callId": callID.uuidString]
        let _: CallEnvelope = try await postJSON("/api/calls/hangup", body: body)
    }

    // MARK: - WebRTC signalling relay (encrypted payload)

    func sendSignal(
        callID: UUID,
        toUserID: String,
        kind: SignalingEvent.CallSignal.Kind,
        ciphertextB64: String,
        senderEphemeralPubB64: String?,
        senderIdentityPubB64: String?
    ) async throws {
        ensureWebSocketStarted()

        let payload: [String: Any?] = [
            "type": "call:signal",
            "payload": [
                "callId": callID.uuidString,
                "toUserId": toUserID,
                "kind": kind.rawValue,
                "ciphertext": ciphertextB64,
                "senderEphemeralPub": senderEphemeralPubB64,
                "senderIdentityPub": senderIdentityPubB64
            ]
        ]
        let compact = Self.compactJSONObject(payload)
        guard let data = try? JSONSerialization.data(withJSONObject: compact),
              let str = String(data: data, encoding: .utf8) else {
            throw Failure.decoding(NSError(domain: "OneWay", code: -1))
        }
        do {
            try await webSocket?.send(.string(str))
        } catch {
            throw Failure.underlying(error)
        }
    }

    // Lifecycle ----------------------------------------------------------

    /// Open the WS up-front (e.g. on app foreground). Idempotent.
    func start() {
        ensureWebSocketStarted()
    }

    /// Close the WS and any pending reconnect. Used on sign-out.
    func stop() {
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        isStarted = false
        attempt = 0
    }

    // MARK: - Private state

    private let baseURL: URL
    private let userID: String
    private let session: URLSession
    private let incomingStream: AsyncStream<SignalingEvent>
    private let eventContinuation: AsyncStream<SignalingEvent>.Continuation

    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var isStarted = false
    private var attempt = 0

    // MARK: - REST plumbing

    private func postJSON<R: Decodable>(_ path: String, body: [String: Any]) async throws -> R {
        guard let url = makeURL(path: path) else {
            throw Failure.http(status: -1, code: "bad_url")
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AuthTokenStore.shared.authorizationHeader(), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.underlying(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw Failure.http(status: -1, code: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            // Try to read error code from body.
            let code = try? JSONDecoder.snakeCamel
                .decode(BackendError.self, from: data).error
            throw Failure.http(status: http.statusCode, code: code)
        }
        do {
            return try JSONDecoder.snakeCamel.decode(R.self, from: data)
        } catch {
            throw Failure.decoding(error)
        }
    }

    private func mintToken(roomName: String) async throws -> CallCredentials {
        let body: [String: Any] = [
            "roomName": roomName,
            "identity": userID,
        ]
        let token: TokenResponse = try await postJSON("/api/livekit/token", body: body)
        guard let url = URL(string: token.url) else {
            throw Failure.http(status: -1, code: "bad_livekit_url")
        }
        return CallCredentials(roomURL: url, token: token.token, iceServers: token.iceServers ?? [])
    }

    private func makeURL(path: String) -> URL? {
        // Path begins with "/api/..." — combine with the base URL safely.
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return baseURL.appendingPathComponent(trimmed)
    }

    // MARK: - WebSocket plumbing

    private func ensureWebSocketStarted() {
        guard !isStarted else { return }
        isStarted = true
        connectWebSocket()
    }

    private func connectWebSocket() {
        guard let url = makeWebSocketURL() else { return }
        print("OneWay signaling WebSocket URL:", url.absoluteString)
        var request = URLRequest(url: url)
        request.setValue(AuthTokenStore.shared.authorizationHeader(),
                         forHTTPHeaderField: "Authorization")

        let task = session.webSocketTask(with: request)
        webSocket = task
        task.resume()
        // Send the auth handshake immediately. This duplicates the bearer
        // header for backends that don't read headers off the upgrade.
        Task { [weak self] in
            await self?.sendAuth()
        }
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    private func makeWebSocketURL() -> URL? {
        let host = baseURL.host?.lowercased()
        if host == canonicalSignalingHost || host == "api." + canonicalSignalingHost {
            return URL(string: "wss://" + canonicalSignalingHost + "/ws/calls")
        }

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http":  components.scheme = "ws"
        default: break
        }
        components.path = (components.path.hasSuffix("/") ? components.path : components.path + "/") + "ws/calls"
        return components.url
    }

    private func sendAuth() async {
        // Strip the "Bearer " prefix for the WS handshake — the server
        // expects the raw token in the payload.
        let header = AuthTokenStore.shared.authorizationHeader()
        let raw = header.hasPrefix("Bearer ") ? String(header.dropFirst("Bearer ".count)) : header
        let payload: [String: Any] = [
            "type": "auth",
            "payload": ["token": raw]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else { return }
        do {
            try await webSocket?.send(.string(str))
        } catch {
            scheduleReconnect()
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled, let socket = webSocket {
            do {
                let message = try await socket.receive()
                handle(message)
            } catch {
                // The socket dropped (network change, backgrounded too long,
                // server restart). Schedule a reconnect with backoff.
                scheduleReconnect()
                return
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let d): data = d
        case .string(let s): data = Data(s.utf8)
        @unknown default: return
        }
        guard let decoded = try? JSONDecoder.snakeCamel.decode(WireMessage.self, from: data) else {
            return
        }
        switch decoded.type {
        case "call:ringing":
            if let call = decoded.payload?.call {
                eventContinuation.yield(.ringing(.init(
                    callID: call.id,
                    callerID: call.callerId,
                    hasVideo: call.hasVideo,
                    roomName: call.roomName
                )))
            }
        case "call:accepted":
            if let call = decoded.payload?.call {
                // Accepted is the moment the *caller* needs credentials. Mint
                // a token now and emit a fully-formed event.
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        let creds = try await self.mintToken(roomName: call.roomName)
                        await self.emit(.accepted(callID: call.id, credentials: creds))
                    } catch {
                        await self.emit(.ended(callID: call.id, reason: .failed))
                    }
                }
            }
        case "call:declined":
            if let call = decoded.payload?.call {
                eventContinuation.yield(.declined(callID: call.id))
            }
        case "call:ended":
            if let call = decoded.payload?.call {
                let reason: SignalingEvent.EndReason = {
                    switch call.status {
                    case "missed": return .missed
                    case "failed": return .failed
                    default: return .ended
                    }
                }()
                eventContinuation.yield(.ended(callID: call.id, reason: reason))
            }
        case "call:state":
            if let call = decoded.payload?.call {
                eventContinuation.yield(.state(callID: call.id, status: call.status))
            }
        case "presence:online":
            if let id = decoded.payload?.userId {
                eventContinuation.yield(.presence(userID: id, online: true))
            }
        case "presence:offline":
            if let id = decoded.payload?.userId {
                eventContinuation.yield(.presence(userID: id, online: false))
            }
        case "call:signal":
            if let signal = decoded.payload?.signal,
               let callID = UUID(uuidString: signal.callId),
               let kind = SignalingEvent.CallSignal.Kind(rawValue: signal.kind) {
                eventContinuation.yield(.signal(.init(
                    callID: callID,
                    fromUserID: signal.fromUserId,
                    kind: kind,
                    ciphertextB64: signal.ciphertext,
                    senderEphemeralPubB64: signal.senderEphemeralPub,
                    senderIdentityPubB64: signal.senderIdentityPub
                )))
            }
        case "error":
            // Server-side error — log via NSLog so it shows up in device logs
            // without a separate logger dependency.
            #if DEBUG
            print("[Signaling] server error: \(decoded.payload?.message ?? "?")")
            #endif
        default:
            break
        }
    }

    private func emit(_ event: SignalingEvent) {
        eventContinuation.yield(event)
    }

    private func scheduleReconnect() {
        guard isStarted, reconnectTask == nil else { return }
        let delay = min(30, pow(2.0, Double(attempt)))
        attempt += 1
        let nanos = UInt64(delay * 1_000_000_000)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            await self?.performReconnect()
        }
    }

    private func performReconnect() {
        reconnectTask = nil
        guard isStarted else { return }
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        connectWebSocket()
    }
}

// MARK: - Wire types

private struct CallEnvelope: Decodable {
    let call: WireCall
}

private struct WireCall: Decodable {
    let id: UUID
    let roomName: String
    let callerId: String
    let calleeId: String
    let status: String
    let hasVideo: Bool

    enum CodingKeys: String, CodingKey {
        // Matches the JSON `"callId"` field but renamed locally to `id` for
        // ergonomics. The other keys decode straight off the snake-case
        // strategy we install on the decoder.
        case id = "callId"
        case roomName, callerId, calleeId, status, hasVideo
    }
}

private struct TokenResponse: Decodable {
    let url: String
    let token: String
    let roomName: String
    let iceServers: [TurnServerConfiguration]?
}

private struct BackendError: Decodable {
    let error: String
}

private struct WireMessage: Decodable {
    let type: String
    let payload: WirePayload?
}

private struct WirePayload: Decodable {
    let call: WireCall?
    let userId: String?
    let message: String?
    let code: String?
    let signal: WireSignal?
}

private struct WireSignal: Decodable {
    let callId: String
    let fromUserId: String
    let kind: String
    let ciphertext: String
    let senderEphemeralPub: String?
    let senderIdentityPub: String?
}

// MARK: - Helpers

private extension JSONDecoder {
    /// Server uses camelCase JSON. We *also* tolerate a stray `_` separator
    /// by using `.convertFromSnakeCase` — harmless when the keys are already
    /// camelCase because no underscores are present to convert.
    static let snakeCamel: JSONDecoder = {
        let d = JSONDecoder()
        // No conversion; we declare CodingKeys explicitly where needed.
        return d
    }()
}

extension URLSession {
    /// Configuration tuned for signalling: longer resource timeout (so the WS
    /// can stay open), short request timeout for REST calls.
    static let signalingDefault: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 60 * 60
        config.waitsForConnectivity = true
        config.httpAdditionalHeaders = ["User-Agent": "OneWay/iOS Signaling"]
        return URLSession(configuration: config)
    }()
}

// MARK: - JSON helpers

private extension NetworkCallSignalingClient {
    /// Removes `nil` values from a JSON object tree so `JSONSerialization`
    /// won't crash on `NSNull` in optional fields we omit.
    static func compactJSONObject(_ obj: Any) -> Any {
        if let dict = obj as? [String: Any?] {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                guard let v else { continue }
                out[k] = compactJSONObject(v)
            }
            return out
        }
        if let dict = obj as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                out[k] = compactJSONObject(v)
            }
            return out
        }
        if let arr = obj as? [Any?] {
            return arr.compactMap { $0 }.map { compactJSONObject($0) }
        }
        if let arr = obj as? [Any] {
            return arr.map { compactJSONObject($0) }
        }
        return obj
    }
}
