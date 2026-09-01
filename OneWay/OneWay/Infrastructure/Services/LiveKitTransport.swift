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
        AudioManager.shared.isAutomaticConfigurationEnabled = false
        try? AudioManager.shared.setEngineAvailability(.none)
    }

    func connect(roomURL: URL, token: String, iceServers: [TurnServerConfiguration], video: Bool) async throws {
        let roomName = roomURL.lastPathComponent.isEmpty ? roomURL.absoluteString : roomURL.lastPathComponent
        print("📞 LiveKitTransport connecting room")
        print("📞 CALL roomName:", roomName)
        print("📞 CALL liveKitURL:", roomURL.absoluteString)
        print("📞 CALL token exists:", !token.isEmpty)

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
        try AudioManager.shared.setEngineAvailability(.default)

        try await room.connect(url: roomURL.absoluteString, token: token)
        print("✅ CALL connected")
        print("👤 CALL local identity:", room.localParticipant.identity?.stringValue ?? "nil")
        print("👥 CALL remote count:", room.remoteParticipants.count)

        try await room.localParticipant.setMicrophone(enabled: true)
        print("🎙 CALL mic ON after connect")
        try? await Task.sleep(nanoseconds: 500_000_000)
        try await room.localParticipant.setMicrophone(enabled: true)
        print("🎙 CALL mic ON confirmed")
        let localAudioTracks = room.localParticipant.audioTracks
        print("🎙 local audio publication count:", localAudioTracks.count)

        if video {
            try await room.localParticipant.setCamera(
                enabled: true,
                captureOptions: CameraCaptureOptions(
                    position: .front,
                    dimensions: .h720_169,
                    fps: 24
                )
            )
        } else {
            try await room.localParticipant.setCamera(enabled: false)
        }
        self.room = room
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
        print("🔈 CALL audio route:", AVAudioSession.sharedInstance().currentRoute)
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
        let granted = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }

        guard granted else {
            throw NSError(
                domain: "OneWayCallAudio",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Microphone permission is required for calls."]
            )
        }

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
        )
        try audioSession.setActive(true)
        try? audioSession.overrideOutputAudioPort(.speaker)

        print("🔈 CALL audio route:", audioSession.currentRoute)
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
    nonisolated func room(
        _ room: Room,
        participant: LocalParticipant,
        didPublishTrack publication: LocalTrackPublication
    ) {
        print("🎙 CALL local published:", publication.kind)
    }

    nonisolated func room(
        _ room: Room,
        participant: RemoteParticipant,
        didSubscribeTrack publication: RemoteTrackPublication,
        track: Track
    ) {
        print("🔊 CALL subscribed track:", track.kind)
        print("🔊 CALL remote:", participant.identity?.stringValue ?? "nil")
        print("🔊 remote publication:", publication.sid?.stringValue ?? "nil")
        print("🔊 subscribed:", publication.isSubscribed)
        print("🔊 muted:", publication.isMuted)
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
        print("🔈 forced speaker after remote subscribe")
    }

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor in
            for publication in participant.audioTracks {
                publication.set(subscribed: true)
                print("🔊 forced subscribe audio publication")
                print("🔊 remote publication:", publication.sid?.stringValue ?? "nil")
                print("🔊 subscribed:", publication.isSubscribed)
                print("🔊 muted:", publication.isMuted)
            }
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
