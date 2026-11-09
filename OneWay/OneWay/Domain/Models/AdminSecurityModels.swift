import Foundation

enum AdminJSONValue: Decodable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: AdminJSONValue])
    case array([AdminJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AdminJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: AdminJSONValue].self) {
            self = .object(value)
        } else {
            self = .null
        }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

struct AdminSensitiveFieldCounts: Decodable, Equatable {
    let recordsScanned: Int
    let encryptedValues: Int
    let plaintextLegacyValues: Int
}

struct AdminExternalConversationCounts: Decodable, Equatable {
    let recordsScanned: Int
    let protected: Int
    let plaintextLegacy: Int
    let missingHash: Int
    let missingCiphertext: Int
}

struct AdminSensitiveDataStatus: Decodable, Equatable {
    let storefrontInquiries: AdminSensitiveFieldCounts
    let storefrontOrders: AdminSensitiveFieldCounts
    let storeNotifications: AdminSensitiveFieldCounts
    let storeEmailMessages: AdminSensitiveFieldCounts
    let oneWayMessages: AdminSensitiveFieldCounts
    let externalConversations: AdminExternalConversationCounts

    var legacyPlaintextCount: Int {
        storefrontInquiries.plaintextLegacyValues
        + storefrontOrders.plaintextLegacyValues
        + storeNotifications.plaintextLegacyValues
        + storeEmailMessages.plaintextLegacyValues
        + oneWayMessages.plaintextLegacyValues
        + externalConversations.plaintextLegacy
    }
}

struct AdminEncryptionStatus: Decodable, Equatable {
    let enabled: Bool
    let requested: Bool?
    let currentKeyId: String?
    let availableKeyCount: Int?
    let hashKeyConfigured: Bool
    let hashKeyRequired: Bool?
    let invalidKeyCount: Int?
    let legacyMasterKeyConfigured: Bool?
}

struct AdminPrivacyStatus: Decodable, Equatable {
    let ok: Bool
    let encryption: AdminEncryptionStatus
    let sensitiveData: AdminSensitiveDataStatus
}

struct AdminAuditVerification: Decodable, Equatable {
    let ok: Bool
    let checked: Int
    let total: Int?
    let firstBrokenEventId: String?
    let firstBrokenEventCreatedAt: String?
    let reason: String?
    let lastEventHash: String?
}

struct AdminAuditStatus: Decodable, Equatable {
    let ok: Bool
    let totalEvents: Int
    let verification: AdminAuditVerification
    let latestEventAt: String?
}

struct AdminAuditEvent: Decodable, Equatable, Identifiable {
    let id: String
    let actorId: String?
    let actorType: String
    let action: String
    let resourceType: String
    let resourceId: String?
    let prevHash: String?
    let eventHash: String?
    let createdAt: String
}

struct AdminAuditRecentResponse: Decodable, Equatable {
    let ok: Bool
    let events: [AdminAuditEvent]
}

struct AdminSecurityCheckRun: Decodable, Equatable, Identifiable {
    let id: String
    let checkType: String
    let status: String
    let severity: String
    let summary: String
    let details: [String: AdminJSONValue]?
    let startedAt: String
    let finishedAt: String
}

struct AdminSecurityStatus: Decodable, Equatable {
    let ok: Bool
    let latestAuditVerification: AdminSecurityCheckRun?
    let latestPrivacyDiagnostics: AdminSecurityCheckRun?
    let latestSecretScan: AdminSecurityCheckRun?
    let latestAlerts: [AdminSecurityCheckRun]
    let auditSummary: AdminAuditStatus?
}

struct AdminSecurityDashboardSnapshot: Equatable {
    let privacy: AdminPrivacyStatus
    let audit: AdminAuditStatus
    let recentAudit: [AdminAuditEvent]
    let security: AdminSecurityStatus
}
