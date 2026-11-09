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
    ///   - baseURL: API base, e.g. `https://api.oneway.is`. Used for REST calls.
    ///   - webSocketURL: optional explicit signaling URL when WebSocket traffic
    ///     is hosted on a different public origin than the REST API.
    ///   - userID: the local user's id. Sent as `Bearer dev:<id>` until real
    ///     auth is in.
    ///   - session: injectable for tests.
    init(baseURL: URL,
         webSocketURL: URL? = nil,
         userID: String,
         session: URLSession = .signalingDefault) {
        self.baseURL = baseURL
        self.webSocketURL = webSocketURL
        self.userID = userID
        self.session = session
        let (stream, continuation) = AsyncStream<SignalingEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        self.incomingStream = stream
        self.eventContinuation = continuation
        Task { [weak self] in await self?.observeAppLifecycle() }
        Task { [weak self] in await self?.observeAuthChanges() }
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

    private func observeAuthChanges() async {
        for await _ in NotificationCenter.default.notifications(named: AuthTokenStore.tokenDidChangeNotification) {
            handleAuthChanged()
        }
    }

    private func handleAuthChanged() {
        authRejectedCount = 0
        attempt = 0
        guard isStarted else {
            ensureWebSocketStarted()
            return
        }
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        connectWebSocket()
    }

    // CallSignalingClient — REST surface ---------------------------------

    nonisolated var incomingEvents: AsyncStream<SignalingEvent> { incomingStream }

    func invite(chatID: UUID, callID: UUID, type: CallType) async throws -> CallCredentials {
        ensureWebSocketStarted()
        let body: [String: Any] = [
            "recipientUserId": chatID.uuidString,
            "type": type == .video ? "video" : "audio"
        ]
        let envelope: CallEnvelope = try await postJSON(CallAPIPath.create, body: body)
        // Join through the authoritative call session. The backend owns the
        // room name and issues the media token for both caller and recipient.
        return try await join(callID: envelope.call.id)
    }

    func accept(callID: UUID) async throws -> CallCredentials {
        ensureWebSocketStarted()
        #if DEBUG
        print("📞 OneWay signaling accept request:", PrivacyLog.shortID(callID.uuidString))
        #endif
        let envelope: CallEnvelope = try await postJSON(CallAPIPath.accept(callID), body: [:])
        #if DEBUG
        logVideoCallTimeline(
            "video.call.accepted.backend",
            call: envelope.call,
            roomName: envelope.call.roomName,
            participantIdentity: envelope.participantIdentity
        )
        #endif
        let credentials = try await join(callID: envelope.call.id)
        #if DEBUG
        logVideoCallTimeline(
            "video.call.token.received",
            call: envelope.call,
            roomName: envelope.call.roomName,
            participantIdentity: credentials.participantIdentity
        )
        #endif
        return credentials
    }

    func join(callID: UUID) async throws -> CallCredentials {
        ensureWebSocketStarted()
        let envelope: CallEnvelope = try await postJSON(CallAPIPath.join(callID), body: [:])
        #if DEBUG
        logVideoCallTimeline(
            "video.call.join.token.received",
            call: envelope.call,
            roomName: envelope.call.roomName,
            participantIdentity: envelope.participantIdentity
        )
        #endif
        guard let credentials = try credentialsFromAcceptEnvelope(envelope) else {
            return try await mintToken(roomName: envelope.call.roomName, callID: envelope.call.id)
        }
        return credentials
    }

    func mediaReady(callID: UUID, audioPublished: Bool, videoPublished: Bool) async throws {
        let body: [String: Any] = [
            "audioPublished": audioPublished,
            "videoPublished": videoPublished
        ]
        let _: CallEnvelope = try await postJSON(CallAPIPath.mediaReady(callID), body: body)
    }

    func decline(callID: UUID) async throws {
        let body: [String: Any] = ["callId": callID.uuidString]
        let _: CallEnvelope = try await postJSON("/api/calls/decline", body: body)
    }

    func hangup(callID: UUID) async throws {
        try await hangup(callID: callID, reason: .localHangup, source: .inCallButton, operationID: UUID())
    }

    func hangup(callID: UUID, reason: CallEndReason, source: CallEndSource, operationID: UUID) async throws {
        let body: [String: Any] = [
            "reason": reason.rawValue,
            "source": source.rawValue,
            "endedByUserId": userID,
            "clientOperationId": operationID.uuidString
        ]
        let _: CallEnvelope = try await postJSON(CallAPIPath.end(callID), body: body)
    }

    func fetchSnapshot(callID: UUID) async throws -> CallSignalingSnapshot {
        let envelope: CallEnvelope = try await getJSON(CallAPIPath.get(callID))
        return envelope.call.signalingSnapshot
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
    func start() async {
        ensureWebSocketStarted()
    }

    /// Close the WS and any pending reconnect. Used on sign-out.
    func stop() async {
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
    private var authRejectedCount = 0
    private let maxAuthRejectedReconnects = 3
    private let webSocketURL: URL?
#if DEBUG
    private var useDebugLANWebSocketFallback = false
    private var debugLANWebSocketFallbackIndex = 0
#endif

    // MARK: - REST plumbing

    private func postJSON<R: Decodable>(_ path: String, body: [String: Any]) async throws -> R {
        guard let url = makeURL(path: path) else {
            throw Failure.http(status: -1, code: "bad_url")
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let authorization = authorizationHeader(forPath: path) else {
            throw Failure.missingAuth
        }
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
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
            #if DEBUG
            let body = String(data: data, encoding: .utf8) ?? ""
            print("❌ OneWay signaling request failed:", PrivacyLog.redact(path), http.statusCode, code ?? "unknown", PrivacyLog.redact(body))
            #endif
            throw Failure.http(status: http.statusCode, code: code)
        }
        do {
            return try JSONDecoder.snakeCamel.decode(R.self, from: data)
        } catch {
            throw Failure.decoding(error)
        }
    }

    private func getJSON<R: Decodable>(_ path: String) async throws -> R {
        guard let url = makeURL(path: path) else {
            throw Failure.http(status: -1, code: "bad_url")
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let authorization = authorizationHeader(forPath: path) else {
            throw Failure.missingAuth
        }
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

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

    private func mintToken(roomName: String, callID: UUID? = nil) async throws -> CallCredentials {
        let body: [String: Any] = [
            "roomName": roomName,
            "identity": userID,
        ]
        let token: TokenResponse = try await postJSON("/api/livekit/token", body: body)
        #if DEBUG
        print("📞 OneWay LiveKit token response:", PrivacyLog.shortID(roomName), PrivacyLog.redact(token.url))
        #endif
        guard let url = URL(string: token.url) else {
            throw Failure.http(status: -1, code: "bad_livekit_url")
        }
        return CallCredentials(
            roomURL: url,
            token: token.token,
            iceServers: token.iceServers ?? [],
            callID: callID,
            participantIdentity: token.participantIdentity
        )
    }

    private func credentialsFromAcceptEnvelope(_ envelope: CallEnvelope) throws -> CallCredentials? {
        guard let liveKitToken = envelope.liveKitToken,
              let liveKitUrl = envelope.liveKitUrl,
              let url = URL(string: liveKitUrl) else {
            return nil
        }
        return CallCredentials(
            roomURL: url,
            token: liveKitToken,
            iceServers: envelope.iceServers ?? [],
            callID: envelope.call.id,
            participantIdentity: envelope.participantIdentity
        )
    }

    private func makeURL(path: String) -> URL? {
        // Path begins with "/api/..." — combine with the base URL safely.
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return baseURL.appendingPathComponent(trimmed)
    }

    // MARK: - WebSocket plumbing

    private func ensureWebSocketStarted() {
        guard !isStarted else { return }
        guard authorizationHeader(forPath: "ws/calls") != nil else {
            #if DEBUG
            print("OneWay signaling start deferred; auth token unavailable")
            #endif
            return
        }
        isStarted = true
        connectWebSocket()
    }

    private func connectWebSocket() {
        guard let url = makeWebSocketURL() else { return }
        var request = URLRequest(url: url)
        guard let authorization = authorizationHeader(forPath: "ws/calls") else {
            #if DEBUG
            print("OneWay signaling waiting for auth token before WebSocket connect")
            #endif
            return
        }
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

        #if DEBUG
        print("OneWay signaling connect caller:", #fileID, #function)
        print("OneWay signaling WebSocket URL:", redactedWebSocketURL(url))
        print("OneWay signaling auth header attached:", !authorization.isEmpty)
        #endif
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
#if DEBUG
        if useDebugLANWebSocketFallback,
           APIConfig.debugLocalOverrideEnabled,
           let rawFallbackURL = debugLANWebSocketFallbackURLString(),
           let fallbackURL = URL(string: rawFallbackURL) {
            return fallbackURL
        }
#endif
        if let webSocketURL {
            return webSocketURL
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
        if DevAuth.authorizationHeader(forPath: "ws/calls", baseURL: baseURL) != nil {
            components.queryItems = [URLQueryItem(name: "token", value: authToken(forPath: "ws/calls"))]
        }
        return components.url
    }

#if DEBUG
    private func debugLANWebSocketFallbackURLString() -> String? {
        let urls = APIConfig.debugLANSignalingWebSocketURLs
        guard !urls.isEmpty else { return nil }
        if urls.indices.contains(debugLANWebSocketFallbackIndex) {
            return urls[debugLANWebSocketFallbackIndex]
        }
        return urls.first
    }

    private func shouldUseDebugLANWebSocketFallback(after error: Error) -> Bool {
        guard APIConfig.debugLocalOverrideEnabled else {
            return false
        }

        guard let url = makeWebSocketURL() else {
            return false
        }

        if useDebugLANWebSocketFallback {
            return debugLANWebSocketFallbackIndex + 1 < APIConfig.debugLANSignalingWebSocketURLs.count
        }

        guard url.host?.lowercased() == "api.oneway.is" else { return false }

        guard let urlError = error as? URLError else {
            return true
        }

        switch urlError.code {
        case .timedOut,
             .cannotConnectToHost,
             .cannotFindHost,
             .networkConnectionLost,
             .notConnectedToInternet,
             .dnsLookupFailed,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
    }
#endif

    private func sendAuth() async {
        // Strip the "Bearer " prefix for the WS handshake — the server
        // expects the raw token in the payload.
        let raw = authToken(forPath: "ws/calls")
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
#if DEBUG
                if shouldUseDebugLANWebSocketFallback(after: error) {
                    if useDebugLANWebSocketFallback {
                        debugLANWebSocketFallbackIndex += 1
                    } else {
                        useDebugLANWebSocketFallback = true
                        debugLANWebSocketFallbackIndex = 0
                    }
                    attempt = 0
                    let fallback = debugLANWebSocketFallbackURLString() ?? "none"
                    print("OneWay signaling WebSocket failed, retrying LAN fallback:", PrivacyLog.redact(fallback))
                }
#endif
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
                let currentUserID = AuthTokenStore.shared.currentUserID()
                guard call.calleeId.caseInsensitiveCompare(currentUserID) == .orderedSame else {
                    #if DEBUG
                    print("Ignoring call:ringing not addressed to current user for callId=\(call.id)")
                    #endif
                    return
                }
                if call.callerId.caseInsensitiveCompare(currentUserID) == .orderedSame {
                    #if DEBUG
                    print("Ignoring self-originated call:ringing for callId=\(call.id)")
                    #endif
                    return
                }
                eventContinuation.yield(.ringing(.init(
                    callID: call.id,
                    callerID: call.callerId,
                    hasVideo: call.hasVideo,
                    roomName: call.roomName
                )))
            }
        case "call:accepted":
            if let call = decoded.payload?.call {
                let currentUserID = AuthTokenStore.shared.currentUserID()
                guard call.callerId.caseInsensitiveCompare(currentUserID) == .orderedSame else {
                    #if DEBUG
                    print(
                        "Ignoring call:accepted not addressed to caller",
                        "callId=\(PrivacyLog.shortID(call.id.uuidString))",
                        "currentUser=\(PrivacyLog.shortID(currentUserID))",
                        "caller=\(PrivacyLog.shortID(call.callerId))"
                    )
                    #endif
                    return
                }
                #if DEBUG
                logVideoCallTimeline("video.call.accepted.event.received", call: call, roomName: call.roomName)
                #endif
                // Accepted is the moment the *caller* needs authoritative
                // join credentials for the stored CallSession room.
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        let creds = try await self.join(callID: call.id)
                        await self.emit(.accepted(callID: call.id, credentials: creds))
                    } catch {
                        await self.emit(.ended(callID: call.id, reason: .failed, metadata: .empty))
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
                eventContinuation.yield(.ended(
                    callID: call.id,
                    reason: reason,
                    metadata: .init(
                        endedByUserId: call.endedByUserId,
                        operationId: call.endOperationIds?.last,
                        sessionVersion: call.version,
                        endedAt: call.endedAt
                    )
                ))
            }
        case "call:state":
            if let call = decoded.payload?.call {
                let currentUserID = AuthTokenStore.shared.currentUserID()
                if call.status == "ringing",
                   call.calleeId.caseInsensitiveCompare(currentUserID) == .orderedSame,
                   call.callerId.caseInsensitiveCompare(currentUserID) != .orderedSame {
                    eventContinuation.yield(.ringing(.init(
                        callID: call.id,
                        callerID: call.callerId,
                        hasVideo: call.hasVideo,
                        roomName: call.roomName
                    )))
                    return
                }
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
            print("[Signaling] server error: \(PrivacyLog.redact(decoded.payload?.message ?? "?"))")
            #endif
            if isAuthRejected(decoded.payload) {
                authRejectedCount += 1
                if authRejectedCount >= maxAuthRejectedReconnects {
                    stopReconnectStorm()
                }
            }
        default:
            authRejectedCount = 0
            break
        }
    }

    private func emit(_ event: SignalingEvent) {
        eventContinuation.yield(event)
    }

    private func scheduleReconnect() {
        guard isStarted,
              reconnectTask == nil,
              authRejectedCount < maxAuthRejectedReconnects else { return }
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

    private func authorizationHeader(forPath path: String) -> String? {
        if let devHeader = DevAuth.authorizationHeader(forPath: path, baseURL: baseURL) {
            return devHeader
        }
        guard let token = AuthTokenStore.shared.token() else {
            return nil
        }
        return "Bearer \(token)"
    }

    private func authToken(forPath path: String) -> String {
        guard let header = authorizationHeader(forPath: path) else { return "" }
        return header.hasPrefix("Bearer ") ? String(header.dropFirst("Bearer ".count)) : header
    }

    private func isAuthRejected(_ payload: WirePayload?) -> Bool {
        let code = payload?.code?.lowercased() ?? ""
        let message = payload?.message?.lowercased() ?? ""
        return code == "bad_token" || message.contains("auth rejected")
    }

    private func stopReconnectStorm() {
        #if DEBUG
        print("Stopping websocket reconnect storm after auth rejection")
        #endif
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        webSocket?.cancel(with: .policyViolation, reason: Data("auth rejected".utf8))
        webSocket = nil
        isStarted = false
    }

    private func redactedWebSocketURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return PrivacyLog.redact(url.absoluteString)
        }
        components.queryItems = components.queryItems?.map { item in
            if item.name == "token" || item.name == "access_token" {
                return URLQueryItem(name: item.name, value: "<redacted>")
            }
            return item
        }
        return PrivacyLog.redact(components.url?.absoluteString ?? url.absoluteString)
    }
}

#if DEBUG
private func logVideoCallTimeline(
    _ event: String,
    call: WireCall,
    roomName: String,
    participantIdentity: String? = nil,
    errorCode: String? = nil
) {
    guard call.hasVideo else { return }
    print(
        "📹 OneWay timeline",
        "event=\(event)",
        "callId=\(PrivacyLog.shortID(call.id.uuidString))",
        "callerUserId=\(PrivacyLog.shortID(call.callerId))",
        "recipientUserId=\(PrivacyLog.shortID(call.calleeId))",
        "currentUserId=\(PrivacyLog.shortID(AuthTokenStore.shared.currentUserID()))",
        "roomName=\(PrivacyLog.shortID(roomName))",
        "participantIdentity=\(PrivacyLog.shortID(participantIdentity))",
        "callStatus=\(call.status)",
        "timestamp=\(ISO8601DateFormatter().string(from: Date()))",
        "errorCode=\(errorCode ?? "none")"
    )
}
#endif

// MARK: - Wire types

private enum CallAPIPath {
    static let create = "/api/calls"

    static func get(_ callID: UUID) -> String {
        "/api/calls/\(callID.uuidString.lowercased())"
    }

    static func accept(_ callID: UUID) -> String {
        "/api/calls/\(callID.uuidString.lowercased())/accept"
    }

    static func join(_ callID: UUID) -> String {
        "/api/calls/\(callID.uuidString.lowercased())/join"
    }

    static func mediaReady(_ callID: UUID) -> String {
        "/api/calls/\(callID.uuidString.lowercased())/media-ready"
    }

    static func end(_ callID: UUID) -> String {
        "/api/calls/\(callID.uuidString.lowercased())/end"
    }
}

private struct CallEnvelope: Decodable {
    let call: WireCall
    let liveKitToken: String?
    let liveKitUrl: String?
    let roomName: String?
    let participantIdentity: String?
    let iceServers: [TurnServerConfiguration]?

    private enum CodingKeys: String, CodingKey {
        case call
        case liveKitToken
        case liveKitUrl
        case livekitUrl
        case roomName
        case participantIdentity
        case iceServers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        call = try container.decode(WireCall.self, forKey: .call)
        liveKitToken = try container.decodeIfPresent(String.self, forKey: .liveKitToken)
        liveKitUrl = try container.decodeIfPresent(String.self, forKey: .liveKitUrl)
            ?? container.decodeIfPresent(String.self, forKey: .livekitUrl)
        roomName = try container.decodeIfPresent(String.self, forKey: .roomName)
        participantIdentity = try container.decodeIfPresent(String.self, forKey: .participantIdentity)
        iceServers = try container.decodeIfPresent([TurnServerConfiguration].self, forKey: .iceServers)
    }
}

private struct WireCall: Decodable {
    let id: UUID
    let roomName: String
    let callerId: String
    let calleeId: String
    let status: String
    let hasVideo: Bool
    let version: Int?
    let endedByUserId: String?
    let endOperationIds: [String]?
    let endedAt: String?

    enum CodingKeys: String, CodingKey {
        // Matches the JSON `"callId"` field but renamed locally to `id` for
        // ergonomics. The other keys decode straight off the snake-case
        // strategy we install on the decoder.
        case id = "callId"
        case roomName, callerId, calleeId, status, hasVideo, version, endedByUserId, endOperationIds, endedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        roomName = try container.decode(String.self, forKey: .roomName)
        callerId = try container.decode(String.self, forKey: .callerId)
        calleeId = try container.decode(String.self, forKey: .calleeId)
        status = try container.decode(String.self, forKey: .status)
        hasVideo = try container.decode(Bool.self, forKey: .hasVideo)
        version = try container.decodeIfPresent(Int.self, forKey: .version)
        endedByUserId = try container.decodeIfPresent(String.self, forKey: .endedByUserId)
        endOperationIds = try container.decodeIfPresent([String].self, forKey: .endOperationIds)
        if let value = try? container.decodeIfPresent(String.self, forKey: .endedAt) {
            endedAt = value
        } else if let value = try? container.decodeIfPresent(Int.self, forKey: .endedAt) {
            endedAt = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(value) / 1000.0))
        } else {
            endedAt = nil
        }
    }

    var signalingSnapshot: CallSignalingSnapshot {
        CallSignalingSnapshot(
            callID: id,
            status: status,
            endedByUserId: endedByUserId,
            operationId: endOperationIds?.last,
            sessionVersion: version,
            endedAt: endedAt
        )
    }
}

private struct TokenResponse: Decodable {
    let url: String
    let token: String
    let roomName: String
    let participantIdentity: String?
    let iceServers: [TurnServerConfiguration]?

    private enum CodingKeys: String, CodingKey {
        case url
        case liveKitUrl
        case livekitUrl
        case token
        case roomName
        case participantIdentity
        case iceServers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let resolvedURL = try container.decodeIfPresent(String.self, forKey: .url)
            ?? container.decodeIfPresent(String.self, forKey: .liveKitUrl)
            ?? container.decodeIfPresent(String.self, forKey: .livekitUrl) else {
            throw DecodingError.keyNotFound(
                CodingKeys.url,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "LiveKit token response did not include url/liveKitUrl."
                )
            )
        }
        url = resolvedURL
        token = try container.decode(String.self, forKey: .token)
        roomName = try container.decode(String.self, forKey: .roomName)
        participantIdentity = try container.decodeIfPresent(String.self, forKey: .participantIdentity)
        iceServers = try container.decodeIfPresent([TurnServerConfiguration].self, forKey: .iceServers)
    }
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
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 60 * 60
        config.waitsForConnectivity = false
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
