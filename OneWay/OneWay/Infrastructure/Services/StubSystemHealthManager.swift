import Foundation

final class StubSystemHealthManager: SystemHealthManager {
    private var statuses: [ServiceHealthStatus] = []

    init() {
        let now = Date()
        statuses = [
            ServiceHealthStatus(serviceName: "AuthService", isActive: true, lastCheckedAt: now, lastSyncAt: now, lastError: nil, dependencies: []),
            ServiceHealthStatus(serviceName: "CryptoService", isActive: true, lastCheckedAt: now, lastSyncAt: now, lastError: nil, dependencies: []),
            ServiceHealthStatus(serviceName: "MessagingService", isActive: true, lastCheckedAt: now, lastSyncAt: now, lastError: nil, dependencies: ["CryptoService", "AuthService"]),
            ServiceHealthStatus(serviceName: "CommunityService", isActive: true, lastCheckedAt: now, lastSyncAt: now, lastError: nil, dependencies: ["AuthService"]),
            ServiceHealthStatus(serviceName: "CallService", isActive: true, lastCheckedAt: now, lastSyncAt: now, lastError: nil, dependencies: ["AuthService"]),
            ServiceHealthStatus(serviceName: "BusinessService", isActive: true, lastCheckedAt: now, lastSyncAt: now, lastError: nil, dependencies: ["AuthService"]),
            ServiceHealthStatus(serviceName: "AIStorefrontService", isActive: true, lastCheckedAt: now, lastSyncAt: now, lastError: nil, dependencies: []),
            ServiceHealthStatus(serviceName: "NotificationService", isActive: true, lastCheckedAt: now, lastSyncAt: now, lastError: nil, dependencies: []),
            ServiceHealthStatus(serviceName: "StorageService", isActive: true, lastCheckedAt: now, lastSyncAt: now, lastError: nil, dependencies: [])
        ]
    }

    func runStartupChecks() async -> [ServiceHealthStatus] {
        statuses
    }

    func latestStatuses() -> [ServiceHealthStatus] {
        statuses
    }
}
