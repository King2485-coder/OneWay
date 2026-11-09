import Foundation
#if canImport(PushKit)
import PushKit

/// Thin `PKPushRegistryDelegate` that forwards events into a closure. Lives
/// in its own type because `PKPushRegistryDelegate` is a class-bound protocol
/// and we want `VoIPPushManager` to stay an actor-friendly value type host.
///
/// All callbacks dispatch onto the main actor before forwarding so the
/// manager doesn't have to thread-juggle.
final class PushRegistryDelegate: NSObject, PKPushRegistryDelegate {
    /// Set by `VoIPPushManager` at construction. The closure is the only
    /// link back into the manager — keep it light.
    var handler: ((VoIPPushManager.Event) -> Void)?

    func pushRegistry(_ registry: PKPushRegistry,
                      didUpdate pushCredentials: PKPushCredentials,
                      for type: PKPushType) {
        guard type == .voIP else { return }
        let token = pushCredentials.token
        DispatchQueue.main.async {
            self.handler?(.credentialsUpdated(token))
        }
    }

    func pushRegistry(_ registry: PKPushRegistry,
                      didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        DispatchQueue.main.async {
            self.handler?(.credentialsInvalidated)
        }
    }

    /// On iOS 13+ the only legal entry point is the variant that takes a
    /// completion handler. Apple terminates apps that don't ring CallKit
    /// before this completion returns.
    func pushRegistry(_ registry: PKPushRegistry,
                      didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType,
                      completion: @escaping () -> Void) {
        guard type == .voIP else {
            completion()
            return
        }
        // The handler is responsible for invoking `completion()` after
        // CallKit reporting has been requested. We intentionally do NOT
        // call it ourselves here — `VoIPPushManager.handleIncomingPush`
        // calls it in a `defer`.
        let dictionary = payload.dictionaryPayload
        #if DEBUG
        let aps = dictionary["aps"] as? [String: Any]
        let sound = aps?["sound"] as? String
        let eventType = (dictionary["eventType"] as? String) ?? (dictionary["type"] as? String)
        let policy = CallPushSoundPolicy.policy(eventType: eventType, hasVideo: (dictionary["hasVideo"] as? Bool) ?? true)
        let diagnosticCallID = UUID(uuidString: (dictionary["callId"] as? String) ?? "")
        if let sound {
            Task { @MainActor in
                SoundDiagnostics.logAudioPlayRequest(
                    filename: sound,
                    soundID: sound,
                    systemSoundID: nil,
                    avAudioPlayerURL: nil,
                    avPlayerURL: nil,
                    category: .notification,
                    callId: diagnosticCallID,
                    sourceFile: #fileID,
                    sourceFunction: #function,
                    line: #line
                )
            }
        }
        print(
            "CALL_PUSH_SOUND_POLICY",
            "eventType=\(eventType ?? "unknown")",
            "payloadSound=\(sound ?? "nil")",
            "policySound=\(policy.sound ?? "nil")",
            "usesCallKit=\(policy.usesCallKit)",
            "sourceFile=PushRegistryDelegate.swift",
            "function=pushRegistry.didReceiveIncomingPushWith",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))"
        )
        #endif
        let callerID = dictionary["callerId"] as? String
        let callerName = (dictionary["callerName"] as? String)
            ?? (dictionary["displayName"] as? String)
            ?? callerID
            ?? "OneWay Caller"
        let callerNumber = dictionary["callerNumber"] as? String
        let callerDisplay = dictionary["displayName"] as? String
            ?? [callerName, callerNumber].compactMap { $0 }.joined(separator: "\n")
        let incomingPayload = VoIPPushManager.IncomingPayload(
            roomName: dictionary["roomName"] as? String,
            hasVideo: (dictionary["hasVideo"] as? Bool) ?? true,
            callerID: callerID,
            callerName: callerName,
            callerNumber: callerNumber,
            callerDisplay: callerDisplay,
            callID: UUID(uuidString: dictionary["callId"] as? String ?? "") ?? UUID(),
            eventType: (dictionary["eventType"] as? String) ?? (dictionary["type"] as? String)
        )
        DispatchQueue.main.async {
            self.handler?(.incoming(payload: incomingPayload, completion: completion))
        }
    }
}
#endif
