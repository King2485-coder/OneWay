import Foundation

#if canImport(CallKit)
import CallKit
import AVFoundation
import UIKit
#if canImport(LiveKit)
import LiveKit
#endif

enum CallAudioActivationBarrierError: LocalizedError {
    case timedOut
    case invalidSession(category: String, mode: String, inputs: String)

    var errorDescription: String? {
        switch self {
        case .timedOut:
            return "Call audio did not activate in time."
        case .invalidSession(let category, let mode, let inputs):
            return "Call audio was not ready. category=\(category) mode=\(mode) inputs=\(inputs)"
        }
    }
}

enum CallAudioActivationLifecycleState: String {
    case inactive
    case activationRequested
    case active
    case deactivating
}

@MainActor
final class CallAudioActivationCoordinator {
    static let shared = CallAudioActivationCoordinator()

    private struct Waiter {
        let continuation: CheckedContinuation<Void, Error>
    }

    private var state: CallAudioActivationLifecycleState = .inactive
    private var activeCallKitUUID: UUID?
    private var activeCallId: UUID?
    private var waiters: [UUID: Waiter] = [:]

    private init() {}

    var activeCallIdentifier: UUID? {
        activeCallId
    }

    func requestActivation(callId: UUID, callKitUUID: UUID, lifecycleState: CallConnectionState?) {
        activeCallId = callId
        activeCallKitUUID = callKitUUID
        state = .activationRequested
        logAudioSequence("call.audio.activation.requested", callId: callId, callKitUUID: callKitUUID, lifecycleState: lifecycleState)
    }

    func waitUntilActivated(callId: UUID, callKitUUID: UUID, timeoutSeconds: TimeInterval, lifecycleState: CallConnectionState?) async throws {
        logAudioSequence("call.audio.barrier.wait.started", callId: callId, callKitUUID: callKitUUID, lifecycleState: lifecycleState)
        if state == .active, activeCallKitUUID == callKitUUID {
            try validateActiveSession()
            logAudioSequence("call.audio.barrier.opened", callId: callId, callKitUUID: callKitUUID, lifecycleState: lifecycleState)
            return
        }

        let waiterID = UUID()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { continuation in
                    self.waiters[waiterID] = Waiter(continuation: continuation)
                }
            }
            group.addTask {
                let delay = UInt64(max(timeoutSeconds, 0) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: delay)
                throw CallAudioActivationBarrierError.timedOut
            }
            do {
                _ = try await group.next()
                group.cancelAll()
                waiters.removeValue(forKey: waiterID)
            } catch {
                group.cancelAll()
                waiters.removeValue(forKey: waiterID)
                if case CallAudioActivationBarrierError.timedOut = error {
                    logAudioSequence("CALLKIT_AUDIO_ACTIVATION_TIMEOUT", callId: callId, callKitUUID: callKitUUID, lifecycleState: lifecycleState)
                }
                throw error
            }
        }
    }

    func didActivate(audioSession: AVAudioSession) {
        state = .active
        logAudioSequence("call.audio.didActivate.received", callId: activeCallId, callKitUUID: activeCallKitUUID, lifecycleState: nil)
        do {
            try CallAudioSessionCoordinator.shared.callKitDidActivate(
                audioSession: audioSession,
                callID: activeCallId,
                owner: "CallAudioActivationCoordinator.didActivate"
            )
            try validateActiveSession()
            logAudioSequence("call.audio.session.validated", callId: activeCallId, callKitUUID: activeCallKitUUID, lifecycleState: nil)
            let continuations = waiters.values
            waiters.removeAll()
            continuations.forEach { $0.continuation.resume(returning: ()) }
            logAudioSequence("CALLKIT_AUDIO_BARRIER_OPENED", callId: activeCallId, callKitUUID: activeCallKitUUID, lifecycleState: nil)
            logAudioSequence("call.audio.barrier.opened", callId: activeCallId, callKitUUID: activeCallKitUUID, lifecycleState: nil)
        } catch {
            let continuations = waiters.values
            waiters.removeAll()
            continuations.forEach { $0.continuation.resume(throwing: error) }
        }
    }

    func didDeactivate() {
        state = .deactivating
        logAudioSequence("call.audio.didDeactivate.received", callId: activeCallId, callKitUUID: activeCallKitUUID, lifecycleState: nil)
        CallAudioSessionCoordinator.shared.callKitDidDeactivate(callID: activeCallId, owner: "CallAudioActivationCoordinator.didDeactivate")
        state = .inactive
        activeCallId = nil
        activeCallKitUUID = nil
    }

    private func validateActiveSession() throws {
        let session = AVAudioSession.sharedInstance()
        let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        guard session.category == .playAndRecord,
              session.mode == .voiceChat || session.mode == .videoChat,
              !session.currentRoute.inputs.isEmpty else {
            throw CallAudioActivationBarrierError.invalidSession(category: session.category.rawValue, mode: session.mode.rawValue, inputs: inputs)
        }
    }

    func logAudioSequence(_ event: String, callId: UUID?, callKitUUID: UUID?, lifecycleState: CallConnectionState?) {
        #if DEBUG
        let session = AVAudioSession.sharedInstance()
        let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        print(
            event,
            "callId=\(PrivacyLog.shortID(callId?.uuidString))",
            "callKitUUID=\(PrivacyLog.shortID(callKitUUID?.uuidString))",
            "lifecycleState=\(lifecycleState?.rawValue ?? "nil")",
            "barrierState=\(state.rawValue)",
            "category=\(session.category.rawValue)",
            "mode=\(session.mode.rawValue)",
            "inputRoute=\(inputs)",
            "outputRoute=\(outputs)",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }
}

