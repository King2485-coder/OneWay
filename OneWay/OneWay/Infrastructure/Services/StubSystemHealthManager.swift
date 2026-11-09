import Foundation

/// Reports only checks that are actually performed. It deliberately does not
/// infer the health of auth, crypto, messaging, calls, or storage from app
/// startup; those services need their own verified probes before appearing in
/// Diagnostics.
final class NetworkSystemHealthManager: SystemHealthManager {
    private var statuses: [ServiceHealthStatus] = []

    func runStartupChecks() async -> [ServiceHealthStatus] {
        let checkedAt = Date()
        let state = await APIClient.shared.health()
        let status: ServiceHealthStatus
        switch state {
        case .connected:
            status = ServiceHealthStatus(
                serviceName: "OneWay API",
                isActive: true,
                lastCheckedAt: checkedAt,
                lastSyncAt: checkedAt,
                lastError: nil,
                dependencies: []
            )
        case .checking:
            status = ServiceHealthStatus(
                serviceName: "OneWay API",
                isActive: false,
                lastCheckedAt: checkedAt,
                lastSyncAt: nil,
                lastError: "Health check did not finish.",
                dependencies: []
            )
        case .unreachable(let reason):
            status = ServiceHealthStatus(
                serviceName: "OneWay API",
                isActive: false,
                lastCheckedAt: checkedAt,
                lastSyncAt: nil,
                lastError: reason,
                dependencies: []
            )
        }
        statuses = [status]
        return statuses
    }

    func latestStatuses() -> [ServiceHealthStatus] {
        statuses
    }
}
