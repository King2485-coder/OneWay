import Foundation
import Combine

#if canImport(CallKit)
@preconcurrency import CallKit
import AVFoundation
#if canImport(LiveKit)
import LiveKit
#endif

@MainActor
final class CallKitManager: NSObject, ObservableObject {
    static let shared = CallKitManager()

    @Published var activeCallUUID: UUID?
    @Published var incomingCallerName: String?
    @Published var isIncomingCall = false
    @Published private(set) var isAudioSessionActive = false

    private var outgoingCallKitUUIDBySessionID: [String: UUID] = [:]
    private var outgoingSessionIDByCallKitUUID: [UUID: String] = [:]

    override init() {
        super.init()

        #if DEBUG
        print(
            "CALLKIT_MANAGER_PROVIDER_DISABLED",
            "reason=CallKitBridge_is_single_provider_owner",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
    }

    func reportIncomingCall(
        uuid: UUID,
        callerName: String,
        callerNumber: String? = nil,
        hasVideo: Bool = true,
        callSessionId: String? = nil,
        sourceFunction: String = "CallKitManager.reportIncomingCall"
    ) {
        if shouldBlockIncomingPresentation(uuid: uuid, callSessionId: callSessionId, sourceFunction: sourceFunction) {
            return
        }

        Task {
            do {
                try await CallKitBridge.shared.reportIncomingCall(uuid: uuid, handle: callerNumber ?? callerName, hasVideo: hasVideo)
                await MainActor.run {
                    self.activeCallUUID = uuid
                    self.incomingCallerName = ["OneWay", callerName, callerNumber].compactMap { $0 }.joined(separator: "\n")
                    self.isIncomingCall = true
                }
            } catch {
                #if DEBUG
                print("❌ CallKit incoming call error:", PrivacyLog.redact(error.localizedDescription))
                #endif
            }
        }
    }

    func startOutgoingCall(
        uuid: UUID,
        handle: String,
        hasVideo: Bool = true,
        callSessionId: String? = nil
    ) {
        let handleValue = handle
        Task {
            do {
                try await CallKitBridge.shared.reportOutboundCallStarted(uuid: uuid, handle: handle, hasVideo: hasVideo)
                await MainActor.run {
                    self.activeCallUUID = uuid
                    self.incomingCallerName = handleValue
                    self.isIncomingCall = false
                    self.bindOutgoingCallSession(callSessionId, uuid: uuid)
                    #if DEBUG
                    print(
                        "callkit.outgoing.started",
                        "callSessionId=\(PrivacyLog.shortID(callSessionId ?? ""))",
                        "uuid=\(PrivacyLog.shortID(uuid.uuidString))",
                        "sourceFunction=CallKitManager.startOutgoingCall"
                    )
                    #endif
                }
            } catch {
                #if DEBUG
                print("❌ Start call error:", PrivacyLog.redact(error.localizedDescription))
                #endif
            }
        }
    }

    func endCall(uuid: UUID) {
        Task {
            do {
                try await CallKitBridge.shared.endCall(uuid: uuid)
                await MainActor.run {
                    self.clearOutgoingCallSession(uuid: uuid)
                    self.activeCallUUID = nil
                    self.incomingCallerName = nil
                    self.isIncomingCall = false
                }
            } catch {
                #if DEBUG
                print("❌ End call error:", PrivacyLog.redact(error.localizedDescription))
                #endif
            }
        }
    }

    func reportOutgoingCallConnected(uuid: UUID) {
        CallKitBridge.shared.reportConnected(uuid: uuid)
        #if DEBUG
        print(
            "callkit.outgoing.connected",
            "callSessionId=\(PrivacyLog.shortID(outgoingSessionIDByCallKitUUID[uuid] ?? ""))",
            "uuid=\(PrivacyLog.shortID(uuid.uuidString))",
            "sourceFunction=CallKitManager.reportOutgoingCallConnected"
        )
        #endif
    }

    func hasActiveOutgoingSession(callSessionId: String?) -> Bool {
        guard let normalizedSessionID = normalizedCallSessionID(callSessionId) else { return false }
        return outgoingCallKitUUIDBySessionID[normalizedSessionID] != nil
    }

    func isActiveOutgoingCall(uuid: UUID) -> Bool {
        activeCallUUID == uuid && !isIncomingCall
    }

    func waitForAudioSessionActivation(timeoutSeconds: TimeInterval = 3) async {
        guard let activeCallUUID else { return }
        try? await CallKitBridge.shared.waitForAudioSessionActivation(
            callId: activeCallUUID,
            timeoutSeconds: timeoutSeconds,
            lifecycleState: .waitingForAudioActivation
        )
        isAudioSessionActive = true
    }
}

extension CallKitManager {
    private func bindOutgoingCallSession(_ callSessionId: String?, uuid: UUID) {
        guard let normalizedSessionID = normalizedCallSessionID(callSessionId) else { return }
        outgoingCallKitUUIDBySessionID[normalizedSessionID] = uuid
        outgoingSessionIDByCallKitUUID[uuid] = normalizedSessionID
    }

