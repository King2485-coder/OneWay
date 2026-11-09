import Foundation

#if canImport(LiveKit)
import AVFoundation
import Combine
import LiveKit
import SwiftUI

struct LiveKitTokenResponse: Codable {
    struct IceServerConfig: Codable {
        let urls: [String]
        let username: String?
        let credential: String?
    }

    let token: String
    let url: String?
    let iceServers: [IceServerConfig]?

    private enum CodingKeys: String, CodingKey {
        case token
        case url
        case liveKitUrl
        case livekitUrl
        case iceServers
    }

    init(token: String, url: String?, iceServers: [IceServerConfig]?) {
        self.token = token
        self.url = url
        self.iceServers = iceServers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(String.self, forKey: .token)
        url = try container.decodeIfPresent(String.self, forKey: .url)
            ?? container.decodeIfPresent(String.self, forKey: .liveKitUrl)
            ?? container.decodeIfPresent(String.self, forKey: .livekitUrl)
        iceServers = try container.decodeIfPresent([IceServerConfig].self, forKey: .iceServers)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(token, forKey: .token)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encodeIfPresent(url, forKey: .liveKitUrl)
        try container.encodeIfPresent(iceServers, forKey: .iceServers)
    }
}

struct LiveKitInviteResponse: Decodable {
    let ok: Bool
    let callId: String
    let roomName: String
    let callerName: String
}

enum LiveKitManagerError: LocalizedError {
    case missingRoom
    case invalidLiveKitURL(String)
    case roomNotConnected
    case microphonePermissionDenied

    var errorDescription: String? {
        switch self {
        case .missingRoom:
            return "Missing room name."
        case .invalidLiveKitURL(let value):
            return "Invalid LiveKit URL: \(value)"
        case .roomNotConnected:
            return "Room not connected."
        case .microphonePermissionDenied:
            return "Microphone permission is required for calls."
        }
    }
}

@MainActor
final class LiveKitManager: ObservableObject {
    static let shared = LiveKitManager()

    @Published var room: Room?
    @Published var isConnected = false
    @Published var isReconnecting = false
    @Published var remoteParticipants: [RemoteParticipant] = []
    @Published var currentRoomName: String?
    @Published var activeCallUUID: UUID?
    @Published var isPresentingGroupCall = false
    @Published var isMicrophoneEnabled = true
    @Published var isCameraEnabled = true
    @Published var lastErrorMessage: String?
    @Published var backendState: BackendConnectionState = .checking

    var pendingRoomName: String?

    private let client: APIClient
    private var reconnectTask: Task<Void, Never>?
    private var reconnectWithCamera = true
    private var reconnectTokenResponseOverride: LiveKitTokenResponse?

    private init(client: APIClient = .shared) {
        self.client = client
    }

    func validateBackend() async {
        backendState = .checking
        backendState = await client.health()
    }

    func startCall(
        roomName: String,
        userId: String,
        calleeUserId: String? = nil,
        callerName: String? = nil,
        callUUID: UUID? = nil
    ) async throws {
        activeCallUUID = callUUID
        lastErrorMessage = nil
        var resolvedRoomName = roomName

        if let calleeUserId {
            let invite = try await invite(
                calleeUserId: calleeUserId,
                callerName: callerName ?? userId,
                roomName: roomName
            )
            resolvedRoomName = invite.roomName
        }

        pendingRoomName = resolvedRoomName
        try await connect(roomName: resolvedRoomName, userId: userId)

        guard room != nil else {
            throw LiveKitManagerError.roomNotConnected
        }

        LaunchTelemetry.shared.track("call_started", parameters: [
            "room_name": resolvedRoomName,
            "call_type": "video"
        ])
    }

    func acceptIncomingCall() async throws {
        let roomName = pendingRoomName ?? "default-room"
        let userId = AppEnvironment.shared.currentUserID
        try await connect(roomName: roomName, userId: userId)
    }

    func connect(roomName: String, userId: String) async throws {
        reconnectTokenResponseOverride = nil
        try await connectInternal(
            roomName: roomName,
            userId: userId,
            tokenResponseOverride: nil,
            enableCamera: true
        )
    }

