import Foundation

enum OneWayIdentityInputError: LocalizedError {
    case missingDisplayName
    case missingUsername
    case invalidOneWayID
    case invalidEmailAlias

    var errorDescription: String? {
        switch self {
        case .missingDisplayName:
            return "Display name is required."
        case .missingUsername:
            return "Private username is required."
        case .invalidOneWayID:
            return "OneWay ID must start with @, use lowercase, and contain no spaces."
        case .invalidEmailAlias:
            return "OneWay email alias must be lowercase, contain no spaces, and use valid characters."
        }
    }
}

final class OneWayIdentityService {
    static let shared = OneWayIdentityService()

    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    func fetchMyIdentity() async throws -> OneWayIdentity {
        try await client.get("api/identity/me")
    }

    func updateIdentity(
        displayName: String,
        walkieName: String,
        username: String,
        usernameHidden: Bool,
        onewayId: String,
        emailAlias: String,
        showEmailAlias: Bool,
        showOneWayId: Bool,
        showNumbers: Bool,
        preferredCallerIdentity: OneWayIdentity.PreferredCallerIdentity
    ) async throws -> OneWayIdentity {
        let sanitizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitizedWalkieName = walkieName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitizedOneWayId = sanitizeOneWayID(onewayId)
        let sanitizedEmailAlias = sanitizeEmailAlias(emailAlias)

        guard !sanitizedDisplayName.isEmpty else { throw OneWayIdentityInputError.missingDisplayName }
        guard !sanitizedUsername.isEmpty else { throw OneWayIdentityInputError.missingUsername }
        guard sanitizedOneWayId != nil else { throw OneWayIdentityInputError.invalidOneWayID }
        guard sanitizedEmailAlias != nil else { throw OneWayIdentityInputError.invalidEmailAlias }

        struct Request: Encodable {
            let displayName: String
            let walkieName: String
            let username: String
            let usernameHidden: Bool
            let onewayId: String
            let emailAlias: String
            let showEmailAlias: Bool
            let showOneWayId: Bool
            let showNumbers: Bool
            let preferredCallerIdentity: String
        }

        return try await client.patch(
            "api/identity/me",
            body: Request(
                displayName: sanitizedDisplayName,
                walkieName: sanitizedWalkieName.isEmpty ? sanitizedDisplayName : sanitizedWalkieName,
                username: sanitizedUsername,
                usernameHidden: usernameHidden,
                onewayId: sanitizedOneWayId ?? onewayId,
                emailAlias: sanitizedEmailAlias ?? emailAlias,
                showEmailAlias: showEmailAlias,
                showOneWayId: showOneWayId,
                showNumbers: showNumbers,
                preferredCallerIdentity: preferredCallerIdentity.rawValue
            )
        )
    }

    private func sanitizeOneWayID(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        guard !trimmed.isEmpty else { return nil }
        let prefixed = trimmed.hasPrefix("@") ? trimmed : "@\(trimmed)"
        guard prefixed.range(of: #"^@[a-z0-9._-]{2,32}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return prefixed
    }

    private func sanitizeEmailAlias(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        guard !trimmed.isEmpty else { return nil }
        let localPart = trimmed.replacingOccurrences(of: "@oneway.app", with: "")
        guard localPart.range(of: #"^[a-z0-9._-]{2,32}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return localPart
    }
}
