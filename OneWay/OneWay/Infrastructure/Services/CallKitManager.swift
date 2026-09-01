import Foundation
import Combine

#if canImport(CallKit)
import CallKit
import AVFoundation
#if canImport(LiveKit)
import LiveKit
#endif

@MainActor
final class CallKitManager: NSObject, ObservableObject {
    static let shared = CallKitManager()

    private let provider: CXProvider
    private let controller = CXCallController()

    @Published var activeCallUUID: UUID?
    @Published var incomingCallerName: String?
    @Published var isIncomingCall = false

    override init() {
        let config = CXProviderConfiguration(localizedName: "OneWay")
        config.supportsVideo = true
        config.maximumCallsPerCallGroup = 1
        config.maximumCallGroups = 1
        config.includesCallsInRecents = true
        config.supportedHandleTypes = [.generic]

        self.provider = CXProvider(configuration: config)

        super.init()

        provider.setDelegate(self, queue: nil)
    }

    func reportIncomingCall(
        uuid: UUID,
        callerName: String,
        hasVideo: Bool = true
    ) {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.localizedCallerName = callerName
        update.hasVideo = hasVideo

        provider.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error {
                print("❌ CallKit incoming call error:", error)
            } else {
                print("✅ Incoming CallKit call shown")
                Task { @MainActor in
                    self.activeCallUUID = uuid
                    self.incomingCallerName = callerName
                    self.isIncomingCall = true
                }
            }
        }
    }

    func startOutgoingCall(
        uuid: UUID,
        handle: String
    ) {
        let handle = CXHandle(type: .generic, value: handle)
        let action = CXStartCallAction(call: uuid, handle: handle)
        action.isVideo = true

        let transaction = CXTransaction(action: action)

        controller.request(transaction) { error in
            if let error {
                print("❌ Start call error:", error)
            } else {
                print("✅ Outgoing call started")
                Task { @MainActor in
                    self.activeCallUUID = uuid
                    self.incomingCallerName = handle.value
                    self.isIncomingCall = false
                }
            }
        }
    }

    func endCall(uuid: UUID) {
        let action = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: action)

        controller.request(transaction) { error in
            if let error {
                print("❌ End call error:", error)
            } else {
                print("✅ Call ended")
                Task { @MainActor in
                    self.activeCallUUID = nil
                    self.incomingCallerName = nil
                    self.isIncomingCall = false
                }
            }
        }
    }
}

extension CallKitManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        activeCallUUID = nil
        incomingCallerName = nil
        isIncomingCall = false
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        print("✅ User accepted incoming call")

        Task {
            try? await AppEnvironment.shared.callService.answerCall(sessionID: action.callUUID)
            try? await LiveKitManager.shared.acceptIncomingCall()
            action.fulfill()
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        print("📞 User ended call")

        Task {
            try? await AppEnvironment.shared.callService.endCall(sessionID: action.callUUID)
            await LiveKitManager.shared.disconnect()
            await MainActor.run {
                self.incomingCallerName = nil
                self.isIncomingCall = false
            }
            action.fulfill()
        }
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        print("📞 User started outgoing call")
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate session: AVAudioSession) {
        #if canImport(LiveKit)
        print("🎧 CallKit didActivate")
        do {
            AudioManager.shared.isAutomaticConfigurationEnabled = false
            try AudioManager.shared.setEngineAvailability(.default)
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
            )
            try session.setActive(true)
            try? session.overrideOutputAudioPort(.speaker)
        } catch {
            print("❌ CallKit audio activation error:", error)
        }
        #endif
    }

    func provider(_ provider: CXProvider, didDeactivate session: AVAudioSession) {
        #if canImport(LiveKit)
        print("🔇 CallKit didDeactivate")
        guard self.activeCallUUID == nil else {
            print("ℹ️ Skipping audio engine shutdown: call still active")
            return
        }
        do {
            try AudioManager.shared.setEngineAvailability(.none)
        } catch {
            print("❌ CallKit audio deactivation error:", error)
        }
        #endif
    }
}
#else
import SwiftUI

@MainActor
final class CallKitManager: NSObject, ObservableObject {
    static let shared = CallKitManager()
    @Published var activeCallUUID: UUID?
    @Published var incomingCallerName: String?
    @Published var isIncomingCall = false

    func reportIncomingCall(uuid: UUID, callerName: String, hasVideo: Bool = true) {
        activeCallUUID = uuid
        incomingCallerName = callerName
        isIncomingCall = true
    }

    func startOutgoingCall(uuid: UUID, handle: String) {
        activeCallUUID = uuid
        incomingCallerName = handle
        isIncomingCall = false
    }

    func endCall(uuid: UUID) {
        activeCallUUID = nil
        incomingCallerName = nil
        isIncomingCall = false
    }
}
#endif