    func connectExternalBridge(
        roomName: String,
        userId: String,
        liveKitURL: String,
        token: String,
        callUUID: UUID?
    ) async throws {
        activeCallUUID = callUUID
        let override = LiveKitTokenResponse(token: token, url: liveKitURL, iceServers: nil)
        reconnectTokenResponseOverride = override
        try await connectInternal(
            roomName: roomName,
            userId: userId,
            tokenResponseOverride: override,
            enableCamera: false,
            presentCallUI: false
        )
    }

    private func connectInternal(
        roomName: String,
        userId: String,
        tokenResponseOverride: LiveKitTokenResponse?,
        enableCamera: Bool,
        presentCallUI: Bool = true
    ) async throws {
        guard !roomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LiveKitManagerError.missingRoom
        }

        reconnectTask?.cancel()
        await validateBackend()
        reconnectWithCamera = enableCamera

        do {
            let tokenResponse: LiveKitTokenResponse
            if let tokenResponseOverride {
                tokenResponse = tokenResponseOverride
            } else {
                tokenResponse = try await fetchLiveKitToken(roomName: roomName, userId: userId)
            }
            let iceServerConfigs: [LiveKitTokenResponse.IceServerConfig] = tokenResponse.iceServers ?? []
            let iceServers: [IceServer] = iceServerConfigs.map { config in
                IceServer(urls: config.urls, username: config.username, credential: config.credential)
            }

            let liveKitURL = try resolveLiveKitConnectURL(from: tokenResponse)

            let connectOptions = ConnectOptions(
                autoSubscribe: true,
                reconnectAttempts: 8,
                reconnectAttemptDelay: 0.8,
                reconnectMaxDelay: 6.0,
                iceServers: iceServers,
                iceTransportPolicy: .all
            )
            let roomOptions = RoomOptions(
                defaultCameraCaptureOptions: CameraCaptureOptions(
                    position: .front,
                    dimensions: .h720_169,
                    fps: 24
                ),
                defaultAudioCaptureOptions: AudioCaptureOptions(
                    echoCancellation: true,
                    autoGainControl: true,
                    noiseSuppression: true
                ),
                adaptiveStream: true,
                dynacast: true
            )

            let room = Room(delegate: self, connectOptions: connectOptions, roomOptions: roomOptions)

            self.room = room
            self.currentRoomName = roomName
            self.pendingRoomName = roomName

            guard await requestMicrophonePermission() else {
                throw LiveKitManagerError.microphonePermissionDenied
            }
            try await configureAudioSession()
            logAudioRoute(context: "before LiveKit connect")

            print("LiveKit connect caller:", #fileID, #function)
            print("LiveKit connect URL:", PrivacyLog.redact(liveKitURL.absoluteString))
            print("🚀 Connecting to:", PrivacyLog.redact(liveKitURL.absoluteString))
            print("👤 User:", PrivacyLog.shortID(userId))
            print("🏠 Room:", PrivacyLog.shortID(roomName))
            if let iceServers = tokenResponse.iceServers {
                print("🧊 ICE servers:", PrivacyLog.redact(iceServers.flatMap { $0.urls }))
            }
            logLiveKitTokenClaims(
                tokenResponse.token,
                liveKitURL: liveKitURL.absoluteString,
                expectedRoom: roomName,
                source: tokenResponseOverride == nil ? "api/livekit/token" : "pstn/calls/start"
            )

            try await room.connect(url: liveKitURL.absoluteString, token: tokenResponse.token)
            try await configureAudioSession()
            logAudioRoute(context: "after LiveKit connect")
            try await room.localParticipant.setMicrophone(enabled: true)
            logAudioRoute(context: "after microphone publish")
            if enableCamera {
                try await room.localParticipant.setCamera(
                    enabled: true,
                    captureOptions: CameraCaptureOptions(
                        position: .front,
                        dimensions: .h720_169,
                        fps: 24
                    )
                )
                isCameraEnabled = true
            } else {
                _ = try? await room.localParticipant.setCamera(enabled: false)
                isCameraEnabled = false
            }
            forceSpeaker()

            isConnected = true
            isReconnecting = false
            isPresentingGroupCall = presentCallUI
            isMicrophoneEnabled = true
            lastErrorMessage = nil
            refreshRemoteParticipants(for: room)

            print("✅ Connected to LiveKit")
        } catch {
            room = nil
            isConnected = false
            isReconnecting = false
            lastErrorMessage = error.localizedDescription
            LaunchTelemetry.shared.capture(
                error: error,
                context: "livekit_connect",
                extras: ["room_name": roomName, "user_id": userId]
            )
            LaunchTelemetry.shared.track("call_failed", parameters: [
                "room_name": roomName
            ])
            print("❌ LiveKit connect failed:", error)
            if isLiveKitAuthRejection(error.localizedDescription) {
                disableManualReconnect(after: error.localizedDescription)
            } else {
                scheduleManualReconnectIfNeeded()
            }
            throw error
        }
    }

