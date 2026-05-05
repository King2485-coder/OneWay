import Foundation

actor StubDeviceSessionService: DeviceSessionService {
    private var sessions: [DeviceSession] = [
        DeviceSession(id: UUID(), deviceName: "iPhone 16 Pro", lastSeenAt: Date(), isCurrent: true),
        DeviceSession(id: UUID(), deviceName: "iPad Air", lastSeenAt: Date().addingTimeInterval(-3600 * 5), isCurrent: false)
    ]

    func fetchSessions() async throws -> [DeviceSession] {
        sessions.sorted { $0.lastSeenAt > $1.lastSeenAt }
    }

    func linkDummyDevice() async throws {
        sessions.append(DeviceSession(id: UUID(), deviceName: "MacBook Session", lastSeenAt: Date(), isCurrent: false))
    }

    func revokeOtherSessions() async throws {
        sessions = sessions.filter { $0.isCurrent }
    }
}
