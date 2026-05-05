import Foundation
import Combine

@MainActor
final class DeviceSessionsViewModel: ObservableObject {
    @Published private(set) var sessions: [DeviceSession] = []
    @Published var infoMessage: String?

    private let service: DeviceSessionService

    init(service: DeviceSessionService) {
        self.service = service
    }

    func load() async {
        sessions = (try? await service.fetchSessions()) ?? []
    }

    func linkDummyDevice() async {
        try? await service.linkDummyDevice()
        await load()
        infoMessage = "Dummy device linked."
    }

    func revokeOtherSessions() async {
        try? await service.revokeOtherSessions()
        await load()
        infoMessage = "Other sessions revoked."
    }
}
