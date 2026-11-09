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
    private var authObserver: NSObjectProtocol?

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
        observeAuthChanges()
    }

    // MARK: - PushKit event handling

    enum Event {
        case credentialsUpdated(Data)
        case credentialsInvalidated
        case incoming(payload: IncomingPayload, completion: () -> Void)
    }

    struct IncomingPayload: Sendable {
        let roomName: String?
        let hasVideo: Bool
        let callerID: String?
        let callerName: String
        let callerNumber: String?
        let callerDisplay: String
        let callID: UUID
        let eventType: String?
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
        print("📲 VoIP Token:", PrivacyLog.shortID(hex))
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
    private func handleIncomingPush(payload: IncomingPayload, completion: () -> Void) {
        defer { completion() }

        if payload.callerID == AuthTokenStore.shared.currentUserID() {
            #if DEBUG
            print("📲 Ignoring self-originated VoIP push for call:", payload.callID)
            #endif
            return
        }

        if let eventType = payload.eventType,
           eventType != "incoming_oneway_call",
           eventType != "call:ringing" {
            #if DEBUG
            print(
                "DUPLICATE_INCOMING_PRESENTATION_BLOCKED",
                "callSessionId=\(PrivacyLog.shortID(payload.callID.uuidString))",
                "existingCallKitUUID=\(PrivacyLog.shortID(CallKitManager.shared.activeCallUUID?.uuidString ?? ""))",
                "eventType=\(eventType)",
                "sourceFunction=VoIPPushManager.handleIncomingPush",
                "reason=non_incoming_call_event"
            )
            #endif
            return
        }

        if CallKitManager.shared.hasActiveOutgoingSession(callSessionId: payload.callID.uuidString)
            || CallKitManager.shared.isActiveOutgoingCall(uuid: payload.callID) {
            #if DEBUG
            print(
                "DUPLICATE_INCOMING_PRESENTATION_BLOCKED",
                "callSessionId=\(PrivacyLog.shortID(payload.callID.uuidString))",
                "existingCallKitUUID=\(PrivacyLog.shortID(CallKitManager.shared.activeCallUUID?.uuidString ?? ""))",
                "eventType=\(payload.eventType ?? "incoming_oneway_call")",
                "sourceFunction=VoIPPushManager.handleIncomingPush",
                "reason=active_outgoing_session"
            )
            #endif
            return
        }

        LiveKitManager.shared.pendingRoomName = payload.roomName

        if let callerID = payload.callerID {
            environment?.callService.prepareIncomingCall(
                callID: payload.callID,
                callerID: callerID,
                hasVideo: payload.hasVideo,
                roomName: payload.roomName
            )
        }

        CallKitManager.shared.reportIncomingCall(
            uuid: payload.callID,
            callerName: payload.callerName,
            callerNumber: payload.callerNumber,
            hasVideo: payload.hasVideo,
            callSessionId: payload.callID.uuidString,
            sourceFunction: "VoIPPushManager.handleIncomingPush"
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

    private func observeAuthChanges() {
        guard authObserver == nil else { return }
        authObserver = NotificationCenter.default.addObserver(
            forName: AuthTokenStore.tokenDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                let manager = VoIPPushManager.shared
                guard let token = manager.lastVoIPToken else { return }
                await manager.registrar?.register(
                    voipToken: token,
                    environment: Self.currentEnvironment()
                )
            }
        }
    }
}

/// Anything that can ship a VoIP push token to the backend. Decoupled so the
/// manager doesn't import `URLSession` directly — also makes the registrar
/// substitutable in previews/tests.
protocol PushTokenRegistering: Sendable {
    func register(voipToken: String, environment: String) async
    func unregister() async
}
