import Foundation

protocol DeviceSessionService {
    func fetchSessions() async throws -> [DeviceSession]
    func linkDummyDevice() async throws
    func revokeOtherSessions() async throws
}
