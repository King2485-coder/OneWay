import Foundation

actor StubDeviceSessionService: DeviceSessionService {
    private var sessions: [DeviceSession] = []

    func fetchSessions() async throws -> [DeviceSession] {
        sessions.sorted { $0.lastSeenAt > $1.lastSeenAt }
    }

    func linkDummyDevice() async throws {
        throw NSError(domain: "OneWay.DeviceSessions", code: 1, userInfo: [NSLocalizedDescriptionKey: "Device linking is unavailable."])
    }

    func revokeOtherSessions() async throws {
        sessions = sessions.filter { $0.isCurrent }
    }
}
