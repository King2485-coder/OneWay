import Foundation

extension Notification.Name {
    static let oneWayActionRequested = Notification.Name("OneWay.action.requested")
    static let oneWayDestinationRequested = Notification.Name("OneWay.destination.requested")
}

enum OneWayLaunchDestination: String, Sendable {
    case chirp
    case camera
    case keypad
    case contacts
    case messages
    case quantum
}

@MainActor
final class OneWayActionRouter {
    static let shared = OneWayActionRouter()

    private enum Keys {
        static let pendingLaunchDestination = "OneWay.PendingLaunchDestination"
    }

    private(set) var pendingAction: OneWayButtonAction?
    private let store: OneWayAutomationPreferencesStore

    convenience init() {
        self.init(store: .shared)
    }

    init(store: OneWayAutomationPreferencesStore) {
        self.store = store
    }

    func requestPrimaryAction() {
        guard store.actionButtonEnabled else {
            request(.smartActionMenu)
            return
        }
        request(store.primaryAction)
    }

    func request(_ action: OneWayButtonAction) {
        pendingAction = safeAction(for: action)
        #if DEBUG
        print("[OneWayRoute] action requested raw=\(action.rawValue) safe=\(pendingAction?.rawValue ?? "none")")
        #endif
        NotificationCenter.default.post(
            name: .oneWayActionRequested,
            object: pendingAction?.rawValue
        )
    }

    func requestDestination(_ destination: OneWayLaunchDestination) {
        UserDefaults.standard.set(destination.rawValue, forKey: Keys.pendingLaunchDestination)
        #if DEBUG
        print("[OneWayRoute] pending destination written \(destination.rawValue)")
        #endif
        NotificationCenter.default.post(
            name: .oneWayDestinationRequested,
            object: destination.rawValue
        )
    }

    func consumePendingAction() -> OneWayButtonAction? {
        defer { pendingAction = nil }
        return pendingAction
    }

    func consumePendingDestination() -> OneWayLaunchDestination? {
        guard let raw = UserDefaults.standard.string(forKey: Keys.pendingLaunchDestination),
              let destination = OneWayLaunchDestination(rawValue: raw) else {
            return nil
        }
        UserDefaults.standard.removeObject(forKey: Keys.pendingLaunchDestination)
        #if DEBUG
        print("[OneWayRoute] pending destination consumed \(destination.rawValue)")
        #endif
        return destination
    }

    func safeAction(for action: OneWayButtonAction) -> OneWayButtonAction {
        guard let feature = action.requiresConfirmationPreference else {
            return action
        }

        switch store.state(for: feature) {
        case .on:
            return action
        case .askFirst:
            return .smartActionMenu
        case .off:
            return .smartActionMenu
        }
    }

    func deepLink(for action: OneWayButtonAction) -> URL {
        URL(string: "oneway://actions/\(action.rawValue)") ?? URL(string: "oneway://actions/smartActionMenu")!
    }
}