@MainActor
final class CallKitProviderRegistry {
    static let shared = CallKitProviderRegistry()

    private var providerOwners: [String: String] = [:]

    private init() {}

    func register(provider: CXProvider, owner: String) {
        let key = String(describing: ObjectIdentifier(provider))
        providerOwners[key] = owner
        #if DEBUG
        assert(providerOwners.count == 1, "OneWay must have exactly one active CXProvider.")
        print(
            "CALLKIT_SINGLE_PROVIDER_CONFIRMED",
            "providerObject=\(key)",
            "owner=\(owner)",
            "activeProviderCount=\(providerOwners.count)",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }
}

@MainActor
final class CallAudioSessionCoordinator {
    static let shared = CallAudioSessionCoordinator()

    private struct RequestedConfiguration: Equatable {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
        let sampleRate: Double
        let ioBufferDuration: TimeInterval
    }

    private var expectedVideoByCallID: [UUID: Bool] = [:]
    private var activeCallID: UUID?
    private var appliedConfiguration: RequestedConfiguration?
    private var configurationMutationCount = 0
    private var routeMutationCount = 0
    private var hasMediaConnected = false
    private var stabilityTask: Task<Void, Never>?

    private init() {}

    private var artifactIsolationModeEnabled: Bool {
        #if DEBUG
        let value = ProcessInfo.processInfo.environment["CALL_AUDIO_ARTIFACT_ISOLATION_MODE"]
            ?? UserDefaults.standard.string(forKey: "CALL_AUDIO_ARTIFACT_ISOLATION_MODE")
        return value?.caseInsensitiveCompare("true") == .orderedSame
            || value == "1"
        #else
        return false
        #endif
    }

