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
        Task { @MainActor in
            self.handler?(.credentialsUpdated(token))
        }
    }

    func pushRegistry(_ registry: PKPushRegistry,
                      didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        Task { @MainActor in
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
        let dict = payload.dictionaryPayload
        Task { @MainActor in
            self.handler?(.incoming(payload: dict, completion: completion))
        }
    }
}
#endif
