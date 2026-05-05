import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(PushKit)
import PushKit
#endif

/// Owns the app's `PKPushRegistry`, forwards device-token updates to the
/// backend, and translates incoming VoIP pushes into CallKit reports + a
/// "pending call" record that `LiveKitCallService` consumes when the user
/// hits Accept.
///
/// One critical iOS contract: when `didReceiveIncomingPushWith` fires, we
/// MUST call `CXProvider.reportNewIncomingCall(...)` synchronously, before
/// the push completion handler returns. Apple kills apps that take too long
/// or that fail to ring. Anything else (LiveKit connect, network calls)
/// happens later, on the user's `Accept` tap.
///
/// `LiveKitCallService` already exposes a `prepareIncomingCall` method that
/// builds the in-memory session record so a subsequent `answerCall` knows
/// what to connect to.
@MainActor
final class VoIPPushManager: NSObject {
    static let shared = VoIPPushManager()
    private(set) var lastVoIPToken: String?

    /// Set on app launch (from `AppDelegate`) so the manager can talk to
    /// the rest of the call system. Optional because the manager exists
    /// even before `AppEnvironment.live` finishes setting up.
    var environment: AppEnvironment?

    /// Backend client that registers push tokens. Injected by the env.
    var registrar: PushTokenRegistering?

    #if canImport(PushKit)
    private var registry: PKPushRegistry?
    private let delegateProxy = PushRegistryDelegate()
    #endif

    private override init() {
        super.init()
        #if canImport(PushKit)
        delegateProxy.handler = { [weak self] event in
            guard let self else { return }
            self.handle(event)
        }
        #endif
    }

    /// Wire the registry to the main run loop. Idempotent — safe to call
    /// from `application(_:didFinishLaunchingWithOptions:)` and again on
    /// app foreground.
    func register() {
        #if canImport(PushKit)
        if registry != nil { return }
        let r = PKPushRegistry(queue: .main)
        r.delegate = delegateProxy
        r.desiredPushTypes = [.voIP]
        self.registry = r
        // If a token is already cached, surface it to the backend immediately
        // so a fresh server can resync without waiting for Apple to push us
        // a new credential.
        if let cached = r.pushToken(for: .voIP) {
            forwardToken(cached)
        }
        #endif
    }

    func start() {
        register()
    }

    // MARK: - PushKit event handling

    enum Event {
        case credentialsUpdated(Data)
        case credentialsInvalidated
        case incoming(payload: [AnyHashable: Any], completion: () -> Void)
    }

    fileprivate func handle(_ event: Event) {
        switch event {
        case .credentialsUpdated(let data):
            forwardToken(data)
        case .credentialsInvalidated:
            forwardInvalidation()
        case .incoming(let payload, let completion):
            handleIncomingPush(payload: payload, completion: completion)
        }
    }

    private func forwardToken(_ token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        lastVoIPToken = hex
        print("📲 VoIP Token:", hex)
        Task { [weak self] in
            await self?.registrar?.register(voipToken: hex,
                                            environment: Self.currentEnvironment())
        }
    }

    private func forwardInvalidation() {
        Task { [weak self] in await self?.registrar?.unregister() }
    }

    /// Decode an APNs payload, ring CallKit, stash a pending session in
    /// `LiveKitCallService`. Must complete its CallKit work before
    /// `completion()` returns — anything async runs in a Task afterwards.
    private func handleIncomingPush(payload: [AnyHashable: Any], completion: () -> Void) {
        defer { completion() }

        let roomName = payload["roomName"] as? String
        let hasVideo = (payload["hasVideo"] as? Bool) ?? true
        let callerID = payload["callerId"] as? String
        let callerName = (payload["callerName"] as? String)
            ?? (payload["displayName"] as? String)
            ?? callerID
            ?? "OneWay Caller"
        let callIdString = payload["callId"] as? String ?? UUID().uuidString
        let callID = UUID(uuidString: callIdString) ?? UUID()

        LiveKitManager.shared.pendingRoomName = roomName

        if let callerID {
            environment?.callService.prepareIncomingCall(
                callID: callID,
                callerID: callerID,
                hasVideo: hasVideo,
                roomName: roomName
            )
        }

        CallKitManager.shared.reportIncomingCall(
            uuid: callID,
            callerName: callerName,
            hasVideo: hasVideo
        )
    }

    // MARK: - Helpers

    private static func currentEnvironment() -> String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }
}

/// Anything that can ship a VoIP push token to the backend. Decoupled so the
/// manager doesn't import `URLSession` directly — also makes the registrar
/// substitutable in previews/tests.
protocol PushTokenRegistering: Sendable {
    func register(voipToken: String, environment: String) async
    func unregister() async
}
