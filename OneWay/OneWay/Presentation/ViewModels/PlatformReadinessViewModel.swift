import Foundation
import Combine

@MainActor
final class PlatformReadinessViewModel: ObservableObject {
    @Published private(set) var readiness = OneWayPlatformReadiness.localFallback
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let service: PlatformCapabilityService

    init(service: PlatformCapabilityService = NetworkPlatformCapabilityService()) {
        self.service = service
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            readiness = try await service.fetchReadiness()
            errorMessage = nil
        } catch {
            readiness = .localFallback
            errorMessage = "Using local platform checklist until the OneWay backend is reachable."
        }
    }
}
