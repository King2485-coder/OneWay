import Foundation

final class StubAuthService: AuthService {
    func currentUser() async throws -> UserProfile? {
        guard AuthTokenStore.shared.token() != nil else { return nil }
        let user = try await AuthAPIService.shared.currentAuthenticatedUser()
        guard let id = UUID(uuidString: user.userId) else { return nil }
        return UserProfile(userID: id, displayName: user.displayName)
    }

    func signInAnonymously() async throws -> UserProfile {
        throw NSError(domain: "OneWay.Auth", code: 1, userInfo: [NSLocalizedDescriptionKey: "Please create an account or sign in."])
    }

    func signOut() async throws {
        AuthTokenStore.shared.clearSession()
    }
}
