import Foundation

struct AuthUserDTO: Codable, Equatable {
    struct IdentityDTO: Codable, Equatable {
        let displayName: String?
        let walkieName: String?
        let username: String?
        let usernameHidden: Bool?
        let onewayId: String?
        let emailAlias: String?
        let showEmailAlias: Bool?
        let showOneWayId: Bool?
        let showNumbers: Bool?
        let preferredCallerIdentity: String?
    }

    let id: String
    let email: String
    let displayName: String
    let identity: IdentityDTO?
}

struct AuthResponseDTO: Codable, Equatable {
    let token: String
    let user: AuthUserDTO
}

struct AuthenticatedUserDTO: Codable, Equatable {
    let userId: String
    let email: String?
    let displayName: String
    let handle: String?
    let username: String?
    let chirpId: String?
}

struct PasswordResetResponseDTO: Codable, Equatable {
    let ok: Bool
    let message: String
}

enum AuthIdentityVerificationError: LocalizedError {
    case tokenUserMismatch(tokenSubject: String, responseUserId: String)
    case loginResponseMismatch(tokenSubject: String, responseUserId: String)

    var errorDescription: String? {
        switch self {
        case .tokenUserMismatch:
            return "We couldn't verify this account. Please sign in again."
        case .loginResponseMismatch:
            return "We couldn't verify this login. Please sign in again."
        }
    }
}

final class AuthAPIService {
    static let shared = AuthAPIService()

    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    func login(
        identifier: String,
        password: String,
        source: String = "AuthAPIService.login",
        retryCount: Int = 0
    ) async throws -> AuthResponseDTO {
        struct Body: Encodable {
            let identifier: String
            let password: String
        }
        #if DEBUG
        print(
            "auth.login.request",
            "timestamp=\(ISO8601DateFormatter().string(from: Date()))",
            "identifier=\(PrivacyLog.redact(identifier))",
            "source=\(source)",
            "retryCount=\(retryCount)"
        )
        #endif
        let response: AuthResponseDTO = try await client.post(
            "api/auth/login",
            body: Body(identifier: identifier, password: password),
            requiresAuth: false,
            headers: [
                "x-oneway-auth-source": source,
                "x-oneway-auth-retry-count": String(retryCount),
            ]
        )
        try Self.verifyLoginResponse(response)
        OneWayGrowthEventReporter.shared.record(.loginCompleted, anonymousUserKey: response.user.id, metadata: ["source": "auth_api"])
        return response
    }

    func register(
        email: String,
        password: String,
        displayName: String? = nil,
        username: String? = nil,
        onewayId: String? = nil,
        emailAlias: String? = nil,
        walkieName: String? = nil
    ) async throws -> AuthResponseDTO {
        struct Body: Encodable {
            let email: String
            let password: String
            let displayName: String?
            let walkieName: String?
            let username: String?
            let onewayId: String?
            let emailAlias: String?
            let usernameHidden: Bool
        }
        let response: AuthResponseDTO = try await client.post(
            "api/auth/register",
            body: Body(
                email: email,
                password: password,
                displayName: Self.nonBlank(displayName),
                walkieName: Self.nonBlank(walkieName),
                username: Self.nonBlank(username),
                onewayId: Self.nonBlank(onewayId),
                emailAlias: Self.nonBlank(emailAlias),
                usernameHidden: true
            ),
            requiresAuth: false
        )
        try Self.verifyLoginResponse(response)
        OneWayGrowthEventReporter.shared.record(.signupCompleted, anonymousUserKey: response.user.id, metadata: ["source": "auth_api"])
        if response.user.identity != nil {
            OneWayGrowthEventReporter.shared.recordFirst(.profileCreated, anonymousUserKey: response.user.id, metadata: ["source": "auth_api"])
        }
        return response
    }

    func currentAuthenticatedUser() async throws -> AuthenticatedUserDTO {
        let response: AuthenticatedUserDTO
        do {
            response = try await client.get("api/auth/me")
        } catch let apiError as APIClientError {
            guard case .server(let statusCode, _) = apiError, statusCode == 404 else {
                throw apiError
            }
            response = try await currentAuthenticatedUserFromLegacyIdentity()
        }

        if let tokenSubject = AuthTokenStore.shared.tokenSubject(),
           tokenSubject.caseInsensitiveCompare(response.userId) != .orderedSame {
            throw AuthIdentityVerificationError.tokenUserMismatch(
                tokenSubject: tokenSubject,
                responseUserId: response.userId
            )
        }
        return response
    }

    func requestPasswordReset(identifier: String) async throws -> PasswordResetResponseDTO {
        struct Body: Encodable { let identifier: String }
        return try await client.post(
            "api/auth/password-reset/request",
            body: Body(identifier: identifier),
            requiresAuth: false
        )
    }

    func confirmPasswordReset(
        identifier: String,
        code: String,
        newPassword: String
    ) async throws -> PasswordResetResponseDTO {
        struct Body: Encodable {
            let identifier: String
            let code: String
            let newPassword: String
        }
        return try await client.post(
            "api/auth/password-reset/confirm",
            body: Body(identifier: identifier, code: code, newPassword: newPassword),
            requiresAuth: false
        )
    }

    private func currentAuthenticatedUserFromLegacyIdentity() async throws -> AuthenticatedUserDTO {
        guard let userId = AuthTokenStore.shared.tokenSubject() ?? AuthTokenStore.shared.storedUserID(),
              !userId.isEmpty else {
            throw AuthIdentityVerificationError.tokenUserMismatch(
                tokenSubject: "none",
                responseUserId: "none"
            )
        }

        let identity = try await OneWayIdentityService.shared.fetchMyIdentity()
        return AuthenticatedUserDTO(
            userId: userId,
            email: identity.emailAlias,
            displayName: identity.displayName,
            handle: identity.onewayId,
            username: identity.username,
            chirpId: identity.chirpId
        )
    }

    private static func nonBlank(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func verifyLoginResponse(_ response: AuthResponseDTO) throws {
        guard let tokenSubject = AuthTokenStore.subject(fromJWT: response.token) else { return }
        guard tokenSubject.caseInsensitiveCompare(response.user.id) == .orderedSame else {
            throw AuthIdentityVerificationError.loginResponseMismatch(
                tokenSubject: tokenSubject,
                responseUserId: response.user.id
            )
        }
    }
}