    func prepareCall(callID: UUID, video: Bool, owner: String) {
        expectedVideoByCallID[callID] = video
        #if DEBUG
        print(
            "CALL_AUDIO_SESSION_PREPARED",
            "callId=\(PrivacyLog.shortID(callID.uuidString))",
            "video=\(video)",
            "owner=\(owner)",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }

    func callKitDidActivate(audioSession: AVAudioSession, callID: UUID?, owner: String) throws {
        activeCallID = callID
        configurationMutationCount = 0
        routeMutationCount = 0
        hasMediaConnected = false
        let video = callID.flatMap { expectedVideoByCallID[$0] } ?? true
        let isolateArtifacts = artifactIsolationModeEnabled
        let request = RequestedConfiguration(
            category: .playAndRecord,
            mode: video ? .videoChat : .voiceChat,
            options: [.allowBluetoothHFP, .defaultToSpeaker],
            sampleRate: isolateArtifacts ? audioSession.sampleRate : 48_000,
            ioBufferDuration: isolateArtifacts ? audioSession.ioBufferDuration : 0.01
        )
        #if DEBUG
        if isolateArtifacts {
            print(
                "CALL_AUDIO_ARTIFACT_ISOLATION_MODE_ENABLED",
                "owner=\(owner)",
                "callId=\(PrivacyLog.shortID(callID?.uuidString))",
                "sampleRatePreferenceSkipped=true",
                "ioBufferPreferenceSkipped=true",
                "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
            )
        }
        #endif
        try applyIfNeeded(request, audioSession: audioSession, owner: owner, allowActiveTransition: false)
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
        AudioManager.shared.isSpeakerOutputPreferred = video
        AudioManager.shared.isVoiceProcessingBypassed = false
        try? AudioManager.shared.setEngineAvailability(.default)
        startStabilityDiagnostics()
    }

    func mediaDidConnect(roomName: String?, owner: String) {
        hasMediaConnected = true
        configurationMutationCount = 0
        routeMutationCount = 0
        #if DEBUG
        print(
            "ACTIVE_CALL_AUDIO_STABILIZED",
            "owner=\(owner)",
            "room=\(PrivacyLog.shortID(roomName))",
            "callId=\(PrivacyLog.shortID(activeCallID?.uuidString))",
            "configurationMutationCount=0",
            "routeMutationCount=0",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }

    func callKitDidDeactivate(callID: UUID?, owner: String) {
        stabilityTask?.cancel()
        stabilityTask = nil
        if let callID {
            expectedVideoByCallID.removeValue(forKey: callID)
        }
        appliedConfiguration = nil
        activeCallID = nil
        hasMediaConnected = false
        #if DEBUG
        print(
            "CALL_AUDIO_SESSION_DEACTIVATED_BY_CALLKIT",
            "callId=\(PrivacyLog.shortID(callID?.uuidString))",
            "owner=\(owner)",
            "configurationMutationCount=\(configurationMutationCount)",
            "routeMutationCount=\(routeMutationCount)",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }

    func liveKitConfigurationRequest(video: Bool, owner: String) {
        #if DEBUG
        print(
            "AUDIO_SESSION_CONFIGURATION_SKIPPED_IDENTICAL",
            "owner=\(owner)",
            "reason=callkit_owns_active_audio_session",
            "video=\(video)",
                    "callId=\(PrivacyLog.shortID(activeCallID?.uuidString))",
                    "mediaConnected=\(hasMediaConnected)",
                    "configurationMutationCount=\(configurationMutationCount)",
                    "routeMutationCount=\(routeMutationCount)",
                    "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }

    func skipRouteOverride(owner: String, requestedRoute: String) {
        #if DEBUG
        print(
            "AUDIO_ROUTE_CHANGE_SKIPPED_IDENTICAL",
            "owner=\(owner)",
            "requestedRoute=\(requestedRoute)",
            "reason=callkit_default_route_preserved",
            "callId=\(PrivacyLog.shortID(activeCallID?.uuidString))",
            "routeMutationCount=\(routeMutationCount)",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }

    private func applyIfNeeded(
        _ request: RequestedConfiguration,
        audioSession: AVAudioSession,
        owner: String,
        allowActiveTransition: Bool
    ) throws {
        let categoryMatches = audioSession.category == request.category
        let modeMatches = audioSession.mode == request.mode
        let sampleRateMatches = abs(audioSession.sampleRate - request.sampleRate) < 1
        let bufferMatches = abs(audioSession.ioBufferDuration - request.ioBufferDuration) < 0.002
        if categoryMatches, modeMatches, sampleRateMatches, bufferMatches, appliedConfiguration == request {
            #if DEBUG
            print(
                "AUDIO_SESSION_CONFIGURATION_SKIPPED_IDENTICAL",
                "owner=\(owner)",
                "category=\(audioSession.category.rawValue)",
                "mode=\(audioSession.mode.rawValue)",
                "sampleRate=\(audioSession.sampleRate)",
                "ioBuffer=\(audioSession.ioBufferDuration)",
                "callId=\(PrivacyLog.shortID(activeCallID?.uuidString))",
                "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
            )
            #endif
            return
        }

        if !sampleRateMatches {
            try audioSession.setPreferredSampleRate(request.sampleRate)
            configurationMutationCount += 1
        }
        if !bufferMatches {
            try audioSession.setPreferredIOBufferDuration(request.ioBufferDuration)
            configurationMutationCount += 1
        }
        if !categoryMatches || !modeMatches {
            try audioSession.setCategory(request.category, mode: request.mode, options: request.options)
            configurationMutationCount += 1
        }
        if allowActiveTransition {
            try audioSession.setActive(true)
            configurationMutationCount += 1
        }
        appliedConfiguration = request
        #if DEBUG
        print(
            "AUDIO_SESSION_CONFIGURATION_APPLIED",
            "owner=\(owner)",
            "category=\(request.category.rawValue)",
            "mode=\(request.mode.rawValue)",
            "sampleRate=\(request.sampleRate)",
            "ioBuffer=\(request.ioBufferDuration)",
            "callId=\(PrivacyLog.shortID(activeCallID?.uuidString))",
            "configurationMutationCount=\(configurationMutationCount)",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }

    private func startStabilityDiagnostics() {
        stabilityTask?.cancel()
        stabilityTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                let session = AVAudioSession.sharedInstance()
                let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
                let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
                #if DEBUG
                print(
                    "ACTIVE_CALL_AUDIO_STABILITY",
                    "callId=\(PrivacyLog.shortID(activeCallID?.uuidString))",
                    "category=\(session.category.rawValue)",
                    "mode=\(session.mode.rawValue)",
                    "activeOwnership=CallKit",
                    "inputRoute=\(inputs)",
                    "outputRoute=\(outputs)",
                    "sampleRate=\(session.sampleRate)",
                    "ioBuffer=\(session.ioBufferDuration)",
                    "configurationMutationCount=\(configurationMutationCount)",
                    "routeMutationCount=\(routeMutationCount)",
                    "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
                )
                #endif
            }
        }
    }
}

/// Thin wrapper around CallKit. Owns the app's single `CXProvider` and exposes
/// helpers for outbound and inbound announcements. Doesn't touch media — that's
/// `CallTransport`'s job. Splitting them keeps the system-call UX (lock-screen,
/// recents, audio routing) decoupled from the WebRTC provider you pick.
@MainActor
final class CallKitBridge: NSObject {
    static let shared = CallKitBridge()

    private let provider: CXProvider
    private let controller = CXCallController()
    private var callKitUUIDByCallID: [UUID: UUID] = [:]
    private var callIDByCallKitUUID: [UUID: UUID] = [:]
    private var callKitUUIDsPendingDeactivationRelease: Set<UUID> = []

    /// Forwarded delegate hooks so a `CallService` can react to CallKit events
    /// (system-driven answer, end, mute, audio session activation).
    var onAnswer:      ((UUID) async -> Void)?
    var onEnd:         ((UUID) async -> Void)?
    var onMute:        ((UUID, Bool) -> Void)?
    var onProviderReset: (() -> Void)?
    var onAudioSessionActivated: ((AVAudioSession) -> Void)?
    var onAudioSessionDeactivated: (() -> Void)?

    private let audioActivationCoordinator = CallAudioActivationCoordinator.shared

    private override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        // OneWay calls must stay on OneWay Signal/LiveKit. Advertising only
        // generic handles prevents iOS from treating these as carrier or
        // FaceTime-addressable phone/email calls.
        config.supportedHandleTypes = [.generic]
        config.maximumCallsPerCallGroup = 1
        config.includesCallsInRecents = true
        if let ringtone = CallSoundController.shared.bundledRingtoneName {
            SoundDiagnostics.logAudioPlayRequest(
                filename: ringtone,
                soundID: "CXProviderConfiguration.ringtoneSound",
                systemSoundID: nil,
                avAudioPlayerURL: nil,
                avPlayerURL: nil,
                category: .manualRingtone,
                callId: nil,
                sourceFile: #fileID,
                sourceFunction: #function,
                line: #line
            )
            config.ringtoneSound = ringtone
        } else {
            CallSoundController.shared.logRingtoneMissing(source: "CallKitBridge.init")
        }
        if let icon = UIImage(named: "CallIcon") {
            config.iconTemplateImageData = icon.pngData()
        }
        self.provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
        CallKitProviderRegistry.shared.register(provider: provider, owner: "CallKitBridge")
        CallSoundController.shared.logCallKitRingtoneConfigured(
            source: "CallKitBridge.init",
            providerObject: String(describing: ObjectIdentifier(provider)),
            supportsVideo: config.supportsVideo
        )
    }

    /// Tell the OS we're starting an outbound call. This makes it appear in
    /// system Recents and lets audio routing survive backgrounding.
    func reportOutboundCallStarted(uuid: UUID, handle: String, hasVideo: Bool) async throws {
        #if DEBUG
        print("📞 OneWay CallKit shell: outbound \(hasVideo ? "video" : "voice") uses OneWay Signal/LiveKit, not FaceTime")
        #endif
        guard registerCallKitMapping(callID: uuid, callKitUUID: uuid, source: "reportOutboundCallStarted") else { return }
        CallAudioSessionCoordinator.shared.prepareCall(callID: uuid, video: hasVideo, owner: "CallKitBridge.reportOutboundCallStarted")
        CallSoundController.shared.logOutgoingRingbackStarted(callId: uuid, hasVideo: hasVideo, source: "CallKitBridge.reportOutboundCallStarted")
        audioActivationCoordinator.requestActivation(callId: uuid, callKitUUID: uuid, lifecycleState: nil)
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: handle))
        action.isVideo = hasVideo
        do {
            try await controller.requestTransaction(with: action)
        } catch {
            releaseCallKitMapping(callKitUUID: uuid, reason: "outbound_start_failed")
            throw error
        }
    }

    /// Show the iOS incoming-call screen for a remote-initiated call. Pair
    /// this with PushKit so it survives the app being suspended.
    func reportIncomingCall(uuid: UUID, handle: String, hasVideo: Bool) async throws {
        #if DEBUG
        print("📞 OneWay CallKit shell: incoming \(hasVideo ? "video" : "voice") callID=\(uuid) uses OneWay Signal/LiveKit, not FaceTime")
        #endif
        guard registerCallKitMapping(callID: uuid, callKitUUID: uuid, source: "reportIncomingCall") else { return }
        CallAudioSessionCoordinator.shared.prepareCall(callID: uuid, video: hasVideo, owner: "CallKitBridge.reportIncomingCall")
        CallSoundController.shared.logIncomingCallReported(callId: uuid, callKitUUID: uuid, hasVideo: hasVideo, source: "CallKitBridge.reportIncomingCall")
        audioActivationCoordinator.requestActivation(callId: uuid, callKitUUID: uuid, lifecycleState: .ringing)
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: handle)
        update.hasVideo = hasVideo
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        do {
            try await provider.reportNewIncomingCall(with: uuid, update: update)
        } catch {
            releaseCallKitMapping(callKitUUID: uuid, reason: "incoming_report_failed")
            throw error
        }
    }

    /// Mark an outbound call as connected (audio session is now hot).
    func reportConnected(uuid: UUID) {
        #if DEBUG
        print("video.call.callkit.reportConnected callId=\(PrivacyLog.shortID(uuid.uuidString)) timestamp=\(ISO8601DateFormatter().string(from: Date()))")
        #endif
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    /// End the call from our side (e.g. user tapped end inside our UI).
    func endCall(uuid: UUID) async throws {
        callKitUUIDsPendingDeactivationRelease.insert(uuid)
        let action = CXEndCallAction(call: uuid)
        do {
            try await controller.requestTransaction(with: action)
        } catch {
            callKitUUIDsPendingDeactivationRelease.remove(uuid)
            throw error
        }
    }

    func callKitUUID(for callID: UUID) -> UUID? {
        callKitUUIDByCallID[callID]
    }

    func callID(forCallKitUUID callKitUUID: UUID) -> UUID {
        callIDByCallKitUUID[callKitUUID] ?? callKitUUID
    }

    func terminateLocalCallKit(callID: UUID, source: CallEndSource, operationID: UUID) async throws {
        let resolvedUUID = callKitUUIDByCallID[callID] ?? callID
        print(
            "UNIFIED_END_CALLKIT_REQUESTED",
            "callId=\(PrivacyLog.shortID(callID.uuidString))",
            "callKitUUID=\(resolvedUUID.uuidString)",
            "source=\(source.rawValue)",
            "operationId=\(PrivacyLog.shortID(operationID.uuidString))",
            "lifecycleState=ending",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        if callKitUUIDByCallID[callID] == nil {
            print(
                "REMOTE_CALLKIT_END_FAILED",
                "reason=missing_callkit_uuid_using_call_id_fallback",
                "callId=\(PrivacyLog.shortID(callID.uuidString))",
                "callKitUUID=\(resolvedUUID.uuidString)",
                "source=\(source.rawValue)",
                "operationId=\(PrivacyLog.shortID(operationID.uuidString))",
                "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
            )
        }
        try await endCall(uuid: resolvedUUID)
        print(
            "UNIFIED_END_CALLKIT_COMPLETED",
            "callId=\(PrivacyLog.shortID(callID.uuidString))",
            "callKitUUID=\(resolvedUUID.uuidString)",
            "source=\(source.rawValue)",
            "operationId=\(PrivacyLog.shortID(operationID.uuidString))",
            "lifecycleState=ending",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
    }

    /// Backend-originated remote hangups are external termination events. Report
    /// them straight to CallKit's provider so the native in-call UI disappears
    /// without waiting for the local user to generate a CXEndCallAction.
    @discardableResult
    func reportRemoteCallEnded(callID: UUID, reason: CXCallEndedReason = .remoteEnded) -> Bool {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        print(
            "REMOTE_CALLKIT_END_REQUESTED",
            "callId=\(PrivacyLog.shortID(callID.uuidString))",
            "endReason=\(reason.rawValue)",
            "timestamp=\(timestamp)"
        )

        // OneWay intentionally uses the authoritative backend call ID as the
        // CallKit UUID. The in-memory mapping can be lost after a process
        // suspension/relaunch or when the terminal event races the initial
        // registration. Falling back to `callID` is therefore safe and is
        // required to dismiss a surviving native call screen remotely.
        let callKitUUID = callKitUUIDByCallID[callID] ?? callID
        if callKitUUIDByCallID[callID] == nil {
            print(
                "REMOTE_CALLKIT_UUID_FALLBACK",
                "reason=missing_in_memory_mapping_using_canonical_call_id",
                "callId=\(PrivacyLog.shortID(callID.uuidString))",
                "callKitUUID=\(callKitUUID.uuidString)",
                "timestamp=\(timestamp)"
            )
        }

        print(
            "REMOTE_CALLKIT_UUID_RESOLVED",
            "callId=\(PrivacyLog.shortID(callID.uuidString))",
            "callKitUUID=\(callKitUUID.uuidString)",
            "originalIncomingOutgoingCallKitUUID=\(callKitUUID.uuidString)",
            "matchesCallId=\(callKitUUID == callID)",
            "timestamp=\(timestamp)"
        )

        callKitUUIDsPendingDeactivationRelease.insert(callKitUUID)
        provider.reportCall(with: callKitUUID, endedAt: Date(), reason: reason)

        print(
            "REMOTE_CALLKIT_PROVIDER_REPORTED_ENDED",
            "callId=\(PrivacyLog.shortID(callID.uuidString))",
            "callKitUUID=\(callKitUUID.uuidString)",
            "originalIncomingOutgoingCallKitUUID=\(callKitUUID.uuidString)",
            "endReason=\(reason.rawValue)",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        return true
    }

    /// Toggle mute through CallKit so the system audio session updates.
    func setMuted(uuid: UUID, muted: Bool) async throws {
        let action = CXSetMutedCallAction(call: uuid, muted: muted)
        try await controller.requestTransaction(with: action)
    }

    func waitForAudioSessionActivation(callId: UUID, timeoutSeconds: TimeInterval = 8, lifecycleState: CallConnectionState?) async throws {
        try await audioActivationCoordinator.waitUntilActivated(callId: callId, callKitUUID: callId, timeoutSeconds: timeoutSeconds, lifecycleState: lifecycleState)
    }

    private func markAudioSessionActivated(_ audioSession: AVAudioSession) {
        CallSoundController.shared.logCallKitAudioActivated(callId: audioActivationCoordinator.activeCallIdentifier, source: "CallKitBridge.didActivate")
        audioActivationCoordinator.didActivate(audioSession: audioSession)
        onAudioSessionActivated?(audioSession)
        #if DEBUG
        let inputs = audioSession.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }
        let outputs = audioSession.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }
        print(
            "call.audio.session.activated " +
            "category=\(audioSession.category.rawValue) mode=\(audioSession.mode.rawValue) " +
            "inputRoute=\(inputs) outputRoute=\(outputs) sampleRate=\(audioSession.sampleRate) " +
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }

    private func markAudioSessionDeactivated() {
        CallSoundController.shared.logCallKitAudioDeactivated(callId: audioActivationCoordinator.activeCallIdentifier, source: "CallKitBridge.didDeactivate")
        audioActivationCoordinator.didDeactivate()
        onAudioSessionDeactivated?()
        releasePendingMappingsAfterDeactivation()
        #if DEBUG
        print("call.audio.session.deactivated owner=CallKitBridge.didDeactivate timestamp=\(ISO8601DateFormatter().string(from: Date()))")
        #endif
    }

    @discardableResult
    private func registerCallKitMapping(callID: UUID, callKitUUID: UUID, source: String) -> Bool {
        if let existingUUID = callKitUUIDByCallID[callID] {
            print(
                "DUPLICATE_CALLKIT_CALL_CREATION_BLOCKED",
                "callId=\(PrivacyLog.shortID(callID.uuidString))",
                "existingCallKitUUID=\(existingUUID.uuidString)",
                "requestedCallKitUUID=\(callKitUUID.uuidString)",
                "source=\(source)",
                "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
            )
            return false
        }
        callKitUUIDByCallID[callID] = callKitUUID
        callIDByCallKitUUID[callKitUUID] = callID
        #if DEBUG
        print(
            "CALLKIT_UUID_MAPPING_REGISTERED",
            "callId=\(PrivacyLog.shortID(callID.uuidString))",
            "callKitUUID=\(callKitUUID.uuidString)",
            "source=\(source)",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
        return true
    }

    private func releaseCallKitMapping(callKitUUID: UUID, reason: String) {
        guard let callID = callIDByCallKitUUID.removeValue(forKey: callKitUUID) else { return }
        callKitUUIDByCallID.removeValue(forKey: callID)
        callKitUUIDsPendingDeactivationRelease.remove(callKitUUID)
        #if DEBUG
        print(
            "CALLKIT_UUID_MAPPING_RELEASED",
            "callId=\(PrivacyLog.shortID(callID.uuidString))",
            "callKitUUID=\(callKitUUID.uuidString)",
            "reason=\(reason)",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }

    private func releasePendingMappingsAfterDeactivation() {
        let pendingUUIDs = callKitUUIDsPendingDeactivationRelease
        guard !pendingUUIDs.isEmpty else { return }
        for callKitUUID in pendingUUIDs {
            let callID = callIDByCallKitUUID[callKitUUID]
            print(
                "REMOTE_CALLKIT_DID_DEACTIVATE",
                "callId=\(PrivacyLog.shortID(callID?.uuidString))",
                "callKitUUID=\(callKitUUID.uuidString)",
                "originalIncomingOutgoingCallKitUUID=\(callKitUUID.uuidString)",
                "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
            )
            releaseCallKitMapping(callKitUUID: callKitUUID, reason: "provider_did_deactivate")
        }
    }
}

// MARK: - CXProviderDelegate

extension CallKitBridge: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in
            #if DEBUG
            print("video.call.callkit.providerReset timestamp=\(ISO8601DateFormatter().string(from: Date()))")
            #endif
            self.onProviderReset?()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor in
            #if DEBUG
            print("📞 OneWay CallKitBridge start action fulfilled:", PrivacyLog.shortID(action.callUUID.uuidString))
            #endif
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in
            CallSoundSuppressionController.shared.acquire(callID: action.callUUID, reason: "CallKitBridge.answer_action_before_fulfill")
            #if DEBUG
            print(
                "CALL_ANSWER_SOUND_GUARD_CONFIRMED",
                "callId=\(PrivacyLog.shortID(action.callUUID.uuidString))",
                "suppressionActive=\(CallSoundSuppressionController.shared.isSuppressionActive)",
                "source=CallKitBridge.provider.perform.CXAnswerCallAction",
                "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
            )
            #endif
            CallAudioActivationCoordinator.shared.requestActivation(callId: action.callUUID, callKitUUID: action.callUUID, lifecycleState: .waitingForAudioActivation)
            CallAudioActivationCoordinator.shared.logAudioSequence("callkit.answerAction.received", callId: action.callUUID, callKitUUID: action.callUUID, lifecycleState: .waitingForAudioActivation)
            action.fulfill()
            CallAudioActivationCoordinator.shared.logAudioSequence("callkit.answerAction.fulfilled", callId: action.callUUID, callKitUUID: action.callUUID, lifecycleState: .waitingForAudioActivation)
            await self.onAnswer?(action.callUUID)
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            #if DEBUG
            print("video.call.callkit.endAction callId=\(PrivacyLog.shortID(action.callUUID.uuidString)) timestamp=\(ISO8601DateFormatter().string(from: Date()))")
            #endif
            self.callKitUUIDsPendingDeactivationRelease.insert(action.callUUID)
            let callID = self.callID(forCallKitUUID: action.callUUID)
            await self.onEnd?(callID)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task { @MainActor in
            self.onMute?(action.callUUID, action.isMuted)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Task { @MainActor in
            self.markAudioSessionActivated(audioSession)
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor in
            self.markAudioSessionDeactivated()
        }
    }
}
#endif
