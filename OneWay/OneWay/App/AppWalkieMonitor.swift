import Combine
import Foundation
import UIKit

extension Notification.Name {
    static let callSoundSuppressionAcquired = Notification.Name("OneWay.callSoundSuppressionAcquired")
    static let callSoundSuppressionClearedChirpAudio = Notification.Name("OneWay.callSoundSuppressionClearedChirpAudio")
}

@MainActor
final class CallSoundController {
    static let shared = CallSoundController()

    static let ringtoneFileName = "OneWayPulse.caf"

    private init() {}

    var bundledRingtoneName: String? {
        Bundle.main.url(forResource: "OneWayPulse", withExtension: "caf") == nil ? nil : Self.ringtoneFileName
    }

    func logCallKitRingtoneConfigured(source: String, providerObject: String, supportsVideo: Bool) {
        #if DEBUG
        print(
            "CALLKIT_RINGTONE_CONFIGURED",
            "sound=\(Self.ringtoneFileName)",
            "supportsVideo=\(supportsVideo)",
            "providerObject=\(providerObject)",
            "source=\(source)",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        print(
            "CALLKIT_PROVIDER_CONFIGURED",
            "localizedName=OneWay",
            "ringtoneSound=\(Self.ringtoneFileName)",
            "supportsVideo=\(supportsVideo)",
            "providerObject=\(providerObject)",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }

    func logIncomingCallReported(callId: UUID, callKitUUID: UUID, hasVideo: Bool, source: String) {
        #if DEBUG
        print(
            "CALLKIT_INCOMING_CALL_REPORTED",
            "callId=\(PrivacyLog.shortID(callId.uuidString))",
            "callKitUUID=\(PrivacyLog.shortID(callKitUUID.uuidString))",
            "ringtoneSound=\(Self.ringtoneFileName)",
            "type=\(hasVideo ? "video" : "audio")",
            "source=\(source)",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }

    func logCallKitAudioActivated(callId: UUID?, source: String) {
        #if DEBUG
        print(
            "CALLKIT_AUDIO_ACTIVATED",
            "sound=\(Self.ringtoneFileName)",
            "callId=\(PrivacyLog.shortID(callId?.uuidString))",
            "source=\(source)",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }

    func logCallKitAudioDeactivated(callId: UUID?, source: String) {
        #if DEBUG
        print(
            "CALLKIT_AUDIO_DEACTIVATED",
            "sound=\(Self.ringtoneFileName)",
            "callId=\(PrivacyLog.shortID(callId?.uuidString))",
            "source=\(source)",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }

    func logOutgoingRingbackStarted(callId: UUID, hasVideo: Bool, source: String) {
        #if DEBUG
        print(
            "CALL_RINGBACK_STARTED",
            "sound=system_callkit_ringback",
            "callId=\(PrivacyLog.shortID(callId.uuidString))",
            "type=\(hasVideo ? "video" : "audio")",
            "source=\(source)",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }

    func logRingtoneMissing(source: String) {
        #if DEBUG
        print(
            "CALL_RINGTONE_ASSET_MISSING",
            "expected=\(Self.ringtoneFileName)",
            "source=\(source)",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }
}

enum CommunicationMode: String {
    case idle
    case chirp
    case audioCall
    case videoCall
}

typealias MediaMode = CommunicationMode

enum AppSoundCategory: String, CaseIterable {
    case chirp
    case notification
    case manualRingtone
    case legacyWalkie
    case audioServices
    case mediaPlayback
    case other
}

struct AppSoundDescriptor: Equatable {
    let name: String
    let category: AppSoundCategory
}

enum OneWaySound: String {
    case incomingCallRingtone
    case outgoingRingback
    case callConnected
    case callEnded
    case chirpStart
    case chirpEnd
    case chirpIncoming
    case chirpRequest
}

enum ChirpSoundEvent: String, CaseIterable {
    case pushToTalkPress
    case pushToTalkRelease
    case incomingTransmission
    case chirpRequest
    case chirpConnected
    case chirpDisconnected
    case chirpNotification

    init?(sound: OneWaySound) {
        switch sound {
        case .chirpStart:
            self = .pushToTalkPress
        case .chirpEnd:
            self = .pushToTalkRelease
        case .chirpIncoming:
            self = .incomingTransmission
        case .chirpRequest:
            self = .chirpRequest
        case .incomingCallRingtone, .outgoingRingback, .callConnected, .callEnded:
            return nil
        }
    }
}

enum CommunicationSoundPolicy {
    static func allowsChirpSound(currentMode: CommunicationMode, event: ChirpSoundEvent) -> Bool {
        currentMode == .chirp
    }
}

@MainActor
enum ManualSoundAuthorization {
    static func isAllowed(category: AppSoundCategory, communicationMode: CommunicationMode) -> Bool {
        guard CallSoundSuppressionController.shared.mayPlayManualAppSound(category) else {
            return false
        }
        switch communicationMode {
        case .audioCall, .videoCall:
            return false
        case .chirp:
            return category == .chirp || category == .legacyWalkie || category == .audioServices
        case .idle:
            return category != .manualRingtone
        }
    }

    static func isAllowed(sound: AppSoundDescriptor, communicationMode: CommunicationMode) -> Bool {
        isAllowed(category: sound.category, communicationMode: communicationMode)
    }
}

enum CallPushSoundPolicy {
    struct Decision: Equatable {
        let sound: String?
        let usesCallKit: Bool
    }

    static func policy(eventType: String?, hasVideo: Bool) -> Decision {
        let normalized = eventType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "incoming_oneway_call" || normalized == "call:ringing" {
            return Decision(sound: nil, usesCallKit: true)
        }
        return Decision(sound: "default", usesCallKit: false)
    }
}

@MainActor
enum SoundDiagnostics {
    static func logPlaybackAboutToStart(
        filename: String,
        soundID: String,
        category: AppSoundCategory,
        callId: UUID?,
        sourceFile: StaticString,
        sourceFunction: StaticString,
        line: UInt = #line
    ) {
        logAudioPlayRequest(
            filename: filename,
            soundID: soundID,
            systemSoundID: nil,
            avAudioPlayerURL: nil,
            avPlayerURL: nil,
            category: category,
            callId: callId,
            sourceFile: sourceFile,
            sourceFunction: sourceFunction,
            line: line
        )
    }

    static func logAudioPlayRequest(
        filename: String?,
        soundID: String?,
        systemSoundID: String?,
        avAudioPlayerURL: String?,
        avPlayerURL: String?,
        category: AppSoundCategory,
        callId: UUID?,
        sourceFile: StaticString,
        sourceFunction: StaticString,
        line: UInt = #line
    ) {
        #if DEBUG
        let mode = MediaModeCoordinator.shared.currentMode
        let resolvedCallId = callId ?? (MediaModeCoordinator.shared.isCallActive ? MediaModeCoordinator.shared.currentSessionId : nil)
        let stackTrace = Thread.callStackSymbols.prefix(15).joined(separator: " <- ")
        print(
            "AUDIO_PLAY_REQUEST",
            "sourceFile=\(sourceFile)",
            "function=\(sourceFunction)",
            "line=\(line)",
            "stackTrace=\(stackTrace)",
            "soundFilename=\(filename ?? "nil")",
            "SystemSoundID=\(systemSoundID ?? "nil")",
            "AVAudioPlayerURL=\(avAudioPlayerURL ?? "nil")",
            "AVPlayerURL=\(avPlayerURL ?? "nil")",
            "soundID=\(soundID ?? "nil")",
            "soundCategory=\(category.rawValue)",
            "communicationMode=\(mode.rawValue)",
            "callId=\(PrivacyLog.shortID(resolvedCallId?.uuidString))",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        print(
            "SOUND_PLAYBACK_ABOUT_TO_START",
            "filename=\(filename ?? "nil")",
            "soundID=\(soundID ?? "nil")",
            "soundCategory=\(category.rawValue)",
            "sourceFile=\(sourceFile)",
            "function=\(sourceFunction)",
            "line=\(line)",
            "callID=\(PrivacyLog.shortID(resolvedCallId?.uuidString))",
            "communicationMode=\(mode.rawValue)",
            "callSuppressionActive=\(CallSoundSuppressionController.shared.isSuppressionActive)",
            "activeCallIds=\(CallSoundSuppressionController.shared.redactedActiveCallIDs)",
            "stackTrace=\(stackTrace)",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }

    static func logOriginTrace(
        sound: AppSoundDescriptor,
        mode: CommunicationMode,
        callId: UUID?,
        chirpId: UUID?,
        sourceFile: StaticString,
        sourceFunction: StaticString,
        line: UInt
    ) {
        #if DEBUG
        print(
            "SOUND_ORIGIN_TRACE",
            "sound=\(sound.name)",
            "soundCategory=\(sound.category.rawValue)",
            "sourceFile=\(sourceFile)",
            "sourceFunction=\(sourceFunction)",
            "line=\(line)",
            "communicationMode=\(mode.rawValue)",
            "callSuppressionActive=\(CallSoundSuppressionController.shared.isSuppressionActive)",
            "activeCallIds=\(CallSoundSuppressionController.shared.redactedActiveCallIDs)",
            "callId=\(PrivacyLog.shortID(callId?.uuidString))",
            "chirpId=\(PrivacyLog.shortID(chirpId?.uuidString))",
            "stack=\(Thread.callStackSymbols.prefix(8).joined(separator: " <- "))",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }

    static func logRequested(
        sound: AppSoundDescriptor,
        mode: CommunicationMode,
        callId: UUID?,
        chirpId: UUID?,
        sourceFile: StaticString,
        sourceFunction: StaticString
    ) {
        logOriginTrace(
            sound: sound,
            mode: mode,
            callId: callId,
            chirpId: chirpId,
            sourceFile: sourceFile,
            sourceFunction: sourceFunction,
            line: #line
        )
        #if DEBUG
        print(
            "SOUND_REQUESTED",
            "sound=\(sound.name)",
            "category=\(sound.category.rawValue)",
            "communicationMode=\(mode.rawValue)",
            "callId=\(PrivacyLog.shortID(callId?.uuidString))",
            "chirpId=\(PrivacyLog.shortID(chirpId?.uuidString))",
            "sourceFile=\(sourceFile)",
            "sourceFunction=\(sourceFunction)",
            "stack=\(Thread.callStackSymbols.prefix(6).joined(separator: " <- "))",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        if CallSoundSuppressionController.shared.isSuppressionActive {
            print(
                "MANUAL_SOUND_HARD_BLOCKED_DURING_CALL",
                "filename=\(sound.name)",
                "category=\(sound.category.rawValue)",
                "communicationMode=\(mode.rawValue)",
                "activeCallIds=\(CallSoundSuppressionController.shared.redactedActiveCallIDs)",
                "sourceFile=\(sourceFile)",
                "function=\(sourceFunction)",
                "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
            )
        }
        #endif
    }

    static func logPlayed(
        sound: AppSoundDescriptor,
        mode: CommunicationMode,
        callId: UUID?,
        chirpId: UUID?,
        sourceFile: StaticString,
        sourceFunction: StaticString
    ) {
        #if DEBUG
        print(
            "SOUND_PLAYED",
            "sound=\(sound.name)",
            "category=\(sound.category.rawValue)",
            "communicationMode=\(mode.rawValue)",
            "callId=\(PrivacyLog.shortID(callId?.uuidString))",
            "chirpId=\(PrivacyLog.shortID(chirpId?.uuidString))",
            "sourceFile=\(sourceFile)",
            "sourceFunction=\(sourceFunction)",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }

    static func logBlocked(
        sound: AppSoundDescriptor,
        mode: CommunicationMode,
        callId: UUID?,
        chirpId: UUID?,
        reason: String,
        sourceFile: StaticString,
        sourceFunction: StaticString
    ) {
        #if DEBUG
        print(
            "SOUND_BLOCKED",
            "sound=\(sound.name)",
            "category=\(sound.category.rawValue)",
            "communicationMode=\(mode.rawValue)",
            "callId=\(PrivacyLog.shortID(callId?.uuidString))",
            "chirpId=\(PrivacyLog.shortID(chirpId?.uuidString))",
            "reason=\(reason)",
            "sourceFile=\(sourceFile)",
            "sourceFunction=\(sourceFunction)",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        if mode == .audioCall || mode == .videoCall || CallSoundSuppressionController.shared.isSuppressionActive {
            print(
                "UNEXPECTED_CALL_SOUND_BLOCKED",
                "filename=\(sound.name)",
                "category=\(sound.category.rawValue)",
                "communicationMode=\(mode.rawValue)",
                "callId=\(PrivacyLog.shortID(callId?.uuidString))",
                "activeCallIds=\(CallSoundSuppressionController.shared.redactedActiveCallIDs)",
                "sourceFile=\(sourceFile)",
                "function=\(sourceFunction)",
                "reason=\(reason)",
                "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
            )
        }
        if (mode == .audioCall || mode == .videoCall || CallSoundSuppressionController.shared.isSuppressionActive),
           sound.category == .chirp || sound.category == .legacyWalkie {
            print(
                "CHIRP_SOUND_BLOCKED_FOR_CALL",
                "sound=\(sound.name)",
                "category=\(sound.category.rawValue)",
                "communicationMode=\(mode.rawValue)",
                "callId=\(PrivacyLog.shortID(callId?.uuidString))",
                "activeCallIds=\(CallSoundSuppressionController.shared.redactedActiveCallIDs)",
                "sourceFile=\(sourceFile)",
                "sourceFunction=\(sourceFunction)",
                "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
            )
        }
        #endif
    }
}

@MainActor
final class CallSoundSuppressionController {
    static let shared = CallSoundSuppressionController()

    private(set) var activeCallIDs: Set<UUID> = []
    private(set) var suppressionGeneration: UInt64 = 0
    private(set) var pendingReleaseCallIDs: Set<UUID> = []

    private init() {}

    var isSuppressionActive: Bool {
        !activeCallIDs.isEmpty
    }

    var redactedActiveCallIDs: String {
        let ids = activeCallIDs
            .map { PrivacyLog.shortID($0.uuidString) }
            .sorted()
            .joined(separator: ",")
        return "[\(ids)]"
    }

    func acquire(callID: UUID, reason: String) {
        guard !activeCallIDs.contains(callID) else {
            #if DEBUG
            print(
                "DUPLICATE_CALL_SOUND_ACQUIRE_IGNORED",
                "callId=\(PrivacyLog.shortID(callID.uuidString))",
                "reason=\(reason)",
                "activeCallCount=\(activeCallIDs.count)",
                "generation=\(suppressionGeneration)",
                "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
            )
            #endif
            return
        }
        activeCallIDs.insert(callID)
        pendingReleaseCallIDs.remove(callID)
        suppressionGeneration += 1
        #if DEBUG
        print(
            "CALL_SOUND_SUPPRESSION_ACQUIRED",
            "callId=\(PrivacyLog.shortID(callID.uuidString))",
            "reason=\(reason)",
            "activeCallCount=\(activeCallIDs.count)",
            "generation=\(suppressionGeneration)",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
        clearQueuedChirpAudioEvents(reason: "suppression_acquired:\(reason)")
        NotificationCenter.default.post(name: .callSoundSuppressionAcquired, object: nil)
    }

    func transfer(from oldCallID: UUID, to newCallID: UUID, reason: String) {
        guard oldCallID != newCallID else {
            acquire(callID: newCallID, reason: reason)
            return
        }
        if activeCallIDs.remove(oldCallID) != nil {
            pendingReleaseCallIDs.remove(oldCallID)
        }
        activeCallIDs.insert(newCallID)
        pendingReleaseCallIDs.remove(newCallID)
        suppressionGeneration += 1
        #if DEBUG
        print(
            "CALL_SOUND_SUPPRESSION_TRANSFERRED",
            "fromCallId=\(PrivacyLog.shortID(oldCallID.uuidString))",
            "toCallId=\(PrivacyLog.shortID(newCallID.uuidString))",
            "reason=\(reason)",
            "activeCallCount=\(activeCallIDs.count)",
            "generation=\(suppressionGeneration)",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
        clearQueuedChirpAudioEvents(reason: "suppression_transferred:\(reason)")
    }

    func releaseAfterTeardown(callID: UUID, reason: String) async {
        guard activeCallIDs.contains(callID) else {
            #if DEBUG
            print(
                "DUPLICATE_CALL_SOUND_RELEASE_IGNORED",
                "callId=\(PrivacyLog.shortID(callID.uuidString))",
                "reason=\(reason)",
                "activeCallCount=\(activeCallIDs.count)",
                "generation=\(suppressionGeneration)",
                "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
            )
            #endif
            return
        }
        guard !pendingReleaseCallIDs.contains(callID) else {
            #if DEBUG
            print(
                "DUPLICATE_CALL_SOUND_RELEASE_IGNORED",
                "callId=\(PrivacyLog.shortID(callID.uuidString))",
                "reason=\(reason)",
                "activeCallCount=\(activeCallIDs.count)",
                "generation=\(suppressionGeneration)",
                "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
            )
            #endif
            return
        }
        pendingReleaseCallIDs.insert(callID)
        #if DEBUG
        print(
            "CALL_SOUND_SUPPRESSION_RELEASE_REQUESTED",
            "callId=\(PrivacyLog.shortID(callID.uuidString))",
            "reason=\(reason)",
            "activeCallCount=\(activeCallIDs.count)",
            "generation=\(suppressionGeneration)",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        print(
            "CHIRP_NETWORK_RESUMED_AUDIO_STILL_SUPPRESSED",
            "callId=\(PrivacyLog.shortID(callID.uuidString))",
            "reason=\(reason)",
            "activeCallIds=\(redactedActiveCallIDs)",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
        clearQueuedChirpAudioEvents(reason: "release_requested:\(reason)")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        clearQueuedChirpAudioEvents(reason: "post_call_silence_window_complete:\(reason)")
        activeCallIDs.remove(callID)
        pendingReleaseCallIDs.remove(callID)
        suppressionGeneration += 1
        #if DEBUG
        print(
            "CALL_SOUND_SUPPRESSION_RELEASED",
            "callId=\(PrivacyLog.shortID(callID.uuidString))",
            "reason=\(reason)",
            "activeCallCount=\(activeCallIDs.count)",
            "generation=\(suppressionGeneration)",
            "queuedChirpAudioCount=0",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }

    func mayPlayChirpSound() -> Bool {
        !isSuppressionActive
    }

    func mayPlayManualAppSound(_ category: AppSoundCategory) -> Bool {
        guard !isSuppressionActive else { return false }
        return category != .manualRingtone
    }

    func clearQueuedChirpAudioEvents(reason: String) {
        #if DEBUG
        print(
            "CHIRP_AUDIO_QUEUE_CLEARED",
            "reason=\(reason)",
            "activeCallIds=\(redactedActiveCallIDs)",
            "queuedChirpAudioCount=0",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
        NotificationCenter.default.post(name: .callSoundSuppressionClearedChirpAudio, object: nil)
    }
}

@MainActor
final class MediaModeCoordinator: ObservableObject {
    static let shared = MediaModeCoordinator()

    @Published private(set) var currentMode: CommunicationMode = .idle
    @Published private(set) var currentSessionId: UUID?

    private init() {}

    var isCallActive: Bool {
        currentMode == .audioCall || currentMode == .videoCall
    }

    func activate(mode: CommunicationMode, sessionId: UUID) {
        if currentMode != .idle, currentMode != mode, currentSessionId != sessionId {
            #if DEBUG
            print(
                "MEDIA_MODE_OWNERSHIP_CONFLICT",
                "currentMode=\(currentMode.rawValue)",
                "currentSessionId=\(PrivacyLog.shortID(currentSessionId?.uuidString))",
                "requestedMode=\(mode.rawValue)",
                "requestedSessionId=\(PrivacyLog.shortID(sessionId.uuidString))",
                "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
            )
            #endif
        }
        currentMode = mode
        currentSessionId = sessionId
        if mode == .audioCall || mode == .videoCall {
            AppWalkieMonitor.shared.suspendForCall(callId: sessionId, mode: mode)
        }
    }

    func deactivate(mode: CommunicationMode, sessionId: UUID) {
        guard currentMode == mode, currentSessionId == sessionId else { return }
        currentMode = .idle
        currentSessionId = nil
        if mode == .audioCall || mode == .videoCall {
            AppWalkieMonitor.shared.resumeAfterCall(callId: sessionId)
        }
    }

    func canStartChirp(sessionId: UUID? = nil) -> Bool {
        if isCallActive {
            #if DEBUG
            print(
                "chirp.media.blocked",
                "reason=\(currentMode.rawValue)",
                "callSessionId=\(PrivacyLog.shortID(currentSessionId?.uuidString))",
                "chirpSessionId=\(PrivacyLog.shortID(sessionId?.uuidString))",
                "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
            )
            #endif
            return false
        }
        return true
    }
}

@MainActor
final class AppWalkieMonitor: ObservableObject {
    static let shared = AppWalkieMonitor()

    @Published var incomingChannel: WalkieChannel?

    private var task: Task<Void, Never>?
    private var seenSessionIds = Set<String>()
    private var isStarted = false
    private var callSuspensionOwner: UUID?
    private var callSuspensionMode: CommunicationMode?
    private var consecutivePollFailures = 0

    private init() {}

    func start() {
        isStarted = true
        guard task == nil, callSuspensionOwner == nil else { return }
        stopTaskOnly()
        consecutivePollFailures = 0

        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                var delaySeconds = 1
                // Only poll when the app is in the foreground.
                if UIApplication.shared.applicationState == .active {
                    if await poll() {
                        consecutivePollFailures = 0
                    } else {
                        consecutivePollFailures = min(consecutivePollFailures + 1, 5)
                        delaySeconds = min(1 << (consecutivePollFailures - 1), 15)
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
            }
        }
    }

    func stop() {
        isStarted = false
        stopTaskOnly()
        incomingChannel = nil
        seenSessionIds.removeAll()
        consecutivePollFailures = 0
    }

    func suspendForCall(callId: UUID, mode: CommunicationMode) {
        let previousOwner = callSuspensionOwner
        callSuspensionOwner = callId
        callSuspensionMode = mode
        stopTaskOnly()
        incomingChannel = nil
        #if DEBUG
        print(
            "chirp.polling.suspended",
            "reason=\(mode == .videoCall ? "activeVideoCall" : "activeAudioCall")",
            "callId=\(PrivacyLog.shortID(callId.uuidString))",
            "previousOwner=\(PrivacyLog.shortID(previousOwner?.uuidString))",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }

    func resumeAfterCall(callId: UUID) {
        guard callSuspensionOwner == callId else {
            #if DEBUG
            print(
                "CHIRP_RESUME_BLOCKED_WRONG_CALL",
                "requestedCallId=\(PrivacyLog.shortID(callId.uuidString))",
                "ownerCallId=\(PrivacyLog.shortID(callSuspensionOwner?.uuidString))",
                "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
            )
            #endif
            return
        }
        callSuspensionOwner = nil
        callSuspensionMode = nil
        #if DEBUG
        print(
            "chirp.polling.resumed",
            "reason=callEnded",
            "callId=\(PrivacyLog.shortID(callId.uuidString))",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
        if isStarted {
            start()
        }
    }

    func ignoreCurrent() {
        if let id = incomingChannel?.sessionId ?? incomingChannel?.id {
            seenSessionIds.insert(id)
        }
        incomingChannel = nil
    }

    private func stopTaskOnly() {
        task?.cancel()
        task = nil
    }

    private func poll() async -> Bool {
        guard callSuspensionOwner == nil, !MediaModeCoordinator.shared.isCallActive else {
            #if DEBUG
            print(
                "CHIRP_POLL_BLOCKED_ACTIVE_CALL",
                "ownerCallId=\(PrivacyLog.shortID(callSuspensionOwner?.uuidString))",
                "mode=\(MediaModeCoordinator.shared.currentMode.rawValue)",
                "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
            )
            #endif
            return true
        }
        do {
            let response = try await WalkieService.shared.channels()
            let activeIncoming = response.channels.first(where: { ($0.isIncoming ?? false) && $0.status == "active" })
            guard let incoming = activeIncoming else {
                incomingChannel = nil
                return true
            }

            let sessionId = incoming.sessionId ?? incoming.id
            guard !seenSessionIds.contains(sessionId) else { return true }

            seenSessionIds.insert(sessionId)
            incomingChannel = incoming
            return true
        } catch {
            // Don't spam UI. Just log in debug.
#if DEBUG
            print("⚠️ Walkie monitor poll failed:", PrivacyLog.redact(error.localizedDescription))
#endif
            return false
        }
    }
}
