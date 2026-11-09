import Foundation
import Combine

@MainActor
final class AdminSecurityDashboardViewModel: ObservableObject {
    @Published private(set) var snapshot: AdminSecurityDashboardSnapshot?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let service: AdminSecurityService

    init(service: AdminSecurityService = APIClient.shared) {
        self.service = service
    }

    func load() async {
        if snapshot == nil { isLoading = true }
        defer { isLoading = false }

        do {
            async let privacy = service.adminPrivacyStatus()
            async let audit = service.adminAuditStatus()
            async let recent = service.adminAuditRecent()
            async let security = service.adminSecurityStatus()

            let loaded = try await AdminSecurityDashboardSnapshot(
                privacy: privacy,
                audit: audit,
                recentAudit: recent.events,
                security: security
            )
            snapshot = loaded
            errorMessage = nil
        } catch {
            errorMessage = "We could not load security status right now. Check admin access and backend health."
        }
    }

    func refresh() async {
        await load()
    }
}