    func disconnect() async {
        let disconnectedRoomName = currentRoomName
        let wasConnected = isConnected
        reconnectTask?.cancel()
        await room?.disconnect()
        room = nil
        isConnected = false
        isReconnecting = false
        remoteParticipants = []
        currentRoomName = nil
        pendingRoomName = nil
        reconnectTokenResponseOverride = nil
        isPresentingGroupCall = false
        isMicrophoneEnabled = true
        isCameraEnabled = true
        activeCallUUID = nil

        if wasConnected {
            LaunchTelemetry.shared.track("call_ended", parameters: [
                "room_name": disconnectedRoomName ?? "unknown"
            ])
        }
    }

    func toggleMic() async {
        guard let participant = room?.localParticipant else { return }
        let enabled = !isMicrophoneEnabled
        _ = try? await participant.setMicrophone(enabled: enabled)
        isMicrophoneEnabled = enabled
    }

    func toggleCamera() async {
        guard let participant = room?.localParticipant else { return }
        let enabled = !isCameraEnabled
        _ = try? await participant.setCamera(enabled: enabled)
        isCameraEnabled = enabled
    }

    func invite(calleeUserId: String, callerName: String, roomName: String) async throws -> LiveKitInviteResponse {
        struct InviteRequest: Encodable {
            let calleeUserId: String
            let callerName: String
            let roomName: String
            let hasVideo: Bool
        }

        return try await client.post(
            "calls/invite",
            body: InviteRequest(
                calleeUserId: calleeUserId,
                callerName: callerName,
                roomName: roomName,
                hasVideo: true
            )
        )
    }

    private func fetchLiveKitToken(roomName: String, userId: String) async throws -> LiveKitTokenResponse {
        struct TokenRequest: Encodable {
            let roomName: String
            let identity: String
        }

        return try await client.post(
            "api/livekit/token",
            body: TokenRequest(roomName: roomName, identity: userId),
            requiresAuth: true
        )
    }

    private func resolveLiveKitConnectURL(from response: LiveKitTokenResponse) throws -> URL {
        let rawURL = response.url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawURL.isEmpty else {
            throw LiveKitManagerError.invalidLiveKitURL("missing LiveKit URL from token response")
        }
        guard let url = URL(string: rawURL) else {
            throw LiveKitManagerError.invalidLiveKitURL(rawURL)
        }
        guard isLiveKitWebSocketURL(url), !isAPIBackendURL(url), !url.absoluteString.contains(":3000") else {
            throw LiveKitManagerError.invalidLiveKitURL(
                "\(rawURL) is not a LiveKit signaling URL. Expected ws(s):// LiveKit, not the OneWay API backend."
            )
        }
        return url
    }

