import Combine
import Foundation

@MainActor
final class WalkieJoinCoordinator: ObservableObject {
    static let shared = WalkieJoinCoordinator()

    @Published var pendingSessionId: String?

    private init() {}

    func requestJoin(sessionId: String) {
        pendingSessionId = sessionId
    }

    func clear() {
        pendingSessionId = nil
    }
}
