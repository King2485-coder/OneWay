import Foundation

#if canImport(CallKit)
import CallKit
import AVFoundation
import UIKit
#if canImport(LiveKit)
import LiveKit
#endif

/// Thin wrapper around CallKit. Owns the app's single `CXProvider` and exposes
/// helpers for outbound and inbound announcements. Doesn't touch media — that's
/// `CallTransport`'s job. Splitting them keeps the system-call UX (lock-screen,
/// recents, audio routing) decoupled from the WebRTC provider you pick.
@MainActor
final class CallKitBridge: NSObject {
    static let shared = CallKitBridge()

    private let provider: CXProvider
    private let controller = CXCallController()

    /// Forwarded delegate hooks so a `CallService` can react to CallKit events
    /// (system-driven answer, end, mute, audio session activation).
    var onAnswer:      ((UUID) -> Void)?
    var onEnd:         ((UUID) -> Void)?
    var onMute:        ((UUID, Bool) -> Void)?
    var onProviderReset: (() -> Void)?

    private override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.supportedHandleTypes = [.generic, .phoneNumber]
        config.maximumCallsPerCallGroup = 1
        config.includesCallsInRecents = true
        if let icon = UIImage(named: "CallIcon") {
            config.iconTemplateImageData = icon.pngData()
        }
        self.provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    /// Tell the OS we're starting an outbound call. This makes it appear in
    /// system Recents and lets audio routing survive backgrounding.
    func reportOutboundCallStarted(uuid: UUID, handle: String, hasVideo: Bool) async throws {
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: handle))
        action.isVideo = hasVideo
        try await controller.requestTransaction(with: action)
    }

    /// Show the iOS incoming-call screen for a remote-initiated call. Pair
    /// this with PushKit so it survives the app being suspended.
    func reportIncomingCall(uuid: UUID, handle: String, hasVideo: Bool) async throws {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: handle)
        update.hasVideo = hasVideo
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        try await provider.reportNewIncomingCall(with: uuid, update: update)
    }

    /// Mark an outbound call as connected (audio session is now hot).
    func reportConnected(uuid: UUID) {
        provider.reportOutgoingCall(with: uuid, connectedAt: Date())
    }

    /// End the call from our side (e.g. user tapped end inside our UI).
    func endCall(uuid: UUID) async throws {
        let action = CXEndCallAction(call: uuid)
        try await controller.requestTransaction(with: action)
    }

    /// Toggle mute through CallKit so the system audio session updates.
    func setMuted(uuid: UUID, muted: Bool) async throws {
        let action = CXSetMutedCallAction(call: uuid, muted: muted)
        try await controller.requestTransaction(with: action)
    }
}

// MARK: - CXProviderDelegate

extension CallKitBridge: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in self.onProviderReset?() }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in
            self.onAnswer?(action.callUUID)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            self.onEnd?(action.callUUID)
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
        #if canImport(LiveKit)
        do {
            try audioSession.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
            )
            try audioSession.setActive(true)
            try AudioManager.shared.setEngineAvailability(.default)
            print("🎧 CallKitBridge didActivate — LiveKit audio engine enabled")
        } catch {
            print("❌ CallKitBridge audio activation error:", error)
        }
        #endif
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        #if canImport(LiveKit)
        print("ℹ️ CallKitBridge didDeactivate — deferring engine shutdown to call teardown")
        #endif
    }
}
#endif
