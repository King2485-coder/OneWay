import Foundation

enum SentinelRiskLevel: String, Codable, CaseIterable, Sendable {
    case safe
    case low
    case elevated
    case high
    case critical

    var scoreFloor: Int {
        switch self {
        case .safe: 0
        case .low: 20
        case .elevated: 40
        case .high: 65
        case .critical: 85
        }
    }
}

enum SentinelSignalKind: String, Codable, Sendable {
    case newDevice
    case impossibleTravel
    case failedLoginBurst
    case simSwapIndicator
    case recoveryChange
    case stolenToken
    case automatedAccount
    case sessionHijacking
    case fakePaymentRequest
    case accountRecoveryScam
    case maliciousLink
    case impersonation
    case romanceScam
    case investmentScam
    case marketplaceScam
    case suspiciousQRCode
    case urgencyPressure
    case fraudulentShopListing
    case dangerousFile
    case harassmentCampaign
    case maliciousInvitation
    case unsolicitedMessaging
    case accountFarming
    case childSafetyRisk
    case chargebackPattern
    case deliveryComplaintPattern
    case reusedProductImage
    case apiAbuse
    case credentialStuffing
    case ddos
    case databaseAnomaly
    case privilegeEscalation
    case secretLeak
    case maliciousBuild
    case suspiciousAdministrator
    case vulnerableDependency
}

struct SentinelSignal: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let kind: SentinelSignalKind
    let weight: Int
    let summary: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        kind: SentinelSignalKind,
        weight: Int,
        summary: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.weight = max(0, min(weight, 100))
        self.summary = summary
        self.createdAt = createdAt
    }
}

struct SentinelAssessment: Identifiable, Codable, Sendable {
    let id: UUID
    let riskScore: Int
    let riskLevel: SentinelRiskLevel
    let signals: [SentinelSignal]
    let recommendedAction: SentinelAction
    let evaluatedAt: Date
    let privacyMode: String

    init(
        id: UUID = UUID(),
        riskScore: Int,
        signals: [SentinelSignal],
        recommendedAction: SentinelAction,
        evaluatedAt: Date = Date(),
        privacyMode: String = "on-device"
    ) {
        let normalizedScore = max(0, min(riskScore, 100))
        self.id = id
        self.riskScore = normalizedScore
        self.riskLevel = SentinelRiskLevel.from(score: normalizedScore)
        self.signals = signals
        self.recommendedAction = recommendedAction
        self.evaluatedAt = evaluatedAt
        self.privacyMode = privacyMode
    }
}

enum SentinelAction: String, Codable, Sendable {
    case allow
    case warn
    case requireFaceID
    case requirePasskey
    case requireTrustedDeviceApproval
    case quarantine
    case rateLimit
    case temporarilySuspend
    case humanReview
}

extension SentinelRiskLevel {
    static func from(score: Int) -> SentinelRiskLevel {
        switch score {
        case 0..<20: .safe
        case 20..<40: .low
        case 40..<65: .elevated
        case 65..<85: .high
        default: .critical
        }
    }
}