    private func isLiveKitWebSocketURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "ws" || scheme == "wss"
    }

    private func isAPIBackendURL(_ url: URL) -> Bool {
        guard let liveKitHost = url.host?.lowercased(),
              let apiHost = client.baseURL.host?.lowercased(),
              liveKitHost == apiHost else {
            return false
        }
        let liveKitPort = resolvedPort(for: url)
        let apiPort = resolvedPort(for: client.baseURL)
        return liveKitPort == apiPort
    }

    private func resolvedPort(for url: URL) -> Int? {
        if let port = url.port {
            return port
        }
        switch url.scheme?.lowercased() {
        case "http", "ws":
            return 80
        case "https", "wss":
            return 443
        default:
            return nil
        }
    }

    private func configureAudioSession() async throws {
        CallAudioSessionCoordinator.shared.liveKitConfigurationRequest(video: true, owner: "LiveKitManager.configureAudioSession")
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func logAudioRoute(context: String) {
        #if DEBUG
        let session = AVAudioSession.sharedInstance()
        let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }
        let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }
        print(
            "🎧 Audio route \(context): " +
            "category=\(session.category.rawValue) mode=\(session.mode.rawValue) " +
            "inputs=\(inputs) outputs=\(outputs) sampleRate=\(session.sampleRate) " +
            "ioBuffer=\(session.ioBufferDuration)"
        )
        #endif
    }

    private func forceSpeaker() {
        CallAudioSessionCoordinator.shared.skipRouteOverride(owner: "LiveKitManager.forceSpeaker", requestedRoute: "speaker")
    }

    private func refreshRemoteParticipants(for room: Room) {
        remoteParticipants = Array(room.remoteParticipants.values)
        if remoteParticipants.count > 8 {
            Task {
                _ = try? await room.localParticipant.setCamera(enabled: false)
                await MainActor.run {
                    self.isCameraEnabled = false
                }
            }
        }
    }

    private func scheduleManualReconnectIfNeeded() {
        guard pendingRoomName != nil else { return }

        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled,
                  !self.isConnected,
                  let roomName = self.pendingRoomName else { return }

            _ = try? await self.connectInternal(
                roomName: roomName,
                userId: AppEnvironment.shared.currentUserID,
                tokenResponseOverride: self.reconnectTokenResponseOverride,
                enableCamera: self.reconnectWithCamera
            )
        }
    }

    private func disableManualReconnect(after reason: String?) {
        reconnectTask?.cancel()
        reconnectTask = nil
        pendingRoomName = nil
        reconnectTokenResponseOverride = nil
        #if DEBUG
        print("🛑 LiveKit auth rejected; manual reconnect disabled:", reason ?? "unknown")
        #endif
    }

    private func isLiveKitAuthRejection(_ message: String?) -> Bool {
        let lower = (message ?? "").lowercased()
        return lower.contains("auth rejected")
            || lower.contains("authentication")
            || lower.contains("not authorized")
            || lower.contains("invalid token")
            || lower.contains("token is expired")
    }

    private func logLiveKitTokenClaims(
        _ token: String,
        liveKitURL: String,
        expectedRoom: String,
        source: String
    ) {
        #if DEBUG
        guard let payload = decodeJWTPayload(token) else {
            print("🔐 LiveKit token claims unavailable source=\(source) url=\(PrivacyLog.redact(liveKitURL)) expectedRoom=\(PrivacyLog.shortID(expectedRoom))")
            return
        }

        let video = payload["video"] as? [String: Any]
        let grantedRoom = video?["room"] as? String
        let subject = payload["sub"] as? String
        let issuer = payload["iss"] as? String
        let expiresAt = payload["exp"] as? Int
        let notBefore = payload["nbf"] as? Int
        let roomJoin = video?["roomJoin"] as? Bool
        let canPublish = video?["canPublish"] as? Bool
        let canSubscribe = video?["canSubscribe"] as? Bool

        print(
            "🔐 LiveKit token claims " +
            "source=\(source) url=\(PrivacyLog.redact(liveKitURL)) expectedRoom=\(PrivacyLog.shortID(expectedRoom)) " +
            "grantRoom=\(PrivacyLog.shortID(grantedRoom)) sub=\(PrivacyLog.shortID(subject)) " +
            "iss=\(redactedIssuer(issuer)) nbf=\(notBefore.map { String($0) } ?? "nil") " +
            "exp=\(expiresAt.map { String($0) } ?? "nil") roomJoin=\(roomJoin?.description ?? "nil") " +
            "canPublish=\(canPublish?.description ?? "nil") canSubscribe=\(canSubscribe?.description ?? "nil")"
        )

        if let grantedRoom, grantedRoom != expectedRoom {
            print("⚠️ LiveKit token room mismatch: expected=\(PrivacyLog.shortID(expectedRoom)) grant=\(PrivacyLog.shortID(grantedRoom))")
        }
        #endif
    }

    private func decodeJWTPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = base64.count % 4
        if padding > 0 {
            base64.append(String(repeating: "=", count: 4 - padding))
        }
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any] else {
            return nil
        }
        return payload
    }

    private func redactedIssuer(_ issuer: String?) -> String {
        guard let issuer, !issuer.isEmpty else { return "nil" }
        return "\(issuer.prefix(4))…len=\(issuer.count)"
    }
}