    private func clearOutgoingCallSession(uuid: UUID) {
        guard let callSessionID = outgoingSessionIDByCallKitUUID.removeValue(forKey: uuid) else { return }
        outgoingCallKitUUIDBySessionID.removeValue(forKey: callSessionID)
    }

    private func shouldBlockIncomingPresentation(
        uuid: UUID,
        callSessionId: String?,
        sourceFunction: String
    ) -> Bool {
        if let normalizedSessionID = normalizedCallSessionID(callSessionId),
           let existingUUID = outgoingCallKitUUIDBySessionID[normalizedSessionID] {
            #if DEBUG
            print(
                "DUPLICATE_INCOMING_PRESENTATION_BLOCKED",
                "callSessionId=\(PrivacyLog.shortID(normalizedSessionID))",
                "existingCallKitUUID=\(PrivacyLog.shortID(existingUUID.uuidString))",
                "incomingUUID=\(PrivacyLog.shortID(uuid.uuidString))",
                "eventType=incoming_oneway_call",
                "sourceFunction=\(sourceFunction)",
                "reason=active_outgoing_session"
            )
            #endif
            return true
        }

        if isActiveOutgoingCall(uuid: uuid) {
            #if DEBUG
            print(
                "DUPLICATE_INCOMING_PRESENTATION_BLOCKED",
                "callSessionId=\(PrivacyLog.shortID(callSessionId ?? ""))",
                "existingCallKitUUID=\(PrivacyLog.shortID(uuid.uuidString))",
                "incomingUUID=\(PrivacyLog.shortID(uuid.uuidString))",
                "eventType=incoming_oneway_call",
                "sourceFunction=\(sourceFunction)",
                "reason=active_outgoing_callkit_uuid"
            )
            #endif
            return true
        }

        return false
    }

    private func normalizedCallSessionID(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return trimmed.isEmpty ? nil : trimmed
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
    private var outgoingCallKitUUIDBySessionID: [String: UUID] = [:]
    private var outgoingSessionIDByCallKitUUID: [UUID: String] = [:]

    func reportIncomingCall(
        uuid: UUID,
        callerName: String,
        callerNumber: String? = nil,
        hasVideo: Bool = true,
        callSessionId: String? = nil,
        sourceFunction: String = "CallKitManager.reportIncomingCall"
    ) {
        if let callSessionId,
           outgoingCallKitUUIDBySessionID[callSessionId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] != nil {
            return
        }
        activeCallUUID = uuid
        incomingCallerName = ["OneWay", callerName, callerNumber].compactMap { $0 }.joined(separator: "\n")
        isIncomingCall = true
    }

    func startOutgoingCall(uuid: UUID, handle: String, hasVideo: Bool = true, callSessionId: String? = nil) {
        activeCallUUID = uuid
        incomingCallerName = handle
        isIncomingCall = false
        if let normalized = callSessionId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !normalized.isEmpty {
            outgoingCallKitUUIDBySessionID[normalized] = uuid
            outgoingSessionIDByCallKitUUID[uuid] = normalized
        }
    }

    func endCall(uuid: UUID) {
        if let callSessionID = outgoingSessionIDByCallKitUUID.removeValue(forKey: uuid) {
            outgoingCallKitUUIDBySessionID.removeValue(forKey: callSessionID)
        }
        activeCallUUID = nil
        incomingCallerName = nil
        isIncomingCall = false
    }

    func reportOutgoingCallConnected(uuid: UUID) {}

    func hasActiveOutgoingSession(callSessionId: String?) -> Bool {
        guard let normalized = callSessionId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else {
            return false
        }
        return outgoingCallKitUUIDBySessionID[normalized] != nil
    }

    func isActiveOutgoingCall(uuid: UUID) -> Bool {
        activeCallUUID == uuid && !isIncomingCall
    }

    func waitForAudioSessionActivation(timeoutSeconds: TimeInterval = 3) async {}
}
#endif
