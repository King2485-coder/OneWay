import Foundation

#if canImport(LiveKit)
import AVFoundation
import Combine
import LiveKit
import SwiftUI

struct LiveKitTokenResponse: Codable {
    let token: String
    let url: String?
    let iceServers: [TurnServerConfiguration]?
}

enum LiveKitManagerError: LocalizedError {
    case missingRoom
    case invalidLiveKitURL(String)
    case roomNotConnected

    var errorDescription: String? {
        switch self {
        case .missingRoom:
            return "Missing room name."
        case .invalidLiveKitURL(let value):
            return "Invalid LiveKit URL: \(value)"
        case .roomNotConnected:
            return "Room not connected."
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
    private let fallbackLiveKitURL = "wss://rtc.oneway.app"
    private var reconnectTask: Task<Void, Never>?

    private init(client: APIClient = .shared) {
        self.client = client
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
        try? AudioManager.shared.setEngineAvailability(.none)
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
        pendingRoomName = roomName
        lastErrorMessage = nil

        if let calleeUserId {
            try? await invite(
                calleeUserId: calleeUserId,
                callerName: callerName ?? userId,
                roomName: roomName
            )
        }

        try await connect(roomName: roomName, userId: userId)

        guard room != nil else {
            throw LiveKitManagerError.roomNotConnected
        }

        LaunchTelemetry.shared.track("call_started", parameters: [
            "room_name": roomName,
            "call_type": "video"
        ])
    }

    func acceptIncomingCall() async throws {
        let roomName = pendingRoomName ?? "default-room"
        let userId = AppEnvironment.shared.currentUserID
        try await connect(roomName: roomName, userId: userId)
    }

    func connect(roomName: String, userId: String) async throws {
        guard !roomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LiveKitManagerError.missingRoom
        }

        reconnectTask?.cancel()
        await validateBackend()

        do {
            let tokenResponse = try await fetchLiveKitToken(roomName: roomName, userId: userId)
            let liveKitURLString = tokenResponse.url ?? fallbackLiveKitURL
            let iceServers = (tokenResponse.iceServers ?? []).map {
                IceServer(urls: $0.urls, username: $0.username, credential: $0.credential)
            }

            guard let liveKitURL = URL(string: liveKitURLString) else {
                throw LiveKitManagerError.invalidLiveKitURL(liveKitURLString)
            }

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

            print("🚀 Connecting to:", liveKitURL.absoluteString)
            print("👤 User:", userId)
            print("🏠 Room:", roomName)
            if let iceServers = tokenResponse.iceServers {
                print("🧊 ICE servers:", iceServers.map(\.urls).flatMap { $0 })
            }

            try await room.connect(url: liveKitURL.absoluteString, token: tokenResponse.token)
            try await configureAudioSession()
            try await room.localParticipant.setMicrophone(enabled: true)
            try await room.localParticipant.setCamera(
                enabled: true,
                captureOptions: CameraCaptureOptions(
                    position: .front,
                    dimensions: .h720_169,
                    fps: 24
                )
            )
            forceSpeaker()

            isConnected = true
            isReconnecting = false
            isPresentingGroupCall = true
            isCameraEnabled = true
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
            scheduleManualReconnectIfNeeded()
            throw error
        }
    }

    func disconnect() async {
        let disconnectedRoomName = currentRoomName
        let wasConnected = isConnected
        reconnectTask?.cancel()
        await room?.disconnect()
        try? AudioManager.shared.setEngineAvailability(.none)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        room = nil
        isConnected = false
        isReconnecting = false
        remoteParticipants = []
        currentRoomName = nil
        pendingRoomName = nil
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
        try? await participant.setMicrophone(enabled: enabled)
        isMicrophoneEnabled = enabled
    }

    func toggleCamera() async {
        guard let participant = room?.localParticipant else { return }
        let enabled = !isCameraEnabled
        try? await participant.setCamera(enabled: enabled)
        isCameraEnabled = enabled
    }

    func invite(calleeUserId: String, callerName: String, roomName: String) async throws {
        struct InviteRequest: Encodable {
            let calleeUserId: String
            let callerName: String
            let roomName: String
            let hasVideo: Bool
        }

        let _: EmptyAPIResponse = try await client.post(
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
            "livekit/token",
            body: TokenRequest(roomName: roomName, identity: userId),
            requiresAuth: false
        )
    }

    private func configureAudioSession() async throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker])
        try audioSession.setActive(true)
    }

    private func forceSpeaker() {
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
        } catch {
            print("❌ Speaker override failed:", error)
        }
    }

    private func refreshRemoteParticipants(for room: Room) {
        remoteParticipants = Array(room.remoteParticipants.values)
        if remoteParticipants.count > 8 {
            Task {
                try? await room.localParticipant.setCamera(enabled: false)
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

            try? await self.connect(roomName: roomName, userId: AppEnvironment.shared.currentUserID)
        }
    }
}

extension LiveKitManager: RoomDelegate {
    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor in
            self.refreshRemoteParticipants(for: room)
        }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        Task { @MainActor in
            self.refreshRemoteParticipants(for: room)
        }
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
            case .disconnected:
                self.isConnected = false
                self.isReconnecting = false
                if self.pendingRoomName != nil {
                    self.scheduleManualReconnectIfNeeded()
                }
            @unknown default:
                break
            }
        }
    }

    nonisolated func room(_ room: Room, didFailToConnectWithError error: LiveKitError?) {
        Task { @MainActor in
            self.lastErrorMessage = error?.localizedDescription ?? "Failed to connect."
            self.isConnected = false
            self.isReconnecting = false
        }
    }

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor in
            self.lastErrorMessage = error?.localizedDescription
            self.isConnected = false
            self.isReconnecting = false
            if self.pendingRoomName != nil {
                self.scheduleManualReconnectIfNeeded()
            }
        }
    }
}

#else
import Combine
import SwiftUI

struct TurnServerConfiguration: Codable, Equatable {
    let urls: [String]
    let username: String?
    let credential: String?
}

struct LiveKitTokenResponse: Codable {
    let token: String
    let url: String?
    let iceServers: [TurnServerConfiguration]?
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
    func disconnect() async {}
    func toggleMic() async {}
    func toggleCamera() async {}
}

#endif
