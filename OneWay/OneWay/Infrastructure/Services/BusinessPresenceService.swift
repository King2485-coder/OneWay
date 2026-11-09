import Foundation

struct BusinessPresenceProfile: Codable, Equatable, Identifiable {
    let id: String
    let userId: String
    var businessName: String
    var industry: String
    var publicPhoneNumber: String
    var businessHours: String
    var greeting: String
    var missedCallAutoReply: String
    var aiReceptionistEnabled: Bool
    var planId: String
    var smsStatus: String
    var voiceStatus: String
    var setupStep: String
    var onboardingProgress: Int
    let createdAt: String?
    let updatedAt: String?

    static let empty = BusinessPresenceProfile(
        id: "local",
        userId: "",
        businessName: "",
        industry: "",
        publicPhoneNumber: "",
        businessHours: "",
        greeting: "",
        missedCallAutoReply: "",
        aiReceptionistEnabled: false,
        planId: "",
        smsStatus: "notConfigured",
        voiceStatus: "notConfigured",
        setupStep: "businessIdentity",
        onboardingProgress: 0,
        createdAt: nil,
        updatedAt: nil
    )
}

struct BusinessPresenceUpdate: Encodable {
    var businessName: String?
    var industry: String?
    var businessHours: String?
    var greeting: String?
    var missedCallAutoReply: String?
    var aiReceptionistEnabled: Bool?
    var planId: String?
    var smsStatus: String?
    var voiceStatus: String?
    var setupStep: String?
    var onboardingProgress: Int?
}

struct BusinessSetupServiceStatus: Codable, Equatable {
    let status: String
    let provider: String?
    let configured: Bool?
    let registrationRequired: Bool?
    let missing: [String]?
}

struct BusinessSetupNextAction: Codable, Equatable {
    let step: String
    let title: String
    let message: String
    let actionLabel: String
}

struct BusinessPlan: Codable, Equatable, Identifiable, Hashable {
    let id: String
    let name: String
    let monthlyPrice: Double
    let tagline: String
    let features: [String]
    let recommended: Bool
}

struct BusinessPlansResponse: Codable, Equatable {
    let plans: [BusinessPlan]
}

struct BusinessPhoneNumberSearchResult: Codable, Equatable, Identifiable, Hashable {
    struct Capabilities: Codable, Equatable, Hashable {
        let voice: Bool
        let sms: Bool
    }

    var id: String { phoneNumber }

    let phoneNumber: String
    let displayName: String
    let locality: String?
    let region: String?
    let capabilities: Capabilities
    let monthlyPrice: Double
    let setupPrice: Double
    let provider: String
    let purchaseToken: String
    let purchaseTokenExpiresAt: String
}

struct BusinessNumberSearchResponse: Codable, Equatable {
    let results: [BusinessPhoneNumberSearchResult]
    let provider: String
    let mode: String
}

struct BusinessNumberPurchaseResponse: Codable, Equatable {
    struct MessagingAttachment: Codable, Equatable {
        let status: String
        let message: String
        let serviceSid: String?
    }

    let number: OneWayNumber
    let provider: String
    let mode: String
    let providerNumberId: String?
    let messagingAttachment: MessagingAttachment?
}

struct BusinessSetupStatus: Codable, Equatable {
    let profile: BusinessPresenceProfile
    let numberConfigured: Bool
    let selectedPlan: BusinessPlan?
    let pstnPreflightStatus: BusinessSetupServiceStatus
    let smsStatus: BusinessSetupServiceStatus
    let voicemailConfigured: Bool
    let aiReceptionistEnabled: Bool
    let nextRecommendedAction: BusinessSetupNextAction
}

protocol BusinessPresenceServicing {
    func fetchPlans() async throws -> [BusinessPlan]
    func fetchProfile() async throws -> BusinessPresenceProfile
    func updateProfile(_ update: BusinessPresenceUpdate) async throws -> BusinessPresenceProfile
    func fetchSetupStatus() async throws -> BusinessSetupStatus
    func searchNumbers(areaCode: String?, contains: String?) async throws -> [BusinessPhoneNumberSearchResult]
    func purchaseNumber(phoneNumber: String, planId: String?, purchaseToken: String?, confirmationAccepted: Bool) async throws -> BusinessNumberPurchaseResponse
    func assignNumber(numberId: String?, phoneNumber: String?) async throws -> BusinessPresenceProfile
}

final class NetworkBusinessPresenceService: BusinessPresenceServicing {
    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    func fetchPlans() async throws -> [BusinessPlan] {
        let response: BusinessPlansResponse = try await client.get("api/business/plans")
        return response.plans
    }

    func fetchProfile() async throws -> BusinessPresenceProfile {
        try await client.get("api/business/profile")
    }

    func updateProfile(_ update: BusinessPresenceUpdate) async throws -> BusinessPresenceProfile {
        try await client.put("api/business/profile", body: update)
    }

    func fetchSetupStatus() async throws -> BusinessSetupStatus {
        try await client.get("api/business/setup/status")
    }

    func searchNumbers(areaCode: String?, contains: String?) async throws -> [BusinessPhoneNumberSearchResult] {
        let response: BusinessNumberSearchResponse = try await client.get(
            "api/numbers/search",
            queryItems: [
                URLQueryItem(name: "areaCode", value: areaCode?.nilIfBlank),
                URLQueryItem(name: "contains", value: contains?.nilIfBlank),
            ].filter { $0.value != nil }
        )
        return response.results
    }

    func purchaseNumber(phoneNumber: String, planId: String?, purchaseToken: String?, confirmationAccepted: Bool) async throws -> BusinessNumberPurchaseResponse {
        struct Request: Encodable {
            let phoneNumber: String
            let planId: String?
            let purchaseToken: String?
            let confirmationAccepted: Bool
        }

        return try await client.post(
            "api/numbers/purchase",
            body: Request(
                phoneNumber: phoneNumber,
                planId: planId?.nilIfBlank,
                purchaseToken: purchaseToken?.nilIfBlank,
                confirmationAccepted: confirmationAccepted
            )
        )
    }

    func assignNumber(numberId: String?, phoneNumber: String?) async throws -> BusinessPresenceProfile {
        struct Request: Encodable {
            let numberId: String?
            let phoneNumber: String?
        }

        return try await client.post(
            "api/business/profile/assign-number",
            body: Request(numberId: numberId?.nilIfBlank, phoneNumber: phoneNumber?.nilIfBlank)
        )
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
