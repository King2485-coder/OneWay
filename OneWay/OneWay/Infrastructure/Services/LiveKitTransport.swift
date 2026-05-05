import Foundation

#if canImport(LiveKit)
import AVFoundation
import LiveKit

@MainActor
final class LiveKitTransport: CallTransport {
    private(set) var room: Room?
    private let updateStream = AsyncStream<[CallParticipant]>.makeStream()
    var participantUpdates: AsyncStream<[CallParticipant]> { updateStream.stream }

    init() {
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
        try? AudioManager.shared.setEngineAvailability(.none)
    }

    func connect(roomURL: URL, token: String, iceServers: [TurnServerConfiguration], video: Bool) async throws {
        let rtcIceServers = iceServers.map {
            IceServer(urls: $0.urls, username: $0.username, credential: $0.credential)
        }
        let connectOptions = ConnectOptions(
            autoSubscribe: true,
            reconnectAttempts: 8,
            reconnectAttemptDelay: 0.8,
            reconnectMaxDelay: 6.0,
            iceServers: rtcIceServers,
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
        try await configureAudioSession()
        try await room.connect(url: roomURL.absoluteString, token: token)
        try await room.localParticipant.setMicrophone(enabled: true)
        if video {
            try await room.localParticipant.setCamera(
                enabled: true,
                captureOptions: CameraCaptureOptions(
                    position: .front,
                    dimensions: .h720_169,
                    fps: 24
                )
            )
        }
        self.room = room
        publishParticipants(from: room)
    }

    func setMicrophoneEnabled(_ enabled: Bool) async throws {
        try await room?.localParticipant.setMicrophone(enabled: enabled)
    }

    func setCameraEnabled(_ enabled: Bool) async throws {
        try await room?.localParticipant.setCamera(enabled: enabled)
    }

    func switchCamera() async throws {
        guard let cameraTrack = room?.localParticipant.firstCameraVideoTrack as? LocalVideoTrack,
              let capturer = cameraTrack.capturer as? CameraCapturer else { return }
        _ = try await capturer.switchCameraPosition()
    }

    func disconnect() async {
        await room?.disconnect()
        try? AudioManager.shared.setEngineAvailability(.none)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        room = nil
        updateStream.continuation.yield([])
    }

    func currentRoom() -> Room? {
        room
    }

    private func configureAudioSession() async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker])
        try session.setActive(true)
    }

    private func publishParticipants(from room: Room) {
        let mapped = room.remoteParticipants.values.map { participant in
            CallParticipant(
                id: UUID(uuidString: (participant.sid?.stringValue ?? "")) ?? UUID(),
                displayName: participant.identity?.stringValue ?? "Participant",
                isMuted: participant.isMicrophoneEnabled(),
                isVideoEnabled: participant.firstCameraVideoTrack != nil || participant.firstScreenShareVideoTrack != nil
            )
        }
        updateStream.continuation.yield(mapped)
    }
}

extension LiveKitTransport: RoomDelegate {
    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor in
            self.publishParticipants(from: room)
        }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        Task { @MainActor in
            self.publishParticipants(from: room)
        }
    }

    nonisolated func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState) {
        Task { @MainActor in
            if connectionState == .connected || connectionState == .reconnecting {
                self.publishParticipants(from: room)
            } else if connectionState == .disconnected {
                self.updateStream.continuation.yield([])
            }
        }
    }
}
#else

@MainActor
final class LiveKitTransport: CallTransport {
    private let updateStream = AsyncStream<[CallParticipant]>.makeStream()
    var participantUpdates: AsyncStream<[CallParticipant]> { updateStream.stream }

    init() {}

    func connect(roomURL: URL, token: String, iceServers: [TurnServerConfiguration], video: Bool) async throws {}
    func setMicrophoneEnabled(_ enabled: Bool) async throws {}
    func setCameraEnabled(_ enabled: Bool) async throws {}
    func switchCamera() async throws {}
    func disconnect() async {}
}
#endif
