import Foundation

#if canImport(LiveKit)
import AVFoundation
import LiveKit

enum LiveKitTransportError: LocalizedError {
    case invalidLiveKitURL(String)
    case microphonePermissionDenied
    case cameraPermissionDenied
    case audioSessionNotActivated

    var errorDescription: String? {
        switch self {
        case .invalidLiveKitURL(let value):
            return "Invalid LiveKit URL: \(value)"
        case .microphonePermissionDenied:
            return "Microphone permission is required for calls."
        case .cameraPermissionDenied:
            return "Camera permission is required for video calls."
        case .audioSessionNotActivated:
            return "Call audio must be activated by CallKit before connecting media."
        }
    }
}

@MainActor
final class LiveKitTransport: CallTransport {
    private(set) var room: Room?
    private var activeConnectID: UUID?
    private var disconnectID: UUID?
    private var configuredRemoteAudioPublications: Set<String> = []
    private let updateStream = AsyncStream<[CallParticipant]>.makeStream()
    private let roomUpdateStream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(32))
    var participantUpdates: AsyncStream<[CallParticipant]> { updateStream.stream }
    var roomUpdates: AsyncStream<Void> { roomUpdateStream.stream }

    init() {
        #if DEBUG
        print("video.call.transport.created transport=\(ObjectIdentifier(self)) timestamp=\(ISO8601DateFormatter().string(from: Date()))")
        #endif
    }

    deinit {
        #if DEBUG
        print("video.call.transport.deinit transport=\(ObjectIdentifier(self)) timestamp=\(ISO8601DateFormatter().string(from: Date()))")
        #endif
    }

    func connect(roomURL: URL, token: String, iceServers: [TurnServerConfiguration], video: Bool) async throws -> CallMediaConnectionResult {
        let connectID = UUID()
        activeConnectID = connectID
        try validateLiveKitConnectURL(roomURL)
        let session = AVAudioSession.sharedInstance()
        guard session.category == .playAndRecord,
              session.mode == .voiceChat || session.mode == .videoChat,
              !session.currentRoute.inputs.isEmpty else {
            #if DEBUG
            print(
                "call.livekit.connect.blocked",
                "reason=audioSessionNotActivated",
                "category=\(session.category.rawValue)",
                "mode=\(session.mode.rawValue)",
                "inputRoute=\(session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ","))",
                "outputRoute=\(session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ","))",
                "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
            )
            #endif
            throw LiveKitTransportError.audioSessionNotActivated
        }
        let audioController = CallAudioSessionController.shared
        await audioController.beginCall(video: video, owner: "LiveKitTransport.connect")
        configuredRemoteAudioPublications.removeAll()
        if let existingRoom = room, existingRoom.connectionState == .connected {
            #if DEBUG
            print(
                "video.call.livekit.join.skipped",
                "reason=already_connected",
                "room=\(PrivacyLog.shortID(existingRoom.name))",
                "connectId=\(PrivacyLog.shortID(connectID.uuidString))",
                "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
            )
            #endif
            publishParticipants(from: existingRoom)
            notifyRoomUpdated(context: "connect skipped already connected")
            return CallMediaConnectionResult(
                microphonePublished: existingRoom.localParticipant.isMicrophoneEnabled(),
                cameraPublished: existingRoom.localParticipant.firstCameraVideoTrack != nil
            )
        }
        #if DEBUG
        print(
            "video.call.livekit.join.started",
            "url=\(PrivacyLog.redactURL(roomURL))",
            "connectId=\(PrivacyLog.shortID(connectID.uuidString))",
            "video=\(video)",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
        let rtcIceServers = iceServers.map {
            IceServer(urls: $0.urls, username: $0.username, credential: $0.credential)
        }
        let connectOptions = ConnectOptions(
            autoSubscribe: true,
            reconnectAttempts: 12,
            reconnectAttemptDelay: 0.35,
            reconnectMaxDelay: 3.0,
            iceServers: rtcIceServers,
            iceTransportPolicy: .all
        )
        let roomOptions = RoomOptions(
            defaultCameraCaptureOptions: CameraCaptureOptions(
                position: .front,
                dimensions: .h540_169,
                fps: 24
            ),
            defaultScreenShareCaptureOptions: ScreenShareCaptureOptions(
                appAudio: true,
                useBroadcastExtension: true
            ),
            defaultAudioCaptureOptions: AudioCaptureOptions(
                echoCancellation: true,
                autoGainControl: true,
                noiseSuppression: true
            ),
            adaptiveStream: true,
            dynacast: true
        )

        guard await requestMicrophonePermission() else {
            throw LiveKitTransportError.microphonePermissionDenied
        }
        var shouldPublishCamera = video
        if video {
            shouldPublishCamera = await requestCameraPermission()
            if !shouldPublishCamera {
                #if DEBUG
                print(
                    "video.call.livekit.camera.permissionDenied",
                    "connectId=\(PrivacyLog.shortID(connectID.uuidString))",
                    "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
                )
                #endif
            }
        }
        await prepareMediaPipelines(video: shouldPublishCamera)

        let room = Room(delegate: self, connectOptions: connectOptions, roomOptions: roomOptions)
        self.room = room
        notifyRoomUpdated(context: "room created")
        try await audioController.configureForActiveCall(video: video, owner: "LiveKitTransport.beforeConnect")
        print("LiveKit connect caller:", #fileID, #function)
        print("LiveKit connect URL:", PrivacyLog.redact(roomURL.absoluteString))
        try await room.connect(url: roomURL.absoluteString, token: token)
        CallAudioSessionCoordinator.shared.mediaDidConnect(roomName: room.name, owner: "LiveKitTransport.roomConnected")
        audioController.logRoute(event: "call.audio.session.activated", roomName: room.name, owner: "LiveKitTransport.roomConnected")
        #if DEBUG
        print(
            "video.call.livekit.join.completed",
            "room=\(PrivacyLog.shortID(room.name))",
            "connectId=\(PrivacyLog.shortID(connectID.uuidString))",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
        notifyRoomUpdated(context: "room connected")
        try await audioController.configureForActiveCall(video: video, owner: "LiveKitTransport.afterConnect")
        #if DEBUG
        print(
            "call.audio.localTrack.publish.started",
            "room=\(PrivacyLog.shortID(room.name))",
            "connectId=\(PrivacyLog.shortID(connectID.uuidString))",
            "localParticipant=\(PrivacyLog.shortID(room.localParticipant.identity?.stringValue))",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
        var microphonePublished = false
        do {
            try await room.localParticipant.setMicrophone(enabled: true)
            microphonePublished = true
        } catch {
            #if DEBUG
            print(
                "call.audio.failure",
                "stage=local_microphone_publish",
                "room=\(PrivacyLog.shortID(room.name))",
                "connectId=\(PrivacyLog.shortID(connectID.uuidString))",
                "error=\(PrivacyLog.redact(error.localizedDescription))",
                "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
            )
            #endif
        }
        if microphonePublished {
            #if DEBUG
            let audioPublication = room.localParticipant.localAudioTracks.first
            print(
                "call.audio.localTrack.published",
                "room=\(PrivacyLog.shortID(room.name))",
                "connectId=\(PrivacyLog.shortID(connectID.uuidString))",
                "publicationSid=\(PrivacyLog.shortID(audioPublication?.sid.stringValue))",
                "trackSource=\(audioPublication?.source ?? .unknown)",
                "muted=\(audioPublication?.isMuted ?? true)",
                "subscribed=\(audioPublication?.isSubscribed ?? false)",
                "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
            )
            #endif
            notifyRoomUpdated(context: "microphone published")
            #if DEBUG
            print(
                "call.audio.microphone.published",
                "room=\(PrivacyLog.shortID(room.name))",
                "roomObject=\(ObjectIdentifier(room))",
                "transportObject=\(ObjectIdentifier(self))",
                "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
            )
            #endif
        }
        var cameraPublished = false
        if shouldPublishCamera {
            #if DEBUG
            print(
                "video.call.livekit.camera.publish.started",
                "room=\(PrivacyLog.shortID(room.name))",
                "connectId=\(PrivacyLog.shortID(connectID.uuidString))",
                "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
            )
            #endif
            do {
                try await room.localParticipant.setCamera(
                    enabled: true,
                    captureOptions: CameraCaptureOptions(
                        position: .front,
                        dimensions: .h540_169,
                        fps: 24
                    )
                )
                cameraPublished = true
                #if DEBUG
                print(
                    "video.call.livekit.camera.published",
                    "room=\(PrivacyLog.shortID(room.name))",
                    "connectId=\(PrivacyLog.shortID(connectID.uuidString))",
                    "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
                )
                #endif
                notifyRoomUpdated(context: "camera published")
                #if DEBUG
                print(
                    "call.video.camera.published",
                    "room=\(PrivacyLog.shortID(room.name))",
                    "roomObject=\(ObjectIdentifier(room))",
                    "transportObject=\(ObjectIdentifier(self))",
                    "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
                )
                #endif
            } catch {
                #if DEBUG
                print(
                    "video.call.livekit.camera.publish.failed",
                    "room=\(PrivacyLog.shortID(room.name))",
                    "connectId=\(PrivacyLog.shortID(connectID.uuidString))",
                    "error=\(PrivacyLog.redact(error.localizedDescription))",
                    "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
                )
                #endif
            }
        }
        await ensureRemoteAudioSubscriptions(room: room, context: "post local media publish")
        publishParticipants(from: room)
        notifyRoomUpdated(context: "participants published")
        #if DEBUG
        print(
            "call.media.ready",
            "room=\(PrivacyLog.shortID(room.name))",
            "microphonePublished=\(microphonePublished)",
            "cameraPublished=\(cameraPublished)",
            "roomObject=\(ObjectIdentifier(room))",
            "transportObject=\(ObjectIdentifier(self))",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
        return CallMediaConnectionResult(
            microphonePublished: microphonePublished,
            cameraPublished: cameraPublished
        )
    }

    func setMicrophoneEnabled(_ enabled: Bool) async throws {
        try await room?.localParticipant.setMicrophone(enabled: enabled)
        if let room {
            logAudioPublication("call.audio.track.\(enabled ? "unmuted" : "muted")", room: room, publication: room.localParticipant.localAudioTracks.first, participantIdentity: room.localParticipant.identity?.stringValue)
        }
    }

    func setCameraEnabled(_ enabled: Bool) async throws {
        if enabled {
            await prepareMediaPipelines(video: true)
            try await room?.localParticipant.setCamera(
                enabled: true,
                captureOptions: CameraCaptureOptions(
                position: .front,
                dimensions: .h540_169,
                fps: 24
                )
            )
        } else {
            try await room?.localParticipant.setCamera(enabled: false)
        }
    }

    func switchCamera() async throws {
        guard let cameraTrack = room?.localParticipant.firstCameraVideoTrack as? LocalVideoTrack,
              let capturer = cameraTrack.capturer as? CameraCapturer else { return }
        _ = try await capturer.switchCameraPosition()
    }

    func disconnect() async {
        let id = UUID()
        disconnectID = id
        #if DEBUG
        let stack = Thread.callStackSymbols.prefix(8).joined(separator: " | ")
        print(
            "video.call.livekit.disconnect.requested",
            "room=\(PrivacyLog.shortID(room?.name))",
            "disconnectId=\(PrivacyLog.shortID(id.uuidString))",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))",
            "stack=\(PrivacyLog.redact(stack))"
        )
        #endif
        BroadcastManager.shared.requestStop()
        await room?.disconnect()
        room = nil
        configuredRemoteAudioPublications.removeAll()
        updateStream.continuation.yield([])
        notifyRoomUpdated(context: "room disconnected")
        #if DEBUG
        print(
            "video.call.livekit.disconnect.completed",
            "disconnectId=\(PrivacyLog.shortID(id.uuidString))",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }

    func currentRoom() -> Room? {
        room
    }

    func waitForRemoteParticipant(timeoutSeconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let room, !room.remoteParticipants.isEmpty {
                #if DEBUG
                print(
                    "video.call.remoteParticipant.present",
                    "room=\(PrivacyLog.shortID(room.name))",
                    "remoteParticipants=\(room.remoteParticipants.count)",
                    "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
                )
                #endif
                await ensureRemoteAudioSubscriptions(room: room, context: "remote participant barrier")
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        #if DEBUG
        print(
            "video.call.remoteParticipant.timeout",
            "room=\(PrivacyLog.shortID(room?.name))",
            "remoteParticipants=\(room?.remoteParticipants.count ?? 0)",
            "timeoutSeconds=\(timeoutSeconds)",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
        return false
    }

    private func prepareMediaPipelines(video: Bool) async {
        try? await CallAudioSessionController.shared.configureForActiveCall(video: video, owner: "LiveKitTransport.prepareMediaPipelines")
        if video {
            await VideoCallMediaPrewarmer.shared.prewarmCameraIfNeeded()
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func requestCameraPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func validateLiveKitConnectURL(_ url: URL) throws {
        let scheme = url.scheme?.lowercased()
        guard scheme == "ws" || scheme == "wss" else {
            throw LiveKitTransportError.invalidLiveKitURL(
                "\(url.absoluteString) is not a LiveKit signaling URL. Expected ws(s):// LiveKit, not the OneWay API backend."
            )
        }
        if isAPIBackendURL(url) || url.absoluteString.contains(":3000") {
            throw LiveKitTransportError.invalidLiveKitURL(
                "\(url.absoluteString) points at the OneWay API backend, not LiveKit signaling."
            )
        }
    }

    private func isAPIBackendURL(_ url: URL) -> Bool {
        guard let apiBaseURL = URL(string: APIConfig.baseURL),
              let liveKitHost = url.host?.lowercased(),
              let apiHost = apiBaseURL.host?.lowercased(),
              liveKitHost == apiHost else {
            return false
        }
        return resolvedPort(for: url) == resolvedPort(for: apiBaseURL)
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

    private func publishParticipants(from room: Room) {
        let mapped = room.remoteParticipants.values.map { participant in
            CallParticipant(
                id: UUID(uuidString: (participant.sid?.stringValue ?? "")) ?? UUID(),
                displayName: participant.identity?.stringValue ?? "Participant",
                isMuted: !participant.isMicrophoneEnabled(),
                isVideoEnabled: participant.firstCameraVideoTrack != nil || participant.firstScreenShareVideoTrack != nil
            )
        }
        #if DEBUG
        let remoteVideoCount = room.remoteParticipants.values.reduce(0) { count, participant in
            count + ((participant.firstCameraVideoTrack ?? participant.firstScreenShareVideoTrack) == nil ? 0 : 1)
        }
        print("🎥 LiveKitTransport participants update: remoteParticipants=\(room.remoteParticipants.count) remoteVideoTracks=\(remoteVideoCount)")
        #endif
        updateStream.continuation.yield(mapped)
    }

    private func notifyRoomUpdated(context: String) {
        #if DEBUG
        if let room {
            let remoteVideoCount = room.remoteParticipants.values.reduce(0) { count, participant in
                count + ((participant.firstCameraVideoTrack ?? participant.firstScreenShareVideoTrack) == nil ? 0 : 1)
            }
            let hasLocalVideo = room.localParticipant.firstCameraVideoTrack != nil
            print("🎥 LiveKit room update \(context): room=\(PrivacyLog.shortID(room.name)) remoteParticipants=\(room.remoteParticipants.count) remoteVideoTracks=\(remoteVideoCount) localVideo=\(hasLocalVideo)")
        } else {
            print("🎥 LiveKit room update \(context): room=nil")
        }
        #endif
        roomUpdateStream.continuation.yield(())
    }

    private func ensureRemoteAudioSubscriptions(room: Room, context: String) async {
        for participant in room.remoteParticipants.values {
            for publication in participant.audioTracks.compactMap({ $0 as? RemoteTrackPublication }) {
                let registryKey = remoteAudioRegistryKey(room: room, participant: participant, publication: publication)
                if configuredRemoteAudioPublications.contains(registryKey) {
                    #if DEBUG
                    print(
                        "REMOTE_AUDIO_SETUP_SKIPPED_DUPLICATE",
                        "room=\(PrivacyLog.shortID(room.name))",
                        "context=\(context)",
                        "remoteParticipant=\(PrivacyLog.shortID(participant.identity?.stringValue))",
                        "publicationSid=\(PrivacyLog.shortID(publication.sid.stringValue))",
                        "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
                    )
                    #endif
                    continue
                }
                logRemoteAudio("call.audio.remotePublication.received", room: room, participant: participant, publication: publication, context: context)
                if !publication.isSubscribed {
                    logRemoteAudio("call.audio.remoteTrack.subscription.requested", room: room, participant: participant, publication: publication, context: context)
                    do {
                        try await publication.set(subscribed: true)
                    } catch {
                        #if DEBUG
                        print(
                            "call.audio.failure",
                            "stage=remote_audio_subscribe",
                            "room=\(PrivacyLog.shortID(room.name))",
                            "remoteParticipant=\(PrivacyLog.shortID(participant.identity?.stringValue))",
                            "publicationSid=\(PrivacyLog.shortID(publication.sid.stringValue))",
                            "error=\(PrivacyLog.redact(error.localizedDescription))",
                            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
                        )
                        #endif
                    }
                }
                if publication.isEnabled == false {
                    do {
                        try await publication.set(enabled: true)
                    } catch {
                        #if DEBUG
                        print(
                            "call.audio.failure",
                            "stage=remote_audio_enable",
                            "room=\(PrivacyLog.shortID(room.name))",
                            "remoteParticipant=\(PrivacyLog.shortID(participant.identity?.stringValue))",
                            "publicationSid=\(PrivacyLog.shortID(publication.sid.stringValue))",
                            "error=\(PrivacyLog.redact(error.localizedDescription))",
                            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
                        )
                        #endif
                    }
                }
                if publication.isSubscribed {
                    logRemoteAudio("call.audio.remoteTrack.subscribed", room: room, participant: participant, publication: publication, context: context)
                    if !publication.isMuted {
                        logRemoteAudio("call.audio.remoteTrack.unmuted", room: room, participant: participant, publication: publication, context: context)
                    }
                    logRemoteAudio("call.audio.remotePlayback.started", room: room, participant: participant, publication: publication, context: context)
                    configuredRemoteAudioPublications.insert(registryKey)
                }
            }
        }
    }

    private func remoteAudioRegistryKey(room: Room, participant: RemoteParticipant, publication: RemoteTrackPublication) -> String {
        [
            room.name ?? "unknown-room",
            participant.identity?.stringValue ?? participant.sid?.stringValue ?? "unknown-participant",
            publication.sid.stringValue
        ].joined(separator: "|")
    }

    private func logAudioPublication(_ event: String, room: Room, publication: LocalTrackPublication?, participantIdentity: String?) {
        #if DEBUG
        print(
            event,
            "room=\(PrivacyLog.shortID(room.name))",
            "localParticipant=\(PrivacyLog.shortID(participantIdentity))",
            "publicationSid=\(PrivacyLog.shortID(publication?.sid.stringValue))",
            "trackSource=\(publication?.source ?? .unknown)",
            "muted=\(publication?.isMuted ?? false)",
            "subscribed=\(publication?.isSubscribed ?? false)",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }

    private func logRemoteAudio(_ event: String, room: Room, participant: RemoteParticipant, publication: RemoteTrackPublication, context: String) {
        #if DEBUG
        print(
            event,
            "room=\(PrivacyLog.shortID(room.name))",
            "context=\(context)",
            "localParticipant=\(PrivacyLog.shortID(room.localParticipant.identity?.stringValue))",
            "remoteParticipant=\(PrivacyLog.shortID(participant.identity?.stringValue))",
            "publicationSid=\(PrivacyLog.shortID(publication.sid.stringValue))",
            "trackSource=\(publication.source)",
            "muted=\(publication.isMuted)",
            "subscribed=\(publication.isSubscribed)",
            "enabled=\(publication.isEnabled)",
            "streamState=\(publication.streamState)",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }
}

@MainActor
private final class CallAudioSessionController {
    static let shared = CallAudioSessionController()

    private var activeCallDepth = 0
    private var observersInstalled = false

    private init() {}

    func beginCall(video: Bool, owner: String) async {
        activeCallDepth += 1
        installObserversIfNeeded()
        CallAudioSessionCoordinator.shared.liveKitConfigurationRequest(video: video, owner: owner)
    }

    func configureForActiveCall(video: Bool, owner: String) async throws {
        CallAudioSessionCoordinator.shared.liveKitConfigurationRequest(video: video, owner: owner)
        logRoute(event: "call.audio.session.configure.skipped", roomName: nil, owner: owner)
    }

    func endCall(owner: String) async {
        activeCallDepth = max(activeCallDepth - 1, 0)
        guard activeCallDepth == 0 else {
            logRoute(event: "call.audio.session.deactivation.skipped", roomName: nil, owner: "\(owner):remaining=\(activeCallDepth)")
            return
        }
        logRoute(event: "call.audio.session.deactivation.deferredToCallKit", roomName: nil, owner: owner)
    }

    func logRoute(event: String, roomName: String?, owner: String) {
        #if DEBUG
        let session = AVAudioSession.sharedInstance()
        let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        print(
            event,
            "owner=\(owner)",
            "room=\(PrivacyLog.shortID(roomName))",
            "category=\(session.category.rawValue)",
            "mode=\(session.mode.rawValue)",
            "inputRoute=\(inputs)",
            "outputRoute=\(outputs)",
            "sampleRate=\(session.sampleRate)",
            "ioBuffer=\(session.ioBufferDuration)",
            "speakerPreferred=\(AudioManager.shared.isSpeakerOutputPreferred)",
            "voiceProcessingBypassed=\(AudioManager.shared.isVoiceProcessingBypassed)",
            "manualRendering=\(AudioManager.shared.isManualRenderingMode)",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }

    private func installObserversIfNeeded() {
        guard !observersInstalled else { return }
        observersInstalled = true
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { notification in
            let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                CallAudioSessionController.shared.handleRouteChange(reasonValue: reasonValue)
            }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { notification in
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in
                CallAudioSessionController.shared.handleInterruption(typeValue: typeValue)
            }
        }
    }

    private func handleRouteChange(reasonValue: UInt?) {
        let reason = reasonValue.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))?.description ?? "unknown"
        logRoute(event: "call.audio.route.changed", roomName: nil, owner: reason)
    }

    private func handleInterruption(typeValue: UInt?) {
        let type = typeValue.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
        switch type {
        case .began:
            logRoute(event: "call.audio.interruption.started", roomName: nil, owner: "AVAudioSession")
        case .ended:
            logRoute(event: "call.audio.interruption.ended", roomName: nil, owner: "AVAudioSession")
            if activeCallDepth > 0 {
                CallAudioSessionCoordinator.shared.liveKitConfigurationRequest(video: true, owner: "interruptionRecovery")
            }
        case .none:
            break
        @unknown default:
            break
        }
    }

    private func hasBluetoothOutput(_ route: AVAudioSessionRouteDescription) -> Bool {
        route.outputs.contains { output in
            output.portType == .bluetoothA2DP
                || output.portType == .bluetoothHFP
                || output.portType == .bluetoothLE
        }
    }

    private func logAudioFailure(stage: String, owner: String, error: Error) {
        #if DEBUG
        print(
            "call.audio.failure",
            "stage=\(stage)",
            "owner=\(owner)",
            "error=\(PrivacyLog.redact(error.localizedDescription))",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }
}

private extension AVAudioSession.RouteChangeReason {
    var description: String {
        switch self {
        case .unknown: return "unknown"
        case .newDeviceAvailable: return "newDeviceAvailable"
        case .oldDeviceUnavailable: return "oldDeviceUnavailable"
        case .categoryChange: return "categoryChange"
        case .override: return "override"
        case .wakeFromSleep: return "wakeFromSleep"
        case .noSuitableRouteForCategory: return "noSuitableRouteForCategory"
        case .routeConfigurationChange: return "routeConfigurationChange"
        @unknown default: return "unknownDefault"
        }
    }
}

private actor VideoCallMediaPrewarmer {
    static let shared = VideoCallMediaPrewarmer()
    private var lastCameraPrewarm: Date?

    func prewarmCameraIfNeeded() async {
        if let lastCameraPrewarm, Date().timeIntervalSince(lastCameraPrewarm) < 30 {
            return
        }
        lastCameraPrewarm = Date()
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let captureSession = AVCaptureSession()
                captureSession.sessionPreset = .medium
                guard
                    let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                    let input = try? AVCaptureDeviceInput(device: device),
                    captureSession.canAddInput(input)
                else {
                    continuation.resume()
                    return
                }
                captureSession.addInput(input)
                captureSession.startRunning()
                Thread.sleep(forTimeInterval: 0.16)
                captureSession.stopRunning()
                continuation.resume()
            }
        }
    }
}

extension LiveKitTransport: RoomDelegate {
    nonisolated func roomDidConnect(_ room: Room) {
        print("✅ LiveKitTransport roomDidConnect:", PrivacyLog.shortID(room.name))
        Task { @MainActor in
            self.notifyRoomUpdated(context: "delegate roomDidConnect")
        }
    }

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        print("👤 LiveKitTransport participant connected:", PrivacyLog.shortID(participant.identity?.stringValue))
        Task { @MainActor in
            await self.ensureRemoteAudioSubscriptions(room: room, context: "remote participant connected")
            self.publishParticipants(from: room)
            self.notifyRoomUpdated(context: "remote participant connected")
        }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        print("👤 LiveKitTransport participant disconnected:", PrivacyLog.shortID(participant.identity?.stringValue))
        Task { @MainActor in
            self.publishParticipants(from: room)
            self.notifyRoomUpdated(context: "remote participant disconnected")
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication) {
        Task { @MainActor in
            if publication.kind == .audio {
                self.logRemoteAudio("call.audio.remotePublication.received", room: room, participant: participant, publication: publication, context: "delegate didPublishTrack")
                await self.ensureRemoteAudioSubscriptions(room: room, context: "delegate didPublishTrack")
            }
            self.publishParticipants(from: room)
            self.notifyRoomUpdated(context: "remote track published")
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        Task { @MainActor in
            if publication.kind == .audio {
                self.logRemoteAudio("call.audio.remoteTrack.subscribed", room: room, participant: participant, publication: publication, context: "delegate didSubscribeTrack")
                if !publication.isMuted {
                    self.logRemoteAudio("call.audio.remoteTrack.unmuted", room: room, participant: participant, publication: publication, context: "delegate didSubscribeTrack")
                }
                CallAudioSessionController.shared.logRoute(event: "call.audio.remotePlayback.started", roomName: room.name, owner: "LiveKitTransport.didSubscribeTrack")
            } else {
                print(
                    "🔊 LiveKitTransport subscribed remote track kind:",
                    publication.kind,
                    "participant:",
                    PrivacyLog.shortID(participant.identity?.stringValue)
                )
            }
            self.publishParticipants(from: room)
            self.notifyRoomUpdated(context: "remote track subscribed")
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        Task { @MainActor in
            if publication.kind == .audio {
                self.logRemoteAudio("call.audio.remoteTrack.unsubscribed", room: room, participant: participant, publication: publication, context: "delegate didUnsubscribeTrack")
            }
            self.publishParticipants(from: room)
            self.notifyRoomUpdated(context: "remote track unsubscribed")
        }
    }

    nonisolated func room(_ room: Room, participant: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
        Task { @MainActor in
            if publication.kind == .audio {
                self.logAudioPublication("call.audio.localTrack.published", room: room, publication: publication, participantIdentity: participant.identity?.stringValue)
            } else {
                print("📤 LiveKitTransport local didPublishTrack kind:", publication.kind)
            }
            self.publishParticipants(from: room)
            self.notifyRoomUpdated(context: "local track published")
        }
    }

    nonisolated func room(_ room: Room, participant: Participant, trackPublication publication: TrackPublication, didUpdateIsMuted isMuted: Bool) {
        Task { @MainActor in
            if publication.kind == .audio {
                #if DEBUG
                print(
                    isMuted ? "call.audio.track.muted" : "call.audio.track.unmuted",
                    "room=\(PrivacyLog.shortID(room.name))",
                    "participant=\(PrivacyLog.shortID(participant.identity?.stringValue))",
                    "publicationSid=\(PrivacyLog.shortID(publication.sid.stringValue))",
                    "trackSource=\(publication.source)",
                    "subscribed=\(publication.isSubscribed)",
                    "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
                )
                #endif
            }
            self.publishParticipants(from: room)
            self.notifyRoomUpdated(context: "audio mute changed")
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, trackPublication publication: RemoteTrackPublication, didUpdateStreamState streamState: StreamState) {
        Task { @MainActor in
            if publication.kind == .audio {
                self.logRemoteAudio("call.audio.remoteTrack.streamState", room: room, participant: participant, publication: publication, context: "\(streamState)")
            }
            self.publishParticipants(from: room)
            self.notifyRoomUpdated(context: "remote stream state")
        }
    }

    nonisolated func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState) {
        #if DEBUG
        print(
            "video.call.livekit.connectionState",
            "room=\(PrivacyLog.shortID(room.name))",
            "from=\(oldConnectionState)",
            "to=\(connectionState)",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
        Task { @MainActor in
            if connectionState == .connected || connectionState == .reconnecting {
                if connectionState == .connected {
                    await self.ensureRemoteAudioSubscriptions(room: room, context: "connection connected")
                }
                self.publishParticipants(from: room)
                self.notifyRoomUpdated(context: "connection \(connectionState)")
            } else if connectionState == .disconnected {
                BroadcastManager.shared.requestStop()
                self.updateStream.continuation.yield([])
                self.notifyRoomUpdated(context: "connection disconnected")
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

    func connect(roomURL: URL, token: String, iceServers: [TurnServerConfiguration], video: Bool) async throws -> CallMediaConnectionResult {
        CallMediaConnectionResult(microphonePublished: true, cameraPublished: video)
    }
    func setMicrophoneEnabled(_ enabled: Bool) async throws {}
    func setCameraEnabled(_ enabled: Bool) async throws {}
    func switchCamera() async throws {}
    func disconnect() async {}
    func waitForRemoteParticipant(timeoutSeconds: TimeInterval) async -> Bool { true }
}
#endif