extension LiveKitManager: RoomDelegate {
    nonisolated func roomDidConnect(_ room: Room) {
        print("✅ LiveKit roomDidConnect:", PrivacyLog.shortID(room.name))
    }

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        print("👤 LiveKit participant connected:", PrivacyLog.shortID(participant.identity?.stringValue))
        Task { @MainActor in
            self.refreshRemoteParticipants(for: room)
        }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        print("👤 LiveKit participant disconnected:", PrivacyLog.shortID(participant.identity?.stringValue))
        Task { @MainActor in
            self.refreshRemoteParticipants(for: room)
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        print(
            "🔊 LiveKit subscribed remote track kind:",
            publication.kind,
            "participant:",
            PrivacyLog.shortID(participant.identity?.stringValue)
        )
        Task { @MainActor in
            self.refreshRemoteParticipants(for: room)
        }
    }

    nonisolated func room(_ room: Room, participant: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
        print("📤 LiveKit local didPublishTrack kind:", publication.kind)
    }

    nonisolated func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState) {
        Task { @MainActor in
            switch connectionState {
            case .connecting:
                self.isConnected = false
            case .connected:
                self.isConnected = true
                self.isReconnecting = false
                self.refreshRemoteParticipants(for: room)
            case .reconnecting:
                self.isReconnecting = true
                self.isConnected = false
            case .disconnecting:
                self.isConnected = false
                self.isReconnecting = true
            case .disconnected:
                self.isConnected = false
                self.isReconnecting = false
                if self.pendingRoomName != nil {
                    self.scheduleManualReconnectIfNeeded()
                }
            }
        }
    }

    nonisolated func room(_ room: Room, didFailToConnectWithError error: LiveKitError?) {
        Task { @MainActor in
            let message = error?.localizedDescription ?? "Failed to connect."
            self.lastErrorMessage = message
            self.isConnected = false
            self.isReconnecting = false
            if self.isLiveKitAuthRejection(message) {
                self.disableManualReconnect(after: message)
            }
        }
    }

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor in
            let message = error?.localizedDescription
            self.lastErrorMessage = message
            self.isConnected = false
            self.isReconnecting = false
            if self.isLiveKitAuthRejection(message) {
                self.disableManualReconnect(after: message)
            } else if self.pendingRoomName != nil {
                self.scheduleManualReconnectIfNeeded()
            }
        }
    }
}

#else
import Combine
import SwiftUI

struct LiveKitTokenResponse: Codable {
    struct IceServerConfig: Codable {
        let urls: [String]
        let username: String?
        let credential: String?
    }

    let token: String
    let url: String?
    let iceServers: [IceServerConfig]?

    private enum CodingKeys: String, CodingKey {
        case token
        case url
        case liveKitUrl
        case livekitUrl
        case iceServers
    }

    init(token: String, url: String?, iceServers: [IceServerConfig]?) {
        self.token = token
        self.url = url
        self.iceServers = iceServers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(String.self, forKey: .token)
        url = try container.decodeIfPresent(String.self, forKey: .url)
            ?? container.decodeIfPresent(String.self, forKey: .liveKitUrl)
            ?? container.decodeIfPresent(String.self, forKey: .livekitUrl)
        iceServers = try container.decodeIfPresent([IceServerConfig].self, forKey: .iceServers)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(token, forKey: .token)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encodeIfPresent(url, forKey: .liveKitUrl)
        try container.encodeIfPresent(iceServers, forKey: .iceServers)
    }
}

@MainActor
final class LiveKitManager: ObservableObject {
    static let shared = LiveKitManager()

    @Published var isConnected = false
    @Published var isReconnecting = false
    @Published var currentRoomName: String?
    @Published var activeCallUUID: UUID?
    @Published var isPresentingGroupCall = false
    @Published var isMicrophoneEnabled = true
    @Published var isCameraEnabled = true
    @Published var lastErrorMessage: String?
    @Published var backendState: BackendConnectionState = .checking

    var pendingRoomName: String?

    func validateBackend() async {
        backendState = await APIClient.shared.health()
    }

    func startCall(roomName: String, userId: String, calleeUserId: String? = nil, callerName: String? = nil, callUUID: UUID? = nil) async throws {}
    func acceptIncomingCall() async throws {}
    func connect(roomName: String, userId: String) async throws {}
    func connectExternalBridge(roomName: String, userId: String, liveKitURL: String, token: String, callUUID: UUID?) async throws {}
    func disconnect() async {}
    func toggleMic() async {}
    func toggleCamera() async {}
}

#endif
