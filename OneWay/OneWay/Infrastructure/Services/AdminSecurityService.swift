import Foundation

protocol AdminSecurityService {
    func adminPrivacyStatus() async throws -> AdminPrivacyStatus
    func adminAuditStatus() async throws -> AdminAuditStatus
    func adminAuditRecent() async throws -> AdminAuditRecentResponse
    func adminSecurityStatus() async throws -> AdminSecurityStatus
}

extension APIClient: AdminSecurityService {
    func adminPrivacyStatus() async throws -> AdminPrivacyStatus {
        try await get("api/admin/privacy/status")
    }

    func adminAuditStatus() async throws -> AdminAuditStatus {
        try await get("api/admin/audit/status")
    }

    func adminAuditRecent() async throws -> AdminAuditRecentResponse {
        try await get("api/admin/audit/recent", queryItems: [URLQueryItem(name: "limit", value: "12")])
    }

    func adminSecurityStatus() async throws -> AdminSecurityStatus {
        try await get("api/admin/security/status")
    }
}
