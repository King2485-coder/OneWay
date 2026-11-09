import Foundation

struct OneWayNumber: Codable, Identifiable, Hashable {
    let id: String
    let userId: String
    let number: String
    let label: String?
    let isPrimary: Bool
    let isPaid: Bool
    let createdAt: String
}

struct OneWayNumbersResponse: Codable {
    struct Billing: Codable, Hashable {
        let freeIncluded: Int
        let extraNumberPriceMonthly: Double
        let hasExtraNumbersSubscription: Bool
    }

    let numbers: [OneWayNumber]
    let billing: Billing
}

struct OneWayUserSearchResult: Codable, Identifiable, Hashable {
    let id: String
    let displayName: String?
    let onewayId: String?
    let chirpId: String?
    let emailAlias: String?
    let username: String?
    let primaryNumber: String?
    let isOneWayReachable: Bool?
    let friendshipState: String?
}

struct OneWayUserSearchResponse: Codable {
    let users: [OneWayUserSearchResult]
}

struct OneWayStartCallResponse: Codable {
    let ok: Bool
    let callId: String
    let roomName: String
    let callerName: String
    let callerNumber: String
    let callerDisplay: String
}

struct OneWayIdentity: Codable, Hashable {
    enum PreferredCallerIdentity: String, Codable, CaseIterable, Identifiable {
        case onewayId
        case number

        var id: String { rawValue }

        var title: String {
            switch self {
            case .onewayId:
                return "OneWay ID"
            case .number:
                return "Number"
            }
        }
    }

    let displayName: String
    let walkieName: String
    let onewayId: String
    let chirpId: String
    let emailAlias: String
    let username: String?
    let usernameHidden: Bool
    let showEmailAlias: Bool
    let showOneWayId: Bool
    let showNumbers: Bool
    let preferredCallerIdentity: PreferredCallerIdentity
}

enum OneWayNumberError: LocalizedError {
    case subscriptionRequired
    case noPrimaryNumber

    var errorDescription: String? {
        switch self {
        case .subscriptionRequired:
            return "Extra numbers require $7.99/month."
        case .noPrimaryNumber:
            return "Set a primary OneWay number before placing a number-to-number call."
        }
    }
}
