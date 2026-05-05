import Foundation

final class StubNotificationService: NotificationService {
    func registerForPushIfNeeded() async {
        // Stub: pretend registration succeeded.
    }

    func handleIncomingSilentPush(payload: [String : Any]) async {
        _ = payload
    }
}
